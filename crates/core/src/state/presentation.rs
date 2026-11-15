//! What the closed notch shows, in three layers (the top one wins):
//!
//! 1. **Interrupt**: a pending approval, then a banner.
//! 2. **Peek**: a few seconds about one of the user's own activities (the
//!    track changed, a countdown is about to end), then it goes away by
//!    itself. Peeks never enter the inbox and focus time does not hold them.
//! 3. **Activity**: the running activities ranked by `settings.notch`
//!    (`Core::compact`).

use serde::{Deserialize, Serialize};

use super::{
    mmss, phase_label, ActivityKind, CompactView, Core, MediaView, Phase, PomodoroView, RunState,
    TimerRun,
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
}

impl Default for PeekConfig {
    fn default() -> Self {
        Self {
            track_change: true,
            time_warning_secs: 300,
        }
    }
}

impl PeekConfig {
    pub(super) fn sanitized(self) -> Self {
        Self {
            time_warning_secs: self.time_warning_secs.min(3600),
            ..self
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PeekKind {
    TrackChanged,
    TimeWarning,
}

/// How long a peek stays.
pub const PEEK_MS: u64 = 4_000;

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
    /// The countdown it is about; `None` for a track change.
    pub clock: Option<Clock>,
    pub until_ms: u64,
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

    /// Records a track change from the media module.
    pub(super) fn track_changed(&mut self, now: u64) {
        if self.settings.peek.track_change {
            self.peek = Some(Peek {
                kind: PeekKind::TrackChanged,
                clock: None,
                until_ms: now.saturating_add(PEEK_MS),
            });
        }
    }

    /// Part of `settle`: starts a peek when a running countdown crosses the
    /// warning since the last look, and ends an expired peek.
    ///
    /// A crossing needs time left to go from above a mark to at or below it
    /// while running. Pausing keeps time left still, so pause and resume
    /// never repeat a peek; a new phase jumps back up, which arms it again.
    pub(super) fn settle_peeks(&mut self, now: u64) {
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
            if !(warn > 0 && cur.total_ms > 2 * warn && prev > warn && cur.left_ms <= warn) {
                continue;
            }
            self.peek = Some(Peek {
                kind: PeekKind::TimeWarning,
                clock: Some(clock),
                until_ms: now.saturating_add(PEEK_MS),
            });
        }
        if self.peek.is_some_and(|p| p.until_ms <= now) {
            self.peek = None;
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
        }
        times.into_iter().flatten().min()
    }

    /// The current peek, if what it is about is still there.
    pub(super) fn peek_view(
        &self,
        pomodoro: &PomodoroView,
        media: &Option<MediaView>,
    ) -> Option<CompactView> {
        let peek = self.peek?;
        let shown = match peek.clock {
            None => playing_view(media)?,
            Some(Clock::Pomodoro) => pomodoro_view(pomodoro)?,
            Some(Clock::Timer) => self.timer_view()?,
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
    use crate::media::NowPlaying;
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
}
