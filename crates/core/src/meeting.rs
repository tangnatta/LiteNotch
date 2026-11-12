//! Meeting timer: an agenda of timed items (stand-up, sprint review, …)
//! run one after another, recording how long each actually took.
//!
//! Pure state with injected time, like the other modules. Elapsed time is
//! kept in milliseconds while running; the view exposes whole seconds plus
//! the instant the current stretch started, so the shell can draw the live
//! count without the core waking every second.

use serde::{Deserialize, Serialize};

use crate::agent::hooks::truncate_chars;
use crate::agent::sanitize;

pub const MAX_ITEMS: usize = 12;
const NAME_CHARS: usize = 60;
const MAX_MINUTES: u32 = 120;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ItemState {
    Pending,
    Running,
    Done,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MeetingRun {
    Stopped,
    Running,
    Paused,
    Finished,
}

/// One agenda line as the shell sends it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AgendaInput {
    pub name: String,
    pub minutes: u32,
}

/// What is saved between launches: the agenda, not a meeting in progress.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct SavedAgenda {
    pub title: String,
    pub items: Vec<AgendaInput>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Item {
    name: String,
    planned_secs: u32,
    /// Time already counted, not including a stretch that is running now.
    elapsed_ms: u64,
    state: ItemState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MeetingItemView {
    pub name: String,
    pub planned_secs: u32,
    pub elapsed_secs: u64,
    pub state: ItemState,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresetView {
    pub id: String,
    pub title: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MeetingView {
    pub title: String,
    pub items: Vec<MeetingItemView>,
    pub current: Option<usize>,
    pub run_state: MeetingRun,
    /// Planned end of the current item; only while running. May be in the
    /// past, which means the item is over time.
    pub ends_at_ms: Option<u64>,
    /// Start of the stretch now running; only while running.
    pub running_since_ms: Option<u64>,
    /// Planned time left on the current item when not running; negative
    /// when it is over.
    pub remaining_secs: i64,
    pub total_planned_secs: u64,
    /// Excludes the stretch running now.
    pub total_elapsed_secs: u64,
    pub presets: Vec<PresetView>,
}

/// Something the core turns into a notification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MeetingEvent {
    Started,
    /// The current item reached its planned time.
    TimeUp {
        item: String,
        next: Option<String>,
    },
    Finished {
        planned_secs: u64,
        elapsed_secs: u64,
    },
}

/// Preset id, title, and agenda (name, minutes).
type Preset = (&'static str, &'static str, &'static [(&'static str, u32)]);

const PRESETS: &[Preset] = &[
    (
        "standup",
        "Daily stand-up",
        &[("Updates", 10), ("Blockers", 5)],
    ),
    (
        "sprint_review",
        "Sprint review",
        &[
            ("Sprint goal recap", 5),
            ("Demo", 25),
            ("Stakeholder feedback", 15),
            ("Backlog updates", 10),
            ("Wrap-up", 5),
        ],
    ),
    (
        "sprint_planning",
        "Sprint planning",
        &[
            ("Sprint goal", 10),
            ("Capacity", 10),
            ("Backlog walkthrough", 40),
            ("Task breakdown", 30),
            ("Commitment", 10),
        ],
    ),
    (
        "retro",
        "Retrospective",
        &[
            ("Check-in", 5),
            ("What went well", 15),
            ("What to improve", 15),
            ("Action items", 15),
            ("Wrap-up", 5),
        ],
    ),
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Meeting {
    title: String,
    items: Vec<Item>,
    current: Option<usize>,
    run: MeetingRun,
    /// Start of the running stretch.
    since_ms: Option<u64>,
    /// The current item's "time is up" was already reported.
    time_up_sent: bool,
}

impl Default for Meeting {
    fn default() -> Self {
        let mut m = Meeting {
            title: String::new(),
            items: Vec::new(),
            current: None,
            run: MeetingRun::Stopped,
            since_ms: None,
            time_up_sent: false,
        };
        m.load_preset("sprint_review");
        m
    }
}

fn clean_name(s: &str, max: usize) -> String {
    let flat = sanitize(s).replace(['\n', '\r', '\t'], " ");
    truncate_chars(flat.trim(), max)
}

impl Meeting {
    pub fn new() -> Self {
        Self::default()
    }

    /// Restores a saved agenda; an empty one keeps the default.
    pub fn from_saved(saved: Option<SavedAgenda>) -> Self {
        let mut m = Self::default();
        if let Some(saved) = saved.filter(|s| !s.items.is_empty()) {
            m.set_agenda(&saved.title, &saved.items);
        }
        m
    }

    pub fn saved(&self) -> SavedAgenda {
        SavedAgenda {
            title: self.title.clone(),
            items: self
                .items
                .iter()
                .map(|i| AgendaInput {
                    name: i.name.clone(),
                    minutes: i.planned_secs / 60,
                })
                .collect(),
        }
    }

    pub fn run_state(&self) -> MeetingRun {
        self.run
    }

    /// The meeting has started and not finished.
    pub fn active(&self) -> bool {
        matches!(self.run, MeetingRun::Running | MeetingRun::Paused)
    }

    fn editable(&self) -> bool {
        matches!(self.run, MeetingRun::Stopped | MeetingRun::Finished)
    }

    /// Replaces the agenda with a preset. Returns false for an unknown id
    /// or while a meeting is in progress.
    pub fn load_preset(&mut self, id: &str) -> bool {
        let Some((_, title, items)) = PRESETS.iter().find(|(pid, _, _)| *pid == id) else {
            return false;
        };
        let items: Vec<AgendaInput> = items
            .iter()
            .map(|(name, minutes)| AgendaInput {
                name: (*name).to_string(),
                minutes: *minutes,
            })
            .collect();
        self.set_agenda(title, &items)
    }

    /// Replaces the agenda. Names are cleaned and capped, minutes clamped to
    /// 1..=120, at most [`MAX_ITEMS`] items, nameless items dropped.
    /// Returns false while a meeting is in progress.
    pub fn set_agenda(&mut self, title: &str, items: &[AgendaInput]) -> bool {
        if !self.editable() {
            return false;
        }
        self.title = clean_name(title, NAME_CHARS);
        self.items = items
            .iter()
            .filter_map(|i| {
                let name = clean_name(&i.name, NAME_CHARS);
                (!name.is_empty()).then(|| Item {
                    name,
                    planned_secs: i.minutes.clamp(1, MAX_MINUTES) * 60,
                    elapsed_ms: 0,
                    state: ItemState::Pending,
                })
            })
            .take(MAX_ITEMS)
            .collect();
        self.reset();
        true
    }

    /// Back to the start of the agenda, keeping it.
    pub fn reset(&mut self) {
        for item in &mut self.items {
            item.elapsed_ms = 0;
            item.state = ItemState::Pending;
        }
        self.current = None;
        self.run = MeetingRun::Stopped;
        self.since_ms = None;
        self.time_up_sent = false;
    }

    /// Start, pause or resume.
    pub fn toggle(&mut self, now: u64) -> Vec<MeetingEvent> {
        match self.run {
            MeetingRun::Stopped if !self.items.is_empty() => {
                self.reset();
                self.start_item(0, now);
                self.run = MeetingRun::Running;
                vec![MeetingEvent::Started]
            }
            MeetingRun::Running => {
                self.bank(now);
                self.run = MeetingRun::Paused;
                Vec::new()
            }
            MeetingRun::Paused => {
                self.since_ms = Some(now);
                self.run = MeetingRun::Running;
                Vec::new()
            }
            MeetingRun::Stopped | MeetingRun::Finished => Vec::new(),
        }
    }

    /// Finishes the current item and starts the next (also from a pause);
    /// on the last item, finishes the meeting.
    pub fn next(&mut self, now: u64) -> Vec<MeetingEvent> {
        let Some(i) = self.current.filter(|_| self.active()) else {
            return Vec::new();
        };
        self.bank(now);
        self.items[i].state = ItemState::Done;
        if i + 1 < self.items.len() {
            self.start_item(i + 1, now);
            self.run = MeetingRun::Running;
            return Vec::new();
        }
        self.current = None;
        self.run = MeetingRun::Finished;
        vec![MeetingEvent::Finished {
            planned_secs: self.total_planned_secs(),
            elapsed_secs: self.total_elapsed_ms() / 1000,
        }]
    }

    fn start_item(&mut self, i: usize, now: u64) {
        self.current = Some(i);
        self.items[i].state = ItemState::Running;
        self.since_ms = Some(now);
        self.time_up_sent = false;
    }

    /// Adds the running stretch to the current item.
    fn bank(&mut self, now: u64) {
        if let (Some(i), Some(since)) = (self.current, self.since_ms.take()) {
            let item = &mut self.items[i];
            item.elapsed_ms = item.elapsed_ms.saturating_add(now.saturating_sub(since));
        }
    }

    /// Planned end of the current item while it runs.
    fn planned_end(&self) -> Option<u64> {
        let since = self.since_ms.filter(|_| self.run == MeetingRun::Running)?;
        let item = &self.items[self.current?];
        let left = u64::from(item.planned_secs) * 1000;
        Some(since.saturating_add(left.saturating_sub(item.elapsed_ms))).map(|end| end.max(since))
    }

    /// When the core must wake: the current item's planned end, until its
    /// "time is up" has been reported.
    pub fn next_deadline(&self) -> Option<u64> {
        self.planned_end().filter(|_| !self.time_up_sent)
    }

    pub fn tick(&mut self, now: u64) -> Vec<MeetingEvent> {
        match (self.next_deadline(), self.current) {
            (Some(end), Some(i)) if now >= end => {
                self.time_up_sent = true;
                vec![MeetingEvent::TimeUp {
                    item: self.items[i].name.clone(),
                    next: self.items.get(i + 1).map(|n| n.name.clone()),
                }]
            }
            _ => Vec::new(),
        }
    }

    fn total_planned_secs(&self) -> u64 {
        self.items.iter().map(|i| u64::from(i.planned_secs)).sum()
    }

    fn total_elapsed_ms(&self) -> u64 {
        self.items.iter().map(|i| i.elapsed_ms).sum()
    }

    pub fn view(&self) -> MeetingView {
        let remaining_secs = self.current.map_or(0, |i| {
            let item = &self.items[i];
            i64::from(item.planned_secs) - (item.elapsed_ms / 1000) as i64
        });
        MeetingView {
            title: self.title.clone(),
            items: self
                .items
                .iter()
                .map(|i| MeetingItemView {
                    name: i.name.clone(),
                    planned_secs: i.planned_secs,
                    elapsed_secs: i.elapsed_ms / 1000,
                    state: i.state,
                })
                .collect(),
            current: self.current,
            run_state: self.run,
            ends_at_ms: self.planned_end(),
            running_since_ms: self.since_ms.filter(|_| self.run == MeetingRun::Running),
            remaining_secs,
            total_planned_secs: self.total_planned_secs(),
            total_elapsed_secs: self.total_elapsed_ms() / 1000,
            presets: PRESETS
                .iter()
                .map(|(id, title, _)| PresetView {
                    id: (*id).to_string(),
                    title: (*title).to_string(),
                })
                .collect(),
        }
    }

    /// Name of the item running or paused now.
    pub fn current_name(&self) -> Option<&str> {
        self.current
            .filter(|_| self.active())
            .map(|i| self.items[i].name.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T: u64 = 1_000_000;

    fn agenda(items: &[(&str, u32)]) -> Vec<AgendaInput> {
        items
            .iter()
            .map(|(n, m)| AgendaInput {
                name: (*n).into(),
                minutes: *m,
            })
            .collect()
    }

    fn two() -> Meeting {
        let mut m = Meeting::new();
        assert!(m.set_agenda("Sync", &agenda(&[("A", 1), ("B", 2)])));
        m
    }

    #[test]
    fn the_default_agenda_is_the_sprint_review_and_presets_load() {
        let m = Meeting::new();
        let v = m.view();
        assert_eq!(v.title, "Sprint review");
        assert_eq!(v.items.len(), 5);
        assert_eq!(v.total_planned_secs, 60 * 60);
        assert_eq!(v.run_state, MeetingRun::Stopped);
        assert_eq!(v.presets.len(), 4);
        let mut m = Meeting::new();
        assert!(m.load_preset("standup"));
        assert_eq!(m.view().title, "Daily stand-up");
        assert!(!m.load_preset("nope"));
        assert_eq!(m.view().title, "Daily stand-up");
    }

    #[test]
    fn a_meeting_runs_item_by_item_and_records_actual_times() {
        let mut m = two();
        assert_eq!(m.toggle(T), vec![MeetingEvent::Started]);
        let v = m.view();
        assert_eq!(v.current, Some(0));
        assert_eq!(v.ends_at_ms, Some(T + 60_000));
        assert_eq!(v.running_since_ms, Some(T));
        assert_eq!(v.items[0].state, ItemState::Running);

        // Pause after 20 s, resume 100 s later: the pause does not count.
        m.toggle(T + 20_000);
        let v = m.view();
        assert_eq!(v.run_state, MeetingRun::Paused);
        assert_eq!((v.ends_at_ms, v.running_since_ms), (None, None));
        assert_eq!(v.remaining_secs, 40);
        assert_eq!(v.items[0].elapsed_secs, 20);
        m.toggle(T + 120_000);
        assert_eq!(m.view().ends_at_ms, Some(T + 160_000));

        assert!(m.next(T + 150_000).is_empty());
        let v = m.view();
        assert_eq!(v.items[0].elapsed_secs, 50);
        assert_eq!(v.items[0].state, ItemState::Done);
        assert_eq!(v.current, Some(1));
        assert_eq!(v.ends_at_ms, Some(T + 150_000 + 120_000));

        let events = m.next(T + 330_000);
        assert_eq!(
            events,
            vec![MeetingEvent::Finished {
                planned_secs: 180,
                elapsed_secs: 230
            }]
        );
        let v = m.view();
        assert_eq!(v.run_state, MeetingRun::Finished);
        assert_eq!(v.current, None);
        assert_eq!(v.items[1].elapsed_secs, 180);
        assert_eq!(v.total_elapsed_secs, 230);
        // Nothing more happens until it is reset or restarted.
        assert!(m.next(T + 400_000).is_empty());
        assert!(m.toggle(T + 400_000).is_empty());
        assert_eq!(m.next_deadline(), None);
    }

    #[test]
    fn time_up_is_reported_once_per_item_and_overtime_is_negative() {
        let mut m = two();
        m.toggle(T);
        assert_eq!(m.next_deadline(), Some(T + 60_000));
        assert!(m.tick(T + 59_999).is_empty());
        assert_eq!(
            m.tick(T + 60_000),
            vec![MeetingEvent::TimeUp {
                item: "A".into(),
                next: Some("B".into())
            }]
        );
        assert!(m.tick(T + 61_000).is_empty());
        assert_eq!(m.next_deadline(), None);
        // Still shown as over time.
        assert_eq!(m.view().ends_at_ms, Some(T + 60_000));
        m.toggle(T + 90_000);
        assert_eq!(m.view().remaining_secs, -30);
        m.toggle(T + 95_000);
        m.next(T + 100_000);
        assert_eq!(m.next_deadline(), Some(T + 100_000 + 120_000));
        assert_eq!(
            m.tick(T + 300_000),
            vec![MeetingEvent::TimeUp {
                item: "B".into(),
                next: None
            }]
        );
    }

    #[test]
    fn next_from_a_pause_starts_the_next_item_running() {
        let mut m = two();
        m.toggle(T);
        m.toggle(T + 10_000);
        m.next(T + 50_000);
        let v = m.view();
        assert_eq!(v.items[0].elapsed_secs, 10);
        assert_eq!(v.run_state, MeetingRun::Running);
        assert_eq!(v.running_since_ms, Some(T + 50_000));
    }

    #[test]
    fn the_agenda_is_locked_while_a_meeting_runs() {
        let mut m = two();
        m.toggle(T);
        assert!(!m.set_agenda("X", &agenda(&[("Z", 5)])));
        assert!(!m.load_preset("retro"));
        assert_eq!(m.view().title, "Sync");
        m.reset();
        assert_eq!(m.view().run_state, MeetingRun::Stopped);
        assert!(m
            .view()
            .items
            .iter()
            .all(|i| i.elapsed_secs == 0 && i.state == ItemState::Pending));
        assert!(m.load_preset("retro"));
    }

    #[test]
    fn agenda_input_is_cleaned_clamped_and_capped() {
        let mut m = Meeting::new();
        let mut items = agenda(&[("  Demo\n day ", 0), ("", 5), ("Long", 500)]);
        items.push(AgendaInput {
            name: format!("a\u{202e}{}", "x".repeat(100)),
            minutes: 3,
        });
        for i in 0..20 {
            items.push(AgendaInput {
                name: format!("n{i}"),
                minutes: 1,
            });
        }
        m.set_agenda("t\u{0007}itle", &items);
        let v = m.view();
        assert_eq!(v.items.len(), MAX_ITEMS);
        assert_eq!(v.items[0].name, "Demo  day");
        assert_eq!(v.items[0].planned_secs, 60);
        assert_eq!(v.items[1].planned_secs, 120 * 60);
        assert!(!v.items[2].name.contains('\u{202e}'));
        assert_eq!(v.items[2].name.chars().count(), NAME_CHARS);
        assert!(!v.title.contains('\u{0007}'));
    }

    #[test]
    fn an_empty_agenda_cannot_start() {
        let mut m = Meeting::new();
        m.set_agenda("Empty", &[]);
        assert!(m.toggle(T).is_empty());
        assert_eq!(m.view().run_state, MeetingRun::Stopped);
        assert!(m.next(T).is_empty());
        assert_eq!(m.current_name(), None);
    }

    #[test]
    fn the_agenda_is_saved_and_restored() {
        let mut m = two();
        m.toggle(T);
        assert_eq!(m.current_name(), Some("A"));
        let saved = m.saved();
        assert_eq!(saved.items, agenda(&[("A", 1), ("B", 2)]));
        let back = Meeting::from_saved(Some(saved));
        assert_eq!(back.view().title, "Sync");
        assert_eq!(back.view().run_state, MeetingRun::Stopped);
        assert_eq!(Meeting::from_saved(None).view().title, "Sprint review");
        assert_eq!(
            Meeting::from_saved(Some(SavedAgenda::default()))
                .view()
                .title,
            "Sprint review"
        );
    }

    #[test]
    fn a_clock_going_backwards_adds_nothing() {
        let mut m = two();
        m.toggle(T);
        m.toggle(T - 5_000);
        assert_eq!(m.view().items[0].elapsed_secs, 0);
    }
}
