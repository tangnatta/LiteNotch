//! A plain countdown timer, separate from the pomodoro and the meeting
//! timer. Pure state with injected time.

use serde::{Deserialize, Serialize};

pub const MAX_SECS: u32 = 24 * 3600;
const DEFAULT_SECS: u32 = 5 * 60;
/// Quick choices offered by the shell, in seconds.
pub const PRESETS: [u32; 6] = [60, 3 * 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TimerRun {
    Stopped,
    Running,
    Paused,
    /// Reached zero; shown until reset or restarted.
    Done,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TimerView {
    /// The length it was set to.
    pub duration_secs: u32,
    pub run_state: TimerRun,
    /// Only while running.
    pub ends_at_ms: Option<u64>,
    /// Time left when not running.
    pub remaining_secs: u32,
    pub presets: Vec<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Countdown {
    duration_secs: u32,
    run: TimerRun,
    ends_at_ms: Option<u64>,
    /// Time left while paused or stopped.
    remaining_ms: u64,
}

impl Default for Countdown {
    fn default() -> Self {
        Self::new(DEFAULT_SECS)
    }
}

impl Countdown {
    /// A stopped timer of `secs` (clamped to 1 s..=24 h).
    pub fn new(secs: u32) -> Self {
        let secs = secs.clamp(1, MAX_SECS);
        Countdown {
            duration_secs: secs,
            run: TimerRun::Stopped,
            ends_at_ms: None,
            remaining_ms: u64::from(secs) * 1000,
        }
    }

    pub fn duration_secs(&self) -> u32 {
        self.duration_secs
    }

    pub fn run_state(&self) -> TimerRun {
        self.run
    }

    /// Sets the length and stops. Returns whether anything changed.
    pub fn set(&mut self, secs: u32) -> bool {
        let next = Self::new(secs);
        let changed = *self != next;
        *self = next;
        changed
    }

    /// Start, pause or resume; a finished timer starts again.
    /// Returns true when it started from the beginning.
    pub fn toggle(&mut self, now: u64) -> bool {
        match self.run {
            TimerRun::Running => {
                self.remaining_ms = self.left_ms(now);
                self.ends_at_ms = None;
                self.run = TimerRun::Paused;
                false
            }
            TimerRun::Paused => {
                self.ends_at_ms = Some(now.saturating_add(self.remaining_ms));
                self.run = TimerRun::Running;
                false
            }
            TimerRun::Stopped | TimerRun::Done => {
                self.remaining_ms = u64::from(self.duration_secs) * 1000;
                self.ends_at_ms = Some(now.saturating_add(self.remaining_ms));
                self.run = TimerRun::Running;
                true
            }
        }
    }

    pub fn reset(&mut self) {
        *self = Self::new(self.duration_secs);
    }

    /// Adds time to a running or paused timer (a stopped one gets a longer
    /// length instead).
    pub fn add(&mut self, secs: u32, now: u64) {
        let extra = u64::from(secs) * 1000;
        match self.run {
            TimerRun::Running => {
                let left = self.left_ms(now).saturating_add(extra);
                let left = left.min(u64::from(MAX_SECS) * 1000);
                self.ends_at_ms = Some(now.saturating_add(left));
            }
            TimerRun::Paused => {
                self.remaining_ms = self
                    .remaining_ms
                    .saturating_add(extra)
                    .min(u64::from(MAX_SECS) * 1000);
            }
            TimerRun::Stopped | TimerRun::Done => {
                self.set(self.duration_secs.saturating_add(secs));
            }
        }
    }

    fn left_ms(&self, now: u64) -> u64 {
        self.ends_at_ms
            .map_or(self.remaining_ms, |end| end.saturating_sub(now))
    }

    pub fn next_deadline(&self) -> Option<u64> {
        self.ends_at_ms.filter(|_| self.run == TimerRun::Running)
    }

    /// Returns true once, when the timer reaches zero.
    pub fn tick(&mut self, now: u64) -> bool {
        match self.next_deadline() {
            Some(end) if now >= end => {
                self.run = TimerRun::Done;
                self.ends_at_ms = None;
                self.remaining_ms = 0;
                true
            }
            _ => false,
        }
    }

    pub fn view(&self) -> TimerView {
        TimerView {
            duration_secs: self.duration_secs,
            run_state: self.run,
            ends_at_ms: self.next_deadline(),
            remaining_secs: u32::try_from(self.remaining_ms.div_ceil(1000)).unwrap_or(MAX_SECS),
            presets: PRESETS.to_vec(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: u64 = 1_000_000;

    #[test]
    fn runs_pauses_resumes_and_finishes_once() {
        let mut c = Countdown::new(60);
        assert_eq!(c.view().remaining_secs, 60);
        assert!(c.toggle(T));
        assert_eq!(c.next_deadline(), Some(T + 60_000));
        assert!(!c.toggle(T + 20_000));
        let v = c.view();
        assert_eq!(
            (v.run_state, v.ends_at_ms, v.remaining_secs),
            (TimerRun::Paused, None, 40)
        );
        assert!(!c.toggle(T + 100_000));
        assert_eq!(c.next_deadline(), Some(T + 140_000));
        assert!(!c.tick(T + 139_999));
        assert!(c.tick(T + 140_000));
        assert!(!c.tick(T + 150_000));
        let v = c.view();
        assert_eq!((v.run_state, v.remaining_secs), (TimerRun::Done, 0));
        assert_eq!(c.next_deadline(), None);
        // From done it starts over at the full length.
        assert!(c.toggle(T + 200_000));
        assert_eq!(c.next_deadline(), Some(T + 260_000));
    }

    #[test]
    fn set_clamps_and_stops() {
        let mut c = Countdown::default();
        assert_eq!(c.duration_secs(), 300);
        c.toggle(T);
        assert!(c.set(0));
        assert_eq!(c.view().duration_secs, 1);
        assert_eq!(c.run_state(), TimerRun::Stopped);
        assert!(c.set(u32::MAX));
        assert_eq!(c.duration_secs(), MAX_SECS);
        assert!(!c.set(MAX_SECS));
        assert_eq!(c.view().presets, PRESETS.to_vec());
    }

    #[test]
    fn adding_time_works_in_every_state() {
        let mut c = Countdown::new(60);
        c.add(60, T);
        assert_eq!(c.duration_secs(), 120);
        c.toggle(T);
        c.add(60, T + 30_000);
        assert_eq!(c.next_deadline(), Some(T + 180_000));
        c.toggle(T + 60_000);
        c.add(30, T + 60_000);
        assert_eq!(c.view().remaining_secs, 150);
        c.add(MAX_SECS, T);
        assert_eq!(c.view().remaining_secs, MAX_SECS);
        c.toggle(T);
        c.add(MAX_SECS, T);
        assert_eq!(c.next_deadline(), Some(T + u64::from(MAX_SECS) * 1000));
    }

    #[test]
    fn reset_keeps_the_length() {
        let mut c = Countdown::new(90);
        c.toggle(T);
        c.reset();
        let v = c.view();
        assert_eq!(
            (v.run_state, v.remaining_secs, v.duration_secs),
            (TimerRun::Stopped, 90, 90)
        );
    }

    #[test]
    fn a_clock_going_backwards_does_not_underflow() {
        let mut c = Countdown::new(60);
        c.toggle(T);
        c.toggle(T + 100_000);
        assert_eq!(c.view().remaining_secs, 0);
    }
}
