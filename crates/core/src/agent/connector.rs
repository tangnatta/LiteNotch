//! Connectors for coding agents other than Claude Code.
//!
//! Each agent runs `litenotch hook --agent <name>` with its own payload on
//! stdin. [`normalize`] turns that into the Claude Code shape the rest of the
//! core already understands (so sessions, the waiting dot and approvals work
//! unchanged), and [`decision_output`] / [`default_output`] write what the
//! agent expects back. What each agent offers differs, and the connector
//! only claims what the agent's documentation promises:
//!
//! | Agent | Config file | Session + "needs input" | Allow / Deny from the notch |
//! |---|---|---|---|
//! | Claude Code | `~/.claude/settings.json` | yes | yes (`PermissionRequest`) |
//! | Codex | `~/.codex/hooks.json` | yes | yes (`PermissionRequest`, same answer) |
//! | Gemini CLI | `~/.gemini/settings.json` | yes (`Notification` is observe-only) | no |
//! | Antigravity | `~/.gemini/config/hooks.json` | start, working, finished | no |
//!
//! Gemini's `Notification` hook "cannot block alerts or grant permissions",
//! and Antigravity has no approval event (only `PreToolUse`, whose answers
//! would replace the agent's own prompt), so neither gets buttons.

use super::install::{
    command_with, events_installed, install_events, litenotch_hook_cli, parse_root, remove_hooks,
    render, InstallError,
};
use super::Decision;
use serde_json::{json, Map, Value};

/// A coding agent LiteNotch can listen to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Agent {
    Claude,
    Codex,
    Gemini,
    Antigravity,
}

impl Agent {
    pub const ALL: [Agent; 4] = [
        Agent::Claude,
        Agent::Codex,
        Agent::Gemini,
        Agent::Antigravity,
    ];

    /// The value of `--agent`.
    pub fn flag(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
            Agent::Gemini => "gemini",
            Agent::Antigravity => "antigravity",
        }
    }

    pub fn from_flag(flag: &str) -> Option<Agent> {
        Agent::ALL.into_iter().find(|a| a.flag() == flag)
    }

    /// The name people know it by.
    pub fn name(self) -> &'static str {
        match self {
            Agent::Claude => "Claude Code",
            Agent::Codex => "Codex",
            Agent::Gemini => "Gemini CLI",
            Agent::Antigravity => "Antigravity",
        }
    }

    /// Whether the agent can hold a permission request open for the notch.
    pub fn can_approve(self) -> bool {
        matches!(self, Agent::Claude | Agent::Codex)
    }
}

fn str_of<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// A session id that cannot collide with another agent's.
fn scoped(agent: Agent, id: &str) -> String {
    format!("{}:{id}", agent.flag())
}

/// The payload as a Claude Code hook would have sent it, or `None` when the
/// event carries nothing LiteNotch shows (it is then acknowledged silently).
/// `event` is `--event`, needed by Antigravity, whose payloads do not name
/// the event that fired.
pub fn normalize(agent: Agent, event: Option<&str>, payload: &Value) -> Option<Value> {
    match agent {
        Agent::Claude => Some(payload.clone()),
        Agent::Codex => codex(payload),
        Agent::Gemini => gemini(payload),
        Agent::Antigravity => antigravity(event?, payload),
    }
}

/// Codex's payloads and `PermissionRequest` answer follow Claude Code's
/// (same event names, `session_id`, `cwd`, `tool_name`, `tool_input`).
fn codex(payload: &Value) -> Option<Value> {
    str_of(payload, "hook_event_name")?;
    let id = str_of(payload, "session_id")?;
    let mut out = payload.clone();
    out["session_id"] = json!(scoped(Agent::Codex, id));
    Some(out)
}

fn gemini(payload: &Value) -> Option<Value> {
    let id = str_of(payload, "session_id")?;
    let kind = match str_of(payload, "hook_event_name")? {
        "SessionStart" => "SessionStart",
        "SessionEnd" => "SessionEnd",
        "BeforeAgent" => "UserPromptSubmit",
        "BeforeTool" => "PreToolUse",
        "AfterTool" => "PostToolUse",
        "AfterAgent" => "Stop",
        "Notification" => "Notification",
        _ => return None,
    };
    let mut out = json!({
        "hook_event_name": kind,
        "session_id": scoped(Agent::Gemini, id),
        "cwd": str_of(payload, "cwd").unwrap_or_default(),
    });
    match kind {
        "UserPromptSubmit" => out["prompt"] = payload.get("prompt").cloned().unwrap_or_default(),
        "PreToolUse" | "PostToolUse" => {
            out["tool_name"] = payload.get("tool_name").cloned().unwrap_or_default();
            out["tool_input"] = payload.get("tool_input").cloned().unwrap_or_default();
        }
        "Stop" => {
            out["last_assistant_message"] =
                payload.get("prompt_response").cloned().unwrap_or_default()
        }
        "SessionEnd" => out["reason"] = payload.get("reason").cloned().unwrap_or_default(),
        "Notification" => {
            // The one alert Gemini documents is a tool waiting for permission.
            let tool_permission = str_of(payload, "notification_type") == Some("ToolPermission");
            out["notification_type"] = json!(if tool_permission {
                "agent_needs_input"
            } else {
                str_of(payload, "notification_type").unwrap_or("notification")
            });
            out["message"] = payload.get("message").cloned().unwrap_or_default();
        }
        _ => {}
    }
    Some(out)
}

fn antigravity(event: &str, payload: &Value) -> Option<Value> {
    let id = str_of(payload, "conversationId")?;
    let cwd = payload
        .get("workspacePaths")
        .and_then(Value::as_array)
        .and_then(|paths| paths.first())
        .and_then(Value::as_str)
        .unwrap_or_default();
    let mut out = json!({
        "session_id": scoped(Agent::Antigravity, id),
        "cwd": cwd,
    });
    let kind = match event {
        "SessionStart" => "SessionStart",
        // The first model call of a conversation is the user's prompt; later
        // ones only say the agent is still working.
        "PreInvocation" if payload.get("invocationNum").and_then(Value::as_u64) == Some(0) => {
            out["prompt"] = payload.get("lastUserInput").cloned().unwrap_or_default();
            "UserPromptSubmit"
        }
        "PreInvocation" => "PreToolUse",
        "PreToolUse" | "PostToolUse" => {
            let call = payload.get("toolCall");
            out["tool_name"] = call
                .and_then(|c| c.get("name"))
                .cloned()
                .unwrap_or_default();
            out["tool_input"] = call
                .and_then(|c| c.get("args"))
                .cloned()
                .unwrap_or_default();
            event
        }
        // Not finished while background commands still run.
        "Stop" if payload.get("fullyIdle").and_then(Value::as_bool) == Some(true) => "Stop",
        _ => return None,
    };
    out["hook_event_name"] = json!(kind);
    Some(out)
}

/// What the agent is told when the user decided an approval in the notch.
/// Only agents that can hold a request open get one.
pub fn decision_output(agent: Agent, decision: Decision) -> Option<String> {
    if agent.can_approve() {
        super::decision_output(decision)
    } else {
        None
    }
}

/// What the agent is told when the user answered a question from the notch.
/// Codex rejects a changed input ("PermissionRequest hooks currently fail
/// closed if this field is present"), and has no question tool anyway.
pub fn answer_output(agent: Agent, updated_input: &Value) -> Option<String> {
    (agent == Agent::Claude).then(|| super::allow_with_input_output(updated_input))
}

/// What the agent needs on stdout when LiteNotch has no decision to give.
/// Antigravity wants JSON from some events (`decision` is required for
/// `PreToolUse` and `Stop`), and `allow` there only "delegates to the next
/// hook or default policy", so its own prompts stay in charge. Everyone
/// else is best left with silence.
pub fn default_output(agent: Agent, event: Option<&str>) -> Option<String> {
    if agent != Agent::Antigravity {
        return None;
    }
    Some(
        match event {
            Some("PreToolUse") => r#"{"decision":"allow"}"#,
            Some("Stop") => r#"{"decision":"stop"}"#,
            _ => "{}",
        }
        .to_owned(),
    )
}

// --- installing -----------------------------------------------------------

/// Events registered in `~/.codex/hooks.json`, timeout in seconds. Codex
/// limits `SessionEnd` to 3 s.
const CODEX_EVENTS: [(&str, u64); 5] = [
    ("PermissionRequest", 130),
    ("SessionStart", 5),
    ("SessionEnd", 2),
    ("UserPromptSubmit", 5),
    ("Stop", 5),
];

/// Events registered in `~/.gemini/settings.json`, timeout in seconds
/// (Gemini counts milliseconds). Tool events are left out on purpose: they
/// would start a process on every tool call.
const GEMINI_EVENTS: [(&str, u64); 5] = [
    ("SessionStart", 5),
    ("SessionEnd", 1),
    ("BeforeAgent", 5),
    ("AfterAgent", 5),
    ("Notification", 5),
];

/// Events registered in Antigravity's `hooks.json`; the name is passed on as
/// `--event` because the payload does not carry it.
const ANTIGRAVITY_EVENTS: [(&str, u64); 3] =
    [("SessionStart", 5), ("PreInvocation", 5), ("Stop", 5)];

/// The key Antigravity's `hooks.json` keeps LiteNotch's hooks under.
const ANTIGRAVITY_KEY: &str = "litenotch";

fn agent_tail(agent: Agent) -> String {
    format!(" --agent {}", agent.flag())
}

fn antigravity_command(cli_path: &str, event: &str) -> String {
    command_with(
        cli_path,
        &format!("{} --event {event}", agent_tail(Agent::Antigravity)),
    )
}

/// Adds LiteNotch's hooks for `agent` to that agent's config text, keeping
/// everything else; idempotent.
pub fn install(agent: Agent, config: &str, cli_path: &str) -> Result<String, InstallError> {
    let tail = agent_tail(agent);
    match agent {
        Agent::Claude => super::install(config, cli_path),
        Agent::Codex => install_events(config, cli_path, &CODEX_EVENTS, None, 1, |_| {
            command_with(cli_path, &tail)
        }),
        Agent::Gemini => install_events(config, cli_path, &GEMINI_EVENTS, None, 1000, |_| {
            command_with(cli_path, &tail)
        }),
        Agent::Antigravity => install_antigravity(config, cli_path),
    }
}

/// Removes LiteNotch's hooks for `agent`, keeping everything else; idempotent.
pub fn uninstall(agent: Agent, config: &str, cli_path: &str) -> Result<String, InstallError> {
    match agent {
        Agent::Claude => super::uninstall(config, cli_path),
        Agent::Codex | Agent::Gemini => {
            let mut root = parse_root(config)?;
            remove_hooks(&mut root, |c| {
                litenotch_hook_cli(c).is_some_and(|cli| cli == cli_path)
            });
            Ok(render(root))
        }
        Agent::Antigravity => {
            let mut root = parse_root(config)?;
            root.remove(ANTIGRAVITY_KEY);
            Ok(render(root))
        }
    }
}

/// True when every event LiteNotch needs is registered for `cli_path`.
pub fn is_installed(agent: Agent, config: &str, cli_path: &str) -> bool {
    let tail = agent_tail(agent);
    match agent {
        Agent::Claude => super::is_installed(config, cli_path),
        Agent::Codex => events_installed(config, &CODEX_EVENTS, |_| command_with(cli_path, &tail)),
        Agent::Gemini => {
            events_installed(config, &GEMINI_EVENTS, |_| command_with(cli_path, &tail))
        }
        Agent::Antigravity => {
            let Ok(root) = parse_root(config) else {
                return false;
            };
            let Some(entry) = root.get(ANTIGRAVITY_KEY) else {
                return false;
            };
            ANTIGRAVITY_EVENTS.iter().all(|(event, _)| {
                let cmd = antigravity_command(cli_path, event);
                entry
                    .get(*event)
                    .and_then(Value::as_array)
                    .is_some_and(|hs| {
                        hs.iter()
                            .any(|h| h.get("command").and_then(Value::as_str) == Some(cmd.as_str()))
                    })
            })
        }
    }
}

/// Antigravity's file maps a hook name to its events; the lifecycle events
/// take their handlers directly (no matcher level). Ours is one entry under
/// its own name, so other hooks are never touched.
fn install_antigravity(config: &str, cli_path: &str) -> Result<String, InstallError> {
    if cli_path.is_empty() {
        return Err(InstallError::EmptyCliPath);
    }
    let mut root = parse_root(config)?;
    let mut entry = Map::new();
    for (event, timeout) in ANTIGRAVITY_EVENTS {
        entry.insert(
            event.into(),
            json!([{"type": "command", "command": antigravity_command(cli_path, event), "timeout": timeout}]),
        );
    }
    root.insert(ANTIGRAVITY_KEY.into(), Value::Object(entry));
    Ok(render(root))
}
