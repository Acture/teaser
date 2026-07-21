//! Secure filesystem state required to start one `tacod` process.

use std::env;
use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::fs::{self, File, OpenOptions, Permissions, TryLockError};
use std::io;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

use crate::SessionRegistry;
use crate::ipc::{IpcServer, IpcServerError};

const LOCK_FILENAME: &str = "tacod.lock";
const SOCKET_FILENAME: &str = "control.sock";

/// Exclusive ownership of one protected `tacod` runtime directory.
#[derive(Debug)]
pub struct DaemonRuntime {
	server: IpcServer,
	_lock_file: File,
	runtime_dir: PathBuf,
	socket_path: PathBuf,
}

impl DaemonRuntime {
	/// Acquires a runtime directory, its single-instance lock, and socket path.
	///
	/// Existing regular files and symlinks at the socket path are never removed.
	/// A stale Unix socket is removed only after the instance lock is held.
	pub fn acquire(runtime_dir: &Path) -> Result<Self, RuntimeError> {
		ensure_runtime_directory(runtime_dir)?;
		let lock_path = runtime_dir.join(LOCK_FILENAME);
		let lock_file = acquire_lock(&lock_path)?;
		let socket_path = runtime_dir.join(SOCKET_FILENAME);
		remove_stale_socket(&socket_path)?;
		let server = IpcServer::bind(&socket_path)
			.map_err(|error| RuntimeError::io("bind control socket", &socket_path, error))?;

		Ok(Self {
			server,
			_lock_file: lock_file,
			runtime_dir: runtime_dir.to_owned(),
			socket_path,
		})
	}

	/// Returns the standard per-user runtime directory on macOS.
	pub fn default_path() -> Result<PathBuf, RuntimeError> {
		let home = env::var_os("HOME")
			.filter(|value| !value.is_empty())
			.ok_or(RuntimeError::HomeDirectoryUnavailable)?;
		Ok(default_path_from_home(home))
	}

	/// Returns the protected directory held by this runtime.
	#[must_use]
	pub fn path(&self) -> &Path {
		&self.runtime_dir
	}

	/// Returns the socket path reserved for this runtime.
	#[must_use]
	pub fn socket_path(&self) -> &Path {
		&self.socket_path
	}

	/// Accepts and handles one local control connection.
	pub fn serve_next(&self, registry: &mut SessionRegistry) -> Result<(), IpcServerError> {
		self.server.serve_next(registry)
	}
}

fn default_path_from_home(home: OsString) -> PathBuf {
	PathBuf::from(home).join("Library/Application Support/TACO/runtime")
}

fn ensure_runtime_directory(runtime_dir: &Path) -> Result<(), RuntimeError> {
	match fs::symlink_metadata(runtime_dir) {
		Ok(metadata) => validate_directory(runtime_dir, &metadata)?,
		Err(error) if error.kind() == io::ErrorKind::NotFound => {
			fs::create_dir_all(runtime_dir).map_err(|error| {
				RuntimeError::io("create runtime directory", runtime_dir, error)
			})?;
			let metadata = fs::symlink_metadata(runtime_dir).map_err(|error| {
				RuntimeError::io("inspect runtime directory", runtime_dir, error)
			})?;
			validate_directory(runtime_dir, &metadata)?;
		}
		Err(error) => {
			return Err(RuntimeError::io(
				"inspect runtime directory",
				runtime_dir,
				error,
			));
		}
	}

	fs::set_permissions(runtime_dir, Permissions::from_mode(0o700))
		.map_err(|error| RuntimeError::io("secure runtime directory", runtime_dir, error))
}

fn validate_directory(runtime_dir: &Path, metadata: &fs::Metadata) -> Result<(), RuntimeError> {
	if metadata.file_type().is_symlink() || !metadata.is_dir() {
		return Err(RuntimeError::UnsafePath {
			path: runtime_dir.to_owned(),
			expected: "a real directory",
		});
	}
	validate_owner(runtime_dir, metadata)?;
	Ok(())
}

fn acquire_lock(lock_path: &Path) -> Result<File, RuntimeError> {
	match fs::symlink_metadata(lock_path) {
		Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_file() => {
			return Err(RuntimeError::UnsafePath {
				path: lock_path.to_owned(),
				expected: "a regular lock file",
			});
		}
		Ok(_) => {}
		Err(error) if error.kind() == io::ErrorKind::NotFound => {}
		Err(error) => {
			return Err(RuntimeError::io("inspect daemon lock", lock_path, error));
		}
	}

	let lock_file = OpenOptions::new()
		.read(true)
		.write(true)
		.create(true)
		.truncate(false)
		.mode(0o600)
		.open(lock_path)
		.map_err(|error| RuntimeError::io("open daemon lock", lock_path, error))?;
	if !lock_file
		.metadata()
		.map_err(|error| RuntimeError::io("inspect daemon lock", lock_path, error))?
		.is_file()
	{
		return Err(RuntimeError::UnsafePath {
			path: lock_path.to_owned(),
			expected: "a regular lock file",
		});
	}
	let lock_metadata = lock_file
		.metadata()
		.map_err(|error| RuntimeError::io("inspect daemon lock", lock_path, error))?;
	validate_owner(lock_path, &lock_metadata)?;
	lock_file
		.set_permissions(Permissions::from_mode(0o600))
		.map_err(|error| RuntimeError::io("secure daemon lock", lock_path, error))?;

	match lock_file.try_lock() {
		Ok(()) => Ok(lock_file),
		Err(TryLockError::WouldBlock) => Err(RuntimeError::AlreadyRunning {
			lock_path: lock_path.to_owned(),
		}),
		Err(TryLockError::Error(error)) => {
			Err(RuntimeError::io("acquire daemon lock", lock_path, error))
		}
	}
}

fn remove_stale_socket(socket_path: &Path) -> Result<(), RuntimeError> {
	let metadata = match fs::symlink_metadata(socket_path) {
		Ok(metadata) => metadata,
		Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
		Err(error) => {
			return Err(RuntimeError::io(
				"inspect control socket",
				socket_path,
				error,
			));
		}
	};

	if !metadata.file_type().is_socket() {
		return Err(RuntimeError::UnsafePath {
			path: socket_path.to_owned(),
			expected: "an absent or stale Unix socket",
		});
	}
	validate_owner(socket_path, &metadata)?;
	match UnixStream::connect(socket_path) {
		Ok(_) => {
			return Err(RuntimeError::LiveSocketWithoutLock {
				socket_path: socket_path.to_owned(),
			});
		}
		Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {}
		Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
		Err(error) => {
			return Err(RuntimeError::io(
				"probe existing control socket",
				socket_path,
				error,
			));
		}
	}

	fs::remove_file(socket_path)
		.map_err(|error| RuntimeError::io("remove stale control socket", socket_path, error))
}

fn validate_owner(path: &Path, metadata: &fs::Metadata) -> Result<(), RuntimeError> {
	let expected_uid = rustix::process::geteuid().as_raw();
	if metadata.uid() != expected_uid {
		return Err(RuntimeError::WrongOwner {
			path: path.to_owned(),
			expected_uid,
			actual_uid: metadata.uid(),
		});
	}
	Ok(())
}

/// A rejected or failed runtime-directory operation.
#[derive(Debug)]
pub enum RuntimeError {
	/// The default runtime directory cannot be resolved without a home directory.
	HomeDirectoryUnavailable,
	/// Another process currently owns the runtime lock.
	AlreadyRunning { lock_path: PathBuf },
	/// A live socket exists without participating in the runtime lock protocol.
	LiveSocketWithoutLock { socket_path: PathBuf },
	/// A runtime path is not owned by the effective user.
	WrongOwner {
		path: PathBuf,
		expected_uid: u32,
		actual_uid: u32,
	},
	/// A security-sensitive path has an unexpected filesystem type.
	UnsafePath {
		path: PathBuf,
		expected: &'static str,
	},
	/// A filesystem operation failed.
	Io {
		operation: &'static str,
		path: PathBuf,
		source: io::Error,
	},
}

impl RuntimeError {
	fn io(operation: &'static str, path: &Path, source: io::Error) -> Self {
		Self::Io {
			operation,
			path: path.to_owned(),
			source,
		}
	}
}

impl fmt::Display for RuntimeError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::HomeDirectoryUnavailable => {
				formatter.write_str("HOME is unavailable; pass --runtime-dir PATH")
			}
			Self::AlreadyRunning { lock_path } => {
				write!(formatter, "another tacod owns {}", lock_path.display())
			}
			Self::LiveSocketWithoutLock { socket_path } => write!(
				formatter,
				"a live process is listening on {} without the runtime lock",
				socket_path.display(),
			),
			Self::WrongOwner {
				path,
				expected_uid,
				actual_uid,
			} => write!(
				formatter,
				"{} is owned by uid {actual_uid}, expected uid {expected_uid}",
				path.display(),
			),
			Self::UnsafePath { path, expected } => {
				write!(formatter, "{} must be {expected}", path.display())
			}
			Self::Io {
				operation,
				path,
				source,
			} => write!(
				formatter,
				"failed to {operation} {}: {source}",
				path.display()
			),
		}
	}
}

impl Error for RuntimeError {
	fn source(&self) -> Option<&(dyn Error + 'static)> {
		match self {
			Self::Io { source, .. } => Some(source),
			_ => None,
		}
	}
}
