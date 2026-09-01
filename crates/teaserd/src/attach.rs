//! Bounded binary framing for an attached surface connection.

use std::error::Error;
use std::fmt;
use std::io::{self, Read, Write};

/// Maximum bytes carried after a frame header.
pub(crate) const MAX_FRAME_PAYLOAD_BYTES: usize = 65_536;

const HEADER_BYTES: usize = 5;
const INPUT_KIND: u8 = 0x01;
const RESIZE_KIND: u8 = 0x02;
const OUTPUT_KIND: u8 = 0x81;
const REPLAY_GAP_KIND: u8 = 0x82;
const EXIT_KIND: u8 = 0x83;

const RESIZE_PAYLOAD_BYTES: usize = 8;
const OUTPUT_OFFSET_BYTES: usize = 8;
const REPLAY_GAP_PAYLOAD_BYTES: usize = 16;
const EXIT_PAYLOAD_BYTES: usize = 4;

/// A frame sent from an attached surface to `teaserd`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ClientFrame {
	/// Arbitrary bytes to write to the attached session.
	Input(Vec<u8>),
	/// The surface's terminal dimensions.
	Resize {
		rows: u16,
		cols: u16,
		pixel_width: u16,
		pixel_height: u16,
	},
}

/// A frame sent from `teaserd` to an attached surface.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ServerFrame {
	/// Session output beginning at an absolute stream offset.
	Output { offset: u64, bytes: Vec<u8> },
	/// A requested replay offset is no longer retained.
	ReplayGap { requested: u64, available_from: u64 },
	/// The attached session exited with this code.
	Exit { code: u32 },
}

/// A malformed frame or transport failure.
#[derive(Debug)]
pub(crate) enum FrameError {
	Io(io::Error),
	TruncatedHeader {
		received: usize,
	},
	PayloadTooLarge {
		length: usize,
		maximum: usize,
	},
	UnknownKind(u8),
	InvalidPayloadLength {
		kind: u8,
		expected: usize,
		actual: usize,
	},
	TruncatedPayload {
		expected: usize,
		received: usize,
	},
}

impl fmt::Display for FrameError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Io(error) => write!(formatter, "attachment frame I/O failed: {error}"),
			Self::TruncatedHeader { received } => write!(
				formatter,
				"attachment frame header ended after {received} of {HEADER_BYTES} bytes",
			),
			Self::PayloadTooLarge { length, maximum } => write!(
				formatter,
				"attachment frame payload is {length} bytes; maximum is {maximum}",
			),
			Self::UnknownKind(kind) => {
				write!(formatter, "unknown attachment frame kind 0x{kind:02x}")
			}
			Self::InvalidPayloadLength {
				kind,
				expected,
				actual,
			} => write!(
				formatter,
				"attachment frame kind 0x{kind:02x} requires {expected} payload bytes, got {actual}",
			),
			Self::TruncatedPayload { expected, received } => write!(
				formatter,
				"attachment frame payload ended after {received} of {expected} bytes",
			),
		}
	}
}

impl Error for FrameError {
	fn source(&self) -> Option<&(dyn Error + 'static)> {
		match self {
			Self::Io(error) => Some(error),
			_ => None,
		}
	}
}

impl From<io::Error> for FrameError {
	fn from(error: io::Error) -> Self {
		Self::Io(error)
	}
}

/// Reads one client frame, returning `None` only for EOF between frames.
pub(crate) fn read_client_frame<R: Read>(
	reader: &mut R,
) -> Result<Option<ClientFrame>, FrameError> {
	let Some((kind, payload_length)) = read_header(reader)? else {
		return Ok(None);
	};
	validate_payload_bound(payload_length)?;

	match kind {
		INPUT_KIND => {
			let mut payload = vec![0; payload_length];
			read_payload(reader, &mut payload)?;
			Ok(Some(ClientFrame::Input(payload)))
		}
		RESIZE_KIND => {
			if payload_length != RESIZE_PAYLOAD_BYTES {
				return Err(FrameError::InvalidPayloadLength {
					kind,
					expected: RESIZE_PAYLOAD_BYTES,
					actual: payload_length,
				});
			}

			let mut payload = [0; RESIZE_PAYLOAD_BYTES];
			read_payload(reader, &mut payload)?;
			Ok(Some(ClientFrame::Resize {
				rows: u16::from_be_bytes([payload[0], payload[1]]),
				cols: u16::from_be_bytes([payload[2], payload[3]]),
				pixel_width: u16::from_be_bytes([payload[4], payload[5]]),
				pixel_height: u16::from_be_bytes([payload[6], payload[7]]),
			}))
		}
		_ => Err(FrameError::UnknownKind(kind)),
	}
}

/// Writes one server frame without buffering its payload in a second allocation.
pub(crate) fn write_server_frame<W: Write>(
	writer: &mut W,
	frame: &ServerFrame,
) -> Result<(), FrameError> {
	match frame {
		ServerFrame::Output { offset, bytes } => {
			let payload_length = OUTPUT_OFFSET_BYTES.checked_add(bytes.len()).ok_or(
				FrameError::PayloadTooLarge {
					length: usize::MAX,
					maximum: MAX_FRAME_PAYLOAD_BYTES,
				},
			)?;
			write_header(writer, OUTPUT_KIND, payload_length)?;
			writer.write_all(&offset.to_be_bytes())?;
			writer.write_all(bytes)?;
		}
		ServerFrame::ReplayGap {
			requested,
			available_from,
		} => {
			write_header(writer, REPLAY_GAP_KIND, REPLAY_GAP_PAYLOAD_BYTES)?;
			writer.write_all(&requested.to_be_bytes())?;
			writer.write_all(&available_from.to_be_bytes())?;
		}
		ServerFrame::Exit { code } => {
			write_header(writer, EXIT_KIND, EXIT_PAYLOAD_BYTES)?;
			writer.write_all(&code.to_be_bytes())?;
		}
	}
	Ok(())
}

fn read_header<R: Read>(reader: &mut R) -> Result<Option<(u8, usize)>, FrameError> {
	let mut header = [0; HEADER_BYTES];
	let received = read_until_full(reader, &mut header)?;
	if received == 0 {
		return Ok(None);
	}
	if received != HEADER_BYTES {
		return Err(FrameError::TruncatedHeader { received });
	}

	let payload_length = u32::from_be_bytes([header[1], header[2], header[3], header[4]]);
	Ok(Some((header[0], payload_length as usize)))
}

fn write_header<W: Write>(
	writer: &mut W,
	kind: u8,
	payload_length: usize,
) -> Result<(), FrameError> {
	validate_payload_bound(payload_length)?;
	let payload_length =
		u32::try_from(payload_length).map_err(|_| FrameError::PayloadTooLarge {
			length: payload_length,
			maximum: MAX_FRAME_PAYLOAD_BYTES,
		})?;
	let payload_length = payload_length.to_be_bytes();
	writer.write_all(&[
		kind,
		payload_length[0],
		payload_length[1],
		payload_length[2],
		payload_length[3],
	])?;
	Ok(())
}

fn validate_payload_bound(payload_length: usize) -> Result<(), FrameError> {
	if payload_length > MAX_FRAME_PAYLOAD_BYTES {
		return Err(FrameError::PayloadTooLarge {
			length: payload_length,
			maximum: MAX_FRAME_PAYLOAD_BYTES,
		});
	}
	Ok(())
}

fn read_payload<R: Read>(reader: &mut R, payload: &mut [u8]) -> Result<(), FrameError> {
	let received = read_until_full(reader, payload)?;
	if received != payload.len() {
		return Err(FrameError::TruncatedPayload {
			expected: payload.len(),
			received,
		});
	}
	Ok(())
}

fn read_until_full<R: Read>(reader: &mut R, buffer: &mut [u8]) -> Result<usize, io::Error> {
	let mut received = 0;
	while received < buffer.len() {
		match reader.read(&mut buffer[received..]) {
			Ok(0) => break,
			Ok(count) => received += count,
			Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
			Err(error) => return Err(error),
		}
	}
	Ok(received)
}

#[cfg(test)]
mod tests {
	use std::io::{Cursor, Read};

	use super::*;

	#[test]
	fn reads_input_split_across_short_reads() {
		let wire = vec![INPUT_KIND, 0, 0, 0, 4, 0, 0xff, b'a', b'\n'];
		let mut reader = ChunkedReader::new(wire, 1);

		assert_eq!(
			read_client_frame(&mut reader).unwrap(),
			Some(ClientFrame::Input(vec![0, 0xff, b'a', b'\n'])),
		);
		assert_eq!(read_client_frame(&mut reader).unwrap(), None);
	}

	#[test]
	fn reads_resize_fields_in_network_byte_order() {
		let wire = [
			RESIZE_KIND,
			0,
			0,
			0,
			8,
			0,
			24,
			0,
			80,
			0x05,
			0x00,
			0x02,
			0xd0,
		];

		assert_eq!(
			read_client_frame(&mut wire.as_slice()).unwrap(),
			Some(ClientFrame::Resize {
				rows: 24,
				cols: 80,
				pixel_width: 1280,
				pixel_height: 720,
			}),
		);
	}

	#[test]
	fn distinguishes_clean_eof_from_a_truncated_header() {
		assert_eq!(read_client_frame(&mut [].as_slice()).unwrap(), None);

		let error = read_client_frame(&mut [INPUT_KIND, 0, 0].as_slice()).unwrap_err();
		assert!(matches!(error, FrameError::TruncatedHeader { received: 3 }));
	}

	#[test]
	fn reports_a_truncated_payload() {
		let wire = [INPUT_KIND, 0, 0, 0, 3, b'a', b'b'];

		let error = read_client_frame(&mut wire.as_slice()).unwrap_err();
		assert!(matches!(
			error,
			FrameError::TruncatedPayload {
				expected: 3,
				received: 2,
			}
		));
	}

	#[test]
	fn rejects_oversized_payload_before_reading_its_body() {
		let oversized = u32::try_from(MAX_FRAME_PAYLOAD_BYTES + 1).unwrap();
		let mut wire = vec![INPUT_KIND];
		wire.extend_from_slice(&oversized.to_be_bytes());

		let error = read_client_frame(&mut wire.as_slice()).unwrap_err();
		assert!(matches!(
			error,
			FrameError::PayloadTooLarge {
				length,
				maximum: MAX_FRAME_PAYLOAD_BYTES,
			} if length == MAX_FRAME_PAYLOAD_BYTES + 1
		));
	}

	#[test]
	fn rejects_unknown_kinds_and_invalid_fixed_lengths() {
		let unknown = [0x7f, 0, 0, 0, 0];
		assert!(matches!(
			read_client_frame(&mut unknown.as_slice()).unwrap_err(),
			FrameError::UnknownKind(0x7f)
		));

		let invalid_resize = [RESIZE_KIND, 0, 0, 0, 7];
		assert!(matches!(
			read_client_frame(&mut invalid_resize.as_slice()).unwrap_err(),
			FrameError::InvalidPayloadLength {
				kind: RESIZE_KIND,
				expected: RESIZE_PAYLOAD_BYTES,
				actual: 7,
			}
		));
	}

	#[test]
	fn writes_output_as_exact_wire_bytes() {
		let mut wire = Vec::new();
		write_server_frame(
			&mut wire,
			&ServerFrame::Output {
				offset: 0x0102_0304_0506_0708,
				bytes: vec![0, 0xff, b'x'],
			},
		)
		.unwrap();

		assert_eq!(
			wire,
			[
				OUTPUT_KIND,
				0,
				0,
				0,
				11,
				1,
				2,
				3,
				4,
				5,
				6,
				7,
				8,
				0,
				0xff,
				b'x',
			],
		);
	}

	#[test]
	fn writes_replay_gap_and_exit_as_exact_wire_bytes() {
		let mut replay_gap = Vec::new();
		write_server_frame(
			&mut replay_gap,
			&ServerFrame::ReplayGap {
				requested: 1,
				available_from: 9,
			},
		)
		.unwrap();
		assert_eq!(
			replay_gap,
			[
				REPLAY_GAP_KIND,
				0,
				0,
				0,
				16,
				0,
				0,
				0,
				0,
				0,
				0,
				0,
				1,
				0,
				0,
				0,
				0,
				0,
				0,
				0,
				9,
			],
		);

		let mut exit = Vec::new();
		write_server_frame(&mut exit, &ServerFrame::Exit { code: 0x0102_0304 }).unwrap();
		assert_eq!(exit, [EXIT_KIND, 0, 0, 0, 4, 1, 2, 3, 4]);
	}

	#[test]
	fn rejects_oversized_output_before_writing_a_header() {
		let mut wire = Vec::new();
		let frame = ServerFrame::Output {
			offset: 0,
			bytes: vec![0; MAX_FRAME_PAYLOAD_BYTES - OUTPUT_OFFSET_BYTES + 1],
		};

		let error = write_server_frame(&mut wire, &frame).unwrap_err();
		assert!(matches!(
			error,
			FrameError::PayloadTooLarge {
				length: 65_537,
				maximum: MAX_FRAME_PAYLOAD_BYTES,
			}
		));
		assert!(wire.is_empty());
	}

	struct ChunkedReader {
		inner: Cursor<Vec<u8>>,
		chunk_bytes: usize,
	}

	impl ChunkedReader {
		fn new(bytes: Vec<u8>, chunk_bytes: usize) -> Self {
			Self {
				inner: Cursor::new(bytes),
				chunk_bytes,
			}
		}
	}

	impl Read for ChunkedReader {
		fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
			let count = buffer.len().min(self.chunk_bytes);
			self.inner.read(&mut buffer[..count])
		}
	}
}
