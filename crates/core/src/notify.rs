//! Notification center: one banner at a time, a priority queue behind it,
//! focus-time DND, and a capped history. Pure logic; time is passed in.

use serde::{Deserialize, Serialize};
use std::cmp::Reverse;

/// Importance of a notification; ordered `Low < Normal < High < Critical`.
#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default, Serialize, Deserialize,
)]
#[serde(rename_all = "snake_case")]
pub enum Priority {
    Low,
    #[default]
    Normal,
    High,
    Critical,
}

/// What a caller posts.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct NotificationInput {
    pub source: String,
    pub title: String,
    pub body: String,
    pub priority: Priority,
    /// With `Some`, a later post from the same `source` replaces this one.
    pub group: Option<String>,
    /// Banner lifetime override; `Some(0)` expires on the next tick.
    pub ttl_secs: Option<u32>,
}

impl Default for NotificationInput {
    fn default() -> Self {
        Self {
            source: String::new(),
            title: String::new(),
            body: String::new(),
            priority: Priority::Normal,
            group: None,
            ttl_secs: None,
        }
    }
}

impl NotificationInput {
    /// Normal-priority input with no group or ttl.
    pub fn new(source: &str, title: &str, body: &str) -> Self {
        Self {
            source: source.to_string(),
            title: title.to_string(),
            body: body.to_string(),
            ..Self::default()
        }
    }
}

/// A stored notification.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Notification {
    pub id: u64,
    pub source: String,
    pub title: String,
    pub body: String,
    pub priority: Priority,
    pub group: Option<String>,
    pub ttl_secs: Option<u32>,
    pub created_ms: u64,
    pub read: bool,
    /// What clicking it opens; filled in by the core's view.
    #[serde(default)]
    pub open: Option<OpenTarget>,
}

/// Where a click on a notification or session takes the user.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum OpenTarget {
    /// Bring an app forward by bundle id (a session's terminal).
    App { bundle_id: String },
    /// Bring an app forward by its name (another app's notification).
    AppNamed { name: String },
    /// Open a tab in the notch; `pane` picks a sub-view where there is one.
    Tab { tab: String, pane: Option<String> },
}

/// Notification center settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct NotifyConfig {
    pub enabled: bool,
    pub banner_secs: u32,
    /// Clamped to at least 1.
    pub max_history: usize,
    /// Advisory: the runtime calls `set_dnd` when focus starts/stops.
    pub dnd_during_focus: bool,
    /// While DND is on, items below this priority are held silently.
    pub dnd_min_priority: Priority,
    /// Also show banners posted by other apps. Off by default: the shell
    /// needs the Accessibility permission to read them.
    pub system: bool,
}

impl Default for NotifyConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            banner_secs: 5,
            max_history: 50,
            dnd_during_focus: true,
            dnd_min_priority: Priority::High,
            system: false,
        }
    }
}

/// State changes the shell should react to.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotifyEvent {
    BannerShown { id: u64 },
    BannerHidden { id: u64 },
    HeldDelivered { count: usize },
}

/// The notification state machine.
#[derive(Debug, Clone)]
pub struct NotificationCenter {
    cfg: NotifyConfig,
    next_id: u64,
    /// Every known item, newest first; banner and queue refer to it by id.
    history: Vec<Notification>,
    banner: Option<u64>,
    /// `None` while a banner is showing means it stays until dismissed.
    banner_deadline: Option<u64>,
    queue: Vec<u64>,
    held: Vec<u64>,
    dnd: bool,
}

impl NotificationCenter {
    /// Creates an empty center (config is sanitised).
    pub fn new(cfg: NotifyConfig) -> Self {
        Self {
            cfg: sanitize(cfg),
            next_id: 1,
            history: Vec::new(),
            banner: None,
            banner_deadline: None,
            queue: Vec::new(),
            held: Vec::new(),
            dnd: false,
        }
    }

    /// Replaces the config; history is re-capped without touching live items.
    pub fn set_config(&mut self, cfg: NotifyConfig) {
        self.cfg = sanitize(cfg);
        self.trim();
    }

    /// Posts a notification; returns its id (0 when disabled) and events.
    pub fn post(&mut self, input: NotificationInput, now: u64) -> (u64, Vec<NotifyEvent>) {
        let mut events = Vec::new();
        if !self.cfg.enabled {
            return (0, events);
        }
        let existing = input.group.as_ref().and_then(|g| {
            self.history
                .iter()
                .position(|n| n.source == input.source && n.group.as_ref() == Some(g))
        });
        let id = match existing {
            Some(i) => self.history[i].id,
            None => {
                let id = self.next_id;
                self.next_id = self.next_id.saturating_add(1);
                id
            }
        };
        let item = Notification {
            id,
            source: input.source,
            title: input.title,
            body: input.body,
            priority: input.priority,
            group: input.group,
            ttl_secs: input.ttl_secs,
            created_ms: now,
            read: false,
            open: None,
        };
        let priority = item.priority;
        match existing {
            Some(i) => self.history[i] = item,
            None => self.history.insert(0, item),
        }

        let was_banner = self.banner == Some(id);
        self.queue.retain(|q| *q != id);
        self.held.retain(|h| *h != id);
        if was_banner {
            self.banner = None;
            self.banner_deadline = None;
        }

        self.arrive(id, priority, now, &mut events);
        if was_banner && !events.contains(&NotifyEvent::BannerShown { id }) {
            events.insert(0, NotifyEvent::BannerHidden { id });
        }
        self.trim();
        (id, events)
    }

    /// Turns DND on or off; turning it off reports held items once.
    pub fn set_dnd(&mut self, on: bool, _now: u64) -> Vec<NotifyEvent> {
        let was = self.dnd;
        self.dnd = on;
        if on {
            // Items already waiting are silenced too; the banner on screen stays.
            let min = self.cfg.dnd_min_priority;
            let (keep, hold): (Vec<u64>, Vec<u64>) = std::mem::take(&mut self.queue)
                .into_iter()
                .partition(|id| self.find(*id).is_some_and(|n| n.priority >= min));
            self.queue = keep;
            self.held.extend(hold);
            return Vec::new();
        }
        if !was {
            return Vec::new();
        }
        let held = std::mem::take(&mut self.held);
        let count = held
            .iter()
            .filter(|id| self.history.iter().any(|n| n.id == **id && !n.read))
            .count();
        if count == 0 {
            Vec::new()
        } else {
            vec![NotifyEvent::HeldDelivered { count }]
        }
    }

    /// Expires the banner when due and promotes the next waiting item.
    pub fn tick(&mut self, now: u64) -> Vec<NotifyEvent> {
        let mut events = Vec::new();
        while matches!(self.banner_deadline, Some(d) if now >= d) {
            self.hide_banner(now, &mut events);
        }
        self.trim();
        events
    }

    /// The banner currently shown, if any.
    pub fn current_banner(&self) -> Option<&Notification> {
        self.banner.and_then(|id| self.find(id))
    }

    /// Number of items waiting behind the banner.
    pub fn queue_len(&self) -> usize {
        self.queue.len()
    }

    /// Dismisses the showing banner (marks it read) and shows the next.
    pub fn dismiss_banner(&mut self, now: u64) -> Vec<NotifyEvent> {
        match self.banner {
            Some(id) => self.dismiss(id, now),
            None => Vec::new(),
        }
    }

    /// Marks one item read and removes it from banner/queue; unknown ids are ignored.
    pub fn dismiss(&mut self, id: u64, now: u64) -> Vec<NotifyEvent> {
        let mut events = Vec::new();
        if let Some(n) = self.history.iter_mut().find(|n| n.id == id) {
            n.read = true;
        }
        self.queue.retain(|q| *q != id);
        if self.banner == Some(id) {
            self.hide_banner(now, &mut events);
        }
        self.trim();
        events
    }

    /// Marks every item read; the banner is left showing.
    pub fn mark_all_read(&mut self) {
        for n in &mut self.history {
            n.read = true;
        }
    }

    /// Drops history that is not live; the banner and queued items remain.
    pub fn clear_history(&mut self) {
        let (banner, queue) = (self.banner, &self.queue);
        self.history
            .retain(|n| Some(n.id) == banner || queue.contains(&n.id));
        self.held.clear();
    }

    /// History, newest first.
    pub fn history(&self) -> &[Notification] {
        &self.history
    }

    /// Count of unread items in history.
    pub fn unread_count(&self) -> usize {
        self.history.iter().filter(|n| !n.read).count()
    }

    /// When the banner should next be hidden; `None` if sticky or idle.
    pub fn next_deadline(&self) -> Option<u64> {
        self.banner.and(self.banner_deadline)
    }

    fn find(&self, id: u64) -> Option<&Notification> {
        self.history.iter().find(|n| n.id == id)
    }

    fn arrive(&mut self, id: u64, priority: Priority, now: u64, events: &mut Vec<NotifyEvent>) {
        if self.dnd && priority < self.cfg.dnd_min_priority {
            self.held.push(id);
            // The post may have replaced the showing banner; let the next
            // waiting item take its place.
            self.fill_banner(now, events);
            return;
        }
        match self.current_banner().map(|b| b.priority) {
            Some(current) if priority > current => {
                if let Some(old) = self.banner.take() {
                    self.banner_deadline = None;
                    events.push(NotifyEvent::BannerHidden { id: old });
                    self.queue.push(old);
                }
                self.queue.push(id);
                self.sort_queue();
                self.fill_banner(now, events);
            }
            _ => {
                self.queue.push(id);
                self.sort_queue();
                self.fill_banner(now, events);
            }
        }
    }

    fn sort_queue(&mut self) {
        let mut q = std::mem::take(&mut self.queue);
        q.sort_by_key(|id| {
            let n = self.find(*id);
            (
                Reverse(n.map(|n| n.priority)),
                n.map_or(u64::MAX, |n| n.created_ms),
                *id,
            )
        });
        self.queue = q;
    }

    fn hide_banner(&mut self, now: u64, events: &mut Vec<NotifyEvent>) {
        if let Some(id) = self.banner.take() {
            self.banner_deadline = None;
            events.push(NotifyEvent::BannerHidden { id });
        }
        self.fill_banner(now, events);
    }

    fn fill_banner(&mut self, now: u64, events: &mut Vec<NotifyEvent>) {
        if self.banner.is_some() {
            return;
        }
        while !self.queue.is_empty() {
            let id = self.queue.remove(0);
            let Some(n) = self.find(id) else { continue };
            let secs = n.ttl_secs.or(if n.priority == Priority::Critical {
                None
            } else {
                Some(self.cfg.banner_secs)
            });
            self.banner_deadline = secs.map(|s| now.saturating_add(u64::from(s) * 1000));
            self.banner = Some(id);
            events.push(NotifyEvent::BannerShown { id });
            return;
        }
    }

    /// Drops the oldest items that are not live until history fits the cap.
    fn trim(&mut self) {
        let mut i = self.history.len();
        while self.history.len() > self.cfg.max_history && i > 0 {
            i -= 1;
            let id = self.history[i].id;
            if self.banner != Some(id) && !self.queue.contains(&id) {
                self.history.remove(i);
            }
        }
    }
}

fn sanitize(mut cfg: NotifyConfig) -> NotifyConfig {
    cfg.max_history = cfg.max_history.max(1);
    // A zero-second banner would vanish in the tick that shows it.
    cfg.banner_secs = cfg.banner_secs.max(1);
    cfg
}

#[cfg(test)]
mod tests {
    use super::*;

    fn center() -> NotificationCenter {
        NotificationCenter::new(NotifyConfig::default())
    }

    fn inp(title: &str, p: Priority) -> NotificationInput {
        NotificationInput {
            source: "app".into(),
            title: title.into(),
            priority: p,
            ..NotificationInput::default()
        }
    }

    fn grouped(source: &str, group: &str, title: &str, p: Priority) -> NotificationInput {
        NotificationInput {
            source: source.into(),
            group: Some(group.into()),
            title: title.into(),
            priority: p,
            ..NotificationInput::default()
        }
    }

    #[test]
    fn priority_is_ordered_and_defaults_to_normal() {
        assert!(Priority::Low < Priority::Normal);
        assert!(Priority::Normal < Priority::High);
        assert!(Priority::High < Priority::Critical);
        assert_eq!(Priority::default(), Priority::Normal);
    }

    #[test]
    fn config_defaults_match_contract() {
        let c = NotifyConfig::default();
        assert!(c.enabled && c.dnd_during_focus);
        assert_eq!(c.banner_secs, 5);
        assert_eq!(c.max_history, 50);
        assert_eq!(c.dnd_min_priority, Priority::High);
    }

    #[test]
    fn input_new_uses_normal_priority() {
        let i = NotificationInput::new("s", "t", "b");
        assert_eq!(
            (i.source.as_str(), i.title.as_str(), i.body.as_str()),
            ("s", "t", "b")
        );
        assert_eq!(i.priority, Priority::Normal);
        assert!(i.group.is_none() && i.ttl_secs.is_none());
    }

    #[test]
    fn config_deserializes_partial_json_with_defaults() {
        let c: NotifyConfig =
            serde_json::from_str(r#"{"banner_secs":9,"dnd_min_priority":"critical"}"#).unwrap();
        assert_eq!(c.banner_secs, 9);
        assert_eq!(c.dnd_min_priority, Priority::Critical);
        assert_eq!(c.max_history, 50);
        let i: NotificationInput = serde_json::from_str(r#"{"title":"x"}"#).unwrap();
        assert_eq!(i.priority, Priority::Normal);
    }

    #[test]
    fn events_serialize_snake_case() {
        let s = serde_json::to_string(&NotifyEvent::BannerShown { id: 3 }).unwrap();
        assert_eq!(s, r#"{"banner_shown":{"id":3}}"#);
        let s = serde_json::to_string(&NotifyEvent::HeldDelivered { count: 2 }).unwrap();
        assert_eq!(s, r#"{"held_delivered":{"count":2}}"#);
    }

    #[test]
    fn first_post_shows_banner_and_returns_id_one() {
        let mut c = center();
        let (id, ev) = c.post(inp("hi", Priority::Normal), 1000);
        assert_eq!(id, 1);
        assert_eq!(ev, vec![NotifyEvent::BannerShown { id: 1 }]);
        assert_eq!(c.current_banner().unwrap().title, "hi");
        assert_eq!(c.next_deadline(), Some(6000));
        assert_eq!(c.unread_count(), 1);
    }

    #[test]
    fn ids_are_monotonic() {
        let mut c = center();
        let a = c.post(inp("a", Priority::Normal), 0).0;
        let b = c.post(inp("b", Priority::Normal), 0).0;
        assert!(b > a);
    }

    #[test]
    fn disabled_center_drops_posts() {
        let mut c = NotificationCenter::new(NotifyConfig {
            enabled: false,
            ..NotifyConfig::default()
        });
        let (id, ev) = c.post(inp("x", Priority::Critical), 0);
        assert_eq!(id, 0);
        assert!(ev.is_empty());
        assert!(c.history().is_empty() && c.current_banner().is_none());
    }

    #[test]
    fn equal_priority_waits_behind_banner() {
        let mut c = center();
        c.post(inp("a", Priority::Normal), 0);
        let (_, ev) = c.post(inp("b", Priority::Normal), 10);
        assert!(ev.is_empty());
        assert_eq!(c.current_banner().unwrap().title, "a");
        assert_eq!(c.queue_len(), 1);
    }

    #[test]
    fn lower_priority_waits_behind_banner() {
        let mut c = center();
        c.post(inp("a", Priority::High), 0);
        c.post(inp("b", Priority::Low), 10);
        assert_eq!(c.current_banner().unwrap().title, "a");
        assert_eq!(c.queue_len(), 1);
    }

    #[test]
    fn strictly_higher_priority_preempts_and_requeues() {
        let mut c = center();
        let (a, _) = c.post(inp("a", Priority::Normal), 0);
        let (b, ev) = c.post(inp("b", Priority::High), 100);
        assert_eq!(
            ev,
            vec![
                NotifyEvent::BannerHidden { id: a },
                NotifyEvent::BannerShown { id: b }
            ]
        );
        assert_eq!(c.current_banner().unwrap().id, b);
        assert_eq!(c.queue_len(), 1);
        // The preempted item returns after the banner expires.
        let ev = c.tick(5100);
        assert_eq!(
            ev,
            vec![
                NotifyEvent::BannerHidden { id: b },
                NotifyEvent::BannerShown { id: a }
            ]
        );
    }

    #[test]
    fn waiting_items_ordered_by_priority_then_age() {
        let mut c = center();
        c.post(inp("shown", Priority::Critical), 0);
        let (l, _) = c.post(inp("low", Priority::Low), 1);
        let (n1, _) = c.post(inp("n1", Priority::Normal), 2);
        let (n2, _) = c.post(inp("n2", Priority::Normal), 3);
        let (h, _) = c.post(inp("high", Priority::High), 4);
        let mut order = Vec::new();
        for _ in 0..4 {
            let ev = c.dismiss_banner(10);
            if let Some(NotifyEvent::BannerShown { id }) = ev.last() {
                order.push(*id);
            }
        }
        assert_eq!(order, vec![h, n1, n2, l]);
    }

    #[test]
    fn same_age_ties_break_by_id() {
        let mut c = center();
        c.post(inp("shown", Priority::Critical), 0);
        let (a, _) = c.post(inp("a", Priority::Normal), 5);
        let (b, _) = c.post(inp("b", Priority::Normal), 5);
        let ev = c.dismiss_banner(6);
        assert_eq!(ev.last(), Some(&NotifyEvent::BannerShown { id: a }));
        assert_eq!(c.queue_len(), 1);
        assert_eq!(c.queue[0], b);
    }

    #[test]
    fn banner_expires_after_banner_secs_and_stays_unread() {
        let mut c = center();
        let (id, _) = c.post(inp("a", Priority::Normal), 0);
        assert!(c.tick(4999).is_empty());
        let ev = c.tick(5000);
        assert_eq!(ev, vec![NotifyEvent::BannerHidden { id }]);
        assert!(c.current_banner().is_none());
        assert_eq!(c.next_deadline(), None);
        assert_eq!(c.unread_count(), 1);
    }

    #[test]
    fn tick_is_idempotent_for_same_now() {
        let mut c = center();
        c.post(inp("a", Priority::Normal), 0);
        c.post(inp("b", Priority::Normal), 0);
        let first = c.tick(5000);
        assert_eq!(first.len(), 2);
        assert!(c.tick(5000).is_empty());
    }

    #[test]
    fn expiry_promotes_next_with_fresh_deadline() {
        let mut c = center();
        c.post(inp("a", Priority::Normal), 0);
        let (b, _) = c.post(inp("b", Priority::Normal), 0);
        c.tick(7000);
        assert_eq!(c.current_banner().unwrap().id, b);
        assert_eq!(c.next_deadline(), Some(12000));
    }

    #[test]
    fn ttl_overrides_banner_secs() {
        let mut c = center();
        let mut i = inp("a", Priority::Normal);
        i.ttl_secs = Some(2);
        c.post(i, 1000);
        assert_eq!(c.next_deadline(), Some(3000));
    }

    #[test]
    fn zero_ttl_expires_on_next_tick_and_chain_flushes_once() {
        let mut c = center();
        let mut a = inp("a", Priority::Normal);
        a.ttl_secs = Some(0);
        let mut b = inp("b", Priority::Normal);
        b.ttl_secs = Some(0);
        c.post(a, 100);
        c.post(b, 100);
        let ev = c.tick(100);
        assert_eq!(ev.len(), 3);
        assert!(c.current_banner().is_none());
        assert!(c.tick(100).is_empty());
    }

    #[test]
    fn critical_without_ttl_is_sticky() {
        let mut c = center();
        c.post(inp("a", Priority::Critical), 0);
        assert_eq!(c.next_deadline(), None);
        assert!(c.tick(u64::MAX).is_empty());
        assert!(c.current_banner().is_some());
    }

    #[test]
    fn critical_with_ttl_expires() {
        let mut c = center();
        let mut i = inp("a", Priority::Critical);
        i.ttl_secs = Some(3);
        c.post(i, 0);
        assert_eq!(c.next_deadline(), Some(3000));
        assert_eq!(c.tick(3000).len(), 1);
    }

    #[test]
    fn huge_now_saturates_deadline() {
        let mut c = center();
        c.post(inp("a", Priority::Normal), u64::MAX - 1);
        assert_eq!(c.next_deadline(), Some(u64::MAX));
    }

    #[test]
    fn clock_going_backwards_keeps_banner() {
        let mut c = center();
        c.post(inp("a", Priority::Normal), 10_000);
        assert!(c.tick(0).is_empty());
        assert!(c.current_banner().is_some());
        assert_eq!(c.tick(15_000).len(), 1);
    }

    #[test]
    fn zero_banner_secs_is_treated_as_one_second() {
        let mut c = NotificationCenter::new(NotifyConfig {
            banner_secs: 0,
            ..NotifyConfig::default()
        });
        c.post(inp("a", Priority::Normal), 50);
        assert_eq!(c.next_deadline(), Some(1050));
        assert_eq!(c.tick(1050).len(), 1);
    }

    #[test]
    fn dismiss_banner_marks_read_and_shows_next() {
        let mut c = center();
        let (a, _) = c.post(inp("a", Priority::Normal), 0);
        let (b, _) = c.post(inp("b", Priority::Normal), 0);
        let ev = c.dismiss_banner(10);
        assert_eq!(
            ev,
            vec![
                NotifyEvent::BannerHidden { id: a },
                NotifyEvent::BannerShown { id: b }
            ]
        );
        assert_eq!(c.unread_count(), 1);
        assert_eq!(c.next_deadline(), Some(5010));
    }

    #[test]
    fn dismiss_banner_without_banner_is_noop() {
        let mut c = center();
        assert!(c.dismiss_banner(0).is_empty());
    }

    #[test]
    fn dismiss_queued_item_removes_it_without_events() {
        let mut c = center();
        c.post(inp("a", Priority::Normal), 0);
        let (b, _) = c.post(inp("b", Priority::Normal), 0);
        assert!(c.dismiss(b, 1).is_empty());
        assert_eq!(c.queue_len(), 0);
        assert_eq!(c.unread_count(), 1);
    }

    #[test]
    fn dismiss_unknown_id_is_noop() {
        let mut c = center();
        c.post(inp("a", Priority::Normal), 0);
        assert!(c.dismiss(999, 0).is_empty());
        assert_eq!(c.unread_count(), 1);
    }

    #[test]
    fn dismiss_banner_by_id() {
        let mut c = center();
        let (a, _) = c.post(inp("a", Priority::Normal), 0);
        let ev = c.dismiss(a, 0);
        assert_eq!(ev, vec![NotifyEvent::BannerHidden { id: a }]);
        assert!(c.current_banner().is_none());
    }

    #[test]
    fn group_replaces_item_in_history() {
        let mut c = center();
        let (a, _) = c.post(grouped("ci", "build", "running", Priority::Normal), 0);
        c.tick(6000);
        let (b, _) = c.post(grouped("ci", "build", "passed", Priority::Normal), 7000);
        assert_eq!(a, b);
        assert_eq!(c.history().len(), 1);
        assert_eq!(c.history()[0].title, "passed");
        assert_eq!(c.history()[0].created_ms, 7000);
    }

    #[test]
    fn group_replacing_read_item_makes_it_unread() {
        let mut c = center();
        let (a, _) = c.post(grouped("ci", "g", "1", Priority::Normal), 0);
        c.dismiss(a, 0);
        assert_eq!(c.unread_count(), 0);
        c.post(grouped("ci", "g", "2", Priority::Normal), 1);
        assert_eq!(c.unread_count(), 1);
    }

    #[test]
    fn group_replaces_showing_banner_and_reshows_it() {
        let mut c = center();
        let (a, _) = c.post(grouped("ci", "g", "1", Priority::Normal), 0);
        let (b, ev) = c.post(grouped("ci", "g", "2", Priority::Normal), 3000);
        assert_eq!(a, b);
        assert_eq!(ev, vec![NotifyEvent::BannerShown { id: a }]);
        assert_eq!(c.current_banner().unwrap().title, "2");
        assert_eq!(c.next_deadline(), Some(8000));
        assert_eq!(c.history().len(), 1);
    }

    #[test]
    fn group_replacing_banner_yields_to_queue_head_when_lower() {
        let mut c = center();
        c.post(grouped("ci", "g", "1", Priority::High), 0);
        let (w, _) = c.post(inp("waiting", Priority::Normal), 1);
        let (a, ev) = c.post(grouped("ci", "g", "2", Priority::Low), 2);
        assert_eq!(
            ev,
            vec![
                NotifyEvent::BannerHidden { id: a },
                NotifyEvent::BannerShown { id: w }
            ]
        );
        assert_eq!(c.queue_len(), 1);
    }

    #[test]
    fn group_replaces_queued_item_in_queue() {
        let mut c = center();
        c.post(inp("shown", Priority::High), 0);
        let (a, _) = c.post(grouped("ci", "g", "1", Priority::Low), 1);
        let (b, ev) = c.post(grouped("ci", "g", "2", Priority::Normal), 2);
        assert_eq!(a, b);
        assert!(ev.is_empty());
        assert_eq!(c.queue_len(), 1);
        assert_eq!(c.history().len(), 2);
    }

    #[test]
    fn replacement_can_preempt_with_higher_priority() {
        let mut c = center();
        c.post(inp("shown", Priority::Normal), 0);
        let (a, _) = c.post(grouped("ci", "g", "1", Priority::Low), 1);
        let (_, ev) = c.post(grouped("ci", "g", "2", Priority::Critical), 2);
        assert!(ev.contains(&NotifyEvent::BannerShown { id: a }));
        assert_eq!(c.current_banner().unwrap().id, a);
    }

    #[test]
    fn same_group_different_source_does_not_replace() {
        let mut c = center();
        c.post(grouped("a", "g", "1", Priority::Normal), 0);
        c.post(grouped("b", "g", "2", Priority::Normal), 0);
        assert_eq!(c.history().len(), 2);
    }

    #[test]
    fn no_group_never_replaces() {
        let mut c = center();
        c.post(inp("a", Priority::Normal), 0);
        c.post(inp("a", Priority::Normal), 0);
        assert_eq!(c.history().len(), 2);
    }

    #[test]
    fn dnd_holds_low_priority_without_banner() {
        let mut c = center();
        c.set_dnd(true, 0);
        let (id, ev) = c.post(inp("a", Priority::Normal), 0);
        assert!(id > 0);
        assert!(ev.is_empty());
        assert!(c.current_banner().is_none());
        assert_eq!(c.unread_count(), 1);
        assert_eq!(c.history().len(), 1);
    }

    #[test]
    fn dnd_lets_min_priority_through() {
        let mut c = center();
        c.set_dnd(true, 0);
        let (_, ev) = c.post(inp("a", Priority::High), 0);
        assert_eq!(ev.len(), 1);
        assert!(c.current_banner().is_some());
    }

    #[test]
    fn dnd_off_reports_held_count_once() {
        let mut c = center();
        c.set_dnd(true, 0);
        c.post(inp("a", Priority::Low), 0);
        c.post(inp("b", Priority::Normal), 0);
        assert_eq!(
            c.set_dnd(false, 1),
            vec![NotifyEvent::HeldDelivered { count: 2 }]
        );
        assert!(c.set_dnd(false, 2).is_empty());
        c.set_dnd(true, 3);
        assert!(c.set_dnd(false, 4).is_empty());
    }

    #[test]
    fn dnd_toggle_without_held_is_silent() {
        let mut c = center();
        assert!(c.set_dnd(true, 0).is_empty());
        assert!(c.set_dnd(true, 0).is_empty());
        assert!(c.set_dnd(false, 0).is_empty());
    }

    #[test]
    fn held_items_read_before_dnd_off_are_not_counted() {
        let mut c = center();
        c.set_dnd(true, 0);
        let (a, _) = c.post(inp("a", Priority::Low), 0);
        c.post(inp("b", Priority::Low), 0);
        c.dismiss(a, 0);
        assert_eq!(
            c.set_dnd(false, 1),
            vec![NotifyEvent::HeldDelivered { count: 1 }]
        );
        c.set_dnd(true, 2);
        c.post(inp("c", Priority::Low), 2);
        c.mark_all_read();
        assert!(c.set_dnd(false, 3).is_empty());
    }

    #[test]
    fn held_item_replaced_by_important_one_is_not_counted() {
        let mut c = center();
        c.set_dnd(true, 0);
        c.post(grouped("s", "g", "1", Priority::Low), 0);
        let (_, ev) = c.post(grouped("s", "g", "2", Priority::Critical), 1);
        assert_eq!(ev.len(), 1);
        assert!(c.set_dnd(false, 2).is_empty());
    }

    #[test]
    fn dnd_does_not_hide_existing_banner() {
        let mut c = center();
        c.post(inp("a", Priority::Low), 0);
        c.set_dnd(true, 1);
        assert!(c.current_banner().is_some());
    }

    #[test]
    fn dnd_min_priority_is_configurable() {
        let mut c = NotificationCenter::new(NotifyConfig {
            dnd_min_priority: Priority::Critical,
            ..NotifyConfig::default()
        });
        c.set_dnd(true, 0);
        c.post(inp("a", Priority::High), 0);
        assert!(c.current_banner().is_none());
        c.post(inp("b", Priority::Critical), 0);
        assert!(c.current_banner().is_some());
    }

    #[test]
    fn history_is_newest_first_and_capped() {
        let mut c = NotificationCenter::new(NotifyConfig {
            max_history: 3,
            ..NotifyConfig::default()
        });
        for i in 0..6 {
            c.post(inp(&format!("t{i}"), Priority::Normal), i);
        }
        let titles: Vec<_> = c.history().iter().map(|n| n.title.as_str()).collect();
        // Live items (banner t0, queued) are kept even beyond the cap.
        assert_eq!(titles.first(), Some(&"t5"));
        assert!(titles.len() >= 3);
    }

    #[test]
    fn history_cap_drops_oldest_once_items_are_not_live() {
        let mut c = NotificationCenter::new(NotifyConfig {
            max_history: 2,
            ..NotifyConfig::default()
        });
        c.post(inp("t0", Priority::Normal), 0);
        c.tick(5000);
        c.post(inp("t1", Priority::Normal), 6000);
        c.tick(11000);
        c.post(inp("t2", Priority::Normal), 12000);
        let titles: Vec<_> = c.history().iter().map(|n| n.title.as_str()).collect();
        assert_eq!(titles, vec!["t2", "t1"]);
    }

    #[test]
    fn expired_overflow_is_trimmed_on_tick() {
        let mut c = NotificationCenter::new(NotifyConfig {
            max_history: 1,
            ..NotifyConfig::default()
        });
        c.post(inp("a", Priority::Normal), 0);
        c.post(inp("b", Priority::Normal), 0);
        assert_eq!(c.history().len(), 2);
        c.tick(5000);
        c.tick(10000);
        assert_eq!(c.history().len(), 1);
        assert_eq!(c.history()[0].title, "b");
    }

    #[test]
    fn zero_max_history_clamps_to_one() {
        let mut c = NotificationCenter::new(NotifyConfig {
            max_history: 0,
            ..NotifyConfig::default()
        });
        c.post(inp("a", Priority::Normal), 0);
        assert_eq!(c.history().len(), 1);
    }

    #[test]
    fn set_config_recaps_history() {
        let mut c = center();
        for i in 0..5 {
            c.post(inp("x", Priority::Normal), i);
            c.dismiss_banner(i);
        }
        assert_eq!(c.history().len(), 5);
        c.set_config(NotifyConfig {
            max_history: 2,
            ..NotifyConfig::default()
        });
        assert_eq!(c.history().len(), 2);
        c.set_config(NotifyConfig {
            max_history: 0,
            ..NotifyConfig::default()
        });
        assert_eq!(c.history().len(), 1);
    }

    #[test]
    fn set_config_changes_banner_duration_for_later_posts() {
        let mut c = center();
        c.set_config(NotifyConfig {
            banner_secs: 1,
            ..NotifyConfig::default()
        });
        c.post(inp("a", Priority::Normal), 0);
        assert_eq!(c.next_deadline(), Some(1000));
    }

    #[test]
    fn mark_all_read_clears_unread_but_keeps_banner() {
        let mut c = center();
        c.post(inp("a", Priority::Normal), 0);
        c.post(inp("b", Priority::Normal), 0);
        c.mark_all_read();
        assert_eq!(c.unread_count(), 0);
        assert!(c.current_banner().unwrap().read);
        assert_eq!(c.queue_len(), 1);
    }

    #[test]
    fn clear_history_keeps_live_items_only() {
        let mut c = center();
        c.post(inp("a", Priority::Normal), 0);
        c.post(inp("b", Priority::Normal), 0);
        c.tick(5000);
        c.post(inp("c", Priority::Normal), 5001);
        c.set_dnd(true, 5002);
        c.post(inp("d", Priority::Low), 5003);
        c.clear_history();
        let titles: Vec<_> = c.history().iter().map(|n| n.title.as_str()).collect();
        // "c" was waiting when DND came on, so it is held, not live.
        assert_eq!(titles, vec!["b"]);
        assert!(c.set_dnd(false, 5004).is_empty());
        c.tick(100_000);
        c.tick(200_000);
        c.clear_history();
        assert!(c.history().is_empty());
    }

    #[test]
    fn unicode_text_is_stored_verbatim() {
        let mut c = center();
        c.post(NotificationInput::new("แอป", "สวัสดี 🎉", "日本語"), 0);
        let b = c.current_banner().unwrap();
        assert_eq!(
            (b.source.as_str(), b.title.as_str(), b.body.as_str()),
            ("แอป", "สวัสดี 🎉", "日本語")
        );
    }

    #[test]
    fn next_deadline_none_when_idle() {
        assert_eq!(center().next_deadline(), None);
    }

    #[test]
    fn repeated_posts_produce_distinct_ids_and_history() {
        let mut c = center();
        for _ in 0..10 {
            c.post(inp("same", Priority::Normal), 5);
        }
        assert_eq!(c.history().len(), 10);
        assert_eq!(c.queue_len(), 9);
    }

    #[test]
    fn id_counter_saturates() {
        let mut c = center();
        c.next_id = u64::MAX;
        let (a, _) = c.post(inp("a", Priority::Normal), 0);
        let (b, _) = c.post(inp("b", Priority::Normal), 0);
        assert_eq!(a, u64::MAX);
        assert_eq!(b, u64::MAX);
    }

    #[test]
    fn orphan_queue_ids_are_skipped() {
        let mut c = center();
        c.queue.push(777);
        let (id, _) = c.post(inp("a", Priority::Normal), 0);
        assert_eq!(c.current_banner().unwrap().id, id);
    }

    #[test]
    fn replacing_the_showing_banner_with_a_held_post_promotes_the_next_in_queue() {
        let mut c = NotificationCenter::new(NotifyConfig::default());
        c.set_dnd(true, 0);
        let grouped = |priority| NotificationInput {
            group: Some("g".into()),
            priority,
            ..NotificationInput::new("src", "grouped", "")
        };
        let (first, _) = c.post(grouped(Priority::High), 0);
        let (second, _) = c.post(
            NotificationInput {
                priority: Priority::High,
                ..NotificationInput::new("src", "other", "")
            },
            1,
        );
        assert_eq!(c.current_banner().map(|b| b.id), Some(first));
        // The same group arrives again below the DND threshold: it is held,
        // and the queued item must take over the banner.
        let (_, events) = c.post(grouped(Priority::Normal), 2);
        assert_eq!(c.current_banner().map(|b| b.id), Some(second));
        assert!(events.contains(&NotifyEvent::BannerShown { id: second }));
        assert_eq!(c.queue_len(), 0);
        assert!(c.next_deadline().is_some());
    }

    #[test]
    fn turning_dnd_on_silences_items_already_waiting() {
        let mut c = NotificationCenter::new(NotifyConfig::default());
        c.post(NotificationInput::new("s", "showing", ""), 0);
        c.post(NotificationInput::new("s", "queued normal", ""), 1);
        let (high, _) = c.post(
            NotificationInput {
                priority: Priority::High,
                ..NotificationInput::new("s", "queued high", "")
            },
            2,
        );
        // The high one preempted; two normal ones wait.
        assert_eq!(c.current_banner().map(|b| b.id), Some(high));
        assert_eq!(c.queue_len(), 2);
        c.set_dnd(true, 3);
        assert_eq!(c.queue_len(), 0);
        let deadline = c.next_deadline().unwrap();
        c.tick(deadline);
        assert!(
            c.current_banner().is_none(),
            "nothing below the threshold shows during DND"
        );
        assert_eq!(
            c.set_dnd(false, deadline + 1),
            vec![NotifyEvent::HeldDelivered { count: 2 }]
        );
    }

    #[test]
    fn a_zero_second_banner_setting_is_raised_to_one_second() {
        let mut c = NotificationCenter::new(NotifyConfig {
            banner_secs: 0,
            ..NotifyConfig::default()
        });
        c.post(NotificationInput::new("s", "t", ""), 1000);
        assert_eq!(c.next_deadline(), Some(2000));
        assert!(c.tick(1000).is_empty());
        assert!(c.current_banner().is_some());
    }
}
