//! Battery and power-source status, read from `pmset -g batt`.

use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Power {
    pub on_ac: bool,
    /// `None` on machines without a battery.
    pub battery_pct: Option<u8>,
}

/// Parses `pmset -g batt` output. Unknown output is treated as AC power with
/// no battery, which is the safe reading for a desktop Mac.
pub fn parse_pmset_batt(output: &str) -> Power {
    let on_ac = !output.contains("'Battery Power'");
    let battery_pct = output.lines().find_map(|line| {
        if !line.contains("InternalBattery") {
            return None;
        }
        let pct_end = line.find('%')?;
        let digits_start = line[..pct_end]
            .rfind(|c: char| !c.is_ascii_digit())
            .map_or(0, |i| i + 1);
        line[digits_start..pct_end]
            .parse::<u16>()
            .ok()
            .map(|p| p.min(100) as u8)
    });
    Power { on_ac, battery_pct }
}

/// Parses `pmset -g` output for the `SleepDisabled` flag that lid mode sets.
pub fn parse_sleep_disabled(output: &str) -> bool {
    output.lines().any(|line| {
        let mut parts = line.split_whitespace();
        parts.next() == Some("SleepDisabled") && parts.next() == Some("1")
    })
}

pub fn read() -> Option<Power> {
    crate::script::run("/usr/bin/pmset", &["-g", "batt"], Duration::from_secs(3))
        .ok()
        .map(|out| parse_pmset_batt(&out))
}

pub fn sleep_disabled() -> Option<bool> {
    crate::script::run("/usr/bin/pmset", &["-g"], Duration::from_secs(3))
        .ok()
        .map(|out| parse_sleep_disabled(&out))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_battery_power_with_percentage() {
        let out = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1234)\t87%; discharging; 5:12 remaining present: true\n";
        assert_eq!(
            parse_pmset_batt(out),
            Power {
                on_ac: false,
                battery_pct: Some(87)
            }
        );
    }

    #[test]
    fn parses_ac_power_while_charging() {
        let out = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged; 0:00 remaining present: true\n";
        assert_eq!(
            parse_pmset_batt(out),
            Power {
                on_ac: true,
                battery_pct: Some(100)
            }
        );
    }

    #[test]
    fn desktop_without_battery_reads_as_ac() {
        assert_eq!(
            parse_pmset_batt("Now drawing from 'AC Power'\n"),
            Power {
                on_ac: true,
                battery_pct: None
            }
        );
        assert_eq!(
            parse_pmset_batt(""),
            Power {
                on_ac: true,
                battery_pct: None
            }
        );
    }

    #[test]
    fn malformed_percentage_is_ignored() {
        let out = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t%; discharging\n";
        assert_eq!(parse_pmset_batt(out).battery_pct, None);
        let out = " -InternalBattery-0 no percent here\n";
        assert_eq!(parse_pmset_batt(out).battery_pct, None);
    }

    #[test]
    fn absurd_percentage_is_clamped() {
        let out = " -InternalBattery-0 (id=1)\t250%; charging\n";
        assert_eq!(parse_pmset_batt(out).battery_pct, Some(100));
    }

    #[test]
    fn sleep_disabled_flag_is_detected() {
        assert!(parse_sleep_disabled(
            "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n"
        ));
        assert!(!parse_sleep_disabled(" SleepDisabled\t\t0\n"));
        assert!(!parse_sleep_disabled("Currently in use:\n standby 1\n"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn reads_live_status_on_macos() {
        let power = read().expect("pmset is available on macOS");
        if let Some(pct) = power.battery_pct {
            assert!(pct <= 100);
        }
        assert!(sleep_disabled().is_some());
    }
}
