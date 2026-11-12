//! Feature-usage counters.
//!
//! Only "feature X was used N times on day D" is ever recorded: no clipboard
//! text, file paths, commands, project names, or timestamps finer than a day.
//! Counting is local. `export` builds the batch a future update/analytics
//! backend would receive, and returns nothing unless the user opted in.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Days of history kept.
pub const RETAIN_DAYS: u32 = 90;

/// Everything that is counted. Adding a variant is the only way to track
/// something new, which keeps free-form strings out of the data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Feature {
    PanelOpen,
    /// The first tab before it became Home; kept so saved counts still load.
    TabNow,
    TabHome,
    TabMusic,
    TabTimer,
    TabClipboard,
    TabAgents,
    TabInbox,
    TabSettings,
    PomodoroStart,
    PomodoroComplete,
    PomodoroSkip,
    ClipboardCopy,
    ClipboardPin,
    ClipboardSearch,
    MediaControl,
    AgentRequest,
    AgentAllow,
    AgentDeny,
    AgentPass,
    CaffeineOn,
    LidModeOn,
    NotificationShown,
    ExternalNotify,
    SettingsChange,
    MeetingStart,
    MeetingFinish,
    ColorPick,
    TimerStart,
}

impl Feature {
    /// Stable name used in storage and exports.
    pub fn name(self) -> &'static str {
        match self {
            Feature::PanelOpen => "panel_open",
            Feature::TabNow => "tab_now",
            Feature::TabHome => "tab_home",
            Feature::TabMusic => "tab_music",
            Feature::TabTimer => "tab_timer",
            Feature::TabClipboard => "tab_clipboard",
            Feature::TabAgents => "tab_agents",
            Feature::TabInbox => "tab_inbox",
            Feature::TabSettings => "tab_settings",
            Feature::PomodoroStart => "pomodoro_start",
            Feature::PomodoroComplete => "pomodoro_complete",
            Feature::PomodoroSkip => "pomodoro_skip",
            Feature::ClipboardCopy => "clipboard_copy",
            Feature::ClipboardPin => "clipboard_pin",
            Feature::ClipboardSearch => "clipboard_search",
            Feature::MediaControl => "media_control",
            Feature::AgentRequest => "agent_request",
            Feature::AgentAllow => "agent_allow",
            Feature::AgentDeny => "agent_deny",
            Feature::AgentPass => "agent_pass",
            Feature::CaffeineOn => "caffeine_on",
            Feature::LidModeOn => "lid_mode_on",
            Feature::NotificationShown => "notification_shown",
            Feature::ExternalNotify => "external_notify",
            Feature::SettingsChange => "settings_change",
            Feature::MeetingStart => "meeting_start",
            Feature::MeetingFinish => "meeting_finish",
            Feature::ColorPick => "color_pick",
            Feature::TimerStart => "timer_start",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AnalyticsConfig {
    /// Count feature usage on this Mac.
    pub enabled: bool,
    /// Allow counters to be sent to the LiteNotch backend. Off by default.
    pub share: bool,
}

impl Default for AnalyticsConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            share: false,
        }
    }
}

/// One row of a usage summary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeatureCount {
    pub feature: String,
    pub count: u32,
}

/// Counters as stored on disk.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct PersistedAnalytics {
    /// Day index → feature name → count.
    pub days: BTreeMap<u32, BTreeMap<String, u32>>,
    /// Last day already included in an export.
    pub exported_through: Option<u32>,
}

/// What an upload would contain.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadBatch {
    pub schema: u32,
    /// Random id created on first launch; not derived from the machine or user.
    pub install_id: String,
    pub app_version: String,
    pub os: String,
    pub days: BTreeMap<u32, BTreeMap<String, u32>>,
}

#[derive(Debug, Clone)]
pub struct Analytics {
    cfg: AnalyticsConfig,
    data: PersistedAnalytics,
}

/// Local day number for a timestamp.
pub fn day_index(now_ms: u64, utc_offset_secs: i32) -> u32 {
    let secs = (now_ms / 1000) as i64 + i64::from(utc_offset_secs);
    secs.div_euclid(86_400).clamp(0, i64::from(u32::MAX)) as u32
}

impl Analytics {
    pub fn new(cfg: AnalyticsConfig) -> Self {
        Self {
            cfg,
            data: PersistedAnalytics::default(),
        }
    }

    pub fn from_persisted(cfg: AnalyticsConfig, data: PersistedAnalytics) -> Self {
        Self { cfg, data }
    }

    pub fn to_persisted(&self) -> PersistedAnalytics {
        self.data.clone()
    }

    pub fn config(&self) -> &AnalyticsConfig {
        &self.cfg
    }

    /// Turning counting off also deletes what was counted.
    pub fn set_config(&mut self, cfg: AnalyticsConfig) {
        if !cfg.enabled {
            self.clear();
        }
        self.cfg = cfg;
    }

    /// Counts one use; returns whether anything was recorded.
    pub fn record(&mut self, feature: Feature, day: u32) -> bool {
        if !self.cfg.enabled {
            return false;
        }
        let count = self
            .data
            .days
            .entry(day)
            .or_default()
            .entry(feature.name().to_string())
            .or_insert(0);
        *count = count.saturating_add(1);
        let oldest_kept = day.saturating_sub(RETAIN_DAYS - 1);
        self.data.days.retain(|d, _| *d >= oldest_kept);
        true
    }

    /// Totals per feature from `since_day` on, most used first.
    pub fn totals(&self, since_day: u32) -> Vec<FeatureCount> {
        let mut sums: BTreeMap<&str, u32> = BTreeMap::new();
        for counts in self.data.days.range(since_day..).map(|(_, c)| c) {
            for (name, n) in counts {
                let sum = sums.entry(name.as_str()).or_insert(0);
                *sum = sum.saturating_add(*n);
            }
        }
        let mut out: Vec<FeatureCount> = sums
            .into_iter()
            .map(|(feature, count)| FeatureCount {
                feature: feature.to_string(),
                count,
            })
            .collect();
        out.sort_by(|a, b| {
            b.count
                .cmp(&a.count)
                .then_with(|| a.feature.cmp(&b.feature))
        });
        out
    }

    /// Completed days not yet exported, or `None` when sharing is off or
    /// there is nothing new. `today` is excluded because it is still changing.
    pub fn export(
        &self,
        install_id: &str,
        app_version: &str,
        os: &str,
        today: u32,
    ) -> Option<UploadBatch> {
        if !self.cfg.enabled || !self.cfg.share {
            return None;
        }
        let from = self
            .data
            .exported_through
            .map_or(0, |d| d.saturating_add(1));
        if from >= today {
            return None;
        }
        let days: BTreeMap<u32, BTreeMap<String, u32>> = self
            .data
            .days
            .range(from..today)
            .map(|(d, c)| (*d, c.clone()))
            .collect();
        if days.is_empty() {
            return None;
        }
        Some(UploadBatch {
            schema: 1,
            install_id: install_id.to_string(),
            app_version: app_version.to_string(),
            os: os.to_string(),
            days,
        })
    }

    /// Call after a batch was accepted so its days are not sent again.
    pub fn mark_exported(&mut self, batch: &UploadBatch) {
        if let Some(last) = batch.days.keys().next_back() {
            let through = self.data.exported_through.map_or(*last, |d| d.max(*last));
            self.data.exported_through = Some(through);
        }
    }

    pub fn clear(&mut self) {
        self.data = PersistedAnalytics::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn on() -> Analytics {
        Analytics::new(AnalyticsConfig::default())
    }

    fn sharing() -> Analytics {
        Analytics::new(AnalyticsConfig {
            enabled: true,
            share: true,
        })
    }

    #[test]
    fn defaults_count_locally_and_do_not_share() {
        let cfg = AnalyticsConfig::default();
        assert!(cfg.enabled);
        assert!(!cfg.share);
        let parsed: AnalyticsConfig = serde_json::from_str("{}").unwrap();
        assert_eq!(parsed, cfg);
    }

    #[test]
    fn day_index_follows_the_local_day() {
        assert_eq!(day_index(0, 0), 0);
        assert_eq!(day_index(86_399_999, 0), 0);
        assert_eq!(day_index(86_400_000, 0), 1);
        // 23:00 UTC is already the next day at UTC+7.
        assert_eq!(day_index(23 * 3_600_000, 7 * 3600), 1);
        // A negative offset before the epoch clamps to day 0 instead of wrapping.
        assert_eq!(day_index(0, -3600), 0);
        assert_eq!(
            day_index(u64::MAX, i32::MAX),
            u32::MAX,
            "far-future times saturate"
        );
    }

    #[test]
    fn records_and_totals_most_used_first() {
        let mut a = on();
        assert!(a.record(Feature::PomodoroStart, 10));
        a.record(Feature::ClipboardCopy, 10);
        a.record(Feature::ClipboardCopy, 11);
        a.record(Feature::AgentAllow, 11);
        let totals = a.totals(0);
        assert_eq!(
            totals[0],
            FeatureCount {
                feature: "clipboard_copy".into(),
                count: 2
            }
        );
        // Ties are ordered by name so the list is stable.
        assert_eq!(totals[1].feature, "agent_allow");
        assert_eq!(totals[2].feature, "pomodoro_start");
        assert_eq!(a.totals(11).len(), 2);
        assert!(a.totals(12).is_empty());
    }

    #[test]
    fn disabled_records_nothing_and_disabling_erases() {
        let mut a = Analytics::new(AnalyticsConfig {
            enabled: false,
            share: false,
        });
        assert!(!a.record(Feature::PanelOpen, 1));
        assert!(a.totals(0).is_empty());
        let mut a = on();
        a.record(Feature::PanelOpen, 1);
        a.set_config(AnalyticsConfig {
            enabled: false,
            share: false,
        });
        assert!(a.totals(0).is_empty());
        assert!(!a.config().enabled);
    }

    #[test]
    fn old_days_are_dropped() {
        let mut a = on();
        a.record(Feature::PanelOpen, 1);
        a.record(Feature::PanelOpen, 1 + RETAIN_DAYS - 1);
        assert_eq!(
            a.to_persisted().days.len(),
            2,
            "day 1 is the oldest day still kept"
        );
        a.record(Feature::PanelOpen, 1 + RETAIN_DAYS);
        assert!(!a.to_persisted().days.contains_key(&1));
        // An early day number cannot underflow.
        a.record(Feature::PanelOpen, 0);
    }

    #[test]
    fn counts_saturate() {
        let mut days = BTreeMap::new();
        days.insert(1, BTreeMap::from([("panel_open".to_string(), u32::MAX)]));
        days.insert(2, BTreeMap::from([("panel_open".to_string(), 5)]));
        let mut a = Analytics::from_persisted(
            AnalyticsConfig::default(),
            PersistedAnalytics {
                days,
                exported_through: None,
            },
        );
        a.record(Feature::PanelOpen, 1);
        assert_eq!(a.totals(0)[0].count, u32::MAX);
    }

    #[test]
    fn export_requires_opt_in() {
        let mut a = on();
        a.record(Feature::PanelOpen, 1);
        assert_eq!(a.export("id", "0.1.0", "macos", 5), None);
        let off = Analytics::from_persisted(
            AnalyticsConfig {
                enabled: false,
                share: true,
            },
            a.to_persisted(),
        );
        assert_eq!(off.export("id", "0.1.0", "macos", 5), None);
    }

    #[test]
    fn export_sends_completed_days_once() {
        let mut a = sharing();
        a.record(Feature::PanelOpen, 1);
        a.record(Feature::PomodoroStart, 2);
        a.record(Feature::PomodoroStart, 3);
        let batch = a.export("abc", "0.1.0", "macos 27", 3).unwrap();
        assert_eq!(batch.schema, 1);
        assert_eq!(batch.install_id, "abc");
        assert_eq!(
            batch.days.keys().copied().collect::<Vec<_>>(),
            [1, 2],
            "today is left out"
        );
        a.mark_exported(&batch);
        assert_eq!(
            a.export("abc", "0.1.0", "macos 27", 3),
            None,
            "nothing new yet"
        );
        let next = a.export("abc", "0.1.0", "macos 27", 4).unwrap();
        assert_eq!(next.days.keys().copied().collect::<Vec<_>>(), [3]);
        a.mark_exported(&next);
        // Marking an older batch again never moves the cursor backwards.
        a.mark_exported(&batch);
        assert_eq!(a.to_persisted().exported_through, Some(3));
    }

    #[test]
    fn export_is_none_when_there_are_no_days_in_range() {
        let a = sharing();
        assert_eq!(a.export("id", "v", "os", 9), None);
        let mut a = sharing();
        a.record(Feature::PanelOpen, 9);
        assert_eq!(a.export("id", "v", "os", 9), None, "only today has data");
        let empty = UploadBatch {
            schema: 1,
            install_id: String::new(),
            app_version: String::new(),
            os: String::new(),
            days: BTreeMap::new(),
        };
        a.mark_exported(&empty);
        assert_eq!(a.to_persisted().exported_through, None);
    }

    #[test]
    fn the_export_contains_only_counters() {
        let mut a = sharing();
        a.record(Feature::ClipboardCopy, 1);
        let json = serde_json::to_value(a.export("id", "0.1.0", "macos", 2).unwrap()).unwrap();
        let keys: Vec<&str> = json
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(keys, ["app_version", "days", "install_id", "os", "schema"]);
        assert_eq!(json["days"]["1"]["clipboard_copy"], 1);
    }

    #[test]
    fn persistence_round_trips_and_clear_wipes() {
        let mut a = on();
        a.record(Feature::MediaControl, 4);
        let restored = Analytics::from_persisted(AnalyticsConfig::default(), a.to_persisted());
        assert_eq!(restored.totals(0), a.totals(0));
        a.clear();
        assert!(a.totals(0).is_empty());
    }

    #[test]
    fn every_feature_has_a_unique_name_matching_its_serde_name() {
        let all = [
            Feature::PanelOpen,
            Feature::TabNow,
            Feature::TabHome,
            Feature::TabMusic,
            Feature::TabTimer,
            Feature::TabClipboard,
            Feature::TabAgents,
            Feature::TabInbox,
            Feature::TabSettings,
            Feature::PomodoroStart,
            Feature::PomodoroComplete,
            Feature::PomodoroSkip,
            Feature::ClipboardCopy,
            Feature::ClipboardPin,
            Feature::ClipboardSearch,
            Feature::MediaControl,
            Feature::AgentRequest,
            Feature::AgentAllow,
            Feature::AgentDeny,
            Feature::AgentPass,
            Feature::CaffeineOn,
            Feature::LidModeOn,
            Feature::NotificationShown,
            Feature::ExternalNotify,
            Feature::SettingsChange,
            Feature::MeetingStart,
            Feature::MeetingFinish,
            Feature::ColorPick,
            Feature::TimerStart,
        ];
        let mut names = std::collections::BTreeSet::new();
        for f in all {
            assert!(names.insert(f.name()), "duplicate {}", f.name());
            assert_eq!(serde_json::to_value(f).unwrap(), f.name());
        }
    }
}
