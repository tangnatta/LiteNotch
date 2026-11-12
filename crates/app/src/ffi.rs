//! C interface for the native shell. Strings are UTF-8, NUL-terminated.
//!
//! ```c
//! typedef void (*ln_view_callback)(const char *view_json, void *context);
//! bool ln_start(const char *config_json, ln_view_callback callback, void *context);
//! bool ln_send(const char *command_json);
//! void ln_stop(void);
//! ```
//!
//! `callback` runs on the runtime thread; the JSON pointer is valid only for
//! the duration of the call. Do not call `ln_stop` from inside the callback:
//! it waits for the runtime thread to finish.

use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::sync::Mutex;

use serde::Deserialize;

use crate::ports::MacPorts;
use crate::runtime::{Config, Runtime};

pub type ViewCallback = extern "C" fn(view_json: *const c_char, context: *mut c_void);

static RUNTIME: Mutex<Option<Runtime>> = Mutex::new(None);

#[derive(Debug, Deserialize)]
struct StartConfig {
    /// The user's home directory.
    home: String,
    /// Absolute path of the bundled `litenotch` CLI.
    cli_path: String,
    /// Override for the data directory (tests, development).
    #[serde(default)]
    data_dir: Option<String>,
    /// The bundled now-playing helper library; without it nothing is shown
    /// as playing.
    #[serde(default)]
    nowplaying_lib: Option<String>,
}

impl StartConfig {
    fn into_config(self) -> Config {
        let dir = self
            .data_dir
            .unwrap_or_else(|| litenotch_core::ipc::data_dir(&self.home));
        Config {
            dir: PathBuf::from(dir),
            claude_dir: PathBuf::from(&self.home).join(".claude"),
            cli_path: self.cli_path,
            serve_socket: true,
            clipboard_poll_ms: 500,
        }
    }
}

struct Context(*mut c_void);
// SAFETY: the context is an opaque token handed back to the shell's
// callback; the shell promises it is usable from the runtime thread.
unsafe impl Send for Context {}

fn lock() -> std::sync::MutexGuard<'static, Option<Runtime>> {
    RUNTIME
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// # Safety
/// `ptr` must be null or a valid NUL-terminated string.
unsafe fn string_arg(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: guaranteed by the caller.
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

/// Starts the runtime. Returns false if the configuration is invalid, the
/// runtime is already started, or another LiteNotch owns the socket.
///
/// # Safety
/// `config_json` must be null or a valid NUL-terminated string, and
/// `context` must stay valid until `ln_stop` returns.
#[no_mangle]
pub unsafe extern "C" fn ln_start(
    config_json: *const c_char,
    callback: Option<ViewCallback>,
    context: *mut c_void,
) -> bool {
    let Some(callback) = callback else {
        return false;
    };
    // SAFETY: forwarded from the caller's contract.
    let Some(json) = (unsafe { string_arg(config_json) }) else {
        return false;
    };
    let Ok(config) = serde_json::from_str::<StartConfig>(&json) else {
        return false;
    };
    let mut runtime = lock();
    if runtime.is_some() {
        return false;
    }
    let context = Context(context);
    let on_view = Box::new(move |view: &str| {
        let context = &context;
        if let Ok(view) = CString::new(view) {
            callback(view.as_ptr(), context.0);
        }
    });
    let now_playing_lib = config.nowplaying_lib.clone().map(PathBuf::from);
    let config = config.into_config();
    let ports = MacPorts::for_app(now_playing_lib, &config.dir);
    match Runtime::start(config, Box::new(ports), on_view) {
        Ok(started) => {
            *runtime = Some(started);
            true
        }
        Err(_) => false,
    }
}

/// Sends one command. Returns false if it is malformed or the runtime is
/// not running.
///
/// # Safety
/// `command_json` must be null or a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn ln_send(command_json: *const c_char) -> bool {
    // SAFETY: forwarded from the caller's contract.
    let Some(json) = (unsafe { string_arg(command_json) }) else {
        return false;
    };
    lock()
        .as_ref()
        .is_some_and(|runtime| runtime.send(&json).is_ok())
}

/// Stops the runtime, saving state and releasing keep-awake. Safe to call
/// when not started.
#[no_mangle]
pub extern "C" fn ln_stop() {
    let runtime = lock().take();
    drop(runtime);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static VIEWS: AtomicUsize = AtomicUsize::new(0);

    extern "C" fn count_views(view_json: *const c_char, context: *mut c_void) {
        // SAFETY: the runtime passes a valid string for the duration of the call.
        let view = unsafe { CStr::from_ptr(view_json) }.to_str().unwrap();
        assert!(view.starts_with('{') && view.contains("\"compact\""));
        assert_eq!(context as usize, 0x5a);
        VIEWS.fetch_add(1, Ordering::SeqCst);
    }

    fn c(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    #[test]
    fn config_resolves_default_and_overridden_directories() {
        let cfg: StartConfig =
            serde_json::from_str(r#"{"home":"/Users/me","cli_path":"/a/litenotch"}"#).unwrap();
        let cfg = cfg.into_config();
        assert_eq!(
            cfg.dir,
            PathBuf::from("/Users/me/Library/Application Support/LiteNotch")
        );
        assert_eq!(cfg.claude_dir, PathBuf::from("/Users/me/.claude"));
        assert_eq!(
            (
                cfg.cli_path.as_str(),
                cfg.serve_socket,
                cfg.clipboard_poll_ms
            ),
            ("/a/litenotch", true, 500)
        );
        let cfg: StartConfig =
            serde_json::from_str(r#"{"home":"/h","cli_path":"x","data_dir":"/tmp/d"}"#).unwrap();
        assert_eq!(cfg.into_config().dir, PathBuf::from("/tmp/d"));
    }

    // One test drives the whole lifecycle because the runtime is a process-wide singleton.
    #[test]
    fn lifecycle_through_the_c_interface() {
        let dir = crate::store::temp_dir("ffi");
        let context = 0x5a as *mut c_void;
        // SAFETY: all pointers are valid C strings or null as each case states.
        unsafe {
            assert!(
                !ln_send(c(r#"{"cmd":"refresh"}"#).as_ptr()),
                "not started yet"
            );
            assert!(!ln_start(std::ptr::null(), Some(count_views), context));
            assert!(!ln_start(
                c("not json").as_ptr(),
                Some(count_views),
                context
            ));
            assert!(
                !ln_start(c(r#"{"home":"/h"}"#).as_ptr(), Some(count_views), context),
                "cli_path is required"
            );

            let config = c(&serde_json::json!({
                "home": dir.join("home").to_string_lossy(),
                "cli_path": "/opt/litenotch",
                "data_dir": dir.join("data").to_string_lossy(),
            })
            .to_string());
            assert!(
                !ln_start(config.as_ptr(), None, context),
                "a null callback is refused"
            );
            assert!(ln_start(config.as_ptr(), Some(count_views), context));
            assert!(
                !ln_start(config.as_ptr(), Some(count_views), context),
                "already started"
            );

            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
            while VIEWS.load(Ordering::SeqCst) == 0 {
                assert!(
                    std::time::Instant::now() < deadline,
                    "no view model arrived"
                );
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
            assert!(ln_send(c(r#"{"cmd":"panel_opened"}"#).as_ptr()));
            assert!(!ln_send(c(r#"{"cmd":"nonsense"}"#).as_ptr()));
            assert!(!ln_send(std::ptr::null()));
            let invalid_utf8 = [0xffu8, 0x00];
            assert!(!ln_send(invalid_utf8.as_ptr().cast()));
        }
        ln_stop();
        ln_stop();
        assert!(
            dir.join("data/state.json").exists(),
            "state is saved on stop"
        );
        // SAFETY: valid C string.
        assert!(
            !unsafe { ln_send(c(r#"{"cmd":"refresh"}"#).as_ptr()) },
            "stopped"
        );
    }
}
