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
    // One of each: connected, installed but not connected, not installed.
    c.apply(
        Input::Connectors(
            [
                ("codex", true, true),
                ("gemini", true, false),
                ("antigravity", false, false),
            ]
            .into_iter()
            .map(
                |(agent, present, installed)| litenotch_core::agent::connector::ConnectorState {
                    agent: agent.into(),
                    present,
                    installed: Some(installed),
                },
            )
            .collect(),
        ),
        T0,
    );
    // A Codex session (ids arrive scoped by the CLI's connector) and its limits.
    c.hook(&json!({"hook_event_name":"UserPromptSubmit","session_id":"codex:c1","cwd":"/Users/me/Github/web","prompt":"fix the login form"}).to_string(), T0 + 1);
    c.apply(
        Input::CodexLimits(
            litenotch_core::usage::parse_codex_limits(
                &json!({"timestamp":"2026-11-14T00:00:00Z","payload":{"type":"token_count","rate_limits":{
                    "primary":{"used_percent":64.0,"window_minutes":300,"resets_at":(T0/1000)+5400},
                    "secondary":{"used_percent":23.0,"window_minutes":10080,"resets_at":(T0/1000)+300000}}}})
                .to_string(),
            )
            .unwrap_or_default(),
        ),
        T0,
    );
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
    c.apply(Input::Command(Command::CaffeineToggle), T0);
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
    // The Calendar tab with the first event open in full.
    let mut detail = Core::new(c.persisted());
    detail.apply(
        Input::Command(Command::CalendarEvents {
            events: vec![
                event("e1", "Design review", "Work", "#1BADF8", "Room 3", 4, 30),
                event("e2", "1:1 with Sam", "Work", "#1BADF8", "", 90, 25),
            ],
        }),
        T0,
    );
    detail.apply(Input::Command(Command::NotifyDismissBanner), T0 + 10);
    let attendee = |name: &str, status, me| litenotch_core::calendar::AttendeeInput {
        name: name.into(),
        status,
        me,
    };
    use litenotch_core::calendar::AttendeeStatus as A;
    detail.apply(
        Input::Command(Command::CalendarDetail {
            detail: Box::new(litenotch_core::calendar::EventDetailInput {
                id: "e1".into(),
                title: "Design review".into(),
                start_ms: T0 + 4 * 60_000,
                end_ms: T0 + 34 * 60_000,
                calendar: "Work".into(),
                color: Some("#1BADF8".into()),
                location: "Room 3".into(),
                notes: "Walk through the new onboarding flow.\n\n- Sign-up screens\n- Empty states"
                    .into(),
                url: "https://meet.example.com/abc-defg-hij".into(),
                organizer: "Sam Lee".into(),
                attendees: vec![
                    attendee("Sam Lee", A::Accepted, false),
                    attendee("Jordan Park", A::Accepted, true),
                    attendee("Alex Kim", A::Tentative, false),
                    attendee("Priya Shah", A::Pending, false),
                ],
                recurring: true,
                can_edit: true,
            }),
        }),
        T0 + 11,
    );
    out.push(("calendar", c));
    out.push(("calendar-detail", detail));
    out.push(("pair", pair));

    // Office hours on, nothing else running: the closed notch shows how far
    // through the day it is.
    let mut c = Core::default();
    let mut settings = c.settings().clone();
    settings.day.enabled = true;
    c.apply(
        Input::Command(Command::SetSettings {
            settings: Box::new(settings),
        }),
        T0,
    );
    out.push(("day", c));

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

    // With the stretch gauge on, the same moment shows it running empty
    // first.
    let mut m = populated();
    let mut s = m.settings().clone();
    // Starting at half, 40 minutes empty at 20.
    s.body.stretch_mins = 40;
    m.apply(
        Input::Command(Command::SetSettings {
            settings: Box::new(s),
        }),
        T0,
    );
    m.apply(Input::Command(Command::PomodoroToggle), T0);
    m.apply(Input::Tick, warn_at);
    views.push(("peek-move", m.view(warn_at + 20)));

    // The water and stretch gauges on Home's big card, part way down, a cup
    // just drunk. `body-water` shows water alone.
    for (name, show) in [
        ("body", litenotch_core::body::BodyShow::Both),
        ("body-water", litenotch_core::body::BodyShow::Water),
    ] {
        let mut b = populated();
        let mut s = b.settings().clone();
        s.body.water_mins = 60;
        s.body.stretch_mins = 45;
        s.body.show = show;
        s.day.home_card = litenotch_core::day::HomeCard::Body;
        b.apply(
            Input::Command(Command::SetSettings {
                settings: Box::new(s),
            }),
            T0,
        );
        let at = T0 + 40 * 60_000;
        b.apply(Input::Tick, at);
        b.apply(Input::Command(Command::BodyDrink), at);
        for _ in 0..6 {
            b.apply(Input::Command(Command::BodyStretch), at + 1_000);
        }
        views.push((name, b.view(at + 5 * 60_000)));
    }

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

    let schema = serde_json::to_string_pretty(&litenotch_core::schema::schema()).expect("schema");
    std::fs::write(format!("{dir}/schema.json"), schema).expect("schema written");
    println!("{dir}/schema.json");

    // The check for a newer version: asking, one found, and none.
    let release = |version: &str| litenotch_core::update::Release {
        version: version.into(),
        url: format!("{}/tag/v{version}", litenotch_core::update::RELEASES_PAGE),
    };
    let mut c = populated();
    c.apply(Input::Command(Command::UpdateCheck), T0);
    views.push(("update-checking", c.view(T0 + 1)));
    // A release of this build's own channel: a stable build is never shown a beta.
    let found =
        if litenotch_core::update::Channel::current() == litenotch_core::update::Channel::Beta {
            "0.3.0-beta"
        } else {
            "0.3.0"
        };
    c.apply(Input::UpdateChecked(Ok(release(found))), T0 + 2);
    views.push(("update-available", c.view(T0 + 3)));
    let mut c = populated();
    c.apply(Input::Command(Command::UpdateCheck), T0);
    c.apply(
        Input::UpdateChecked(Ok(release(litenotch_core::update::VERSION))),
        T0 + 2,
    );
    views.push(("update-current", c.view(T0 + 3)));

    for (name, view) in views {
        let json = serde_json::to_string_pretty(&view).expect("view model serializes");
        let path = format!("{dir}/{name}.json");
        std::fs::write(&path, json).expect("fixture written");
        println!("{path}");
    }
}
