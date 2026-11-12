//! Agent usage tracking: rate-limit windows from the Claude Code status line
//! and per-day token totals from transcript lines.

use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, HashSet};
use std::fmt;
use std::hash::{Hash, Hasher};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent::hooks::truncate_chars;
use crate::agent::sanitize;

const DAY_MS: u64 = 86_400_000;
/// Days shown in the usage chart, today included.
pub const HISTORY_DAYS: usize = 7;
/// Models and projects listed for today.
const TOP_NAMES: usize = 4;
const NAME_CHARS: usize = 40;
/// Distinct names remembered per day; more than this is not a real workload.
const MAX_NAMES: usize = 64;

/// One rate-limit window (e.g. the 5-hour or 7-day limit).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RateWindow {
    /// Percentage of the window used, as reported (not clamped).
    pub used_pct: f32,
    /// Unix ms at which the window resets, when known.
    pub resets_at_ms: Option<u64>,
}

/// Token counters accumulated for one local day.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct TokenTotals {
    /// Input tokens.
    pub input: u64,
    /// Output tokens.
    pub output: u64,
    /// Tokens read from the prompt cache.
    pub cache_read: u64,
    /// Tokens written to the prompt cache.
    pub cache_write: u64,
    /// Number of assistant messages counted.
    pub messages: u64,
}

/// Everything the UI needs to show usage at a glance.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct UsageSnapshot {
    /// 5-hour rate window, if reported.
    pub five_hour: Option<RateWindow>,
    /// 7-day rate window, if reported.
    pub seven_day: Option<RateWindow>,
    /// Cost of the current session in USD.
    pub session_cost_usd: Option<f64>,
    /// Context window usage percentage.
    pub context_pct: Option<f32>,
    /// Model display name (or id when no display name).
    pub model: Option<String>,
    /// Time of the last accepted status line; 0 if none yet.
    pub updated_ms: u64,
    /// Token totals for today.
    pub today: TokenTotals,
    /// The last [`HISTORY_DAYS`] days, oldest first; the last entry is today.
    pub week: Vec<DayUsage>,
    /// Today's tokens by model, largest first.
    pub models: Vec<NamedTokens>,
    /// Today's tokens by project, largest first.
    pub projects: Vec<NamedTokens>,
    /// One sentence about today; empty when there is nothing to say.
    pub summary: String,
}

/// Input plus output tokens for one local day.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct DayUsage {
    pub day_start_ms: u64,
    pub tokens: u64,
    pub messages: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct NamedTokens {
    pub name: String,
    pub tokens: u64,
}

/// The few fields of a transcript line that usage needs. Transcript lines
/// can be hundreds of kilobytes; the scanner keeps only this.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UsageRecord {
    pub ts_ms: u64,
    /// Hash of the message and request ids; `None` when there is no id.
    pub key: Option<u64>,
    pub model: String,
    pub project: String,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
}

/// Start of the local day containing `now_ms`, in Unix ms.
pub fn local_day_start_ms(now_ms: u64, utc_offset_secs: i32) -> u64 {
    let offset_ms = i64::from(utc_offset_secs) * 1000;
    let local = (now_ms as i64).saturating_add(offset_ms);
    let start = local.div_euclid(DAY_MS as i64) * DAY_MS as i64 - offset_ms;
    start.max(0) as u64
}

/// `1234567` as `1.2M`, `45300` as `45k`, `950` as `950`.
pub fn format_tokens(n: u64) -> String {
    if n >= 1_000_000_000 {
        format!("{:.1}B", n as f64 / 1e9)
    } else if n >= 1_000_000 {
        format!("{:.1}M", n as f64 / 1e6)
    } else if n >= 1_000 {
        format!("{}k", n / 1_000)
    } else {
        n.to_string()
    }
}

/// Claude Code stores a project's transcripts in a directory named after the
/// project's path with every non-alphanumeric character replaced by `-`.
fn encode_project_path(path: &str) -> String {
    path.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// The project a session belongs to: the directory Claude Code was started
/// in (found by matching `cwd` and its parents against the transcript
/// directory's name), not whichever subdirectory the session moved into.
fn project_name(cwd: &str, transcript_dir: Option<&str>) -> String {
    let cwd = cwd.trim_end_matches('/');
    let mut root = cwd;
    if let Some(dir) = transcript_dir {
        let mut candidate = cwd;
        loop {
            if encode_project_path(candidate) == dir {
                root = candidate;
                break;
            }
            match candidate.rfind('/') {
                Some(i) if i > 0 => candidate = &candidate[..i],
                _ => break,
            }
        }
    }
    let name = root.rsplit('/').next().unwrap_or("");
    truncate_chars(sanitize(name).trim(), NAME_CHARS)
}

/// Extracts the usage fields of an assistant message; `None` for any other line.
pub fn parse_record(line: &str) -> Option<UsageRecord> {
    parse_record_in(line, None)
}

/// Like [`parse_record`], for a line read from the transcript directory
/// named `transcript_dir`.
pub fn parse_record_in(line: &str, transcript_dir: Option<&str>) -> Option<UsageRecord> {
    let v: Value = serde_json::from_str(line).ok()?;
    if let Some(t) = v.get("type").and_then(Value::as_str) {
        if t != "assistant" {
            return None;
        }
    }
    if let Some(r) = v.pointer("/message/role").and_then(Value::as_str) {
        if r != "assistant" {
            return None;
        }
    }
    let ts_ms = v
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339_ms)?;
    let usage = v.pointer("/message/usage").filter(|u| u.is_object())?;
    // Without a message id there is nothing to dedupe on.
    let key = v.pointer("/message/id").and_then(Value::as_str).map(|id| {
        let req = v.get("requestId").and_then(Value::as_str).unwrap_or("");
        let mut hasher = DefaultHasher::new();
        (id, req).hash(&mut hasher);
        hasher.finish()
    });
    let n = |name: &str| usage.get(name).and_then(Value::as_u64).unwrap_or(0);
    let model = v
        .pointer("/message/model")
        .and_then(Value::as_str)
        .filter(|m| !m.starts_with('<'))
        .map(|m| m.strip_prefix("claude-").unwrap_or(m))
        .map(|m| truncate_chars(sanitize(m).trim(), NAME_CHARS))
        .unwrap_or_default();
    let project = v
        .get("cwd")
        .and_then(Value::as_str)
        .map(|cwd| project_name(cwd, transcript_dir))
        .unwrap_or_default();
    Some(UsageRecord {
        ts_ms,
        key,
        model,
        project,
        input: n("input_tokens"),
        output: n("output_tokens"),
        cache_read: n("cache_read_input_tokens"),
        cache_write: n("cache_creation_input_tokens"),
    })
}

/// Why a status line was rejected.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UsageError {
    /// The input was not valid JSON.
    InvalidJson(String),
    /// The JSON root was not an object.
    NotAnObject,
}

impl fmt::Display for UsageError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            UsageError::InvalidJson(e) => write!(f, "invalid status line JSON: {e}"),
            UsageError::NotAnObject => write!(f, "status line JSON must be an object"),
        }
    }
}

impl std::error::Error for UsageError {}

/// Usage tracker; holds the latest status line and today's token totals.
#[derive(Debug, Clone, Default)]
pub struct Usage {
    snap: UsageSnapshot,
    // Dedupe set so a message re-logged across transcript lines counts once.
    seen: HashSet<u64>,
    /// Start of the day `snap.today` belongs to; 0 until first told.
    day_start_ms: u64,
    /// Earlier days: index 0 is yesterday.
    history: [(u64, u64); HISTORY_DAYS - 1],
    models: BTreeMap<String, u64>,
    projects: BTreeMap<String, u64>,
}

impl Usage {
    /// Creates an empty tracker.
    pub fn new() -> Self {
        Self::default()
    }

    /// Replaces the status-line fields from `json_str`; absent fields become `None`.
    pub fn on_statusline(&mut self, json_str: &str, now: u64) -> Result<(), UsageError> {
        let v: Value =
            serde_json::from_str(json_str).map_err(|e| UsageError::InvalidJson(e.to_string()))?;
        if !v.is_object() {
            return Err(UsageError::NotAnObject);
        }
        let limits = v.get("rate_limits");
        self.snap.five_hour = limits.and_then(|l| window(l.get("five_hour")));
        self.snap.seven_day = limits.and_then(|l| window(l.get("seven_day")));
        self.snap.session_cost_usd = v.pointer("/cost/total_cost_usd").and_then(Value::as_f64);
        self.snap.context_pct = v
            .pointer("/context_window/used_percentage")
            .and_then(Value::as_f64)
            .and_then(finite_f32);
        self.snap.model = ["/model/display_name", "/model/id"]
            .iter()
            .filter_map(|p| v.pointer(p).and_then(Value::as_str))
            .find(|s| !s.is_empty())
            .map(str::to_owned);
        self.snap.updated_ms = now;
        Ok(())
    }

    /// Adds one transcript line; see [`Usage::ingest`].
    pub fn ingest_transcript_line(
        &mut self,
        line: &str,
        day_start_ms: u64,
        day_end_ms: u64,
    ) -> bool {
        parse_record(line).is_some_and(|r| self.ingest(&r, day_start_ms, day_end_ms))
    }

    /// Adds `record` to today when it falls inside `[day_start_ms, day_end_ms)`
    /// and returns true; a record from the six days before is added to the
    /// history instead. Anything else, and a record seen before, is ignored.
    pub fn ingest(&mut self, record: &UsageRecord, day_start_ms: u64, day_end_ms: u64) -> bool {
        let ts = record.ts_ms;
        let oldest = day_start_ms.saturating_sub(DAY_MS * (HISTORY_DAYS as u64 - 1));
        if ts < oldest || ts >= day_end_ms {
            return false;
        }
        if let Some(key) = record.key {
            if !self.seen.insert(key) {
                return false;
            }
        }
        let tokens = record.input.saturating_add(record.output);
        if ts < day_start_ms {
            let days_ago = (day_start_ms - ts).div_ceil(DAY_MS) as usize;
            if let Some(day) = self.history.get_mut(days_ago.saturating_sub(1)) {
                day.0 = day.0.saturating_add(tokens);
                day.1 = day.1.saturating_add(1);
            }
            return false;
        }
        let t = &mut self.snap.today;
        t.input = t.input.saturating_add(record.input);
        t.output = t.output.saturating_add(record.output);
        t.cache_read = t.cache_read.saturating_add(record.cache_read);
        t.cache_write = t.cache_write.saturating_add(record.cache_write);
        t.messages = t.messages.saturating_add(1);
        add_named(&mut self.models, &record.model, tokens);
        add_named(&mut self.projects, &record.project, tokens);
        true
    }

    /// Tells the tracker which day is today. On a new day, today's totals
    /// move into the history, so the chart is right before the next scan.
    pub fn set_day(&mut self, day_start_ms: u64) {
        if day_start_ms == self.day_start_ms {
            return;
        }
        let previous = self.day_start_ms;
        self.day_start_ms = day_start_ms;
        if previous == 0 {
            return;
        }
        let elapsed = if day_start_ms > previous {
            (day_start_ms - previous).div_ceil(DAY_MS) as usize
        } else {
            usize::MAX
        };
        let today = &self.snap.today;
        let mut days = vec![(today.input.saturating_add(today.output), today.messages)];
        days.extend(self.history);
        self.history = [(0, 0); HISTORY_DAYS - 1];
        for (i, day) in days.into_iter().enumerate() {
            // `elapsed - 1` days had no record at all.
            if let Some(slot) = elapsed
                .checked_add(i)
                .and_then(|n| self.history.get_mut(n - 1))
            {
                *slot = day;
            }
        }
        self.snap.today = TokenTotals::default();
        self.models.clear();
        self.projects.clear();
    }

    /// Clears today's totals and the dedupe set (call on day change).
    pub fn reset_today(&mut self) {
        self.snap.today = TokenTotals::default();
        self.seen.clear();
        self.history = [(0, 0); HISTORY_DAYS - 1];
        self.models.clear();
        self.projects.clear();
    }

    /// Current view of usage; `now` is unused but kept for a uniform API.
    pub fn snapshot(&self, _now: u64) -> UsageSnapshot {
        let mut snap = self.snap.clone();
        let today_tokens = snap.today.input.saturating_add(snap.today.output);
        snap.week = (0..HISTORY_DAYS)
            .rev()
            .map(|days_ago| {
                let (tokens, messages) = match days_ago {
                    0 => (today_tokens, snap.today.messages),
                    n => self.history[n - 1],
                };
                DayUsage {
                    day_start_ms: self.day_start_ms.saturating_sub(DAY_MS * days_ago as u64),
                    tokens,
                    messages,
                }
            })
            .collect();
        snap.models = top(&self.models);
        snap.projects = top(&self.projects);
        snap.summary = self.summary(today_tokens, &snap);
        snap
    }

    fn summary(&self, today: u64, snap: &UsageSnapshot) -> String {
        let earlier: u64 = self.history.iter().map(|d| d.0).sum();
        let average = earlier / (HISTORY_DAYS as u64 - 1);
        if today == 0 {
            if average == 0 {
                return String::new();
            }
            return format!(
                "No Claude usage yet today. You averaged {} tokens a day this week.",
                format_tokens(average)
            );
        }
        let mut text = format!("{} tokens today", format_tokens(today));
        match snap.projects.len() {
            0 => {}
            1 => text.push_str(" in 1 project"),
            n => text.push_str(&format!(" across {n} projects")),
        }
        if average > 0 {
            let ratio = today as f64 / average as f64;
            if ratio >= 1.2 {
                text.push_str(&format!(
                    ", {:.0}% above your daily average",
                    ((ratio - 1.0) * 100.0).min(999.0)
                ));
            } else if ratio <= 0.8 {
                text.push_str(&format!(
                    ", {:.0}% below your daily average",
                    (1.0 - ratio) * 100.0
                ));
            } else {
                text.push_str(", about your daily average");
            }
        }
        text.push('.');
        match (snap.models.first(), snap.projects.first()) {
            (Some(m), Some(p)) => text.push_str(&format!(" Mostly {} on {}.", m.name, p.name)),
            (Some(m), None) => text.push_str(&format!(" Mostly {}.", m.name)),
            (None, Some(p)) => text.push_str(&format!(" Mostly on {}.", p.name)),
            (None, None) => {}
        }
        text
    }

    /// True if no status line ever arrived or the last one is older than `max_age_ms`.
    /// A clock that went backwards counts as fresh.
    pub fn is_stale(&self, now: u64, max_age_ms: u64) -> bool {
        self.snap.updated_ms == 0 || now.saturating_sub(self.snap.updated_ms) > max_age_ms
    }
}

fn add_named(map: &mut BTreeMap<String, u64>, name: &str, tokens: u64) {
    if name.is_empty() {
        return;
    }
    if let Some(total) = map.get_mut(name) {
        *total = total.saturating_add(tokens);
    } else if map.len() < MAX_NAMES {
        map.insert(name.to_string(), tokens);
    }
}

/// Largest first; equal totals in name order.
fn top(map: &BTreeMap<String, u64>) -> Vec<NamedTokens> {
    let mut all: Vec<_> = map.iter().collect();
    all.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
    all.into_iter()
        .take(TOP_NAMES)
        .map(|(name, tokens)| NamedTokens {
            name: name.clone(),
            tokens: *tokens,
        })
        .collect()
}

/// A percentage as `f32`, or `None` if it does not fit: an infinite value
/// would serialize as `null` and break the shell's decoding of the view.
fn finite_f32(value: f64) -> Option<f32> {
    let narrowed = value as f32;
    narrowed.is_finite().then_some(narrowed)
}

fn window(v: Option<&Value>) -> Option<RateWindow> {
    let v = v?;
    let used_pct = v
        .get("used_percentage")
        .and_then(Value::as_f64)
        .and_then(finite_f32)?;
    let resets_at_ms = v.get("resets_at").and_then(|r| {
        r.as_u64()
            .or_else(|| r.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64))
            .map(|s| s.saturating_mul(1000))
    });
    Some(RateWindow {
        used_pct,
        resets_at_ms,
    })
}

fn digits(b: &[u8]) -> Option<i64> {
    if b.is_empty() || !b.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(b.iter().fold(0i64, |a, d| a * 10 + i64::from(d - b'0')))
}

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        2 if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

/// Parses an RFC 3339 timestamp to Unix ms; `None` if malformed or before 1970.
/// Fractions are truncated to milliseconds; a leap second (`:60`) rolls forward.
pub fn parse_rfc3339_ms(s: &str) -> Option<u64> {
    if !s.is_ascii() || s.len() < 20 {
        return None;
    }
    let b = s.as_bytes();
    if b[4] != b'-' || b[7] != b'-' || !matches!(b[10], b'T' | b't') || b[13] != b':' {
        return None;
    }
    if b[16] != b':' {
        return None;
    }
    let (y, mo, d) = (digits(&b[0..4])?, digits(&b[5..7])?, digits(&b[8..10])?);
    let (h, mi, sec) = (
        digits(&b[11..13])?,
        digits(&b[14..16])?,
        digits(&b[17..19])?,
    );
    if !(1..=12).contains(&mo) || d < 1 || d > days_in_month(y, mo) || h > 23 || mi > 59 || sec > 60
    {
        return None;
    }
    let mut i = 19;
    let mut frac_ms = 0i64;
    if b[i] == b'.' {
        let start = i + 1;
        i = start;
        while i < b.len() && b[i].is_ascii_digit() {
            i += 1;
        }
        if i == start {
            return None;
        }
        let mut f = b[start..i].iter().take(3).map(|c| i64::from(c - b'0'));
        for scale in [100, 10, 1] {
            frac_ms += f.next().unwrap_or(0) * scale;
        }
    }
    let rest = &b[i..];
    let offset_secs = match rest {
        [b'Z' | b'z'] => 0,
        [sign @ (b'+' | b'-'), hh @ .., b':', m1, m2] if hh.len() == 2 => {
            let oh = digits(hh)?;
            let om = digits(&[*m1, *m2])?;
            if oh > 23 || om > 59 {
                return None;
            }
            let o = oh * 3600 + om * 60;
            if *sign == b'-' {
                -o
            } else {
                o
            }
        }
        _ => return None,
    };
    // Days-from-civil (Howard Hinnant); March-based years.
    let yy = if mo <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let mp = if mo > 2 { mo - 3 } else { mo + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let secs = days * 86_400 + h * 3600 + mi * 60 + sec - offset_secs;
    if secs < 0 {
        return None;
    }
    u64::try_from(secs * 1000 + frac_ms).ok()
}

/// Compact one-line summary such as `5h 42% · 7d 18%`; empty when no window is known.
pub fn statusline_text(s: &UsageSnapshot) -> String {
    let mut parts = Vec::new();
    if let Some(w) = &s.five_hour {
        parts.push(format!("5h {}%", w.used_pct.round()));
    }
    if let Some(w) = &s.seven_day {
        parts.push(format!("7d {}%", w.used_pct.round()));
    }
    parts.join(" · ")
}

#[cfg(test)]
mod tests {
    use super::*;

    const FULL: &str = r#"{
        "model": {"id": "claude-x", "display_name": "Sonnet"},
        "cost": {"total_cost_usd": 1.25},
        "context_window": {"used_percentage": 33.5},
        "rate_limits": {
            "five_hour": {"used_percentage": 42.4, "resets_at": 1700000000},
            "seven_day": {"used_percentage": 18, "resets_at": 1700500000}
        }
    }"#;

    fn line(id: &str, req: &str, ts: &str) -> String {
        format!(
            r#"{{"type":"assistant","timestamp":"{ts}","requestId":"{req}","message":{{"id":"{id}","role":"assistant","usage":{{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}}}}"#
        )
    }

    const DAY_START: u64 = 1_700_000_000_000;
    const DAY_END: u64 = DAY_START + 86_400_000;

    #[test]
    fn statusline_parses_all_fields() {
        let mut u = Usage::new();
        u.on_statusline(FULL, 5).unwrap();
        let s = u.snapshot(5);
        let f = s.five_hour.unwrap();
        assert!((f.used_pct - 42.4).abs() < 1e-4);
        assert_eq!(f.resets_at_ms, Some(1_700_000_000_000));
        assert_eq!(s.seven_day.unwrap().resets_at_ms, Some(1_700_500_000_000));
        assert_eq!(s.session_cost_usd, Some(1.25));
        assert_eq!(s.context_pct, Some(33.5));
        assert_eq!(s.model.as_deref(), Some("Sonnet"));
        assert_eq!(s.updated_ms, 5);
    }

    #[test]
    fn statusline_empty_object_leaves_everything_none() {
        let mut u = Usage::new();
        u.on_statusline("{}", 9).unwrap();
        let s = u.snapshot(9);
        assert!(s.five_hour.is_none() && s.seven_day.is_none());
        assert!(s.session_cost_usd.is_none() && s.context_pct.is_none() && s.model.is_none());
        assert_eq!(s.updated_ms, 9);
    }

    #[test]
    fn statusline_falls_back_to_model_id() {
        let mut u = Usage::new();
        u.on_statusline(r#"{"model":{"id":"claude-x"}}"#, 1)
            .unwrap();
        assert_eq!(u.snapshot(1).model.as_deref(), Some("claude-x"));
        u.on_statusline(r#"{"model":{"id":"m","display_name":""}}"#, 2)
            .unwrap();
        assert_eq!(u.snapshot(2).model.as_deref(), Some("m"));
    }

    #[test]
    fn statusline_window_without_percentage_is_none() {
        let mut u = Usage::new();
        u.on_statusline(r#"{"rate_limits":{"five_hour":{"resets_at":5}}}"#, 1)
            .unwrap();
        assert!(u.snapshot(1).five_hour.is_none());
    }

    #[test]
    fn statusline_window_without_reset_keeps_percentage() {
        let mut u = Usage::new();
        u.on_statusline(r#"{"rate_limits":{"seven_day":{"used_percentage":7}}}"#, 1)
            .unwrap();
        let w = u.snapshot(1).seven_day.unwrap();
        assert_eq!(w.resets_at_ms, None);
        assert_eq!(w.used_pct, 7.0);
    }

    #[test]
    fn statusline_accepts_fractional_reset_seconds() {
        let mut u = Usage::new();
        u.on_statusline(
            r#"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":10.7}}}"#,
            1,
        )
        .unwrap();
        assert_eq!(u.snapshot(1).five_hour.unwrap().resets_at_ms, Some(10_000));
    }

    #[test]
    fn statusline_negative_reset_is_ignored_and_huge_saturates() {
        let mut u = Usage::new();
        u.on_statusline(
            r#"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":-5.0}}}"#,
            1,
        )
        .unwrap();
        assert_eq!(u.snapshot(1).five_hour.unwrap().resets_at_ms, None);
        u.on_statusline(
            r#"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":18446744073709551615}}}"#,
            2,
        )
        .unwrap();
        assert_eq!(
            u.snapshot(2).five_hour.unwrap().resets_at_ms,
            Some(u64::MAX)
        );
    }

    #[test]
    fn statusline_values_over_100_are_kept() {
        let mut u = Usage::new();
        u.on_statusline(
            r#"{"rate_limits":{"five_hour":{"used_percentage":150.0}}}"#,
            1,
        )
        .unwrap();
        assert_eq!(u.snapshot(1).five_hour.unwrap().used_pct, 150.0);
    }

    #[test]
    fn statusline_later_call_clears_absent_fields() {
        let mut u = Usage::new();
        u.on_statusline(FULL, 1).unwrap();
        u.on_statusline(r#"{"cost":{"total_cost_usd":2.0}}"#, 2)
            .unwrap();
        let s = u.snapshot(2);
        assert!(s.five_hour.is_none() && s.model.is_none());
        assert_eq!(s.session_cost_usd, Some(2.0));
    }

    #[test]
    fn statusline_rejects_bad_json_and_non_objects() {
        let mut u = Usage::new();
        assert!(matches!(
            u.on_statusline("not json", 1),
            Err(UsageError::InvalidJson(_))
        ));
        assert_eq!(u.on_statusline("[1]", 1), Err(UsageError::NotAnObject));
        assert!(u.on_statusline("", 1).is_err());
        assert_eq!(u.snapshot(1).updated_ms, 0);
    }

    #[test]
    fn statusline_handles_unicode_model_name() {
        let mut u = Usage::new();
        u.on_statusline(r#"{"model":{"display_name":"โมเดล 🚀"}}"#, 1)
            .unwrap();
        assert_eq!(u.snapshot(1).model.as_deref(), Some("โมเดล 🚀"));
    }

    #[test]
    fn usage_error_display_and_serde() {
        let e = UsageError::InvalidJson("x".into());
        assert!(e.to_string().contains("invalid status line JSON: x"));
        assert!(UsageError::NotAnObject.to_string().contains("object"));
        let j = serde_json::to_string(&UsageError::NotAnObject).unwrap();
        assert_eq!(j, "\"not_an_object\"");
        let _: &dyn std::error::Error = &e;
    }

    #[test]
    fn transcript_counts_tokens_in_day() {
        let mut u = Usage::new();
        let l = line("m1", "r1", "2023-11-14T22:14:00Z");
        assert!(u.ingest_transcript_line(&l, DAY_START, DAY_END));
        let t = u.snapshot(0).today;
        assert_eq!(
            t,
            TokenTotals {
                input: 10,
                output: 20,
                cache_read: 30,
                cache_write: 40,
                messages: 1
            }
        );
    }

    #[test]
    fn transcript_dedupes_by_message_and_request() {
        let mut u = Usage::new();
        let l = line("m1", "r1", "2023-11-14T22:14:30Z");
        assert!(u.ingest_transcript_line(&l, DAY_START, DAY_END));
        assert!(!u.ingest_transcript_line(&l, DAY_START, DAY_END));
        assert!(u.ingest_transcript_line(
            &line("m1", "r2", "2023-11-14T22:14:30Z"),
            DAY_START,
            DAY_END
        ));
        assert!(u.ingest_transcript_line(
            &line("m2", "r1", "2023-11-14T22:14:30Z"),
            DAY_START,
            DAY_END
        ));
        assert_eq!(u.snapshot(0).today.messages, 3);
    }

    #[test]
    fn transcript_day_bounds_are_start_inclusive_end_exclusive() {
        let mut u = Usage::new();
        // DAY_START is 2023-11-14T22:13:20Z.
        assert!(u.ingest_transcript_line(
            &line("a", "r", "2023-11-14T22:13:20Z"),
            DAY_START,
            DAY_END
        ));
        assert!(!u.ingest_transcript_line(
            &line("b", "r", "2023-11-14T22:13:19.999Z"),
            DAY_START,
            DAY_END
        ));
        assert!(!u.ingest_transcript_line(
            &line("c", "r", "2023-11-15T22:13:20Z"),
            DAY_START,
            DAY_END
        ));
        assert!(u.ingest_transcript_line(
            &line("d", "r", "2023-11-15T22:13:19.999Z"),
            DAY_START,
            DAY_END
        ));
        assert_eq!(u.snapshot(0).today.messages, 2);
    }

    #[test]
    fn transcript_out_of_day_line_is_not_marked_seen() {
        let mut u = Usage::new();
        let l = line("m", "r", "2023-11-16T00:00:00Z");
        assert!(!u.ingest_transcript_line(&l, DAY_START, DAY_END));
        assert!(u.ingest_transcript_line(&l, 0, u64::MAX));
    }

    #[test]
    fn transcript_ignores_malformed_and_irrelevant_lines() {
        let mut u = Usage::new();
        let ts = "2023-11-14T23:00:00Z";
        let cases = [
            "".to_string(),
            "garbage".to_string(),
            "{".to_string(),
            "[]".to_string(),
            r#"{"type":"user","timestamp":"2023-11-14T23:00:00Z","message":{"usage":{}}}"#
                .to_string(),
            format!(r#"{{"timestamp":"{ts}","message":{{"role":"user","usage":{{}}}}}}"#),
            r#"{"type":"assistant","message":{"usage":{}}}"#.to_string(),
            r#"{"type":"assistant","timestamp":"bad","message":{"usage":{}}}"#.to_string(),
            format!(r#"{{"type":"assistant","timestamp":"{ts}","message":{{"id":"x"}}}}"#),
            format!(r#"{{"type":"assistant","timestamp":"{ts}","message":{{"usage":5}}}}"#),
            r#"{"type":"assistant","timestamp":7,"message":{"usage":{}}}"#.to_string(),
        ];
        for c in &cases {
            assert!(!u.ingest_transcript_line(c, 0, u64::MAX), "{c}");
        }
        assert_eq!(u.snapshot(0).today, TokenTotals::default());
    }

    #[test]
    fn transcript_without_message_id_always_counts() {
        let mut u = Usage::new();
        let l = r#"{"timestamp":"2023-11-14T23:00:00Z","message":{"usage":{"input_tokens":1}}}"#;
        assert!(u.ingest_transcript_line(l, 0, u64::MAX));
        assert!(u.ingest_transcript_line(l, 0, u64::MAX));
        let t = u.snapshot(0).today;
        assert_eq!((t.input, t.messages), (2, 2));
    }

    #[test]
    fn transcript_missing_request_id_still_dedupes() {
        let mut u = Usage::new();
        let l = r#"{"timestamp":"2023-11-14T23:00:00Z","message":{"id":"m","usage":{}}}"#;
        assert!(u.ingest_transcript_line(l, 0, u64::MAX));
        assert!(!u.ingest_transcript_line(l, 0, u64::MAX));
    }

    #[test]
    fn transcript_missing_or_bad_token_fields_count_as_zero() {
        let mut u = Usage::new();
        let l = r#"{"timestamp":"2023-11-14T23:00:00Z","message":{"id":"m","usage":{"input_tokens":"x","output_tokens":-3,"cache_read_input_tokens":4}}}"#;
        assert!(u.ingest_transcript_line(l, 0, u64::MAX));
        let t = u.snapshot(0).today;
        assert_eq!(
            (t.input, t.output, t.cache_read, t.cache_write),
            (0, 0, 4, 0)
        );
    }

    #[test]
    fn transcript_totals_saturate() {
        let mut u = Usage::new();
        let big = format!(
            r#"{{"timestamp":"2023-11-14T23:00:00Z","message":{{"usage":{{"input_tokens":{},"output_tokens":{},"cache_read_input_tokens":{},"cache_creation_input_tokens":{}}}}}}}"#,
            u64::MAX,
            u64::MAX,
            u64::MAX,
            u64::MAX
        );
        assert!(u.ingest_transcript_line(&big, 0, u64::MAX));
        assert!(u.ingest_transcript_line(&big, 0, u64::MAX));
        let t = u.snapshot(0).today;
        assert_eq!(t.input, u64::MAX);
        assert_eq!(t.output, u64::MAX);
        assert_eq!(t.cache_read, u64::MAX);
        assert_eq!(t.cache_write, u64::MAX);
        assert_eq!(t.messages, 2);
    }

    #[test]
    fn transcript_empty_day_range_counts_nothing() {
        let mut u = Usage::new();
        let l = line("m", "r", "2023-11-14T23:00:00Z");
        assert!(!u.ingest_transcript_line(&l, 100, 100));
        assert!(!u.ingest_transcript_line(&l, 200, 100));
    }

    #[test]
    fn reset_today_clears_totals_and_dedupe() {
        let mut u = Usage::new();
        u.on_statusline(FULL, 1).unwrap();
        let l = line("m", "r", "2023-11-14T23:00:00Z");
        assert!(u.ingest_transcript_line(&l, 0, u64::MAX));
        u.reset_today();
        assert_eq!(u.snapshot(2).today, TokenTotals::default());
        assert!(u.ingest_transcript_line(&l, 0, u64::MAX));
        // Status-line data survives a day reset.
        assert!(u.snapshot(2).five_hour.is_some());
        u.reset_today();
        u.reset_today();
        assert_eq!(u.snapshot(2).today.messages, 0);
    }

    #[test]
    fn stale_before_first_statusline() {
        let u = Usage::new();
        assert!(u.is_stale(0, u64::MAX));
        assert!(u.is_stale(1_000_000, 10));
    }

    #[test]
    fn stale_after_max_age_only() {
        let mut u = Usage::new();
        u.on_statusline("{}", 1000).unwrap();
        assert!(!u.is_stale(1000, 0));
        assert!(!u.is_stale(1500, 500));
        assert!(u.is_stale(1501, 500));
    }

    #[test]
    fn stale_with_clock_going_backwards_is_fresh() {
        let mut u = Usage::new();
        u.on_statusline("{}", 5000).unwrap();
        assert!(!u.is_stale(10, 0));
    }

    #[test]
    fn stale_with_huge_values_does_not_overflow() {
        let mut u = Usage::new();
        u.on_statusline("{}", u64::MAX).unwrap();
        assert!(!u.is_stale(0, 0));
        assert!(!u.is_stale(u64::MAX, u64::MAX));
    }

    #[test]
    fn snapshot_is_repeatable_and_independent_of_now() {
        let mut u = Usage::new();
        u.on_statusline(FULL, 7).unwrap();
        assert_eq!(u.snapshot(0), u.snapshot(u64::MAX));
        assert_eq!(u.snapshot(0).week.len(), HISTORY_DAYS);
        assert_eq!(u.snapshot(1), u.snapshot(1));
    }

    #[test]
    fn rfc3339_utc_and_epoch() {
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:01Z"), Some(1000));
        assert_eq!(parse_rfc3339_ms("2023-11-14T22:13:20Z"), Some(DAY_START));
        assert_eq!(parse_rfc3339_ms("2023-11-14t22:13:20z"), Some(DAY_START));
    }

    #[test]
    fn rfc3339_fractions() {
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00.5Z"), Some(500));
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00.123Z"), Some(123));
        assert_eq!(
            parse_rfc3339_ms("1970-01-01T00:00:00.123456789Z"),
            Some(123)
        );
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00.05Z"), Some(50));
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00.Z"), None);
    }

    #[test]
    fn rfc3339_offsets() {
        assert_eq!(
            parse_rfc3339_ms("2023-11-15T05:13:20+07:00"),
            Some(DAY_START)
        );
        assert_eq!(
            parse_rfc3339_ms("2023-11-14T17:13:20-05:00"),
            Some(DAY_START)
        );
        assert_eq!(
            parse_rfc3339_ms("2023-11-14T22:13:20+00:00"),
            Some(DAY_START)
        );
        assert_eq!(
            parse_rfc3339_ms("2023-11-14T22:13:20.250+00:00"),
            Some(DAY_START + 250)
        );
    }

    #[test]
    fn rfc3339_leap_years_and_month_ends() {
        assert_eq!(
            parse_rfc3339_ms("2000-02-29T00:00:00Z"),
            Some(951_782_400_000)
        );
        assert!(parse_rfc3339_ms("2024-02-29T00:00:00Z").is_some());
        assert_eq!(parse_rfc3339_ms("1900-02-29T00:00:00Z"), None);
        assert_eq!(parse_rfc3339_ms("2023-02-29T00:00:00Z"), None);
        assert!(parse_rfc3339_ms("2023-04-30T00:00:00Z").is_some());
        assert_eq!(parse_rfc3339_ms("2023-04-31T00:00:00Z"), None);
        assert!(parse_rfc3339_ms("2023-12-31T23:59:59Z").is_some());
        assert_eq!(parse_rfc3339_ms("2023-13-01T00:00:00Z"), None);
        assert_eq!(parse_rfc3339_ms("2023-00-01T00:00:00Z"), None);
        assert_eq!(parse_rfc3339_ms("2023-01-00T00:00:00Z"), None);
    }

    #[test]
    fn rfc3339_leap_second_rolls_forward() {
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:60Z"), Some(60_000));
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:61Z"), None);
    }

    #[test]
    fn rfc3339_rejects_before_epoch() {
        assert_eq!(parse_rfc3339_ms("1969-12-31T23:59:59Z"), None);
        assert_eq!(parse_rfc3339_ms("1970-01-01T00:00:00+01:00"), None);
        assert_eq!(parse_rfc3339_ms("1970-01-01T01:00:00+01:00"), Some(0));
    }

    #[test]
    fn rfc3339_rejects_malformed() {
        for s in [
            "",
            "2023-11-14",
            "2023-11-14T22:13:20",
            "2023-11-14 22:13:20Z",
            "2023/11/14T22:13:20Z",
            "2023-11-14T22-13-20Z",
            "2023-11-14T22:13-20Z",
            "2023-11-14T24:00:00Z",
            "2023-11-14T22:60:00Z",
            "2023-11-14T22:13:20ZZ",
            "2023-11-14T22:13:20+0700",
            "2023-11-14T22:13:20+07:0",
            "2023-11-14T22:13:20+24:00",
            "2023-11-14T22:13:20+07:60",
            "2023-11-14T22:13:20+0a:00",
            "2023-11-14T22:13:20*07:00",
            "20x3-11-14T22:13:20Z",
            "2023-11-14T22:13:20.1",
            "2023-11-14T22:13:20.",
        ] {
            assert_eq!(parse_rfc3339_ms(s), None, "{s}");
        }
    }

    #[test]
    fn rfc3339_rejects_non_ascii_without_panicking() {
        assert_eq!(parse_rfc3339_ms("2023-11-14T22:13:20Z วัน"), None);
        assert_eq!(parse_rfc3339_ms("๒๐๒๓-๑๑-๑๔T๒๒:๑๓:๒๐Z"), None);
        assert_eq!(parse_rfc3339_ms("2023-11-14T22:13:20\u{2212}07:00"), None);
    }

    #[test]
    fn rfc3339_far_future_year() {
        assert!(parse_rfc3339_ms("9999-12-31T23:59:59Z").is_some());
    }

    #[test]
    fn text_shows_both_windows() {
        let mut u = Usage::new();
        u.on_statusline(FULL, 1).unwrap();
        assert_eq!(statusline_text(&u.snapshot(1)), "5h 42% · 7d 18%");
    }

    #[test]
    fn text_shows_single_window_or_nothing() {
        let mut s = UsageSnapshot::default();
        assert_eq!(statusline_text(&s), "");
        s.seven_day = Some(RateWindow {
            used_pct: 99.5,
            resets_at_ms: None,
        });
        assert_eq!(statusline_text(&s), "7d 100%");
        s.seven_day = None;
        s.five_hour = Some(RateWindow {
            used_pct: 0.0,
            resets_at_ms: Some(1),
        });
        assert_eq!(statusline_text(&s), "5h 0%");
    }

    #[test]
    fn snapshot_serde_roundtrip_and_defaults() {
        let mut u = Usage::new();
        u.on_statusline(FULL, 3).unwrap();
        let s = u.snapshot(3);
        let j = serde_json::to_string(&s).unwrap();
        let back: UsageSnapshot = serde_json::from_str(&j).unwrap();
        assert_eq!(s, back);
        let d: UsageSnapshot = serde_json::from_str("{}").unwrap();
        assert_eq!(d, UsageSnapshot::default());
        assert!(d.week.is_empty() && d.summary.is_empty());
        let t: TokenTotals = serde_json::from_str(r#"{"input":2}"#).unwrap();
        assert_eq!((t.input, t.output), (2, 0));
    }

    #[test]
    fn absurd_percentages_are_dropped_so_the_view_always_serializes_as_numbers() {
        let mut u = Usage::new();
        u.on_statusline(
            r#"{"rate_limits":{"five_hour":{"used_percentage":1e300},"seven_day":{"used_percentage":12.5}},
                "context_window":{"used_percentage":-1e300}}"#,
            1,
        )
        .unwrap();
        let s = u.snapshot(1);
        assert!(s.five_hour.is_none() && s.context_pct.is_none());
        assert_eq!(s.seven_day.as_ref().map(|w| w.used_pct), Some(12.5));
        assert!(!serde_json::to_string(&s).unwrap().contains("null,\"resets"));
        assert_eq!(
            serde_json::to_value(&s).unwrap()["seven_day"]["used_pct"],
            12.5
        );
    }

    fn record(id: u64, ts_ms: u64, model: &str, project: &str, tokens: u64) -> UsageRecord {
        UsageRecord {
            ts_ms,
            key: Some(id),
            model: model.into(),
            project: project.into(),
            input: tokens,
            ..UsageRecord::default()
        }
    }

    #[test]
    fn parse_record_reads_model_project_and_tokens() {
        let l = r#"{"type":"assistant","timestamp":"2023-11-14T22:14:00Z","cwd":"/Users/me/Github/LiteNotch/",
            "requestId":"r","message":{"id":"m","role":"assistant","model":"claude-fable-5-2",
            "usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}"#;
        let r = parse_record(l).unwrap();
        assert_eq!(r.ts_ms, 1_700_000_040_000);
        assert_eq!(
            (r.model.as_str(), r.project.as_str()),
            ("fable-5-2", "LiteNotch")
        );
        assert_eq!(
            (r.input, r.output, r.cache_read, r.cache_write),
            (1, 2, 3, 4)
        );
        assert!(r.key.is_some());
        // The same ids hash the same; another request does not.
        assert_eq!(parse_record(l).unwrap().key, r.key);
        assert_ne!(
            parse_record(&l.replace(r#""requestId":"r""#, r#""requestId":"q""#))
                .unwrap()
                .key,
            r.key
        );
    }

    #[test]
    fn parse_record_tolerates_missing_and_odd_names() {
        let l =
            r#"{"timestamp":"2023-11-14T22:14:00Z","message":{"model":"<synthetic>","usage":{}}}"#;
        let r = parse_record(l).unwrap();
        assert_eq!((r.model.as_str(), r.project.as_str()), ("", ""));
        assert_eq!(r.key, None);
        let l = r#"{"timestamp":"2023-11-14T22:14:00Z","cwd":"/a/b\u202e","message":{"model":"gpt","usage":{}}}"#;
        let r = parse_record(l).unwrap();
        assert_eq!(r.model, "gpt");
        assert!(!r.project.contains('\u{202e}'));
        assert!(parse_record(
            r#"{"type":"user","timestamp":"2023-11-14T22:14:00Z","message":{"usage":{}}}"#
        )
        .is_none());
    }

    #[test]
    fn the_project_is_where_the_session_started_not_where_it_moved_to() {
        let dir = Some("-Users-me-Github-my-app");
        assert_eq!(
            project_name("/Users/me/Github/my-app/crates/core", dir),
            "my-app"
        );
        assert_eq!(project_name("/Users/me/Github/my-app/", dir), "my-app");
        assert_eq!(
            project_name("/Users/me/Github/my.app", Some("-Users-me-Github-my-app")),
            "my.app"
        );
        // No match (a worktree elsewhere), or no directory known: the last component.
        assert_eq!(project_name("/tmp/elsewhere/sub", dir), "sub");
        assert_eq!(
            project_name("/Users/me/Github/my-app/crates", None),
            "crates"
        );
        assert_eq!(project_name("", dir), "");
        assert_eq!(project_name("/", dir), "");
        let line =
            r#"{"timestamp":"2023-11-14T22:14:00Z","cwd":"/w/api/src","message":{"usage":{}}}"#;
        assert_eq!(
            parse_record_in(line, Some("-w-api")).unwrap().project,
            "api"
        );
    }

    #[test]
    fn earlier_days_go_to_the_week_not_to_today() {
        let mut u = Usage::new();
        u.set_day(DAY_START);
        assert!(u.ingest(
            &record(1, DAY_START + 5, "fable", "api", 100),
            DAY_START,
            DAY_END
        ));
        // Yesterday, six days ago, and too old.
        assert!(!u.ingest(
            &record(2, DAY_START - 1, "fable", "api", 7),
            DAY_START,
            DAY_END
        ));
        assert!(!u.ingest(
            &record(3, DAY_START - 6 * DAY_MS, "fable", "api", 9),
            DAY_START,
            DAY_END
        ));
        assert!(!u.ingest(
            &record(4, DAY_START - 6 * DAY_MS - 1, "fable", "api", 1000),
            DAY_START,
            DAY_END
        ));
        // A repeat of yesterday's message is ignored.
        assert!(!u.ingest(
            &record(2, DAY_START - 1, "fable", "api", 7),
            DAY_START,
            DAY_END
        ));
        let s = u.snapshot(0);
        let tokens: Vec<u64> = s.week.iter().map(|d| d.tokens).collect();
        assert_eq!(tokens, vec![9, 0, 0, 0, 0, 7, 100]);
        assert_eq!(s.week[6].day_start_ms, DAY_START);
        assert_eq!(s.week[5].day_start_ms, DAY_START - DAY_MS);
        assert_eq!(s.week[0].messages, 1);
        assert_eq!(s.today.input, 100);
    }

    #[test]
    fn models_and_projects_are_ranked_and_limited() {
        let mut u = Usage::new();
        u.set_day(DAY_START);
        let rows = [
            ("opus", "api", 50),
            ("fable", "web", 300),
            ("fable", "api", 20),
            ("haiku", "docs", 5),
            ("sonnet", "cli", 5),
            ("mini", "infra", 1),
            ("", "", 999),
        ];
        for (i, (model, project, tokens)) in rows.iter().enumerate() {
            u.ingest(
                &record(i as u64, DAY_START + 1, model, project, *tokens),
                DAY_START,
                DAY_END,
            );
        }
        let s = u.snapshot(0);
        let names = |v: &[NamedTokens]| {
            v.iter()
                .map(|n| (n.name.clone(), n.tokens))
                .collect::<Vec<_>>()
        };
        assert_eq!(
            names(&s.models),
            vec![
                ("fable".to_string(), 320),
                ("opus".to_string(), 50),
                ("haiku".to_string(), 5),
                ("sonnet".to_string(), 5)
            ]
        );
        assert_eq!(
            s.projects[0],
            NamedTokens {
                name: "web".into(),
                tokens: 300
            }
        );
        assert_eq!(s.projects.len(), 4);
    }

    #[test]
    fn name_lists_do_not_grow_without_bound() {
        let mut u = Usage::new();
        for i in 0..(MAX_NAMES as u64 + 20) {
            u.ingest(&record(i, 5, &format!("m{i}"), "p", 1), 0, u64::MAX);
        }
        assert_eq!(u.models.len(), MAX_NAMES);
        assert_eq!(u.projects.len(), 1);
    }

    #[test]
    fn a_new_day_moves_today_into_the_history() {
        let mut u = Usage::new();
        u.set_day(DAY_START);
        u.ingest(
            &record(1, DAY_START + 1, "fable", "api", 100),
            DAY_START,
            DAY_END,
        );
        u.ingest(
            &record(2, DAY_START - 1, "fable", "api", 40),
            DAY_START,
            DAY_END,
        );
        u.set_day(DAY_START);
        assert_eq!(u.snapshot(0).today.input, 100);

        u.set_day(DAY_START + 2 * DAY_MS);
        let s = u.snapshot(0);
        let tokens: Vec<u64> = s.week.iter().map(|d| d.tokens).collect();
        assert_eq!(tokens, vec![0, 0, 0, 40, 100, 0, 0]);
        assert_eq!(s.today, TokenTotals::default());
        assert!(s.models.is_empty() && s.projects.is_empty());
        // The message is still known, so a rescan does not count it twice.
        assert!(!u.ingest(
            &record(1, DAY_START + 1, "fable", "api", 100),
            DAY_START + 2 * DAY_MS,
            DAY_START + 3 * DAY_MS
        ));
        assert_eq!(u.snapshot(0).week[4].tokens, 100);

        // Far ahead, or backwards: nothing of the old week remains.
        u.set_day(DAY_START + 30 * DAY_MS);
        assert!(u.snapshot(0).week.iter().all(|d| d.tokens == 0));
        u.ingest(
            &record(9, DAY_START + 30 * DAY_MS, "fable", "api", 5),
            DAY_START + 30 * DAY_MS,
            u64::MAX,
        );
        u.set_day(DAY_START);
        assert!(u.snapshot(0).week.iter().all(|d| d.tokens == 0));
    }

    #[test]
    fn reset_clears_history_and_names() {
        let mut u = Usage::new();
        u.set_day(DAY_START);
        u.ingest(
            &record(1, DAY_START + 1, "fable", "api", 100),
            DAY_START,
            DAY_END,
        );
        u.ingest(
            &record(2, DAY_START - 1, "fable", "api", 40),
            DAY_START,
            DAY_END,
        );
        u.reset_today();
        let s = u.snapshot(0);
        assert!(s.week.iter().all(|d| d.tokens == 0));
        assert!(s.models.is_empty() && s.summary.is_empty());
        assert_eq!(s.week[6].day_start_ms, DAY_START);
    }

    #[test]
    fn summary_compares_today_with_the_week() {
        let mut u = Usage::new();
        u.set_day(DAY_START);
        assert_eq!(u.snapshot(0).summary, "");
        // 6000 tokens over the six earlier days: 1000 a day.
        u.ingest(
            &record(1, DAY_START - 1, "fable", "api", 6_000),
            DAY_START,
            DAY_END,
        );
        assert_eq!(
            u.snapshot(0).summary,
            "No Claude usage yet today. You averaged 1k tokens a day this week."
        );
        u.ingest(
            &record(2, DAY_START + 1, "fable-5-2", "api", 1_000),
            DAY_START,
            DAY_END,
        );
        assert_eq!(
            u.snapshot(0).summary,
            "1k tokens today in 1 project, about your daily average. Mostly fable-5-2 on api."
        );
        u.ingest(
            &record(3, DAY_START + 1, "fable-5-2", "web", 1_500),
            DAY_START,
            DAY_END,
        );
        assert_eq!(
            u.snapshot(0).summary,
            "2k tokens today across 2 projects, 150% above your daily average. Mostly fable-5-2 on web."
        );
    }

    #[test]
    fn summary_without_history_or_names() {
        let mut u = Usage::new();
        u.ingest(&record(1, 5, "", "", 500), 0, u64::MAX);
        assert_eq!(u.snapshot(0).summary, "500 tokens today.");
        let mut u = Usage::new();
        u.set_day(DAY_START);
        u.ingest(
            &record(1, DAY_START - 1, "", "", 60_000),
            DAY_START,
            DAY_END,
        );
        u.ingest(
            &record(2, DAY_START + 1, "opus", "", 2_000),
            DAY_START,
            DAY_END,
        );
        assert_eq!(
            u.snapshot(0).summary,
            "2k tokens today, 80% below your daily average. Mostly opus."
        );
        let mut u = Usage::new();
        u.ingest(&record(1, 5, "", "api", 500), 0, u64::MAX);
        assert_eq!(
            u.snapshot(0).summary,
            "500 tokens today in 1 project. Mostly on api."
        );
    }

    #[test]
    fn tokens_are_formatted_compactly() {
        assert_eq!(format_tokens(0), "0");
        assert_eq!(format_tokens(999), "999");
        assert_eq!(format_tokens(45_300), "45k");
        assert_eq!(format_tokens(1_234_567), "1.2M");
        assert_eq!(format_tokens(3_400_000_000), "3.4B");
    }

    #[test]
    fn local_day_start_follows_the_offset() {
        assert_eq!(local_day_start_ms(DAY_MS + 5, 0), DAY_MS);
        // UTC+7: the local day began 7 hours before UTC midnight.
        assert_eq!(
            local_day_start_ms(DAY_MS + 5, 7 * 3600),
            DAY_MS - 7 * 3_600_000
        );
        assert_eq!(local_day_start_ms(DAY_MS + 5, -5 * 3600), 5 * 3_600_000);
        assert_eq!(local_day_start_ms(0, -3600), 0);
    }
}
