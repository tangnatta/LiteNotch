//! Platform-independent logic for LiteNotch.
//!
//! Nothing here reads a clock, touches the filesystem, or spawns a thread:
//! callers pass `now_ms` (Unix milliseconds) in and act on the returned
//! effects. [`state::Core`] ties the feature modules together.
#![forbid(unsafe_code)]

pub mod agent;
pub mod analytics;
pub mod caffeine;
pub mod clipboard;
pub mod ipc;
pub mod media;
pub mod meeting;
pub mod notify;
pub mod pomodoro;
pub mod state;
pub mod usage;
