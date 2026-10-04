use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};
use teaser_core::SessionId;
use teaserd::ipc::PROTOCOL_VERSION;

const INPUT_FRAME: u8 = 0x01;
const RESIZE_FRAME: u8 = 0x02;
const OUTPUT_FRAME: u8 = 0x81;
const EXIT_FRAME: u8 = 0x83;
const IO_TIMEOUT: Duration = Duration::from_secs(2);
const STATE_TIMEOUT: Duration = Duration::from_secs(2);
const POLL_INTERVAL: Duration = Duration::from_millis(10);

#[test]
fn probe_session_supports_attach_resize_offline_replay_and_exit() {
	let runtime = TestRuntime::new();
	let mut daemon = ProbeDaemon::spawn(&runtime);
	assert_eq!(
		daemon.startup.socket_path,
		runtime.socket_path().display().to_string()
	);
	let _: SessionId = daemon.startup.session_id.parse().unwrap();
	assert_ne!(daemon.startup.process_id, 0);

	let mut first =
		AttachedClient::connect(runtime.socket_path(), &daemon.startup.session_id, 101, 0).unwrap();
	assert_eq!(
		first.read_output_line(),
		format!("READY {}\r\n", daemon.startup.process_id).as_bytes(),
	);

	let rejected = AttachedClient::connect(
		runtime.socket_path(),
		&daemon.startup.session_id,
		202,
		first.next_offset(),
	)
	.unwrap_err();
	assert_eq!(rejected["error"]["code"], "session_already_attached");

	first.send_input(b"PING\n");
	assert_eq!(
		first.read_output_line(),
		format!("PONG {}\r\n", daemon.startup.process_id).as_bytes(),
	);
	first.send_resize(40, 120);
	first.send_input(b"SIZE\n");
	assert_eq!(first.read_output_line(), b"SIZE 40 120\r\n");

	let resume_offset = first.next_offset();
	first.send_input(b"ARM\n");
	drop(first);

	let mut second = connect_after_detach(
		runtime.socket_path(),
		&daemon.startup.session_id,
		303,
		resume_offset,
	);
	assert_eq!(
		second.read_output_line(),
		format!("OFFLINE {}\r\n", daemon.startup.process_id).as_bytes(),
	);
	second.send_input(b"EXIT\n");
	assert_eq!(
		second.read_output_line(),
		format!("EXIT {}\r\n", daemon.startup.process_id).as_bytes(),
	);
	assert_eq!(second.read_exit_code(), 0);
	daemon.wait_for_probe_exit();
}

fn connect_after_detach(
	socket_path: &Path,
	session_id: &str,
	surface_id: u64,
	next_offset: u64,
) -> AttachedClient {
	let deadline = Instant::now() + STATE_TIMEOUT;
	loop {
		match AttachedClient::connect(socket_path, session_id, surface_id, next_offset) {
			Ok(client) => return client,
			Err(response) if response["error"]["code"] == "session_already_attached" => {
				assert!(
					Instant::now() < deadline,
					"timed out waiting for the first probe attachment to detach",
				);
				thread::sleep(POLL_INTERVAL);
			}
			Err(response) => panic!("probe reattach failed: {response}"),
		}
	}
}

#[derive(Debug)]
struct AttachedClient {
	stream: UnixStream,
	next_offset: u64,
	pending_output: Vec<u8>,
}

impl AttachedClient {
	fn connect(
		socket_path: &Path,
		session_id: &str,
		surface_id: u64,
		next_offset: u64,
	) -> Result<Self, Value> {
		let mut stream = UnixStream::connect(socket_path).unwrap();
		stream.set_read_timeout(Some(IO_TIMEOUT)).unwrap();
		stream.set_write_timeout(Some(IO_TIMEOUT)).unwrap();
		let request = json!({
			"version": PROTOCOL_VERSION,
			"request_id": surface_id,
			"method": "session.attach",
			"session_id": session_id,
			"surface_id": surface_id,
			"next_offset": next_offset,
		});
		writeln!(stream, "{request}").unwrap();
		let response = read_json_line(&mut stream);
		if response["status"] != "ok" {
			return Err(response);
		}
		assert_eq!(response["upgrade"], "teaser.attach.v1");
		let replay_from = response["replay_from"].as_u64().unwrap();
		Ok(Self {
			stream,
			next_offset: replay_from,
			pending_output: Vec::new(),
		})
	}

	fn next_offset(&self) -> u64 {
		self.next_offset
	}

	fn send_input(&mut self, bytes: &[u8]) {
		write_frame(&mut self.stream, INPUT_FRAME, bytes);
	}

	fn send_resize(&mut self, rows: u16, columns: u16) {
		let mut payload = Vec::with_capacity(8);
		payload.extend_from_slice(&rows.to_be_bytes());
		payload.extend_from_slice(&columns.to_be_bytes());
		payload.extend_from_slice(&0_u16.to_be_bytes());
		payload.extend_from_slice(&0_u16.to_be_bytes());
		write_frame(&mut self.stream, RESIZE_FRAME, &payload);
	}

	fn read_output_line(&mut self) -> Vec<u8> {
		loop {
			if let Some(end) = self.pending_output.iter().position(|byte| *byte == b'\n') {
				return self.pending_output.drain(..=end).collect();
			}
			let (kind, payload) = read_frame(&mut self.stream);
			assert_eq!(kind, OUTPUT_FRAME);
			assert!(payload.len() >= 8);
			let offset = u64::from_be_bytes(payload[..8].try_into().unwrap());
			assert_eq!(offset, self.next_offset);
			let bytes = &payload[8..];
			self.next_offset += u64::try_from(bytes.len()).unwrap();
			self.pending_output.extend_from_slice(bytes);
		}
	}

	fn read_exit_code(&mut self) -> u32 {
		assert!(self.pending_output.is_empty());
		let (kind, payload) = read_frame(&mut self.stream);
		assert_eq!(kind, EXIT_FRAME);
		assert_eq!(payload.len(), 4);
		u32::from_be_bytes(payload.try_into().unwrap())
	}
}

fn write_frame(stream: &mut UnixStream, kind: u8, payload: &[u8]) {
	stream.write_all(&[kind]).unwrap();
	stream
		.write_all(&u32::try_from(payload.len()).unwrap().to_be_bytes())
		.unwrap();
	stream.write_all(payload).unwrap();
	stream.flush().unwrap();
}

fn read_frame(stream: &mut UnixStream) -> (u8, Vec<u8>) {
	let mut header = [0; 5];
	stream.read_exact(&mut header).unwrap();
	let payload_length = u32::from_be_bytes(header[1..].try_into().unwrap());
	let mut payload = vec![0; usize::try_from(payload_length).unwrap()];
	stream.read_exact(&mut payload).unwrap();
	(header[0], payload)
}

fn read_json_line(stream: &mut UnixStream) -> Value {
	let mut bytes = Vec::new();
	loop {
		let mut byte = [0; 1];
		stream.read_exact(&mut byte).unwrap();
		if byte[0] == b'\n' {
			break;
		}
		bytes.push(byte[0]);
	}
	serde_json::from_slice(&bytes).unwrap()
}

#[derive(Debug, Deserialize)]
struct ProbeStartup {
	socket_path: String,
	session_id: String,
	process_id: u32,
}

struct ProbeDaemon {
	child: Child,
	startup: ProbeStartup,
}

impl ProbeDaemon {
	fn spawn(runtime: &TestRuntime) -> Self {
		let mut child = ChildGuard::new(
			Command::new(env!("CARGO_BIN_EXE_teaserd"))
				.arg("--runtime-dir")
				.arg(runtime.path())
				.arg("--probe-session")
				.stdin(Stdio::null())
				.stdout(Stdio::piped())
				.stderr(Stdio::null())
				.spawn()
				.unwrap(),
		);
		let stdout = child.child_mut().stdout.take().unwrap();
		let (sender, receiver) = mpsc::sync_channel(1);
		let reader = thread::spawn(move || {
			let mut line = String::new();
			let result = BufReader::new(stdout).read_line(&mut line).map(|_| line);
			let _ = sender.send(result);
		});
		let line = match receiver.recv_timeout(STATE_TIMEOUT) {
			Ok(result) => result.unwrap(),
			Err(error) => {
				child.stop();
				reader.join().unwrap();
				panic!("timed out waiting for probe startup: {error}");
			}
		};
		reader.join().unwrap();
		let startup = serde_json::from_str(&line).unwrap();
		Self {
			child: child.into_child(),
			startup,
		}
	}

	fn wait_for_probe_exit(&mut self) {
		let deadline = Instant::now() + STATE_TIMEOUT;
		loop {
			if !process_exists(self.startup.process_id) {
				return;
			}
			assert!(
				Instant::now() < deadline,
				"probe process {} did not exit",
				self.startup.process_id,
			);
			thread::sleep(POLL_INTERVAL);
		}
	}
}

impl Drop for ProbeDaemon {
	fn drop(&mut self) {
		let _ = self.child.kill();
		let _ = self.child.wait();
	}
}

struct ChildGuard {
	child: Option<Child>,
}

impl ChildGuard {
	fn new(child: Child) -> Self {
		Self { child: Some(child) }
	}

	fn child_mut(&mut self) -> &mut Child {
		self.child.as_mut().expect("guard must own its child")
	}

	fn into_child(mut self) -> Child {
		self.child.take().expect("guard must own its child")
	}

	fn stop(&mut self) {
		let Some(mut child) = self.child.take() else {
			return;
		};
		let _ = child.kill();
		let _ = child.wait();
	}
}

impl Drop for ChildGuard {
	fn drop(&mut self) {
		self.stop();
	}
}

fn process_exists(process_id: u32) -> bool {
	Command::new("/bin/kill")
		.arg("-0")
		.arg(process_id.to_string())
		.stdin(Stdio::null())
		.stdout(Stdio::null())
		.stderr(Stdio::null())
		.status()
		.is_ok_and(|status| status.success())
}

struct TestRuntime {
	path: PathBuf,
	socket_path: PathBuf,
}

impl TestRuntime {
	fn new() -> Self {
		let path = PathBuf::from(format!(
			"/tmp/teaserd-probe-{}-{}",
			std::process::id(),
			SessionId::generate(),
		));
		fs::DirBuilder::new()
			.mode(0o700)
			.create(&path)
			.expect("create owned probe runtime directory");
		let socket_path = path.join("control.sock");
		Self { path, socket_path }
	}

	fn path(&self) -> &Path {
		&self.path
	}

	fn socket_path(&self) -> &Path {
		&self.socket_path
	}
}

impl Drop for TestRuntime {
	fn drop(&mut self) {
		let _ = fs::remove_dir_all(&self.path);
	}
}
