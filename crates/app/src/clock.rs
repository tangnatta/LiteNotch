//! A clock for timers: follows wall time, but never goes backwards.
//!
//! Timers compare against Unix milliseconds. Reading the wall clock directly
//! would let a manual clock change or an NTP step fire or stall them, so the
//! clock advances with the monotonic clock and only re-anchors to wall time
//! when wall time is ahead (which is also what happens after the Mac sleeps,
//! because the monotonic clock pauses during sleep).

use std::time::{Instant, SystemTime, UNIX_EPOCH};

/// Wall time may lead by this much before the clock jumps to it.
const RESYNC_AFTER_MS: u64 = 2_000;

pub fn wall_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

pub struct SteadyClock {
    base_ms: u64,
    base: Instant,
    last: u64,
}

impl Default for SteadyClock {
    fn default() -> Self {
        Self::new()
    }
}

impl SteadyClock {
    pub fn new() -> Self {
        let now = wall_ms();
        Self {
            base_ms: now,
            base: Instant::now(),
            last: now,
        }
    }

    pub fn now_ms(&mut self) -> u64 {
        let steady = self
            .base_ms
            .saturating_add(self.base.elapsed().as_millis() as u64);
        let (now, resync) = reconcile(steady, wall_ms(), self.last);
        if resync {
            self.base_ms = now;
            self.base = Instant::now();
        }
        self.last = now;
        now
    }
}

/// Returns the time to report and whether to re-anchor to it.
fn reconcile(steady: u64, wall: u64, last: u64) -> (u64, bool) {
    if wall > steady.saturating_add(RESYNC_AFTER_MS) {
        (wall.max(last), true)
    } else {
        (steady.max(last), false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follows_the_steady_clock_when_wall_time_agrees() {
        assert_eq!(reconcile(10_000, 10_000, 9_000), (10_000, false));
        assert_eq!(
            reconcile(10_000, 11_999, 9_000),
            (10_000, false),
            "small drift is ignored"
        );
    }

    #[test]
    fn jumps_forward_after_sleep_or_a_clock_set_ahead() {
        assert_eq!(reconcile(10_000, 3_610_000, 9_000), (3_610_000, true));
    }

    #[test]
    fn ignores_wall_time_going_backwards() {
        assert_eq!(reconcile(10_000, 5_000, 9_999), (10_000, false));
        assert_eq!(reconcile(10_000, 0, 9_999), (10_000, false));
    }

    #[test]
    fn never_reports_an_earlier_time_than_before() {
        assert_eq!(reconcile(10_000, 10_000, 12_000), (12_000, false));
        assert_eq!(reconcile(u64::MAX, u64::MAX, 0), (u64::MAX, false));
    }

    #[test]
    fn the_real_clock_is_close_to_wall_time_and_monotonic() {
        let mut clock = SteadyClock::default();
        let a = clock.now_ms();
        std::thread::sleep(std::time::Duration::from_millis(15));
        let b = clock.now_ms();
        assert!(b >= a + 10, "{a} -> {b}");
        assert!(wall_ms().abs_diff(b) < 2_500);
        assert!(a > 1_600_000_000_000, "wall time is after 2020");
    }
}
