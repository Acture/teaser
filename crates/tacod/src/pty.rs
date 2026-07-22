//! PTY-backed process execution owned by `tacod`.
//!
//! A [`PtySession`] serializes input, resize, and termination on one worker
//! thread. A separate reader continuously drains the PTY so a detached UI
//! cannot stall the child on a full kernel buffer. Output is retained in a
//! bounded byte replay buffer and addressed by monotonically increasing
//! offsets.

use std::collections::VecDeque;
use std::error::Error;
use std::ffi::OsString;
use std::fmt;
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use portable_pty::{Child, CommandBuilder, MasterPty, PtySize, native_pty_system};
use rustix::io::Errno;
use rustix::process::{
	Pid, Signal, WaitId, WaitIdOptions, getpgid, getsid, kill_process_group, waitid,
};

const READER_BUFFER_BYTES: usize = 16 * 1024;
const WORKER_POLL_INTERVAL: Duration = Duration::from_millis(20);
const PROCESS_GROUP_TERMINATION_GRACE: Duration = Duration::from_millis(250);

type PtyChild = Box<dyn Child + Send + Sync>;
type PtyMaster = Box<dyn MasterPty + Send>;
type PtyReader = Box<dyn Read + Send>;
type PtyWriter = Box<dyn Write + Send>;
type CommandReply = mpsc::SyncSender<Result<(), PtyError>>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// The initial PTY child's verified process group.
///
/// Interactive shell job control can create other groups in the same session;
/// this checkpoint does not claim that those groups are represented here.
struct PtyProcessGroup(Pid);

impl PtyProcessGroup {
	fn for_spawned_child(process_id: u32) -> Result<Self, PtyError> {
		let raw_process_id =
			i32::try_from(process_id).map_err(|_| PtyError::InvalidProcessId { process_id })?;
		let child_id =
			Pid::from_raw(raw_process_id).ok_or(PtyError::InvalidProcessId { process_id })?;
		let process_group_id = getpgid(Some(child_id)).map_err(|source| {
			Self::operation_error("inspect spawned PTY process group", child_id, source)
		})?;
		if process_group_id != child_id {
			return Err(PtyError::UnexpectedProcessGroup {
				process_id,
				process_group_id: process_group_id.as_raw_pid(),
			});
		}
		let session_id = getsid(Some(child_id)).map_err(|source| {
			Self::operation_error("inspect spawned PTY session", process_group_id, source)
		})?;
		if session_id != child_id {
			return Err(PtyError::UnexpectedSessionLeader {
				process_id,
				session_id: session_id.as_raw_pid(),
			});
		}
		Ok(Self(process_group_id))
	}

	fn signal(self, signal: Signal, operation: &'static str) -> Result<(), PtyError> {
		match kill_process_group(self.0, signal) {
			Ok(()) | Err(Errno::SRCH) => Ok(()),
			Err(Errno::PERM) if cfg!(target_os = "macos") && self.child_has_exited()? => Ok(()),
			Err(source) => Err(Self::operation_error(operation, self.0, source)),
		}
	}

	fn child_has_exited(self) -> Result<bool, PtyError> {
		let options = WaitIdOptions::EXITED | WaitIdOptions::NOHANG | WaitIdOptions::NOWAIT;
		waitid(WaitId::Pid(self.0), options)
			.map(|status| status.is_some())
			.map_err(|source| Self::operation_error("observe PTY process exit", self.0, source))
	}

	fn operation_error(operation: &'static str, process_group_id: Pid, source: Errno) -> PtyError {
		PtyError::ProcessGroup {
			operation,
			process_group_id: process_group_id.as_raw_pid(),
			source: source.into(),
		}
	}
}

/// A validated terminal grid size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TerminalSize {
	rows: u16,
	cols: u16,
	pixel_width: u16,
	pixel_height: u16,
}

impl TerminalSize {
	/// Creates a non-empty terminal grid.
	pub fn new(rows: u16, cols: u16) -> Result<Self, PtyError> {
		Self::with_pixels(rows, cols, 0, 0)
	}

	/// Creates a non-empty terminal grid with its rendered pixel dimensions.
	pub fn with_pixels(
		rows: u16,
		cols: u16,
		pixel_width: u16,
		pixel_height: u16,
	) -> Result<Self, PtyError> {
		let size = Self {
			rows,
			cols,
			pixel_width,
			pixel_height,
		};
		size.validate()?;
		Ok(size)
	}

	fn validate(self) -> Result<(), PtyError> {
		if self.rows == 0 || self.cols == 0 {
			return Err(PtyError::InvalidTerminalSize {
				rows: self.rows,
				cols: self.cols,
			});
		}
		Ok(())
	}

	/// Returns the number of terminal rows.
	#[must_use]
	pub const fn rows(self) -> u16 {
		self.rows
	}

	/// Returns the number of terminal columns.
	#[must_use]
	pub const fn columns(self) -> u16 {
		self.cols
	}

	/// Returns the rendered width reported to the child, in pixels.
	#[must_use]
	pub const fn pixel_width(self) -> u16 {
		self.pixel_width
	}

	/// Returns the rendered height reported to the child, in pixels.
	#[must_use]
	pub const fn pixel_height(self) -> u16 {
		self.pixel_height
	}
}

impl From<TerminalSize> for PtySize {
	fn from(size: TerminalSize) -> Self {
		Self {
			rows: size.rows,
			cols: size.cols,
			pixel_width: size.pixel_width,
			pixel_height: size.pixel_height,
		}
	}
}

/// A program and environment to spawn directly inside a PTY.
///
/// This builder never inserts a shell. Arguments are passed directly to the
/// requested program. The parent environment is inherited unless
/// [`Self::env_clear`] is selected.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtySpawnSpec {
	program: OsString,
	arguments: Vec<OsString>,
	environment: Vec<(OsString, OsString)>,
	clear_environment: bool,
}

impl PtySpawnSpec {
	/// Starts a spawn specification for an exact executable.
	#[must_use]
	pub fn new(program: impl Into<OsString>) -> Self {
		Self {
			program: program.into(),
			arguments: Vec::new(),
			environment: Vec::new(),
			clear_environment: false,
		}
	}

	/// Appends one argument without shell parsing.
	#[must_use]
	pub fn arg(mut self, argument: impl Into<OsString>) -> Self {
		self.arguments.push(argument.into());
		self
	}

	/// Appends arguments without shell parsing.
	#[must_use]
	pub fn args<I, S>(mut self, arguments: I) -> Self
	where
		I: IntoIterator<Item = S>,
		S: Into<OsString>,
	{
		self.arguments.extend(arguments.into_iter().map(Into::into));
		self
	}

	/// Sets or replaces one environment variable.
	#[must_use]
	pub fn env(mut self, name: impl Into<OsString>, value: impl Into<OsString>) -> Self {
		self.environment.push((name.into(), value.into()));
		self
	}

	/// Clears the inherited environment before applying explicit variables.
	#[must_use]
	pub fn env_clear(mut self) -> Self {
		self.clear_environment = true;
		self
	}

	fn into_command(self) -> Result<CommandBuilder, PtyError> {
		if self.program.is_empty() {
			return Err(PtyError::EmptyProgram);
		}
		let mut command = CommandBuilder::new(self.program);
		if self.clear_environment {
			command.env_clear();
		}
		command.args(self.arguments);
		for (name, value) in self.environment {
			command.env(name, value);
		}
		Ok(command)
	}
}

/// An ordered event observed from a PTY output subscription.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PtyOutputEvent {
	/// Bytes beginning at the supplied absolute stream offset.
	Output { offset: u64, bytes: Vec<u8> },
	/// The requested offset was evicted from the bounded replay buffer.
	ReplayGap { requested: u64, available_from: u64 },
	/// The process was reaped and all PTY output reached EOF.
	Exit { code: u32 },
}

/// A cloneable handle to one running or completed PTY process.
#[derive(Clone)]
pub(crate) struct PtySession {
	inner: Arc<PtySessionInner>,
}

impl PtySession {
	/// Spawns `spec` in a PTY and starts its worker and continuous output drain.
	///
	/// `replay_capacity` is measured in bytes. A zero capacity still drains the
	/// PTY but causes every lagging subscriber to observe a replay gap.
	pub(crate) fn spawn(
		spec: PtySpawnSpec,
		size: TerminalSize,
		replay_capacity: usize,
	) -> Result<Self, PtyError> {
		size.validate()?;
		let command = spec.into_command()?;
		let pair = native_pty_system()
			.openpty(size.into())
			.map_err(|error| PtyError::OpenPty(error.to_string()))?;
		let mut child = pair
			.slave
			.spawn_command(command)
			.map_err(|error| PtyError::Spawn(error.to_string()))?;
		drop(pair.slave);

		let process_id = match child.process_id() {
			Some(process_id) => process_id,
			None => {
				reap_after_spawn_failure(&mut child);
				return Err(PtyError::MissingProcessId);
			}
		};
		let process_group = match PtyProcessGroup::for_spawned_child(process_id) {
			Ok(process_group) => process_group,
			Err(error) => {
				reap_after_spawn_failure(&mut child);
				return Err(error);
			}
		};
		let reader = match pair.master.try_clone_reader() {
			Ok(reader) => reader,
			Err(error) => {
				reap_process_group_after_spawn_failure(&mut child, process_group);
				return Err(PtyError::CloneReader(error.to_string()));
			}
		};
		let writer = match pair.master.take_writer() {
			Ok(writer) => writer,
			Err(error) => {
				reap_process_group_after_spawn_failure(&mut child, process_group);
				drop(reader);
				return Err(PtyError::TakeWriter(error.to_string()));
			}
		};

		let output = Arc::new(OutputState::new(replay_capacity));
		let (commands, command_receiver) = mpsc::channel();
		let (reader_done, reader_done_receiver) = mpsc::channel();
		let (bootstrap, bootstrap_receiver) = mpsc::sync_channel(1);

		let worker_thread = match thread::Builder::new()
			.name(format!("tacod-pty-{process_id}-worker"))
			.spawn(move || {
				if let Ok(resources) = bootstrap_receiver.recv() {
					run_worker(resources, command_receiver);
				}
			}) {
			Ok(thread) => thread,
			Err(source) => {
				reap_process_group_after_spawn_failure(&mut child, process_group);
				drop(writer);
				return Err(PtyError::ThreadSpawn {
					role: "PTY worker",
					source,
				});
			}
		};

		let reader_output = Arc::clone(&output);
		let reader_thread = match thread::Builder::new()
			.name(format!("tacod-pty-{process_id}-reader"))
			.spawn(move || drain_output(reader, &reader_output, reader_done))
		{
			Ok(thread) => thread,
			Err(source) => {
				drop(bootstrap);
				reap_process_group_after_spawn_failure(&mut child, process_group);
				drop(writer);
				let _ = worker_thread.join();
				return Err(PtyError::ThreadSpawn {
					role: "PTY reader",
					source,
				});
			}
		};

		let resources = WorkerResources {
			master: Some(pair.master),
			writer: Some(writer),
			child,
			process_group,
			output: Arc::clone(&output),
			reader_done: reader_done_receiver,
			reader_thread: Some(reader_thread),
		};
		if let Err(mpsc::SendError(mut resources)) = bootstrap.send(resources) {
			reap_process_group_after_spawn_failure(&mut resources.child, resources.process_group);
			drop(resources.writer.take());
			drop(resources.master.take());
			if let Some(reader_thread) = resources.reader_thread.take() {
				let _ = reader_thread.join();
			}
			let _ = worker_thread.join();
			return Err(PtyError::WorkerUnavailable);
		}
		drop(worker_thread);

		Ok(Self {
			inner: Arc::new(PtySessionInner {
				process_id,
				commands,
				output,
			}),
		})
	}

	/// Returns the operating-system process identifier of the direct child.
	#[must_use]
	pub(crate) fn process_id(&self) -> u32 {
		self.inner.process_id
	}

	/// Writes raw input bytes to the PTY in command order.
	pub(crate) fn input(&self, bytes: Vec<u8>) -> Result<(), PtyError> {
		if bytes.is_empty() {
			return Ok(());
		}
		self.request(|reply| WorkerCommand::Input { bytes, reply })
	}

	/// Updates the PTY grid and causes the kernel to notify its foreground job.
	pub(crate) fn resize(&self, size: TerminalSize) -> Result<(), PtyError> {
		size.validate()?;
		self.request(|reply| WorkerCommand::Resize { size, reply })
	}

	/// Subscribes at an absolute byte offset in the output stream.
	pub(crate) fn subscribe(&self, next_offset: u64) -> Result<PtyOutputCursor, PtyError> {
		let (_, live_offset) = self.replay_bounds();
		if next_offset > live_offset {
			return Err(PtyError::InvalidOutputOffset {
				requested: next_offset,
				live_offset,
			});
		}
		Ok(PtyOutputCursor {
			output: Arc::clone(&self.inner.output),
			next_offset,
			failure_delivered: false,
			exit_delivered: false,
		})
	}

	/// Returns the oldest retained offset and the next live output offset.
	#[must_use]
	pub(crate) fn replay_bounds(&self) -> (u64, u64) {
		self.inner.output.replay_bounds()
	}

	/// Terminates the verified owning process group, reaps the direct child,
	/// then waits for PTY output EOF.
	///
	/// The worker deliberately waits before dropping the writer because
	/// `portable-pty` writes the terminal EOF character from its Unix writer's
	/// destructor. Job-control processes moved to another PGID are outside this
	/// checkpoint's termination guarantee.
	pub(crate) fn terminate(&self) -> Result<(), PtyError> {
		if self.inner.output.exit_code().is_some() {
			return Ok(());
		}
		match self.request(|reply| WorkerCommand::Terminate { reply: Some(reply) }) {
			Err(PtyError::ProcessExited { .. }) => Ok(()),
			result => result,
		}
	}

	/// Clears an attachment flag while holding the cursor's condition mutex.
	///
	/// This ordering prevents detach from notifying between a cursor's final
	/// flag check and its atomic condition-variable wait.
	pub(crate) fn deactivate_reader(&self, active: &AtomicBool) -> bool {
		self.inner.output.deactivate_reader(active)
	}

	fn request(&self, command: impl FnOnce(CommandReply) -> WorkerCommand) -> Result<(), PtyError> {
		let (reply, response) = mpsc::sync_channel(1);
		if self.inner.commands.send(command(reply)).is_err() {
			return match self.inner.output.exit_code() {
				Some(code) => Err(PtyError::ProcessExited { code }),
				None => Err(PtyError::WorkerUnavailable),
			};
		}
		response.recv().map_err(|_| PtyError::WorkerUnavailable)?
	}
}

impl fmt::Debug for PtySession {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		formatter
			.debug_struct("PtySession")
			.field("process_id", &self.process_id())
			.finish_non_exhaustive()
	}
}

struct PtySessionInner {
	process_id: u32,
	commands: mpsc::Sender<WorkerCommand>,
	output: Arc<OutputState>,
}

impl Drop for PtySessionInner {
	fn drop(&mut self) {
		let _ = self.commands.send(WorkerCommand::Terminate { reply: None });
		self.output.wake_readers();
	}
}

/// A blocking cursor over one session's ordered output events.
pub(crate) struct PtyOutputCursor {
	output: Arc<OutputState>,
	next_offset: u64,
	failure_delivered: bool,
	exit_delivered: bool,
}

impl PtyOutputCursor {
	/// Waits for the next output event, terminal exit, or lease release.
	///
	/// The caller must clear `active` through
	/// [`PtySession::deactivate_reader`] to interrupt a cursor that is blocked
	/// without pending output.
	pub(crate) fn next_event(
		&mut self,
		active: &AtomicBool,
	) -> Result<Option<PtyOutputEvent>, PtyError> {
		loop {
			if !active.load(Ordering::Acquire) {
				return Ok(None);
			}

			let mut replay = lock_unpoisoned(&self.output.replay);
			if self.next_offset < replay.available_from() {
				let requested = self.next_offset;
				let available_from = replay.available_from();
				self.next_offset = available_from;
				return Ok(Some(PtyOutputEvent::ReplayGap {
					requested,
					available_from,
				}));
			}
			if self.next_offset < replay.next_offset {
				let offset = self.next_offset;
				let bytes = replay.bytes_from(offset);
				self.next_offset = replay.next_offset;
				return Ok(Some(PtyOutputEvent::Output { offset, bytes }));
			}
			if !self.failure_delivered
				&& let Some(failure) = replay.failure.as_ref()
			{
				self.failure_delivered = true;
				return Err(PtyError::Background {
					operation: failure.operation,
					message: failure.message.clone(),
				});
			}
			if !self.exit_delivered
				&& let Some(code) = replay.exit_code
			{
				self.exit_delivered = true;
				return Ok(Some(PtyOutputEvent::Exit { code }));
			}
			if !active.load(Ordering::Acquire) {
				return Ok(None);
			}
			replay = wait_unpoisoned(&self.output.changed, replay);
			drop(replay);
		}
	}
}

impl fmt::Debug for PtyOutputCursor {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		formatter
			.debug_struct("PtyOutputCursor")
			.field("next_offset", &self.next_offset)
			.field("exit_delivered", &self.exit_delivered)
			.finish_non_exhaustive()
	}
}

#[derive(Debug)]
enum WorkerCommand {
	Input {
		bytes: Vec<u8>,
		reply: CommandReply,
	},
	Resize {
		size: TerminalSize,
		reply: CommandReply,
	},
	Terminate {
		reply: Option<CommandReply>,
	},
}

struct WorkerResources {
	master: Option<PtyMaster>,
	writer: Option<PtyWriter>,
	child: PtyChild,
	process_group: PtyProcessGroup,
	output: Arc<OutputState>,
	reader_done: mpsc::Receiver<ReaderCompletion>,
	reader_thread: Option<JoinHandle<()>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReaderCompletion {
	Eof,
	Failed,
}

fn run_worker(mut resources: WorkerResources, commands: mpsc::Receiver<WorkerCommand>) {
	let mut exit_code = None;
	let mut reader_completion = None;
	let mut pending_terminations: Vec<CommandReply> = Vec::new();
	let mut commands_open = true;
	let mut automatic_termination_attempted = false;
	let mut reader_failure_handled = false;

	loop {
		if reader_completion.is_none() {
			match resources.reader_done.try_recv() {
				Ok(completion) => reader_completion = Some(completion),
				Err(mpsc::TryRecvError::Empty) => {}
				Err(mpsc::TryRecvError::Disconnected) => {
					resources.output.record_failure(
						"receive PTY reader completion",
						"PTY reader stopped without reporting EOF",
					);
					reader_completion = Some(ReaderCompletion::Failed);
				}
			}
		}

		if exit_code.is_none() {
			match resources.process_group.child_has_exited() {
				Ok(true) => match terminate_child(&mut resources.child, resources.process_group) {
					Ok(code) => exit_code = Some(code),
					Err(error) => resources
						.output
						.record_failure("reap exited PTY process group", error.to_string()),
				},
				Ok(false) => {}
				Err(error) => resources
					.output
					.record_failure("observe PTY child exit", error.to_string()),
			}
		}

		if reader_completion == Some(ReaderCompletion::Failed)
			&& exit_code.is_none()
			&& !reader_failure_handled
		{
			match terminate_child(&mut resources.child, resources.process_group) {
				Ok(code) => {
					reader_failure_handled = true;
					exit_code = Some(code);
				}
				Err(error) => resources.output.record_failure(
					"terminate child after PTY reader failure",
					error.to_string(),
				),
			}
		}

		if exit_code.is_some() {
			// Both natural and explicit exits are reaped before the writer drops.
			drop(resources.writer.take());
			drop(resources.master.take());
		}

		if let (Some(code), Some(_)) = (exit_code, reader_completion) {
			if let Some(reader_thread) = resources.reader_thread.take()
				&& reader_thread.join().is_err()
			{
				resources
					.output
					.record_failure("join PTY reader", "PTY reader thread panicked");
			}
			resources.output.publish_exit(code);
			for reply in pending_terminations {
				let _ = reply.send(Ok(()));
			}
			return;
		}

		if commands_open {
			match commands.recv_timeout(WORKER_POLL_INTERVAL) {
				Ok(command) => handle_command(
					command,
					&mut resources,
					&mut exit_code,
					&mut pending_terminations,
				),
				Err(mpsc::RecvTimeoutError::Timeout) => {}
				Err(mpsc::RecvTimeoutError::Disconnected) => commands_open = false,
			}
		} else {
			if exit_code.is_none() && !automatic_termination_attempted {
				match terminate_child(&mut resources.child, resources.process_group) {
					Ok(code) => {
						automatic_termination_attempted = true;
						exit_code = Some(code);
					}
					Err(error) => resources
						.output
						.record_failure("terminate unowned PTY child", error.to_string()),
				}
			}
			thread::sleep(WORKER_POLL_INTERVAL);
		}
	}
}

fn handle_command(
	command: WorkerCommand,
	resources: &mut WorkerResources,
	exit_code: &mut Option<u32>,
	pending_terminations: &mut Vec<CommandReply>,
) {
	match command {
		WorkerCommand::Input { bytes, reply } => {
			let result = match *exit_code {
				Some(code) => Err(PtyError::ProcessExited { code }),
				None => resources
					.writer
					.as_mut()
					.expect("running PTY worker must own its writer")
					.write_all(&bytes)
					.map_err(|source| PtyError::Input { source }),
			};
			let _ = reply.send(result);
		}
		WorkerCommand::Resize { size, reply } => {
			let result = match *exit_code {
				Some(code) => Err(PtyError::ProcessExited { code }),
				None => resources
					.master
					.as_ref()
					.expect("running PTY worker must own its master")
					.resize(size.into())
					.map_err(|error| PtyError::Resize(error.to_string())),
			};
			let _ = reply.send(result);
		}
		WorkerCommand::Terminate { reply } => {
			if exit_code.is_some() {
				if let Some(reply) = reply {
					pending_terminations.push(reply);
				}
				return;
			}

			match terminate_child(&mut resources.child, resources.process_group) {
				Ok(code) => {
					*exit_code = Some(code);
					if let Some(reply) = reply {
						pending_terminations.push(reply);
					}
				}
				Err(error) => {
					if let Some(reply) = reply {
						let _ = reply.send(Err(error));
					} else {
						resources
							.output
							.record_failure("terminate PTY child", error.to_string());
					}
				}
			}
		}
	}
}

fn terminate_child(child: &mut PtyChild, process_group: PtyProcessGroup) -> Result<u32, PtyError> {
	if !process_group.child_has_exited()? {
		process_group.signal(Signal::TERM, "send SIGTERM to PTY process group")?;
		thread::sleep(PROCESS_GROUP_TERMINATION_GRACE);
	}
	// Keep the direct child unreaped while signalling so its PID cannot be
	// reused as an unrelated process-group ID before KILL.
	process_group.signal(Signal::KILL, "send SIGKILL to PTY process group")?;
	child
		.wait()
		.map(|status| status.exit_code())
		.map_err(|source| PtyError::Wait { source })
}

fn reap_after_spawn_failure(child: &mut PtyChild) {
	let _ = child.kill();
	let _ = child.wait();
}

fn reap_process_group_after_spawn_failure(child: &mut PtyChild, process_group: PtyProcessGroup) {
	let _ = process_group.signal(Signal::KILL, "send SIGKILL to failed PTY process group");
	let _ = child.wait();
}

fn drain_output(
	mut reader: PtyReader,
	output: &OutputState,
	completion: mpsc::Sender<ReaderCompletion>,
) {
	let mut buffer = [0_u8; READER_BUFFER_BYTES];
	loop {
		match reader.read(&mut buffer) {
			Ok(0) => {
				let _ = completion.send(ReaderCompletion::Eof);
				return;
			}
			Ok(read) => {
				if output.append(&buffer[..read]).is_err() {
					output.record_failure(
						"advance PTY output offset",
						"PTY output offset exceeded u64::MAX",
					);
					let _ = completion.send(ReaderCompletion::Failed);
					return;
				}
			}
			Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
			Err(error) => {
				output.record_failure("read PTY output", error.to_string());
				let _ = completion.send(ReaderCompletion::Failed);
				return;
			}
		}
	}
}

struct OutputState {
	replay: Mutex<ReplayBuffer>,
	changed: Condvar,
}

impl OutputState {
	fn new(capacity: usize) -> Self {
		Self {
			replay: Mutex::new(ReplayBuffer::new(capacity)),
			changed: Condvar::new(),
		}
	}

	fn append(&self, bytes: &[u8]) -> Result<(), ()> {
		let mut replay = lock_unpoisoned(&self.replay);
		replay.append(bytes)?;
		drop(replay);
		self.changed.notify_all();
		Ok(())
	}

	fn record_failure(&self, operation: &'static str, message: impl Into<String>) {
		let mut replay = lock_unpoisoned(&self.replay);
		if replay.failure.is_none() {
			replay.failure = Some(BackgroundFailure {
				operation,
				message: message.into(),
			});
		}
		drop(replay);
		self.changed.notify_all();
	}

	fn publish_exit(&self, code: u32) {
		let mut replay = lock_unpoisoned(&self.replay);
		replay.exit_code.get_or_insert(code);
		drop(replay);
		self.changed.notify_all();
	}

	fn exit_code(&self) -> Option<u32> {
		lock_unpoisoned(&self.replay).exit_code
	}

	fn replay_bounds(&self) -> (u64, u64) {
		let replay = lock_unpoisoned(&self.replay);
		(replay.available_from(), replay.next_offset)
	}

	fn deactivate_reader(&self, active: &AtomicBool) -> bool {
		let replay = lock_unpoisoned(&self.replay);
		let was_active = active.swap(false, Ordering::AcqRel);
		drop(replay);
		self.changed.notify_all();
		was_active
	}

	fn wake_readers(&self) {
		self.changed.notify_all();
	}
}

struct ReplayBuffer {
	bytes: VecDeque<u8>,
	next_offset: u64,
	capacity: usize,
	failure: Option<BackgroundFailure>,
	exit_code: Option<u32>,
}

impl ReplayBuffer {
	fn new(capacity: usize) -> Self {
		Self {
			bytes: VecDeque::new(),
			next_offset: 0,
			capacity,
			failure: None,
			exit_code: None,
		}
	}

	fn append(&mut self, bytes: &[u8]) -> Result<(), ()> {
		let byte_count = u64::try_from(bytes.len()).map_err(|_| ())?;
		self.next_offset = self.next_offset.checked_add(byte_count).ok_or(())?;
		if self.capacity == 0 {
			self.bytes.clear();
			return Ok(());
		}

		if bytes.len() >= self.capacity {
			self.bytes.clear();
			self.bytes
				.extend(bytes[bytes.len() - self.capacity..].iter().copied());
			return Ok(());
		}

		self.bytes.extend(bytes.iter().copied());
		let excess = self.bytes.len().saturating_sub(self.capacity);
		self.bytes.drain(..excess);
		Ok(())
	}

	fn available_from(&self) -> u64 {
		let retained = u64::try_from(self.bytes.len())
			.expect("a usize byte count must fit in u64 on supported platforms");
		self.next_offset - retained
	}

	fn bytes_from(&self, offset: u64) -> Vec<u8> {
		let index = usize::try_from(offset - self.available_from())
			.expect("a replay-buffer index must fit in usize");
		self.bytes.range(index..).copied().collect()
	}
}

#[derive(Debug, Clone)]
struct BackgroundFailure {
	operation: &'static str,
	message: String,
}

fn lock_unpoisoned<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
	mutex
		.lock()
		.unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn wait_unpoisoned<'a, T>(
	condition: &Condvar,
	guard: std::sync::MutexGuard<'a, T>,
) -> std::sync::MutexGuard<'a, T> {
	condition
		.wait(guard)
		.unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// A synchronous or background PTY lifecycle failure.
#[derive(Debug)]
pub enum PtyError {
	/// A terminal cannot have zero rows or columns.
	InvalidTerminalSize { rows: u16, cols: u16 },
	/// No executable was supplied.
	EmptyProgram,
	/// The operating system could not create the PTY pair.
	OpenPty(String),
	/// The program could not be spawned inside the PTY.
	Spawn(String),
	/// The platform implementation did not expose a child process identifier.
	MissingProcessId,
	/// The platform returned a process identifier outside the supported range.
	InvalidProcessId { process_id: u32 },
	/// The PTY child was not the leader of its owning process group.
	UnexpectedProcessGroup {
		process_id: u32,
		process_group_id: i32,
	},
	/// The PTY child was not the leader of its owning process session.
	UnexpectedSessionLeader { process_id: u32, session_id: i32 },
	/// Inspecting or signalling the verified PTY process group failed.
	ProcessGroup {
		operation: &'static str,
		process_group_id: i32,
		source: io::Error,
	},
	/// The master-side output reader could not be cloned.
	CloneReader(String),
	/// The single master-side input writer could not be acquired.
	TakeWriter(String),
	/// A required background thread could not be created.
	ThreadSpawn {
		role: &'static str,
		source: io::Error,
	},
	/// The serialized worker stopped before answering a command.
	WorkerUnavailable,
	/// The process exited before a control operation was applied.
	ProcessExited { code: u32 },
	/// A subscription requested output beyond the live stream offset.
	InvalidOutputOffset { requested: u64, live_offset: u64 },
	/// Writing input to the PTY failed.
	Input { source: io::Error },
	/// Applying a terminal resize failed.
	Resize(String),
	/// Polling or waiting for the child failed.
	Wait { source: io::Error },
	/// A background reader or lifecycle operation failed.
	Background {
		operation: &'static str,
		message: String,
	},
}

impl fmt::Display for PtyError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::InvalidTerminalSize { rows, cols } => {
				write!(formatter, "invalid terminal size {cols}x{rows}")
			}
			Self::EmptyProgram => formatter.write_str("PTY program must not be empty"),
			Self::OpenPty(message) => write!(formatter, "failed to open PTY: {message}"),
			Self::Spawn(message) => {
				write!(formatter, "failed to spawn program in PTY: {message}")
			}
			Self::MissingProcessId => {
				formatter.write_str("spawned PTY process has no process identifier")
			}
			Self::InvalidProcessId { process_id } => {
				write!(
					formatter,
					"invalid spawned PTY process identifier {process_id}"
				)
			}
			Self::UnexpectedProcessGroup {
				process_id,
				process_group_id,
			} => write!(
				formatter,
				"PTY process {process_id} unexpectedly belongs to process group {process_group_id}",
			),
			Self::UnexpectedSessionLeader {
				process_id,
				session_id,
			} => write!(
				formatter,
				"PTY process {process_id} unexpectedly belongs to process session {session_id}",
			),
			Self::ProcessGroup {
				operation,
				process_group_id,
				source,
			} => write!(
				formatter,
				"failed to {operation} {process_group_id}: {source}",
			),
			Self::CloneReader(message) => {
				write!(formatter, "failed to clone PTY output reader: {message}")
			}
			Self::TakeWriter(message) => {
				write!(formatter, "failed to take PTY input writer: {message}")
			}
			Self::ThreadSpawn { role, source } => {
				write!(formatter, "failed to start {role} thread: {source}")
			}
			Self::WorkerUnavailable => formatter.write_str("PTY worker is unavailable"),
			Self::ProcessExited { code } => {
				write!(formatter, "PTY process already exited with code {code}")
			}
			Self::InvalidOutputOffset {
				requested,
				live_offset,
			} => write!(
				formatter,
				"PTY output offset {requested} is beyond live offset {live_offset}",
			),
			Self::Input { source } => write!(formatter, "failed to write PTY input: {source}"),
			Self::Resize(message) => write!(formatter, "failed to resize PTY: {message}"),
			Self::Wait { source } => write!(formatter, "failed to wait for PTY process: {source}"),
			Self::Background { operation, message } => {
				write!(formatter, "failed to {operation}: {message}")
			}
		}
	}
}

impl Error for PtyError {
	fn source(&self) -> Option<&(dyn Error + 'static)> {
		match self {
			Self::ThreadSpawn { source, .. }
			| Self::ProcessGroup { source, .. }
			| Self::Input { source }
			| Self::Wait { source } => Some(source),
			_ => None,
		}
	}
}
