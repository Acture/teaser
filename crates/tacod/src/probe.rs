use std::env;
use std::error::Error;
use std::fmt;
use std::io::{self, BufRead, Write};
use std::process;
use std::thread;
use std::time::Duration;

use rustix::termios::{LocalModes, OptionalActions, Termios, tcgetattr, tcgetwinsize, tcsetattr};
use taco_core::{CheckoutId, SessionId};
use tacod::{PtyError, PtySpawnSpec, SessionRegistry, TerminalSize};

const PROBE_CHECKOUT_ID: u64 = 0;
const PROBE_ROWS: u16 = 24;
const PROBE_COLUMNS: u16 = 80;
const PROBE_REPLAY_CAPACITY_BYTES: usize = 64 * 1024;
const OFFLINE_DELAY: Duration = Duration::from_millis(200);

pub(crate) struct ProbeSession {
	session_id: SessionId,
	process_id: u32,
}

impl ProbeSession {
	pub(crate) const fn session_id(&self) -> SessionId {
		self.session_id
	}

	pub(crate) const fn process_id(&self) -> u32 {
		self.process_id
	}
}

pub(crate) fn spawn_session(registry: &SessionRegistry) -> Result<ProbeSession, ProbeError> {
	let executable = env::current_exe().map_err(ProbeError::CurrentExecutable)?;
	let spawn_spec = PtySpawnSpec::new(executable)
		.arg("--probe-child")
		.env_clear()
		.env("LC_ALL", "C");
	let terminal_size = TerminalSize::new(PROBE_ROWS, PROBE_COLUMNS)?;
	let session_id = registry.create_pty_session(
		CheckoutId::new(PROBE_CHECKOUT_ID),
		spawn_spec,
		terminal_size,
		PROBE_REPLAY_CAPACITY_BYTES,
	)?;
	let process_id = registry
		.session_process_id(session_id)
		.ok_or(ProbeError::MissingProcessId)?;
	Ok(ProbeSession {
		session_id,
		process_id,
	})
}

pub(crate) fn run_child() -> Result<(), ProbeError> {
	let stdin = io::stdin();
	let _echo_guard = disable_input_echo(&stdin)?;
	let stdout = io::stdout();
	let mut stdout = stdout.lock();
	let process_id = process::id();
	write_response(&mut stdout, format_args!("READY {process_id}"))?;

	for line in stdin.lock().lines() {
		let line = line.map_err(ProbeError::Input)?;
		match line.trim_end_matches('\r') {
			"PING" => write_response(&mut stdout, format_args!("PONG {process_id}"))?,
			"ARM" => {
				thread::sleep(OFFLINE_DELAY);
				write_response(&mut stdout, format_args!("OFFLINE {process_id}"))?;
			}
			"SIZE" => {
				let size = tcgetwinsize(&stdin).map_err(ProbeError::Terminal)?;
				write_response(
					&mut stdout,
					format_args!("SIZE {} {}", size.ws_row, size.ws_col),
				)?;
			}
			"EXIT" => {
				write_response(&mut stdout, format_args!("EXIT {process_id}"))?;
				return Ok(());
			}
			_ => write_response(&mut stdout, format_args!("UNKNOWN {process_id}"))?,
		}
	}
	Ok(())
}

fn disable_input_echo(stdin: &io::Stdin) -> Result<InputEchoGuard<'_>, ProbeError> {
	let mut settings = tcgetattr(stdin).map_err(ProbeError::Terminal)?;
	let original = settings.clone();
	settings
		.local_modes
		.remove(LocalModes::ECHO | LocalModes::ECHONL);
	tcsetattr(stdin, OptionalActions::Now, &settings).map_err(ProbeError::Terminal)?;
	Ok(InputEchoGuard { stdin, original })
}

struct InputEchoGuard<'a> {
	stdin: &'a io::Stdin,
	original: Termios,
}

impl Drop for InputEchoGuard<'_> {
	fn drop(&mut self) {
		let _ = tcsetattr(self.stdin, OptionalActions::Now, &self.original);
	}
}

fn write_response(
	writer: &mut impl Write,
	arguments: fmt::Arguments<'_>,
) -> Result<(), ProbeError> {
	writeln!(writer, "{arguments}")
		.and_then(|()| writer.flush())
		.map_err(ProbeError::Output)
}

#[derive(Debug)]
pub(crate) enum ProbeError {
	CurrentExecutable(io::Error),
	Input(io::Error),
	Output(io::Error),
	Terminal(rustix::io::Errno),
	Pty(PtyError),
	MissingProcessId,
}

impl fmt::Display for ProbeError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::CurrentExecutable(error) => {
				write!(
					formatter,
					"failed to resolve the fixed probe executable: {error}"
				)
			}
			Self::Input(error) => write!(formatter, "failed to read probe input: {error}"),
			Self::Output(error) => write!(formatter, "failed to write probe output: {error}"),
			Self::Terminal(error) => write!(formatter, "probe terminal operation failed: {error}"),
			Self::Pty(error) => write!(formatter, "failed to create probe PTY: {error}"),
			Self::MissingProcessId => formatter.write_str("probe PTY has no process ID"),
		}
	}
}

impl Error for ProbeError {
	fn source(&self) -> Option<&(dyn Error + 'static)> {
		match self {
			Self::CurrentExecutable(error) | Self::Input(error) | Self::Output(error) => {
				Some(error)
			}
			Self::Terminal(error) => Some(error),
			Self::Pty(error) => Some(error),
			Self::MissingProcessId => None,
		}
	}
}

impl From<PtyError> for ProbeError {
	fn from(error: PtyError) -> Self {
		Self::Pty(error)
	}
}
