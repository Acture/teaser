use taco_core::{CheckoutId, SurfaceId};
use tacod::{SessionRegistry, SessionRegistryError};

#[test]
fn creates_independent_sessions_for_one_checkout() {
	let checkout_id = CheckoutId::new(7);
	let mut registry = SessionRegistry::new();

	let first_id = registry.create_session(checkout_id);
	let second_id = registry.create_session(checkout_id);

	assert_ne!(first_id, second_id);
	assert_eq!(
		registry.session(first_id).unwrap().checkout_id(),
		checkout_id
	);
	assert_eq!(
		registry.session(second_id).unwrap().checkout_id(),
		checkout_id
	);
}

#[test]
fn attaches_a_surface_to_the_exact_session() {
	let mut registry = SessionRegistry::new();
	let first_id = registry.create_session(CheckoutId::new(1));
	let second_id = registry.create_session(CheckoutId::new(1));
	let surface_id = SurfaceId::new(11);

	registry.attach(second_id, surface_id).unwrap();

	assert_eq!(
		registry.session(first_id).unwrap().attached_surface_id(),
		None
	);
	assert_eq!(
		registry.session(second_id).unwrap().attached_surface_id(),
		Some(surface_id),
	);
}

#[test]
fn rejects_a_second_surface_for_one_session() {
	let mut registry = SessionRegistry::new();
	let session_id = registry.create_session(CheckoutId::new(1));
	let first_surface_id = SurfaceId::new(1);
	let second_surface_id = SurfaceId::new(2);
	registry.attach(session_id, first_surface_id).unwrap();

	let error = registry.attach(session_id, second_surface_id).unwrap_err();

	assert_eq!(
		error,
		SessionRegistryError::SessionAlreadyAttached {
			session_id,
			attached_surface_id: first_surface_id,
		},
	);
}

#[test]
fn attaching_an_unknown_session_does_not_create_one() {
	let mut registry = SessionRegistry::new();
	let unknown_id = taco_core::SessionId::generate();
	let surface_id = SurfaceId::new(1);

	let error = registry.attach(unknown_id, surface_id).unwrap_err();

	assert_eq!(error, SessionRegistryError::SessionNotFound(unknown_id),);
	assert!(registry.session(unknown_id).is_none());
}

#[test]
fn detach_keeps_the_session_alive_and_allows_reattachment() {
	let mut registry = SessionRegistry::new();
	let session_id = registry.create_session(CheckoutId::new(1));
	let first_surface_id = SurfaceId::new(1);
	let second_surface_id = SurfaceId::new(2);
	registry.attach(session_id, first_surface_id).unwrap();

	registry.detach(session_id, first_surface_id).unwrap();
	registry.attach(session_id, second_surface_id).unwrap();

	assert_eq!(
		registry.session(session_id).unwrap().attached_surface_id(),
		Some(second_surface_id),
	);
}

#[test]
fn stale_surface_cannot_detach_the_current_surface() {
	let mut registry = SessionRegistry::new();
	let session_id = registry.create_session(CheckoutId::new(1));
	let current_surface_id = SurfaceId::new(1);
	let stale_surface_id = SurfaceId::new(2);
	registry.attach(session_id, current_surface_id).unwrap();

	let error = registry.detach(session_id, stale_surface_id).unwrap_err();

	assert_eq!(
		error,
		SessionRegistryError::AttachmentMismatch {
			session_id,
			expected_surface_id: current_surface_id,
			actual_surface_id: stale_surface_id,
		},
	);
}

#[test]
fn repeated_attach_and_detach_are_idempotent() {
	let mut registry = SessionRegistry::new();
	let session_id = registry.create_session(CheckoutId::new(1));
	let surface_id = SurfaceId::new(1);

	registry.attach(session_id, surface_id).unwrap();
	registry.attach(session_id, surface_id).unwrap();
	registry.detach(session_id, surface_id).unwrap();
	registry.detach(session_id, surface_id).unwrap();

	assert_eq!(
		registry.session(session_id).unwrap().attached_surface_id(),
		None
	);
}
