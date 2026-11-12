//! The LiteNotch runtime. One thread owns the [`litenotch_core::state::Core`]
//! and sleeps until the next deadline or message; a small socket server
//! feeds it requests from the `litenotch` CLI; the shell talks to it through
//! the C functions in [`ffi`].

pub mod clock;
pub mod ffi;
pub mod ports;
pub mod runtime;
pub mod server;
pub mod transcripts;

pub use litenotch_files::{hooks_file, store};
