use std::env;
use std::ffi::{OsStr, OsString};
use std::path::PathBuf;
use std::process::ExitCode;

use tacod::SessionRegistry;
use tacod::runtime::DaemonRuntime;

const USAGE: &str = "Usage: tacod [--runtime-dir PATH]";

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
	let runtime_dir = match parse_arguments(env::args_os().skip(1))? {
		Invocation::Help => {
			println!("{USAGE}");
			return Ok(());
		}
		Invocation::Run(Some(runtime_dir)) => runtime_dir,
		Invocation::Run(None) => {
			DaemonRuntime::default_path().map_err(|error| error.to_string())?
		}
	};
	let runtime = DaemonRuntime::acquire(&runtime_dir).map_err(|error| error.to_string())?;
	let registry = SessionRegistry::new();

	eprintln!("tacod: listening on {}", runtime.socket_path().display());
	loop {
		if let Err(error) = runtime.serve_next(&registry) {
			eprintln!("tacod: control request failed: {error}");
		}
	}
}

enum Invocation {
	Help,
	Run(Option<PathBuf>),
}

fn parse_arguments(mut arguments: impl Iterator<Item = OsString>) -> Result<Invocation, String> {
	let Some(flag) = arguments.next() else {
		return Ok(Invocation::Run(None));
	};
	if flag == OsStr::new("--help") || flag == OsStr::new("-h") {
		if arguments.next().is_some() {
			return Err(format!("unexpected arguments after --help; {USAGE}"));
		}
		return Ok(Invocation::Help);
	}
	if flag != OsStr::new("--runtime-dir") {
		return Err(format!(
			"unknown argument {}; {USAGE}",
			flag.to_string_lossy()
		));
	}
	let Some(path) = arguments.next() else {
		return Err(format!("missing runtime directory; {USAGE}"));
	};
	if arguments.next().is_some() {
		return Err(format!("unexpected extra arguments; {USAGE}"));
	}
	if path.is_empty() {
		return Err(format!("runtime directory cannot be empty; {USAGE}"));
	}
	Ok(Invocation::Run(Some(PathBuf::from(path))))
}
