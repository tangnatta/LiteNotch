//! The connectors against the payloads and config layouts in each agent's
//! documentation (see `tests/fixtures/connectors/README.md` for where each
//! fixture comes from and how much of it is quoted rather than built).
//!
//! These live in the library, not in `tests/`: a second compile of the core
//! for an integration test made the coverage report count the unexercised
//! copy as missed lines.

use super::connector::{self, Agent};
use super::{AgentConfig, AgentStatus, Agents, Decision, HookEvent, HookKind, HookOutcome};
use serde_json::{json, Value};

fn fixture(agent: &str, name: &str) -> Value {
    let path = format!(
        "{}/tests/fixtures/connectors/{agent}/{name}.json",
        env!("CARGO_MANIFEST_DIR")
    );
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("{path}: {e}"))
}

/// Feeds a fixture through the adapter into the agent state, as the CLI,
/// socket and runtime do.
fn feed(
    agents: &mut Agents,
    agent: Agent,
    event: Option<&str>,
    payload: &Value,
    now: u64,
) -> Option<HookOutcome> {
    let normalized = connector::normalize(agent, event, payload)?;
    let hook = HookEvent::parse(&normalized.to_string()).expect("a normalized payload parses");
    Some(agents.on_hook(&hook, now))
}

fn only_session(agents: &Agents) -> super::AgentSession {
    assert_eq!(agents.sessions().len(), 1, "{:?}", agents.sessions());
    agents.sessions()[0].clone()
}

// --- Codex ----------------------------------------------------------------

#[test]
fn codex_session_runs_from_prompt_to_stop() {
    let mut agents = Agents::new(AgentConfig::default());
    let go = |agents: &mut Agents, name: &str, now| {
        feed(agents, Agent::Codex, None, &fixture("codex", name), now)
    };
    go(&mut agents, "SessionStart", 1_000);
    let s = only_session(&agents);
    assert_eq!(s.status, AgentStatus::Idle);
    assert_eq!(s.project, "proj");
    assert_eq!(s.id, "codex:019e0000-aaaa-7bbb-8ccc-000000000001");

    go(&mut agents, "UserPromptSubmit", 2_000);
    let s = only_session(&agents);
    assert_eq!(s.status, AgentStatus::Working);
    assert_eq!(s.last_message.as_deref(), Some("Refactor the parser"));

    go(&mut agents, "Stop", 3_000);
    let s = only_session(&agents);
    assert_eq!(s.status, AgentStatus::Idle);
    assert_eq!(
        s.last_message.as_deref(),
        Some("Parser refactored; tests pass.")
    );

    go(&mut agents, "SessionEnd", 4_000);
    assert!(agents.sessions().is_empty());
}

#[test]
fn codex_permission_request_waits_for_the_notch_and_answers_in_codex_form() {
    let mut agents = Agents::new(AgentConfig::default());
    let outcome = feed(
        &mut agents,
        Agent::Codex,
        None,
        &fixture("codex", "PermissionRequest"),
        1_000,
    );
    let Some(HookOutcome::Pending(id)) = outcome else {
        panic!("expected a pending request, got {outcome:?}");
    };
    let request = &agents.pending()[0];
    assert_eq!(request.id, id);
    assert_eq!(request.tool_name, "Bash");
    assert!(
        request.detail.starts_with("rm -rf build"),
        "{}",
        request.detail
    );
    assert!(request.detail.contains("Remove the build directory"));
    assert_eq!(only_session(&agents).status, AgentStatus::WaitingApproval);

    // What Codex's own schema (permission-request.command.output) accepts:
    // hookSpecificOutput.{hookEventName: "PermissionRequest", decision.behavior}.
    for (decision, behavior) in [(Decision::Allow, "allow"), (Decision::Deny, "deny")] {
        let text = connector::decision_output(Agent::Codex, decision).unwrap();
        let out: Value = serde_json::from_str(&text).unwrap();
        let hso = out["hookSpecificOutput"].as_object().unwrap();
        assert_eq!(hso["hookEventName"], "PermissionRequest");
        assert_eq!(hso["decision"]["behavior"], behavior);
        // Reserved fields make a Codex hook fail closed: never send them.
        for reserved in ["interrupt", "updatedInput", "updatedPermissions"] {
            assert!(hso["decision"].get(reserved).is_none(), "{text}");
        }
        assert_eq!(hso.len(), 2, "no other keys: {text}");
    }
    assert_eq!(
        connector::decision_output(Agent::Codex, Decision::Pass),
        None
    );
    assert_eq!(
        connector::answer_output(Agent::Codex, &json!({"answers": {}})),
        None,
        "an updated input would make Codex fail closed"
    );
}

#[test]
fn codex_approval_is_the_same_text_claude_code_gets() {
    for d in [Decision::Allow, Decision::Deny, Decision::Pass] {
        assert_eq!(
            connector::decision_output(Agent::Codex, d),
            connector::decision_output(Agent::Claude, d)
        );
    }
}

// --- Gemini CLI -----------------------------------------------------------

#[test]
fn gemini_prompt_to_finish_and_tool_permission_alert() {
    let mut agents = Agents::new(AgentConfig::default());
    let go = |agents: &mut Agents, name: &str, now| {
        feed(agents, Agent::Gemini, None, &fixture("gemini", name), now)
    };
    go(&mut agents, "SessionStart", 1_000);
    assert_eq!(only_session(&agents).status, AgentStatus::Idle);
    assert!(only_session(&agents).id.starts_with("gemini:"));

    go(&mut agents, "BeforeAgent", 2_000);
    let s = only_session(&agents);
    assert_eq!(s.status, AgentStatus::Working);
    assert_eq!(
        s.last_message.as_deref(),
        Some("Add a retry to the fetch helper")
    );

    go(&mut agents, "BeforeTool", 2_500);
    assert_eq!(only_session(&agents).status, AgentStatus::Working);

    // The ToolPermission alert is what turns the waiting dot on.
    go(&mut agents, "Notification", 3_000);
    let s = only_session(&agents);
    assert_eq!(s.status, AgentStatus::WaitingInput);
    assert_eq!(
        s.last_message.as_deref(),
        Some("Gemini needs your permission to run a shell command")
    );

    go(&mut agents, "AfterAgent", 4_000);
    let s = only_session(&agents);
    assert_eq!(s.status, AgentStatus::Idle);
    assert_eq!(
        s.last_message.as_deref(),
        Some("Added a 3-try retry with backoff.")
    );

    go(&mut agents, "SessionEnd", 5_000);
    assert!(agents.sessions().is_empty());
}

#[test]
fn gemini_events_without_a_use_are_ignored_and_nothing_can_be_approved() {
    assert_eq!(
        connector::normalize(Agent::Gemini, None, &fixture("gemini", "BeforeModel")),
        None
    );
    // Gemini's Notification hook "cannot grant permissions": no approval
    // path exists, so an answer is never printed for it.
    for d in [Decision::Allow, Decision::Deny, Decision::Pass] {
        assert_eq!(connector::decision_output(Agent::Gemini, d), None);
    }
    assert_eq!(connector::answer_output(Agent::Gemini, &json!({})), None);
    // "Silence is Mandatory": plain text on stdout would break its JSON parse.
    assert_eq!(connector::default_output(Agent::Gemini, None), None);
    let mut agents = Agents::new(AgentConfig::default());
    for name in ["BeforeTool", "Notification"] {
        let out = feed(
            &mut agents,
            Agent::Gemini,
            None,
            &fixture("gemini", name),
            1,
        );
        assert_eq!(
            out,
            Some(HookOutcome::Ack),
            "{name} never holds a hook open"
        );
    }
    assert!(agents.pending().is_empty());
}

// --- Antigravity ----------------------------------------------------------

#[test]
fn antigravity_conversation_from_start_to_finished() {
    let mut agents = Agents::new(AgentConfig::default());
    let go = |agents: &mut Agents, event: &str, name: &str, now| {
        feed(
            agents,
            Agent::Antigravity,
            Some(event),
            &fixture("antigravity", name),
            now,
        )
    };
    go(&mut agents, "SessionStart", "SessionStart", 1_000);
    let s = only_session(&agents);
    assert_eq!(s.status, AgentStatus::Idle);
    assert_eq!(s.cwd, "/workspace/project");
    assert_eq!(s.project, "project");
    assert_eq!(s.id, "antigravity:ec33ebf9-0cba-4100-8142-c61503f6c587");

    go(&mut agents, "PreInvocation", "PreInvocation-first", 2_000);
    let s = only_session(&agents);
    assert_eq!(s.status, AgentStatus::Working);
    assert_eq!(s.last_message.as_deref(), Some("Fix the failing unit test"));

    // A later model call only says it is still going.
    go(&mut agents, "Stop", "Stop-busy", 2_500);
    assert_eq!(
        only_session(&agents).status,
        AgentStatus::Working,
        "background tasks run"
    );
    go(&mut agents, "PreInvocation", "PreInvocation", 2_600);
    assert_eq!(only_session(&agents).status, AgentStatus::Working);

    go(&mut agents, "Stop", "Stop", 3_000);
    assert_eq!(only_session(&agents).status, AgentStatus::Idle);
}

#[test]
fn antigravity_tool_events_carry_the_tool_call() {
    let pre = connector::normalize(
        Agent::Antigravity,
        Some("PreToolUse"),
        &fixture("antigravity", "PreToolUse"),
    )
    .unwrap();
    assert_eq!(pre["hook_event_name"], "PreToolUse");
    assert_eq!(pre["tool_name"], "run_command");
    assert_eq!(pre["tool_input"]["CommandLine"], "npm test");
    let post = connector::normalize(
        Agent::Antigravity,
        Some("PostToolUse"),
        &fixture("antigravity", "PostToolUse"),
    )
    .unwrap();
    assert_eq!(post["hook_event_name"], "PostToolUse");
    let parsed = HookEvent::parse(&pre.to_string()).unwrap();
    assert_eq!(parsed.kind, HookKind::PreToolUse);
}

#[test]
fn antigravity_payloads_that_name_no_event_or_no_conversation_are_ignored() {
    let payload = fixture("antigravity", "SessionStart");
    assert_eq!(
        connector::normalize(Agent::Antigravity, None, &payload),
        None
    );
    assert_eq!(
        connector::normalize(Agent::Antigravity, Some("PostInvocation"), &payload),
        None
    );
    assert_eq!(
        connector::normalize(Agent::Antigravity, Some("SessionStart"), &json!({})),
        None
    );
}

/// Antigravity requires `decision` from PreToolUse and Stop. `allow` there
/// "delegates to the next hook or default policy", so its own prompt stays.
#[test]
fn antigravity_replies_with_what_its_docs_require_and_never_decides() {
    let reply = |event| connector::default_output(Agent::Antigravity, Some(event));
    let pre: Value = serde_json::from_str(&reply("PreToolUse").unwrap()).unwrap();
    assert_eq!(pre, json!({"decision": "allow"}));
    let stop: Value = serde_json::from_str(&reply("Stop").unwrap()).unwrap();
    assert_ne!(
        stop["decision"], "continue",
        "never keeps the agent running"
    );
    for event in ["SessionStart", "PreInvocation", "PostToolUse"] {
        assert_eq!(reply(event).as_deref(), Some("{}"), "{event}");
    }
    for d in [Decision::Allow, Decision::Deny] {
        assert_eq!(connector::decision_output(Agent::Antigravity, d), None);
    }
}

// --- the same id from two agents never merges ------------------------------

#[test]
fn sessions_of_different_agents_do_not_collide() {
    let mut agents = Agents::new(AgentConfig::default());
    let mut a = fixture("gemini", "SessionStart");
    let mut b = fixture("codex", "SessionStart");
    a["session_id"] = json!("same");
    b["session_id"] = json!("same");
    feed(&mut agents, Agent::Gemini, None, &a, 1);
    feed(&mut agents, Agent::Codex, None, &b, 2);
    assert_eq!(agents.sessions().len(), 2);
}

// --- installing: the files match each agent's documented layout ------------

const CLI: &str = "/Applications/LiteNotch.app/Contents/Helpers/litenotch";

/// Every event name in Codex's hook schemas (`*.command.input.schema.json`).
const CODEX_DOC_EVENTS: [&str; 14] = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PreCompact",
    "PostCompact",
    "Stop",
    "SubagentStart",
    "SubagentStop",
    "PreModelRequest",
    "PostModelRequest",
    "Interrupt",
];

/// Gemini CLI's hook events (docs/hooks/reference.md).
const GEMINI_DOC_EVENTS: [&str; 11] = [
    "BeforeTool",
    "AfterTool",
    "BeforeAgent",
    "AfterAgent",
    "BeforeModel",
    "BeforeToolSelection",
    "AfterModel",
    "SessionStart",
    "SessionEnd",
    "Notification",
    "PreCompress",
];

fn installed(agent: Agent, before: &str) -> Value {
    let text = connector::install(agent, before, CLI).unwrap();
    serde_json::from_str(&text).unwrap()
}

fn commands_of(group_or_handlers: &Value) -> Vec<String> {
    let mut out = Vec::new();
    let handlers = match group_or_handlers.get("hooks") {
        Some(h) => h,
        None => group_or_handlers,
    };
    for h in handlers.as_array().into_iter().flatten() {
        out.push(h["command"].as_str().unwrap().to_owned());
    }
    out
}

#[test]
fn codex_hooks_json_matches_the_documented_layout() {
    let root = installed(Agent::Codex, "");
    let hooks = root["hooks"].as_object().unwrap();
    for (event, groups) in hooks {
        assert!(CODEX_DOC_EVENTS.contains(&event.as_str()), "{event}");
        for group in groups.as_array().unwrap() {
            // The documented example: {"matcher"?, "hooks":[{"type":"command","command":…}]}.
            assert!(
                group.get("matcher").is_none(),
                "an optional regex; '*' is not one"
            );
            for h in group["hooks"].as_array().unwrap() {
                assert_eq!(h["type"], "command");
                assert_eq!(h["command"], format!("'{CLI}' hook --agent codex"));
                assert!(h["timeout"].as_u64().unwrap() >= 1, "seconds");
            }
        }
    }
    assert_eq!(hooks["PermissionRequest"][0]["hooks"][0]["timeout"], 130);
    // SessionEnd hooks are capped at 3 s.
    assert!(
        hooks["SessionEnd"][0]["hooks"][0]["timeout"]
            .as_u64()
            .unwrap()
            <= 3
    );
    assert!(connector::is_installed(
        Agent::Codex,
        &serde_json::to_string(&root).unwrap(),
        CLI
    ));
}

#[test]
fn gemini_settings_match_the_documented_layout_and_use_milliseconds() {
    let root = installed(
        Agent::Gemini,
        r#"{"theme":"Default","hooks":{"BeforeTool":[{"matcher":"run_shell_command","hooks":[{"type":"command","command":"./mine.sh"}]}]}}"#,
    );
    assert_eq!(root["theme"], "Default");
    let hooks = root["hooks"].as_object().unwrap();
    for (event, groups) in hooks {
        assert!(GEMINI_DOC_EVENTS.contains(&event.as_str()), "{event}");
        for group in groups.as_array().unwrap() {
            for h in group["hooks"].as_array().unwrap() {
                assert_eq!(h["type"], "command", "the only documented type");
            }
        }
    }
    let ours = &hooks["Notification"][0]["hooks"][0];
    assert_eq!(ours["command"], format!("'{CLI}' hook --agent gemini"));
    assert_eq!(ours["timeout"], 5000, "milliseconds (default 60000)");
    // The user's own hook is untouched, and no per-tool hooks are added.
    assert_eq!(commands_of(&hooks["BeforeTool"][0]), ["./mine.sh"]);
    assert_eq!(hooks["BeforeTool"].as_array().unwrap().len(), 1);
    assert!(hooks.get("AfterTool").is_none());
}

#[test]
fn antigravity_hooks_json_matches_the_documented_layout() {
    // The layout example from the docs: hook name -> event -> handlers.
    let docs_example = r#"{
      "my-linter-hook": {"PostToolUse": [{"matcher": "run_command",
        "hooks": [{"type": "command", "command": "./scripts/lint.sh", "timeout": 10}]}]},
      "session-init": {"SessionStart": [{"type": "command", "command": "./scripts/init-env.sh"}]}
    }"#;
    let root = installed(Agent::Antigravity, docs_example);
    let ours = root["litenotch"].as_object().unwrap();
    // Lifecycle events list handlers directly (no matcher level).
    for event in ["SessionStart", "PreInvocation", "Stop"] {
        let handlers = ours[event].as_array().unwrap();
        assert_eq!(handlers.len(), 1);
        let h = &handlers[0];
        assert_eq!(h["type"], "command");
        assert!(h["timeout"].as_u64().is_some(), "integer seconds");
        assert_eq!(
            h["command"],
            format!("'{CLI}' hook --agent antigravity --event {event}"),
            "the payload does not name its event, so the command does"
        );
        assert!(h.get("matcher").is_none() && h.get("hooks").is_none());
    }
    assert!(ours.get("enabled").is_none(), "defaults to true");
    // The user's hooks are untouched.
    assert_eq!(
        root["my-linter-hook"]["PostToolUse"][0]["hooks"][0]["timeout"],
        10
    );
    assert_eq!(
        root["session-init"]["SessionStart"][0]["command"],
        "./scripts/init-env.sh"
    );
}

#[test]
fn every_connector_installs_idempotently_and_uninstalls_cleanly() {
    for agent in Agent::ALL {
        let user_config = match agent {
            Agent::Antigravity => r#"{"mine":{"Stop":[{"command":"./x.sh"}]}}"#,
            _ => r#"{"keep":"me"}"#,
        };
        let once = connector::install(agent, user_config, CLI).unwrap();
        let twice = connector::install(agent, &once, CLI).unwrap();
        assert_eq!(once, twice, "{agent:?}: installing again changes nothing");
        assert!(connector::is_installed(agent, &once, CLI), "{agent:?}");
        assert!(
            !connector::is_installed(agent, user_config, CLI),
            "{agent:?}"
        );
        assert!(
            !connector::is_installed(agent, &once, "/elsewhere/litenotch"),
            "{agent:?}"
        );

        let gone = connector::uninstall(agent, &once, CLI).unwrap();
        let before: Value = serde_json::from_str(user_config).unwrap();
        let after: Value = serde_json::from_str(&gone).unwrap();
        assert_eq!(
            after, before,
            "{agent:?}: the user's config comes back as it was"
        );
    }
}

#[test]
fn installing_replaces_another_copys_hooks() {
    let old = "/Users/me/Downloads/LiteNotch.app/Contents/Helpers/litenotch";
    for agent in [Agent::Codex, Agent::Gemini] {
        let first = connector::install(agent, "", old).unwrap();
        let second = connector::install(agent, &first, CLI).unwrap();
        assert!(!second.contains(old), "{agent:?}: {second}");
        assert!(connector::is_installed(agent, &second, CLI));
    }
}

#[test]
fn bad_config_is_refused_not_overwritten() {
    for agent in Agent::ALL {
        assert!(connector::install(agent, "[1]", CLI).is_err(), "{agent:?}");
        assert!(connector::install(agent, "{", CLI).is_err(), "{agent:?}");
        assert!(connector::install(agent, "{}", "").is_err(), "{agent:?}");
    }
}

#[test]
fn agent_flags_round_trip() {
    for agent in Agent::ALL {
        assert_eq!(Agent::from_flag(agent.flag()), Some(agent));
        assert!(!agent.name().is_empty());
    }
    assert_eq!(Agent::from_flag("cursor"), None);
    assert!(Agent::Claude.can_approve() && Agent::Codex.can_approve());
    assert!(!Agent::Gemini.can_approve() && !Agent::Antigravity.can_approve());
}
