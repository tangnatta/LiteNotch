//! The `litenotch` command.
//!
//! `hook` and `statusline` are run by Claude Code, possibly many times a
//! minute, so they must never get in its way: if the app is not running or
//! anything goes wrong they print nothing and exit 0, which leaves Claude
//! Code behaving exactly as if LiteNotch were not installed.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Duration;

use litenotch_core::agent::decision_output;
use litenotch_core::ipc::{self, Request, Response, MAX_REQUEST_BYTES};
use litenotch_core::notify::Priority;
use litenotch_files::hooks_file;
use serde_json::Value;

pub const USAGE: &str = "\
litenotch — companion for the LiteNotch app

USAGE:
  litenotch notify <title> [body] [--priority low|normal|high] [--source NAME]
                   [--group KEY] [--ttl SECONDS]
  litenotch status                 Show what the notch is doing (JSON)
  litenotch hooks install          Register LiteNotch in ~/.claude/settings.json
  litenotch hooks uninstall        Remove it again
  litenotch hooks status           Say whether it is registered
  litenotch statusline [-- CMD…]   Claude Code status line; feeds usage to the
                                   notch and prints it (after CMD's output)
  litenotch hook                   Claude Code hook entry point (reads stdin)
";

/// Longest wait for an approval: just under the 130 s hook timeout, after
/// which Claude Code would kill this process anyway.
const APPROVAL_WAIT: Duration = Duration::from_secs(125);
const QUICK_WAIT: Duration = Duration::from_secs(2);

pub struct Env {
    pub home: String,
    /// `LITENOTCH_SOCKET`: talk to this socket instead of the default one.
    pub socket: Option<String>,
    /// `CLAUDE_CONFIG_DIR`: Claude Code's configuration directory.
    pub claude_dir: Option<String>,
    /// Path of this executable, as registered in hooks.
    pub exe: String,
    /// `__CFBundleIdentifier`: the app this process was started from (the
    /// terminal or editor running Claude Code), so the notch can bring it
    /// forward.
    pub app: Option<String>,
}

impl Env {
    pub fn from_process() -> Env {
        Env {
            home: std::env::var("HOME").unwrap_or_default(),
            socket: std::env::var("LITENOTCH_SOCKET")
                .ok()
                .filter(|s| !s.is_empty()),
            claude_dir: std::env::var("CLAUDE_CONFIG_DIR")
                .ok()
                .filter(|s| !s.is_empty()),
            exe: std::env::current_exe()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| "litenotch".to_string()),
            app: std::env::var("__CFBundleIdentifier")
                .ok()
                .filter(|s| !s.is_empty()),
        }
    }

    fn socket_path(&self) -> String {
        self.socket
            .clone()
            .unwrap_or_else(|| ipc::socket_path(&ipc::data_dir(&self.home)))
    }

    fn claude_dir(&self) -> PathBuf {
        match &self.claude_dir {
            Some(dir) => PathBuf::from(dir),
            None => PathBuf::from(&self.home).join(".claude"),
        }
    }
}

/// Sends one request and waits up to `wait` for the reply.
fn exchange(env: &Env, request: &Request, wait: Duration) -> Result<Response, String> {
    let mut stream = UnixStream::connect(env.socket_path())
        .map_err(|_| "LiteNotch is not running".to_string())?;
    // An Allow must come from the user's own LiteNotch, not from whoever
    // owns the socket a stray LITENOTCH_SOCKET points at.
    if !peer_is_current_user(&stream) {
        return Err("the socket belongs to another user".to_string());
    }
    stream
        .set_write_timeout(Some(QUICK_WAIT))
        .map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(wait))
        .map_err(|e| e.to_string())?;
    stream
        .write_all(request.to_line().as_bytes())
        .map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(stream)
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;
    if line.is_empty() {
        return Err("LiteNotch closed the connection".to_string());
    }
    Response::parse(&line)
}

#[cfg(any(target_os = "macos", target_os = "freebsd"))]
fn peer_is_current_user(stream: &UnixStream) -> bool {
    use std::os::fd::AsRawFd;
    extern "C" {
        fn getpeereid(fd: i32, uid: *mut u32, gid: *mut u32) -> i32;
        fn geteuid() -> u32;
    }
    let (mut uid, mut gid) = (u32::MAX, u32::MAX);
    // SAFETY: the descriptor is open for the lifetime of `stream`, and both
    // out-pointers are valid for writes.
    let ok = unsafe { getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } == 0;
    // SAFETY: geteuid has no preconditions.
    ok && uid == unsafe { geteuid() }
}

#[cfg(not(any(target_os = "macos", target_os = "freebsd")))]
fn peer_is_current_user(_stream: &UnixStream) -> bool {
    true
}

fn read_input(stdin: &mut dyn Read) -> Option<Value> {
    let mut text = String::new();
    stdin
        .take(MAX_REQUEST_BYTES as u64)
        .read_to_string(&mut text)
        .ok()?;
    serde_json::from_str(&text).ok()
}

pub fn run(
    args: &[String],
    env: &Env,
    stdin: &mut dyn Read,
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> i32 {
    let rest: Vec<&str> = args.iter().skip(1).map(String::as_str).collect();
    match args.first().map(String::as_str) {
        Some("hook") => hook(env, stdin, stdout),
        Some("statusline") => statusline(env, &rest, stdin, stdout),
        Some("notify") => notify(env, &rest, stdout, stderr),
        Some("status") => status(env, stdout, stderr),
        Some("hooks") => hooks(env, &rest, stdout, stderr),
        Some("help" | "--help" | "-h") | None => {
            let _ = stdout.write_all(USAGE.as_bytes());
            0
        }
        Some(other) => {
            let _ = writeln!(stderr, "litenotch: unknown command '{other}'\n\n{USAGE}");
            2
        }
    }
}

fn hook(env: &Env, stdin: &mut dyn Read, stdout: &mut dyn Write) -> i32 {
    let Some(mut payload) = read_input(stdin) else {
        return 0;
    };
    // Only this process's own app may be named; a value already in the
    // payload is never passed on.
    if let Some(obj) = payload.as_object_mut() {
        obj.remove("litenotch_app");
        if let Some(app) = &env.app {
            obj.insert("litenotch_app".into(), Value::String(app.clone()));
        }
    }
    let is_permission =
        payload.get("hook_event_name").and_then(Value::as_str) == Some("PermissionRequest");
    let wait = if is_permission {
        APPROVAL_WAIT
    } else {
        QUICK_WAIT
    };
    if let Ok(Response::Decision { decision }) = exchange(env, &Request::Hook { payload }, wait) {
        if let Some(output) = decision_output(decision) {
            let _ = writeln!(stdout, "{output}");
        }
    }
    0
}

fn statusline(env: &Env, rest: &[&str], stdin: &mut dyn Read, stdout: &mut dyn Write) -> i32 {
    let mut input = String::new();
    let _ = stdin
        .take(MAX_REQUEST_BYTES as u64)
        .read_to_string(&mut input);
    let ours = serde_json::from_str::<Value>(&input)
        .ok()
        .and_then(|payload| exchange(env, &Request::Statusline { payload }, QUICK_WAIT).ok())
        .and_then(|response| match response {
            Response::Statusline { text } if !text.is_empty() => Some(text),
            _ => None,
        });
    // `-- CMD ARGS…` wraps the status line the user already had.
    let wrapped = match rest.split_first() {
        Some((&"--", command)) if !command.is_empty() => run_wrapped(command, &input),
        _ => None,
    };
    let line = match (wrapped, ours) {
        (Some(theirs), Some(ours)) => format!("{theirs} │ {ours}"),
        (Some(theirs), None) => theirs,
        (None, Some(ours)) => ours,
        (None, None) => String::new(),
    };
    if !line.is_empty() {
        let _ = writeln!(stdout, "{line}");
    }
    0
}

/// Longest the user's own status line command may take.
const WRAPPED_TIMEOUT: Duration = Duration::from_secs(3);

/// Runs the user's own status line command with the same input.
fn run_wrapped(command: &[&str], input: &str) -> Option<String> {
    let mut child = Command::new(command[0])
        .args(&command[1..])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    // Feed stdin and collect stdout on their own threads so neither a full
    // pipe nor a command that never exits can hang the status line.
    if let Some(mut stdin) = child.stdin.take() {
        let input = input.to_owned();
        std::thread::spawn(move || {
            let _ = stdin.write_all(input.as_bytes());
        });
    }
    let stdout = child.stdout.take()?;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout
            .take(MAX_REQUEST_BYTES as u64)
            .read_to_string(&mut text);
        let _ = tx.send(text);
    });
    let text = rx.recv_timeout(WRAPPED_TIMEOUT).ok();
    let _ = child.kill();
    let _ = child.wait();
    let text = text?.trim_end().to_string();
    (!text.is_empty()).then_some(text)
}

fn notify(env: &Env, rest: &[&str], stdout: &mut dyn Write, stderr: &mut dyn Write) -> i32 {
    let mut positional = Vec::new();
    let (mut priority, mut source, mut group, mut ttl_secs) =
        (Priority::Normal, String::new(), None, None);
    let mut args = rest.iter();
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().copied().ok_or(format!("{name} needs a value"));
        let parsed = match *arg {
            "--priority" => value("--priority").and_then(|v| {
                priority = match v {
                    "low" => Priority::Low,
                    "normal" => Priority::Normal,
                    "high" => Priority::High,
                    other => {
                        return Err(format!(
                            "unknown priority '{other}' (use low, normal or high)"
                        ))
                    }
                };
                Ok(())
            }),
            "--source" => value("--source").map(|v| source = v.to_string()),
            "--group" => value("--group").map(|v| group = Some(v.to_string())),
            "--ttl" => value("--ttl").and_then(|v| {
                v.parse::<u32>()
                    .map(|n| ttl_secs = Some(n))
                    .map_err(|_| format!("--ttl needs a number of seconds, got '{v}'"))
            }),
            flag if flag.starts_with("--") => Err(format!("unknown option '{flag}'")),
            text => {
                positional.push(text);
                Ok(())
            }
        };
        if let Err(message) = parsed {
            let _ = writeln!(stderr, "litenotch notify: {message}");
            return 2;
        }
    }
    let (title, body) = match positional.as_slice() {
        [title] => (title.to_string(), String::new()),
        [title, body] => (title.to_string(), body.to_string()),
        _ => {
            let _ = writeln!(
                stderr,
                "litenotch notify: expected a title and an optional body"
            );
            return 2;
        }
    };
    let request = Request::Notify {
        title,
        body,
        source,
        priority,
        group,
        ttl_secs,
    };
    match exchange(env, &request, QUICK_WAIT) {
        Ok(Response::Ok) => {
            let _ = writeln!(stdout, "sent");
            0
        }
        Ok(Response::Error { message }) | Err(message) => {
            let _ = writeln!(stderr, "litenotch notify: {message}");
            1
        }
        Ok(_) => {
            let _ = writeln!(stderr, "litenotch notify: unexpected reply");
            1
        }
    }
}

fn status(env: &Env, stdout: &mut dyn Write, stderr: &mut dyn Write) -> i32 {
    match exchange(env, &Request::Status, QUICK_WAIT) {
        Ok(Response::Status { view }) => {
            let text = serde_json::to_string_pretty(&view).unwrap_or_default();
            let _ = writeln!(stdout, "{text}");
            0
        }
        Ok(_) => {
            let _ = writeln!(stderr, "litenotch status: unexpected reply");
            1
        }
        Err(message) => {
            let _ = writeln!(stderr, "litenotch status: {message}");
            1
        }
    }
}

fn hooks(env: &Env, rest: &[&str], stdout: &mut dyn Write, stderr: &mut dyn Write) -> i32 {
    let dir = env.claude_dir();
    let settings = hooks_file::settings_path(&dir);
    let result = match rest {
        ["install"] => hooks_file::install_hooks(&dir, &env.exe).map(|()| {
            format!(
                "Hooks registered in {}. New Claude Code sessions will use them.",
                settings.display()
            )
        }),
        ["uninstall"] => hooks_file::uninstall_hooks(&dir, &env.exe)
            .map(|()| format!("Hooks removed from {}.", settings.display())),
        ["status"] => {
            return match hooks_file::installed(&dir, &env.exe) {
                Some(true) => {
                    let _ = writeln!(stdout, "installed");
                    0
                }
                Some(false) => {
                    let _ = writeln!(stdout, "not installed");
                    1
                }
                None => {
                    let _ = writeln!(
                        stderr,
                        "litenotch hooks: cannot read {}",
                        settings.display()
                    );
                    1
                }
            };
        }
        _ => {
            let _ = writeln!(
                stderr,
                "litenotch hooks: expected install, uninstall or status"
            );
            return 2;
        }
    };
    match result {
        Ok(message) => {
            let _ = writeln!(stdout, "{message}");
            0
        }
        Err(e) => {
            let _ = writeln!(stderr, "litenotch hooks: {e}");
            1
        }
    }
}
