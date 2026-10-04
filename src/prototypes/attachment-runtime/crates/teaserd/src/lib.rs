//! Runtime ownership for Teaser sessions.

pub mod ipc;
pub mod runtime;

mod attach;
mod pty;

pub use pty::{PtyError, PtySpawnSpec, TerminalSize};

use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::error::Error;
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, Weak};

use pty::{PtyOutputCursor, PtyOutputEvent, PtySession};
use teaser_core::{CheckoutId, SessionId, SurfaceId};

/// A Teaser-owned session maintained independently of its attached surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Session {
	id: SessionId,
	checkout_id: CheckoutId,
	attached_surface_id: Option<SurfaceId>,
}

impl Session {
	/// Returns the session identity.
	#[must_use]
	pub const fn id(&self) -> SessionId {
		self.id
	}

	/// Returns the checkout in which this session operates.
	#[must_use]
	pub const fn checkout_id(&self) -> CheckoutId {
		self.checkout_id
	}

	/// Returns the currently attached surface, if any.
	#[must_use]
	pub const fn attached_surface_id(&self) -> Option<SurfaceId> {
		self.attached_surface_id
	}
}

/// Thread-safe owner of Teaser sessions and their exact surface attachments.
///
/// Registry locks are private and are never held while reading a socket or a
/// PTY. An attachment is a generation-checked lease: dropping it releases the
/// surface without destroying the child process.
#[derive(Debug, Clone)]
pub struct SessionRegistry {
	inner: Arc<Mutex<RegistryState>>,
}

#[derive(Debug)]
struct RegistryState {
	sessions: HashMap<SessionId, SessionRecord>,
	surface_attachments: HashMap<SurfaceId, SessionId>,
	next_attachment_generation: u64,
}

#[derive(Debug)]
struct SessionRecord {
	snapshot: Session,
	pty: Option<PtySession>,
	attachment_generation: Option<u64>,
}

impl SessionRegistry {
	/// Creates an empty registry.
	#[must_use]
	pub fn new() -> Self {
		Self {
			inner: Arc::new(Mutex::new(RegistryState {
				sessions: HashMap::new(),
				surface_attachments: HashMap::new(),
				next_attachment_generation: 1,
			})),
		}
	}

	/// Creates a detached metadata-only session for an exact checkout.
	///
	/// The Checkout catalog will eventually resolve the child program and
	/// working directory. Until then, the public `session.create` request does
	/// not guess either value and therefore does not spawn a process.
	pub fn create_session(&self, checkout_id: CheckoutId) -> SessionId {
		self.insert_session(checkout_id, None)
	}

	/// Creates a detached PTY-backed session from an already-resolved command.
	///
	/// This is an internal composition seam, not part of the local JSON
	/// protocol. It lets the Checkout resolver remain out of this checkpoint.
	pub fn create_pty_session(
		&self,
		checkout_id: CheckoutId,
		spawn_spec: PtySpawnSpec,
		size: TerminalSize,
		replay_capacity: usize,
	) -> Result<SessionId, PtyError> {
		let pty = PtySession::spawn(spawn_spec, size, replay_capacity)?;
		Ok(self.insert_session(checkout_id, Some(pty)))
	}

	fn insert_session(&self, checkout_id: CheckoutId, pty: Option<PtySession>) -> SessionId {
		let mut state = self.lock();
		loop {
			let session_id = SessionId::generate();
			if let Entry::Vacant(entry) = state.sessions.entry(session_id) {
				entry.insert(SessionRecord {
					snapshot: Session {
						id: session_id,
						checkout_id,
						attached_surface_id: None,
					},
					pty,
					attachment_generation: None,
				});
				return session_id;
			}
		}
	}

	/// Returns a copy of one session without exposing locked registry state.
	#[must_use]
	pub fn session(&self, session_id: SessionId) -> Option<Session> {
		self.lock()
			.sessions
			.get(&session_id)
			.map(|record| record.snapshot)
	}

	/// Claims one exact session for one surface.
	///
	/// Every live claim is exclusive, including a second connection that
	/// repeats the same surface identity. The returned lease releases the claim
	/// on drop; it does not terminate the session.
	pub fn attach(
		&self,
		session_id: SessionId,
		surface_id: SurfaceId,
	) -> Result<AttachmentLease, SessionRegistryError> {
		let mut state = self.lock();

		let record = state
			.sessions
			.get(&session_id)
			.ok_or(SessionRegistryError::SessionNotFound(session_id))?;
		if let Some(attached_surface_id) = record.snapshot.attached_surface_id {
			return Err(SessionRegistryError::SessionAlreadyAttached {
				session_id,
				attached_surface_id,
			});
		}
		if let Some(attached_session_id) = state.surface_attachments.get(&surface_id) {
			return Err(SessionRegistryError::SurfaceAlreadyAttached {
				surface_id,
				attached_session_id: *attached_session_id,
			});
		}

		let generation = state.next_attachment_generation;
		state.next_attachment_generation = state
			.next_attachment_generation
			.checked_add(1)
			.ok_or(SessionRegistryError::AttachmentGenerationExhausted)?;
		let record = state
			.sessions
			.get_mut(&session_id)
			.ok_or(SessionRegistryError::SessionNotFound(session_id))?;
		record.snapshot.attached_surface_id = Some(surface_id);
		record.attachment_generation = Some(generation);
		state.surface_attachments.insert(surface_id, session_id);

		Ok(AttachmentLease {
			inner: Arc::new(AttachmentLeaseInner {
				registry: Arc::downgrade(&self.inner),
				session_id,
				surface_id,
				generation,
				active: AtomicBool::new(true),
			}),
		})
	}

	pub(crate) fn attach_pty(
		&self,
		session_id: SessionId,
		surface_id: SurfaceId,
		next_offset: u64,
	) -> Result<PtyAttachment, PtyAttachmentError> {
		let lease = self.attach(session_id, surface_id)?;
		let pty = self
			.lock()
			.sessions
			.get(&session_id)
			.and_then(|record| record.pty.clone())
			.ok_or(PtyAttachmentError::SessionNotRunning(session_id))?;
		let cursor = pty.subscribe(next_offset)?;
		let (replay_start, live_offset) = pty.replay_bounds();

		Ok(PtyAttachment {
			lease,
			pty,
			cursor,
			replay_start,
			live_offset,
		})
	}

	/// Returns the retained and live byte offsets for a PTY-backed session.
	#[must_use]
	pub fn replay_bounds(&self, session_id: SessionId) -> Option<(u64, u64)> {
		self.lock()
			.sessions
			.get(&session_id)
			.and_then(|record| record.pty.as_ref())
			.map(PtySession::replay_bounds)
	}

	/// Returns the direct child process ID for a PTY-backed session.
	#[must_use]
	pub fn session_process_id(&self, session_id: SessionId) -> Option<u32> {
		self.lock()
			.sessions
			.get(&session_id)
			.and_then(|record| record.pty.as_ref())
			.map(PtySession::process_id)
	}

	/// Terminates and reaps one PTY-backed session without guessing a process.
	pub fn terminate_session(&self, session_id: SessionId) -> Result<(), SessionProcessError> {
		let pty = self
			.lock()
			.sessions
			.get(&session_id)
			.ok_or(SessionProcessError::SessionNotFound(session_id))?
			.pty
			.clone()
			.ok_or(SessionProcessError::SessionNotRunning(session_id))?;
		pty.terminate().map_err(SessionProcessError::Pty)
	}

	fn lock(&self) -> MutexGuard<'_, RegistryState> {
		lock_registry(&self.inner)
	}
}

impl Default for SessionRegistry {
	fn default() -> Self {
		Self::new()
	}
}

fn lock_registry(registry: &Mutex<RegistryState>) -> MutexGuard<'_, RegistryState> {
	registry
		.lock()
		.unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Exclusive ownership of one Session-to-Surface attachment.
#[derive(Debug)]
#[must_use = "dropping the lease detaches the surface"]
pub struct AttachmentLease {
	inner: Arc<AttachmentLeaseInner>,
}

#[derive(Debug)]
struct AttachmentLeaseInner {
	registry: Weak<Mutex<RegistryState>>,
	session_id: SessionId,
	surface_id: SurfaceId,
	generation: u64,
	active: AtomicBool,
}

impl AttachmentLease {
	/// Returns whether this exact lease still owns the attachment.
	#[must_use]
	pub fn is_active(&self) -> bool {
		self.inner.active.load(Ordering::Acquire)
	}

	/// Releases this exact attachment generation without destroying the Session.
	pub fn detach(&self) {
		self.inner.detach();
	}
}

impl Drop for AttachmentLease {
	fn drop(&mut self) {
		self.detach();
	}
}

impl AttachmentLeaseInner {
	fn detach(&self) {
		if !self.active.swap(false, Ordering::AcqRel) {
			return;
		}
		self.release_registry();
	}

	fn release_registry(&self) {
		let Some(registry) = self.registry.upgrade() else {
			return;
		};
		let mut state = lock_registry(&registry);
		let Some(record) = state.sessions.get_mut(&self.session_id) else {
			return;
		};
		if record.attachment_generation != Some(self.generation) {
			return;
		}
		record.snapshot.attached_surface_id = None;
		record.attachment_generation = None;
		if state.surface_attachments.get(&self.surface_id) == Some(&self.session_id) {
			state.surface_attachments.remove(&self.surface_id);
		}
	}
}

pub(crate) struct PtyAttachment {
	lease: AttachmentLease,
	pty: PtySession,
	cursor: PtyOutputCursor,
	replay_start: u64,
	live_offset: u64,
}

impl PtyAttachment {
	pub(crate) fn replay_start(&self) -> u64 {
		self.replay_start
	}

	pub(crate) fn live_offset(&self) -> u64 {
		self.live_offset
	}

	pub(crate) fn control(&self) -> PtyAttachmentControl {
		PtyAttachmentControl {
			lease: Arc::clone(&self.lease.inner),
			pty: self.pty.clone(),
		}
	}

	pub(crate) fn next_event(&mut self) -> Result<Option<PtyOutputEvent>, PtyError> {
		self.cursor.next_event(&self.lease.inner.active)
	}

	fn detach(&self) {
		if self.pty.deactivate_reader(&self.lease.inner.active) {
			self.lease.inner.release_registry();
		}
	}
}

impl Drop for PtyAttachment {
	fn drop(&mut self) {
		self.detach();
	}
}

pub(crate) struct PtyAttachmentControl {
	lease: Arc<AttachmentLeaseInner>,
	pty: PtySession,
}

impl PtyAttachmentControl {
	pub(crate) fn input(&self, bytes: Vec<u8>) -> Result<(), PtyError> {
		if !self.lease.active.load(Ordering::Acquire) {
			return Ok(());
		}
		self.pty.input(bytes)
	}

	pub(crate) fn resize(&self, size: TerminalSize) -> Result<(), PtyError> {
		if !self.lease.active.load(Ordering::Acquire) {
			return Ok(());
		}
		self.pty.resize(size)
	}

	pub(crate) fn detach(&self) {
		if self.pty.deactivate_reader(&self.lease.active) {
			self.lease.release_registry();
		}
	}
}

impl Drop for PtyAttachmentControl {
	fn drop(&mut self) {
		self.detach();
	}
}

/// A rejected SessionRegistry operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionRegistryError {
	/// The requested session does not exist.
	SessionNotFound(SessionId),
	/// The session already belongs to a surface, including the same surface.
	SessionAlreadyAttached {
		session_id: SessionId,
		attached_surface_id: SurfaceId,
	},
	/// The surface already belongs to a different session.
	SurfaceAlreadyAttached {
		surface_id: SurfaceId,
		attached_session_id: SessionId,
	},
	/// The attachment generation space has been exhausted.
	AttachmentGenerationExhausted,
}

impl fmt::Display for SessionRegistryError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::SessionNotFound(session_id) => {
				write!(formatter, "session {session_id} not found")
			}
			Self::SessionAlreadyAttached {
				session_id,
				attached_surface_id,
			} => write!(
				formatter,
				"session {session_id} is already attached to surface {attached_surface_id}",
			),
			Self::SurfaceAlreadyAttached {
				surface_id,
				attached_session_id,
			} => write!(
				formatter,
				"surface {surface_id} is already attached to session {attached_session_id}",
			),
			Self::AttachmentGenerationExhausted => {
				formatter.write_str("attachment generation space exhausted")
			}
		}
	}
}

impl Error for SessionRegistryError {}

/// A rejected or failed operation on a Session's owned child process.
#[derive(Debug)]
pub enum SessionProcessError {
	/// The requested Session does not exist.
	SessionNotFound(SessionId),
	/// The Session has no resolved child process yet.
	SessionNotRunning(SessionId),
	/// The PTY worker rejected or failed the operation.
	Pty(PtyError),
}

impl fmt::Display for SessionProcessError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::SessionNotFound(session_id) => {
				write!(formatter, "session {session_id} not found")
			}
			Self::SessionNotRunning(session_id) => {
				write!(formatter, "session {session_id} has no PTY process")
			}
			Self::Pty(error) => error.fmt(formatter),
		}
	}
}

impl Error for SessionProcessError {
	fn source(&self) -> Option<&(dyn Error + 'static)> {
		match self {
			Self::Pty(error) => Some(error),
			_ => None,
		}
	}
}

#[derive(Debug)]
pub(crate) enum PtyAttachmentError {
	Registry(SessionRegistryError),
	SessionNotRunning(SessionId),
	Pty(PtyError),
}

impl fmt::Display for PtyAttachmentError {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		match self {
			Self::Registry(error) => error.fmt(formatter),
			Self::SessionNotRunning(session_id) => {
				write!(formatter, "session {session_id} has no PTY process")
			}
			Self::Pty(error) => error.fmt(formatter),
		}
	}
}

impl Error for PtyAttachmentError {}

impl From<SessionRegistryError> for PtyAttachmentError {
	fn from(error: SessionRegistryError) -> Self {
		Self::Registry(error)
	}
}

impl From<PtyError> for PtyAttachmentError {
	fn from(error: PtyError) -> Self {
		Self::Pty(error)
	}
}
