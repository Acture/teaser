use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

use serde_json::{Value, json};
use taco_core::SessionId;
use tacod::ipc::{MAX_REQUEST_BYTES, PROTOCOL_VERSION};

static NEXT_RUNTIME_ID: AtomicU64 = AtomicU64::new(1);

#[test]
fn daemon_creates_a_session_over_versioned_ipc() {
	let runtime = TestRuntime::new();
	let daemon = TestDaemon::spawn(&runtime);
	let runtime_permissions = permissions(runtime.path());
	let lock_permissions = permissions(&runtime.path().join("tacod.lock"));
	let socket_permissions = permissions(runtime.socket_path());

	let response = create_session(daemon.socket_path(), 41, 7);

	assert_eq!(runtime_permissions, 0o700);
	assert_eq!(lock_permissions, 0o600);
	assert_eq!(socket_permissions, 0o600);
	assert_eq!(response["version"], PROTOCOL_VERSION);
	assert_eq!(response["request_id"], 41);
	assert_eq!(response["status"], "ok");
	parse_session_id(&response);
}

#[test]
fn daemon_creates_distinct_sessions_for_one_checkout() {
	let runtime = TestRuntime::new();
	let daemon = TestDaemon::spawn(&runtime);
	let first = parse_session_id(&create_session(daemon.socket_path(), 1, 7));
	let second = parse_session_id(&create_session(daemon.socket_path(), 2, 7));

	assert_ne!(first, second);
}

#[test]
fn unsupported_version_is_rejected_without_stopping_the_daemon() {
	let runtime = TestRuntime::new();
	let daemon = TestDaemon::spawn(&runtime);

	let rejected = request(
		daemon.socket_path(),
		&json!({
			"version": PROTOCOL_VERSION + 1,
			"request_id": 1,
			"method": "session.create",
			"checkout_id": 7,
		})
		.to_string(),
	);
	let accepted = create_session(daemon.socket_path(), 2, 7);

	assert_eq!(rejected["status"], "error");
	assert_eq!(rejected["error"]["code"], "unsupported_version");
	parse_session_id(&accepted);
}

#[test]
fn missing_checkout_id_is_rejected_without_stopping_the_daemon() {
	let runtime = TestRuntime::new();
	let daemon = TestDaemon::spawn(&runtime);

	let rejected = request(
		daemon.socket_path(),
		&json!({
			"version": PROTOCOL_VERSION,
			"request_id": 1,
			"method": "session.create",
		})
		.to_string(),
	);
	let accepted = create_session(daemon.socket_path(), 2, 7);

	assert_eq!(rejected["status"], "error");
	assert_eq!(rejected["error"]["code"], "invalid_parameters");
	parse_session_id(&accepted);
}

#[test]
fn oversized_request_is_rejected_without_stopping_the_daemon() {
	let runtime = TestRuntime::new();
	let daemon = TestDaemon::spawn(&runtime);
	let oversized = "x".repeat(MAX_REQUEST_BYTES + 1);

	let rejected = request(daemon.socket_path(), &oversized);
	let accepted = create_session(daemon.socket_path(), 2, 9);

	assert_eq!(rejected["status"], "error");
	assert_eq!(rejected["error"]["code"], "request_too_large");
	parse_session_id(&accepted);
}

#[test]
fn second_daemon_cannot_take_over_a_live_runtime() {
	let runtime = TestRuntime::new();
	let primary = TestDaemon::spawn(&runtime);
	let mut second = spawn_tacod(runtime.path());

	let status = wait_for_exit(&mut second);
	let response = create_session(primary.socket_path(), 1, 7);

	assert!(!status.success());
	parse_session_id(&response);
}

#[test]
fn killed_daemon_recovers_stale_socket_without_reusing_session_id() {
	let runtime = TestRuntime::new();
	let first_session_id = {
		let daemon = TestDaemon::spawn(&runtime);
		parse_session_id(&create_session(daemon.socket_path(), 1, 7))
	};
	assert!(runtime.socket_path().exists());

	let restarted = TestDaemon::spawn(&runtime);
	let second_session_id = parse_session_id(&create_session(restarted.socket_path(), 2, 7));

	assert_ne!(first_session_id, second_session_id);
}

fn request(socket_path: &Path, payload: &str) -> Value {
	let mut stream = UnixStream::connect(socket_path).unwrap();
	stream.write_all(payload.as_bytes()).unwrap();
	stream.write_all(b"\n").unwrap();

	let mut response = String::new();
	BufReader::new(stream).read_line(&mut response).unwrap();
	serde_json::from_str(&response).unwrap()
}

fn create_session(socket_path: &Path, request_id: u64, checkout_id: u64) -> Value {
	request(
		socket_path,
		&json!({
			"version": PROTOCOL_VERSION,
			"request_id": request_id,
			"method": "session.create",
			"checkout_id": checkout_id,
		})
		.to_string(),
	)
}

fn parse_session_id(response: &Value) -> SessionId {
	response["session_id"].as_str().unwrap().parse().unwrap()
}

fn permissions(path: &Path) -> u32 {
	fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
}

struct TestRuntime {
	path: PathBuf,
	socket_path: PathBuf,
}

impl TestRuntime {
	fn new() -> Self {
		let runtime_id = NEXT_RUNTIME_ID.fetch_add(1, Ordering::Relaxed);
		let path = PathBuf::from(format!(
			"/tmp/tacod-test-{}-{runtime_id}",
			std::process::id(),
		));
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

struct TestDaemon {
	child: Child,
	socket_path: PathBuf,
}

impl TestDaemon {
	fn spawn(runtime: &TestRuntime) -> Self {
		let socket_path = runtime.path().join("control.sock");
		let previous_socket_inode = fs::symlink_metadata(&socket_path)
			.ok()
			.map(|metadata| metadata.ino());
		let child = spawn_tacod(runtime.path());
		let mut daemon = Self { child, socket_path };
		daemon.wait_until_ready(previous_socket_inode);
		daemon
	}

	fn socket_path(&self) -> &Path {
		&self.socket_path
	}

	fn wait_until_ready(&mut self, previous_socket_inode: Option<u64>) {
		for _ in 0..100 {
			if let Ok(metadata) = fs::symlink_metadata(&self.socket_path)
				&& metadata.file_type().is_socket()
				&& Some(metadata.ino()) != previous_socket_inode
			{
				return;
			}
			if let Some(status) = self.child.try_wait().unwrap() {
				panic!("tacod exited before binding its socket: {status}");
			}
			thread::sleep(Duration::from_millis(10));
		}
		panic!("tacod did not bind its socket within one second");
	}
}

impl Drop for TestDaemon {
	fn drop(&mut self) {
		let _ = self.child.kill();
		let _ = self.child.wait();
	}
}

fn spawn_tacod(runtime_dir: &Path) -> Child {
	Command::new(env!("CARGO_BIN_EXE_tacod"))
		.arg("--runtime-dir")
		.arg(runtime_dir)
		.stdin(Stdio::null())
		.stdout(Stdio::null())
		.stderr(Stdio::null())
		.spawn()
		.unwrap()
}

fn wait_for_exit(child: &mut Child) -> ExitStatus {
	for _ in 0..100 {
		if let Some(status) = child.try_wait().unwrap() {
			return status;
		}
		thread::sleep(Duration::from_millis(10));
	}
	let _ = child.kill();
	let _ = child.wait();
	panic!("second tacod did not reject the occupied runtime within one second");
}
