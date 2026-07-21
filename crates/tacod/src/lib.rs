//! Runtime ownership for TACO sessions.

pub mod ipc;
pub mod runtime;

use std::collections::HashMap;
use std::collections::hash_map::Entry;
use std::error::Error;
use std::fmt;

use taco_core::{CheckoutId, SessionId, SurfaceId};

/// A TACO-owned session maintained independently of its attached surface.
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

/// In-memory owner of TACO sessions and their exact surface attachments.
#[derive(Debug)]
pub struct SessionRegistry {
	sessions: HashMap<SessionId, Session>,
}

impl SessionRegistry {
	/// Creates an empty registry.
	#[must_use]
	pub fn new() -> Self {
		Self {
			sessions: HashMap::new(),
		}
	}

	/// Creates a detached session for an exact checkout.
	pub fn create_session(&mut self, checkout_id: CheckoutId) -> SessionId {
		loop {
			let session_id = SessionId::generate();
			if let Entry::Vacant(entry) = self.sessions.entry(session_id) {
				entry.insert(Session {
					id: session_id,
					checkout_id,
					attached_surface_id: None,
				});
				return session_id;
			}
		}
	}

	/// Returns a session without exposing mutable registry state.
	#[must_use]
	pub fn session(&self, session_id: SessionId) -> Option<&Session> {
		self.sessions.get(&session_id)
	}

	/// Attaches one surface to an exact session.
	///
	/// Repeating the same attachment is idempotent. A session may participate in
	/// at most one attachment.
	pub fn attach(
		&mut self,
		session_id: SessionId,
		surface_id: SurfaceId,
	) -> Result<(), SessionRegistryError> {
		let session = self
			.sessions
			.get_mut(&session_id)
			.ok_or(SessionRegistryError::SessionNotFound(session_id))?;

		if session.attached_surface_id == Some(surface_id) {
			return Ok(());
		}
		if let Some(attached_surface_id) = session.attached_surface_id {
			return Err(SessionRegistryError::SessionAlreadyAttached {
				session_id,
				attached_surface_id,
			});
		}
		session.attached_surface_id = Some(surface_id);
		Ok(())
	}

	/// Detaches a surface without destroying its session.
	///
	/// Repeating a completed detach is idempotent. A stale surface cannot detach
	/// a different surface that has since attached to the session.
	pub fn detach(
		&mut self,
		session_id: SessionId,
		surface_id: SurfaceId,
	) -> Result<(), SessionRegistryError> {
		let attached_surface_id = self
			.sessions
			.get(&session_id)
			.ok_or(SessionRegistryError::SessionNotFound(session_id))?
			.attached_surface_id;

		match attached_surface_id {
			None => Ok(()),
			Some(attached_surface_id) if attached_surface_id == surface_id => {
				self.sessions
					.get_mut(&session_id)
					.ok_or(SessionRegistryError::SessionNotFound(session_id))?
					.attached_surface_id = None;
				Ok(())
			}
			Some(attached_surface_id) => Err(SessionRegistryError::AttachmentMismatch {
				session_id,
				expected_surface_id: attached_surface_id,
				actual_surface_id: surface_id,
			}),
		}
	}
}

impl Default for SessionRegistry {
	fn default() -> Self {
		Self::new()
	}
}

/// A rejected SessionRegistry operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionRegistryError {
	/// The requested session does not exist.
	SessionNotFound(SessionId),
	/// The session already belongs to a different surface.
	SessionAlreadyAttached {
		session_id: SessionId,
		attached_surface_id: SurfaceId,
	},
	/// A stale or unrelated surface attempted to detach the session.
	AttachmentMismatch {
		session_id: SessionId,
		expected_surface_id: SurfaceId,
		actual_surface_id: SurfaceId,
	},
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
			Self::AttachmentMismatch {
				session_id,
				expected_surface_id,
				actual_surface_id,
			} => write!(
				formatter,
				"session {session_id} is attached to surface {expected_surface_id}, not {actual_surface_id}",
			),
		}
	}
}

impl Error for SessionRegistryError {}
