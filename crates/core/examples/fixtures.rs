//! Writes sample view models for the shell's previews and tests:
//! `cargo run -p litenotch-core --example fixtures -- macos/Fixtures`

use litenotch_core::caffeine::AwakeMode;
use litenotch_core::clipboard::{ClipCapture, ClipKind};
use litenotch_core::media::NowPlaying;
use litenotch_core::notify::{NotificationInput, Priority};
use litenotch_core::state::{Command, Core, Input, ViewModel, PEEK_MS};
use litenotch_core::usage::{local_day_start_ms, UsageRecord};
use serde_json::json;

const T0: u64 = 1_794_400_000_000;

fn clip(core: &mut Core, text: &str, app: &str, kind: ClipKind, at: u64) {
    core.apply(
        Input::ClipCaptured(ClipCapture {
            kind,
            text: text.into(),
            source_app: Some(app.into()),
            concealed: false,
            image_path: (kind == ClipKind::Image).then(|| "/tmp/litenotch-fixture/clip.png".into()),
            rich_path: text
                .starts_with("https://")
                .then(|| "/tmp/litenotch-fixture/rich.html".into()),
        }),
        at,
    );
}

/// A week of token usage ending today, across a few models and projects.
fn usage_week(c: &mut Core) {
    let day_start = local_day_start_ms(T0, 0);
    let rows: [(u64, &str, &str, u64); 9] = [
        (6, "fable-5-2", "litenotch", 410_000),
        (5, "fable-5-2", "litenotch", 690_000),
        (4, "sonnet-5-5", "api-gateway", 240_000),
        (3, "fable-5-2", "litenotch", 880_000),
        (2, "fable-5-2", "docs", 150_000),
        (1, "fable-5-2", "litenotch", 520_000),
        (0, "fable-5-2", "litenotch", 610_000),
        (0, "sonnet-5-5", "api-gateway", 180_000),
        (0, "haiku-5-5", "docs", 42_000),
    ];
    for (i, (days_ago, model, project, tokens)) in rows.into_iter().enumerate() {
        c.apply(
            Input::UsageRecord {
                record: UsageRecord {
                    ts_ms: day_start - days_ago * 86_400_000 + 3_600_000,
                    key: Some(i as u64),
                    model: model.into(),
                    project: project.into(),
                    input: tokens / 10,
                    output: tokens - tokens / 10,
                    cache_read: tokens * 6,
                    cache_write: tokens / 2,
                },
                day_start_ms: day_start,
                day_end_ms: day_start + 86_400_000,
            },
            T0,
        );
    }
}

fn populated() -> Core {
    let mut c = Core::default();
    c.apply(Input::HooksInstalled(Some(true)), T0);
    usage_week(&mut c);
    clip(
        &mut c,
        "cargo llvm-cov --workspace --fail-under-lines 90",
        "Ghostty",
        ClipKind::Text,
        T0,
    );
    clip(
        &mut c,
        "https://code.claude.com/docs/en/hooks",
        "Safari",
        ClipKind::Text,
        T0 + 1,
    );
    clip(
        &mut c,
        "/Users/me/Desktop/notch-mock.png\n/Users/me/Desktop/notch-mock@2x.png",
        "Finder",
        ClipKind::Files,
        T0 + 2,
    );
    clip(
        &mut c,
        "fn next_deadline(&self) -> Option<u64> {\n    self.until_ms\n}",
        "Zed",
        ClipKind::Text,
        T0 + 3,
    );
    clip(&mut c, "Image", "Preview", ClipKind::Image, T0 + 4);
    let pinned = c.view(T0).clipboard.items.last().map(|i| i.id).unwrap_or(1);
    c.apply(
        Input::Command(Command::ClipPin {
            id: pinned,
            pinned: true,
        }),
        T0 + 5,
    );
    c.apply(
        Input::Statusline(
            json!({"rate_limits":{"five_hour":{"used_percentage":42.0,"resets_at":(T0/1000)+7200},
                   "seven_day":{"used_percentage":18.5,"resets_at":(T0/1000)+400000}},
                   "cost":{"total_cost_usd":3.42},"context_window":{"used_percentage":37.0},
                   "model":{"display_name":"Fable 5.2"}})
            .to_string(),
        ),
        T0,
    );
    c.hook(&json!({"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/Users/me/Github/LiteNotch","prompt":"add tests"}).to_string(), T0);
    c.hook(&json!({"hook_event_name":"Stop","session_id":"s2","cwd":"/Users/me/Github/api-server","last_assistant_message":"All 42 tests pass."}).to_string(), T0 + 1);
    c.apply(Input::Command(Command::NotifyDismissBanner), T0 + 2);
    c.apply(
        Input::ExternalNotify(NotificationInput {
            source: "ci".into(),
            title: "Deploy finished".into(),
            body: "main → production in 3m 12s".into(),
            priority: Priority::Normal,
            group: None,
            ttl_secs: None,
        }),
        T0 + 3,
    );
    c.apply(Input::Command(Command::NotifyDismissBanner), T0 + 4);
    c.apply(Input::Command(Command::PanelOpened), T0);
    c
}

fn media(c: &mut Core) {
    c.apply(
        Input::NowPlaying(Some(NowPlaying {
            app: "Spotify".into(),
            title: "Weightless".into(),
            artist: "Marconi Union".into(),
            album: "Ambient Transmissions".into(),
            playing: true,
            duration_ms: Some(480_000),
            position_ms: Some(95_000),
            updated_ms: T0,
            artwork_path: None,
        })),
        T0,
    );
}

/// Lets the track-change peek end, so a fixture shows the activity.
fn after_peek(c: &mut Core) {
    c.apply(Input::Tick, T0 + PEEK_MS);
}

fn main() {
    let dir = std::env::args().nth(1).unwrap_or_else(|| ".".into());
    let mut out: Vec<(&str, Core)> = Vec::new();

    out.push(("idle", Core::default()));

    let mut c = populated();
    c.apply(Input::Command(Command::PomodoroToggle), T0);
    out.push(("pomodoro", c));

    let mut c = populated();
    media(&mut c);
    after_peek(&mut c);
    out.push(("media", c));

    let mut c = populated();
    media(&mut c);
    out.push(("peek-track", c));

    let mut c = populated();
    media(&mut c);
    c.apply(Input::Command(Command::PomodoroToggle), T0);
    c.apply(
        Input::Command(Command::CaffeineActivate {
            mode: AwakeMode::Display,
            duration_secs: Some(3600),
        }),
        T0,
    );
    c.hook(&json!({"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/Users/me/Github/LiteNotch",
        "tool_name":"Bash","tool_input":{"command":"cargo test --workspace && git push origin feature/notch-ui"}}).to_string(), T0 + 10);
    out.push(("approval", c));

    let mut c = populated();
    c.apply(
        Input::ExternalNotify(NotificationInput {
            source: "ci".into(),
            title: "Build failed on main".into(),
            body: "2 tests failed in crates/core".into(),
            priority: Priority::High,
            group: None,
            ttl_secs: None,
        }),
        T0 + 10,
    );
    out.push(("banner", c));

    let mut c = populated();
    c.apply(Input::Command(Command::CaffeineLid { on: true }), T0);
    c.apply(Input::LidResult { ok: true }, T0 + 1);
    out.push(("caffeine", c));

    let mut c = populated();
    let mut settings = c.settings().clone();
    settings.calendar.enabled = true;
    c.apply(
        Input::Command(Command::SetSettings {
            settings: Box::new(settings),
        }),
        T0,
    );
    let event = |id: &str,
                 title: &str,
                 calendar: &str,
                 color: &str,
                 location: &str,
                 mins: u64,
                 len: u64| {
        litenotch_core::calendar::EventInput {
            id: id.into(),
            title: title.into(),
            start_ms: T0 + mins * 60_000,
            end_ms: T0 + (mins + len) * 60_000,
            all_day: false,
            calendar: calendar.into(),
            color: Some(color.into()),
            location: location.into(),
        }
    };
    c.apply(
        Input::Command(Command::CalendarEvents {
            events: vec![
                event("e1", "Design review", "Work", "#1BADF8", "Room 3", 4, 30),
                event("e2", "1:1 with Sam", "Work", "#1BADF8", "", 90, 25),
                event(
                    "e3",
                    "Dentist",
                    "Home",
                    "#FF2968",
                    "12 High Street",
                    300,
                    45,
                ),
            ],
        }),
        T0,
    );
    c.apply(Input::Command(Command::NotifyDismissBanner), T0 + 10);
    // The same moment with a focus session running: two things to show.
    let mut pair = Core::new(c.persisted());
    pair.apply(Input::Command(Command::PomodoroToggle), T0);
    pair.apply(
        Input::Command(Command::CalendarEvents {
            events: vec![event(
                "e1",
                "Design review",
                "Work",
                "#1BADF8",
                "Room 3",
                4,
                30,
            )],
        }),
        T0,
    );
    pair.apply(Input::Command(Command::NotifyDismissBanner), T0 + 10);
    pair.hook(
        &json!({"hook_event_name":"Notification","session_id":"s9","cwd":"/Users/me/Github/api",
            "notification_type":"idle_prompt","message":"Claude is waiting for your input"})
        .to_string(),
        T0 + 11,
    );
    out.push(("calendar", c));
    out.push(("pair", pair));

    let mut views: Vec<(&str, ViewModel)> = out
        .into_iter()
        .map(|(name, core)| (name, core.view(T0 + 20)))
        .collect();

    // A focus phase five minutes from its end: the warning peek.
    let mut c = populated();
    c.apply(Input::Command(Command::PomodoroToggle), T0);
    let warn_at = T0 + 20 * 60_000;
    c.apply(Input::Tick, warn_at);
    views.push(("peek-warning", c.view(warn_at + 20)));

    // With Move on, the same moment shows the Move reminder first.
    let mut m = populated();
    let mut s = m.settings().clone();
    s.peek.move_mins = 20;
    m.apply(
        Input::Command(Command::SetSettings {
            settings: Box::new(s),
        }),
        T0,
    );
    m.apply(Input::Command(Command::PomodoroToggle), T0);
    m.apply(Input::Tick, warn_at);
    views.push(("peek-move", m.view(warn_at + 20)));

    // The eye break, five minutes of screen time in.
    let mut e = populated();
    let mut s = e.settings().clone();
    s.peek.eye_break_mins = 5;
    e.apply(
        Input::Command(Command::SetSettings {
            settings: Box::new(s),
        }),
        T0,
    );
    e.apply(Input::Tick, T0 + 5 * 60_000);
    views.push(("peek-eye-break", e.view(T0 + 5 * 60_000 + 20)));

    // The short break has ended and its banner gone: the line after it.
    let end = T0 + 30 * 60_000 + 5_000;
    while let Some(t) = c.next_deadline().filter(|&t| t <= end) {
        c.apply(Input::Tick, t);
    }
    views.push(("peek-quote", c.view(end + 20)));

    // Still at the keyboard during the short break: the first check gives
    // a peek, the third a banner offering to skip the break.
    let mut w = populated();
    w.apply(Input::Command(Command::PomodoroToggle), T0);
    fn nag(w: &mut Core, at: u64) {
        while let Some(t) = w.next_deadline().filter(|&t| t <= at) {
            w.apply(Input::Tick, t);
        }
        w.apply(Input::InputIdle { secs: 0 }, at);
    }
    let first = T0 + 26 * 60_000;
    nag(&mut w, first);
    views.push(("peek-still-working", w.view(first + 20)));
    nag(&mut w, first + 90_000);
    nag(&mut w, first + 180_000);
    views.push(("banner-skip-break", w.view(first + 180_020)));

    for (name, view) in views {
        let json = serde_json::to_string_pretty(&view).expect("view model serializes");
        let path = format!("{dir}/{name}.json");
        std::fs::write(&path, json).expect("fixture written");
        println!("{path}");
    }
}
