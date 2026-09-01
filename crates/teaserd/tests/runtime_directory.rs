use std::fs::{self, Permissions};
use std::os::unix::fs::{FileTypeExt, PermissionsExt, symlink};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use teaserd::runtime::{DaemonRuntime, RuntimeError};

static NEXT_FIXTURE_ID: AtomicU64 = AtomicU64::new(1);

#[test]
fn acquire_creates_private_runtime_lock_and_socket() {
	let fixture = RuntimeFixture::new();
	let runtime = DaemonRuntime::acquire(fixture.runtime_path()).unwrap();

	assert_eq!(runtime.path(), fixture.runtime_path());
	assert_eq!(permissions(runtime.path()), 0o700);
	assert_eq!(permissions(&runtime.path().join("teaserd.lock")), 0o600);
	assert_eq!(permissions(runtime.socket_path()), 0o600);
}

#[test]
fn second_owner_is_rejected_without_replacing_the_live_socket() {
	let fixture = RuntimeFixture::new();
	let first = DaemonRuntime::acquire(fixture.runtime_path()).unwrap();
	let socket_metadata = fs::symlink_metadata(first.socket_path()).unwrap();

	let error = DaemonRuntime::acquire(fixture.runtime_path()).unwrap_err();
	let current_metadata = fs::symlink_metadata(first.socket_path()).unwrap();

	assert!(matches!(error, RuntimeError::AlreadyRunning { .. }));
	assert_eq!(
		std::os::unix::fs::MetadataExt::ino(&socket_metadata),
		std::os::unix::fs::MetadataExt::ino(&current_metadata),
	);
}

#[test]
fn stale_socket_is_replaced_after_the_lock_is_acquired() {
	let fixture = RuntimeFixture::new();
	fixture.create_runtime_dir();
	let stale_listener = UnixListener::bind(fixture.socket_path()).unwrap();
	let stale_inode =
		std::os::unix::fs::MetadataExt::ino(&fs::symlink_metadata(fixture.socket_path()).unwrap());
	drop(stale_listener);

	let runtime = DaemonRuntime::acquire(fixture.runtime_path()).unwrap();
	let current_inode =
		std::os::unix::fs::MetadataExt::ino(&fs::symlink_metadata(runtime.socket_path()).unwrap());

	assert_ne!(stale_inode, current_inode);
}

#[test]
fn regular_file_at_socket_path_is_preserved() {
	let fixture = RuntimeFixture::new();
	fixture.create_runtime_dir();
	fs::write(fixture.socket_path(), b"do not delete").unwrap();

	let error = DaemonRuntime::acquire(fixture.runtime_path()).unwrap_err();

	assert!(matches!(error, RuntimeError::UnsafePath { .. }));
	assert_eq!(fs::read(fixture.socket_path()).unwrap(), b"do not delete");
}

#[test]
fn symlink_at_socket_path_is_preserved() {
	let fixture = RuntimeFixture::new();
	fixture.create_runtime_dir();
	let target_path = fixture.base_path().join("target");
	fs::write(&target_path, b"target").unwrap();
	symlink(&target_path, fixture.socket_path()).unwrap();

	let error = DaemonRuntime::acquire(fixture.runtime_path()).unwrap_err();

	assert!(matches!(error, RuntimeError::UnsafePath { .. }));
	assert!(
		fs::symlink_metadata(fixture.socket_path())
			.unwrap()
			.file_type()
			.is_symlink()
	);
	assert_eq!(fs::read(target_path).unwrap(), b"target");
}

#[test]
fn live_socket_without_lock_is_preserved() {
	let fixture = RuntimeFixture::new();
	fixture.create_runtime_dir();
	let listener = UnixListener::bind(fixture.socket_path()).unwrap();

	let error = DaemonRuntime::acquire(fixture.runtime_path()).unwrap_err();

	assert!(matches!(error, RuntimeError::LiveSocketWithoutLock { .. }));
	assert!(
		fs::symlink_metadata(fixture.socket_path())
			.unwrap()
			.file_type()
			.is_socket()
	);
	drop(listener);
}

#[test]
fn runtime_directory_symlink_is_rejected() {
	let fixture = RuntimeFixture::new();
	let target_path = fixture.base_path().join("target-runtime");
	fs::create_dir_all(&target_path).unwrap();
	symlink(&target_path, fixture.runtime_path()).unwrap();

	let error = DaemonRuntime::acquire(fixture.runtime_path()).unwrap_err();

	assert!(matches!(error, RuntimeError::UnsafePath { .. }));
	assert!(target_path.is_dir());
}

#[test]
fn drop_does_not_delete_a_replacement_at_the_socket_path() {
	let fixture = RuntimeFixture::new();
	let runtime = DaemonRuntime::acquire(fixture.runtime_path()).unwrap();
	fs::remove_file(runtime.socket_path()).unwrap();
	fs::write(runtime.socket_path(), b"replacement").unwrap();

	drop(runtime);

	assert_eq!(fs::read(fixture.socket_path()).unwrap(), b"replacement");
}

fn permissions(path: &Path) -> u32 {
	fs::symlink_metadata(path).unwrap().permissions().mode() & 0o777
}

struct RuntimeFixture {
	base_path: PathBuf,
	runtime_path: PathBuf,
	socket_path: PathBuf,
}

impl RuntimeFixture {
	fn new() -> Self {
		let fixture_id = NEXT_FIXTURE_ID.fetch_add(1, Ordering::Relaxed);
		let base_path = PathBuf::from(format!(
			"/tmp/teaserd-runtime-test-{}-{fixture_id}",
			std::process::id(),
		));
		let runtime_path = base_path.join("runtime");
		let socket_path = runtime_path.join("control.sock");
		Self {
			base_path,
			runtime_path,
			socket_path,
		}
	}

	fn create_runtime_dir(&self) {
		fs::create_dir_all(&self.runtime_path).unwrap();
		fs::set_permissions(&self.runtime_path, Permissions::from_mode(0o700)).unwrap();
	}

	fn base_path(&self) -> &Path {
		&self.base_path
	}

	fn runtime_path(&self) -> &Path {
		&self.runtime_path
	}

	fn socket_path(&self) -> &Path {
		&self.socket_path
	}
}

impl Drop for RuntimeFixture {
	fn drop(&mut self) {
		let _ = fs::remove_dir_all(&self.base_path);
	}
}
