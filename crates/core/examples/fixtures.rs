//! Writes sample view models for the shell's previews and tests:
//! `cargo run -p litenotch-core --example fixtures -- macos/Fixtures`

use litenotch_core::caffeine::AwakeMode;
use litenotch_core::clipboard::{ClipCapture, ClipKind};
use litenotch_core::media::NowPlaying;
use litenotch_core::notify::{NotificationInput, Priority};
use litenotch_core::state::{Command, Core, Input};
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

fn main() {
    let dir = std::env::args().nth(1).unwrap_or_else(|| ".".into());
    let mut out: Vec<(&str, Core)> = Vec::new();

    out.push(("idle", Core::default()));

    let mut c = populated();
    c.apply(Input::Command(Command::PomodoroToggle), T0);
    out.push(("pomodoro", c));

    let mut c = populated();
    media(&mut c);
    out.push(("media", c));

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

    for (name, core) in out {
        let json =
            serde_json::to_string_pretty(&core.view(T0 + 20)).expect("view model serializes");
        let path = format!("{dir}/{name}.json");
        std::fs::write(&path, json).expect("fixture written");
        println!("{path}");
    }
}
