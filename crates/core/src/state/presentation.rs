//! What the closed notch shows, in three layers (the top one wins):
//!
//! 1. **Interrupt**: a pending approval, then a banner.
//! 2. **Peek**: a few seconds about one of the user's own activities (the
//!    track changed, a countdown is about to end) or a wellbeing nudge (an
//!    eye break, a Move reminder, a line after a break), then it goes away
//!    by itself. Peeks never enter the inbox and focus time does not hold
//!    them. A new peek replaces the one showing, except that a nudge is not
//!    cut short: a countdown or track peek waits until it ends.
//! 3. **Activity**: the running activities ranked by `settings.notch`
//!    (`Core::compact`).

use serde::{Deserialize, Serialize};

use crate::body::Which;

use super::{
    mmss, phase_label, ActivityKind, CompactView, Core, MediaView, NotificationInput, Phase,
    PomodoroView, Priority, RunState, TimerRun,
};

/// Which peeks are on.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PeekConfig {
    /// Show the new track for a moment when it changes.
    pub track_change: bool,
    /// Peek when a running countdown has this long left; 0 is off. Only for
    /// countdowns longer than twice this.
    pub time_warning_secs: u32,
    /// A quick blinking `O-O` every this many minutes at the screen, so the
    /// user blinks and looks away; 0 is off (the default), else 1..=60.
    pub eye_break_mins: u32,
    /// The Move reminder of earlier versions, read from old files only: the
    /// water and stretch gauges (`settings.body`) replaced it, and
    /// `Core::new` moves its interval there.
    #[serde(skip_serializing)]
    pub move_mins: u32,
    /// Show a short encouraging line when a pomodoro break completes.
    pub break_quote: bool,
    /// Remind the user who keeps typing or using the mouse during a running
    /// break (`BREAK_CHECK_*`): twice as a peek, then as a banner that offers
    /// to skip the break.
    pub still_working: bool,
}

impl Default for PeekConfig {
    fn default() -> Self {
        Self {
            track_change: true,
            time_warning_secs: 300,
            eye_break_mins: 0,
            move_mins: 0,
            break_quote: true,
            still_working: true,
        }
    }
}

impl PeekConfig {
    pub(super) fn sanitized(self) -> Self {
        let on = |mins: u32, lo: u32, hi: u32| if mins == 0 { 0 } else { mins.clamp(lo, hi) };
        Self {
            time_warning_secs: self.time_warning_secs.min(3600),
            eye_break_mins: on(self.eye_break_mins, 1, 60),
            move_mins: 0,
            ..self
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PeekKind {
    TrackChanged,
    TimeWarning,
    /// Blink and look away (`ActivityKind::Nudge`); short, it comes often.
    EyeBreak,
    /// The water or stretch gauge ran empty (`ActivityKind::Nudge`, `title`
    /// names which).
    Move,
    /// A short line after a break (`ActivityKind::Nudge`).
    Quote,
    /// The user is still at the keyboard during a break
    /// (`ActivityKind::Nudge`).
    StillWorking,
}

impl PeekKind {
    /// A wellbeing nudge rather than news about an activity.
    fn is_nudge(self) -> bool {
        matches!(
            self,
            PeekKind::EyeBreak | PeekKind::Move | PeekKind::Quote | PeekKind::StillWorking
        )
    }

    fn duration_ms(self) -> u64 {
        match self {
            PeekKind::EyeBreak => EYE_MS,
            PeekKind::Move | PeekKind::Quote | PeekKind::StillWorking => NUDGE_MS,
            _ => PEEK_MS,
        }
    }
}

/// How long a peek stays.
pub const PEEK_MS: u64 = 4_000;
/// How long a nudge with a line stays: it scrolls through a narrow wing.
pub const NUDGE_MS: u64 = 8_000;
/// How long the eye break stays: a glance, since it comes every few minutes.
pub const EYE_MS: u64 = 3_000;
/// A mark seen this much later than it fell was slept through (the runtime
/// wakes at each deadline): the user was away, so no reminder.
const LATE_MS: u64 = 60_000;
/// How long a break's line waits for the "Break over" banner (or an
/// approval) to go before it is dropped.
const QUOTE_WAIT_MS: u64 = 60_000;

const EYE_BREAK_TITLE: &str = "Eye break";
/// The eye break's word, one per break (picked from the minute).
pub const EYE_LINES: [&str; 3] = ["Blink", "Relax", "Look away"];
const QUOTE_TITLE: &str = "Break over";

/// The first check whether the user is still working, this long into a
/// running break, then every `BREAK_CHECK_STEP_MS`: a 5-minute break gets
/// three (1:00, 2:30, 4:00). Each check asks the runtime for one reading of
/// the input idle time (`Core::wants_idle`); nothing polls.
pub const BREAK_CHECK_FIRST_MS: u64 = 60_000;
pub const BREAK_CHECK_STEP_MS: u64 = 90_000;
/// Keyboard or mouse used within this long counts as still working.
pub const WORKING_IDLE_SECS: u32 = 30;
const BREAK_TITLE: &str = "Break";
/// What the reminders say, gentle first. After these, a banner.
const STILL_WORKING_LINES: [&str; 2] = [
    "Break time. Step away for a bit.",
    "Still working? Your break is ticking away.",
];
/// The banner's title; `Core::banner_action` offers "Skip break" on it.
pub(super) const STILL_WORKING_BANNER: &str = "Still working on your break?";

/// Checks passed at `elapsed_ms` into a break.
fn break_checks(elapsed_ms: u64) -> u64 {
    if elapsed_ms < BREAK_CHECK_FIRST_MS {
        0
    } else {
        (elapsed_ms - BREAK_CHECK_FIRST_MS) / BREAK_CHECK_STEP_MS + 1
    }
}

/// What an empty gauge says: `(title, line)`, one picked from the moment.
pub const WATER_LINES: [&str; 2] = ["Drink some water", "Refill your water"];
pub const STRETCH_LINES: [&str; 4] = [
    "Stand up and stretch",
    "Roll your shoulders, stretch",
    "Take a short walk",
    "Walk around for a minute",
];
const WATER_TITLE: &str = "Water";
const STRETCH_TITLE: &str = "Stretch";
const BOTH_TITLE: &str = "Water and stretch";
const BOTH_LINE: &str = "Drink some water, then stretch";

/// One of `lines`, picked by the moment: the core reads no clock.
fn pick(lines: &'static [&'static str], at_ms: u64) -> &'static str {
    lines[(at_ms / 1000 % lines.len() as u64) as usize]
}

/// Lines shown after a break. Written for LiteNotch; short enough to read
/// in the few seconds a peek stays.
pub const BREAK_LINES: [&str; 20] = [
    "Fresh start. You've got this.",
    "Rested and ready. Go.",
    "One step at a time.",
    "Small steps add up.",
    "Back at it, nice and easy.",
    "Steady wins the day.",
    "Pick one thing. Begin.",
    "Good work so far. Keep going.",
    "Clear head, clear code.",
    "Breathe in. Dive in.",
    "Let's make this one count.",
    "Focus on the next small win.",
    "Doing better than you think.",
    "Fresh eyes catch more.",
    "Another round, another win.",
    "Keep it simple. Keep going.",
    "Recharged. Let's build.",
    "Nice break. Now, one task.",
    "Ship something small.",
    "Easy does it. Back to it.",
];

/// The line for a break that ended at `at_ms`: the core reads no clock, so
/// the moment itself picks one.
fn break_line(at_ms: u64) -> &'static str {
    BREAK_LINES[(at_ms / 1000 % BREAK_LINES.len() as u64) as usize]
}

/// A countdown that can peek.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Clock {
    Pomodoro,
    Timer,
}

const CLOCKS: [Clock; 2] = [Clock::Pomodoro, Clock::Timer];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Peek {
    pub kind: PeekKind,
    /// The countdown it is about; `None` for a track change or a nudge.
    pub clock: Option<Clock>,
    /// A nudge's title and line; empty otherwise.
    pub title: &'static str,
    pub text: &'static str,
    pub until_ms: u64,
}

impl Peek {
    fn about(kind: PeekKind, clock: Clock) -> Self {
        Self::new(kind, Some(clock), "", "")
    }

    fn nudge(kind: PeekKind, title: &'static str, text: &'static str) -> Self {
        Self::new(kind, None, title, text)
    }

    /// `until_ms` is set when it starts showing.
    fn new(kind: PeekKind, clock: Option<Clock>, title: &'static str, text: &'static str) -> Self {
        Self {
            kind,
            clock,
            title,
            text,
            until_ms: 0,
        }
    }
}

/// A countdown's state at one moment.
struct Left {
    left_ms: u64,
    total_ms: u64,
    /// Running, not paused.
    running: bool,
}

impl Core {
    fn clock_left(&self, clock: Clock, now: u64) -> Option<Left> {
        match clock {
            Clock::Pomodoro => {
                let s = self.pomodoro.snapshot(now);
                if s.phase == Phase::Idle {
                    return None;
                }
                let ends = self.pomodoro.next_deadline();
                let left_ms = match (s.run_state, ends) {
                    (RunState::Running, Some(end)) => end.saturating_sub(now),
                    (RunState::Paused, _) => u64::from(s.remaining_secs) * 1000,
                    _ => return None,
                };
                Some(Left {
                    left_ms,
                    total_ms: u64::from(s.total_secs) * 1000,
                    running: s.run_state == RunState::Running,
                })
            }
            Clock::Timer => {
                let t = self.timer.view();
                let left_ms = match (t.run_state, t.ends_at_ms) {
                    (TimerRun::Running, Some(end)) => end.saturating_sub(now),
                    (TimerRun::Paused, _) => u64::from(t.remaining_secs) * 1000,
                    _ => return None,
                };
                Some(Left {
                    left_ms,
                    total_ms: u64::from(t.duration_secs) * 1000,
                    running: t.run_state == TimerRun::Running,
                })
            }
        }
    }

    fn clock_index(clock: Clock) -> usize {
        match clock {
            Clock::Pomodoro => 0,
            Clock::Timer => 1,
        }
    }

    fn warn_ms(&self) -> u64 {
        u64::from(self.settings.peek.time_warning_secs) * 1000
    }

    fn eye_ms(&self) -> u64 {
        u64::from(self.settings.peek.eye_break_mins) * 60_000
    }

    /// The user cannot be at the screen: it is locked, the displays or the
    /// Mac sleep (the shell says so), or the lid is shut in closed-lid mode
    /// with no other display. The Mac may be awake then, but nobody is
    /// looking, so screen time does not count.
    pub(super) fn is_away(&self) -> bool {
        self.away || self.lid_shut
    }

    /// A pomodoro break is running.
    pub(super) fn break_running(&self, now: u64) -> bool {
        let s = self.pomodoro.snapshot(now);
        matches!(s.phase, Phase::ShortBreak | Phase::LongBreak) && s.run_state == RunState::Running
    }

    /// A still-working check of a running break was crossed since the last
    /// look, just now (not slept through), and the user is here.
    fn break_check(&self, prev_left: u64, cur: &Left, now: u64) -> bool {
        if !self.settings.peek.still_working
            || self.is_away()
            || !self.break_running(now)
            || prev_left <= cur.left_ms
        {
            return false;
        }
        let elapsed = cur.total_ms.saturating_sub(cur.left_ms);
        let before = break_checks(cur.total_ms.saturating_sub(prev_left));
        break_checks(elapsed) > before
            && (elapsed - BREAK_CHECK_FIRST_MS) % BREAK_CHECK_STEP_MS <= LATE_MS
    }

    /// The runtime should read the input idle time and send
    /// `Input::InputIdle`: a still-working check is due.
    pub fn wants_idle(&self) -> bool {
        self.idle_wanted
    }

    /// The answer to `wants_idle`: seconds since the keyboard or mouse was
    /// last used. Recent use during a break gets a reminder, firmer each
    /// time; an idle user (on a break, as meant) gets none.
    pub(super) fn input_idle(&mut self, secs: u32, now: u64) {
        if !std::mem::take(&mut self.idle_wanted)
            || secs >= WORKING_IDLE_SECS
            || self.is_away()
            || !self.settings.peek.still_working
            || !self.break_running(now)
        {
            return;
        }
        let n = usize::from(self.break_nags);
        self.break_nags = self.break_nags.saturating_add(1);
        if let Some(line) = STILL_WORKING_LINES.get(n) {
            self.start_peek(Peek::nudge(PeekKind::StillWorking, BREAK_TITLE, line), now);
            return;
        }
        let mins = self
            .clock_left(Clock::Pomodoro, now)
            .map_or(0, |l| l.total_ms.saturating_sub(l.left_ms) / 60_000);
        self.post(
            NotificationInput {
                source: "pomodoro".into(),
                title: STILL_WORKING_BANNER.into(),
                body: format!("{mins} min in, still at the keyboard."),
                priority: Priority::Normal,
                group: Some("pomodoro".into()),
                ttl_secs: Some(60),
            },
            now,
        );
    }

    /// Shows a peek now, or after the nudge that is showing. A nudge that
    /// replaces a peek shown for less than half its time brings that peek
    /// back afterwards.
    fn start_peek(&mut self, peek: Peek, now: u64) {
        let new = Peek {
            until_ms: now.saturating_add(peek.kind.duration_ms()),
            ..peek
        };
        match self.peek.filter(|p| p.until_ms > now) {
            Some(cur) if cur.kind.is_nudge() && !new.kind.is_nudge() => {
                self.peek_next = Some(new);
            }
            Some(cur) if !cur.kind.is_nudge() && new.kind.is_nudge() => {
                if cur.until_ms - now > cur.kind.duration_ms() / 2 {
                    self.peek_next = Some(cur);
                }
                self.peek = Some(new);
            }
            _ => self.peek = Some(new),
        }
    }

    /// Records a track change from the media module.
    pub(super) fn track_changed(&mut self, now: u64) {
        if self.settings.peek.track_change {
            self.start_peek(Peek::new(PeekKind::TrackChanged, None, "", ""), now);
        }
    }

    /// A pomodoro break completed: its line shows once nothing covers it.
    pub(super) fn break_done(&mut self, now: u64) {
        if self.settings.peek.break_quote {
            self.quote_due = Some(now);
        }
    }

    /// Part of `settle_peeks` for the eye break, counted in screen time.
    /// Away (or off) its interval starts over.
    fn eye_due(&mut self, now: u64) -> bool {
        let (on, step) = (self.settings.peek.eye_break_mins > 0, self.eye_ms());
        let away = self.is_away();
        let since = &mut self.eye_since;
        if !on || away {
            *since = None;
            return false;
        }
        let Some(start) = *since else {
            *since = Some(now);
            return false;
        };
        let due = start.saturating_add(step);
        if now < due {
            return false;
        }
        *since = Some(now);
        now - due <= LATE_MS
    }

    /// Part of `settle`: starts a peek when a running countdown crosses the
    /// warning or a gauge runs empty since the last look, and ends an
    /// expired peek.
    ///
    /// A crossing needs time left to go from above a mark to at or below it
    /// while running. Pausing keeps time left still, so pause and resume
    /// never repeat a peek; a new phase jumps back up, which arms it again.
    pub(super) fn settle_peeks(&mut self, now: u64) {
        if let Some(ended) = self.peek.map(|p| p.until_ms).filter(|&t| t <= now) {
            // What waited behind a nudge starts now, unless that was long
            // ago (the Mac slept).
            self.peek = self
                .peek_next
                .take()
                .filter(|_| now - ended <= LATE_MS)
                .map(|p| Peek {
                    until_ms: now.saturating_add(p.kind.duration_ms()),
                    ..p
                });
        }
        if !self.break_running(now) {
            // A new break starts gently again.
            self.break_nags = 0;
            self.idle_wanted = false;
        }
        let warn = self.warn_ms();
        for clock in CLOCKS {
            let i = Self::clock_index(clock);
            let cur = self.clock_left(clock, now);
            let prev = std::mem::replace(&mut self.clock_seen[i], cur.as_ref().map(|c| c.left_ms));
            let (Some(prev), Some(cur)) = (prev, cur) else {
                continue;
            };
            if !cur.running || cur.left_ms == 0 {
                continue;
            }
            if clock == Clock::Pomodoro && self.break_check(prev, &cur, now) {
                self.idle_wanted = true;
            }
            if warn > 0 && cur.total_ms > 2 * warn && prev > warn && cur.left_ms <= warn {
                self.start_peek(Peek::about(PeekKind::TimeWarning, clock), now);
            }
        }
        if self.eye_due(now) {
            let eye = Peek::nudge(
                PeekKind::EyeBreak,
                EYE_BREAK_TITLE,
                EYE_LINES[(now / 60_000 % EYE_LINES.len() as u64) as usize],
            );
            self.start_peek(eye, now);
        }
        // After the eye break, so an empty gauge at the same moment wins.
        let counting = !self.is_away();
        let emptied: Vec<Which> = self
            .body
            .sync(counting, now)
            .into_iter()
            .filter(|&(_, at)| now - at <= LATE_MS)
            .map(|(which, _)| which)
            .collect();
        let (title, line) = match emptied.as_slice() {
            [] => ("", ""),
            [Which::Water] => (WATER_TITLE, pick(&WATER_LINES, now)),
            [Which::Stretch] => (STRETCH_TITLE, pick(&STRETCH_LINES, now)),
            _ => (BOTH_TITLE, BOTH_LINE),
        };
        if !title.is_empty() {
            self.start_peek(Peek::nudge(PeekKind::Move, title, line), now);
        }
        if let Some(at) = self.quote_due {
            let covered = self.notify.current_banner().is_some()
                || !self.agents.pending().is_empty()
                || self.is_away();
            if now.saturating_sub(at) > QUOTE_WAIT_MS {
                self.quote_due = None;
            } else if !covered {
                self.quote_due = None;
                let quote = Peek::nudge(PeekKind::Quote, QUOTE_TITLE, break_line(at));
                self.start_peek(quote, now);
            }
        }
    }

    /// The earliest time a peek starts or ends. Uses what `settle_peeks`
    /// saw last, so every time returned is still ahead.
    pub(super) fn peek_deadline(&self) -> Option<u64> {
        let warn = self.warn_ms();
        let ends = |clock| match clock {
            Clock::Pomodoro => self.pomodoro.next_deadline(),
            Clock::Timer => self.timer.next_deadline(),
        };
        let total_ms = |clock| match clock {
            Clock::Pomodoro => u64::from(self.pomodoro.snapshot(0).total_secs) * 1000,
            Clock::Timer => u64::from(self.timer.duration_secs()) * 1000,
        };
        let mut times = vec![self.peek.map(|p| p.until_ms)];
        for clock in CLOCKS {
            let (Some(left), Some(end)) = (self.clock_seen[Self::clock_index(clock)], ends(clock))
            else {
                continue;
            };
            if warn > 0 && left > warn && total_ms(clock) > 2 * warn {
                times.push(Some(end.saturating_sub(warn)));
            }
            if clock == Clock::Pomodoro
                && self.settings.peek.still_working
                && !self.is_away()
                && self.break_running(0)
            {
                let (total, elapsed) = (total_ms(clock), total_ms(clock).saturating_sub(left));
                let mark = BREAK_CHECK_FIRST_MS + break_checks(elapsed) * BREAK_CHECK_STEP_MS;
                if mark < total {
                    times.push(end.checked_sub(total - mark));
                }
            }
        }
        times.push(self.eye_since.map(|s| s.saturating_add(self.eye_ms())));
        times.push(self.body.next_deadline());
        times.into_iter().flatten().min()
    }

    /// The current peek, if what it is about is still there.
    pub(super) fn peek_view(
        &self,
        pomodoro: &PomodoroView,
        media: &Option<MediaView>,
    ) -> Option<CompactView> {
        let peek = self.peek?;
        let shown = match (peek.kind, peek.clock) {
            (PeekKind::EyeBreak | PeekKind::Move | PeekKind::Quote | PeekKind::StillWorking, _) => {
                view(ActivityKind::Nudge, peek.title, peek.text)
            }
            (_, None) => playing_view(media)?,
            (_, Some(Clock::Pomodoro)) => pomodoro_view(pomodoro)?,
            (_, Some(Clock::Timer)) => self.timer_view()?,
        };
        Some(CompactView {
            peek: Some(peek.kind),
            ..shown
        })
    }

    fn timer_view(&self) -> Option<CompactView> {
        let timer = self.timer.view();
        if !matches!(timer.run_state, TimerRun::Running | TimerRun::Paused) {
            return None;
        }
        let value = if timer.run_state == TimerRun::Paused {
            mmss(timer.remaining_secs)
        } else {
            String::new()
        };
        Some(CompactView {
            ends_at_ms: timer.ends_at_ms,
            total_secs: Some(timer.duration_secs),
            ..view(ActivityKind::Timer, "Timer", &value)
        })
    }
}

fn view(kind: ActivityKind, title: &str, value: &str) -> CompactView {
    CompactView {
        kind,
        title: title.to_string(),
        value: value.to_string(),
        ends_at_ms: None,
        total_secs: None,
        count: 0,
        peek: None,
    }
}

fn pomodoro_view(pomodoro: &PomodoroView) -> Option<CompactView> {
    if pomodoro.phase == Phase::Idle {
        return None;
    }
    let value = if pomodoro.ends_at_ms.is_some() {
        String::new()
    } else {
        mmss(pomodoro.remaining_secs)
    };
    Some(CompactView {
        ends_at_ms: pomodoro.ends_at_ms,
        total_secs: Some(pomodoro.total_secs),
        ..view(ActivityKind::Pomodoro, phase_label(pomodoro.phase), &value)
    })
}

fn playing_view(media: &Option<MediaView>) -> Option<CompactView> {
    let m = media.as_ref().filter(|m| m.playing)?;
    Some(view(ActivityKind::Media, &m.title, &m.artist))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::body::BodyConfig;
    use crate::media::NowPlaying;
    use crate::notify::BannerAction;
    use crate::state::{Command, Input, Settings};
    use serde_json::json;

    const T0: u64 = 1_700_000_000_000;
    const MIN: u64 = 60_000;

    fn cmd(c: &mut Core, command: Command, now: u64) {
        c.apply(Input::Command(command), now);
    }

    fn with(c: &mut Core, edit: impl FnOnce(&mut Settings), now: u64) {
        let mut s = c.settings().clone();
        edit(&mut s);
        cmd(
            c,
            Command::SetSettings {
                settings: Box::new(s),
            },
            now,
        );
    }

    fn track(title: &str, playing: bool) -> NowPlaying {
        NowPlaying {
            app: "Music".into(),
            title: title.into(),
            artist: "Band".into(),
            playing,
            updated_ms: T0,
            ..NowPlaying::default()
        }
    }

    fn play(c: &mut Core, title: &str, now: u64) {
        c.apply(Input::NowPlaying(Some(track(title, true))), now);
    }

    fn approval(c: &mut Core, now: u64) {
        let json = json!({"hook_event_name":"PermissionRequest","session_id":"s","cwd":"/w/p",
            "tool_name":"Read","tool_input":{"file_path":"/a"}});
        c.hook(&json.to_string(), now);
    }

    fn compact(c: &Core, now: u64) -> CompactView {
        c.view(now).compact
    }

    #[test]
    fn auto_keeps_the_original_order() {
        let mut c = Core::default();
        play(&mut c, "Song", T0);
        c.apply(Input::Tick, T0 + PEEK_MS);
        assert_eq!(compact(&c, T0 + PEEK_MS).kind, ActivityKind::Media);
        cmd(&mut c, Command::PomodoroToggle, T0 + PEEK_MS);
        let v = compact(&c, T0 + PEEK_MS);
        assert_eq!((v.kind, v.peek), (ActivityKind::Pomodoro, None));
    }

    #[test]
    fn a_track_change_peeks_for_a_moment() {
        let mut c = Core::default();
        play(&mut c, "One", T0);
        let v = compact(&c, T0);
        assert_eq!(v.peek, Some(PeekKind::TrackChanged));
        assert_eq!((v.title.as_str(), v.value.as_str()), ("One", "Band"));
        assert_eq!(c.next_deadline(), Some(T0 + PEEK_MS));
        c.apply(Input::Tick, T0 + PEEK_MS);
        assert_eq!(compact(&c, T0 + PEEK_MS).peek, None);
        assert_eq!(c.next_deadline(), None);

        // Same track again (a position update, pause and play): no peek.
        c.apply(Input::NowPlaying(Some(track("One", false))), T0 + 5_000);
        play(&mut c, "One", T0 + 6_000);
        assert_eq!(compact(&c, T0 + 6_000).peek, None);
        // The next track replaces a peek that is still showing.
        play(&mut c, "Two", T0 + 7_000);
        play(&mut c, "Three", T0 + 8_000);
        let v = compact(&c, T0 + 8_000);
        assert_eq!(
            (v.title.as_str(), v.peek),
            ("Three", Some(PeekKind::TrackChanged))
        );
        assert_eq!(c.next_deadline(), Some(T0 + 8_000 + PEEK_MS));
    }

    #[test]
    fn the_view_says_when_the_track_changed() {
        let mut c = Core::default();
        // Even with the peek off: Home's Auto card goes by it.
        with(&mut c, |s| s.peek.track_change = false, T0);
        play(&mut c, "One", T0);
        let at = |c: &Core, now| c.view(now).media.and_then(|m| m.changed_at_ms);
        assert_eq!(at(&c, T0), Some(T0));
        // Pause and play again, or a position update: the same track.
        c.apply(Input::NowPlaying(Some(track("One", false))), T0 + 5_000);
        play(&mut c, "One", T0 + 6_000);
        assert_eq!(at(&c, T0 + 6_000), Some(T0));
        play(&mut c, "Two", T0 + 90_000);
        assert_eq!(at(&c, T0 + 90_000), Some(T0 + 90_000));
    }

    #[test]
    fn a_track_change_peek_can_be_turned_off() {
        let mut c = Core::default();
        with(&mut c, |s| s.peek.track_change = false, T0);
        play(&mut c, "One", T0);
        assert_eq!(compact(&c, T0).peek, None);
    }

    #[test]
    fn the_time_warning_fires_once_per_phase() {
        let mut c = Core::default();
        cmd(&mut c, Command::PomodoroToggle, T0);
        let warn_at = T0 + 20 * MIN;
        assert_eq!(c.next_deadline(), Some(warn_at));
        c.apply(Input::Tick, warn_at);
        let v = compact(&c, warn_at);
        assert_eq!(
            (v.kind, v.peek),
            (ActivityKind::Pomodoro, Some(PeekKind::TimeWarning))
        );
        assert_eq!(v.ends_at_ms, Some(T0 + 25 * MIN));
        c.apply(Input::Tick, warn_at + PEEK_MS);
        assert_eq!(compact(&c, warn_at + PEEK_MS).peek, None);

        // Pause and resume with less than the warning left: no second peek.
        cmd(&mut c, Command::PomodoroToggle, warn_at + MIN);
        cmd(&mut c, Command::PomodoroToggle, warn_at + 10 * MIN);
        assert_eq!(compact(&c, warn_at + 10 * MIN).peek, None);
        assert_eq!(c.next_deadline(), Some(T0 + 34 * MIN), "only the phase end");
    }

    #[test]
    fn short_phases_and_a_zero_warning_do_not_warn() {
        let mut c = Core::default();
        // A 10-minute timer is not longer than twice the 5-minute warning.
        cmd(&mut c, Command::TimerSet { secs: 600 }, T0);
        cmd(&mut c, Command::TimerToggle, T0);
        assert_eq!(c.next_deadline(), Some(T0 + 10 * MIN));

        let mut c = Core::default();
        with(&mut c, |s| s.peek.time_warning_secs = 0, T0);
        cmd(&mut c, Command::PomodoroToggle, T0);
        assert_eq!(c.next_deadline(), Some(T0 + 25 * MIN));
    }

    #[test]
    fn the_timer_warns_too() {
        let mut c = Core::default();
        cmd(&mut c, Command::TimerSet { secs: 1200 }, T0);
        cmd(&mut c, Command::TimerToggle, T0);
        assert_eq!(c.next_deadline(), Some(T0 + 15 * MIN));
        c.apply(Input::Tick, T0 + 15 * MIN);
        let v = compact(&c, T0 + 15 * MIN);
        assert_eq!(
            (v.kind, v.peek),
            (ActivityKind::Timer, Some(PeekKind::TimeWarning))
        );
    }

    #[test]
    fn a_warning_missed_during_sleep_shows_on_wake() {
        let mut c = Core::default();
        cmd(&mut c, Command::PomodoroToggle, T0);
        c.apply(Input::Tick, T0 + 22 * MIN);
        assert_eq!(compact(&c, T0 + 22 * MIN).peek, Some(PeekKind::TimeWarning));
    }

    #[test]
    fn an_approval_comes_before_a_peek() {
        let mut c = Core::default();
        play(&mut c, "One", T0);
        approval(&mut c, T0 + 1);
        assert_eq!(compact(&c, T0 + 1).kind, ActivityKind::Approval);
    }

    #[test]
    fn a_peek_about_something_gone_is_not_shown() {
        let mut c = Core::default();
        play(&mut c, "One", T0);
        c.apply(Input::NowPlaying(None), T0 + 1);
        assert_eq!(compact(&c, T0 + 1).kind, ActivityKind::Idle);
    }

    #[test]
    fn peek_settings_are_clamped_and_old_settings_still_load() {
        let mut c = Core::default();
        with(&mut c, |s| s.peek.time_warning_secs = 99_999, T0);
        assert_eq!(c.settings().peek.time_warning_secs, 3600);

        let old: Settings = serde_json::from_value(json!({"general":{"persist_clipboard":true}}))
            .expect("old settings");
        assert_eq!(old.peek, PeekConfig::default());
        // Keys from a build that had "When idle" and checkpoints are ignored.
        let newer: Settings = serde_json::from_value(
            json!({"general":{"resting":"hidden"},"peek":{"checkpoint_mins":5,"time_warning_secs":60}}),
        )
        .expect("settings with dropped keys");
        assert_eq!(newer.peek.time_warning_secs, 60);
    }

    /// A core with the stretch gauge on, empty after 20 minutes (it
    /// starts at half of 40).
    fn moving() -> Core {
        stretching(40)
    }

    fn stretching(mins: u32) -> Core {
        let mut c = Core::default();
        with(&mut c, |s| s.body.stretch_mins = mins, T0);
        c
    }

    /// A core with the eye break on every `mins`.
    fn blinking(mins: u32) -> Core {
        let mut c = Core::default();
        with(&mut c, |s| s.peek.eye_break_mins = mins, T0);
        c
    }

    /// Ticks at every deadline up to and including `until`, as the runtime
    /// does.
    fn run_to(c: &mut Core, until: u64) {
        while let Some(t) = c.next_deadline().filter(|&t| t <= until) {
            c.apply(Input::Tick, t);
        }
        c.apply(Input::Tick, until);
    }

    fn away(c: &mut Core, away: bool, now: u64) {
        cmd(c, Command::ScreenAway { away }, now);
    }

    #[test]
    fn an_empty_gauge_peeks_once_then_stays_quiet() {
        let mut c = moving();
        // First at 20 %: 8 of 40 minutes left, 12 minutes in.
        assert_eq!(c.next_deadline(), Some(T0 + 12 * MIN));
        c.apply(Input::Tick, T0 + 12 * MIN);
        let v = compact(&c, T0 + 12 * MIN);
        assert_eq!(
            (v.peek, v.title.as_str()),
            (Some(PeekKind::Move), "Stretch")
        );
        run_to(&mut c, T0 + 12 * MIN + NUDGE_MS);
        assert_eq!(c.next_deadline(), Some(T0 + 20 * MIN), "then when empty");
        c.apply(Input::Tick, T0 + 20 * MIN);
        let v = compact(&c, T0 + 20 * MIN);
        assert_eq!(
            (v.peek, v.title.as_str()),
            (Some(PeekKind::Move), "Stretch")
        );
        assert!(STRETCH_LINES.contains(&v.value.as_str()));
        run_to(&mut c, T0 + 20 * MIN + NUDGE_MS);
        let v = compact(&c, T0 + 20 * MIN + NUDGE_MS);
        assert_eq!(
            (v.kind, v.title.as_str(), v.value.as_str()),
            (ActivityKind::Body, "Stretch", "0%"),
            "the gauge stays in the closed notch, still and empty"
        );
        assert_eq!(c.next_deadline(), None, "empty: nothing more to say");

        // Five stretches fill half of the 40 minutes; it runs down from there.
        let at = T0 + 30 * MIN;
        for _ in 0..5 {
            cmd(&mut c, Command::BodyStretch, at);
        }
        assert_eq!(c.next_deadline(), Some(at + 12 * MIN), "its 20 % again");
        // Locking stops it; coming back goes on from where it was.
        away(&mut c, true, at + 5 * MIN);
        assert_eq!(c.next_deadline(), None);
        away(&mut c, false, at + 60 * MIN);
        assert_eq!(c.next_deadline(), Some(at + 67 * MIN));

        // A sleep without word from the shell: late, so no peek.
        c.apply(Input::Tick, at + 200 * MIN);
        assert_eq!(compact(&c, at + 200 * MIN).peek, None);
        assert_eq!(c.next_deadline(), None);

        with(&mut c, |s| s.body.stretch_mins = 0, at + 201 * MIN);
        assert_eq!(c.view(at + 201 * MIN).body, None, "off means gone");
    }

    /// Reported: after a restart the gauges showed 0 %. They were started
    /// at time 0, so the first look at the real time found them long empty.
    #[test]
    fn saved_gauges_start_at_half_when_litenotch_starts() {
        let saved: crate::state::Persisted = serde_json::from_value(
            json!({"settings":{"body":{"water_mins":90,"stretch_mins":60}}}),
        )
        .expect("saved");
        let mut c = Core::new(saved);
        c.apply(Input::Tick, T0);
        let b = c.view(T0).body.expect("gauges");
        let w = b.water.expect("water");
        assert_eq!(w.empty_at_ms, Some(T0 + 45 * MIN), "half of 90 min");
        assert_eq!(b.stretch.and_then(|s| s.empty_at_ms), Some(T0 + 30 * MIN));
        assert_eq!(compact(&c, T0).peek, None, "not announced as empty");
    }

    #[test]
    fn the_closed_notch_shows_the_gauge_that_empties_first() {
        let mut c = Core::default();
        // Water 90 min from half: empty in 45. Stretch 60 from half: in 30.
        with(
            &mut c,
            |s| {
                s.body.water_mins = 90;
                s.body.stretch_mins = 60;
            },
            T0,
        );
        let v = compact(&c, T0 + 1_000);
        assert_eq!(
            (v.kind, v.title.as_str(), v.ends_at_ms, v.total_secs),
            (
                ActivityKind::Body,
                "Stretch",
                Some(T0 + 30 * MIN),
                Some(3600)
            )
        );
        assert_eq!(v.value, "", "counting: the shell draws the level");
        // Ten stretches: now water empties first.
        for _ in 0..10 {
            cmd(&mut c, Command::BodyStretch, T0 + 2_000);
        }
        let v = compact(&c, T0 + 3_000);
        assert_eq!(
            (v.title.as_str(), v.ends_at_ms),
            ("Water", Some(T0 + 45 * MIN))
        );
        // Away: standing still, with the level written out.
        away(&mut c, true, T0 + 15 * MIN);
        let v = compact(&c, T0 + 20 * MIN);
        assert_eq!(
            (v.title.as_str(), v.ends_at_ms, v.value.as_str()),
            ("Water", None, "33%")
        );
        // Last in the order: anything else running comes first, and it can
        // be hidden.
        away(&mut c, false, T0 + 20 * MIN);
        cmd(&mut c, Command::PomodoroToggle, T0 + 20 * MIN);
        let both = c.view(T0 + 21 * MIN);
        assert_eq!(both.compact.kind, ActivityKind::Pomodoro);
        assert_eq!(
            both.compact_secondary.map(|s| s.kind),
            Some(ActivityKind::Body)
        );
        with(
            &mut c,
            |s| s.notch.hidden = vec![ActivityKind::Body],
            T0 + 21 * MIN,
        );
        assert_eq!(c.view(T0 + 21 * MIN).compact_secondary, None);
    }

    #[test]
    fn water_says_so_and_both_at_once_are_one_peek() {
        let mut c = Core::default();
        with(&mut c, |s| s.body.water_mins = 60, T0);
        run_to(&mut c, T0 + 30 * MIN);
        let v = compact(&c, T0 + 30 * MIN);
        assert_eq!((v.peek, v.title.as_str()), (Some(PeekKind::Move), "Water"));
        assert!(WATER_LINES.contains(&v.value.as_str()));

        let mut c = Core::default();
        with(
            &mut c,
            |s| {
                s.body.water_mins = 60;
                s.body.stretch_mins = 60;
            },
            T0,
        );
        run_to(&mut c, T0 + 30 * MIN);
        let v = compact(&c, T0 + 30 * MIN);
        assert_eq!(v.title, "Water and stretch");
    }

    #[test]
    fn drinking_fills_the_water_gauge_in_the_view() {
        let mut c = Core::default();
        assert_eq!(c.view(T0).body, None, "off by default");
        with(&mut c, |s| s.body.water_mins = 60, T0);
        run_to(&mut c, T0 + 60 * MIN);
        cmd(&mut c, Command::BodyDrink, T0 + 61 * MIN);
        let w = c
            .view(T0 + 61 * MIN)
            .body
            .and_then(|b| b.water)
            .expect("water");
        assert_eq!(w.empty_at_ms, Some(T0 + 91 * MIN), "a cup is half");
        assert_eq!(w.last_label.as_deref(), Some("+200 ml"));
        cmd(&mut c, Command::BodyDrink, T0 + 61 * MIN);
        let w = c
            .view(T0 + 61 * MIN)
            .body
            .and_then(|b| b.water)
            .expect("water");
        assert_eq!(
            w.empty_at_ms,
            Some(T0 + 98 * MIN + 30_000),
            "right after, a sip: 50 ml is 7.5 min"
        );
        assert_eq!(w.last_label.as_deref(), Some("+50 ml"));
        let cmd: Command = serde_json::from_str(r#"{"cmd":"body_drink"}"#).expect("command");
        assert_eq!(cmd, Command::BodyDrink);
        let cmd: Command = serde_json::from_str(r#"{"cmd":"body_stretch"}"#).expect("command");
        assert_eq!(cmd, Command::BodyStretch);
    }

    #[test]
    fn an_eye_break_is_a_quick_blink_every_few_minutes_at_the_screen() {
        assert_eq!(
            Core::default().settings().peek.eye_break_mins,
            0,
            "off by default"
        );
        let mut c = blinking(5);
        assert_eq!(c.next_deadline(), Some(T0 + 5 * MIN));
        c.apply(Input::Tick, T0 + 5 * MIN);
        let v = compact(&c, T0 + 5 * MIN);
        assert_eq!(
            (v.kind, v.peek, v.title.as_str(), v.value.as_str()),
            (
                ActivityKind::Nudge,
                Some(PeekKind::EyeBreak),
                "Eye break",
                EYE_LINES[((T0 + 5 * MIN) / MIN % 3) as usize]
            )
        );
        assert_eq!(c.next_deadline(), Some(T0 + 5 * MIN + EYE_MS), "a glance");
        c.apply(Input::Tick, T0 + 5 * MIN + EYE_MS);
        assert_eq!(compact(&c, T0 + 5 * MIN + EYE_MS).peek, None);
        assert_eq!(c.next_deadline(), Some(T0 + 10 * MIN), "once per interval");

        // Away: no wake, and the count starts over on return.
        away(&mut c, true, T0 + 7 * MIN);
        assert_eq!(c.next_deadline(), None);
        away(&mut c, false, T0 + 12 * MIN);
        assert_eq!(c.next_deadline(), Some(T0 + 17 * MIN));
        // Slept through: skipped.
        c.apply(Input::Tick, T0 + 30 * MIN);
        assert_eq!(compact(&c, T0 + 30 * MIN).peek, None);
        assert_eq!(c.next_deadline(), Some(T0 + 35 * MIN));

        with(&mut c, |s| s.peek.eye_break_mins = 0, T0 + 31 * MIN);
        assert_eq!(c.next_deadline(), None);
    }

    #[test]
    fn gauges_count_screen_time_whatever_the_focus_timer_does() {
        assert_eq!(Core::default().settings().body, BodyConfig::default());
        assert_eq!(BodyConfig::default().stretch_mins, 0, "off by default");
        // No focus session at all: it still comes after 12 minutes at the
        // Mac (its 20 %), then at 20 (empty).
        let mut c = moving();
        assert_eq!(c.next_deadline(), Some(T0 + 12 * MIN));
        c.apply(Input::Tick, T0 + 12 * MIN);
        assert_eq!(compact(&c, T0 + 12 * MIN).peek, Some(PeekKind::Move));
        run_to(&mut c, T0 + 20 * MIN);
        assert_eq!(compact(&c, T0 + 20 * MIN).peek, Some(PeekKind::Move));

        // Starting, pausing and finishing a focus session change nothing.
        let mut c = moving();
        cmd(&mut c, Command::PomodoroToggle, T0 + 5 * MIN);
        cmd(&mut c, Command::PomodoroToggle, T0 + 8 * MIN);
        cmd(&mut c, Command::PomodoroReset, T0 + 9 * MIN);
        assert_eq!(c.next_deadline(), Some(T0 + 12 * MIN));

        // A break counts too: the user is still at the screen.
        let mut c = stretching(56);
        with(&mut c, |s| s.peek.still_working = false, T0);
        cmd(&mut c, Command::PomodoroToggle, T0);
        run_to(&mut c, T0 + 26 * MIN);
        assert_eq!(c.view(T0 + 26 * MIN).pomodoro.phase, Phase::ShortBreak);
        run_to(&mut c, T0 + 28 * MIN);
        assert_eq!(compact(&c, T0 + 28 * MIN).peek, Some(PeekKind::Move));
    }

    /// Closed-lid mode on and confirmed, display at the lid.
    fn lid_mode_on(c: &mut Core, now: u64) {
        cmd(c, Command::CaffeineLid { on: true }, now);
        cmd(c, Command::CaffeineToggle, now);
        c.apply(Input::LidResult { ok: true }, now);
    }

    fn lid(c: &mut Core, closed: bool, external: bool, now: u64) {
        c.apply(
            Input::Clamshell {
                closed,
                external_display: external,
            },
            now,
        );
    }

    #[test]
    fn a_shut_lid_stops_both_reminders_counting_even_though_keep_awake_runs() {
        let mut c = moving();
        with(&mut c, |s| s.peek.eye_break_mins = 5, T0);
        lid_mode_on(&mut c, T0);
        // The Mac is awake with the lid shut, but nobody sees the screen.
        lid(&mut c, true, false, T0 + 2 * MIN);
        // Only the 12-hour limit of closed-lid mode is left to wake for.
        assert_eq!(c.next_deadline(), Some(T0 + 12 * 3_600_000));
        c.apply(Input::Tick, T0 + 30 * MIN);
        assert_eq!(compact(&c, T0 + 30 * MIN).peek, None);
        // Opening it starts the eye break over; the gauge goes on from
        // where it stood.
        lid(&mut c, false, false, T0 + 40 * MIN);
        assert_eq!(c.next_deadline(), Some(T0 + 45 * MIN), "eye break: 5 min");
        run_to(&mut c, T0 + 58 * MIN);
        let at = |mins: u64| compact(&c, T0 + mins * MIN).peek;
        assert_eq!(at(58), Some(PeekKind::Move), "2 min before, 18 after");
    }

    #[test]
    fn a_shut_lid_with_another_display_keeps_counting() {
        let mut c = moving();
        lid_mode_on(&mut c, T0);
        lid(&mut c, true, true, T0 + 2 * MIN);
        assert_eq!(c.next_deadline(), Some(T0 + 12 * MIN), "its 20 %, on time");
    }

    #[test]
    fn a_nudge_is_not_cut_short_and_what_came_with_it_follows() {
        let mut c = moving();
        cmd(&mut c, Command::PomodoroToggle, T0);
        // 25-minute focus: the Move and the 5-minute warning both fall at
        // 20 minutes.
        c.apply(Input::Tick, T0 + 20 * MIN);
        assert_eq!(compact(&c, T0 + 20 * MIN).peek, Some(PeekKind::Move));
        play(&mut c, "Song", T0 + 20 * MIN + 1_000);
        assert_eq!(
            compact(&c, T0 + 20 * MIN + 1_000).peek,
            Some(PeekKind::Move),
            "a new track waits"
        );
        let after = T0 + 20 * MIN + NUDGE_MS;
        c.apply(Input::Tick, after);
        let v = compact(&c, after);
        assert_eq!(
            (v.kind, v.peek, v.title.as_str()),
            (ActivityKind::Media, Some(PeekKind::TrackChanged), "Song"),
            "the newest waiting peek"
        );
        assert_eq!(c.next_deadline(), Some(after + PEEK_MS));
        c.apply(Input::Tick, after + PEEK_MS);
        assert_eq!(compact(&c, after + PEEK_MS).peek, None);

        // A nudge over a peek that has mostly shown does not bring it back.
        let mut c = moving();
        play(&mut c, "Song", T0 + 20 * MIN - 3_000);
        c.apply(Input::Tick, T0 + 20 * MIN);
        assert_eq!(compact(&c, T0 + 20 * MIN).peek, Some(PeekKind::Move));
        c.apply(Input::Tick, T0 + 20 * MIN + NUDGE_MS);
        assert_eq!(compact(&c, T0 + 20 * MIN + NUDGE_MS).peek, None);
    }

    #[test]
    fn a_move_wins_over_an_eye_break_at_the_same_moment() {
        let mut c = moving();
        with(&mut c, |s| s.peek.eye_break_mins = 5, T0);
        run_to(&mut c, T0 + 20 * MIN);
        assert_eq!(compact(&c, T0 + 20 * MIN).peek, Some(PeekKind::Move));
        assert_eq!(c.next_deadline(), Some(T0 + 20 * MIN + NUDGE_MS));
    }

    #[test]
    fn a_peek_waiting_through_a_sleep_is_dropped() {
        let mut c = moving();
        cmd(&mut c, Command::PomodoroToggle, T0);
        c.apply(Input::Tick, T0 + 20 * MIN);
        // The warning waits behind the Move, then the Mac sleeps.
        c.apply(Input::Tick, T0 + 22 * MIN);
        assert_eq!(compact(&c, T0 + 22 * MIN).peek, None);
    }

    /// Runs a default pomodoro through its focus and short break; the break
    /// ends at 30 minutes.
    fn through_a_break(c: &mut Core) -> u64 {
        // No still-working checks during it.
        with(c, |s| s.peek.still_working = false, T0);
        cmd(c, Command::PomodoroToggle, T0);
        // Breaks start by themselves.
        run_to(c, T0 + 25 * MIN + 5_000);
        let end = T0 + 30 * MIN;
        assert_eq!(c.next_deadline(), Some(end));
        c.apply(Input::Tick, end);
        end
    }

    #[test]
    fn a_line_follows_the_break_over_banner() {
        let mut c = Core::default();
        let end = through_a_break(&mut c);
        let v = compact(&c, end);
        assert_eq!(
            (v.kind, v.title.as_str()),
            (ActivityKind::Banner, "Break over"),
            "the banner first"
        );
        let shown = end + 5_000;
        assert_eq!(c.next_deadline(), Some(shown));
        c.apply(Input::Tick, shown);
        let v = compact(&c, shown);
        assert_eq!(
            (v.kind, v.peek, v.title.as_str()),
            (ActivityKind::Nudge, Some(PeekKind::Quote), "Break over")
        );
        assert_eq!(v.value, break_line(end));
        assert!(BREAK_LINES.contains(&v.value.as_str()));
        assert_eq!(c.next_deadline(), Some(shown + NUDGE_MS));
        c.apply(Input::Tick, shown + NUDGE_MS);
        assert_eq!(compact(&c, shown + NUDGE_MS).peek, None);
        assert_eq!(c.next_deadline(), None, "once");
        // Starting the next focus brings no second line.
        cmd(&mut c, Command::PomodoroToggle, shown + MIN);
        assert_eq!(compact(&c, shown + MIN).peek, None);
    }

    #[test]
    fn no_line_after_a_skipped_break_or_with_it_off() {
        let mut c = Core::default();
        cmd(&mut c, Command::PomodoroToggle, T0);
        cmd(&mut c, Command::PomodoroSkip, T0 + MIN);
        cmd(&mut c, Command::PomodoroSkip, T0 + 2 * MIN);
        run_to(&mut c, T0 + 3 * MIN);
        assert_eq!(compact(&c, T0 + 3 * MIN).peek, None);

        let mut c = Core::default();
        with(&mut c, |s| s.peek.break_quote = false, T0);
        let end = through_a_break(&mut c);
        run_to(&mut c, end + 6_000);
        assert_eq!(compact(&c, end + 6_000).peek, None);
    }

    #[test]
    fn a_line_waits_for_an_approval_but_not_forever() {
        let mut c = Core::default();
        cmd(&mut c, Command::PomodoroToggle, T0);
        run_to(&mut c, T0 + 25 * MIN + 5_000);
        // It expires 120 s later, 90 s after the break ends.
        approval(&mut c, T0 + 29 * MIN + 30_000);
        let end = T0 + 30 * MIN;
        run_to(&mut c, end + 30_000);
        assert_eq!(compact(&c, end + 30_000).kind, ActivityKind::Approval);
        // Over a minute after the break the line is dropped.
        let gone = end + 90_000;
        run_to(&mut c, gone);
        let v = compact(&c, gone);
        assert_ne!(v.kind, ActivityKind::Approval, "expired");
        assert_eq!(v.peek, None);
        run_to(&mut c, gone + MIN);
        assert_eq!(compact(&c, gone + MIN).peek, None);
    }

    #[test]
    fn a_line_waits_while_away() {
        let mut c = Core::default();
        let end = through_a_break(&mut c);
        away(&mut c, true, end + 1_000);
        run_to(&mut c, end + 10_000);
        assert_eq!(compact(&c, end + 10_000).peek, None);
        away(&mut c, false, end + 20_000);
        assert_eq!(compact(&c, end + 20_000).peek, Some(PeekKind::Quote));
    }

    /// A default pomodoro just into its short break (25:00 to 30:00), with
    /// the time warning off so only still-working checks fall in it.
    fn in_a_break(c: &mut Core) {
        with(c, |s| s.peek.time_warning_secs = 0, T0);
        cmd(c, Command::PomodoroToggle, T0);
        run_to(c, T0 + 25 * MIN + 5_000);
        assert!(c.break_running(0));
    }

    /// Runs to the next check and answers it with `idle` seconds.
    fn check(c: &mut Core, at: u64, idle: u32) {
        run_to(c, at - 1);
        assert!(!c.wants_idle(), "not before {at}");
        assert_eq!(c.next_deadline(), Some(at));
        c.apply(Input::Tick, at);
        assert!(c.wants_idle(), "at {at}");
        c.apply(Input::InputIdle { secs: idle }, at);
        assert!(!c.wants_idle());
    }

    #[test]
    fn working_through_a_break_gets_two_peeks_then_a_banner() {
        let mut c = Core::default();
        in_a_break(&mut c);
        let start = T0 + 25 * MIN;
        let first = start + BREAK_CHECK_FIRST_MS;
        check(&mut c, first, 2);
        let v = compact(&c, first);
        assert_eq!(
            (v.kind, v.peek, v.title.as_str(), v.value.as_str()),
            (
                ActivityKind::Nudge,
                Some(PeekKind::StillWorking),
                BREAK_TITLE,
                STILL_WORKING_LINES[0]
            )
        );
        let second = first + BREAK_CHECK_STEP_MS;
        check(&mut c, second, 0);
        assert_eq!(compact(&c, second).value, STILL_WORKING_LINES[1]);
        let third = second + BREAK_CHECK_STEP_MS;
        check(&mut c, third, 0);
        let banner = c.view(third).inbox.banner.expect("a banner");
        assert_eq!(banner.title, STILL_WORKING_BANNER);
        assert_eq!(banner.body, "4 min in, still at the keyboard.");
        assert_eq!(banner.action, Some(BannerAction::SkipBreak));
        // 5:30 is past the break's end: no fourth check.
        run_to(&mut c, start + 5 * MIN - 1);
        assert!(!c.wants_idle());
        // Its button skips the break; then the offer goes.
        cmd(&mut c, Command::PomodoroSkip, start + 5 * MIN - 1);
        assert!(!c.break_running(0));
        let b = c.view(start + 5 * MIN - 1).inbox.banner;
        assert!(b.is_none() || b.and_then(|b| b.action).is_none());
    }

    #[test]
    fn an_idle_user_is_on_a_break_and_hears_nothing() {
        let mut c = Core::default();
        in_a_break(&mut c);
        let first = T0 + 25 * MIN + BREAK_CHECK_FIRST_MS;
        check(&mut c, first, WORKING_IDLE_SECS);
        assert_eq!(compact(&c, first).peek, None);
        // Not counted: the next one is still the gentle one.
        let second = first + BREAK_CHECK_STEP_MS;
        check(&mut c, second, 1);
        assert_eq!(compact(&c, second).value, STILL_WORKING_LINES[0]);
        // An answer nobody asked for does nothing.
        c.apply(Input::InputIdle { secs: 0 }, second + 1_000);
        assert_eq!(compact(&c, second + 1_000).value, STILL_WORKING_LINES[0]);
    }

    #[test]
    fn no_checks_off_paused_away_or_in_focus() {
        let first = T0 + 25 * MIN + BREAK_CHECK_FIRST_MS;
        let mut c = Core::default();
        with(&mut c, |s| s.peek.still_working = false, T0);
        in_a_break(&mut c);
        run_to(&mut c, first + MIN);
        assert!(!c.wants_idle());

        let mut c = Core::default();
        in_a_break(&mut c);
        cmd(&mut c, Command::PomodoroToggle, first - 1_000);
        run_to(&mut c, first + MIN);
        assert!(!c.wants_idle(), "paused");

        let mut c = Core::default();
        in_a_break(&mut c);
        away(&mut c, true, first - 1_000);
        run_to(&mut c, first + MIN);
        assert!(!c.wants_idle(), "away");
        // A check asked for and then the screen locked gets no reminder.
        away(&mut c, false, first + MIN);
        let second = first + BREAK_CHECK_STEP_MS;
        run_to(&mut c, second);
        assert!(c.wants_idle());
        away(&mut c, true, second);
        c.apply(Input::InputIdle { secs: 0 }, second);
        assert_eq!(compact(&c, second).peek, None);

        // Focus phases never ask.
        let mut c = Core::default();
        cmd(&mut c, Command::PomodoroToggle, T0);
        run_to(&mut c, T0 + 20 * MIN);
        assert!(!c.wants_idle());
    }

    #[test]
    fn a_check_slept_through_is_skipped_and_a_new_break_starts_gently() {
        let mut c = Core::default();
        in_a_break(&mut c);
        let first = T0 + 25 * MIN + BREAK_CHECK_FIRST_MS;
        check(&mut c, first, 0);
        // The Mac slept past the second mark by more than a minute.
        c.apply(Input::Tick, first + BREAK_CHECK_STEP_MS + 70_000);
        assert!(!c.wants_idle());
        // The next break starts again from the gentle line.
        let mut c = Core::default();
        with(
            &mut c,
            |s| {
                s.peek.time_warning_secs = 0;
                s.pomodoro.auto_start_focus = true;
            },
            T0,
        );
        cmd(&mut c, Command::PomodoroToggle, T0);
        check(&mut c, T0 + 25 * MIN + BREAK_CHECK_FIRST_MS, 0);
        check(
            &mut c,
            T0 + 25 * MIN + BREAK_CHECK_FIRST_MS + BREAK_CHECK_STEP_MS,
            0,
        );
        // Focus 30:00 to 55:00, the next break from 55:00.
        let next = T0 + 55 * MIN + BREAK_CHECK_FIRST_MS;
        check(&mut c, next, 0);
        assert_eq!(compact(&c, next).value, STILL_WORKING_LINES[0]);
    }

    #[test]
    fn still_working_lines_fit_and_are_on_by_default() {
        for line in STILL_WORKING_LINES {
            assert!(line.chars().count() <= 45, "{line}");
        }
        assert!(PeekConfig::default().still_working);
        let old: PeekConfig = serde_json::from_value(json!({"track_change": true})).unwrap();
        assert!(old.still_working, "settings saved before it default to on");
        assert_eq!(break_checks(0), 0);
        assert_eq!(break_checks(BREAK_CHECK_FIRST_MS), 1);
        assert_eq!(
            break_checks(BREAK_CHECK_FIRST_MS + BREAK_CHECK_STEP_MS - 1),
            1
        );
    }

    #[test]
    fn break_lines_are_short_distinct_and_picked_by_the_moment() {
        for line in BREAK_LINES {
            assert!(line.chars().count() <= 30, "{line}");
        }
        let mut sorted = BREAK_LINES.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), BREAK_LINES.len());
        assert_eq!(break_line(0), BREAK_LINES[0]);
        assert_eq!(break_line(1_999), BREAK_LINES[1]);
        assert_eq!(break_line(20_000), BREAK_LINES[0]);
    }

    #[test]
    fn gauge_lines_are_short_and_picked_by_the_moment() {
        for line in WATER_LINES.iter().chain(STRETCH_LINES.iter()) {
            assert!(line.chars().count() <= 30, "{line}");
        }
        assert!(BOTH_LINE.chars().count() <= 30);
        assert_eq!(pick(&STRETCH_LINES, 0), STRETCH_LINES[0]);
        assert_eq!(pick(&STRETCH_LINES, 5_000), STRETCH_LINES[1]);
    }

    #[test]
    fn reminder_settings_are_clamped_and_load_from_old_files() {
        let mut c = Core::default();
        with(
            &mut c,
            |s| {
                s.peek.eye_break_mins = 999;
                s.body.water_mins = 1;
            },
            T0,
        );
        assert_eq!(c.settings().peek.eye_break_mins, 60);
        assert_eq!(c.settings().body.water_mins, 5);
        with(&mut c, |s| s.body.stretch_mins = 9_999, T0);
        assert_eq!(c.settings().body.stretch_mins, 180);
        with(&mut c, |s| s.peek.eye_break_mins = 0, T0);
        assert_eq!(c.settings().peek.eye_break_mins, 0, "0 stays off");

        let old: PeekConfig =
            serde_json::from_value(json!({"track_change":false})).expect("old peek settings");
        assert_eq!(
            (old.eye_break_mins, old.move_mins, old.break_quote),
            (0, 0, true)
        );
        // Settings saved when Move could count focus time still load.
        let older: PeekConfig =
            serde_json::from_value(json!({"move_mins":20,"move_counts":"focus"}))
                .expect("older peek settings");
        assert_eq!(older.move_mins, 20);
        // A saved Move reminder becomes both gauges, and is not written
        // back.
        let saved: crate::state::Persisted =
            serde_json::from_value(json!({"settings":{"peek":{"move_mins":20}}})).expect("saved");
        let c = Core::new(saved);
        assert_eq!(
            (c.settings().body.water_mins, c.settings().body.stretch_mins),
            (20, 20)
        );
        assert_eq!(c.settings().peek.move_mins, 0);
        let written = serde_json::to_value(c.settings()).expect("json");
        assert!(written["peek"].get("move_mins").is_none());
        // Gauges already set win over an old Move value.
        let both: crate::state::Persisted = serde_json::from_value(
            json!({"settings":{"peek":{"move_mins":20},"body":{"water_mins":45}}}),
        )
        .expect("saved");
        assert_eq!(Core::new(both).settings().body.stretch_mins, 0);
        let cmd: Command =
            serde_json::from_str(r#"{"cmd":"screen_away","away":true}"#).expect("command");
        assert_eq!(cmd, Command::ScreenAway { away: true });
    }
}
