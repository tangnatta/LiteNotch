//! File access shared by the app and the CLI. Kept apart from the runtime so
//! the CLI, which runs on every agent hook, does not link the system
//! frameworks the app needs.

pub mod hooks_file;
pub mod store;
