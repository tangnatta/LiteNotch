//! Runs the real `litenotch` binary against a real socket server.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use litenotch_app::server::{Server, ServerEvent};
use litenotch_core::agent::Decision;
use litenotch_core::ipc::{Request, Response};
use litenotch_core::notify::Priority;
use litenotch_files::store::temp_dir;
use serde_json::json;

const BIN: &str = env!("CARGO_BIN_EXE_litenotch");

struct Fixture {
    dir: PathBuf,
    socket: PathBuf,
    seen: Arc<Mutex<Vec<Request>>>,
    _server: Option<Server>,
}

/// Starts a server that records requests and answers with `answer(request)`;
/// `None` leaves the client waiting.
fn serve(
    name: &str,
    answer: impl Fn(&Request) -> Option<Response> + Send + Sync + 'static,
) -> Fixture {
    let dir = temp_dir(name);
    let socket = dir.join("s.sock");
    let seen: Arc<Mutex<Vec<Request>>> = Arc::default();
    let held = Mutex::new(Vec::new());
    let server = {
        let seen = Arc::clone(&seen);
        Server::start(&socket, move |event| {
            if let ServerEvent::Request { request, reply, .. } = event {
                let response = answer(&request);
                seen.lock().unwrap().push(request);
                match response {
                    Some(response) => {
                        let _ = reply.send(response);
                    }
                    None => held.lock().unwrap().push(reply),
                }
            }
        })
        .unwrap()
    };
    Fixture {
        dir,
        socket,
        seen,
        _server: Some(server),
    }
}

fn offline(name: &str) -> Fixture {
    let dir = temp_dir(name);
    Fixture {
        socket: dir.join("nobody-home.sock"),
        dir,
        seen: Arc::default(),
        _server: None,
    }
}

fn run(fx: &Fixture, args: &[&str], stdin: &str) -> Output {
    let mut child = Command::new(BIN)
        .args(args)
        .env("LITENOTCH_SOCKET", &fx.socket)
        .env("CLAUDE_CONFIG_DIR", fx.dir.join("claude"))
        .env("HOME", &fx.dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn out(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn err(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn permission() -> String {
    json!({"hook_event_name":"PermissionRequest","session_id":"s1","cwd":"/w/p","tool_name":"Bash","tool_input":{"command":"ls"}}).to_string()
}

#[test]
fn an_allowed_permission_prints_the_allow_decision() {
    let fx = serve("cli-allow", |_| {
        Some(Response::Decision {
            decision: Decision::Allow,
        })
    });
    let output = run(&fx, &["hook"], &permission());
    assert_eq!(output.status.code(), Some(0));
    let printed: serde_json::Value = serde_json::from_str(&out(&output)).unwrap();
    assert_eq!(
        printed,
        json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}})
    );
    // The payload reaches the app unchanged.
    let seen = fx.seen.lock().unwrap();
    let Request::Hook { payload } = &seen[0] else {
        panic!("{seen:?}")
    };
    assert_eq!(payload["tool_input"]["command"], "ls");
}

#[test]
fn a_denied_permission_prints_the_deny_decision_with_a_message() {
    let fx = serve("cli-deny", |_| {
        Some(Response::Decision {
            decision: Decision::Deny,
        })
    });
    let printed: serde_json::Value =
        serde_json::from_str(&out(&run(&fx, &["hook"], &permission()))).unwrap();
    assert_eq!(
        printed["hookSpecificOutput"]["decision"]["behavior"],
        "deny"
    );
    assert_eq!(
        printed["hookSpecificOutput"]["decision"]["message"],
        "Denied from LiteNotch"
    );
}

#[test]
fn pass_and_plain_acknowledgements_print_nothing() {
    let fx = serve("cli-pass", |_| {
        Some(Response::Decision {
            decision: Decision::Pass,
        })
    });
    let output = run(&fx, &["hook"], &permission());
    assert_eq!((output.status.code(), out(&output).as_str()), (Some(0), ""));

    let fx = serve("cli-ack", |_| Some(Response::Ok));
    let output = run(
        &fx,
        &["hook"],
        r#"{"hook_event_name":"Stop","session_id":"s1"}"#,
    );
    assert_eq!((output.status.code(), out(&output).as_str()), (Some(0), ""));
    assert_eq!(fx.seen.lock().unwrap().len(), 1);
}

#[test]
fn hooks_stay_out_of_the_way_when_the_app_is_not_running() {
    let fx = offline("cli-offline");
    let started = Instant::now();
    for stdin in [permission(), "not json".to_string(), String::new()] {
        let output = run(&fx, &["hook"], &stdin);
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(out(&output), "");
        assert_eq!(err(&output), "");
    }
    assert!(started.elapsed() < Duration::from_secs(3), "must fail fast");
}

#[test]
fn a_non_approval_hook_does_not_wait_long_for_a_stuck_app() {
    let fx = serve("cli-stuck", |_| None);
    let started = Instant::now();
    let output = run(
        &fx,
        &["hook"],
        r#"{"hook_event_name":"Stop","session_id":"s1"}"#,
    );
    assert_eq!((output.status.code(), out(&output).as_str()), (Some(0), ""));
    let waited = started.elapsed();
    assert!(
        waited >= Duration::from_millis(1500) && waited < Duration::from_secs(5),
        "{waited:?}"
    );
}

#[test]
fn an_error_reply_to_a_hook_is_silent() {
    let fx = serve("cli-hook-err", |_| {
        Some(Response::Error {
            message: "boom".into(),
        })
    });
    let output = run(&fx, &["hook"], &permission());
    assert_eq!(
        (
            output.status.code(),
            out(&output).as_str(),
            err(&output).as_str()
        ),
        (Some(0), "", "")
    );
}

#[test]
fn statusline_prints_usage_and_forwards_the_input() {
    let fx = serve("cli-sl", |_| {
        Some(Response::Statusline {
            text: "5h 42% · 7d 18%".into(),
        })
    });
    let output = run(
        &fx,
        &["statusline"],
        r#"{"rate_limits":{"five_hour":{"used_percentage":42}}}"#,
    );
    assert_eq!(out(&output), "5h 42% · 7d 18%\n");
    let seen = fx.seen.lock().unwrap();
    let Request::Statusline { payload } = &seen[0] else {
        panic!("{seen:?}")
    };
    assert_eq!(payload["rate_limits"]["five_hour"]["used_percentage"], 42);
}

#[test]
fn statusline_wraps_an_existing_command_and_survives_without_the_app() {
    let fx = serve("cli-sl-wrap", |_| {
        Some(Response::Statusline {
            text: "5h 42%".into(),
        })
    });
    // The wrapped command receives the same stdin.
    let output = run(
        &fx,
        &["statusline", "--", "/bin/sh", "-c", "printf 'mine:'; cat"],
        r#"{"a":1}"#,
    );
    assert_eq!(out(&output), "mine:{\"a\":1} │ 5h 42%\n");

    let fx = offline("cli-sl-offline");
    let output = run(&fx, &["statusline", "--", "/bin/echo", "mine"], "{}");
    assert_eq!(
        (output.status.code(), out(&output).as_str()),
        (Some(0), "mine\n")
    );
    let output = run(&fx, &["statusline"], "{}");
    assert_eq!((output.status.code(), out(&output).as_str()), (Some(0), ""));
    let output = run(
        &fx,
        &["statusline", "--", "/nonexistent/statusline"],
        "garbage",
    );
    assert_eq!((output.status.code(), out(&output).as_str()), (Some(0), ""));
}

#[test]
fn a_wrapped_status_line_that_hangs_is_abandoned() {
    let fx = serve("cli-sl-hang", |_| {
        Some(Response::Statusline {
            text: "5h 42%".into(),
        })
    });
    let started = Instant::now();
    let output = run(&fx, &["statusline", "--", "/bin/sleep", "30"], "{}");
    assert_eq!(
        (output.status.code(), out(&output).as_str()),
        (Some(0), "5h 42%\n")
    );
    assert!(
        started.elapsed() < Duration::from_secs(8),
        "{:?}",
        started.elapsed()
    );
}

#[test]
fn notify_sends_title_body_and_options() {
    let fx = serve("cli-notify", |_| Some(Response::Ok));
    let output = run(
        &fx,
        &[
            "notify",
            "Build done",
            "in 3m",
            "--priority",
            "high",
            "--source",
            "ci",
            "--group",
            "build",
            "--ttl",
            "9",
        ],
        "",
    );
    assert_eq!(
        (output.status.code(), out(&output).as_str()),
        (Some(0), "sent\n")
    );
    run(&fx, &["notify", "Just a title", "--priority", "low"], "");
    let seen = fx.seen.lock().unwrap();
    assert_eq!(
        seen[0],
        Request::Notify {
            title: "Build done".into(),
            body: "in 3m".into(),
            source: "ci".into(),
            priority: Priority::High,
            group: Some("build".into()),
            ttl_secs: Some(9)
        }
    );
    assert_eq!(
        seen[1],
        Request::Notify {
            title: "Just a title".into(),
            body: String::new(),
            source: String::new(),
            priority: Priority::Low,
            group: None,
            ttl_secs: None
        }
    );
}

#[test]
fn notify_rejects_bad_arguments_without_contacting_the_app() {
    let fx = serve("cli-notify-bad", |_| Some(Response::Ok));
    for (args, message) in [
        (vec!["notify"], "expected a title"),
        (vec!["notify", "a", "b", "c"], "expected a title"),
        (
            vec!["notify", "t", "--priority", "urgent"],
            "unknown priority 'urgent'",
        ),
        (
            vec!["notify", "t", "--priority"],
            "--priority needs a value",
        ),
        (vec!["notify", "t", "--ttl", "soon"], "--ttl needs a number"),
        (vec!["notify", "t", "--loud"], "unknown option '--loud'"),
    ] {
        let output = run(&fx, &args, "");
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        assert!(err(&output).contains(message), "{args:?}: {}", err(&output));
    }
    assert!(fx.seen.lock().unwrap().is_empty());
}

#[test]
fn notify_and_status_report_when_the_app_is_not_running_or_misbehaves() {
    let fx = offline("cli-down");
    let output = run(&fx, &["notify", "t"], "");
    assert_eq!(output.status.code(), Some(1));
    assert!(err(&output).contains("LiteNotch is not running"));
    let output = run(&fx, &["status"], "");
    assert_eq!(output.status.code(), Some(1));
    assert!(err(&output).contains("LiteNotch is not running"));

    let fx = serve("cli-weird", |request| match request {
        Request::Notify { title, .. } if title == "err" => Some(Response::Error {
            message: "nope".into(),
        }),
        _ => Some(Response::Statusline { text: "?".into() }),
    });
    assert!(err(&run(&fx, &["notify", "err"], "")).contains("nope"));
    assert!(err(&run(&fx, &["notify", "x"], "")).contains("unexpected reply"));
    assert!(err(&run(&fx, &["status"], "")).contains("unexpected reply"));
}

#[test]
fn status_prints_the_summary_as_json() {
    let fx = serve("cli-status", |_| {
        Some(Response::Status {
            view: json!({"compact":{"kind":"idle"}}),
        })
    });
    let output = run(&fx, &["status"], "");
    assert_eq!(output.status.code(), Some(0));
    let printed: serde_json::Value = serde_json::from_str(&out(&output)).unwrap();
    assert_eq!(printed["compact"]["kind"], "idle");
}

fn settings(fx: &Fixture) -> PathBuf {
    fx.dir.join("claude/settings.json")
}

fn read_json(path: &Path) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
fn hooks_install_status_and_uninstall_edit_the_claude_settings() {
    let fx = offline("cli-hooks");
    std::fs::create_dir_all(fx.dir.join("claude")).unwrap();
    std::fs::write(settings(&fx), r#"{"theme":"dark"}"#).unwrap();

    let output = run(&fx, &["hooks", "status"], "");
    assert_eq!(
        (output.status.code(), out(&output).as_str()),
        (Some(1), "not installed\n")
    );

    let output = run(&fx, &["hooks", "install"], "");
    assert_eq!(output.status.code(), Some(0), "{}", err(&output));
    assert!(out(&output).contains("Hooks registered"));
    let json = read_json(&settings(&fx));
    assert_eq!(json["theme"], "dark");
    let command = json["hooks"]["PermissionRequest"][0]["hooks"][0]["command"]
        .as_str()
        .unwrap();
    assert_eq!(
        command,
        format!("'{BIN}' hook"),
        "the hook runs this very binary"
    );
    assert_eq!(
        json["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"],
        130
    );

    let output = run(&fx, &["hooks", "status"], "");
    assert_eq!(
        (output.status.code(), out(&output).as_str()),
        (Some(0), "installed\n")
    );

    let output = run(&fx, &["hooks", "uninstall"], "");
    assert_eq!(output.status.code(), Some(0));
    assert_eq!(read_json(&settings(&fx)), json!({"theme":"dark"}));
}

#[test]
fn hooks_errors_are_reported() {
    let fx = offline("cli-hooks-bad");
    std::fs::create_dir_all(fx.dir.join("claude")).unwrap();
    std::fs::write(settings(&fx), "[]").unwrap();
    let output = run(&fx, &["hooks", "install"], "");
    assert_eq!(output.status.code(), Some(1));
    assert!(err(&output).contains("not usable"));
    assert_eq!(std::fs::read_to_string(settings(&fx)).unwrap(), "[]");

    let output = run(&fx, &["hooks", "frobnicate"], "");
    assert_eq!(output.status.code(), Some(2));
    assert!(err(&output).contains("expected install, uninstall or status"));

    // A directory where the file should be cannot be read.
    let fx = offline("cli-hooks-unreadable");
    std::fs::create_dir_all(settings(&fx)).unwrap();
    let output = run(&fx, &["hooks", "status"], "");
    assert_eq!(output.status.code(), Some(1));
    assert!(err(&output).contains("cannot read"));
}

#[test]
fn help_and_unknown_commands() {
    let fx = offline("cli-help");
    for args in [vec![], vec!["help"], vec!["--help"], vec!["-h"]] {
        let output = run(&fx, &args, "");
        assert_eq!(output.status.code(), Some(0));
        assert!(out(&output).contains("litenotch notify <title>"));
    }
    let output = run(&fx, &["explode"], "");
    assert_eq!(output.status.code(), Some(2));
    assert!(err(&output).contains("unknown command 'explode'"));
}

#[test]
fn the_default_socket_lives_under_application_support() {
    // No LITENOTCH_SOCKET: the CLI derives the path from HOME and finds nobody there.
    let dir = temp_dir("cli-default");
    let output = Command::new(BIN)
        .args(["status"])
        .env_remove("LITENOTCH_SOCKET")
        .env("HOME", &dir)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(err(&output).contains("LiteNotch is not running"));
}
