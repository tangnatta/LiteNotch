//! Operating-system adapters. Parsing and command construction are plain
//! functions so they can be tested anywhere; the calls into the OS are gated
//! on `target_os` and return `Unsupported` elsewhere.

pub mod battery;
pub mod clipboard;
pub mod display;
pub mod lid;
pub mod nowplaying;
pub mod power;
pub mod script;
