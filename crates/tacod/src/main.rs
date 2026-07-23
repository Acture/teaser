use std::env;
use std::ffi::{OsStr, OsString};
use std::io::{self, Write};
use std::path::PathBuf;
use std::process::ExitCode;

use serde::Serialize;
use taco_core::SessionId;
use tacod::SessionRegistry;
use tacod::runtime::DaemonRuntime;

mod probe;

const USAGE: &str = "Usage: tacod [--runtime-dir PATH] [--probe-session]";

fn main() -> ExitCode {
	match run() {
		Ok(()) => ExitCode::SUCCESS,
		Err(message) => {
			eprintln!("tacod: {message}");
			ExitCode::FAILURE
		}
	}
}

fn run() -> Result<(), String> {
	let invocation = parse_arguments(env::args_os().skip(1))?;
	let (runtime_dir, probe_session) = match invocation {
		Invocation::Help => {
			println!("{USAGE}");
			return Ok(());
		}
		Invocation::ProbeChild => return probe::run_child().map_err(|error| error.to_string()),
		Invocation::Run {
			runtime_dir,
			probe_session,
		} => {
			let runtime_dir = match runtime_dir {
				Some(runtime_dir) => runtime_dir,
				None => DaemonRuntime::default_path().map_err(|error| error.to_string())?,
			};
			(runtime_dir, probe_session)
		}
	};
	let runtime = DaemonRuntime::acquire(&runtime_dir).map_err(|error| error.to_string())?;
	let registry = SessionRegistry::new();
	if probe_session {
		// Keep portable-pty process setup ahead of every IPC accept thread.
		let probe = probe::spawn_session(&registry).map_err(|error| error.to_string())?;
		write_probe_startup(&runtime, probe.session_id(), probe.process_id())?;
	}

	eprintln!("tacod: listening on {}", runtime.socket_path().display());
	loop {
		if let Err(error) = runtime.serve_next(&registry) {
			eprintln!("tacod: control request failed: {error}");
		}
	}
}

#[derive(Debug, PartialEq, Eq)]
enum Invocation {
	Help,
	ProbeChild,
	Run {
		runtime_dir: Option<PathBuf>,
		probe_session: bool,
	},
}

fn parse_arguments(arguments: impl Iterator<Item = OsString>) -> Result<Invocation, String> {
	let arguments = arguments.collect::<Vec<_>>();
	if arguments.is_empty() {
		return Ok(Invocation::Run {
			runtime_dir: None,
			probe_session: false,
		});
	}
	if arguments.len() == 1 && arguments[0] == OsStr::new("--probe-child") {
		return Ok(Invocation::ProbeChild);
	}
	if arguments
		.iter()
		.any(|argument| argument == OsStr::new("--probe-child"))
	{
		return Err(format!(
			"--probe-child does not accept other arguments; {USAGE}"
		));
	}
	if arguments
		.iter()
		.any(|argument| argument == OsStr::new("--help") || argument == OsStr::new("-h"))
	{
		if arguments.len() != 1 {
			return Err(format!("unexpected arguments with --help; {USAGE}"));
		}
		return Ok(Invocation::Help);
	}

	let mut runtime_dir = None;
	let mut probe_session = false;
	let mut index = 0;
	while index < arguments.len() {
		let flag = &arguments[index];
		if flag == OsStr::new("--runtime-dir") {
			if runtime_dir.is_some() {
				return Err(format!("--runtime-dir may be specified only once; {USAGE}"));
			}
			index += 1;
			let Some(path) = arguments.get(index) else {
				return Err(format!("missing runtime directory; {USAGE}"));
			};
			if path.is_empty() {
				return Err(format!("runtime directory cannot be empty; {USAGE}"));
			}
			if path.to_string_lossy().starts_with("--") {
				return Err(format!("missing runtime directory; {USAGE}"));
			}
			runtime_dir = Some(PathBuf::from(path));
		} else if flag == OsStr::new("--probe-session") {
			if probe_session {
				return Err(format!(
					"--probe-session may be specified only once; {USAGE}"
				));
			}
			probe_session = true;
		} else {
			return Err(format!(
				"unknown argument {}; {USAGE}",
				flag.to_string_lossy()
			));
		}
		index += 1;
	}
	if probe_session && runtime_dir.is_none() {
		return Err(format!(
			"--probe-session requires an explicit --runtime-dir; {USAGE}"
		));
	}
	Ok(Invocation::Run {
		runtime_dir,
		probe_session,
	})
}

#[derive(Serialize)]
struct ProbeStartup<'a> {
	socket_path: &'a str,
	session_id: String,
	process_id: u32,
}

fn write_probe_startup(
	runtime: &DaemonRuntime,
	session_id: SessionId,
	process_id: u32,
) -> Result<(), String> {
	let socket_path = runtime
		.socket_path()
		.to_str()
		.ok_or_else(|| "probe socket path must be valid UTF-8".to_owned())?;
	let startup = ProbeStartup {
		socket_path,
		session_id: session_id.to_string(),
		process_id,
	};
	let stdout = io::stdout();
	let mut stdout = stdout.lock();
	serde_json::to_writer(&mut stdout, &startup)
		.map_err(|error| format!("failed to serialize probe startup: {error}"))?;
	stdout
		.write_all(b"\n")
		.and_then(|()| stdout.flush())
		.map_err(|error| format!("failed to publish probe startup: {error}"))
}

#[cfg(test)]
mod tests {
	use super::*;

	fn args(values: &[&str]) -> impl Iterator<Item = OsString> {
		values
			.iter()
			.map(|value| OsString::from(*value))
			.collect::<Vec<_>>()
			.into_iter()
	}

	#[test]
	fn parses_probe_session_with_runtime_directory_in_either_order() {
		let expected = Invocation::Run {
			runtime_dir: Some(PathBuf::from("/tmp/taco-probe")),
			probe_session: true,
		};
		assert_eq!(
			parse_arguments(args(&[
				"--runtime-dir",
				"/tmp/taco-probe",
				"--probe-session"
			]))
			.unwrap(),
			expected,
		);
		assert_eq!(
			parse_arguments(args(&[
				"--probe-session",
				"--runtime-dir",
				"/tmp/taco-probe"
			]))
			.unwrap(),
			expected,
		);
	}

	#[test]
	fn probe_child_is_private_and_rejects_other_arguments() {
		assert_eq!(
			parse_arguments(args(&["--probe-child"])).unwrap(),
			Invocation::ProbeChild,
		);
		assert!(
			parse_arguments(args(&["--probe-child", "--probe-session"]))
				.unwrap_err()
				.contains("does not accept other arguments")
		);
	}

	#[test]
	fn rejects_duplicate_and_missing_probe_arguments() {
		assert!(
			parse_arguments(args(&["--probe-session", "--probe-session"]))
				.unwrap_err()
				.contains("only once")
		);
		assert!(
			parse_arguments(args(&["--runtime-dir", "--probe-session"]))
				.unwrap_err()
				.contains("missing runtime directory")
		);
		assert!(
			parse_arguments(args(&["--probe-session"]))
				.unwrap_err()
				.contains("requires an explicit --runtime-dir")
		);
	}
}
