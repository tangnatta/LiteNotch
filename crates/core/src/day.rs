//! Day progress: where the user is in their working day, from fixed office
//! hours. The core only gives today's start and end; the shell works out the
//! percentage itself, so nothing here changes by the second.

use serde::{Deserialize, Serialize};

use crate::analytics::day_index;

const DAY_MS: u64 = 86_400_000;
const MINUTES_PER_DAY: u16 = 24 * 60;
/// Shortest working day accepted, in minutes.
const MIN_SPAN: u16 = 30;

/// A line under the number, one per day. About the person, not the work:
/// the day is theirs before and after office hours too, so no line tells
/// them to finish, stop or push.
pub const DAY_LINES: [&str; 8] = [
    "Take a deep breath.",
    "One thing at a time.",
    "Be kind to yourself today.",
    "Drink some water.",
    "Small steps still count.",
    "Enjoy the little things.",
    "You\u{2019}re doing fine.",
    "Look up, look around.",
];

/// What the big card on the left of Home shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum HomeCard {
    /// Now playing, as before.
    Media,
    /// Day progress, always.
    Day,
    /// Now playing while something plays, day progress otherwise.
    #[default]
    Auto,
}

/// How the day's icon looks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum DayIcons {
    /// Sun and moon by the time of day, in the usual text colour.
    #[default]
    Sun,
    /// A plant growing through the day, green in the closed notch.
    Tree,
}

/// Office hours.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct DayConfig {
    pub enabled: bool,
    /// Minutes after local midnight.
    pub start_min: u16,
    pub end_min: u16,
    /// Working days, bit 0 = Monday … bit 6 = Sunday.
    pub days: u8,
    /// Home's left card, while day progress is on.
    pub home_card: HomeCard,
    pub icons: DayIcons,
}

impl Default for DayConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            start_min: 10 * 60,
            end_min: 18 * 60,
            days: 0b001_1111,
            home_card: HomeCard::Auto,
            icons: DayIcons::Sun,
        }
    }
}

impl DayConfig {
    /// Times inside the day, the end at least `MIN_SPAN` after the start.
    pub fn normalized(self) -> Self {
        let start = self.start_min.min(MINUTES_PER_DAY - MIN_SPAN);
        let end = self.end_min.clamp(start + MIN_SPAN, MINUTES_PER_DAY);
        Self {
            start_min: start,
            end_min: end,
            days: self.days & 0b111_1111,
            ..self
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DayView {
    /// Today's office hours as absolute times; the shell shows
    /// `(now − start) / (end − start)`, negative before the start and over
    /// 100 after the end.
    pub start_ms: u64,
    pub end_ms: u64,
    pub line: String,
}

/// Monday = 0 for local day number `day` (1970-01-01 was a Thursday).
fn weekday(day: u32) -> u32 {
    (day + 3) % 7
}

fn local_midnight_ms(day: u32, utc_offset_secs: i32) -> u64 {
    let ms = i64::from(day) * DAY_MS as i64 - i64::from(utc_offset_secs) * 1000;
    ms.max(0) as u64
}

/// Today's office hours, or `None` when off or not a working day.
pub fn today(cfg: &DayConfig, now_ms: u64, utc_offset_secs: i32) -> Option<DayView> {
    if !cfg.enabled {
        return None;
    }
    let day = day_index(now_ms, utc_offset_secs);
    if cfg.days & (1 << weekday(day)) == 0 {
        return None;
    }
    let midnight = local_midnight_ms(day, utc_offset_secs);
    Some(DayView {
        start_ms: midnight + u64::from(cfg.start_min) * 60_000,
        end_ms: midnight + u64::from(cfg.end_min) * 60_000,
        line: DAY_LINES[day as usize % DAY_LINES.len()].to_string(),
    })
}

/// The next local midnight, when `today` gives another answer.
pub fn next_deadline(cfg: &DayConfig, now_ms: u64, utc_offset_secs: i32) -> Option<u64> {
    cfg.enabled
        .then(|| local_midnight_ms(day_index(now_ms, utc_offset_secs) + 1, utc_offset_secs))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Monday 2026-11-16 00:00 UTC.
    const MONDAY: u64 = 1_794_787_200_000;
    const HOUR: u64 = 3_600_000;

    fn on() -> DayConfig {
        DayConfig {
            enabled: true,
            ..DayConfig::default()
        }
    }

    #[test]
    fn monday_is_a_monday() {
        assert_eq!(weekday(day_index(MONDAY, 0)), 0);
    }

    #[test]
    fn off_by_default() {
        assert_eq!(today(&DayConfig::default(), MONDAY, 0), None);
        assert_eq!(next_deadline(&DayConfig::default(), MONDAY, 0), None);
    }

    #[test]
    fn office_hours_on_a_working_day() {
        let v = today(&on(), MONDAY + 7 * HOUR, 0).unwrap();
        assert_eq!(v.start_ms, MONDAY + 10 * HOUR);
        assert_eq!(v.end_ms, MONDAY + 18 * HOUR);
        assert!(DAY_LINES.contains(&v.line.as_str()));
    }

    #[test]
    fn the_local_day_follows_the_offset() {
        // 20:00 UTC Sunday is 03:00 Monday at UTC+7.
        let v = today(&on(), MONDAY - 4 * HOUR, 7 * 3600).unwrap();
        assert_eq!(v.start_ms, MONDAY - 7 * HOUR + 10 * HOUR);
    }

    #[test]
    fn weekends_are_off() {
        let saturday = MONDAY + 5 * 24 * HOUR + 12 * HOUR;
        assert_eq!(today(&on(), saturday, 0), None);
        let every_day = DayConfig {
            days: 0b111_1111,
            ..on()
        };
        assert!(today(&every_day, saturday, 0).is_some());
    }

    #[test]
    fn wakes_at_the_next_local_midnight() {
        assert_eq!(
            next_deadline(&on(), MONDAY + 13 * HOUR, 0),
            Some(MONDAY + 24 * HOUR)
        );
        assert_eq!(
            next_deadline(&on(), MONDAY + 13 * HOUR, 7 * 3600),
            Some(MONDAY + 24 * HOUR - 7 * HOUR)
        );
    }

    #[test]
    fn a_new_line_each_day() {
        let a = today(&on(), MONDAY, 0).unwrap().line;
        let b = today(&on(), MONDAY + 24 * HOUR, 0).unwrap().line;
        assert_ne!(a, b);
    }

    #[test]
    fn normalizes_bad_times() {
        let n = DayConfig {
            start_min: 2000,
            end_min: 0,
            days: 0xFF,
            ..on()
        }
        .normalized();
        assert_eq!(n.start_min, MINUTES_PER_DAY - MIN_SPAN);
        assert_eq!(n.end_min, MINUTES_PER_DAY);
        assert_eq!(n.days, 0b111_1111);
        let backwards = DayConfig {
            start_min: 600,
            end_min: 500,
            ..on()
        }
        .normalized();
        assert_eq!(backwards.end_min, 630);
    }
}
