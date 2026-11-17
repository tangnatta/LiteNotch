//! What the core accepts and sends, written out so the shell can be held to
//! it: `cargo run -p litenotch-core --example fixtures -- macos/Fixtures`
//! writes it as `schema.json`, and the shell's tests compare its enums, its
//! sound list and the ranges of its controls with it.
//!
//! Nothing here is a second source of truth. The limits are *measured* by
//! saving extreme values through the core's own `SetSettings` and reading
//! back what it kept, and each enum's variants are listed with a `match` the
//! compiler checks, so a variant added to the core cannot be left out.

use serde_json::{json, Value};

use crate::agent::AgentStatus;
use crate::caffeine::{AwakeMode, LidState};
use crate::clipboard::ClipKind;
use crate::day::HomeCard;
use crate::notify::Priority;
use crate::pomodoro::{Phase, RunState};
use crate::state::{
    ActivityKind, ClosedNotch, Command, Core, Input, Material, NotchStyle, PeekKind, Settings,
    Shrink, Tab, ThemeChoice, SOUNDS,
};

/// A value no setting accepts: what is kept is the upper limit.
const HUGE: u64 = 4_000_000_000;

/// Lists every variant of `$t`, and fails to compile when one is missing.
macro_rules! variants {
    ($t:ty: $($v:ident),+ $(,)?) => {{
        #[allow(dead_code)]
        fn exhaustive(x: $t) {
            match x {
                $(<$t>::$v => {},)+
            }
        }
        // `unknown` is how a core enum says "newer than this build"; the
        // shell has the same case, and it is not a value to compare.
        let all: Vec<Value> = vec![$(serde_json::to_value(<$t>::$v).unwrap_or(Value::Null)),+];
        Value::Array(all.into_iter().filter(|v| v != "unknown").collect())
    }};
}

/// Saves `value` at `path` (dotted, in the settings JSON) through the core
/// and returns what it kept.
fn kept(path: &str, value: u64) -> u64 {
    let mut core = Core::default();
    let mut json = serde_json::to_value(core.settings()).unwrap_or(Value::Null);
    let mut at = &mut json;
    for key in path.split('.') {
        let Some(next) = at.get_mut(key) else {
            return 0;
        };
        at = next;
    }
    *at = json!(value);
    if let Ok(settings) = serde_json::from_value::<Settings>(json) {
        core.apply(
            Input::Command(Command::SetSettings {
                settings: Box::new(settings),
            }),
            0,
        );
    }
    serde_json::to_value(core.settings())
        .ok()
        .and_then(|v| path.split('.').try_fold(v, |v, k| v.get(k).cloned()))
        .and_then(|v| v.as_u64())
        .unwrap_or(0)
}

/// The smallest and largest value the core keeps for each numeric setting.
/// `from` is the smallest value tried at the bottom: 0 where 0 means a
/// number like any other, 1 where 0 means "off".
fn limits() -> Value {
    // (setting, a value below any limit, a value above any limit that still
    // fits the setting's type)
    let paths: [(&str, u64, u64); 15] = [
        ("pomodoro.focus_secs", 0, HUGE),
        ("pomodoro.short_break_secs", 0, HUGE),
        ("pomodoro.long_break_secs", 0, HUGE),
        ("pomodoro.rounds_before_long", 0, HUGE),
        ("notify.banner_secs", 0, HUGE),
        ("notify.max_history", 0, HUGE),
        ("clipboard.max_items", 0, HUGE),
        ("agent.approval_timeout_secs", 0, HUGE),
        ("calendar.alert_minutes", 0, HUGE),
        ("caffeine.battery_floor_pct", 0, 255),
        ("peek.time_warning_secs", 0, HUGE),
        ("peek.eye_break_mins", 1, HUGE),
        ("peek.move_mins", 1, HUGE),
        ("day.start_min", 0, 65_000),
        ("day.end_min", 0, 65_000),
    ];
    let mut out = serde_json::Map::new();
    for (path, low, high) in paths {
        out.insert(path.into(), json!([kept(path, low), kept(path, high)]));
    }
    Value::Object(out)
}

/// The whole schema.
pub fn schema() -> Value {
    json!({
        "limits": limits(),
        "sounds": SOUNDS,
        "enums": {
            "theme": variants!(ThemeChoice: System, Dark, Light),
            "notch_style": variants!(NotchStyle: Attached, Island),
            "closed_notch": variants!(ClosedNotch: Dark, Theme),
            "shrink": variants!(Shrink: Off, WhenEmpty, Always),
            "material": variants!(Material: Solid, Glass),
            "home_card": variants!(HomeCard: Media, Day, Auto),
            "priority": variants!(Priority: Low, Normal, High, Critical),
            "awake_mode": variants!(AwakeMode: Off, System, Display),
            "lid_state": variants!(LidState: Off, Pending, On),
            "agent_status": variants!(AgentStatus: Working, WaitingApproval, WaitingInput, Idle, Ended),
            "clip_kind": variants!(ClipKind: Text, Files, Image),
            "phase": variants!(Phase: Idle, Focus, ShortBreak, LongBreak),
            "run_state": variants!(RunState: Stopped, Running, Paused),
            "tab": variants!(Tab: Home, Music, Timer, Clipboard, Agents, Inbox, Settings),
            "peek_kind": variants!(PeekKind: TrackChanged, TimeWarning, EyeBreak, Move, Quote, StillWorking),
            "activity_kind": variants!(ActivityKind: Idle, Approval, Banner, Pomodoro, Media, Caffeine, Agent,
                Meeting, Timer, Calendar, Nudge, Day, Unknown),
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_core_reports_the_limits_it_enforces() {
        let s = schema();
        let l = &s["limits"];
        // Spot checks that probing really reads what the core keeps.
        assert_eq!(l["pomodoro.rounds_before_long"], json!([1, 12]));
        assert_eq!(l["calendar.alert_minutes"], json!([0, 60]));
        assert_eq!(l["agent.approval_timeout_secs"], json!([5, 120]));
        assert_eq!(l["caffeine.battery_floor_pct"], json!([0, 100]));
        assert_eq!(l["peek.move_mins"], json!([5, 180]));
        assert_eq!(s["sounds"].as_array().map(Vec::len), Some(SOUNDS.len()));
        // A probe that could not be saved would leave both ends equal.
        for (path, range) in l.as_object().into_iter().flatten() {
            assert!(range[1].as_u64() > range[0].as_u64(), "{path}: {range}");
        }
    }

    #[test]
    fn every_enum_is_listed_without_its_unknown_case() {
        let e = &schema()["enums"];
        assert_eq!(e["tab"].as_array().map(Vec::len), Some(7));
        assert!(!e["activity_kind"]
            .as_array()
            .is_some_and(|a| a.iter().any(|v| v == "unknown")));
        assert_eq!(e["notch_style"], json!(["attached", "island"]));
    }
}
