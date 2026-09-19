use std::fmt;
use std::str::FromStr;

use uuid::Uuid;

macro_rules! define_numeric_id {
	($name:ident, $description:literal) => {
		#[doc = $description]
		#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
		pub struct $name(u64);

		impl $name {
			/// Creates an identity from its internal numeric representation.
			#[must_use]
			pub const fn new(value: u64) -> Self {
				Self(value)
			}

			/// Returns the internal numeric representation.
			#[must_use]
			pub const fn value(self) -> u64 {
				self.0
			}
		}

		impl fmt::Display for $name {
			fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
				self.0.fmt(formatter)
			}
		}
	};
}

define_numeric_id!(CheckoutId, "Identifies one concrete checkout or worktree.");
define_numeric_id!(
	SurfaceId,
	"Identifies one Teaser-owned or external attached surface."
);

/// Identifies one Teaser-owned interactive session with collision-resistant UUIDs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SessionId(Uuid);

impl SessionId {
	/// Generates an opaque random session identity.
	#[must_use]
	pub fn generate() -> Self {
		Self(Uuid::new_v4())
	}
}

impl fmt::Display for SessionId {
	fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
		self.0.fmt(formatter)
	}
}

impl FromStr for SessionId {
	type Err = uuid::Error;

	fn from_str(value: &str) -> Result<Self, Self::Err> {
		Uuid::parse_str(value).map(Self)
	}
}
