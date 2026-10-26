//! App Context Kit: the Rust implementation of `spec/APP-CONTEXT.md`.
//!
//! * [`manifest`] and [`mod@resolve`] are pure (no I/O) and are checked by `spec/conformance/*.json`.
//! * [`config_store`], [`roster`] and [`app_context`] do the I/O.
//! * [`venue`] is the session that hides local, fake and real Venue.
//!
//! Implements spec v0.1 (`spec/APP-CONTEXT.md`, sections 1, 2 and 5).

#![forbid(unsafe_code)]

pub mod adopt;
pub mod app_context;
pub mod config_store;
pub mod manifest;
pub mod resolve;
pub mod roster;
pub mod venue;

#[cfg(test)]
mod testutil;

pub use adopt::{
    AdoptError, AdoptedContext, ContextSnapshot, ReadOnlySettings, SettingsError, SnapshotError,
    SNAPSHOT_SCHEMA,
};
pub use app_context::{
    AppContext, CloseError, CloseErrors, ContextError, Note, OpenOptions, Severity,
};
pub use config_store::{ConfigError, ConfigStore};
pub use manifest::{Manifest, ManifestError, VenueMode};
pub use resolve::{resolve, Dirs, Env, Mode, Platform, ResolveError, Resolved};
pub use roster::{Announcement, EntryStatus, Roster, RosterEntry, ScanEntry};
pub use venue::{
    FakeVenue, HoldOptions, HoldOutcome, LocalVenue, RefusalKind, VenueError, VenueHold, VenueNeed,
    VenueSession,
};
