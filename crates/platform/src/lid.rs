//! Closed-lid keep-awake.
//!
//! macOS only stays awake with the lid shut when the kernel `SleepDisabled`
//! flag is set, which needs root (`pmset -a disablesleep 1`). LiteNotch asks
//! for administrator rights once and starts a root shell loop that sets the
//! flag and clears it again as soon as either the LiteNotch process is gone
//! or the sentinel file is removed. A crash therefore cannot leave the Mac
//! unable to sleep, and turning lid mode off needs no second password prompt.

use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, PartialEq, Eq)]
pub enum LidError {
    Unsupported,
    /// The sentinel path contains characters we refuse to pass to a root shell.
    UnsafePath,
    Io(String),
    /// The user dismissed the password prompt, or the script failed.
    Denied(String),
    /// The command ran but the system does not report sleep as disabled.
    NotApplied,
}

impl std::fmt::Display for LidError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LidError::Unsupported => write!(f, "closed-lid mode is not supported on this platform"),
            LidError::UnsafePath => write!(f, "refusing to use an unsafe sentinel path"),
            LidError::Io(e) => write!(f, "could not prepare closed-lid mode: {e}"),
            LidError::Denied(e) => write!(f, "administrator approval was not given: {}", e.trim()),
            LidError::NotApplied => write!(f, "macOS did not accept the sleep setting"),
        }
    }
}

impl std::error::Error for LidError {}

/// Where the sentinel for one closed-lid session lives. `dir` is the
/// user's private temporary directory (mode 0700), so no other user can
/// create or remove it. `session` makes each enable use a fresh file, so
/// a watchdog from an earlier session can never be kept alive by a later one.
pub fn sentinel_path(dir: &Path, uid: u32, pid: u32, session: u32) -> PathBuf {
    dir.join(format!("litenotch-lid-{uid}-{pid}-{session}"))
}

static SESSION: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
/// The flag's value before this process first touched it. Read once: a
/// later reading could be our own earlier session that is still winding
/// down, and restoring to that would leave sleep disabled for good.
static ORIGINAL: std::sync::OnceLock<bool> = std::sync::OnceLock::new();

/// Only plain path characters may reach the root shell.
fn is_safe_path(path: &Path) -> bool {
    match path.to_str() {
        Some(s) => {
            s.starts_with('/')
                && !s.contains("..")
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'/' | b'-' | b'_' | b'.'))
        }
        None => false,
    }
}

/// The shell command run as root. It returns immediately; the watchdog loop
/// keeps running in the background with its output detached.
///
/// The loop identifies LiteNotch by pid *and* start time, so a recycled pid
/// cannot keep sleep disabled, and it gives up after `MAX_HOURS` regardless.
/// `restore_to` is the flag's value before lid mode (normally 0). The loop
/// only ever tests the sentinel; it never writes or deletes through it.
pub fn watchdog_command(pid: u32, sentinel: &Path, restore_to: bool) -> Result<String, LidError> {
    if !is_safe_path(sentinel) {
        return Err(LidError::UnsafePath);
    }
    let s = sentinel.to_str().ok_or(LidError::UnsafePath)?;
    let restore = u8::from(restore_to);
    let max_loops = MAX_HOURS * 3600 / 2;
    Ok(format!(
        "S=$(/bin/ps -o lstart= -p {pid}); [ -n \"$S\" ] || exit 1; \
         /usr/bin/pmset -a disablesleep 1; \
         (N=0; while [ $N -lt {max_loops} ] && [ -e {s} ] && \
         [ \"$(/bin/ps -o lstart= -p {pid} 2>/dev/null)\" = \"$S\" ]; \
         do /bin/sleep 2; N=$((N+1)); done; \
         /usr/bin/pmset -a disablesleep {restore}) >/dev/null 2>&1 &"
    ))
}

/// Hard cap on one closed-lid session.
const MAX_HOURS: u32 = 12;

/// The AppleScript that runs the watchdog with an administrator prompt.
pub fn admin_script(pid: u32, sentinel: &Path, restore_to: bool) -> Result<String, LidError> {
    let command = watchdog_command(pid, sentinel, restore_to)?;
    Ok(format!(
        "do shell script {} with prompt {} with administrator privileges",
        crate::script::applescript_quote(&command),
        crate::script::applescript_quote(
            "LiteNotch needs permission to keep your Mac awake with the lid closed."
        ),
    ))
}

/// An active closed-lid session. Dropping it ends the session.
#[derive(Debug)]
pub struct LidGuard {
    sentinel: PathBuf,
}

impl LidGuard {
    /// Shows the administrator prompt and blocks until it is answered, so
    /// call this off the UI thread.
    pub fn enable() -> Result<LidGuard, LidError> {
        if !cfg!(target_os = "macos") {
            return Err(LidError::Unsupported);
        }
        let session = SESSION.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let sentinel = sentinel_path(
            &std::env::temp_dir(),
            current_uid(),
            std::process::id(),
            session,
        );
        // If something else had already disabled sleep, leave it that way afterwards.
        let restore_to =
            *ORIGINAL.get_or_init(|| crate::battery::sleep_disabled().unwrap_or(false));
        let script = admin_script(std::process::id(), &sentinel, restore_to)?;
        // `create_new` never adopts a file that is already there.
        let _ = std::fs::remove_file(&sentinel);
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&sentinel)
            .map_err(|e| LidError::Io(e.to_string()))?;
        let guard = LidGuard { sentinel };
        // Five minutes for the user to type a password.
        if let Err(e) = crate::script::osascript(&script, Duration::from_secs(300)) {
            return Err(LidError::Denied(e.to_string()));
        }
        if crate::battery::sleep_disabled() != Some(true) {
            return Err(LidError::NotApplied);
        }
        Ok(guard)
    }

    pub fn sentinel(&self) -> &Path {
        &self.sentinel
    }
}

impl Drop for LidGuard {
    fn drop(&mut self) {
        // The root watchdog sees the file vanish and restores normal sleep.
        let _ = std::fs::remove_file(&self.sentinel);
    }
}

/// Removes sentinels left behind by earlier runs of this user, which stops
/// any watchdog whose process id has since been reused.
pub fn cleanup_stale() {
    cleanup_stale_in(&std::env::temp_dir(), current_uid(), std::process::id());
}

fn cleanup_stale_in(dir: &Path, uid: u32, own_pid: u32) {
    let prefix = format!("litenotch-lid-{uid}-");
    let own = format!("{prefix}{own_pid}-");
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if name.starts_with(&prefix) && !name.starts_with(&own) {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(unix)]
fn current_uid() -> u32 {
    extern "C" {
        fn getuid() -> u32;
    }
    // SAFETY: getuid has no preconditions and cannot fail.
    unsafe { getuid() }
}

#[cfg(not(unix))]
fn current_uid() -> u32 {
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sentinel_path_is_per_user_and_process() {
        assert_eq!(
            sentinel_path(Path::new("/var/folders/ab/T"), 501, 4242, 3),
            PathBuf::from("/var/folders/ab/T/litenotch-lid-501-4242-3")
        );
    }

    #[test]
    fn watchdog_sets_and_restores_the_flag() {
        let cmd =
            watchdog_command(77, Path::new("/private/tmp/litenotch-lid-501-77"), false).unwrap();
        assert!(cmd.contains("/usr/bin/pmset -a disablesleep 1;"));
        assert!(cmd.contains("/bin/ps -o lstart= -p 77"));
        assert!(cmd.contains("[ -e /private/tmp/litenotch-lid-501-77 ]"));
        assert!(cmd.contains("/usr/bin/pmset -a disablesleep 0)"));
        assert!(
            cmd.contains("[ $N -lt 21600 ]"),
            "the loop is capped at 12 hours"
        );
        assert!(
            !cmd.contains("rm "),
            "root never deletes through the sentinel path"
        );
        assert!(cmd.trim_end().ends_with('&'), "the loop must be detached");
        let keep = watchdog_command(77, Path::new("/private/tmp/x"), true).unwrap();
        assert!(
            keep.contains("/usr/bin/pmset -a disablesleep 1)"),
            "a pre-existing flag is restored"
        );
    }

    #[test]
    fn shell_metacharacters_in_the_path_are_refused() {
        for bad in [
            "/tmp/x; rm -rf /",
            "/tmp/$(id)",
            "/tmp/a b",
            "/tmp/a'b",
            "/tmp/a\"b",
            "/tmp/`id`",
            "/tmp/../etc/passwd",
            "relative/path",
            "/tmp/a\nb",
            "",
        ] {
            assert_eq!(
                watchdog_command(1, Path::new(bad), false),
                Err(LidError::UnsafePath),
                "{bad:?}"
            );
            assert_eq!(
                admin_script(1, Path::new(bad), false),
                Err(LidError::UnsafePath),
                "{bad:?}"
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_path_is_refused() {
        use std::os::unix::ffi::OsStrExt;
        let p = Path::new(std::ffi::OsStr::from_bytes(b"/tmp/\xff"));
        assert_eq!(watchdog_command(1, p, false), Err(LidError::UnsafePath));
    }

    #[test]
    fn admin_script_wraps_the_command_and_asks_for_privileges() {
        let script = admin_script(
            9,
            &sentinel_path(Path::new("/private/tmp"), 501, 9, 0),
            false,
        )
        .unwrap();
        assert!(script.starts_with("do shell script \"S=$(/bin/ps -o lstart= -p 9);"));
        assert!(script.ends_with("with administrator privileges"));
        assert!(script.contains("with prompt \"LiteNotch needs permission"));
        // The shell's double quotes are escaped for AppleScript.
        assert!(script.contains("[ -n \\\"$S\\\" ]"));
    }

    #[test]
    fn the_watchdog_loop_restores_when_the_sentinel_disappears() {
        let (dir, sentinel, restored) = loop_fixture("sentinel");
        run_loop_unprivileged(std::process::id(), &sentinel, &restored);
        std::thread::sleep(Duration::from_millis(400));
        assert!(
            !restored.exists(),
            "must keep waiting while the sentinel exists"
        );
        std::fs::remove_file(&sentinel).unwrap();
        assert!(
            wait_for(&restored),
            "must restore once the sentinel is removed"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_watchdog_loop_restores_when_the_process_exits() {
        let (dir, sentinel, restored) = loop_fixture("process");
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        run_loop_unprivileged(child.id(), &sentinel, &restored);
        std::thread::sleep(Duration::from_millis(400));
        assert!(
            !restored.exists(),
            "must keep waiting while the process lives"
        );
        child.kill().unwrap();
        child.wait().unwrap();
        assert!(wait_for(&restored), "must restore once the process is gone");
        assert!(sentinel.exists(), "the loop never deletes the sentinel");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_watchdog_refuses_to_start_for_a_dead_process() {
        let (dir, sentinel, restored) = loop_fixture("dead");
        let mut child = std::process::Command::new("/usr/bin/true").spawn().unwrap();
        let pid = child.id();
        child.wait().unwrap();
        let cmd = unprivileged(pid, &sentinel, &restored);
        let err = crate::script::run("/bin/sh", &["-c", &cmd], Duration::from_secs(5)).unwrap_err();
        assert!(matches!(
            err,
            crate::script::ScriptError::Failed { code: Some(1), .. }
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn loop_fixture(name: &str) -> (PathBuf, PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!("litenotch-lid-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let sentinel = dir.join("sentinel");
        std::fs::write(&sentinel, b"").unwrap();
        (dir.clone(), sentinel, dir.join("restored"))
    }

    /// The real loop with `pmset` swapped for a marker file, runnable without root.
    fn unprivileged(pid: u32, sentinel: &Path, restored: &Path) -> String {
        watchdog_command(pid, Path::new("/private/tmp/SENTINEL"), false)
            .unwrap()
            .replace("/private/tmp/SENTINEL", sentinel.to_str().unwrap())
            .replace("/usr/bin/pmset -a disablesleep 1;", "")
            .replace(
                "/usr/bin/pmset -a disablesleep 0",
                &format!("/usr/bin/touch {}", restored.to_str().unwrap()),
            )
            .replace("/bin/sleep 2", "/bin/sleep 0.1")
    }

    fn run_loop_unprivileged(pid: u32, sentinel: &Path, restored: &Path) {
        let cmd = unprivileged(pid, sentinel, restored);
        crate::script::run("/bin/sh", &["-c", &cmd], Duration::from_secs(5)).unwrap();
    }

    fn wait_for(path: &Path) -> bool {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !path.exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        path.exists()
    }

    #[test]
    fn stale_sentinels_of_this_user_are_removed_but_others_are_kept() {
        let dir = std::env::temp_dir().join(format!("litenotch-stale-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let names = [
            "litenotch-lid-501-1-0",
            "litenotch-lid-501-2-0",
            "litenotch-lid-501-2-7",
            "litenotch-lid-501-21-0",
            "litenotch-lid-502-1-0",
            "unrelated",
        ];
        for name in names {
            std::fs::write(dir.join(name), b"").unwrap();
        }
        cleanup_stale_in(&dir, 501, 2);
        assert!(!dir.join("litenotch-lid-501-1-0").exists());
        assert!(
            !dir.join("litenotch-lid-501-21-0").exists(),
            "pid 21 is not pid 2"
        );
        assert!(
            dir.join("litenotch-lid-501-2-0").exists(),
            "own sessions are kept"
        );
        assert!(dir.join("litenotch-lid-501-2-7").exists());
        assert!(
            dir.join("litenotch-lid-502-1-0").exists(),
            "other users are untouched"
        );
        assert!(dir.join("unrelated").exists());
        cleanup_stale_in(&dir.join("missing"), 501, 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_users_temporary_directory_is_private_and_safe_to_pass_to_the_root_shell() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir();
        let sentinel = sentinel_path(&dir, current_uid(), std::process::id(), 0);
        if cfg!(target_os = "macos") {
            let mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o700, "{dir:?} must not be writable by other users");
            assert!(
                watchdog_command(1, &sentinel, false).is_ok(),
                "{sentinel:?}"
            );
        }
    }

    #[test]
    fn dropping_the_guard_removes_the_sentinel() {
        let path =
            std::env::temp_dir().join(format!("litenotch-guard-test-{}", std::process::id()));
        std::fs::write(&path, b"").unwrap();
        let guard = LidGuard {
            sentinel: path.clone(),
        };
        assert_eq!(guard.sentinel(), path.as_path());
        drop(guard);
        assert!(!path.exists());
    }

    #[test]
    fn errors_read_well() {
        assert!(LidError::Denied(" User canceled. ".into())
            .to_string()
            .ends_with("User canceled."));
        assert!(LidError::NotApplied.to_string().contains("did not accept"));
        assert!(LidError::Unsupported.to_string().contains("not supported"));
        assert!(LidError::UnsafePath.to_string().contains("unsafe"));
        assert!(LidError::Io("x".into()).to_string().contains("x"));
    }
}
