use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use rustix::process::{Pid, getpgid};
use serde_json::{Value, json};
use teaser_core::{CheckoutId, SessionId, SurfaceId};
use teaserd::ipc::PROTOCOL_VERSION;
use teaserd::runtime::DaemonRuntime;
use teaserd::{PtySpawnSpec, SessionRegistry, TerminalSize};

const SHELL: &str = "/bin/sh";
const MKFIFO: &str = "/usr/bin/mkfifo";
const KILL: &str = "/bin/kill";
const MOVE: &str = "/bin/mv";
const IO_TIMEOUT: Duration = Duration::from_secs(2);
const STATE_TIMEOUT: Duration = Duration::from_secs(2);
const POLL_INTERVAL: Duration = Duration::from_millis(10);
const MAX_JSON_LINE_BYTES: usize = 64 * 1024;
const MAX_FRAME_PAYLOAD_BYTES: usize = 65_536;

const INPUT_FRAME: u8 = 0x01;
const RESIZE_FRAME: u8 = 0x02;
const OUTPUT_FRAME: u8 = 0x81;
const REPLAY_GAP_FRAME: u8 = 0x82;
const EXIT_FRAME: u8 = 0x83;

const FIXTURE_SCRIPT: &str = r#"set -eu
gate=$1
/bin/stty -echo
printf 'READY %s\n' "$$"
while IFS= read -r command; do
	case "$command" in
		BEFORE)
			printf 'BEFORE %s\n' "$$"
			;;
		ARM)
			printf 'ARMED %s\n' "$$"
			IFS= read -r release < "$gate"
			printf 'DURING %s\n' "$$"
			;;
		SIZE)
			set -- $(/bin/stty size)
			printf 'SIZE %s %s\n' "$1" "$2"
			;;
		EXIT)
			printf 'EXIT %s\n' "$$"
			exit 0
			;;
		*)
			printf 'UNKNOWN\n'
			;;
	esac
done
"#;

const STUBBORN_TREE_FIXTURE_SCRIPT: &str = r#"set -eu
pid_file=$1
pid_file_pending=$pid_file.pending
/bin/stty -echo
/bin/sh -c 'trap "" 1 15; exec /usr/bin/tail -f /dev/null' &
descendant=$!
printf '%s\n' "$descendant" > "$pid_file_pending"
/bin/mv "$pid_file_pending" "$pid_file"
printf 'TREE %s %s\n' "$$" "$descendant"
wait "$descendant"
"#;

const NATURAL_EXIT_STUBBORN_TREE_FIXTURE_SCRIPT: &str = r#"set -eu
pid_file=$1
pid_file_pending=$pid_file.pending
/bin/stty -echo
/bin/sh -c 'trap "" 1 15; exec /usr/bin/tail -f /dev/null' &
descendant=$!
printf '%s\n' "$descendant" > "$pid_file_pending"
/bin/mv "$pid_file_pending" "$pid_file"
printf 'TREE %s %s\n' "$$" "$descendant"
IFS= read -r command
[ "$command" = EXIT_PARENT ]
exit 0
"#;

static NEXT_DIRECTORY_ID: AtomicU64 = AtomicU64::new(1);

#[test]
fn pty_session_survives_detach_replays_missing_output_and_stays_exclusive() {
	let directory = TestDirectory::new();
	let runtime = DaemonRuntime::acquire(directory.path()).unwrap();
	let socket_path = runtime.socket_path().to_owned();
	let (gate_path, mut gate) = create_gate(directory.path());
	let registry = SessionRegistry::new();
	let session = RunningSession::spawn(&registry, &gate_path, 4 * 1024);
	let mut server = TestServer::start(runtime, registry.clone(), 3);

	let mut first = AttachedClient::connect(&socket_path, session.id(), 101, 0).unwrap();
	assert_eq!(first.replay_from(), 0);
	let process_id = parse_process_id(&first.read_output_line(), "READY");
	assert_eq!(registry.session_process_id(session.id()), Some(process_id));

	first.send_input(b"BEFORE\n");
	assert_eq!(
		first.read_output_line(),
		format!("BEFORE {process_id}\r\n").as_bytes(),
	);
	first.send_input(b"ARM\n");
	assert_eq!(
		first.read_output_line(),
		format!("ARMED {process_id}\r\n").as_bytes(),
	);
	let resume_offset = first.consumed_offset();
	assert_eq!(resume_offset, first.next_offset());

	drop(first);
	wait_until("first surface to detach", || {
		registry
			.session(session.id())
			.is_some_and(|snapshot| snapshot.attached_surface_id().is_none())
	});

	gate.write_all(b"release\n").unwrap();
	gate.flush().unwrap();
	let during = format!("DURING {process_id}\r\n");
	let during_end = resume_offset + u64::try_from(during.len()).unwrap();
	wait_until("detached output to enter replay", || {
		registry
			.replay_bounds(session.id())
			.is_some_and(|(_, live_offset)| live_offset >= during_end)
	});
	assert_eq!(registry.replay_bounds(session.id()), Some((0, during_end)));

	let mut second =
		AttachedClient::connect(&socket_path, session.id(), 202, resume_offset).unwrap();
	assert_eq!(second.replay_from(), resume_offset);
	assert_eq!(second.live_offset(), during_end);
	assert_eq!(second.read_output_line(), during.as_bytes());
	assert_eq!(second.consumed_offset(), during_end);
	assert_eq!(registry.session_process_id(session.id()), Some(process_id));

	let rejected = AttachedClient::connect(&socket_path, session.id(), 303, during_end)
		.expect_err("a live session must reject every second surface");
	assert_eq!(rejected["status"], "error");
	assert_eq!(rejected["error"]["code"], "session_already_attached");
	assert_eq!(
		registry
			.session(session.id())
			.unwrap()
			.attached_surface_id(),
		Some(SurfaceId::new(202)),
	);

	second.send_resize(40, 120);
	second.send_input(b"SIZE\n");
	assert_eq!(second.read_output_line(), b"SIZE 40 120\r\n");
	second.send_input(b"EXIT\n");
	assert_eq!(
		second.read_output_line(),
		format!("EXIT {process_id}\r\n").as_bytes(),
	);
	assert_eq!(second.read_frame(), ServerFrame::Exit { code: 0 });
	wait_until("second surface to detach after exit", || {
		registry
			.session(session.id())
			.is_some_and(|snapshot| snapshot.attached_surface_id().is_none())
	});
	registry.terminate_session(session.id()).unwrap();

	server.finish();
}

#[test]
fn attachment_reports_a_gap_before_replaying_a_bounded_suffix() {
	const REPLAY_CAPACITY: usize = 8;

	let directory = TestDirectory::new();
	let runtime = DaemonRuntime::acquire(directory.path()).unwrap();
	let socket_path = runtime.socket_path().to_owned();
	let (gate_path, _gate) = create_gate(directory.path());
	let registry = SessionRegistry::new();
	let session = RunningSession::spawn(&registry, &gate_path, REPLAY_CAPACITY);
	let process_id = registry.session_process_id(session.id()).unwrap();
	let ready = format!("READY {process_id}\r\n");
	let ready_end = u64::try_from(ready.len()).unwrap();
	wait_until("fixture readiness to enter replay", || {
		registry
			.replay_bounds(session.id())
			.is_some_and(|(_, live_offset)| live_offset == ready_end)
	});
	let available_from = ready_end - u64::try_from(REPLAY_CAPACITY).unwrap();
	assert_eq!(
		registry.replay_bounds(session.id()),
		Some((available_from, ready_end)),
	);

	let mut server = TestServer::start(runtime, registry.clone(), 1);
	let mut client = AttachedClient::connect(&socket_path, session.id(), 404, 0).unwrap();
	assert_eq!(client.replay_from(), available_from);
	assert_eq!(client.live_offset(), ready_end);
	assert_eq!(
		client.read_frame(),
		ServerFrame::ReplayGap {
			requested: 0,
			available_from,
		},
	);
	assert_eq!(
		client.read_frame(),
		ServerFrame::Output {
			offset: available_from,
			bytes: ready.as_bytes()[ready.len() - REPLAY_CAPACITY..].to_vec(),
		},
	);

	registry.terminate_session(session.id()).unwrap();
	assert_eq!(client.read_frame(), ServerFrame::Exit { code: 1 });

	server.finish();
}

#[test]
fn terminating_session_reaps_stubborn_process_group_and_closes_attachment() {
	let directory = TestDirectory::new();
	let runtime = DaemonRuntime::acquire(directory.path()).unwrap();
	let socket_path = runtime.socket_path().to_owned();
	let registry = SessionRegistry::new();
	let mut session = StubbornTreeSession::spawn(&registry, directory.path());
	let mut server = TestServer::start(runtime, registry.clone(), 1);
	let mut client = AttachedClient::connect(&socket_path, session.id(), 505, 0).unwrap();

	let (parent_pid, descendant_pid) = parse_tree_ready(&client.read_output_line());
	assert_eq!(parent_pid, session.parent_pid());
	assert_eq!(descendant_pid, session.descendant_pid());
	assert!(process_exists(parent_pid));
	assert!(process_exists(descendant_pid));
	let parent_process_group = process_group_id(parent_pid);
	assert_eq!(parent_process_group, parent_pid);
	assert_eq!(process_group_id(descendant_pid), parent_process_group);

	let termination_registry = registry.clone();
	let session_id = session.id();
	let (termination_sender, termination_done) = mpsc::sync_channel(1);
	let termination_thread = thread::spawn(move || {
		let result = termination_registry
			.terminate_session(session_id)
			.map_err(|error| error.to_string());
		let _ = termination_sender.send(result);
	});

	match termination_done.recv_timeout(STATE_TIMEOUT) {
		Ok(result) => {
			termination_thread.join().unwrap();
			result.unwrap();
		}
		Err(mpsc::RecvTimeoutError::Timeout) => {
			session.force_cleanup();
			let cleanup_result = termination_done.recv_timeout(IO_TIMEOUT);
			if cleanup_result.is_ok() {
				termination_thread.join().unwrap();
			}
			wait_until("stubborn fixture cleanup", || {
				!process_exists(parent_pid) && !process_exists(descendant_pid)
			});
			session.disarm_cleanup();
			panic!(
				"terminate_session exceeded {STATE_TIMEOUT:?}; direct child {parent_pid} was reaped but descendant {descendant_pid} kept the slave PTY open",
			);
		}
		Err(mpsc::RecvTimeoutError::Disconnected) => {
			termination_thread.join().unwrap();
			panic!("termination worker stopped without reporting a result");
		}
	}

	assert!(matches!(client.read_frame(), ServerFrame::Exit { .. }));
	client.expect_eof();
	wait_until("terminated attachment to detach", || {
		registry
			.session(session.id())
			.is_some_and(|snapshot| snapshot.attached_surface_id().is_none())
	});
	wait_until("terminated process group to disappear", || {
		!process_exists(parent_pid) && !process_exists(descendant_pid)
	});
	session.disarm_cleanup();

	server.finish();
}

#[test]
fn natural_leader_exit_reaps_stubborn_process_group_and_closes_attachment() {
	let directory = TestDirectory::new();
	let runtime = DaemonRuntime::acquire(directory.path()).unwrap();
	let socket_path = runtime.socket_path().to_owned();
	let registry = SessionRegistry::new();
	let mut session = StubbornTreeSession::spawn_natural_exit(&registry, directory.path());
	let mut server = TestServer::start(runtime, registry.clone(), 1);
	let mut client = AttachedClient::connect(&socket_path, session.id(), 606, 0).unwrap();

	let (parent_pid, descendant_pid) = parse_tree_ready(&client.read_output_line());
	assert_eq!(parent_pid, session.parent_pid());
	assert_eq!(descendant_pid, session.descendant_pid());
	assert!(process_exists(parent_pid));
	assert!(process_exists(descendant_pid));
	let parent_process_group = process_group_id(parent_pid);
	assert_eq!(parent_process_group, parent_pid);
	assert_eq!(process_group_id(descendant_pid), parent_process_group);

	client.send_input(b"EXIT_PARENT\n");
	assert_eq!(client.read_frame(), ServerFrame::Exit { code: 0 });
	client.expect_eof();
	wait_until("naturally exited attachment to detach", || {
		registry
			.session(session.id())
			.is_some_and(|snapshot| snapshot.attached_surface_id().is_none())
	});
	wait_until("naturally exited process group to disappear", || {
		!process_exists(parent_pid) && !process_exists(descendant_pid)
	});
	session.disarm_cleanup();

	server.finish();
}

fn create_gate(directory: &Path) -> (PathBuf, File) {
	let metadata = fs::metadata(MKFIFO).expect("/usr/bin/mkfifo must exist on macOS");
	assert!(metadata.is_file());
	assert_ne!(metadata.permissions().mode() & 0o111, 0);

	let path = directory.join("gate");
	let status = Command::new(MKFIFO)
		.arg(&path)
		.stdin(Stdio::null())
		.stdout(Stdio::null())
		.stderr(Stdio::null())
		.status()
		.unwrap();
	assert!(status.success(), "mkfifo failed with {status}");

	// Opening both ends keeps later opens bounded while the fixture waits for a
	// release line. The test never reads this descriptor, so only the fixture
	// can consume the line written by the test.
	let gate = OpenOptions::new()
		.read(true)
		.write(true)
		.open(&path)
		.unwrap();
	(path, gate)
}

fn fixture_spawn_spec(gate_path: &Path) -> PtySpawnSpec {
	let shell = fs::metadata(SHELL).expect("/bin/sh must exist on macOS");
	assert!(shell.is_file());
	assert_ne!(shell.permissions().mode() & 0o111, 0);

	PtySpawnSpec::new(SHELL)
		.arg("-c")
		.arg(FIXTURE_SCRIPT)
		.arg("teaserd-pty-fixture")
		.arg(gate_path.as_os_str())
		.env_clear()
		.env("LC_ALL", "C")
}

fn stubborn_tree_spawn_spec(pid_file: &Path, fixture_script: &str) -> PtySpawnSpec {
	for executable in [SHELL, KILL, MOVE, "/usr/bin/tail"] {
		let metadata = fs::metadata(executable).unwrap_or_else(|error| {
			panic!("required fixture executable {executable} is missing: {error}")
		});
		assert!(metadata.is_file());
		assert_ne!(metadata.permissions().mode() & 0o111, 0);
	}

	PtySpawnSpec::new(SHELL)
		.arg("-c")
		.arg(fixture_script)
		.arg("teaserd-pty-tree-fixture")
		.arg(pid_file.as_os_str())
		.env_clear()
		.env("LC_ALL", "C")
}

fn wait_until(description: &str, mut condition: impl FnMut() -> bool) {
	let deadline = Instant::now() + STATE_TIMEOUT;
	loop {
		if condition() {
			return;
		}
		assert!(
			Instant::now() < deadline,
			"timed out waiting for {description}"
		);
		thread::sleep(POLL_INTERVAL);
	}
}

fn parse_process_id(line: &[u8], label: &str) -> u32 {
	let line = std::str::from_utf8(line).unwrap();
	let value = line
		.strip_suffix("\r\n")
		.and_then(|line| line.strip_prefix(label))
		.and_then(|line| line.strip_prefix(' '))
		.unwrap_or_else(|| panic!("expected {label} line, got {line:?}"));
	value.parse().unwrap()
}

fn parse_tree_ready(line: &[u8]) -> (u32, u32) {
	let line = std::str::from_utf8(line).unwrap();
	let mut fields = line.trim_end_matches(['\r', '\n']).split_ascii_whitespace();
	assert_eq!(fields.next(), Some("TREE"));
	let parent_pid = fields.next().unwrap().parse().unwrap();
	let descendant_pid = fields.next().unwrap().parse().unwrap();
	assert_eq!(fields.next(), None);
	(parent_pid, descendant_pid)
}

fn process_exists(process_id: u32) -> bool {
	Command::new(KILL)
		.arg("-0")
		.arg(process_id.to_string())
		.stdin(Stdio::null())
		.stdout(Stdio::null())
		.stderr(Stdio::null())
		.status()
		.is_ok_and(|status| status.success())
}

fn process_group_id(process_id: u32) -> u32 {
	let process_id = i32::try_from(process_id).unwrap();
	let process_id = Pid::from_raw(process_id).unwrap();
	u32::try_from(getpgid(Some(process_id)).unwrap().as_raw_pid()).unwrap()
}

fn force_kill(process_id: u32) {
	let _ = Command::new(KILL)
		.arg("-KILL")
		.arg(process_id.to_string())
		.stdin(Stdio::null())
		.stdout(Stdio::null())
		.stderr(Stdio::null())
		.status();
}

struct RunningSession {
	registry: SessionRegistry,
	session_id: SessionId,
}

impl RunningSession {
	fn spawn(registry: &SessionRegistry, gate_path: &Path, replay_capacity: usize) -> Self {
		let session_id = registry
			.create_pty_session(
				CheckoutId::new(7),
				fixture_spawn_spec(gate_path),
				TerminalSize::new(24, 80).unwrap(),
				replay_capacity,
			)
			.unwrap();
		Self {
			registry: registry.clone(),
			session_id,
		}
	}

	fn id(&self) -> SessionId {
		self.session_id
	}
}

impl Drop for RunningSession {
	fn drop(&mut self) {
		let _ = self.registry.terminate_session(self.session_id);
	}
}

struct StubbornTreeSession {
	session_id: SessionId,
	parent_pid: u32,
	descendant_pid: u32,
	cleanup_armed: bool,
}

impl StubbornTreeSession {
	fn spawn(registry: &SessionRegistry, directory: &Path) -> Self {
		Self::spawn_with_fixture(registry, directory, STUBBORN_TREE_FIXTURE_SCRIPT)
	}

	fn spawn_natural_exit(registry: &SessionRegistry, directory: &Path) -> Self {
		Self::spawn_with_fixture(
			registry,
			directory,
			NATURAL_EXIT_STUBBORN_TREE_FIXTURE_SCRIPT,
		)
	}

	fn spawn_with_fixture(
		registry: &SessionRegistry,
		directory: &Path,
		fixture_script: &str,
	) -> Self {
		let pid_file = directory.join("descendant.pid");
		let session_id = registry
			.create_pty_session(
				CheckoutId::new(8),
				stubborn_tree_spawn_spec(&pid_file, fixture_script),
				TerminalSize::new(24, 80).unwrap(),
				4 * 1024,
			)
			.unwrap();
		let parent_pid = registry.session_process_id(session_id).unwrap();
		let descendant_pid = wait_for_process_id(&pid_file, parent_pid);
		Self {
			session_id,
			parent_pid,
			descendant_pid,
			cleanup_armed: true,
		}
	}

	fn id(&self) -> SessionId {
		self.session_id
	}

	fn parent_pid(&self) -> u32 {
		self.parent_pid
	}

	fn descendant_pid(&self) -> u32 {
		self.descendant_pid
	}

	fn force_cleanup(&self) {
		force_kill(self.descendant_pid);
		force_kill(self.parent_pid);
	}

	fn disarm_cleanup(&mut self) {
		self.cleanup_armed = false;
	}
}

impl Drop for StubbornTreeSession {
	fn drop(&mut self) {
		if self.cleanup_armed {
			self.force_cleanup();
		}
	}
}

fn wait_for_process_id(pid_file: &Path, parent_pid: u32) -> u32 {
	let deadline = Instant::now() + STATE_TIMEOUT;
	loop {
		match fs::read_to_string(pid_file) {
			Ok(contents) => return contents.trim().parse().unwrap(),
			Err(error) if error.kind() == io::ErrorKind::NotFound => {}
			Err(error) => {
				force_kill(parent_pid);
				panic!("failed to read {}: {error}", pid_file.display());
			}
		}
		if Instant::now() >= deadline {
			force_kill(parent_pid);
			panic!("timed out waiting for {}", pid_file.display());
		}
		thread::sleep(POLL_INTERVAL);
	}
}

struct TestDirectory {
	path: PathBuf,
}

impl TestDirectory {
	fn new() -> Self {
		loop {
			let id = NEXT_DIRECTORY_ID.fetch_add(1, Ordering::Relaxed);
			let path = PathBuf::from(format!("/tmp/teaserd-pty-{}-{id}", std::process::id(),));
			match fs::create_dir(&path) {
				Ok(()) => return Self { path },
				Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
				Err(error) => panic!("failed to create {}: {error}", path.display()),
			}
		}
	}

	fn path(&self) -> &Path {
		&self.path
	}
}

impl Drop for TestDirectory {
	fn drop(&mut self) {
		let _ = fs::remove_dir_all(&self.path);
	}
}

struct TestServer {
	socket_path: PathBuf,
	connection_count: usize,
	done: Receiver<Result<(), String>>,
	thread: Option<JoinHandle<()>>,
}

impl TestServer {
	fn start(runtime: DaemonRuntime, registry: SessionRegistry, connection_count: usize) -> Self {
		let socket_path = runtime.socket_path().to_owned();
		let (done_sender, done) = mpsc::sync_channel(1);
		let thread = thread::spawn(move || {
			let result = (0..connection_count)
				.try_for_each(|_| runtime.serve_next(&registry))
				.map_err(|error| error.to_string());
			let _ = done_sender.send(result);
		});
		Self {
			socket_path,
			connection_count,
			done,
			thread: Some(thread),
		}
	}

	fn finish(&mut self) {
		let result = self
			.done
			.recv_timeout(IO_TIMEOUT)
			.expect("server did not accept the expected connections");
		result.unwrap();
		self.thread.take().unwrap().join().unwrap();
	}

	fn wake_accept_loop(&self) {
		for _ in 0..self.connection_count {
			let Ok(mut stream) = UnixStream::connect(&self.socket_path) else {
				break;
			};
			let _ = stream.set_write_timeout(Some(IO_TIMEOUT));
			let _ = stream.write_all(
				format!(
					"{{\"version\":{PROTOCOL_VERSION},\"request_id\":0,\"method\":\"test.wake\"}}\n"
				)
				.as_bytes(),
			);
		}
	}
}

impl Drop for TestServer {
	fn drop(&mut self) {
		if self.thread.is_none() {
			return;
		}
		self.wake_accept_loop();
		if self.done.recv_timeout(IO_TIMEOUT).is_ok()
			&& let Some(thread) = self.thread.take()
		{
			let _ = thread.join();
		}
	}
}

#[derive(Debug)]
struct AttachedClient {
	stream: UnixStream,
	replay_from: u64,
	live_offset: u64,
	next_offset: u64,
	pending_output: Vec<u8>,
}

impl AttachedClient {
	fn connect(
		socket_path: &Path,
		session_id: SessionId,
		surface_id: u64,
		next_offset: u64,
	) -> Result<Self, Value> {
		let mut stream = UnixStream::connect(socket_path).unwrap();
		stream.set_nonblocking(true).unwrap();
		write_json(
			&mut stream,
			&json!({
				"version": PROTOCOL_VERSION,
				"request_id": surface_id,
				"method": "session.attach",
				"session_id": session_id.to_string(),
				"surface_id": surface_id,
				"next_offset": next_offset,
			}),
		);
		let response = read_json(&mut stream);
		if response["status"] == "error" {
			return Err(response);
		}

		assert_eq!(response["version"], PROTOCOL_VERSION);
		assert_eq!(response["request_id"], surface_id);
		assert_eq!(response["status"], "ok");
		assert_eq!(response["session_id"], session_id.to_string());
		assert_eq!(response["upgrade"], "teaser.attach.v1");
		assert_eq!(
			response["max_frame_payload_bytes"],
			u64::try_from(MAX_FRAME_PAYLOAD_BYTES).unwrap(),
		);
		let replay_from = response["replay_from"].as_u64().unwrap();
		let live_offset = response["live_offset"].as_u64().unwrap();

		Ok(Self {
			stream,
			replay_from,
			live_offset,
			next_offset,
			pending_output: Vec::new(),
		})
	}

	fn replay_from(&self) -> u64 {
		self.replay_from
	}

	fn live_offset(&self) -> u64 {
		self.live_offset
	}

	fn next_offset(&self) -> u64 {
		self.next_offset
	}

	fn consumed_offset(&self) -> u64 {
		self.next_offset - u64::try_from(self.pending_output.len()).unwrap()
	}

	fn send_input(&mut self, bytes: &[u8]) {
		write_frame(&mut self.stream, INPUT_FRAME, bytes);
	}

	fn send_resize(&mut self, rows: u16, cols: u16) {
		let mut payload = Vec::with_capacity(8);
		payload.extend_from_slice(&rows.to_be_bytes());
		payload.extend_from_slice(&cols.to_be_bytes());
		payload.extend_from_slice(&0_u16.to_be_bytes());
		payload.extend_from_slice(&0_u16.to_be_bytes());
		write_frame(&mut self.stream, RESIZE_FRAME, &payload);
	}

	fn read_output_line(&mut self) -> Vec<u8> {
		loop {
			if let Some(newline) = self.pending_output.iter().position(|byte| *byte == b'\n') {
				return self.pending_output.drain(..=newline).collect();
			}
			match self.read_frame() {
				ServerFrame::Output { bytes, .. } => self.pending_output.extend(bytes),
				frame => panic!("expected PTY output, got {frame:?}"),
			}
		}
	}

	fn read_frame(&mut self) -> ServerFrame {
		let deadline = Instant::now() + IO_TIMEOUT;
		let mut header = [0_u8; 5];
		read_exact_before(&mut self.stream, &mut header, deadline);
		let payload_length =
			u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
		assert!(
			payload_length <= MAX_FRAME_PAYLOAD_BYTES,
			"server frame payload exceeded bound: {payload_length}",
		);
		let mut payload = vec![0_u8; payload_length];
		read_exact_before(&mut self.stream, &mut payload, deadline);

		match header[0] {
			OUTPUT_FRAME => {
				assert!(payload.len() >= 8, "output frame omitted its offset");
				let offset = u64::from_be_bytes(payload[..8].try_into().unwrap());
				let bytes = payload[8..].to_vec();
				assert_eq!(offset, self.next_offset, "PTY output was not contiguous");
				self.next_offset += u64::try_from(bytes.len()).unwrap();
				ServerFrame::Output { offset, bytes }
			}
			REPLAY_GAP_FRAME => {
				assert_eq!(payload.len(), 16);
				let requested = u64::from_be_bytes(payload[..8].try_into().unwrap());
				let available_from = u64::from_be_bytes(payload[8..].try_into().unwrap());
				assert_eq!(requested, self.next_offset);
				self.next_offset = available_from;
				ServerFrame::ReplayGap {
					requested,
					available_from,
				}
			}
			EXIT_FRAME => {
				assert_eq!(payload.len(), 4);
				ServerFrame::Exit {
					code: u32::from_be_bytes(payload.try_into().unwrap()),
				}
			}
			kind => panic!("unknown server frame kind 0x{kind:02x}"),
		}
	}

	fn expect_eof(&mut self) {
		let deadline = Instant::now() + IO_TIMEOUT;
		loop {
			assert!(
				Instant::now() < deadline,
				"timed out waiting for attachment EOF"
			);
			let mut byte = [0_u8];
			match self.stream.read(&mut byte) {
				Ok(0) => return,
				Ok(_) => panic!("received trailing attachment byte 0x{:02x}", byte[0]),
				Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
				Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
					thread::sleep(Duration::from_millis(1));
				}
				Err(error) => panic!("attachment EOF read failed: {error}"),
			}
		}
	}
}

#[derive(Debug, PartialEq, Eq)]
enum ServerFrame {
	Output { offset: u64, bytes: Vec<u8> },
	ReplayGap { requested: u64, available_from: u64 },
	Exit { code: u32 },
}

fn write_json(stream: &mut UnixStream, value: &Value) {
	let mut bytes = serde_json::to_vec(value).unwrap();
	bytes.push(b'\n');
	write_all_before(stream, &bytes, Instant::now() + IO_TIMEOUT);
}

fn read_json(stream: &mut UnixStream) -> Value {
	let deadline = Instant::now() + IO_TIMEOUT;
	let mut line = Vec::new();
	loop {
		assert!(
			line.len() < MAX_JSON_LINE_BYTES,
			"JSON response exceeded {MAX_JSON_LINE_BYTES} bytes",
		);
		let mut byte = [0_u8];
		read_exact_before(stream, &mut byte, deadline);
		if byte[0] == b'\n' {
			return serde_json::from_slice(&line).unwrap();
		}
		line.push(byte[0]);
	}
}

fn write_frame(stream: &mut UnixStream, kind: u8, payload: &[u8]) {
	assert!(payload.len() <= MAX_FRAME_PAYLOAD_BYTES);
	let payload_length = u32::try_from(payload.len()).unwrap().to_be_bytes();
	let mut frame = Vec::with_capacity(5 + payload.len());
	frame.extend_from_slice(&[
		kind,
		payload_length[0],
		payload_length[1],
		payload_length[2],
		payload_length[3],
	]);
	frame.extend_from_slice(payload);
	write_all_before(stream, &frame, Instant::now() + IO_TIMEOUT);
}

fn read_exact_before(stream: &mut UnixStream, bytes: &mut [u8], deadline: Instant) {
	let mut received = 0;
	while received < bytes.len() {
		assert!(
			Instant::now() < deadline,
			"timed out during attachment read"
		);
		match stream.read(&mut bytes[received..]) {
			Ok(0) => panic!(
				"attachment stream ended after {received} of {} bytes",
				bytes.len(),
			),
			Ok(count) => received += count,
			Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
			Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
				thread::sleep(Duration::from_millis(1));
			}
			Err(error) => panic!("attachment read failed: {error}"),
		}
	}
}

fn write_all_before(stream: &mut UnixStream, bytes: &[u8], deadline: Instant) {
	let mut written = 0;
	while written < bytes.len() {
		assert!(
			Instant::now() < deadline,
			"timed out during attachment write"
		);
		match stream.write(&bytes[written..]) {
			Ok(0) => panic!("attachment write made no progress"),
			Ok(count) => written += count,
			Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
			Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
				thread::sleep(Duration::from_millis(1));
			}
			Err(error) => panic!("attachment write failed: {error}"),
		}
	}
}
