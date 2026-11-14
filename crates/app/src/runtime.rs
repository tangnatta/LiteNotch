//! The event loop. One thread owns the core, applies inputs, performs the
//! resulting effects, and pushes the view model to the shell when it
//! changes. Between events it sleeps until the next deadline, so an idle
//! app does nothing but check the pasteboard change counter.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::Duration;

use litenotch_core::agent::{Decision, HookOutcome};
use litenotch_core::ipc::{Request, Response};
use litenotch_core::media::parse_helper_line;
use litenotch_core::notify::{NotificationInput, Priority};
use litenotch_core::state::{Command, Core, Effect, Input};
use litenotch_core::usage::{statusline_text, UsageRecord};
use serde::Deserialize;

use crate::clock::SteadyClock;
use crate::ports::Ports;
use crate::server::{Server, ServerEvent};
use crate::transcripts::{day_start_ms, TranscriptScanner};
use crate::{hooks_file, store};

/// How long a change may sit in memory before it is written to disk.
const SAVE_DEBOUNCE_MS: u64 = 2_000;
const POWER_POLL_MS: u64 = 30_000;
/// Transcripts are re-read at most this often, and only after agent activity.
const TRANSCRIPT_MIN_INTERVAL_MS: u64 = 30_000;
/// Longest the loop sleeps, so the clock notices the Mac waking from sleep.
const MAX_SLEEP_MS: u64 = 60_000;

pub struct Config {
    /// Directory for saved state and the socket.
    pub dir: PathBuf,
    /// Claude Code's configuration directory (normally `~/.claude`).
    pub claude_dir: PathBuf,
    /// Absolute path of the `litenotch` CLI, as registered in hooks.
    pub cli_path: String,
    pub serve_socket: bool,
    pub clipboard_poll_ms: u64,
}

/// Where the now-playing helper writes artwork, inside the data directory.
pub fn artwork_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("artwork")
}

/// Where copied images are saved, inside the data directory.
pub fn clips_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("clips")
}

impl Config {
    pub fn socket_path(&self) -> PathBuf {
        PathBuf::from(litenotch_core::ipc::socket_path(
            &self.dir.to_string_lossy(),
        ))
    }
}

/// Commands the shell can send: the core's commands plus the few that need
/// file access.
#[derive(Debug, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
enum ShellCommand {
    HooksInstall,
    HooksUninstall,
    /// Route Claude Code's status line through LiteNotch (usage limits).
    StatuslineInstall,
    StatuslineUninstall,
    #[serde(untagged)]
    Core(Command),
}

enum Msg {
    Shell(ShellCommand),
    Server(ServerEvent),
    LidResult(bool),
    Transcripts {
        reset: bool,
        records: Vec<UsageRecord>,
    },
    NowPlaying(String),
    Lid(litenotch_platform::display::Clamshell),
    Stop,
}

pub struct Runtime {
    tx: Sender<Msg>,
    thread: Option<JoinHandle<()>>,
    _server: Option<Server>,
}

impl Runtime {
    /// Loads saved state and starts the loop. `on_view` receives the view
    /// model as JSON on the runtime thread each time it changes.
    pub fn start(
        config: Config,
        ports: Box<dyn Ports>,
        on_view: Box<dyn Fn(&str) + Send>,
    ) -> std::io::Result<Runtime> {
        store::ensure_dir(&config.dir)?;
        let (tx, rx) = mpsc::channel();
        let server = if config.serve_socket {
            let tx = tx.clone();
            Some(Server::start(&config.socket_path(), move |event| {
                let _ = tx.send(Msg::Server(event));
            })?)
        } else {
            None
        };
        let core = Core::new(store::load(&config.dir));
        let scan_tx = spawn_transcript_scanner(config.claude_dir.join("projects"), tx.clone());
        let mut state = Loop {
            core,
            ports,
            on_view,
            config,
            tx: tx.clone(),
            clock: SteadyClock::new(),
            waiters: HashMap::new(),
            last_view: String::new(),
            save_at: None,
            next_clip: 0,
            next_power: 0,
            watching_lid: false,
            scan_tx,
            last_scan: 0,
            scan_wanted: true,
            scanned_day: 0,
            now_playing_on: false,
            kept_files: None,
        };
        let thread = std::thread::Builder::new()
            .name("litenotch-core".into())
            .spawn(move || state.run(rx))?;
        Ok(Runtime {
            tx,
            thread: Some(thread),
            _server: server,
        })
    }

    /// Sends one shell command as JSON, e.g. `{"cmd":"pomodoro_toggle"}`.
    pub fn send(&self, json: &str) -> Result<(), String> {
        let command: ShellCommand = serde_json::from_str(json).map_err(|e| e.to_string())?;
        self.tx
            .send(Msg::Shell(command))
            .map_err(|_| "runtime stopped".to_string())
    }
}

impl Drop for Runtime {
    fn drop(&mut self) {
        let _ = self.tx.send(Msg::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Transcript files can be large, so they are read off the core thread.
fn spawn_transcript_scanner(projects_dir: PathBuf, tx: Sender<Msg>) -> Sender<u64> {
    let (scan_tx, scan_rx) = mpsc::channel::<u64>();
    let _ = std::thread::Builder::new()
        .name("litenotch-usage".into())
        .spawn(move || {
            let mut scanner = TranscriptScanner::new(projects_dir);
            while let Ok(day_start) = scan_rx.recv() {
                let scan = scanner.scan(day_start);
                if (scan.reset || !scan.records.is_empty())
                    && tx
                        .send(Msg::Transcripts {
                            reset: scan.reset,
                            records: scan.records,
                        })
                        .is_err()
                {
                    break;
                }
            }
        });
    scan_tx
}

struct Loop {
    core: Core,
    ports: Box<dyn Ports>,
    on_view: Box<dyn Fn(&str) + Send>,
    config: Config,
    tx: Sender<Msg>,
    clock: SteadyClock,
    /// Hook connections waiting for a decision, by request id.
    waiters: HashMap<String, (u64, Sender<Response>)>,
    last_view: String,
    save_at: Option<u64>,
    next_clip: u64,
    next_power: u64,
    /// The lid watcher has been asked to run.
    watching_lid: bool,
    scan_tx: Sender<u64>,
    last_scan: u64,
    scan_wanted: bool,
    /// Start of the day the transcript totals belong to.
    scanned_day: u64,
    /// The now-playing helper has been asked to run.
    now_playing_on: bool,
    /// Clipboard files last known to be referenced; `None` before the first
    /// check, so leftovers from an earlier run are removed at start.
    kept_files: Option<Vec<String>>,
}

impl Loop {
    fn run(&mut self, rx: Receiver<Msg>) {
        let now = self.clock.now_ms();
        self.refresh_hooks_installed(now);
        self.after_event(now);
        loop {
            let now = self.clock.now_ms();
            let timeout = self.sleep_ms(now);
            match rx.recv_timeout(Duration::from_millis(timeout)) {
                Ok(Msg::Stop) | Err(RecvTimeoutError::Disconnected) => break,
                Ok(msg) => {
                    let now = self.clock.now_ms();
                    self.handle(msg, now);
                }
                Err(RecvTimeoutError::Timeout) => {}
            }
            let now = self.clock.now_ms();
            self.poll(now);
            self.after_event(now);
        }
        // Leave nothing behind: release the system, answer waiting hooks, save.
        self.ports.disable_lid();
        self.ports
            .set_assertion(litenotch_core::caffeine::AwakeMode::Off);
        for (_, (_, reply)) in self.waiters.drain() {
            let _ = reply.send(Response::Decision {
                decision: Decision::Pass,
            });
        }
        let _ = store::save(&self.config.dir, &self.core.persisted());
        // History that is not kept across restarts leaves no files behind.
        if !self.core.settings().general.persist_clipboard {
            self.ports.prune_clip_files(&[]);
        }
    }

    fn clipboard_enabled(&self) -> bool {
        self.config.clipboard_poll_ms > 0 && self.core.settings().clipboard.enabled
    }

    fn sleep_ms(&self, now: u64) -> u64 {
        let mut wake = now.saturating_add(MAX_SLEEP_MS);
        if let Some(deadline) = self.core.next_deadline() {
            wake = wake.min(deadline);
        }
        if let Some(save_at) = self.save_at {
            wake = wake.min(save_at);
        }
        if self.clipboard_enabled() {
            wake = wake.min(self.next_clip);
        }
        if self.core.wants_power_updates() {
            wake = wake.min(self.next_power);
        }
        wake.saturating_sub(now)
    }

    fn poll(&mut self, now: u64) {
        if self.clipboard_enabled() && now >= self.next_clip {
            self.next_clip = now.saturating_add(self.config.clipboard_poll_ms);
            let core = &self.core;
            if let Some(capture) = self.ports.poll_clipboard(&|c| core.clip_would_keep(c)) {
                let had_file = capture.image_path.is_some() || capture.rich_path.is_some();
                self.apply(Input::ClipCaptured(capture), now);
                if had_file {
                    // A file was written; if the copy was then dropped (too
                    // large, empty), nothing refers to it: prune now.
                    self.kept_files = None;
                }
            }
        }
        if self.core.wants_power_updates() && now >= self.next_power {
            self.next_power = now.saturating_add(POWER_POLL_MS);
            if let Some(status) = self.ports.power() {
                self.apply(Input::Power(status), now);
            }
        }
        // A new day starts with empty token totals even without agent activity.
        let offset = self.core.settings().pomodoro.utc_offset_secs;
        let today = day_start_ms(now, offset);
        if self.scanned_day != today {
            self.scanned_day = today;
            self.scan_wanted = true;
            self.last_scan = 0;
        }
        if self.scan_wanted && now.saturating_sub(self.last_scan) >= TRANSCRIPT_MIN_INTERVAL_MS {
            self.scan_wanted = false;
            self.last_scan = now;
            let offset = self.core.settings().pomodoro.utc_offset_secs;
            let _ = self.scan_tx.send(day_start_ms(now, offset));
        }
    }

    fn handle(&mut self, msg: Msg, now: u64) {
        match msg {
            Msg::Shell(ShellCommand::Core(command)) => {
                let utc_changed = matches!(command, Command::SetUtcOffset { .. });
                // The battery guard decides on the last reading it saw, and
                // power is only polled while keep-awake is on. Read it now
                // so turning keep-awake on is judged on the current state.
                if matches!(
                    command,
                    Command::CaffeineToggle
                        | Command::CaffeineActivate { .. }
                        | Command::CaffeineLid { on: true }
                ) {
                    if let Some(status) = self.ports.power() {
                        self.apply(Input::Power(status), now);
                    }
                }
                self.apply(Input::Command(command), now);
                if utc_changed {
                    // Day boundaries moved: recount today's tokens.
                    self.scan_wanted = true;
                    self.last_scan = 0;
                }
            }
            Msg::Shell(ShellCommand::HooksInstall) => {
                let result =
                    hooks_file::install_hooks(&self.config.claude_dir, &self.config.cli_path);
                self.report_hooks(result, "Connected to Claude Code", now);
            }
            Msg::Shell(ShellCommand::HooksUninstall) => {
                let result =
                    hooks_file::uninstall_hooks(&self.config.claude_dir, &self.config.cli_path);
                self.report_hooks(result, "Disconnected from Claude Code", now);
            }
            Msg::Shell(ShellCommand::StatuslineInstall) => {
                let result = hooks_file::install_statusline_file(
                    &self.config.claude_dir,
                    &self.config.cli_path,
                );
                self.report_hooks(result, "Usage limits turned on", now);
            }
            Msg::Shell(ShellCommand::StatuslineUninstall) => {
                let result = hooks_file::uninstall_statusline_file(
                    &self.config.claude_dir,
                    &self.config.cli_path,
                );
                self.report_hooks(result, "Usage limits turned off", now);
            }
            Msg::Server(ServerEvent::Request {
                request,
                conn,
                reply,
            }) => {
                self.request(request, conn, reply, now);
            }
            Msg::Server(ServerEvent::Gone { conn }) => {
                // The hook was answered in the terminal or killed: withdraw
                // its request so the notch stops asking.
                let ids: Vec<String> = self
                    .waiters
                    .iter()
                    .filter(|(_, (c, _))| *c == conn)
                    .map(|(id, _)| id.clone())
                    .collect();
                for request_id in ids {
                    self.apply(
                        Input::Command(Command::AgentDecide {
                            request_id,
                            decision: Decision::Pass,
                        }),
                        now,
                    );
                }
            }
            Msg::LidResult(ok) => self.apply(Input::LidResult { ok }, now),
            Msg::Transcripts { reset, records } => {
                if reset {
                    self.apply(Input::UsageResetToday, now);
                }
                let offset = self.core.settings().pomodoro.utc_offset_secs;
                let day_start = day_start_ms(now, offset);
                let day_end = day_start.saturating_add(86_400_000);
                for record in records {
                    self.apply(
                        Input::UsageRecord {
                            record,
                            day_start_ms: day_start,
                            day_end_ms: day_end,
                        },
                        now,
                    );
                }
            }
            Msg::NowPlaying(line) => {
                if !self.now_playing_on {
                    return;
                }
                if let Some(mut playing) = parse_helper_line(&line, now) {
                    // The shell opens this file; only the helper's own
                    // artwork directory is acceptable.
                    let dir = artwork_dir(&self.config.dir);
                    if let Some(np) = playing.as_mut() {
                        np.artwork_path = np.artwork_path.take().filter(|path| {
                            let path = Path::new(path);
                            path.parent() == Some(dir.as_path())
                                && path
                                    .file_name()
                                    .is_some_and(|n| n.to_string_lossy().starts_with("art-"))
                        });
                    }
                    self.apply(Input::NowPlaying(playing), now);
                }
            }
            Msg::Lid(lid) => {
                if self.watching_lid {
                    // The moment it matters: if the helper has stopped, say
                    // so now instead of showing a mode that does nothing.
                    if lid.closed && !self.ports.lid_active() {
                        self.apply(Input::LidLost, now);
                        return;
                    }
                    self.apply(
                        Input::Clamshell {
                            closed: lid.closed,
                            external_display: lid.external_display,
                        },
                        now,
                    );
                }
            }
            Msg::Stop => {}
        }
    }

    /// Listens to the lid only while closed-lid mode needs it.
    fn sync_lid_watch(&mut self) {
        let wanted = self.core.wants_clamshell_updates();
        if wanted == self.watching_lid {
            return;
        }
        self.watching_lid = wanted;
        if wanted {
            let tx = self.tx.clone();
            self.ports.watch_lid(Some(Box::new(move |lid| {
                let _ = tx.send(Msg::Lid(lid));
            })));
        } else {
            self.ports.watch_lid(None);
        }
    }

    /// Starts or stops the now-playing helper to match the setting.
    fn sync_now_playing(&mut self, now: u64) {
        let wanted = self.core.settings().media.enabled;
        if wanted == self.now_playing_on {
            return;
        }
        self.now_playing_on = wanted;
        if wanted {
            let tx = self.tx.clone();
            self.ports.now_playing(Some(Box::new(move |line| {
                let _ = tx.send(Msg::NowPlaying(line));
            })));
        } else {
            self.ports.now_playing(None);
            self.apply(Input::NowPlaying(None), now);
        }
    }

    fn request(&mut self, request: Request, conn: u64, reply: Sender<Response>, now: u64) {
        match request {
            Request::Hook { payload } => {
                self.scan_wanted = true;
                let (outcome, effects) = self.core.hook(&payload.to_string(), now);
                match outcome {
                    HookOutcome::Pending(request_id) => {
                        self.waiters.insert(request_id, (conn, reply));
                    }
                    HookOutcome::Decided(decision) => {
                        let _ = reply.send(Response::Decision { decision });
                    }
                    HookOutcome::Ack => {
                        let _ = reply.send(Response::Ok);
                    }
                }
                self.perform(effects);
            }
            Request::Statusline { payload } => {
                self.scan_wanted = true;
                self.apply(Input::Statusline(payload.to_string()), now);
                let text = statusline_text(&self.core.view(now).usage);
                let _ = reply.send(Response::Statusline { text });
            }
            Request::Notify {
                title,
                body,
                source,
                priority,
                group,
                ttl_secs,
            } => {
                self.apply(
                    Input::ExternalNotify(NotificationInput {
                        source,
                        title,
                        body,
                        priority,
                        group,
                        ttl_secs,
                    }),
                    now,
                );
                let _ = reply.send(Response::Ok);
            }
            Request::Status => {
                let _ = reply.send(Response::Status {
                    view: self.status(now),
                });
            }
        }
    }

    /// What `litenotch status` shows. Clipboard and notification text stay
    /// out of it: the socket is for commands, not for reading user data.
    fn status(&self, now: u64) -> serde_json::Value {
        let view = self.core.view(now);
        serde_json::json!({
            "compact": view.compact,
            "pomodoro": view.pomodoro,
            "caffeine": view.caffeine,
            "usage": view.usage,
            "pending_approvals": view.agents.pending.len(),
            "sessions": view.agents.sessions.len(),
            "hooks_installed": view.agents.hooks_installed,
        })
    }

    fn report_hooks(
        &mut self,
        result: Result<(), hooks_file::HooksFileError>,
        done: &str,
        now: u64,
    ) {
        let (title, body, priority) = match result {
            Ok(()) => (
                done.to_string(),
                "Takes effect in new Claude Code sessions.".to_string(),
                Priority::Normal,
            ),
            Err(e) => (
                "Claude Code settings not changed".to_string(),
                e.to_string(),
                Priority::High,
            ),
        };
        self.refresh_hooks_installed(now);
        self.apply(
            Input::OwnNotify(NotificationInput {
                source: "litenotch".into(),
                title,
                body,
                priority,
                group: Some("hooks".into()),
                ttl_secs: None,
            }),
            now,
        );
    }

    fn refresh_hooks_installed(&mut self, now: u64) {
        let state = hooks_file::installed(&self.config.claude_dir, &self.config.cli_path);
        self.apply(Input::HooksInstalled(state), now);
        let state =
            hooks_file::statusline_installed(&self.config.claude_dir, &self.config.cli_path);
        self.apply(Input::StatuslineInstalled(state), now);
    }

    fn apply(&mut self, input: Input, now: u64) {
        let effects = self.core.apply(input, now);
        self.perform(effects);
    }

    fn perform(&mut self, effects: Vec<Effect>) {
        for effect in effects {
            match effect {
                Effect::SetAssertion(mode) => self.ports.set_assertion(mode),
                Effect::EnableLid => {
                    let tx = self.tx.clone();
                    self.ports.enable_lid(Box::new(move |ok| {
                        let _ = tx.send(Msg::LidResult(ok));
                    }));
                }
                Effect::DisableLid => self.ports.disable_lid(),
                Effect::WriteClipboard(text) => self.ports.write_clipboard(&text),
                Effect::WriteClipboardImage(path) => self.ports.write_clipboard_image(&path),
                Effect::WriteClipboardRich { text, path } => {
                    self.ports.write_clipboard_rich(&text, &path)
                }
                Effect::SleepDisplay => self.ports.sleep_display(),
                Effect::MediaCommand(command) => self.ports.media_command(command.code()),
                Effect::Resolve(resolved) => {
                    if let Some((_, reply)) = self.waiters.remove(&resolved.request_id) {
                        let _ = reply.send(Response::Decision {
                            decision: resolved.decision,
                        });
                    }
                }
            }
        }
    }

    /// Runs due timers, pushes the view model if it changed, and saves.
    fn after_event(&mut self, now: u64) {
        self.apply(Input::Tick, now);
        self.sync_now_playing(now);
        self.sync_lid_watch();
        let files = self.core.clip_file_paths();
        if self.kept_files.as_ref() != Some(&files) {
            self.ports.prune_clip_files(&files);
            self.kept_files = Some(files);
        }
        if let Ok(json) = serde_json::to_string(&self.core.view(now)) {
            if json != self.last_view {
                (self.on_view)(&json);
                self.last_view = json;
            }
        }
        if self.core.take_dirty() && self.save_at.is_none() {
            self.save_at = Some(now.saturating_add(SAVE_DEBOUNCE_MS));
        }
        if self.save_at.is_some_and(|at| now >= at) {
            self.save_at = None;
            let _ = store::save(&self.config.dir, &self.core.persisted());
        }
    }
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;
    use litenotch_core::caffeine::{AwakeMode, PowerStatus};
    use litenotch_core::clipboard::{ClipCapture, ClipKind};
    use std::sync::{Arc, Condvar, Mutex};

    /// Everything the runtime asked the fake OS to do, plus scripted answers.
    #[derive(Default)]
    pub struct FakeOs {
        pub calls: Vec<String>,
        pub clipboard: Option<String>,
        pub power: Option<PowerStatus>,
        /// `Some(ok)` answers lid requests immediately; `None` leaves them open.
        pub lid_answer: Option<bool>,
        pub lid_done: Option<Box<dyn FnOnce(bool) + Send>>,
        /// Call this to play the part of the now-playing helper.
        pub now_playing: Option<Box<dyn Fn(String) + Send>>,
        pub now_playing_switches: Vec<bool>,
        /// Each `prune_clip_files` call's keep list.
        pub pruned: Vec<Vec<String>>,
        /// `Some(closed)` plays a laptop lid: its state when watching starts.
        pub lid_closed: Option<bool>,
        /// Call this to play a lid change while the lid is watched.
        pub lid_watch: Option<Box<dyn Fn(litenotch_platform::display::Clamshell) + Send>>,
        /// True plays a root helper that has stopped.
        pub lid_helper_gone: bool,
    }

    #[derive(Clone, Default)]
    pub struct FakePorts(pub Arc<Mutex<FakeOs>>);

    impl Ports for FakePorts {
        fn set_assertion(&mut self, mode: AwakeMode) {
            self.0
                .lock()
                .unwrap()
                .calls
                .push(format!("assert:{mode:?}"));
        }
        fn enable_lid(&mut self, done: Box<dyn FnOnce(bool) + Send>) {
            let mut os = self.0.lock().unwrap();
            os.calls.push("lid:on".into());
            match os.lid_answer {
                Some(ok) => {
                    drop(os);
                    done(ok);
                }
                None => os.lid_done = Some(done),
            }
        }
        fn disable_lid(&mut self) {
            self.0.lock().unwrap().calls.push("lid:off".into());
        }
        fn write_clipboard(&mut self, text: &str) {
            self.0.lock().unwrap().calls.push(format!("write:{text}"));
        }
        fn now_playing(&mut self, sink: Option<Box<dyn Fn(String) + Send>>) {
            let mut os = self.0.lock().unwrap();
            os.now_playing_switches.push(sink.is_some());
            os.now_playing = sink;
        }
        fn media_command(&mut self, code: u32) {
            self.0.lock().unwrap().calls.push(format!("media:{code}"));
        }
        fn write_clipboard_image(&mut self, path: &str) {
            self.0.lock().unwrap().calls.push(format!("image:{path}"));
        }
        fn write_clipboard_rich(&mut self, text: &str, path: &str) {
            self.0
                .lock()
                .unwrap()
                .calls
                .push(format!("rich:{text}|{path}"));
        }
        fn prune_clip_files(&mut self, keep: &[String]) {
            self.0.lock().unwrap().pruned.push(keep.to_vec());
        }
        fn lid_active(&mut self) -> bool {
            !self.0.lock().unwrap().lid_helper_gone
        }
        fn watch_lid(
            &mut self,
            sink: Option<Box<dyn Fn(litenotch_platform::display::Clamshell) + Send>>,
        ) {
            let mut os = self.0.lock().unwrap();
            if let (Some(sink), Some(closed)) = (&sink, os.lid_closed) {
                sink(litenotch_platform::display::Clamshell {
                    closed,
                    external_display: false,
                });
            }
            os.lid_watch = sink;
        }
        fn sleep_display(&mut self) {
            self.0.lock().unwrap().calls.push("display:sleep".into());
        }
        fn power(&mut self) -> Option<PowerStatus> {
            let mut os = self.0.lock().unwrap();
            os.calls.push("power".into());
            os.power.clone()
        }
        fn poll_clipboard(&mut self, _keep: &dyn Fn(&ClipCapture) -> bool) -> Option<ClipCapture> {
            self.0
                .lock()
                .unwrap()
                .clipboard
                .take()
                .map(|text| ClipCapture {
                    kind: ClipKind::Text,
                    text,
                    source_app: Some("Test".into()),
                    concealed: false,
                    image_path: None,
                    rich_path: None,
                })
        }
    }

    /// Collects view models and lets a test wait for one that matches.
    #[derive(Clone, Default)]
    pub struct Views(Arc<(Mutex<Vec<serde_json::Value>>, Condvar)>);

    impl Views {
        pub fn sink(&self) -> Box<dyn Fn(&str) + Send> {
            let inner = Arc::clone(&self.0);
            Box::new(move |json| {
                let value = serde_json::from_str(json).expect("view model is JSON");
                inner.0.lock().unwrap().push(value);
                inner.1.notify_all();
            })
        }

        pub fn count(&self) -> usize {
            self.0 .0.lock().unwrap().len()
        }

        pub fn last(&self) -> serde_json::Value {
            self.0
                 .0
                .lock()
                .unwrap()
                .last()
                .cloned()
                .unwrap_or_default()
        }

        /// Waits until the newest view model satisfies `pred`.
        pub fn wait(
            &self,
            what: &str,
            pred: impl Fn(&serde_json::Value) -> bool,
        ) -> serde_json::Value {
            let (lock, cond) = &*self.0;
            let mut views = lock.lock().unwrap();
            let deadline = std::time::Instant::now() + Duration::from_secs(10);
            loop {
                if let Some(view) = views.last().filter(|v| pred(v)) {
                    return view.clone();
                }
                let left = deadline.saturating_duration_since(std::time::Instant::now());
                assert!(
                    !left.is_zero(),
                    "timed out waiting for: {what}; last view: {:?}",
                    views.last()
                );
                views = cond.wait_timeout(views, left).unwrap().0;
            }
        }
    }

    pub struct Harness {
        pub runtime: Runtime,
        pub os: Arc<Mutex<FakeOs>>,
        pub views: Views,
        pub dir: PathBuf,
        pub socket: PathBuf,
    }

    impl Harness {
        pub fn start(name: &str) -> Harness {
            Self::start_in(crate::store::temp_dir(name), FakeOs::default())
        }

        pub fn start_in(dir: PathBuf, os: FakeOs) -> Harness {
            let ports = FakePorts(Arc::new(Mutex::new(os)));
            let os = Arc::clone(&ports.0);
            let views = Views::default();
            let config = Config {
                dir: dir.join("data"),
                claude_dir: dir.join("claude"),
                cli_path: "/opt/litenotch/litenotch".into(),
                serve_socket: true,
                clipboard_poll_ms: 20,
            };
            let socket = config.socket_path();
            let runtime =
                Runtime::start(config, Box::new(ports), views.sink()).expect("runtime starts");
            views.wait("first view", |_| true);
            Harness {
                runtime,
                os,
                views,
                dir,
                socket,
            }
        }

        pub fn send(&self, json: &str) {
            self.runtime.send(json).expect("command accepted");
        }

        pub fn calls(&self) -> Vec<String> {
            self.os
                .lock()
                .unwrap()
                .calls
                .iter()
                .filter(|c| *c != "power")
                .cloned()
                .collect()
        }

        pub fn wait_call(&self, call: &str) {
            let deadline = std::time::Instant::now() + Duration::from_secs(10);
            while !self.calls().iter().any(|c| c == call) {
                assert!(
                    std::time::Instant::now() < deadline,
                    "no {call} in {:?}",
                    self.calls()
                );
                std::thread::sleep(Duration::from_millis(5));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::*;
    use super::*;
    use litenotch_core::caffeine::PowerStatus;
    use serde_json::json;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixStream;

    fn request(h: &Harness, request: &Request) -> UnixStream {
        let mut stream = UnixStream::connect(&h.socket).unwrap();
        stream.write_all(request.to_line().as_bytes()).unwrap();
        stream
    }

    fn reply(stream: UnixStream) -> Response {
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        Response::parse(&line).unwrap_or_else(|e| panic!("bad reply {line:?}: {e}"))
    }

    fn hook(h: &Harness, payload: serde_json::Value) -> UnixStream {
        request(h, &Request::Hook { payload })
    }

    fn permission(session: &str, command: &str) -> serde_json::Value {
        json!({"hook_event_name":"PermissionRequest","session_id":session,"cwd":"/work/api",
               "tool_name":"Bash","tool_input":{"command":command}})
    }

    #[test]
    fn starts_idle_and_pushes_a_view_only_when_something_changes() {
        let h = Harness::start("rt-idle");
        assert_eq!(h.views.last()["compact"]["kind"], "idle");
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(h.views.count(), 1, "an idle runtime pushes nothing");
        h.send(r#"{"cmd":"refresh"}"#);
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(h.views.count(), 1, "an unchanged view is not re-sent");
    }

    #[test]
    fn rejects_malformed_and_unknown_commands() {
        let h = Harness::start("rt-bad");
        assert!(h.runtime.send("nope").is_err());
        assert!(h.runtime.send(r#"{"cmd":"launch_missiles"}"#).is_err());
        assert!(
            h.runtime.send(r#"{"cmd":"clip_copy"}"#).is_err(),
            "missing field"
        );
    }

    #[test]
    fn a_pomodoro_runs_to_completion_on_the_timer() {
        let h = Harness::start("rt-pomo");
        let mut settings = litenotch_core::state::Settings::default();
        settings.pomodoro.focus_secs = 10;
        // The minimum focus length is 10 s; shorten the test by skipping instead.
        h.send(&json!({"cmd":"set_settings","settings":settings}).to_string());
        h.send(r#"{"cmd":"pomodoro_toggle"}"#);
        let view = h
            .views
            .wait("focus running", |v| v["pomodoro"]["run_state"] == "running");
        assert_eq!(view["compact"]["kind"], "pomodoro");
        assert!(view["compact"]["ends_at_ms"].is_u64());
        assert_eq!(view["inbox"]["dnd"], true);
        h.send(r#"{"cmd":"pomodoro_skip"}"#);
        h.views
            .wait("break", |v| v["pomodoro"]["phase"] == "short_break");
    }

    #[test]
    fn timers_fire_without_any_further_input() {
        let h = Harness::start("rt-timer");
        h.send(r#"{"cmd":"caffeine_activate","mode":"system","duration_secs":1}"#);
        h.wait_call("assert:System");
        h.views
            .wait("caffeine on", |v| v["caffeine"]["mode"] == "system");
        // No more commands: the loop must wake itself when the timer ends.
        h.views
            .wait("caffeine expired", |v| v["caffeine"]["mode"] == "off");
        assert_eq!(h.calls(), ["assert:System", "assert:Off"]);
    }

    #[test]
    fn clipboard_changes_are_captured_and_copied_back() {
        let h = Harness::start("rt-clip");
        h.os.lock().unwrap().clipboard = Some("hello from the pasteboard".into());
        let view = h.views.wait("captured", |v| v["clipboard"]["total"] == 1);
        assert_eq!(
            view["clipboard"]["items"][0]["preview"],
            "hello from the pasteboard"
        );
        assert_eq!(view["clipboard"]["items"][0]["source_app"], "Test");
        let id = view["clipboard"]["items"][0]["id"].as_u64().unwrap();
        h.send(&json!({"cmd":"clip_copy","id":id}).to_string());
        h.wait_call("write:hello from the pasteboard");
    }

    #[test]
    fn disabling_the_clipboard_stops_capturing() {
        let h = Harness::start("rt-clip-off");
        let mut settings = litenotch_core::state::Settings::default();
        settings.clipboard.enabled = false;
        h.send(&json!({"cmd":"set_settings","settings":settings}).to_string());
        h.views.wait("setting applied", |v| {
            v["settings"]["clipboard"]["enabled"] == false
        });
        h.os.lock().unwrap().clipboard = Some("ignored".into());
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(h.views.last()["clipboard"]["total"], 0);
        assert!(
            h.os.lock().unwrap().clipboard.is_some(),
            "the pasteboard was not even read"
        );
    }

    #[test]
    fn now_playing_comes_from_the_helper_and_commands_go_back_to_it() {
        let h = Harness::start("rt-media");
        let helper = |line: String| {
            let os = h.os.lock().unwrap();
            (os.now_playing.as_ref().expect("helper started"))(line);
        };
        let art = artwork_dir(&h.dir.join("data")).join("art-12ab");
        helper(
            json!({"title":"Song","artist":"Band","app":"Google Chrome","playing":true,
                "artwork_path": art.to_string_lossy()})
            .to_string(),
        );
        let v = h.views.wait("playing", |v| v["media"]["title"] == "Song");
        assert_eq!(v["media"]["app"], "Google Chrome");
        assert_eq!(v["media"]["artwork_path"], art.to_string_lossy().as_ref());
        assert_eq!(v["compact"]["kind"], "media");

        // A path outside the helper's own directory is not passed on.
        for bad in ["/etc/passwd", "/tmp/art-1", "relative/art-1"] {
            helper(json!({"title":"Other","playing":true,"artwork_path":bad}).to_string());
            let v = h.views.wait("other", |v| v["media"]["title"] == "Other");
            assert!(v["media"]["artwork_path"].is_null(), "{bad}");
            helper(json!({"title":"Song","playing":true}).to_string());
            h.views.wait("song", |v| v["media"]["title"] == "Song");
        }
        let inside_but_odd = artwork_dir(&h.dir.join("data")).join("state.json");
        helper(
            json!({"title":"Odd","playing":true,"artwork_path":inside_but_odd.to_string_lossy()})
                .to_string(),
        );
        let v = h.views.wait("odd", |v| v["media"]["title"] == "Odd");
        assert!(v["media"]["artwork_path"].is_null());

        h.send(r#"{"cmd":"media","action":"next"}"#);
        h.wait_call("media:4");
        helper("garbage".into());
        helper(r#"{"stopped":true}"#.into());
        h.views.wait("stopped", |v| v["media"].is_null());
        h.send(r#"{"cmd":"media","action":"play_pause"}"#);
        h.send(r#"{"cmd":"refresh"}"#);
        assert!(!h.calls().iter().any(|c| c == "media:2"));
    }

    #[test]
    fn switching_now_playing_off_stops_the_helper_and_clears_the_track() {
        let h = Harness::start("rt-media-off");
        {
            let os = h.os.lock().unwrap();
            (os.now_playing.as_ref().unwrap())(r#"{"title":"Song","playing":true}"#.into());
        }
        let v = h.views.wait("playing", |v| v["media"]["title"] == "Song");
        let mut settings = v["settings"].clone();
        settings["media"]["enabled"] = json!(false);
        h.send(&json!({"cmd":"set_settings","settings":settings}).to_string());
        h.views.wait("cleared", |v| {
            v["media"].is_null() && v["settings"]["media"]["enabled"] == false
        });
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while h.os.lock().unwrap().now_playing_switches != [true, false] {
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(h.os.lock().unwrap().now_playing.is_none());

        settings["media"]["enabled"] = json!(true);
        h.send(&json!({"cmd":"set_settings","settings":settings}).to_string());
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while h.os.lock().unwrap().now_playing_switches != [true, false, true] {
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn other_apps_notifications_reach_the_inbox_once_enabled() {
        let h = Harness::start("rt-sysnotify");
        let mut settings = h.views.last()["settings"].clone();
        settings["notify"]["system"] = json!(true);
        h.send(&json!({"cmd":"set_settings","settings":settings}).to_string());
        h.send(r#"{"cmd":"notify_system","app":"Mail","title":"New message","body":"Hi"}"#);
        let v = h
            .views
            .wait("banner", |v| v["inbox"]["banner"]["title"] == "New message");
        assert_eq!(v["inbox"]["banner"]["source"], "Mail");
    }

    #[test]
    fn a_permission_hook_waits_for_the_user_and_gets_the_decision() {
        let h = Harness::start("rt-allow");
        let stream = hook(&h, permission("s1", "cargo test"));
        let view = h
            .views
            .wait("approval shown", |v| v["compact"]["kind"] == "approval");
        assert_eq!(view["attention"], true);
        let id = view["agents"]["pending"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
        assert_eq!(view["agents"]["pending"][0]["detail"], "cargo test");
        h.send(&json!({"cmd":"agent_decide","request_id":id,"decision":"allow"}).to_string());
        assert_eq!(
            reply(stream),
            Response::Decision {
                decision: Decision::Allow
            }
        );
        h.views.wait("approval cleared", |v| {
            v["agents"]["pending"].as_array().unwrap().is_empty()
        });

        let stream = hook(&h, permission("s1", "rm -rf /"));
        let view = h
            .views
            .wait("second approval", |v| v["compact"]["kind"] == "approval");
        let id = view["agents"]["pending"][0]["id"]
            .as_str()
            .unwrap()
            .to_string();
        h.send(&json!({"cmd":"agent_decide","request_id":id,"decision":"deny"}).to_string());
        assert_eq!(
            reply(stream),
            Response::Decision {
                decision: Decision::Deny
            }
        );
    }

    #[test]
    fn two_sessions_can_wait_at_once_and_are_answered_separately() {
        let h = Harness::start("rt-two");
        let first = hook(&h, permission("s1", "one"));
        h.views.wait("first", |v| {
            v["agents"]["pending"].as_array().unwrap().len() == 1
        });
        let second = hook(&h, permission("s2", "two"));
        let view = h.views.wait("both", |v| {
            v["agents"]["pending"].as_array().unwrap().len() == 2
        });
        assert_eq!(view["compact"]["count"], 2);
        let id_of = |detail: &str| {
            view["agents"]["pending"]
                .as_array()
                .unwrap()
                .iter()
                .find(|r| r["detail"] == detail)
                .unwrap()["id"]
                .as_str()
                .unwrap()
                .to_string()
        };
        h.send(
            &json!({"cmd":"agent_decide","request_id":id_of("two"),"decision":"deny"}).to_string(),
        );
        assert_eq!(
            reply(second),
            Response::Decision {
                decision: Decision::Deny
            }
        );
        h.send(
            &json!({"cmd":"agent_decide","request_id":id_of("one"),"decision":"allow"}).to_string(),
        );
        assert_eq!(
            reply(first),
            Response::Decision {
                decision: Decision::Allow
            }
        );
    }

    #[test]
    fn a_hook_that_goes_away_withdraws_its_request() {
        let h = Harness::start("rt-gone");
        let stream = hook(&h, permission("s1", "ls"));
        h.views
            .wait("approval shown", |v| v["compact"]["kind"] == "approval");
        drop(stream);
        h.views.wait("approval withdrawn", |v| {
            v["agents"]["pending"].as_array().unwrap().is_empty()
        });
    }

    #[test]
    fn the_socket_cannot_be_used_to_approve() {
        let h = Harness::start("rt-noapprove");
        let waiting = hook(&h, permission("s1", "ls"));
        let view = h
            .views
            .wait("approval shown", |v| v["compact"]["kind"] == "approval");
        let id = view["agents"]["pending"][0]["id"].as_str().unwrap();
        let mut attacker = UnixStream::connect(&h.socket).unwrap();
        attacker
            .write_all(format!("{{\"type\":\"command\",\"cmd\":\"agent_decide\",\"request_id\":\"{id}\",\"decision\":\"allow\"}}\n").as_bytes())
            .unwrap();
        assert!(matches!(reply(attacker), Response::Error { .. }));
        assert_eq!(
            h.views.last()["agents"]["pending"]
                .as_array()
                .unwrap()
                .len(),
            1,
            "still pending"
        );
        drop(waiting);
    }

    #[test]
    fn non_blocking_hooks_are_acknowledged_and_update_sessions() {
        let h = Harness::start("rt-hooks");
        let ack = reply(hook(
            &h,
            json!({"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/work/api","prompt":"go"}),
        ));
        assert_eq!(ack, Response::Ok);
        let view = h.views.wait("working", |v| v["compact"]["kind"] == "agent");
        assert_eq!(view["agents"]["sessions"][0]["status"], "working");
        assert_eq!(
            reply(hook(
                &h,
                json!({"hook_event_name":"Stop","session_id":"s1","cwd":"/work/api","last_assistant_message":"done"})
            )),
            Response::Ok
        );
        let view = h.views.wait("finished banner", |v| {
            v["inbox"]["banner"]["title"] == "api finished"
        });
        assert_eq!(view["agents"]["sessions"][0]["status"], "idle");
    }

    #[test]
    fn statusline_updates_usage_and_returns_the_text() {
        let h = Harness::start("rt-status");
        let payload = json!({"rate_limits":{"five_hour":{"used_percentage":42.0},"seven_day":{"used_percentage":18.0}}});
        let response = reply(request(&h, &Request::Statusline { payload }));
        let Response::Statusline { text } = response else {
            panic!("{response:?}")
        };
        assert!(text.contains("42") && text.contains("18"), "{text}");
        h.views.wait("usage shown", |v| {
            v["usage"]["five_hour"]["used_pct"] == 42.0
        });
    }

    #[test]
    fn notify_posts_a_banner_and_status_summarises_without_user_data() {
        let h = Harness::start("rt-notify");
        h.os.lock().unwrap().clipboard = Some("my secret clipboard".into());
        h.views.wait("captured", |v| v["clipboard"]["total"] == 1);
        let notify = Request::Notify {
            title: "Deploy done".into(),
            body: "private body".into(),
            source: "ci".into(),
            priority: Priority::High,
            group: None,
            ttl_secs: None,
        };
        assert_eq!(reply(request(&h, &notify)), Response::Ok);
        h.views
            .wait("banner", |v| v["inbox"]["banner"]["title"] == "Deploy done");
        let Response::Status { view } = reply(request(&h, &Request::Status)) else {
            panic!()
        };
        assert_eq!(view["compact"]["kind"], "banner");
        assert_eq!(view["pending_approvals"], 0);
        let text = view.to_string();
        assert!(
            !text.contains("secret clipboard") && !text.contains("private body"),
            "{text}"
        );
    }

    /// From review: when the root helper has stopped, the mode stayed shown
    /// as on. Closing the lid is when that is checked.
    #[test]
    fn closing_the_lid_without_a_helper_ends_lid_mode_and_says_so() {
        let os = FakeOs {
            lid_answer: Some(true),
            lid_closed: Some(false),
            power: Some(PowerStatus {
                on_ac: true,
                battery_pct: Some(90),
            }),
            ..FakeOs::default()
        };
        let h = Harness::start_in(crate::store::temp_dir("rt-lid-lost"), os);
        h.send(r#"{"cmd":"caffeine_activate","mode":"display","duration_secs":null}"#);
        h.send(r#"{"cmd":"caffeine_lid","on":true}"#);
        h.views.wait("lid on", |v| v["caffeine"]["lid"] == "on");
        {
            let mut os = h.os.lock().unwrap();
            os.lid_helper_gone = true;
            (os.lid_watch.as_ref().expect("the lid is watched"))(
                litenotch_platform::display::Clamshell {
                    closed: true,
                    external_display: false,
                },
            );
        }
        h.views.wait("lid off with a notice", |v| {
            v["caffeine"]["lid"] == "off"
                && v["inbox"]["history"]
                    .as_array()
                    .is_some_and(|n| n.iter().any(|n| n["title"] == "Lid mode stopped"))
        });
        assert!(
            !h.calls().iter().any(|c| c == "display:sleep"),
            "the display is not turned off for a mode that has ended"
        );
    }

    #[test]
    fn closing_the_lid_in_lid_mode_turns_the_display_off() {
        let os = FakeOs {
            lid_answer: Some(true),
            lid_closed: Some(false),
            power: Some(PowerStatus {
                on_ac: true,
                battery_pct: Some(90),
            }),
            ..FakeOs::default()
        };
        let h = Harness::start_in(crate::store::temp_dir("rt-lid-shut"), os);
        h.send(r#"{"cmd":"caffeine_activate","mode":"display","duration_secs":null}"#);
        h.send(r#"{"cmd":"caffeine_lid","on":true}"#);
        h.views.wait("lid on", |v| v["caffeine"]["lid"] == "on");
        h.wait_call("assert:Display");
        let lid = |closed| {
            let os = h.os.lock().unwrap();
            (os.lid_watch
                .as_ref()
                .expect("the lid is watched in lid mode"))(
                litenotch_platform::display::Clamshell {
                    closed,
                    external_display: false,
                },
            );
        };
        lid(true);
        h.wait_call("display:sleep");
        h.wait_call("assert:System");
        lid(false);
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while h.calls().iter().filter(|c| *c == "assert:Display").count() < 2 {
            assert!(std::time::Instant::now() < deadline, "{:?}", h.calls());
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn lid_mode_goes_through_the_platform_and_is_reverted_on_cancel() {
        let h = Harness::start("rt-lid");
        h.send(r#"{"cmd":"caffeine_lid","on":true}"#);
        h.views
            .wait("pending", |v| v["caffeine"]["lid"] == "pending");
        // The user cancels while the password prompt is still open …
        h.send(r#"{"cmd":"caffeine_lid","on":false}"#);
        h.views.wait("off", |v| v["caffeine"]["lid"] == "off");
        // … and then the prompt succeeds anyway: it must be reverted.
        let done =
            h.os.lock()
                .unwrap()
                .lid_done
                .take()
                .expect("lid was requested");
        done(true);
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while h.calls().iter().filter(|c| *c == "lid:off").count() < 2 {
            assert!(std::time::Instant::now() < deadline, "{:?}", h.calls());
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(h.views.last()["caffeine"]["lid"], "off");
    }

    #[test]
    fn low_battery_turns_caffeine_off() {
        let dir = crate::store::temp_dir("rt-batt");
        let os = FakeOs {
            power: Some(PowerStatus {
                on_ac: false,
                battery_pct: Some(4),
            }),
            lid_answer: Some(true),
            ..FakeOs::default()
        };
        let h = Harness::start_in(dir, os);
        h.send(r#"{"cmd":"caffeine_toggle"}"#);
        // Activation is refused outright or reverted by the first power reading.
        let view = h.views.wait("guard notice", |v| {
            v["inbox"]["banner"]["source"] == "caffeine"
        });
        assert_eq!(view["caffeine"]["mode"], "off");
    }

    #[test]
    fn keep_awake_works_again_once_power_is_back_after_the_battery_guard() {
        let dir = crate::store::temp_dir("rt-batt-back");
        let os = FakeOs {
            power: Some(PowerStatus {
                on_ac: false,
                battery_pct: Some(4),
            }),
            ..FakeOs::default()
        };
        let h = Harness::start_in(dir, os);
        h.send(r#"{"cmd":"caffeine_toggle"}"#);
        h.views.wait("refused on low battery", |v| {
            v["inbox"]["banner"]["source"] == "caffeine"
        });
        assert_eq!(h.views.last()["caffeine"]["mode"], "off");
        // Plugged in. Nothing polls power while keep-awake is off, so the
        // command itself must pick up the new reading.
        h.os.lock().unwrap().power = Some(PowerStatus {
            on_ac: true,
            battery_pct: Some(4),
        });
        h.send(r#"{"cmd":"caffeine_toggle"}"#);
        h.views
            .wait("keep-awake on", |v| v["caffeine"]["mode"] == "display");
        h.wait_call("assert:Display");
    }

    #[test]
    fn hooks_are_installed_and_removed_in_the_claude_settings_file() {
        let h = Harness::start("rt-install");
        assert_eq!(h.views.last()["agents"]["hooks_installed"], false);
        h.send(r#"{"cmd":"hooks_install"}"#);
        let view = h
            .views
            .wait("installed", |v| v["agents"]["hooks_installed"] == true);
        assert_eq!(view["inbox"]["banner"]["title"], "Connected to Claude Code");
        let text = std::fs::read_to_string(h.dir.join("claude/settings.json")).unwrap();
        assert!(
            text.contains("'/opt/litenotch/litenotch' hook")
                || text.contains("/opt/litenotch/litenotch")
        );
        h.send(r#"{"cmd":"hooks_uninstall"}"#);
        h.views
            .wait("removed", |v| v["agents"]["hooks_installed"] == false);
    }

    #[test]
    fn a_broken_settings_file_is_reported_not_overwritten() {
        let dir = crate::store::temp_dir("rt-install-bad");
        std::fs::create_dir_all(dir.join("claude")).unwrap();
        std::fs::write(dir.join("claude/settings.json"), "[]").unwrap();
        let h = Harness::start_in(dir, FakeOs::default());
        h.send(r#"{"cmd":"hooks_install"}"#);
        let view = h.views.wait("error banner", |v| {
            v["inbox"]["banner"]["title"] == "Claude Code settings not changed"
        });
        assert_eq!(view["inbox"]["banner"]["priority"], "high");
        assert_eq!(
            std::fs::read_to_string(h.dir.join("claude/settings.json")).unwrap(),
            "[]"
        );
    }

    #[test]
    fn todays_tokens_are_read_from_transcripts() {
        let dir = crate::store::temp_dir("rt-usage");
        let project = dir.join("claude/projects/-work-api");
        std::fs::create_dir_all(&project).unwrap();
        let now = crate::clock::wall_ms();
        let stamp = |ms: u64| {
            // RFC 3339 in UTC, built by hand to avoid a date dependency.
            let secs = ms / 1000;
            let (h, m, s) = ((secs / 3600) % 24, (secs / 60) % 60, secs % 60);
            let days = secs / 86_400;
            let (mut year, mut rest) = (1970u64, days);
            loop {
                let len = if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
                    366
                } else {
                    365
                };
                if rest < len {
                    break;
                }
                rest -= len;
                year += 1;
            }
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
            let lens = [
                31,
                if leap { 29 } else { 28 },
                31,
                30,
                31,
                30,
                31,
                31,
                30,
                31,
                30,
                31,
            ];
            let mut month = 0;
            while rest >= lens[month] {
                rest -= lens[month];
                month += 1;
            }
            format!(
                "{year:04}-{:02}-{:02}T{h:02}:{m:02}:{s:02}Z",
                month + 1,
                rest + 1
            )
        };
        let line = |id: &str, ms: u64| {
            json!({"type":"assistant","timestamp":stamp(ms),"requestId":id,"cwd":"/work/api",
                   "message":{"id":id,"model":"claude-m","usage":{"input_tokens":100,"output_tokens":50}}})
            .to_string()
        };
        // One message now, one from two days ago (counts for that day only).
        std::fs::write(
            project.join("s1.jsonl"),
            format!("{}\n{}\n", line("a", now), line("b", now - 2 * 86_400_000)),
        )
        .unwrap();
        let h = Harness::start_in(dir, FakeOs::default());
        let view = h
            .views
            .wait("tokens counted", |v| v["usage"]["today"]["messages"] == 1);
        assert_eq!(view["usage"]["today"]["input"], 100);
        assert_eq!(view["usage"]["today"]["output"], 50);
        let week: Vec<u64> = view["usage"]["week"]
            .as_array()
            .unwrap()
            .iter()
            .map(|d| d["tokens"].as_u64().unwrap())
            .collect();
        assert_eq!(week, [0, 0, 0, 0, 150, 0, 150]);
        assert_eq!(view["usage"]["models"], json!([{"name":"m","tokens":150}]));
        assert_eq!(
            view["usage"]["projects"],
            json!([{"name":"api","tokens":150}])
        );
        assert!(view["usage"]["summary"]
            .as_str()
            .unwrap()
            .starts_with("150 tokens today in 1 project"));
    }

    #[test]
    fn state_is_saved_on_shutdown_and_restored_on_the_next_start() {
        let dir = crate::store::temp_dir("rt-persist");
        let h = Harness::start_in(dir.clone(), FakeOs::default());
        let mut settings = litenotch_core::state::Settings::default();
        settings.pomodoro.focus_secs = 1200;
        h.send(&json!({"cmd":"set_settings","settings":settings}).to_string());
        h.views.wait("applied", |v| {
            v["settings"]["pomodoro"]["focus_secs"] == 1200
        });
        let socket = h.socket.clone();
        drop(h);
        assert!(!socket.exists(), "the socket is cleaned up");
        assert!(dir.join("data/state.json").exists());
        let h = Harness::start_in(dir, FakeOs::default());
        assert_eq!(h.views.last()["settings"]["pomodoro"]["focus_secs"], 1200);
    }

    #[test]
    fn changes_are_saved_after_the_debounce_without_shutting_down() {
        let h = Harness::start("rt-debounce");
        h.send(r#"{"cmd":"panel_opened"}"#);
        let path = h.dir.join("data/state.json");
        assert!(!path.exists(), "not written immediately");
        let deadline = std::time::Instant::now() + Duration::from_secs(8);
        while !path.exists() {
            assert!(
                std::time::Instant::now() < deadline,
                "state was never saved"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
        let saved: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(saved["version"], 1);
        assert!(saved["analytics"]["days"]
            .as_object()
            .unwrap()
            .values()
            .any(|d| d["panel_open"] == 1));
    }

    #[test]
    fn shutting_down_releases_the_system_and_answers_waiting_hooks() {
        let h = Harness::start("rt-stop");
        h.send(r#"{"cmd":"caffeine_toggle"}"#);
        h.wait_call("assert:Display");
        let stream = hook(&h, permission("s1", "ls"));
        h.views
            .wait("approval shown", |v| v["compact"]["kind"] == "approval");
        let os = std::sync::Arc::clone(&h.os);
        drop(h);
        assert_eq!(
            reply(stream),
            Response::Decision {
                decision: Decision::Pass
            }
        );
        let calls = os.lock().unwrap().calls.clone();
        assert_eq!(&calls[calls.len() - 2..], ["lid:off", "assert:Off"]);
    }

    #[test]
    fn a_second_instance_in_the_same_directory_is_refused() {
        let h = Harness::start("rt-dup");
        let config = Config {
            dir: h.dir.join("data"),
            claude_dir: h.dir.join("claude"),
            cli_path: "x".into(),
            serve_socket: true,
            clipboard_poll_ms: 0,
        };
        let err = Runtime::start(config, Box::new(FakePorts::default()), Box::new(|_| {}))
            .err()
            .unwrap();
        assert_eq!(err.kind(), std::io::ErrorKind::AddrInUse);
    }

    #[test]
    fn usage_limits_can_be_turned_on_and_off_from_the_notch() {
        let dir = crate::store::temp_dir("rt-statusline");
        std::fs::create_dir_all(dir.join("claude")).unwrap();
        std::fs::write(
            dir.join("claude/settings.json"),
            r#"{"statusLine":{"type":"command","command":"my-line"}}"#,
        )
        .unwrap();
        let h = Harness::start_in(dir, FakeOs::default());
        h.views.wait("not installed", |v| {
            v["agents"]["statusline_installed"] == false
        });
        h.send(r#"{"cmd":"statusline_install"}"#);
        h.views
            .wait("installed", |v| v["agents"]["statusline_installed"] == true);
        let text = std::fs::read_to_string(h.dir.join("claude/settings.json")).unwrap();
        assert!(
            text.contains("statusline -- /bin/sh -c 'my-line'"),
            "{text}"
        );
        h.send(r#"{"cmd":"statusline_uninstall"}"#);
        h.views
            .wait("removed", |v| v["agents"]["statusline_installed"] == false);
        let back: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(h.dir.join("claude/settings.json")).unwrap(),
        )
        .unwrap();
        assert_eq!(back["statusLine"]["command"], "my-line");
    }
}
