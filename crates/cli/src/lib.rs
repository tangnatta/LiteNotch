//! The `litenotch` command.
//!
//! `hook` and `statusline` are run by Claude Code, possibly many times a
//! minute, so they must never get in its way: if the app is not running or
//! anything goes wrong they print nothing and exit 0, which leaves Claude
//! Code behaving exactly as if LiteNotch were not installed.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::time::Duration;

use litenotch_core::agent::connector::{self, Agent};
use litenotch_core::ipc::{self, Request, Response, MAX_REQUEST_BYTES};
use litenotch_core::notify::Priority;
use litenotch_files::hooks_file::{self, AgentDirs};
use serde_json::Value;

pub const USAGE: &str = "\
litenotch — companion for the LiteNotch app

USAGE:
  litenotch notify <title> [body] [--priority low|normal|high] [--source NAME]
                   [--group KEY] [--ttl SECONDS]
  litenotch status                 Show what the notch is doing (JSON)
  litenotch hooks install [--agent A]    Register LiteNotch with a coding agent
  litenotch hooks uninstall [--agent A]  Remove it again
  litenotch hooks status [--agent A]     Say whether it is registered
                                   A: claude (default), codex, gemini,
                                   antigravity, or all (those installed)
  litenotch statusline [-- CMD…]   Claude Code status line; feeds usage to the
                                   notch and prints it (after CMD's output)
  litenotch hook [--agent A [--event E]]
                                   Hook entry point (reads stdin); Claude Code
                                   unless --agent says which agent is calling
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
    /// `CODEX_HOME`: Codex's configuration directory.
    pub codex_dir: Option<String>,
    /// Path of this executable, as registered in hooks.
    pub exe: String,
    /// `__CFBundleIdentifier`: the app this process was started from (the
    /// terminal or editor running Claude Code), so the notch can bring it
    /// forward.
    pub app: Option<String>,
    /// The terminal device this process runs on (`ttys003`), so the notch
    /// can bring that window forward and not just the app.
    pub tty: Option<String>,
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
            codex_dir: std::env::var("CODEX_HOME").ok().filter(|s| !s.is_empty()),
            exe: std::env::current_exe()
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|_| "litenotch".to_string()),
            app: std::env::var("__CFBundleIdentifier")
                .ok()
                .filter(|s| !s.is_empty()),
            tty: controlling_tty(),
        }
    }

    fn socket_path(&self) -> String {
        self.socket
            .clone()
            .unwrap_or_else(|| ipc::socket_path(&ipc::data_dir(&self.home)))
    }

    fn dirs(&self) -> AgentDirs {
        AgentDirs::new(
            &self.home,
            self.claude_dir.as_deref(),
            self.codex_dir.as_deref(),
        )
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
        Some("hook") => hook(env, &rest, stdin, stdout),
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

/// The terminal device of this process, or of the nearest ancestor that has
/// one: Claude Code may run a hook without a terminal of its own, but it sits
/// in the tab's. Two or three system calls; no process is started.
#[cfg(target_os = "macos")]
pub fn controlling_tty() -> Option<String> {
    use std::ffi::{c_char, c_int, c_void, CStr};
    extern "C" {
        fn devname_r(
            dev: libc::dev_t,
            mode: libc::mode_t,
            buf: *mut c_char,
            len: c_int,
        ) -> *mut c_char;
    }
    const NO_DEVICE: u32 = u32::MAX;
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as c_int;
    let mut pid = std::process::id() as c_int;
    for _ in 0..8 {
        // SAFETY: an all-zero `proc_bsdinfo` is a valid value of this plain C struct.
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        // SAFETY: the buffer is a `proc_bsdinfo` and `size` is its size.
        let n = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                (&mut info as *mut libc::proc_bsdinfo).cast::<c_void>(),
                size,
            )
        };
        if n != size {
            return None;
        }
        if info.e_tdev != NO_DEVICE && info.e_tdev != 0 {
            let mut buf = [0 as c_char; 64];
            // SAFETY: `buf` is writable for the length passed.
            let name = unsafe {
                devname_r(
                    info.e_tdev as libc::dev_t,
                    libc::S_IFCHR,
                    buf.as_mut_ptr(),
                    buf.len() as c_int,
                )
            };
            if name.is_null() {
                return None;
            }
            // SAFETY: `devname_r` wrote a NUL-terminated name into `buf`.
            let name = unsafe { CStr::from_ptr(buf.as_ptr()) }.to_str().ok()?;
            return litenotch_core::agent::valid_tty(name).then(|| name.to_owned());
        }
        if info.pbi_ppid <= 1 {
            return None;
        }
        pid = info.pbi_ppid as c_int;
    }
    None
}

#[cfg(not(target_os = "macos"))]
pub fn controlling_tty() -> Option<String> {
    None
}

/// The value after `name` in `rest` (`--agent codex`).
fn option<'a>(rest: &[&'a str], name: &str) -> Option<&'a str> {
    rest.iter()
        .position(|a| *a == name)
        .and_then(|i| rest.get(i + 1).copied())
}

fn hook(env: &Env, rest: &[&str], stdin: &mut dyn Read, stdout: &mut dyn Write) -> i32 {
    let agent = match option(rest, "--agent") {
        None => Agent::Claude,
        Some(flag) => match Agent::from_flag(flag) {
            Some(agent) => agent,
            None => return 0,
        },
    };
    let event = option(rest, "--event");
    // Whatever happens below, an agent that insists on an answer gets one.
    let say_default = |stdout: &mut dyn Write| {
        if let Some(output) = connector::default_output(agent, event) {
            let _ = writeln!(stdout, "{output}");
        }
    };
    let Some(payload) = read_input(stdin) else {
        say_default(stdout);
        return 0;
    };
    let Some(mut payload) = connector::normalize(agent, event, &payload) else {
        say_default(stdout);
        return 0;
    };
    // Only this process's own app may be named; a value already in the
    // payload is never passed on.
    if let Some(obj) = payload.as_object_mut() {
        obj.remove("litenotch_app");
        obj.remove("litenotch_tty");
        if let Some(app) = &env.app {
            obj.insert("litenotch_app".into(), Value::String(app.clone()));
        }
        if let Some(tty) = &env.tty {
            obj.insert("litenotch_tty".into(), Value::String(tty.clone()));
        }
    }
    let is_permission =
        payload.get("hook_event_name").and_then(Value::as_str) == Some("PermissionRequest");
    let wait = if is_permission {
        APPROVAL_WAIT
    } else {
        QUICK_WAIT
    };
    let output = match exchange(env, &Request::Hook { payload }, wait) {
        Ok(Response::Decision { decision }) => connector::decision_output(agent, decision),
        Ok(Response::Answer { updated_input }) => connector::answer_output(agent, &updated_input),
        _ => None,
    };
    match output {
        Some(output) => {
            let _ = writeln!(stdout, "{output}");
        }
        None => say_default(stdout),
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

/// The agents a `hooks` command acts on: `--agent`, or Claude Code. `all`
/// means every agent that looks installed.
fn hook_agents(env: &Env, rest: &[&str]) -> Result<Vec<Agent>, String> {
    match option(rest, "--agent") {
        None => Ok(vec![Agent::Claude]),
        Some("all") => {
            let dirs = env.dirs();
            let found: Vec<Agent> = Agent::ALL
                .into_iter()
                .filter(|a| dirs.present(*a))
                .collect();
            if found.is_empty() {
                Err("no supported coding agent found".to_string())
            } else {
                Ok(found)
            }
        }
        Some(flag) => Agent::from_flag(flag).map(|a| vec![a]).ok_or_else(|| {
            format!("unknown agent '{flag}' (use claude, codex, gemini, antigravity or all)")
        }),
    }
}

fn hooks(env: &Env, rest: &[&str], stdout: &mut dyn Write, stderr: &mut dyn Write) -> i32 {
    let Some(action) = rest.first().copied() else {
        let _ = writeln!(
            stderr,
            "litenotch hooks: expected install, uninstall or status"
        );
        return 2;
    };
    if !["install", "uninstall", "status"].contains(&action) {
        let _ = writeln!(
            stderr,
            "litenotch hooks: expected install, uninstall or status"
        );
        return 2;
    }
    let agents = match hook_agents(env, &rest[1..]) {
        Ok(agents) => agents,
        Err(message) => {
            let _ = writeln!(stderr, "litenotch hooks: {message}");
            return 2;
        }
    };
    let dirs = env.dirs();
    // Without --agent the messages are the ones Claude Code's alone had.
    let plain = option(&rest[1..], "--agent").is_none();
    let mut code = 0;
    for agent in agents {
        let path = dirs.config_path(agent).display().to_string();
        let name = agent.name();
        match action {
            "install" => match hooks_file::install_agent(&dirs, agent, &env.exe) {
                Ok(()) => {
                    let note = if agent.can_approve() {
                        ""
                    } else {
                        " (status only: it has no approval hook for the notch)"
                    };
                    let _ = if plain {
                        writeln!(
                            stdout,
                            "Hooks registered in {path}. New Claude Code sessions will use them."
                        )
                    } else {
                        writeln!(
                            stdout,
                            "Hooks registered for {name} in {path}. New sessions will use them{note}."
                        )
                    };
                }
                Err(e) => {
                    let _ = writeln!(stderr, "litenotch hooks: {name}: {e}");
                    code = 1;
                }
            },
            "uninstall" => match hooks_file::uninstall_agent(&dirs, agent, &env.exe) {
                Ok(()) => {
                    let _ = if plain {
                        writeln!(stdout, "Hooks removed from {path}.")
                    } else {
                        writeln!(stdout, "Hooks removed for {name} from {path}.")
                    };
                }
                Err(e) => {
                    let _ = writeln!(stderr, "litenotch hooks: {name}: {e}");
                    code = 1;
                }
            },
            _ => match hooks_file::agent_installed(&dirs, agent, &env.exe) {
                Some(true) => {
                    let _ = if plain {
                        writeln!(stdout, "installed")
                    } else {
                        writeln!(stdout, "{name}: installed")
                    };
                }
                Some(false) => {
                    let _ = if plain {
                        writeln!(stdout, "not installed")
                    } else {
                        writeln!(stdout, "{name}: not installed")
                    };
                    code = 1;
                }
                None => {
                    let _ = writeln!(stderr, "litenotch hooks: cannot read {path}");
                    code = 1;
                }
            },
        }
    }
    code
}
