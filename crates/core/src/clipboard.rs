//! Clipboard history: dedupe, pinning, limits, search and persistence.

use serde::{Deserialize, Serialize};

/// Upper bound for `max_items` so a bad config cannot grow memory unbounded.
const MAX_ITEMS_CEILING: usize = 10_000;

/// Most items that can be pinned; pinned items are exempt from eviction, so
/// without a cap they would be the one way to grow memory without bound.
pub const MAX_PINNED: usize = 20;

/// What the pasteboard held.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClipKind {
    /// Plain text.
    Text,
    /// File references; `text` holds a printable description.
    Files,
    /// Image; `text` holds a printable description.
    Image,
}

/// A raw pasteboard reading handed over by the platform layer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipCapture {
    /// Kind of content.
    pub kind: ClipKind,
    /// Text or description of the content.
    pub text: String,
    /// Frontmost app that produced the copy, if known.
    pub source_app: Option<String>,
    /// Marked concealed/transient (e.g. password managers).
    pub concealed: bool,
    /// For an image: the file the runtime saved it to.
    #[serde(default)]
    pub image_path: Option<String>,
    /// For formatted text: the file holding the formatting (RTF or HTML).
    #[serde(default)]
    pub rich_path: Option<String>,
}

/// A stored history entry.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClipItem {
    /// Monotonic id, never reused.
    pub id: u64,
    /// Kind of content.
    pub kind: ClipKind,
    /// Text or description of the content.
    pub text: String,
    /// App the item was copied from.
    pub source_app: Option<String>,
    /// Time of the latest capture of this content.
    pub created_ms: u64,
    /// Pinned items sort first and never evict.
    pub pinned: bool,
    /// Size of `text` in bytes. Image data lives in a file and is not counted.
    pub byte_len: usize,
    /// For an image: the file holding it.
    #[serde(default)]
    pub image_path: Option<String>,
    /// For formatted text: the file holding the formatting.
    #[serde(default)]
    pub rich_path: Option<String>,
}

/// Clipboard settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ClipboardConfig {
    /// Master switch; when off every capture is ignored.
    pub enabled: bool,
    /// Max unpinned items kept (clamped to 1..=10000).
    pub max_items: usize,
    /// Captures larger than this many bytes are ignored.
    pub max_item_bytes: usize,
    /// Unpinned items are evicted, oldest first, to stay under this total.
    pub max_total_bytes: usize,
    /// Skip captures flagged concealed.
    pub ignore_concealed: bool,
    /// Source apps whose copies are skipped (case-insensitive).
    pub excluded_apps: Vec<String>,
}

impl Default for ClipboardConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            max_items: 100,
            max_item_bytes: 262_144,
            max_total_bytes: 4 * 1024 * 1024,
            ignore_concealed: true,
            excluded_apps: Vec::new(),
        }
    }
}

impl ClipboardConfig {
    fn clamped(mut self) -> Self {
        self.max_items = self.max_items.clamp(1, MAX_ITEMS_CEILING);
        self
    }
}

/// Why a capture was not stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IgnoreReason {
    /// Clipboard history is disabled.
    Disabled,
    /// Capture was flagged concealed.
    Concealed,
    /// Source app is excluded.
    ExcludedApp,
    /// Text is empty or whitespace only.
    Empty,
    /// Text exceeds `max_item_bytes`.
    TooLarge,
}

/// Result of [`ClipboardHistory::capture`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CaptureOutcome {
    /// New item stored with this id.
    Added(u64),
    /// Existing identical item moved to the top.
    Bumped(u64),
    /// Not stored.
    Ignored(IgnoreReason),
}

/// Serializable history state for persistence.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct PersistedClipboard {
    /// Items, newest first.
    pub items: Vec<ClipItem>,
    /// Next id to hand out.
    pub next_id: u64,
}

/// Clipboard history store.
#[derive(Debug, Clone, PartialEq)]
pub struct ClipboardHistory {
    cfg: ClipboardConfig,
    /// Newest first, regardless of pin state.
    items: Vec<ClipItem>,
    next_id: u64,
}

impl ClipboardHistory {
    /// Empty history with the given config.
    pub fn new(cfg: ClipboardConfig) -> Self {
        Self {
            cfg: cfg.clamped(),
            items: Vec::new(),
            next_id: 1,
        }
    }

    /// Current (clamped) config.
    pub fn config(&self) -> &ClipboardConfig {
        &self.cfg
    }

    /// Replace the config and re-apply the item cap (oversized kept items stay).
    pub fn set_config(&mut self, cfg: ClipboardConfig) {
        self.cfg = cfg.clamped();
        self.evict();
    }

    /// Record a pasteboard reading.
    pub fn capture(&mut self, c: ClipCapture, now_ms: u64) -> CaptureOutcome {
        if !self.cfg.enabled {
            return CaptureOutcome::Ignored(IgnoreReason::Disabled);
        }
        if c.concealed && self.cfg.ignore_concealed {
            return CaptureOutcome::Ignored(IgnoreReason::Concealed);
        }
        if let Some(app) = &c.source_app {
            if self
                .cfg
                .excluded_apps
                .iter()
                .any(|e| e.eq_ignore_ascii_case(app))
            {
                return CaptureOutcome::Ignored(IgnoreReason::ExcludedApp);
            }
        }
        if c.text.trim().is_empty() {
            return CaptureOutcome::Ignored(IgnoreReason::Empty);
        }
        if c.text.len() > self.cfg.max_item_bytes {
            return CaptureOutcome::Ignored(IgnoreReason::TooLarge);
        }
        if let Some(pos) = self
            .items
            .iter()
            .position(|i| i.kind == c.kind && i.text == c.text && i.image_path == c.image_path)
        {
            let mut item = self.items.remove(pos);
            item.created_ms = now_ms;
            if c.source_app.is_some() {
                item.source_app = c.source_app;
            }
            // The latest copy of the same text decides its formatting.
            item.rich_path = c.rich_path;
            let id = item.id;
            self.items.insert(0, item);
            return CaptureOutcome::Bumped(id);
        }
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        let byte_len = c.text.len();
        self.items.insert(
            0,
            ClipItem {
                id,
                kind: c.kind,
                text: c.text,
                source_app: c.source_app,
                created_ms: now_ms,
                pinned: false,
                byte_len,
                image_path: c.image_path,
                rich_path: c.rich_path,
            },
        );
        self.evict();
        CaptureOutcome::Added(id)
    }

    /// Items with pinned first, then newest first.
    pub fn items(&self) -> Vec<&ClipItem> {
        let pinned = self.items.iter().filter(|i| i.pinned);
        let rest = self.items.iter().filter(|i| !i.pinned);
        pinned.chain(rest).collect()
    }

    /// Look an item up by id.
    pub fn get(&self, id: u64) -> Option<&ClipItem> {
        self.items.iter().find(|i| i.id == id)
    }

    /// Pin or unpin; false if the id is unknown or `MAX_PINNED` items are
    /// already pinned. Unpinning may evict.
    pub fn set_pinned(&mut self, id: u64, pinned: bool) -> bool {
        let pinned_count = self.items.iter().filter(|i| i.pinned).count();
        let Some(item) = self.items.iter_mut().find(|i| i.id == id) else {
            return false;
        };
        if pinned && !item.pinned && pinned_count >= MAX_PINNED {
            return false;
        }
        item.pinned = pinned;
        self.evict();
        true
    }

    /// Delete one item; false if the id is unknown.
    /// Files (images, formatting) the history still refers to.
    pub fn file_paths(&self) -> Vec<String> {
        self.items
            .iter()
            .flat_map(|i| [i.image_path.clone(), i.rich_path.clone()])
            .flatten()
            .collect()
    }

    pub fn remove(&mut self, id: u64) -> bool {
        let before = self.items.len();
        self.items.retain(|i| i.id != id);
        self.items.len() != before
    }

    /// Delete everything, or everything unpinned.
    pub fn clear(&mut self, keep_pinned: bool) {
        if keep_pinned {
            self.items.retain(|i| i.pinned);
        } else {
            self.items.clear();
        }
    }

    /// Case-insensitive substring search in `items()` order; empty query returns all.
    pub fn search(&self, query: &str) -> Vec<&ClipItem> {
        let q = query.to_lowercase();
        self.items()
            .into_iter()
            .filter(|i| q.is_empty() || i.text.to_lowercase().contains(&q))
            .collect()
    }

    /// Single-line preview of at most `max_chars` chars, ending in `…` when cut.
    pub fn preview(text: &str, max_chars: usize) -> String {
        let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
        if collapsed.chars().count() <= max_chars {
            return collapsed;
        }
        if max_chars == 0 {
            return String::new();
        }
        let mut out: String = collapsed.chars().take(max_chars - 1).collect();
        out.push('…');
        out
    }

    /// Snapshot for persistence.
    pub fn to_persisted(&self) -> PersistedClipboard {
        PersistedClipboard {
            items: self.items.clone(),
            next_id: self.next_id,
        }
    }

    /// Rebuild from persisted state; `next_id` is raised above every stored id.
    pub fn from_persisted(cfg: ClipboardConfig, p: PersistedClipboard) -> Self {
        let max_id = p.items.iter().map(|i| i.id).max().unwrap_or(0);
        let mut h = Self {
            cfg: cfg.clamped(),
            items: p.items,
            next_id: p.next_id.max(max_id.saturating_add(1)).max(1),
        };
        h.evict();
        h
    }

    /// Drop the oldest unpinned items beyond `max_items` or `max_total_bytes`.
    /// The newest unpinned item always survives the byte limit.
    fn evict(&mut self) {
        let mut unpinned = self.items.iter().filter(|i| !i.pinned).count();
        let mut bytes: usize = self
            .items
            .iter()
            .filter(|i| !i.pinned)
            .map(|i| i.byte_len)
            .sum();
        let mut idx = self.items.len();
        while idx > 0
            && (unpinned > self.cfg.max_items || (bytes > self.cfg.max_total_bytes && unpinned > 1))
        {
            idx -= 1;
            if !self.items[idx].pinned {
                bytes = bytes.saturating_sub(self.items[idx].byte_len);
                self.items.remove(idx);
                unpinned -= 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(s: &str) -> ClipCapture {
        ClipCapture {
            kind: ClipKind::Text,
            text: s.to_string(),
            source_app: None,
            concealed: false,
            image_path: None,
            rich_path: None,
        }
    }

    fn hist() -> ClipboardHistory {
        ClipboardHistory::new(ClipboardConfig::default())
    }

    fn texts(h: &ClipboardHistory) -> Vec<String> {
        h.items().iter().map(|i| i.text.clone()).collect()
    }

    #[test]
    fn defaults_match_contract() {
        let c = ClipboardConfig::default();
        assert!(c.enabled && c.ignore_concealed);
        assert_eq!(c.max_items, 100);
        assert_eq!(c.max_item_bytes, 262_144);
        assert!(c.excluded_apps.is_empty());
    }

    #[test]
    fn config_deserializes_with_defaults() {
        let c: ClipboardConfig = serde_json::from_str(r#"{"max_items":5}"#).unwrap();
        assert_eq!(c.max_items, 5);
        assert!(c.enabled);
    }

    #[test]
    fn capture_adds_with_monotonic_ids() {
        let mut h = hist();
        assert_eq!(h.capture(text("a"), 1), CaptureOutcome::Added(1));
        assert_eq!(h.capture(text("b"), 2), CaptureOutcome::Added(2));
        let it = h.get(2).unwrap();
        assert_eq!(it.created_ms, 2);
        assert_eq!(it.byte_len, 1);
        assert!(!it.pinned);
    }

    #[test]
    fn disabled_ignores_everything() {
        let mut h = ClipboardHistory::new(ClipboardConfig {
            enabled: false,
            ..Default::default()
        });
        assert_eq!(
            h.capture(text("a"), 1),
            CaptureOutcome::Ignored(IgnoreReason::Disabled)
        );
        assert!(h.items().is_empty());
    }

    #[test]
    fn concealed_ignored_by_default_but_allowed_when_configured() {
        let mut h = hist();
        let mut c = text("secret");
        c.concealed = true;
        assert_eq!(
            h.capture(c.clone(), 1),
            CaptureOutcome::Ignored(IgnoreReason::Concealed)
        );
        h.set_config(ClipboardConfig {
            ignore_concealed: false,
            ..Default::default()
        });
        assert_eq!(h.capture(c, 2), CaptureOutcome::Added(1));
    }

    #[test]
    fn excluded_app_is_case_insensitive() {
        let mut h = ClipboardHistory::new(ClipboardConfig {
            excluded_apps: vec!["1Password".into()],
            ..Default::default()
        });
        let mut c = text("x");
        c.source_app = Some("1password".into());
        assert_eq!(
            h.capture(c, 1),
            CaptureOutcome::Ignored(IgnoreReason::ExcludedApp)
        );
        let mut ok = text("x");
        ok.source_app = Some("Safari".into());
        assert_eq!(h.capture(ok, 2), CaptureOutcome::Added(1));
    }

    #[test]
    fn whitespace_only_is_empty() {
        let mut h = hist();
        for s in ["", "   ", "\n\t \r\n", "\u{3000}"] {
            assert_eq!(
                h.capture(text(s), 1),
                CaptureOutcome::Ignored(IgnoreReason::Empty)
            );
        }
    }

    #[test]
    fn too_large_boundary_uses_bytes() {
        let mut h = ClipboardHistory::new(ClipboardConfig {
            max_item_bytes: 4,
            ..Default::default()
        });
        assert_eq!(h.capture(text("abcd"), 1), CaptureOutcome::Added(1));
        assert_eq!(
            h.capture(text("abcde"), 2),
            CaptureOutcome::Ignored(IgnoreReason::TooLarge)
        );
        // 2 chars but 6 bytes
        assert_eq!(
            h.capture(text("日本"), 3),
            CaptureOutcome::Ignored(IgnoreReason::TooLarge)
        );
    }

    #[test]
    fn zero_max_bytes_rejects_all() {
        let mut h = ClipboardHistory::new(ClipboardConfig {
            max_item_bytes: 0,
            ..Default::default()
        });
        assert_eq!(
            h.capture(text("a"), 1),
            CaptureOutcome::Ignored(IgnoreReason::TooLarge)
        );
    }

    #[test]
    fn duplicate_bumps_to_top_and_updates_time() {
        let mut h = hist();
        h.capture(text("a"), 1);
        h.capture(text("b"), 2);
        assert_eq!(h.capture(text("a"), 3), CaptureOutcome::Bumped(1));
        assert_eq!(texts(&h), vec!["a", "b"]);
        assert_eq!(h.get(1).unwrap().created_ms, 3);
        assert_eq!(h.items().len(), 2);
    }

    #[test]
    fn bump_keeps_pin_and_updates_source_only_when_given() {
        let mut h = hist();
        let mut c = text("a");
        c.source_app = Some("Xcode".into());
        h.capture(c, 1);
        h.set_pinned(1, true);
        h.capture(text("a"), 2);
        assert_eq!(h.get(1).unwrap().source_app.as_deref(), Some("Xcode"));
        let mut c2 = text("a");
        c2.source_app = Some("Safari".into());
        h.capture(c2, 3);
        let it = h.get(1).unwrap();
        assert_eq!(it.source_app.as_deref(), Some("Safari"));
        assert!(it.pinned);
    }

    #[test]
    fn same_text_different_kind_is_distinct() {
        let mut h = hist();
        h.capture(text("a"), 1);
        let mut f = text("a");
        f.kind = ClipKind::Files;
        assert_eq!(h.capture(f, 2), CaptureOutcome::Added(2));
    }

    #[test]
    fn clock_going_backwards_keeps_insertion_order() {
        let mut h = hist();
        h.capture(text("a"), 100);
        h.capture(text("b"), 50);
        assert_eq!(texts(&h), vec!["b", "a"]);
        h.capture(text("a"), 10);
        assert_eq!(texts(&h), vec!["a", "b"]);
        assert_eq!(h.get(1).unwrap().created_ms, 10);
    }

    #[test]
    fn items_put_pinned_first_then_newest() {
        let mut h = hist();
        h.capture(text("a"), 1);
        h.capture(text("b"), 2);
        h.capture(text("c"), 3);
        h.set_pinned(1, true);
        assert_eq!(texts(&h), vec!["a", "c", "b"]);
    }

    #[test]
    fn eviction_drops_oldest_unpinned_only() {
        let mut h = ClipboardHistory::new(ClipboardConfig {
            max_items: 2,
            ..Default::default()
        });
        h.capture(text("a"), 1);
        h.set_pinned(1, true);
        h.capture(text("b"), 2);
        h.capture(text("c"), 3);
        h.capture(text("d"), 4);
        assert_eq!(texts(&h), vec!["a", "d", "c"]);
        assert!(h.get(2).is_none());
    }

    #[test]
    fn pinned_do_not_count_toward_cap() {
        let mut h = ClipboardHistory::new(ClipboardConfig {
            max_items: 1,
            ..Default::default()
        });
        for (i, s) in ["a", "b", "c"].iter().enumerate() {
            h.capture(text(s), i as u64);
            h.set_pinned(i as u64 + 1, true);
        }
        h.capture(text("d"), 9);
        assert_eq!(h.items().len(), 4);
    }

    #[test]
    fn unpinning_over_cap_evicts_oldest() {
        let mut h = ClipboardHistory::new(ClipboardConfig {
            max_items: 1,
            ..Default::default()
        });
        h.capture(text("a"), 1);
        h.set_pinned(1, true);
        h.capture(text("b"), 2);
        assert!(h.set_pinned(1, false));
        assert_eq!(texts(&h), vec!["b"]);
    }

    #[test]
    fn zero_max_items_is_clamped_to_one() {
        let mut h = ClipboardHistory::new(ClipboardConfig {
            max_items: 0,
            ..Default::default()
        });
        assert_eq!(h.config().max_items, 1);
        h.capture(text("a"), 1);
        h.capture(text("b"), 2);
        assert_eq!(texts(&h), vec!["b"]);
    }

    #[test]
    fn huge_max_items_is_clamped() {
        let h = ClipboardHistory::new(ClipboardConfig {
            max_items: usize::MAX,
            ..Default::default()
        });
        assert_eq!(h.config().max_items, MAX_ITEMS_CEILING);
    }

    #[test]
    fn ids_never_reused_after_remove_and_clear() {
        let mut h = hist();
        h.capture(text("a"), 1);
        h.remove(1);
        assert_eq!(h.capture(text("b"), 2), CaptureOutcome::Added(2));
        h.clear(false);
        assert_eq!(h.capture(text("c"), 3), CaptureOutcome::Added(3));
    }

    #[test]
    fn get_unknown_is_none() {
        assert!(hist().get(42).is_none());
    }

    #[test]
    fn set_pinned_unknown_returns_false() {
        let mut h = hist();
        assert!(!h.set_pinned(9, true));
    }

    #[test]
    fn remove_reports_whether_found_and_works_on_pinned() {
        let mut h = hist();
        h.capture(text("a"), 1);
        h.set_pinned(1, true);
        assert!(h.remove(1));
        assert!(!h.remove(1));
        assert!(h.items().is_empty());
    }

    #[test]
    fn clear_keep_pinned_and_clear_all() {
        let mut h = hist();
        h.capture(text("a"), 1);
        h.capture(text("b"), 2);
        h.set_pinned(1, true);
        h.clear(true);
        assert_eq!(texts(&h), vec!["a"]);
        h.clear(false);
        assert!(h.items().is_empty());
        h.clear(true);
        assert!(h.items().is_empty());
    }

    #[test]
    fn search_is_case_insensitive_substring_and_unicode_aware() {
        let mut h = hist();
        h.capture(text("Hello World"), 1);
        h.capture(text("ÉCOLE"), 2);
        h.capture(text("other"), 3);
        let r: Vec<_> = h.search("WORLD").iter().map(|i| i.id).collect();
        assert_eq!(r, vec![1]);
        let r: Vec<_> = h.search("école").iter().map(|i| i.id).collect();
        assert_eq!(r, vec![2]);
        assert!(h.search("zzz").is_empty());
    }

    #[test]
    fn search_empty_returns_all_in_display_order() {
        let mut h = hist();
        h.capture(text("a"), 1);
        h.capture(text("b"), 2);
        h.set_pinned(1, true);
        let r: Vec<_> = h.search("").iter().map(|i| i.id).collect();
        assert_eq!(r, vec![1, 2]);
    }

    #[test]
    fn set_config_reapplies_cap() {
        let mut h = hist();
        for i in 0..5 {
            h.capture(text(&format!("t{i}")), i);
        }
        h.set_config(ClipboardConfig {
            max_items: 2,
            ..Default::default()
        });
        assert_eq!(texts(&h), vec!["t4", "t3"]);
    }

    #[test]
    fn preview_collapses_whitespace() {
        assert_eq!(ClipboardHistory::preview("  a \n\t b  c ", 50), "a b c");
        assert_eq!(ClipboardHistory::preview("", 5), "");
    }

    #[test]
    fn preview_truncates_on_char_boundary_with_ellipsis() {
        assert_eq!(ClipboardHistory::preview("abcdef", 4), "abc…");
        assert_eq!(ClipboardHistory::preview("abcd", 4), "abcd");
        assert_eq!(ClipboardHistory::preview("日本語テキスト", 3), "日本…");
        assert_eq!(ClipboardHistory::preview("a😀b😀c", 3), "a😀…");
    }

    #[test]
    fn preview_zero_and_one_char_limits() {
        assert_eq!(ClipboardHistory::preview("abc", 0), "");
        assert_eq!(ClipboardHistory::preview("abc", 1), "…");
        assert_eq!(ClipboardHistory::preview("", 0), "");
    }

    #[test]
    fn persistence_roundtrips_via_json() {
        let mut h = hist();
        h.capture(text("a"), 1);
        h.capture(text("日本"), 2);
        h.set_pinned(1, true);
        let json = serde_json::to_string(&h.to_persisted()).unwrap();
        let p: PersistedClipboard = serde_json::from_str(&json).unwrap();
        let mut h2 = ClipboardHistory::from_persisted(ClipboardConfig::default(), p);
        assert_eq!(h2.items(), h.items());
        assert_eq!(h2.capture(text("new"), 3), CaptureOutcome::Added(3));
    }

    #[test]
    fn from_persisted_repairs_next_id_and_caps_items() {
        let items: Vec<ClipItem> = (1..=5)
            .rev()
            .map(|id| ClipItem {
                id,
                kind: ClipKind::Text,
                text: format!("t{id}"),
                source_app: None,
                created_ms: id,
                pinned: false,
                byte_len: 2,
                image_path: None,
                rich_path: None,
            })
            .collect();
        let p = PersistedClipboard { items, next_id: 0 };
        let mut h = ClipboardHistory::from_persisted(
            ClipboardConfig {
                max_items: 3,
                ..Default::default()
            },
            p,
        );
        assert_eq!(h.items().len(), 3);
        assert_eq!(h.capture(text("n"), 9), CaptureOutcome::Added(6));
    }

    #[test]
    fn from_persisted_empty_default_starts_at_one() {
        let mut h =
            ClipboardHistory::from_persisted(ClipboardConfig::default(), Default::default());
        assert_eq!(h.capture(text("a"), 1), CaptureOutcome::Added(1));
    }

    #[test]
    fn outcome_and_kind_serialize_snake_case() {
        assert_eq!(
            serde_json::to_string(&CaptureOutcome::Ignored(IgnoreReason::TooLarge)).unwrap(),
            r#"{"ignored":"too_large"}"#
        );
        assert_eq!(
            serde_json::to_string(&ClipKind::Files).unwrap(),
            r#""files""#
        );
    }

    #[test]
    fn files_and_image_kinds_are_stored() {
        let mut h = hist();
        let mut c = text("2 files");
        c.kind = ClipKind::Image;
        assert_eq!(h.capture(c, 1), CaptureOutcome::Added(1));
        assert_eq!(h.get(1).unwrap().kind, ClipKind::Image);
    }

    #[test]
    fn total_byte_limit_evicts_oldest_unpinned_but_keeps_the_newest() {
        let mut h = ClipboardHistory::new(ClipboardConfig {
            max_total_bytes: 10,
            ..Default::default()
        });
        h.capture(text("aaaa"), 1);
        h.capture(text("bbbb"), 2);
        h.capture(text("cccc"), 3);
        let texts: Vec<&str> = h.items().iter().map(|i| i.text.as_str()).collect();
        assert_eq!(texts, ["cccc", "bbbb"]);
        // One item larger than the whole budget still replaces everything else.
        h.capture(text("dddddddddddddddd"), 4);
        let texts: Vec<&str> = h.items().iter().map(|i| i.text.as_str()).collect();
        assert_eq!(texts, ["dddddddddddddddd"]);
    }

    #[test]
    fn pinned_items_do_not_count_toward_the_byte_limit() {
        let mut h = ClipboardHistory::new(ClipboardConfig {
            max_total_bytes: 8,
            ..Default::default()
        });
        let CaptureOutcome::Added(a) = h.capture(text("aaaa"), 1) else {
            panic!()
        };
        assert!(h.set_pinned(a, true));
        h.capture(text("bbbb"), 2);
        h.capture(text("cccc"), 3);
        assert_eq!(h.items().len(), 3);
    }

    #[test]
    fn pinning_stops_at_the_cap() {
        let mut h = ClipboardHistory::new(ClipboardConfig::default());
        let mut ids = Vec::new();
        for n in 0..=MAX_PINNED {
            let CaptureOutcome::Added(id) = h.capture(text(&format!("item {n}")), n as u64) else {
                panic!()
            };
            ids.push(id);
        }
        for id in &ids[..MAX_PINNED] {
            assert!(h.set_pinned(*id, true));
        }
        assert!(
            !h.set_pinned(ids[MAX_PINNED], true),
            "one over the cap is refused"
        );
        assert!(
            h.set_pinned(ids[0], true),
            "re-pinning a pinned item is fine"
        );
        assert!(h.set_pinned(ids[0], false));
        assert!(
            h.set_pinned(ids[MAX_PINNED], true),
            "room again after unpinning"
        );
    }

    #[test]
    fn formatting_follows_the_latest_copy_and_files_are_listed() {
        let mut h = ClipboardHistory::new(ClipboardConfig::default());
        let rich = |path: Option<&str>| ClipCapture {
            rich_path: path.map(str::to_owned),
            ..text("hello")
        };
        h.capture(rich(Some("/c/rich-1.rtf")), 1);
        assert_eq!(h.file_paths(), ["/c/rich-1.rtf"]);
        h.capture(rich(None), 2);
        assert_eq!(h.items().len(), 1);
        assert!(h.file_paths().is_empty());
        h.capture(rich(Some("/c/rich-2.html")), 3);
        h.capture(
            ClipCapture {
                kind: ClipKind::Image,
                image_path: Some("/c/img-1.png".into()),
                ..text("PNG image")
            },
            4,
        );
        assert_eq!(h.file_paths(), ["/c/img-1.png", "/c/rich-2.html"]);
    }
}
