//! Closed-lid keep-awake.
//!
//! macOS only stays awake with the lid shut when the kernel `SleepDisabled`
//! flag is set, which needs root (`pmset -a disablesleep 1`). LiteNotch asks
//! for administrator rights once per run and starts a root shell loop, the
//! helper, which sets the flag and then waits on a named pipe that LiteNotch
//! holds open:
//!
//! - a line `0` restores normal sleep, a line `1` disables it again, so
//!   turning the mode off and on needs no second password prompt;
//! - when the pipe closes (LiteNotch quit or crashed) it restores sleep and
//!   exits at once, so a crash cannot leave the Mac unable to sleep.
//!
//! The helper sleeps in `read`; nothing polls. Every `TICK_SECS` it wakes to
//! check that the LiteNotch process (pid and start time) is still the same
//! one, which also covers another process holding the pipe open, and to
//! count towards the cap on one stretch with sleep disabled.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, PartialEq, Eq)]
pub enum LidError {
    Unsupported,
    /// The pipe path contains characters we refuse to pass to a root shell.
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
            LidError::UnsafePath => write!(f, "refusing to use an unsafe pipe path"),
            LidError::Io(e) => write!(f, "could not prepare closed-lid mode: {e}"),
            LidError::Denied(e) => write!(f, "administrator approval was not given: {}", e.trim()),
            LidError::NotApplied => write!(f, "macOS did not accept the sleep setting"),
        }
    }
}

impl std::error::Error for LidError {}

/// Where the pipe for one helper lives. `dir` is the user's private
/// temporary directory (mode 0700), so no other user can reach it.
/// `session` gives every helper a fresh pipe, so nothing written for an
/// earlier helper is ever read by a later one.
pub fn pipe_path(dir: &Path, uid: u32, pid: u32, session: u32) -> PathBuf {
    dir.join(format!("litenotch-lid-{uid}-{pid}-{session}"))
}

static SESSION: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
/// The flag's value before this process first touched it. Read once: a
/// later reading could be our own helper's doing, and restoring to that
/// would leave sleep disabled for good.
static ORIGINAL: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
/// The helper started by this process, if any.
static HELPER: Mutex<Option<Arc<Helper>>> = Mutex::new(None);

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

/// The helper's own cap on one stretch with sleep disabled. LiteNotch turns
/// the mode off itself after `caffeine::LID_MAX_HOURS` (12); this is the
/// backstop for a LiteNotch that does not, so it is a little longer.
const MAX_MINUTES: u32 = 12 * 60 + 10;
/// How often the helper wakes from `read` to check on LiteNotch.
const TICK_SECS: u32 = 30;

/// The shell command run as root. It returns immediately; the helper loop
/// keeps running in the background with its output detached.
///
/// Root only ever reads from the pipe, at most four characters at a time,
/// and compares what it read with `0` and `1`; anything else ends the
/// helper with sleep restored. `read` reports end-of-file and a timeout the
/// same way in this shell, so the two are told apart by how long it took:
/// end-of-file returns at once. The cap is measured on the shell's clock
/// from the moment the mode last went from off to on, so neither repeating
/// `1` nor writing often enough to keep `read` from timing out stretches it.
/// `restore_to` is the flag's value before lid mode (normally 0).
pub fn helper_command(pid: u32, pipe: &Path, restore_to: bool) -> Result<String, LidError> {
    if !is_safe_path(pipe) {
        return Err(LidError::UnsafePath);
    }
    let f = pipe.to_str().ok_or(LidError::UnsafePath)?;
    let restore = u8::from(restore_to);
    let tick = TICK_SECS;
    let tick_min = TICK_SECS - 1;
    let max_secs = MAX_MINUTES * 60;
    // The pipe is opened before the flag is touched: if that fails, nothing
    // has been changed and nothing needs restoring. The loop inherits it.
    Ok(format!(
        "S=$(/bin/ps -o lstart= -p {pid}); [ -n \"$S\" ] || exit 1; \
         [ -p {f} ] || exit 1; exec 3<{f} || exit 1; \
         /usr/bin/pmset -a disablesleep 1; \
         (ON=1; B=$SECONDS; \
         while [ \"$(/bin/ps -o lstart= -p {pid} 2>/dev/null)\" = \"$S\" ]; do \
         [ $ON = 0 ] || [ $((SECONDS-B)) -lt {max_secs} ] || break; \
         T=$SECONDS; \
         if IFS= read -r -n 4 -t {tick} L <&3; then \
         case \"$L\" in \
         1) [ $ON = 1 ] || B=$SECONDS; /usr/bin/pmset -a disablesleep 1; ON=1;; \
         0) /usr/bin/pmset -a disablesleep {restore}; ON=0;; \
         *) break;; esac; \
         else [ $((SECONDS-T)) -ge {tick_min} ] || break; \
         fi; done; \
         /usr/bin/pmset -a disablesleep {restore}) >/dev/null 2>&1 &"
    ))
}

/// The AppleScript that starts the helper with an administrator prompt.
pub fn admin_script(pid: u32, pipe: &Path, restore_to: bool) -> Result<String, LidError> {
    let command = helper_command(pid, pipe, restore_to)?;
    Ok(format!(
        "do shell script {} with prompt {} with administrator privileges",
        crate::script::applescript_quote(&command),
        crate::script::applescript_quote(
            "LiteNotch needs permission to keep your Mac awake with the lid closed."
        ),
    ))
}

/// LiteNotch's end of the pipe to a running helper.
#[derive(Debug)]
struct Helper {
    pipe: PathBuf,
    /// Open for reading and writing: opening never blocks, a write never
    /// fails for want of a reader, and the helper sees end-of-file only
    /// when this process lets go of it.
    writer: Mutex<std::fs::File>,
}

impl Helper {
    /// Creates the pipe (mode 0600) and opens it. Never adopts a file that
    /// is already there.
    fn create(pipe: PathBuf) -> Result<Helper, LidError> {
        let _ = std::fs::remove_file(&pipe);
        make_fifo(&pipe).map_err(|e| LidError::Io(e.to_string()))?;
        let writer = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&pipe)
            .map_err(|e| LidError::Io(e.to_string()))?;
        Ok(Helper {
            pipe,
            writer: Mutex::new(writer),
        })
    }

    /// Tells the helper to disable sleep (`true`) or restore it.
    fn send(&self, on: bool) -> std::io::Result<()> {
        let mut w = self.writer.lock().unwrap_or_else(|e| e.into_inner());
        w.write_all(if on { b"1\n" } else { b"0\n" })
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        // Closing the pipe is what ends the helper; the name goes too.
        let _ = std::fs::remove_file(&self.pipe);
    }
}

/// Closed-lid mode being on. Dropping it turns the mode off; the helper
/// stays, so turning it on again needs no password.
#[derive(Debug)]
pub struct LidGuard {
    helper: Arc<Helper>,
}

impl LidGuard {
    /// Turns the mode on. The first time in a run this shows the
    /// administrator prompt and blocks until it is answered, so call it off
    /// the UI thread.
    pub fn enable() -> Result<LidGuard, LidError> {
        if !cfg!(target_os = "macos") {
            return Err(LidError::Unsupported);
        }
        let mut slot = HELPER.lock().unwrap_or_else(|e| e.into_inner());
        // A helper from earlier in this run: ask it, and check it answered.
        // It may be gone (the 12 hour cap, or it was killed).
        if let Some(helper) = slot.as_ref() {
            if helper.send(true).is_ok() && wait_for_flag(true, Duration::from_secs(2)) {
                return Ok(LidGuard {
                    helper: Arc::clone(helper),
                });
            }
            *slot = None;
        }
        let session = SESSION.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let pipe = pipe_path(
            &std::env::temp_dir(),
            current_uid(),
            std::process::id(),
            session,
        );
        // If something else had already disabled sleep, leave it that way afterwards.
        let restore_to =
            *ORIGINAL.get_or_init(|| crate::battery::sleep_disabled().unwrap_or(false));
        let script = admin_script(std::process::id(), &pipe, restore_to)?;
        let helper = Arc::new(Helper::create(pipe)?);
        // Five minutes for the user to type a password. On any failure the
        // helper value is dropped, which closes and removes the pipe.
        if let Err(e) = crate::script::osascript(&script, Duration::from_secs(300)) {
            return Err(LidError::Denied(e.to_string()));
        }
        if crate::battery::sleep_disabled() != Some(true) {
            return Err(LidError::NotApplied);
        }
        *slot = Some(Arc::clone(&helper));
        Ok(LidGuard { helper })
    }
}

impl Drop for LidGuard {
    fn drop(&mut self) {
        // The helper restores normal sleep and keeps waiting.
        let _ = self.helper.send(false);
    }
}

/// Polls the system flag until it has the wanted value.
fn wait_for_flag(want: bool, within: Duration) -> bool {
    let deadline = std::time::Instant::now() + within;
    loop {
        if crate::battery::sleep_disabled() == Some(want) {
            return true;
        }
        if std::time::Instant::now() >= deadline {
            return false;
        }
        std::thread::sleep(Duration::from_millis(150));
    }
}

#[cfg(target_os = "macos")]
fn make_fifo(path: &Path) -> std::io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    extern "C" {
        fn mkfifo(path: *const std::ffi::c_char, mode: u16) -> i32;
    }
    let c = std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidInput, e))?;
    // SAFETY: `c` is a valid NUL-terminated path for the duration of the call.
    if unsafe { mkfifo(c.as_ptr(), 0o600) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "macos"))]
fn make_fifo(_path: &Path) -> std::io::Result<()> {
    Err(std::io::Error::new(
        std::io::ErrorKind::Unsupported,
        "no named pipes",
    ))
}

/// Removes pipes left behind by earlier runs of this user.
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
    fn pipe_path_is_per_user_process_and_helper() {
        assert_eq!(
            pipe_path(Path::new("/var/folders/ab/T"), 501, 4242, 3),
            PathBuf::from("/var/folders/ab/T/litenotch-lid-501-4242-3")
        );
    }

    #[test]
    fn the_helper_sets_and_restores_the_flag_and_only_compares_what_it_reads() {
        let cmd =
            helper_command(77, Path::new("/private/tmp/litenotch-lid-501-77"), false).unwrap();
        assert!(cmd.contains("/bin/ps -o lstart= -p 77"));
        assert!(cmd.contains("[ -p /private/tmp/litenotch-lid-501-77 ] || exit 1"));
        // The pipe is opened before the flag is first set, so a failure
        // there leaves nothing to restore.
        let open = cmd
            .find("exec 3</private/tmp/litenotch-lid-501-77 || exit 1")
            .unwrap();
        assert!(open < cmd.find("/usr/bin/pmset").unwrap());
        assert!(
            cmd.contains("1) [ $ON = 1 ] || B=$SECONDS; /usr/bin/pmset -a disablesleep 1; ON=1;;")
        );
        assert!(cmd.contains("0) /usr/bin/pmset -a disablesleep 0; ON=0;;"));
        assert!(cmd.contains("*) break;;"), "anything else ends the helper");
        assert!(cmd.contains("read -r -n 4 -t 30 L <&3"), "bounded reads");
        assert!(
            cmd.contains("[ $ON = 0 ] || [ $((SECONDS-B)) -lt 43800 ] || break"),
            "one stretch is capped at 12 hours and 10 minutes"
        );
        assert!(cmd
            .trim_end()
            .ends_with("/usr/bin/pmset -a disablesleep 0) >/dev/null 2>&1 &"));
        // What was read is never run, and nothing is written or deleted through the path.
        for never in ["eval", "$L;", "`", "rm ", "> /", ">>", "source ", ". /"] {
            assert!(!cmd.contains(never), "{never:?}");
        }
        assert_eq!(
            cmd.matches("$L").count(),
            1,
            "the line is used once, in the case"
        );
        let keep = helper_command(77, Path::new("/private/tmp/x"), true).unwrap();
        assert!(keep.contains("0) /usr/bin/pmset -a disablesleep 1; ON=0;;"));
        assert!(
            keep.contains("/usr/bin/pmset -a disablesleep 1) >/dev/null"),
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
                helper_command(1, Path::new(bad), false),
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
        assert_eq!(helper_command(1, p, false), Err(LidError::UnsafePath));
    }

    #[test]
    fn admin_script_wraps_the_command_and_asks_for_privileges() {
        let script =
            admin_script(9, &pipe_path(Path::new("/private/tmp"), 501, 9, 0), false).unwrap();
        assert!(script.starts_with("do shell script \"S=$(/bin/ps -o lstart= -p 9);"));
        assert!(script.ends_with("with administrator privileges"));
        assert!(script.contains("with prompt \"LiteNotch needs permission"));
        // The shell's double quotes are escaped for AppleScript.
        assert!(script.contains("[ -n \\\"$S\\\" ]"));
    }

    // The tests below run the real loop without root: `pmset` is swapped
    // for a line appended to a log, and the 30 s tick for 2 s.

    struct Fixture {
        dir: PathBuf,
        pipe: PathBuf,
        log: PathBuf,
    }

    impl Fixture {
        fn new(name: &str) -> Fixture {
            let dir =
                std::env::temp_dir().join(format!("litenotch-lid-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            Fixture {
                pipe: dir.join("pipe"),
                log: dir.join("log"),
                dir,
            }
        }

        /// The helper command for `pid`, made runnable without root.
        fn command(&self, pid: u32, max_secs: u32) -> String {
            let log = self.log.to_str().unwrap();
            helper_command(pid, Path::new("/private/tmp/PIPE"), false)
                .unwrap()
                .replace("/private/tmp/PIPE", self.pipe.to_str().unwrap())
                .replace(
                    "/usr/bin/pmset -a disablesleep 1",
                    &format!("echo on >> {log}"),
                )
                .replace(
                    "/usr/bin/pmset -a disablesleep 0",
                    &format!("echo off >> {log}"),
                )
                .replace("-t 30 ", "-t 2 ")
                .replace("-ge 29 ]", "-ge 1 ]")
                .replace("-lt 43800 ]", &format!("-lt {max_secs} ]"))
        }

        fn start(&self, pid: u32) {
            let cmd = self.command(pid, 43800);
            crate::script::run("/bin/sh", &["-c", &cmd], Duration::from_secs(5)).unwrap();
        }

        fn log(&self) -> Vec<String> {
            std::fs::read_to_string(&self.log)
                .unwrap_or_default()
                .lines()
                .map(str::to_owned)
                .collect()
        }

        /// Waits until the log is exactly `want`.
        fn expect(&self, want: &[&str]) {
            let deadline = std::time::Instant::now() + Duration::from_secs(8);
            while self.log() != want && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(50));
            }
            assert_eq!(self.log(), want);
        }

        /// The log stays `want` for a while: nothing more happens.
        fn stays(&self, want: &[&str]) {
            std::thread::sleep(Duration::from_millis(600));
            assert_eq!(self.log(), want);
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// Reported: closed-lid mode asked for the password every time it was
    /// turned on. One helper now serves any number of off/on switches.
    #[test]
    fn one_helper_turns_the_mode_off_and_on_again_without_a_new_prompt() {
        let fx = Fixture::new("toggle");
        let helper = Helper::create(fx.pipe.clone()).unwrap();
        fx.start(std::process::id());
        fx.expect(&["on"]);
        fx.stays(&["on"]);
        helper.send(false).unwrap();
        fx.expect(&["on", "off"]);
        helper.send(true).unwrap();
        fx.expect(&["on", "off", "on"]);
        // A guard is the mode being on: dropping it turns it off, the helper stays.
        let helper = Arc::new(helper);
        drop(LidGuard {
            helper: Arc::clone(&helper),
        });
        fx.expect(&["on", "off", "on", "off"]);
        helper.send(true).unwrap();
        fx.expect(&["on", "off", "on", "off", "on"]);
        // LiteNotch letting go of the pipe (quitting, crashing) restores sleep at once.
        let pipe = fx.pipe.clone();
        drop(helper);
        fx.expect(&["on", "off", "on", "off", "on", "off"]);
        assert!(!pipe.exists(), "the pipe's name is removed with the helper");
        fx.stays(&["on", "off", "on", "off", "on", "off"]);
    }

    #[test]
    fn the_helper_restores_when_the_process_is_gone_even_if_the_pipe_stays_open() {
        let fx = Fixture::new("process");
        // This test holds the pipe, standing in for some other process doing so.
        let _held = Helper::create(fx.pipe.clone()).unwrap();
        let mut child = std::process::Command::new("/bin/sleep")
            .arg("30")
            .spawn()
            .unwrap();
        fx.start(child.id());
        fx.expect(&["on"]);
        fx.stays(&["on"]);
        child.kill().unwrap();
        child.wait().unwrap();
        // Noticed at the next tick (2 s here, 30 s for real).
        fx.expect(&["on", "off"]);
    }

    #[test]
    fn the_helper_refuses_to_start_for_a_dead_process_or_without_a_pipe() {
        let fx = Fixture::new("dead");
        let _held = Helper::create(fx.pipe.clone()).unwrap();
        let mut child = std::process::Command::new("/usr/bin/true").spawn().unwrap();
        let pid = child.id();
        child.wait().unwrap();
        let failed = |cmd: &str| {
            matches!(
                crate::script::run("/bin/sh", &["-c", cmd], Duration::from_secs(5)),
                Err(crate::script::ScriptError::Failed { code: Some(1), .. })
            )
        };
        assert!(failed(&fx.command(pid, 43800)));
        // A plain file where the pipe should be is not read.
        let plain = Fixture::new("plain");
        std::fs::write(&plain.pipe, b"1\n1\n1\n").unwrap();
        assert!(failed(&plain.command(std::process::id(), 43800)));
        assert!(fx.log().is_empty() && plain.log().is_empty());
    }

    #[test]
    fn anything_but_a_command_ends_the_helper_with_sleep_restored() {
        for junk in [
            &b"2\n"[..],
            b"11\n",
            b"\n",
            b"on\n",
            b"1; id\n",
            b"\0\0\0\0\0\0\0\0",
        ] {
            let fx = Fixture::new("junk");
            let helper = Helper::create(fx.pipe.clone()).unwrap();
            fx.start(std::process::id());
            fx.expect(&["on"]);
            helper.writer.lock().unwrap().write_all(junk).unwrap();
            fx.expect(&["on", "off"]);
            // It is gone: a command after that does nothing.
            helper.send(true).unwrap();
            fx.stays(&["on", "off"]);
        }
    }

    #[test]
    fn a_stretch_with_sleep_disabled_is_capped() {
        let fx = Fixture::new("cap");
        let _helper = Helper::create(fx.pipe.clone()).unwrap();
        // Four seconds instead of 12 hours and 10 minutes.
        let cmd = fx.command(std::process::id(), 4);
        crate::script::run("/bin/sh", &["-c", &cmd], Duration::from_secs(5)).unwrap();
        fx.expect(&["on"]);
        std::thread::sleep(Duration::from_millis(1500));
        assert_eq!(fx.log(), ["on"], "not before the cap");
        fx.expect(&["on", "off"]);
    }

    /// From review: every `1` restarted the count, so a process repeating it
    /// could keep sleep disabled past the cap.
    #[test]
    fn repeating_the_on_command_does_not_stretch_the_cap() {
        let fx = Fixture::new("cap-repeat");
        let helper = Helper::create(fx.pipe.clone()).unwrap();
        // A cap of six seconds.
        let cmd = fx.command(std::process::id(), 6);
        crate::script::run("/bin/sh", &["-c", &cmd], Duration::from_secs(5)).unwrap();
        fx.expect(&["on"]);
        let started = std::time::Instant::now();
        // A `1` every 1.5 s, more often than the 2 s tick, so `read` never
        // times out. Each is acted on (logged) but none restarts the clock.
        while fx.log().last().map(String::as_str) != Some("off")
            && started.elapsed() < Duration::from_secs(20)
        {
            helper.send(true).unwrap();
            std::thread::sleep(Duration::from_millis(1500));
        }
        assert_eq!(fx.log().last().map(String::as_str), Some("off"));
        assert!(
            started.elapsed() < Duration::from_secs(20),
            "the helper must stop by itself: {:?}",
            fx.log()
        );
    }

    /// From review: the flag was set before the pipe was opened, so a pipe
    /// that vanished in between left sleep disabled with no helper.
    #[test]
    fn a_pipe_that_cannot_be_opened_changes_nothing() {
        let fx = Fixture::new("no-open");
        let _held = Helper::create(fx.pipe.clone()).unwrap();
        // The check passes, then the pipe is gone when it is opened.
        let cmd = fx.command(std::process::id(), 43800).replace(
            "|| exit 1; exec 3<",
            &format!("|| exit 1; /bin/rm {}; exec 3<", fx.pipe.display()),
        );
        assert!(crate::script::run("/bin/sh", &["-c", &cmd], Duration::from_secs(5)).is_err());
        fx.stays(&[]);
    }

    #[test]
    fn creating_a_helper_never_adopts_what_is_already_there() {
        use std::os::unix::fs::{FileTypeExt, PermissionsExt};
        let fx = Fixture::new("create");
        std::fs::write(&fx.pipe, b"1\n").unwrap();
        let helper = Helper::create(fx.pipe.clone()).unwrap();
        let meta = std::fs::metadata(&fx.pipe).unwrap();
        assert!(meta.file_type().is_fifo());
        assert_eq!(meta.permissions().mode() & 0o777, 0o600);
        drop(helper);
        assert!(!fx.pipe.exists());
        // A directory in the way is an error, not something to write into.
        std::fs::create_dir(&fx.pipe).unwrap();
        assert!(matches!(
            Helper::create(fx.pipe.clone()),
            Err(LidError::Io(_))
        ));
    }

    #[test]
    fn stale_pipes_of_this_user_are_removed_but_others_are_kept() {
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
            "own pipes are kept"
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
        let pipe = pipe_path(&dir, current_uid(), std::process::id(), 0);
        if cfg!(target_os = "macos") {
            let mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o700, "{dir:?} must not be writable by other users");
            assert!(helper_command(1, &pipe, false).is_ok(), "{pipe:?}");
        }
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
