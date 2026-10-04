use teaser_core::{CheckoutId, SurfaceId};
use teaserd::{SessionRegistry, SessionRegistryError};

#[test]
fn creates_independent_sessions_for_one_checkout() {
	let checkout_id = CheckoutId::new(7);
	let registry = SessionRegistry::new();

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
	let registry = SessionRegistry::new();
	let first_id = registry.create_session(CheckoutId::new(1));
	let second_id = registry.create_session(CheckoutId::new(1));
	let surface_id = SurfaceId::new(11);

	let _lease = registry.attach(second_id, surface_id).unwrap();

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
fn rejects_every_second_connection_for_one_session() {
	let registry = SessionRegistry::new();
	let session_id = registry.create_session(CheckoutId::new(1));
	let first_surface_id = SurfaceId::new(1);
	let second_surface_id = SurfaceId::new(2);
	let _lease = registry.attach(session_id, first_surface_id).unwrap();

	let different_surface_error = registry.attach(session_id, second_surface_id).unwrap_err();
	let same_surface_error = registry.attach(session_id, first_surface_id).unwrap_err();

	assert_eq!(
		different_surface_error,
		SessionRegistryError::SessionAlreadyAttached {
			session_id,
			attached_surface_id: first_surface_id,
		},
	);
	assert_eq!(same_surface_error, different_surface_error);
}

#[test]
fn one_surface_cannot_own_two_sessions() {
	let registry = SessionRegistry::new();
	let first_id = registry.create_session(CheckoutId::new(1));
	let second_id = registry.create_session(CheckoutId::new(2));
	let surface_id = SurfaceId::new(1);
	let _lease = registry.attach(first_id, surface_id).unwrap();

	let error = registry.attach(second_id, surface_id).unwrap_err();

	assert_eq!(
		error,
		SessionRegistryError::SurfaceAlreadyAttached {
			surface_id,
			attached_session_id: first_id,
		},
	);
}

#[test]
fn attaching_an_unknown_session_does_not_create_one() {
	let registry = SessionRegistry::new();
	let unknown_id = teaser_core::SessionId::generate();
	let surface_id = SurfaceId::new(1);

	let error = registry.attach(unknown_id, surface_id).unwrap_err();

	assert_eq!(error, SessionRegistryError::SessionNotFound(unknown_id));
	assert!(registry.session(unknown_id).is_none());
}

#[test]
fn dropping_a_lease_keeps_the_session_alive_and_allows_reattachment() {
	let registry = SessionRegistry::new();
	let session_id = registry.create_session(CheckoutId::new(1));
	let first_surface_id = SurfaceId::new(1);
	let second_surface_id = SurfaceId::new(2);

	{
		let _lease = registry.attach(session_id, first_surface_id).unwrap();
	}
	let _lease = registry.attach(session_id, second_surface_id).unwrap();

	assert_eq!(
		registry.session(session_id).unwrap().attached_surface_id(),
		Some(second_surface_id),
	);
}

#[test]
fn stale_lease_cannot_detach_a_new_generation() {
	let registry = SessionRegistry::new();
	let session_id = registry.create_session(CheckoutId::new(1));
	let surface_id = SurfaceId::new(1);
	let stale_lease = registry.attach(session_id, surface_id).unwrap();
	stale_lease.detach();
	let _current_lease = registry.attach(session_id, surface_id).unwrap();

	stale_lease.detach();

	assert_eq!(
		registry.session(session_id).unwrap().attached_surface_id(),
		Some(surface_id),
	);
}

#[test]
fn explicit_detach_is_idempotent() {
	let registry = SessionRegistry::new();
	let session_id = registry.create_session(CheckoutId::new(1));
	let surface_id = SurfaceId::new(1);
	let lease = registry.attach(session_id, surface_id).unwrap();

	lease.detach();
	lease.detach();

	assert_eq!(
		registry.session(session_id).unwrap().attached_surface_id(),
		None
	);
}
