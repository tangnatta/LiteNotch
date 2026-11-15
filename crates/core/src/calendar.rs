//! Upcoming calendar events and when to announce them.
//!
//! The shell reads the system's calendars and passes the next events in
//! whole; this module keeps them in order, decides when a reminder and a
//! "starting now" notice are due, and remembers which it has already given
//! so that a re-read of the calendar does not repeat them.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::agent::hooks::truncate_chars;
use crate::agent::sanitize;
use crate::state::normalize_hex;

/// Most events kept; the soonest win.
pub const MAX_EVENTS: usize = 50;
/// Most events in the view model.
pub const VIEW_EVENTS: usize = 12;
/// Longest reminder lead.
pub const MAX_ALERT_MINUTES: u32 = 60;
/// A start is announced only this soon after it happened: after a long
/// sleep, "starting now" for a meeting that began an hour ago is noise.
const START_GRACE_MS: u64 = 2 * 60_000;
const ID_CHARS: usize = 200;
const TITLE_CHARS: usize = 120;
const DETAIL_CHARS: usize = 80;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct CalendarConfig {
    /// Read the calendar. Off by default: it needs the user's permission.
    pub enabled: bool,
    /// Remind this many minutes before an event; 0 for no reminder.
    pub alert_minutes: u32,
    /// Also say when an event starts.
    pub alert_at_start: bool,
}

impl Default for CalendarConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            alert_minutes: 5,
            alert_at_start: true,
        }
    }
}

impl CalendarConfig {
    fn clamped(mut self) -> Self {
        self.alert_minutes = self.alert_minutes.min(MAX_ALERT_MINUTES);
        self
    }

    fn lead_ms(&self) -> u64 {
        u64::from(self.alert_minutes) * 60_000
    }
}

/// One event as the shell reports it. The text is whatever the invitation
/// said, which anyone can send, so it is sanitized and capped here.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct EventInput {
    pub id: String,
    pub title: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub all_day: bool,
    /// Name of the calendar it is in.
    pub calendar: String,
    /// The calendar's colour, `#RRGGBB`.
    pub color: Option<String>,
    pub location: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CalendarEvent {
    pub id: String,
    pub title: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub calendar: String,
    pub color: Option<String>,
    pub location: String,
}

/// Something to tell the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CalendarAlert {
    /// The event starts in `minutes` (rounded up, at least 1).
    Soon {
        event: CalendarEvent,
        minutes: u32,
    },
    Started {
        event: CalendarEvent,
    },
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CalendarView {
    /// Events that have not ended, soonest first.
    pub events: Vec<CalendarEvent>,
}

/// Sanitized, on one line (an address is often several), capped.
fn one_line(text: &str, max: usize) -> String {
    let joined = text.split_whitespace().collect::<Vec<_>>().join(" ");
    truncate_chars(&sanitize(&joined), max)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Notice {
    Soon,
    Start,
}

/// Which notice of which occurrence: a moved event is a new occurrence.
type Given = (String, u64, Notice);

#[derive(Debug, Default)]
pub struct Calendar {
    config: CalendarConfig,
    /// Not all-day, not ended, by start time.
    events: Vec<CalendarEvent>,
    given: BTreeSet<Given>,
}

impl Calendar {
    pub fn new(config: CalendarConfig) -> Self {
        Self {
            config: config.clamped(),
            events: Vec::new(),
            given: BTreeSet::new(),
        }
    }

    pub fn config(&self) -> &CalendarConfig {
        &self.config
    }

    pub fn set_config(&mut self, config: CalendarConfig) {
        self.config = config.clamped();
        if !self.config.enabled {
            self.events.clear();
            self.given.clear();
        }
    }

    /// Replaces the known events with what the calendar holds now.
    pub fn set_events(&mut self, inputs: Vec<EventInput>, now: u64) {
        if !self.config.enabled {
            return;
        }
        let mut events: Vec<CalendarEvent> = inputs
            .into_iter()
            .filter(|e| !e.all_day && e.end_ms > e.start_ms && e.end_ms > now)
            .filter_map(|e| {
                let id = truncate_chars(&e.id, ID_CHARS);
                let title = one_line(&e.title, TITLE_CHARS);
                (!id.is_empty()).then(|| CalendarEvent {
                    id,
                    title: if title.is_empty() {
                        "Event".into()
                    } else {
                        title
                    },
                    start_ms: e.start_ms,
                    end_ms: e.end_ms,
                    calendar: one_line(&e.calendar, DETAIL_CHARS),
                    color: e.color.as_deref().and_then(normalize_hex),
                    location: one_line(&e.location, DETAIL_CHARS),
                })
            })
            .collect();
        events.sort_by(|a, b| (a.start_ms, &a.id).cmp(&(b.start_ms, &b.id)));
        events.dedup_by(|a, b| a.id == b.id && a.start_ms == b.start_ms);
        events.truncate(MAX_EVENTS);
        for e in &events {
            let known = self
                .events
                .iter()
                .any(|k| k.id == e.id && k.start_ms == e.start_ms);
            // Already under way when first seen (LiteNotch was just started,
            // or the calendar just turned on): nothing to announce.
            if !known && e.start_ms <= now {
                self.given.insert((e.id.clone(), e.start_ms, Notice::Soon));
                self.given.insert((e.id.clone(), e.start_ms, Notice::Start));
            }
        }
        self.events = events;
        self.forget_gone();
    }

    fn forget_gone(&mut self) {
        let events = &self.events;
        self.given
            .retain(|(id, start, _)| events.iter().any(|e| e.id == *id && e.start_ms == *start));
    }

    fn was_given(&self, e: &CalendarEvent, notice: Notice) -> bool {
        self.given.contains(&(e.id.clone(), e.start_ms, notice))
    }

    /// Notices that have come due, and drops events that have ended.
    pub fn tick(&mut self, now: u64) -> Vec<CalendarAlert> {
        let mut alerts = Vec::new();
        if !self.config.enabled {
            return alerts;
        }
        let lead = self.config.lead_ms();
        for e in &self.events {
            let soon = (e.id.clone(), e.start_ms, Notice::Soon);
            let start = (e.id.clone(), e.start_ms, Notice::Start);
            if now >= e.start_ms {
                // A reminder that never came (asleep through it) is dropped.
                self.given.insert(soon);
                if self.given.insert(start)
                    && self.config.alert_at_start
                    && now < e.start_ms.saturating_add(START_GRACE_MS)
                    && now < e.end_ms
                {
                    alerts.push(CalendarAlert::Started { event: e.clone() });
                }
            } else if lead > 0 && now >= e.start_ms.saturating_sub(lead) && self.given.insert(soon)
            {
                let minutes = (e.start_ms - now).div_ceil(60_000).max(1);
                alerts.push(CalendarAlert::Soon {
                    event: e.clone(),
                    minutes: u32::try_from(minutes).unwrap_or(u32::MAX),
                });
            }
        }
        let before = self.events.len();
        self.events.retain(|e| e.end_ms > now);
        if self.events.len() != before {
            self.forget_gone();
        }
        alerts
    }

    /// When `tick` next has something to do: a reminder, a start, or an
    /// event ending (so the view model stops listing it).
    pub fn next_deadline(&self) -> Option<u64> {
        if !self.config.enabled {
            return None;
        }
        let lead = self.config.lead_ms();
        self.events
            .iter()
            .flat_map(|e| {
                let soon = (lead > 0 && !self.was_given(e, Notice::Soon))
                    .then(|| e.start_ms.saturating_sub(lead));
                let start = (!self.was_given(e, Notice::Start)).then_some(e.start_ms);
                [soon, start, Some(e.end_ms)]
            })
            .flatten()
            .min()
    }

    /// The event the closed notch counts down to: the next one to start,
    /// once its reminder time has come.
    pub fn imminent(&self, now: u64) -> Option<&CalendarEvent> {
        let lead = self.config.lead_ms();
        self.events
            .iter()
            .find(|e| e.start_ms > now)
            .filter(|e| lead > 0 && now >= e.start_ms.saturating_sub(lead))
    }

    pub fn view(&self, now: u64) -> CalendarView {
        CalendarView {
            events: self
                .events
                .iter()
                .filter(|e| e.end_ms > now)
                .take(VIEW_EVENTS)
                .cloned()
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIN: u64 = 60_000;
    /// An arbitrary "now": tests place events relative to it.
    const T0: u64 = 1_800_000_000_000;

    fn on() -> Calendar {
        Calendar::new(CalendarConfig {
            enabled: true,
            ..CalendarConfig::default()
        })
    }

    fn input(id: &str, start: u64, mins: u64) -> EventInput {
        EventInput {
            id: id.into(),
            title: format!("Event {id}"),
            start_ms: start,
            end_ms: start + mins * MIN,
            ..EventInput::default()
        }
    }

    fn kinds(alerts: &[CalendarAlert]) -> Vec<String> {
        alerts
            .iter()
            .map(|a| match a {
                CalendarAlert::Soon { event, minutes } => format!("soon {} {minutes}", event.id),
                CalendarAlert::Started { event } => format!("start {}", event.id),
            })
            .collect()
    }

    #[test]
    fn off_by_default_and_ignores_events_while_off() {
        let mut c = Calendar::new(CalendarConfig::default());
        assert!(!c.config().enabled);
        c.set_events(vec![input("a", T0 + 10 * MIN, 30)], T0);
        assert!(c.view(T0).events.is_empty());
        assert_eq!(c.next_deadline(), None);
        assert!(c.tick(T0 + 10 * MIN).is_empty());
    }

    #[test]
    fn reminds_before_then_announces_the_start_then_drops_the_event() {
        let mut c = on();
        let start = T0 + 30 * MIN;
        c.set_events(vec![input("a", start, 30)], T0);
        assert_eq!(c.next_deadline(), Some(start - 5 * MIN));
        assert!(c.tick(start - 5 * MIN - 1).is_empty());

        assert_eq!(kinds(&c.tick(start - 5 * MIN)), ["soon a 5"]);
        assert_eq!(c.next_deadline(), Some(start));
        assert!(c.tick(start - MIN).is_empty(), "one reminder only");

        assert_eq!(kinds(&c.tick(start)), ["start a"]);
        assert_eq!(c.next_deadline(), Some(start + 30 * MIN));
        assert!(c.tick(start + MIN).is_empty());
        assert_eq!(
            c.view(start + MIN).events.len(),
            1,
            "still on while it runs"
        );

        assert!(c.tick(start + 30 * MIN).is_empty());
        assert!(c.view(start + 30 * MIN).events.is_empty());
        assert_eq!(c.next_deadline(), None);
    }

    #[test]
    fn reading_the_calendar_again_does_not_repeat_a_notice() {
        let mut c = on();
        let start = T0 + 10 * MIN;
        c.set_events(vec![input("a", start, 30)], T0);
        assert_eq!(kinds(&c.tick(start - 5 * MIN)), ["soon a 5"]);
        c.set_events(vec![input("a", start, 30)], start - 4 * MIN);
        assert!(c.tick(start - 4 * MIN).is_empty());
        assert_eq!(kinds(&c.tick(start)), ["start a"]);
        c.set_events(vec![input("a", start, 30)], start + 1);
        assert!(c.tick(start + 1).is_empty());
    }

    #[test]
    fn a_moved_event_is_announced_at_its_new_time() {
        let mut c = on();
        let start = T0 + 10 * MIN;
        c.set_events(vec![input("a", start, 30)], T0);
        assert_eq!(kinds(&c.tick(start - 5 * MIN)), ["soon a 5"]);
        let later = start + 60 * MIN;
        c.set_events(vec![input("a", later, 30)], start - 4 * MIN);
        assert!(c.tick(start).is_empty(), "nothing at the old time");
        assert_eq!(kinds(&c.tick(later - 5 * MIN)), ["soon a 5"]);
    }

    #[test]
    fn an_event_first_seen_inside_the_lead_time_says_how_long_is_left() {
        let mut c = on();
        let start = T0 + 2 * MIN + 30_000;
        c.set_events(vec![input("a", start, 30)], T0);
        assert_eq!(kinds(&c.tick(T0)), ["soon a 3"], "2.5 min rounds up");
    }

    #[test]
    fn an_event_already_under_way_when_first_seen_is_listed_but_not_announced() {
        let mut c = on();
        c.set_events(vec![input("a", T0 - 10 * MIN, 30)], T0);
        assert!(c.tick(T0).is_empty());
        assert_eq!(c.view(T0).events.len(), 1);
        assert_eq!(c.next_deadline(), Some(T0 + 20 * MIN));
    }

    #[test]
    fn a_start_slept_through_is_not_announced_late() {
        let mut c = on();
        let start = T0 + 10 * MIN;
        c.set_events(vec![input("a", start, 60)], T0);
        // The Mac slept from before the reminder until well after the start.
        assert!(c.tick(start + 20 * MIN).is_empty());
        assert_eq!(c.next_deadline(), Some(start + 60 * MIN));
        // Just after the start is still worth saying.
        let mut c = on();
        c.set_events(vec![input("a", start, 60)], T0);
        assert_eq!(kinds(&c.tick(start + 90_000)), ["start a"]);
    }

    #[test]
    fn the_settings_choose_which_notices_are_given() {
        let start = T0 + 30 * MIN;
        let mut c = Calendar::new(CalendarConfig {
            enabled: true,
            alert_minutes: 0,
            alert_at_start: true,
        });
        c.set_events(vec![input("a", start, 30)], T0);
        assert_eq!(c.next_deadline(), Some(start), "no reminder to wake for");
        assert!(c.tick(start - MIN).is_empty());
        assert_eq!(kinds(&c.tick(start)), ["start a"]);

        let mut c = Calendar::new(CalendarConfig {
            enabled: true,
            alert_minutes: 15,
            alert_at_start: false,
        });
        c.set_events(vec![input("a", start, 30)], T0);
        assert_eq!(kinds(&c.tick(start - 15 * MIN)), ["soon a 15"]);
        assert!(c.tick(start).is_empty());

        let c = Calendar::new(CalendarConfig {
            enabled: true,
            alert_minutes: 600,
            alert_at_start: true,
        });
        assert_eq!(c.config().alert_minutes, MAX_ALERT_MINUTES);
    }

    #[test]
    fn every_deadline_is_cleared_by_the_tick_at_that_time() {
        // The runtime sleeps until `next_deadline`; a deadline that a tick
        // does not clear would make it spin.
        let mut c = on();
        c.set_events(
            vec![
                input("a", T0 + 3 * MIN, 10),
                input("b", T0 + 20 * MIN, 5),
                input("c", T0 - MIN, 2),
            ],
            T0,
        );
        let mut steps = 0;
        while let Some(at) = c.next_deadline() {
            c.tick(at);
            assert_ne!(c.next_deadline(), Some(at), "deadline {at} was not cleared");
            steps += 1;
            assert!(steps < 20);
        }
        assert!(c.view(u64::MAX).events.is_empty());
    }

    #[test]
    fn all_day_ended_and_malformed_events_are_left_out() {
        let mut c = on();
        let mut all_day = input("day", T0, 24 * 60);
        all_day.all_day = true;
        let mut backwards = input("back", T0 + 10 * MIN, 30);
        backwards.end_ms = backwards.start_ms;
        let mut nameless = input("", T0 + 10 * MIN, 30);
        nameless.title = "No id".into();
        c.set_events(
            vec![
                all_day,
                backwards,
                nameless,
                input("past", T0 - 60 * MIN, 30),
                input("ok", T0 + 10 * MIN, 30),
                input("ok", T0 + 10 * MIN, 30),
            ],
            T0,
        );
        let ids: Vec<_> = c.view(T0).events.into_iter().map(|e| e.id).collect();
        assert_eq!(ids, ["ok"]);
    }

    #[test]
    fn text_from_an_invitation_is_sanitized_and_capped() {
        let mut c = on();
        let mut e = input("a", T0 + 10 * MIN, 30);
        e.title = format!("Pay\u{202E}now\n{}", "x".repeat(500));
        e.location = "  Room\u{0007} 3  ".into();
        e.calendar = "y".repeat(500);
        e.color = Some("ff3b30".into());
        let mut blank = input("b", T0 + 20 * MIN, 30);
        blank.title = " \n ".into();
        blank.color = Some("javascript:".into());
        c.set_events(vec![e, blank], T0);
        let events = c.view(T0).events;
        assert!(!events[0].title.contains('\u{202E}') && !events[0].title.contains('\n'));
        assert_eq!(events[0].title.chars().count(), TITLE_CHARS);
        assert!(!events[0].location.contains('\u{0007}'));
        assert!(events[0].location.starts_with("Room") && events[0].location.ends_with('3'));
        assert_eq!(events[0].calendar.chars().count(), DETAIL_CHARS);
        assert_eq!(events[0].color.as_deref(), Some("#FF3B30"));
        assert_eq!(events[1].title, "Event");
        assert_eq!(events[1].color, None);
    }

    #[test]
    fn events_are_ordered_capped_and_the_view_is_shorter_still() {
        let mut c = on();
        let inputs: Vec<_> = (0..80u64)
            .rev()
            .map(|i| input(&format!("e{i:02}"), T0 + (i + 1) * 10 * MIN, 5))
            .collect();
        c.set_events(inputs, T0);
        let view = c.view(T0).events;
        assert_eq!(view.len(), VIEW_EVENTS);
        assert_eq!(view[0].id, "e00");
        assert!(view.windows(2).all(|w| w[0].start_ms <= w[1].start_ms));
        assert_eq!(c.events.len(), MAX_EVENTS);
    }

    #[test]
    fn the_notch_counts_down_to_the_next_event_once_its_reminder_is_due() {
        let mut c = on();
        let start = T0 + 30 * MIN;
        c.set_events(vec![input("a", start, 30)], T0);
        assert!(c.imminent(T0).is_none());
        assert_eq!(
            c.imminent(start - 5 * MIN).map(|e| e.id.as_str()),
            Some("a")
        );
        assert!(c.imminent(start).is_none(), "it has started");
        c.set_config(CalendarConfig {
            enabled: true,
            alert_minutes: 0,
            alert_at_start: true,
        });
        assert!(
            c.imminent(start - MIN).is_none(),
            "no reminder, no countdown"
        );
    }

    #[test]
    fn turning_the_calendar_off_forgets_the_events() {
        let mut c = on();
        c.set_events(vec![input("a", T0 + 10 * MIN, 30)], T0);
        c.set_config(CalendarConfig::default());
        assert!(c.view(T0).events.is_empty());
        assert_eq!(c.next_deadline(), None);
    }
}
