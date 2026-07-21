//! Versioned local control protocol for `tacod`.

use std::error::Error;
use std::fmt;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use taco_core::CheckoutId;

use crate::SessionRegistry;

/// The protocol version understood by this build of `tacod`.
pub const PROTOCOL_VERSION: u32 = 1;

/// Maximum JSON payload size, excluding the terminating newline.
pub const MAX_REQUEST_BYTES: usize = 16 * 1024;

const CONNECTION_TIMEOUT: Duration = Duration::from_secs(5);

/// A Unix-domain-socket server for low-frequency `tacod` control requests.
///
/// Each connection carries exactly one newline-terminated JSON request and one
/// newline-terminated JSON response. The connection then closes.
#[derive(Debug)]
pub(crate) struct IpcServer {
	listener: UnixListener,
	socket_path: PathBuf,
	socket_device: u64,
	socket_inode: u64,
}

impl IpcServer {
	/// Binds a socket without replacing an existing filesystem entry.
	pub(crate) fn bind(socket_path: &Path) -> io::Result<Self> {
		let listener = UnixListener::bind(socket_path)?;
		let metadata = fs::symlink_metadata(socket_path)?;
		let mut permissions = metadata.permissions();
		permissions.set_mode(0o600);
		if let Err(error) = fs::set_permissions(socket_path, permissions) {
			drop(listener);
			remove_matching_socket(socket_path, metadata.dev(), metadata.ino());
			return Err(error);
		}
		Ok(Self {
			listener,
			socket_path: socket_path.to_owned(),
			socket_device: metadata.dev(),
			socket_inode: metadata.ino(),
		})
	}

	/// Accepts and handles one connection.
	pub(crate) fn serve_next(&self, registry: &mut SessionRegistry) -> Result<(), IpcServerError> {
		let (mut stream, _) = self.listener.accept()?;
		stream.set_read_timeout(Some(CONNECTION_TIMEOUT))?;
		stream.set_write_timeout(Some(CONNECTION_TIMEOUT))?;
		handle_connection(&mut stream, registry)
	}
}

impl Drop for IpcServer {
	fn drop(&mut self) {
		remove_matching_socket(&self.socket_path, self.socket_device, self.socket_inode);
	}
}

fn remove_matching_socket(socket_path: &Path, expected_device: u64, expected_inode: u64) {
	let Ok(metadata) = fs::symlink_metadata(socket_path) else {
		return;
	};
	if metadata.file_type().is_socket()
		&& metadata.dev() == expected_device
		&& metadata.ino() == expected_inode
	{
		let _ = fs::remove_file(socket_path);
	}
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RequestEnvelope {
	version: u32,
	request_id: u64,
	method: RequestMethod,
	checkout_id: Option<u64>,
}

#[derive(Debug, Deserialize)]
enum RequestMethod {
	#[serde(rename = "session.create")]
	CreateSession,
	#[serde(other)]
	Unknown,
}

#[derive(Debug, Serialize)]
struct ResponseEnvelope {
	version: u32,
	request_id: Option<u64>,
	#[serde(flatten)]
	outcome: ResponseOutcome,
}

#[derive(Debug, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
enum ResponseOutcome {
	Ok { session_id: String },
	Error { error: ProtocolError },
}

#[derive(Debug, Serialize)]
struct ProtocolError {
	code: &'static str,
	message: String,
}

fn handle_connection(
	stream: &mut UnixStream,
	registry: &mut SessionRegistry,
) -> Result<(), IpcServerError> {
	let frame = match read_frame(stream) {
		Ok(frame) => frame,
		Err(FrameError::Io(error)) => return Err(error.into()),
		Err(FrameError::TooLarge) => {
			return write_response(
				stream,
				ResponseEnvelope::error(
					None,
					"request_too_large",
					format!("request exceeds {MAX_REQUEST_BYTES} bytes"),
				),
			);
		}
		Err(FrameError::MissingNewline) => {
			return write_response(
				stream,
				ResponseEnvelope::error(
					None,
					"invalid_frame",
					"request must end with a newline".to_owned(),
				),
			);
		}
	};

	let request = match serde_json::from_slice::<RequestEnvelope>(&frame) {
		Ok(request) => request,
		Err(_) => {
			return write_response(
				stream,
				ResponseEnvelope::error(
					None,
					"invalid_request",
					"request must match the versioned JSON protocol".to_owned(),
				),
			);
		}
	};

	let response = dispatch(request, registry);
	write_response(stream, response)
}

fn dispatch(request: RequestEnvelope, registry: &mut SessionRegistry) -> ResponseEnvelope {
	if request.version != PROTOCOL_VERSION {
		return ResponseEnvelope::error(
			Some(request.request_id),
			"unsupported_version",
			format!(
				"protocol version {} is unsupported; expected {PROTOCOL_VERSION}",
				request.version,
			),
		);
	}

	match request.method {
		RequestMethod::CreateSession => {
			let Some(checkout_id) = request.checkout_id else {
				return ResponseEnvelope::error(
					Some(request.request_id),
					"invalid_parameters",
					"session.create requires checkout_id".to_owned(),
				);
			};

			let session_id = registry.create_session(CheckoutId::new(checkout_id));
			ResponseEnvelope::success(request.request_id, session_id.to_string())
		}
		RequestMethod::Unknown => ResponseEnvelope::error(
			Some(request.request_id),
			"unknown_method",
			"unknown control method".to_owned(),
		),
	}
}

fn read_frame(stream: &mut UnixStream) -> Result<Vec<u8>, FrameError> {
	let reader = BufReader::new(stream);
	let mut limited = reader.take((MAX_REQUEST_BYTES + 2) as u64);
	let mut frame = Vec::new();
	limited.read_until(b'\n', &mut frame)?;

	if frame.len() > MAX_REQUEST_BYTES + 1 {
		return Err(FrameError::TooLarge);
	}
	if frame.last() != Some(&b'\n') {
		return Err(FrameError::MissingNewline);
	}

	frame.pop();
	if frame.last() == Some(&b'\r') {
		frame.pop();
	}
	if frame.len() > MAX_REQUEST_BYTES {
		return Err(FrameError::TooLarge);
	}
	Ok(frame)
}

fn write_response(
	stream: &mut UnixStream,
	response: ResponseEnvelope,
) -> Result<(), IpcServerError> {
	serde_json::to_writer(&mut *stream, &response)?;
	stream.write_all(b"\n")?;
	Ok(())
}

impl ResponseEnvelope {
	fn success(request_id: u64, session_id: String) -> Self {
		Self {
			version: PROTOCOL_VERSION,
			request_id: Some(request_id),
			outcome: ResponseOutcome::Ok { session_id },
		}
	}

	fn error(request_id: Option<u64>, code: &'static str, message: String) -> Self {
		Self {
			version: PROTOCOL_VERSION,
			request_id,
			outcome: ResponseOutcome::Error {
				error: ProtocolError { code, message },
			},
		}
	}
}

#[derive(Debug)]
enum FrameError {
	Io(io::Error),
	TooLarge,
	MissingNewline,
}

impl From<io::Error> for FrameError {
	fn from(error: io::Error) -> Self {
		Self::Io(error)
	}
}

/// A transport or serialization failure while serving a connection.
#[derive(Debug)]
pub enum IpcServerError {
	Io(io::Error),
	Json(serde_json::Error),
}

impl fmt::Display for IpcServerError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Io(error) => write!(formatter, "IPC I/O failed: {error}"),
			Self::Json(error) => write!(formatter, "IPC JSON serialization failed: {error}"),
		}
	}
}

impl Error for IpcServerError {
	fn source(&self) -> Option<&(dyn Error + 'static)> {
		match self {
			Self::Io(error) => Some(error),
			Self::Json(error) => Some(error),
		}
	}
}

impl From<io::Error> for IpcServerError {
	fn from(error: io::Error) -> Self {
		Self::Io(error)
	}
}

impl From<serde_json::Error> for IpcServerError {
	fn from(error: serde_json::Error) -> Self {
		Self::Json(error)
	}
}
