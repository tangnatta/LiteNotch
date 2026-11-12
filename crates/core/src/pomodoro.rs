//! Pomodoro state machine. Pure logic: time is always passed in as Unix ms.

use serde::{Deserialize, Serialize};

const MIN_SECS: u32 = 10;
const MAX_SECS: u32 = 14_400;
const MIN_ROUNDS: u32 = 1;
const MAX_ROUNDS: u32 = 12;
const DAY_SECS: i64 = 86_400;

/// User-tunable timer settings. Out-of-range values are clamped on use.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PomodoroConfig {
    /// Focus length in seconds (10..=14400).
    pub focus_secs: u32,
    /// Short break length in seconds (10..=14400).
    pub short_break_secs: u32,
    /// Long break length in seconds (10..=14400).
    pub long_break_secs: u32,
    /// Focus sessions before a long break (1..=12).
    pub rounds_before_long: u32,
    /// Start a break automatically after focus ends.
    pub auto_start_breaks: bool,
    /// Start focus automatically after a break ends.
    pub auto_start_focus: bool,
    /// Local offset from UTC, used only to decide when "today" rolls over.
    pub utc_offset_secs: i32,
}

impl Default for PomodoroConfig {
    fn default() -> Self {
        Self {
            focus_secs: 1500,
            short_break_secs: 300,
            long_break_secs: 900,
            rounds_before_long: 4,
            auto_start_breaks: true,
            auto_start_focus: false,
            utc_offset_secs: 0,
        }
    }
}

impl PomodoroConfig {
    /// Returns a copy with every field forced into its allowed range.
    pub fn clamped(&self) -> Self {
        Self {
            focus_secs: self.focus_secs.clamp(MIN_SECS, MAX_SECS),
            short_break_secs: self.short_break_secs.clamp(MIN_SECS, MAX_SECS),
            long_break_secs: self.long_break_secs.clamp(MIN_SECS, MAX_SECS),
            rounds_before_long: self.rounds_before_long.clamp(MIN_ROUNDS, MAX_ROUNDS),
            ..self.clone()
        }
    }
}

/// Which part of the cycle the timer is in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    /// Nothing started yet (or after `reset`).
    Idle,
    /// Working.
    Focus,
    /// Short rest between focus sessions.
    ShortBreak,
    /// Long rest after a full set of rounds.
    LongBreak,
}

/// Whether the clock is ticking.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RunState {
    /// Not running; the phase waits for `start`.
    Stopped,
    /// Counting down.
    Running,
    /// Frozen mid-phase.
    Paused,
}

/// Something a caller may want to notify the user about.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PomodoroEvent {
    /// A phase began counting down.
    PhaseStarted {
        /// The phase that began.
        phase: Phase,
    },
    /// A phase ended, naturally or via `skip`.
    PhaseCompleted {
        /// The phase that ended.
        phase: Phase,
        /// True when the user skipped it.
        skipped: bool,
    },
}

/// Per-day counters, exposed so callers can persist them.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PomodoroStats {
    /// Local day number the counters belong to.
    pub day: i64,
    /// Focus sessions fully completed that day.
    pub completed_today: u32,
    /// Seconds of completed focus that day.
    pub focus_secs_today: u64,
}

/// View of the timer for UI rendering.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PomodoroSnapshot {
    /// Current phase.
    pub phase: Phase,
    /// Current run state.
    pub run_state: RunState,
    /// Whole seconds left, rounded up.
    pub remaining_secs: u32,
    /// Length of the current phase in seconds.
    pub total_secs: u32,
    /// Elapsed fraction of the phase, 0.0..=1.0.
    pub progress: f32,
    /// Focus sessions completed in the current cycle (0..rounds_before_long).
    pub round: u32,
    /// Configured rounds before a long break.
    pub rounds_before_long: u32,
    /// Focus sessions completed today.
    pub completed_today: u32,
    /// Focus seconds completed today.
    pub focus_secs_today: u64,
}

/// The timer itself.
#[derive(Debug, Clone)]
pub struct Pomodoro {
    cfg: PomodoroConfig,
    phase: Phase,
    run_state: RunState,
    total_ms: u64,
    /// Absolute end time; meaningful only while running.
    deadline_ms: u64,
    /// Time left; meaningful only while not running.
    remaining_ms: u64,
    round: u32,
    long_pending: bool,
    stats: PomodoroStats,
}

impl Pomodoro {
    /// Creates an idle timer; the config is clamped.
    pub fn new(cfg: PomodoroConfig) -> Self {
        let cfg = cfg.clamped();
        let total_ms = u64::from(cfg.focus_secs) * 1000;
        Self {
            cfg,
            phase: Phase::Idle,
            run_state: RunState::Stopped,
            total_ms,
            deadline_ms: 0,
            remaining_ms: total_ms,
            round: 0,
            long_pending: false,
            stats: PomodoroStats::default(),
        }
    }

    /// Current (clamped) config.
    pub fn config(&self) -> &PomodoroConfig {
        &self.cfg
    }

    /// Replaces the config; a running phase keeps its length until the next one.
    pub fn set_config(&mut self, cfg: PomodoroConfig) {
        self.cfg = cfg.clamped();
        if self.phase == Phase::Idle {
            self.total_ms = self.phase_ms(Phase::Focus);
            self.remaining_ms = self.total_ms;
        }
    }

    /// Starts the current phase (focus when idle); resumes if paused.
    pub fn start(&mut self, now_ms: u64) -> Vec<PomodoroEvent> {
        match self.run_state {
            RunState::Running => Vec::new(),
            RunState::Paused => self.resume(now_ms),
            RunState::Stopped => {
                let phase = if self.phase == Phase::Idle {
                    Phase::Focus
                } else {
                    self.phase
                };
                self.begin(phase, now_ms);
                vec![PomodoroEvent::PhaseStarted { phase }]
            }
        }
    }

    /// Freezes the remaining time; no-op unless running.
    pub fn pause(&mut self, now_ms: u64) -> Vec<PomodoroEvent> {
        if self.run_state == RunState::Running {
            self.remaining_ms = self.remaining_at(now_ms);
            self.run_state = RunState::Paused;
        }
        Vec::new()
    }

    /// Continues a paused phase; no-op otherwise.
    pub fn resume(&mut self, now_ms: u64) -> Vec<PomodoroEvent> {
        if self.run_state == RunState::Paused {
            self.deadline_ms = now_ms.saturating_add(self.remaining_ms);
            self.run_state = RunState::Running;
        }
        Vec::new()
    }

    /// Pauses when running, resumes when paused, starts when stopped.
    pub fn toggle(&mut self, now_ms: u64) -> Vec<PomodoroEvent> {
        match self.run_state {
            RunState::Running => self.pause(now_ms),
            RunState::Paused => self.resume(now_ms),
            RunState::Stopped => self.start(now_ms),
        }
    }

    /// Ends the current phase early without credit; no-op when idle.
    pub fn skip(&mut self, now_ms: u64) -> Vec<PomodoroEvent> {
        if self.phase == Phase::Idle {
            return Vec::new();
        }
        self.complete(now_ms, true)
    }

    /// Back to idle with the cycle cleared; today's stats are kept.
    pub fn reset(&mut self) -> Vec<PomodoroEvent> {
        self.phase = Phase::Idle;
        self.run_state = RunState::Stopped;
        self.round = 0;
        self.long_pending = false;
        self.total_ms = self.phase_ms(Phase::Focus);
        self.remaining_ms = self.total_ms;
        self.deadline_ms = 0;
        Vec::new()
    }

    /// Advances time. Completes at most one phase per call, so a long gap
    /// never produces a catch-up chain.
    pub fn tick(&mut self, now_ms: u64) -> Vec<PomodoroEvent> {
        if self.run_state == RunState::Running && now_ms >= self.deadline_ms {
            self.complete(now_ms, false)
        } else {
            Vec::new()
        }
    }

    /// UI view at `now_ms`; stats from a previous local day read as zero.
    pub fn snapshot(&self, now_ms: u64) -> PomodoroSnapshot {
        let remaining_ms = if self.run_state == RunState::Running {
            self.remaining_at(now_ms)
        } else {
            self.remaining_ms.min(self.total_ms)
        };
        let progress = if self.total_ms == 0 {
            0.0
        } else {
            (1.0 - remaining_ms as f64 / self.total_ms as f64).clamp(0.0, 1.0) as f32
        };
        let (completed_today, focus_secs_today) = if self.stats.day == self.day_of(now_ms) {
            (self.stats.completed_today, self.stats.focus_secs_today)
        } else {
            (0, 0)
        };
        PomodoroSnapshot {
            phase: self.phase,
            run_state: self.run_state,
            remaining_secs: remaining_ms.div_ceil(1000) as u32,
            total_secs: (self.total_ms / 1000) as u32,
            progress,
            round: self.round,
            rounds_before_long: self.cfg.rounds_before_long,
            completed_today,
            focus_secs_today,
        }
    }

    /// When `tick` next needs to run; `None` unless running.
    pub fn next_deadline(&self) -> Option<u64> {
        (self.run_state == RunState::Running).then_some(self.deadline_ms)
    }

    /// True while a focus phase is counting down.
    pub fn is_focus_running(&self) -> bool {
        self.phase == Phase::Focus && self.run_state == RunState::Running
    }

    /// Current day counters, for persistence.
    pub fn stats(&self) -> PomodoroStats {
        self.stats.clone()
    }

    /// Loads persisted counters; stale days are zeroed on next use.
    pub fn restore_stats(&mut self, stats: PomodoroStats) {
        self.stats = stats;
    }

    fn phase_ms(&self, phase: Phase) -> u64 {
        let secs = match phase {
            Phase::Idle | Phase::Focus => self.cfg.focus_secs,
            Phase::ShortBreak => self.cfg.short_break_secs,
            Phase::LongBreak => self.cfg.long_break_secs,
        };
        u64::from(secs) * 1000
    }

    /// Clamped to `total_ms` so a backwards clock cannot inflate the time left.
    fn remaining_at(&self, now_ms: u64) -> u64 {
        self.deadline_ms.saturating_sub(now_ms).min(self.total_ms)
    }

    fn day_of(&self, now_ms: u64) -> i64 {
        let secs = i64::try_from(now_ms / 1000).unwrap_or(i64::MAX);
        secs.saturating_add(i64::from(self.cfg.utc_offset_secs))
            .div_euclid(DAY_SECS)
    }

    fn begin(&mut self, phase: Phase, now_ms: u64) {
        self.phase = phase;
        self.total_ms = self.phase_ms(phase);
        self.deadline_ms = now_ms.saturating_add(self.total_ms);
        self.remaining_ms = self.total_ms;
        self.run_state = RunState::Running;
    }

    fn complete(&mut self, now_ms: u64, skipped: bool) -> Vec<PomodoroEvent> {
        let done = self.phase;
        let mut events = vec![PomodoroEvent::PhaseCompleted {
            phase: done,
            skipped,
        }];
        if done == Phase::Focus && !skipped {
            let day = self.day_of(now_ms);
            if self.stats.day != day {
                self.stats = PomodoroStats {
                    day,
                    ..PomodoroStats::default()
                };
            }
            self.stats.completed_today = self.stats.completed_today.saturating_add(1);
            self.stats.focus_secs_today = self
                .stats
                .focus_secs_today
                .saturating_add(self.total_ms / 1000);
            self.round += 1;
            if self.round >= self.cfg.rounds_before_long {
                self.round = 0;
                self.long_pending = true;
            }
        }
        let (next, auto) = if done == Phase::Focus {
            let next = if self.long_pending {
                self.long_pending = false;
                Phase::LongBreak
            } else {
                Phase::ShortBreak
            };
            (next, self.cfg.auto_start_breaks)
        } else {
            (Phase::Focus, self.cfg.auto_start_focus)
        };
        if auto {
            self.begin(next, now_ms);
            events.push(PomodoroEvent::PhaseStarted { phase: next });
        } else {
            self.phase = next;
            self.run_state = RunState::Stopped;
            self.total_ms = self.phase_ms(next);
            self.remaining_ms = self.total_ms;
            self.deadline_ms = 0;
        }
        events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: u64 = 1_700_000_000_000;

    fn cfg() -> PomodoroConfig {
        PomodoroConfig {
            focus_secs: 100,
            short_break_secs: 20,
            long_break_secs: 60,
            rounds_before_long: 2,
            auto_start_breaks: true,
            auto_start_focus: false,
            utc_offset_secs: 0,
        }
    }

    fn started(c: PomodoroConfig) -> Pomodoro {
        let mut p = Pomodoro::new(c);
        p.start(T0);
        p
    }

    #[test]
    fn defaults_match_contract() {
        let c = PomodoroConfig::default();
        assert_eq!(c.focus_secs, 1500);
        assert_eq!(c.short_break_secs, 300);
        assert_eq!(c.long_break_secs, 900);
        assert_eq!(c.rounds_before_long, 4);
        assert!(c.auto_start_breaks);
        assert!(!c.auto_start_focus);
        assert_eq!(c.utc_offset_secs, 0);
    }

    #[test]
    fn config_deserializes_partial_json_with_defaults() {
        let c: PomodoroConfig = serde_json::from_str(r#"{"focus_secs":60}"#).unwrap();
        assert_eq!(c.focus_secs, 60);
        assert_eq!(c.short_break_secs, 300);
    }

    #[test]
    fn clamps_low_and_high_values() {
        let c = PomodoroConfig {
            focus_secs: 0,
            short_break_secs: 1,
            long_break_secs: u32::MAX,
            rounds_before_long: 0,
            ..PomodoroConfig::default()
        }
        .clamped();
        assert_eq!(c.focus_secs, 10);
        assert_eq!(c.short_break_secs, 10);
        assert_eq!(c.long_break_secs, 14_400);
        assert_eq!(c.rounds_before_long, 1);
        let c = PomodoroConfig {
            rounds_before_long: 99,
            ..PomodoroConfig::default()
        }
        .clamped();
        assert_eq!(c.rounds_before_long, 12);
    }

    #[test]
    fn new_clamps_config_and_is_idle() {
        let p = Pomodoro::new(PomodoroConfig {
            focus_secs: 0,
            ..PomodoroConfig::default()
        });
        assert_eq!(p.config().focus_secs, 10);
        let s = p.snapshot(T0);
        assert_eq!(s.phase, Phase::Idle);
        assert_eq!(s.run_state, RunState::Stopped);
        assert_eq!(s.remaining_secs, 10);
        assert_eq!(s.total_secs, 10);
        assert_eq!(s.progress, 0.0);
        assert_eq!(p.next_deadline(), None);
        assert!(!p.is_focus_running());
    }

    #[test]
    fn start_from_idle_begins_focus() {
        let mut p = Pomodoro::new(cfg());
        let ev = p.start(T0);
        assert_eq!(
            ev,
            vec![PomodoroEvent::PhaseStarted {
                phase: Phase::Focus
            }]
        );
        assert!(p.is_focus_running());
        assert_eq!(p.next_deadline(), Some(T0 + 100_000));
    }

    #[test]
    fn start_while_running_is_noop() {
        let mut p = started(cfg());
        assert!(p.start(T0 + 5000).is_empty());
        assert_eq!(p.next_deadline(), Some(T0 + 100_000));
    }

    #[test]
    fn start_while_paused_resumes() {
        let mut p = started(cfg());
        p.pause(T0 + 40_000);
        let ev = p.start(T0 + 50_000);
        assert!(ev.is_empty());
        assert_eq!(p.next_deadline(), Some(T0 + 110_000));
    }

    #[test]
    fn pause_freezes_remaining_time() {
        let mut p = started(cfg());
        assert!(p.pause(T0 + 30_000).is_empty());
        let s = p.snapshot(T0 + 30_000);
        assert_eq!(s.run_state, RunState::Paused);
        assert_eq!(s.remaining_secs, 70);
        assert_eq!(p.snapshot(T0 + 9_999_999).remaining_secs, 70);
        assert_eq!(p.next_deadline(), None);
        assert!(!p.is_focus_running());
        assert!(p.tick(T0 + 9_999_999).is_empty());
    }

    #[test]
    fn pause_when_not_running_is_noop() {
        let mut p = Pomodoro::new(cfg());
        assert!(p.pause(T0).is_empty());
        assert_eq!(p.snapshot(T0).run_state, RunState::Stopped);
        let mut p = started(cfg());
        p.pause(T0 + 10_000);
        p.pause(T0 + 90_000);
        assert_eq!(p.snapshot(T0 + 90_000).remaining_secs, 90);
    }

    #[test]
    fn resume_continues_from_frozen_time() {
        let mut p = started(cfg());
        p.pause(T0 + 30_000);
        assert!(p.resume(T0 + 500_000).is_empty());
        assert_eq!(p.next_deadline(), Some(T0 + 570_000));
        assert!(p.is_focus_running());
    }

    #[test]
    fn resume_when_not_paused_is_noop() {
        let mut p = started(cfg());
        p.resume(T0 + 10_000);
        assert_eq!(p.next_deadline(), Some(T0 + 100_000));
        let mut p = Pomodoro::new(cfg());
        p.resume(T0);
        assert_eq!(p.snapshot(T0).run_state, RunState::Stopped);
    }

    #[test]
    fn toggle_cycles_through_states() {
        let mut p = Pomodoro::new(cfg());
        assert_eq!(p.toggle(T0).len(), 1);
        assert_eq!(p.snapshot(T0).run_state, RunState::Running);
        p.toggle(T0 + 1000);
        assert_eq!(p.snapshot(T0 + 1000).run_state, RunState::Paused);
        p.toggle(T0 + 2000);
        assert_eq!(p.snapshot(T0 + 2000).run_state, RunState::Running);
    }

    #[test]
    fn tick_before_deadline_does_nothing() {
        let mut p = started(cfg());
        assert!(p.tick(T0 + 99_999).is_empty());
        assert!(p.tick(T0).is_empty());
    }

    #[test]
    fn tick_at_deadline_completes_focus_and_starts_break() {
        let mut p = started(cfg());
        let ev = p.tick(T0 + 100_000);
        assert_eq!(
            ev,
            vec![
                PomodoroEvent::PhaseCompleted {
                    phase: Phase::Focus,
                    skipped: false
                },
                PomodoroEvent::PhaseStarted {
                    phase: Phase::ShortBreak
                },
            ]
        );
        let s = p.snapshot(T0 + 100_000);
        assert_eq!(s.phase, Phase::ShortBreak);
        assert_eq!(s.total_secs, 20);
        assert_eq!(p.next_deadline(), Some(T0 + 120_000));
    }

    #[test]
    fn tick_is_idempotent_for_same_time() {
        let mut p = started(cfg());
        assert!(!p.tick(T0 + 100_000).is_empty());
        assert!(p.tick(T0 + 100_000).is_empty());
        assert!(p.tick(T0 + 100_000).is_empty());
        assert_eq!(p.snapshot(T0 + 100_000).completed_today, 1);
    }

    #[test]
    fn long_gap_completes_only_current_phase() {
        let mut p = started(cfg());
        let ev = p.tick(T0 + 10_000_000);
        assert_eq!(ev.len(), 2);
        let s = p.snapshot(T0 + 10_000_000);
        assert_eq!(s.phase, Phase::ShortBreak);
        assert_eq!(s.remaining_secs, 20);
        assert_eq!(p.next_deadline(), Some(T0 + 10_020_000));
    }

    #[test]
    fn break_end_waits_when_auto_start_focus_off() {
        let mut p = started(cfg());
        p.tick(T0 + 100_000);
        let ev = p.tick(T0 + 120_000);
        assert_eq!(
            ev,
            vec![PomodoroEvent::PhaseCompleted {
                phase: Phase::ShortBreak,
                skipped: false
            }]
        );
        let s = p.snapshot(T0 + 120_000);
        assert_eq!(s.phase, Phase::Focus);
        assert_eq!(s.run_state, RunState::Stopped);
        assert_eq!(s.remaining_secs, 100);
        assert_eq!(p.next_deadline(), None);
        let ev = p.start(T0 + 200_000);
        assert_eq!(
            ev,
            vec![PomodoroEvent::PhaseStarted {
                phase: Phase::Focus
            }]
        );
    }

    #[test]
    fn break_end_auto_starts_focus_when_enabled() {
        let mut p = started(PomodoroConfig {
            auto_start_focus: true,
            ..cfg()
        });
        p.tick(T0 + 100_000);
        let ev = p.tick(T0 + 120_000);
        assert_eq!(ev.len(), 2);
        assert!(p.is_focus_running());
    }

    #[test]
    fn focus_end_waits_when_auto_start_breaks_off() {
        let mut p = started(PomodoroConfig {
            auto_start_breaks: false,
            ..cfg()
        });
        let ev = p.tick(T0 + 100_000);
        assert_eq!(ev.len(), 1);
        let s = p.snapshot(T0 + 100_000);
        assert_eq!(s.phase, Phase::ShortBreak);
        assert_eq!(s.run_state, RunState::Stopped);
        assert_eq!(s.remaining_secs, 20);
        assert_eq!(s.completed_today, 1);
    }

    #[test]
    fn long_break_after_configured_rounds_and_round_resets() {
        let mut p = started(cfg());
        let mut t = T0 + 100_000;
        p.tick(t);
        assert_eq!(p.snapshot(t).round, 1);
        t += 20_000;
        p.tick(t);
        p.start(t);
        t += 100_000;
        let ev = p.tick(t);
        assert!(ev.contains(&PomodoroEvent::PhaseStarted {
            phase: Phase::LongBreak
        }));
        let s = p.snapshot(t);
        assert_eq!(s.round, 0);
        assert_eq!(s.total_secs, 60);
        assert_eq!(s.completed_today, 2);
        t += 60_000;
        p.tick(t);
        p.start(t);
        t += 100_000;
        let ev = p.tick(t);
        assert!(ev.contains(&PomodoroEvent::PhaseStarted {
            phase: Phase::ShortBreak
        }));
        assert_eq!(p.snapshot(t).round, 1);
    }

    #[test]
    fn single_round_cycle_always_long_break() {
        let mut p = started(PomodoroConfig {
            rounds_before_long: 1,
            ..cfg()
        });
        p.tick(T0 + 100_000);
        assert_eq!(p.snapshot(T0 + 100_000).phase, Phase::LongBreak);
    }

    #[test]
    fn skip_focus_gives_no_credit_and_starts_break() {
        let mut p = started(cfg());
        let ev = p.skip(T0 + 10_000);
        assert_eq!(
            ev[0],
            PomodoroEvent::PhaseCompleted {
                phase: Phase::Focus,
                skipped: true
            }
        );
        let s = p.snapshot(T0 + 10_000);
        assert_eq!(s.phase, Phase::ShortBreak);
        assert_eq!(s.completed_today, 0);
        assert_eq!(s.focus_secs_today, 0);
        assert_eq!(s.round, 0);
    }

    #[test]
    fn skip_break_moves_to_focus() {
        let mut p = started(cfg());
        p.skip(T0);
        let ev = p.skip(T0 + 1000);
        assert_eq!(
            ev,
            vec![PomodoroEvent::PhaseCompleted {
                phase: Phase::ShortBreak,
                skipped: true
            }]
        );
        assert_eq!(p.snapshot(T0 + 1000).phase, Phase::Focus);
    }

    #[test]
    fn skip_when_idle_is_noop() {
        let mut p = Pomodoro::new(cfg());
        assert!(p.skip(T0).is_empty());
        assert_eq!(p.snapshot(T0).phase, Phase::Idle);
    }

    #[test]
    fn skip_while_paused_advances_phase() {
        let mut p = started(cfg());
        p.pause(T0 + 1000);
        let ev = p.skip(T0 + 2000);
        assert_eq!(ev.len(), 2);
        assert_eq!(p.snapshot(T0 + 2000).phase, Phase::ShortBreak);
        assert_eq!(p.snapshot(T0 + 2000).run_state, RunState::Running);
    }

    #[test]
    fn skip_pending_stopped_phase_advances_without_starting() {
        let mut p = started(PomodoroConfig {
            auto_start_breaks: false,
            ..cfg()
        });
        p.tick(T0 + 100_000);
        let ev = p.skip(T0 + 121_000);
        assert_eq!(ev.len(), 1);
        let s = p.snapshot(T0 + 121_000);
        assert_eq!(s.phase, Phase::Focus);
        assert_eq!(s.run_state, RunState::Stopped);
    }

    #[test]
    fn reset_returns_to_idle_but_keeps_stats() {
        let mut p = started(cfg());
        p.tick(T0 + 100_000);
        assert!(p.reset().is_empty());
        let s = p.snapshot(T0 + 100_000);
        assert_eq!(s.phase, Phase::Idle);
        assert_eq!(s.run_state, RunState::Stopped);
        assert_eq!(s.round, 0);
        assert_eq!(s.completed_today, 1);
        assert_eq!(s.remaining_secs, 100);
        assert_eq!(p.next_deadline(), None);
    }

    #[test]
    fn reset_clears_pending_long_break() {
        let mut p = started(PomodoroConfig {
            auto_start_breaks: false,
            rounds_before_long: 1,
            ..cfg()
        });
        p.tick(T0 + 100_000);
        p.reset();
        p.start(T0 + 200_000);
        p.tick(T0 + 300_000);
        assert_eq!(p.snapshot(T0 + 300_000).phase, Phase::LongBreak);
    }

    #[test]
    fn set_config_applies_from_next_phase() {
        let mut p = started(cfg());
        p.set_config(PomodoroConfig {
            focus_secs: 500,
            short_break_secs: 40,
            ..cfg()
        });
        assert_eq!(p.snapshot(T0).total_secs, 100);
        assert_eq!(p.next_deadline(), Some(T0 + 100_000));
        p.tick(T0 + 100_000);
        assert_eq!(p.snapshot(T0 + 100_000).total_secs, 40);
    }

    #[test]
    fn set_config_while_idle_updates_displayed_total() {
        let mut p = Pomodoro::new(cfg());
        p.set_config(PomodoroConfig {
            focus_secs: 0,
            ..cfg()
        });
        assert_eq!(p.snapshot(T0).total_secs, 10);
        assert_eq!(p.config().focus_secs, 10);
    }

    #[test]
    fn set_config_pending_phase_uses_new_length_on_start() {
        let mut p = started(PomodoroConfig {
            auto_start_breaks: false,
            ..cfg()
        });
        p.tick(T0 + 100_000);
        p.set_config(PomodoroConfig {
            short_break_secs: 45,
            auto_start_breaks: false,
            ..cfg()
        });
        p.start(T0 + 110_000);
        assert_eq!(p.snapshot(T0 + 110_000).total_secs, 45);
    }

    #[test]
    fn clock_going_backwards_does_not_inflate_or_complete() {
        let mut p = started(cfg());
        let s = p.snapshot(T0 - 50_000);
        assert_eq!(s.remaining_secs, 100);
        assert_eq!(s.progress, 0.0);
        assert!(p.tick(T0 - 50_000).is_empty());
        p.pause(T0 - 50_000);
        assert_eq!(p.snapshot(T0).remaining_secs, 100);
    }

    #[test]
    fn progress_and_remaining_round_up() {
        let p = started(cfg());
        let s = p.snapshot(T0 + 25_000);
        assert!((s.progress - 0.25).abs() < 1e-6);
        assert_eq!(s.remaining_secs, 75);
        assert_eq!(p.snapshot(T0 + 25_001).remaining_secs, 75);
        assert_eq!(p.snapshot(T0 + 100_000).progress, 1.0);
        assert_eq!(p.snapshot(T0 + 999_999_999).remaining_secs, 0);
    }

    #[test]
    fn huge_now_saturates_without_panic() {
        let mut p = Pomodoro::new(cfg());
        p.start(u64::MAX);
        assert_eq!(p.next_deadline(), Some(u64::MAX));
        let s = p.snapshot(u64::MAX);
        assert_eq!(s.remaining_secs, 0);
        p.pause(u64::MAX);
        p.resume(u64::MAX);
        assert!(!p.tick(u64::MAX).is_empty());
    }

    #[test]
    fn zero_now_works() {
        let mut p = Pomodoro::new(cfg());
        p.start(0);
        assert_eq!(p.next_deadline(), Some(100_000));
        assert_eq!(p.tick(100_000).len(), 2);
    }

    #[test]
    fn focus_seconds_accumulate_using_phase_length() {
        let mut p = started(PomodoroConfig {
            auto_start_breaks: false,
            ..cfg()
        });
        p.tick(T0 + 100_000);
        p.set_config(PomodoroConfig {
            focus_secs: 300,
            auto_start_breaks: false,
            ..cfg()
        });
        p.start(T0 + 101_000);
        p.tick(T0 + 121_000);
        p.start(T0 + 122_000);
        p.tick(T0 + 422_000);
        let s = p.snapshot(T0 + 422_000);
        assert_eq!(s.completed_today, 2);
        assert_eq!(s.focus_secs_today, 400);
    }

    #[test]
    fn stats_reset_when_local_day_changes() {
        let mut p = started(cfg());
        p.tick(T0 + 100_000);
        assert_eq!(p.snapshot(T0 + 100_000).completed_today, 1);
        let next_day = T0 + 86_400_000;
        let s = p.snapshot(next_day);
        assert_eq!(s.completed_today, 0);
        assert_eq!(s.focus_secs_today, 0);
        p.tick(T0 + 120_000);
        p.start(next_day);
        p.tick(next_day + 100_000);
        let s = p.snapshot(next_day + 100_000);
        assert_eq!(s.completed_today, 1);
        assert_eq!(s.focus_secs_today, 100);
    }

    #[test]
    fn utc_offset_shifts_day_boundary() {
        // 23:59:00 UTC on day N; offset +2h puts local time on day N+1.
        let day_start_ms = 20_000u64 * 86_400_000;
        let now = day_start_ms + 86_340_000;
        let mut p = Pomodoro::new(PomodoroConfig {
            utc_offset_secs: 7200,
            ..cfg()
        });
        p.start(now - 100_000);
        p.tick(now);
        assert_eq!(p.stats().day, 20_001);
        let mut q = Pomodoro::new(cfg());
        q.start(now - 100_000);
        q.tick(now);
        assert_eq!(q.stats().day, 20_000);
    }

    #[test]
    fn negative_offset_before_epoch_uses_floor_division() {
        let p = Pomodoro::new(PomodoroConfig {
            utc_offset_secs: -3600,
            ..cfg()
        });
        assert_eq!(p.day_of(0), -1);
    }

    #[test]
    fn stats_roundtrip_through_restore() {
        let mut p = started(cfg());
        p.tick(T0 + 100_000);
        let saved = p.stats();
        let json = serde_json::to_string(&saved).unwrap();
        let loaded: PomodoroStats = serde_json::from_str(&json).unwrap();
        let mut q = Pomodoro::new(cfg());
        q.restore_stats(loaded);
        let s = q.snapshot(T0 + 100_000);
        assert_eq!(s.completed_today, 1);
        assert_eq!(s.focus_secs_today, 100);
    }

    #[test]
    fn restored_stale_stats_read_as_zero() {
        let mut q = Pomodoro::new(cfg());
        q.restore_stats(PomodoroStats {
            day: 5,
            completed_today: 9,
            focus_secs_today: 9999,
        });
        assert_eq!(q.snapshot(T0).completed_today, 0);
    }

    #[test]
    fn stats_counters_saturate() {
        let mut p = started(cfg());
        p.restore_stats(PomodoroStats {
            day: p.day_of(T0 + 100_000),
            completed_today: u32::MAX,
            focus_secs_today: u64::MAX,
        });
        p.tick(T0 + 100_000);
        let s = p.stats();
        assert_eq!(s.completed_today, u32::MAX);
        assert_eq!(s.focus_secs_today, u64::MAX);
    }

    #[test]
    fn events_serialize_snake_case() {
        let ev = PomodoroEvent::PhaseCompleted {
            phase: Phase::ShortBreak,
            skipped: true,
        };
        let json = serde_json::to_string(&ev).unwrap();
        assert_eq!(
            json,
            r#"{"phase_completed":{"phase":"short_break","skipped":true}}"#
        );
        let back: PomodoroEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ev);
        let json = serde_json::to_string(&RunState::Paused).unwrap();
        assert_eq!(json, r#""paused""#);
    }

    #[test]
    fn snapshot_serializes() {
        let p = Pomodoro::new(cfg());
        let json = serde_json::to_string(&p.snapshot(T0)).unwrap();
        let back: PomodoroSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(back, p.snapshot(T0));
    }

    #[test]
    fn repeated_start_pause_resume_cycles_are_stable() {
        let mut p = Pomodoro::new(cfg());
        let mut t = T0;
        p.start(t);
        for _ in 0..50 {
            t += 1000;
            p.pause(t);
            p.resume(t);
        }
        assert_eq!(p.snapshot(t).remaining_secs, 50);
    }
}
