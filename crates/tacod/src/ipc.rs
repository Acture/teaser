//! Versioned local control protocol for `tacod`.

use std::error::Error;
use std::fmt;
use std::fs;
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use taco_core::{CheckoutId, SessionId, SurfaceId};

use crate::attach::{
	ClientFrame, FrameError as AttachmentFrameError, MAX_FRAME_PAYLOAD_BYTES, ServerFrame,
	read_client_frame, write_server_frame,
};
use crate::pty::{PtyError, PtyOutputEvent, TerminalSize};
use crate::{PtyAttachment, PtyAttachmentError, SessionRegistry, SessionRegistryError};

/// The protocol version understood by this build of `tacod`.
pub const PROTOCOL_VERSION: u32 = 1;

/// Maximum JSON payload size, excluding the terminating newline.
pub const MAX_REQUEST_BYTES: usize = 16 * 1024;

const CONNECTION_TIMEOUT: Duration = Duration::from_secs(5);
const ATTACH_UPGRADE: &str = "taco.attach.v1";

/// A Unix-domain-socket server for `tacod` control and attachment requests.
///
/// Each accepted connection gets an independent handler thread. A request
/// starts as one bounded newline-terminated JSON envelope. `session.attach`
/// upgrades that same socket to a bounded binary stream after its JSON reply.
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

	/// Accepts one connection and delegates it without blocking later accepts.
	pub(crate) fn serve_next(&self, registry: &SessionRegistry) -> Result<(), IpcServerError> {
		let (stream, _) = self.listener.accept()?;
		stream.set_read_timeout(Some(CONNECTION_TIMEOUT))?;
		stream.set_write_timeout(Some(CONNECTION_TIMEOUT))?;
		let registry = registry.clone();
		thread::Builder::new()
			.name("tacod-ipc".to_owned())
			.spawn(move || {
				if let Err(error) = handle_connection(stream, &registry) {
					eprintln!("tacod: connection failed: {error}");
				}
			})
			.map_err(IpcServerError::Io)?;
		Ok(())
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
	session_id: Option<String>,
	surface_id: Option<u64>,
	next_offset: Option<u64>,
}

#[derive(Debug, Deserialize)]
enum RequestMethod {
	#[serde(rename = "session.create")]
	CreateSession,
	#[serde(rename = "session.attach")]
	AttachSession,
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
	Ok {
		#[serde(flatten)]
		result: SuccessResult,
	},
	Error {
		error: ProtocolError,
	},
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
enum SuccessResult {
	SessionCreated {
		session_id: String,
	},
	SessionAttached {
		session_id: String,
		upgrade: &'static str,
		replay_from: u64,
		live_offset: u64,
		max_frame_payload_bytes: usize,
	},
}

#[derive(Debug, Serialize)]
struct ProtocolError {
	code: &'static str,
	message: String,
}

fn handle_connection(
	mut stream: UnixStream,
	registry: &SessionRegistry,
) -> Result<(), IpcServerError> {
	let frame = match read_json_frame(&mut stream) {
		Ok(frame) => frame,
		Err(JsonFrameError::Io(error)) => return Err(error.into()),
		Err(JsonFrameError::TooLarge) => {
			return write_response(
				&mut stream,
				ResponseEnvelope::error(
					None,
					"request_too_large",
					format!("request exceeds {MAX_REQUEST_BYTES} bytes"),
				),
			);
		}
		Err(JsonFrameError::MissingNewline) => {
			return write_response(
				&mut stream,
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
				&mut stream,
				ResponseEnvelope::error(
					None,
					"invalid_request",
					"request must match the versioned JSON protocol".to_owned(),
				),
			);
		}
	};

	if request.version != PROTOCOL_VERSION {
		return write_response(
			&mut stream,
			ResponseEnvelope::error(
				Some(request.request_id),
				"unsupported_version",
				format!(
					"protocol version {} is unsupported; expected {PROTOCOL_VERSION}",
					request.version,
				),
			),
		);
	}

	match request.method {
		RequestMethod::CreateSession => handle_create(&mut stream, request, registry),
		RequestMethod::AttachSession => handle_attach(stream, request, registry),
		RequestMethod::Unknown => write_response(
			&mut stream,
			ResponseEnvelope::error(
				Some(request.request_id),
				"unknown_method",
				"unknown control method".to_owned(),
			),
		),
	}
}

fn handle_create(
	stream: &mut UnixStream,
	request: RequestEnvelope,
	registry: &SessionRegistry,
) -> Result<(), IpcServerError> {
	let Some(checkout_id) = request.checkout_id else {
		return write_response(
			stream,
			ResponseEnvelope::error(
				Some(request.request_id),
				"invalid_parameters",
				"session.create requires checkout_id".to_owned(),
			),
		);
	};
	if request.session_id.is_some() || request.surface_id.is_some() || request.next_offset.is_some()
	{
		return write_response(
			stream,
			ResponseEnvelope::error(
				Some(request.request_id),
				"invalid_parameters",
				"session.create accepts only checkout_id".to_owned(),
			),
		);
	}

	let session_id = registry.create_session(CheckoutId::new(checkout_id));
	write_response(
		stream,
		ResponseEnvelope::session_created(request.request_id, session_id),
	)
}

fn handle_attach(
	mut stream: UnixStream,
	request: RequestEnvelope,
	registry: &SessionRegistry,
) -> Result<(), IpcServerError> {
	if request.checkout_id.is_some() {
		return write_response(
			&mut stream,
			ResponseEnvelope::error(
				Some(request.request_id),
				"invalid_parameters",
				"session.attach does not accept checkout_id".to_owned(),
			),
		);
	}
	let Some(session_id) = request.session_id.as_deref() else {
		return write_response(
			&mut stream,
			ResponseEnvelope::error(
				Some(request.request_id),
				"invalid_parameters",
				"session.attach requires session_id".to_owned(),
			),
		);
	};
	let Ok(session_id) = session_id.parse::<SessionId>() else {
		return write_response(
			&mut stream,
			ResponseEnvelope::error(
				Some(request.request_id),
				"invalid_parameters",
				"session_id must be an opaque UUID".to_owned(),
			),
		);
	};
	let Some(surface_id) = request.surface_id else {
		return write_response(
			&mut stream,
			ResponseEnvelope::error(
				Some(request.request_id),
				"invalid_parameters",
				"session.attach requires surface_id".to_owned(),
			),
		);
	};
	let Some(next_offset) = request.next_offset else {
		return write_response(
			&mut stream,
			ResponseEnvelope::error(
				Some(request.request_id),
				"invalid_parameters",
				"session.attach requires next_offset".to_owned(),
			),
		);
	};

	let attachment = match registry.attach_pty(session_id, SurfaceId::new(surface_id), next_offset)
	{
		Ok(attachment) => attachment,
		Err(error) => {
			let (code, message) = attachment_protocol_error(error);
			return write_response(
				&mut stream,
				ResponseEnvelope::error(Some(request.request_id), code, message),
			);
		}
	};

	let response = ResponseEnvelope::session_attached(
		request.request_id,
		session_id,
		next_offset.max(attachment.replay_start()),
		attachment.live_offset(),
	);
	write_response(&mut stream, response)?;
	stream.set_read_timeout(None)?;
	serve_attachment(stream, attachment)
}

fn attachment_protocol_error(error: PtyAttachmentError) -> (&'static str, String) {
	let code = match &error {
		PtyAttachmentError::Registry(SessionRegistryError::SessionNotFound(_)) => {
			"session_not_found"
		}
		PtyAttachmentError::Registry(SessionRegistryError::SessionAlreadyAttached { .. }) => {
			"session_already_attached"
		}
		PtyAttachmentError::Registry(SessionRegistryError::SurfaceAlreadyAttached { .. }) => {
			"surface_already_attached"
		}
		PtyAttachmentError::Registry(SessionRegistryError::AttachmentGenerationExhausted) => {
			"attachment_unavailable"
		}
		PtyAttachmentError::SessionNotRunning(_) => "session_not_running",
		PtyAttachmentError::Pty(_) => "invalid_offset",
	};
	(code, error.to_string())
}

fn serve_attachment(
	mut stream: UnixStream,
	mut attachment: PtyAttachment,
) -> Result<(), IpcServerError> {
	let mut input_stream = stream.try_clone()?;
	let control = attachment.control();
	let input_thread = thread::Builder::new()
		.name("tacod-pty-input".to_owned())
		.spawn(move || {
			while let Ok(Some(frame)) = read_client_frame(&mut input_stream) {
				let result = match frame {
					ClientFrame::Input(bytes) => control.input(bytes),
					ClientFrame::Resize {
						rows,
						cols,
						pixel_width,
						pixel_height,
					} => TerminalSize::with_pixels(rows, cols, pixel_width, pixel_height)
						.and_then(|size| control.resize(size)),
				};
				if result.is_err() {
					break;
				}
			}
		})
		.map_err(IpcServerError::Io)?;

	let output_result = stream_attachment_output(&mut stream, &mut attachment);
	attachment.detach();
	let _ = stream.shutdown(Shutdown::Both);
	let _ = input_thread.join();
	output_result
}

fn stream_attachment_output(
	stream: &mut UnixStream,
	attachment: &mut PtyAttachment,
) -> Result<(), IpcServerError> {
	while let Some(event) = attachment.next_event()? {
		let (frame, exited) = match event {
			PtyOutputEvent::Output { offset, bytes } => {
				write_output_frames(stream, offset, &bytes)?;
				continue;
			}
			PtyOutputEvent::ReplayGap {
				requested,
				available_from,
			} => (
				ServerFrame::ReplayGap {
					requested,
					available_from,
				},
				false,
			),
			PtyOutputEvent::Exit { code } => (ServerFrame::Exit { code }, true),
		};
		write_server_frame(stream, &frame)?;
		if exited {
			break;
		}
	}
	Ok(())
}

fn write_output_frames(
	stream: &mut UnixStream,
	mut offset: u64,
	bytes: &[u8],
) -> Result<(), IpcServerError> {
	const OFFSET_BYTES: usize = size_of::<u64>();
	const MAX_OUTPUT_BYTES: usize = MAX_FRAME_PAYLOAD_BYTES - OFFSET_BYTES;

	for chunk in bytes.chunks(MAX_OUTPUT_BYTES) {
		write_server_frame(
			stream,
			&ServerFrame::Output {
				offset,
				bytes: chunk.to_vec(),
			},
		)?;
		offset = offset
			.checked_add(u64::try_from(chunk.len()).expect("frame length must fit in u64"))
			.ok_or_else(|| io::Error::other("PTY output offset exceeded u64::MAX"))?;
	}
	Ok(())
}

fn read_json_frame(stream: &mut UnixStream) -> Result<Vec<u8>, JsonFrameError> {
	let mut frame = Vec::new();
	loop {
		let mut byte = [0];
		match stream.read(&mut byte) {
			Ok(0) => return Err(JsonFrameError::MissingNewline),
			Ok(_) if byte[0] == b'\n' => break,
			Ok(_) => frame.push(byte[0]),
			Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
			Err(error) => return Err(JsonFrameError::Io(error)),
		}
		if frame.len() > MAX_REQUEST_BYTES {
			return Err(JsonFrameError::TooLarge);
		}
	}

	if frame.last() == Some(&b'\r') {
		frame.pop();
	}
	Ok(frame)
}

fn write_response(
	stream: &mut UnixStream,
	response: ResponseEnvelope,
) -> Result<(), IpcServerError> {
	serde_json::to_writer(&mut *stream, &response)?;
	stream.write_all(b"\n")?;
	stream.flush()?;
	Ok(())
}

impl ResponseEnvelope {
	fn session_created(request_id: u64, session_id: SessionId) -> Self {
		Self {
			version: PROTOCOL_VERSION,
			request_id: Some(request_id),
			outcome: ResponseOutcome::Ok {
				result: SuccessResult::SessionCreated {
					session_id: session_id.to_string(),
				},
			},
		}
	}

	fn session_attached(
		request_id: u64,
		session_id: SessionId,
		replay_from: u64,
		live_offset: u64,
	) -> Self {
		Self {
			version: PROTOCOL_VERSION,
			request_id: Some(request_id),
			outcome: ResponseOutcome::Ok {
				result: SuccessResult::SessionAttached {
					session_id: session_id.to_string(),
					upgrade: ATTACH_UPGRADE,
					replay_from,
					live_offset,
					max_frame_payload_bytes: MAX_FRAME_PAYLOAD_BYTES,
				},
			},
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
enum JsonFrameError {
	Io(io::Error),
	TooLarge,
	MissingNewline,
}

/// A transport, PTY, frame, or serialization failure while serving a connection.
#[derive(Debug)]
pub enum IpcServerError {
	Io(io::Error),
	Json(serde_json::Error),
	AttachmentFrame(String),
	Pty(String),
}

impl fmt::Display for IpcServerError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Io(error) => write!(formatter, "IPC I/O failed: {error}"),
			Self::Json(error) => write!(formatter, "IPC JSON serialization failed: {error}"),
			Self::AttachmentFrame(message) | Self::Pty(message) => formatter.write_str(message),
		}
	}
}

impl Error for IpcServerError {
	fn source(&self) -> Option<&(dyn Error + 'static)> {
		match self {
			Self::Io(error) => Some(error),
			Self::Json(error) => Some(error),
			Self::AttachmentFrame(_) | Self::Pty(_) => None,
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

impl From<AttachmentFrameError> for IpcServerError {
	fn from(error: AttachmentFrameError) -> Self {
		Self::AttachmentFrame(error.to_string())
	}
}

impl From<PtyError> for IpcServerError {
	fn from(error: PtyError) -> Self {
		Self::Pty(error.to_string())
	}
}
