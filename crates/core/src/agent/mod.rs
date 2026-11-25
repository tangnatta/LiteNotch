//! Sessions and approvals for coding agents, driven by Claude Code hook payloads.

pub mod connector;
#[cfg(test)]
mod connector_tests;
pub mod hooks;
pub mod install;
pub mod statusline;

pub use hooks::{
    allow_with_input_output, decision_output, describe, sanitize, summarize, valid_bundle_id,
    valid_tty, Description, HookError, HookEvent, HookKind,
};
pub use install::{
    install, is_installed, other_hook_clis, remove_other_hooks, uninstall, InstallError,
};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Longest stored `last_message`, in chars.
const MAX_MESSAGE_CHARS: usize = 200;
/// Longest project name shown, in chars.
const MAX_PROJECT_CHARS: usize = 60;
/// Most sessions tracked at once; beyond this the least recently active
/// session without a pending request is dropped.
pub const MAX_SESSIONS: usize = 64;

/// What an agent session is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    Working,
    WaitingApproval,
    WaitingInput,
    Idle,
    Ended,
}

/// One tracked agent session.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentSession {
    pub id: String,
    /// Last path component of `cwd`.
    pub project: String,
    pub cwd: String,
    pub status: AgentStatus,
    pub last_event_ms: u64,
    pub last_message: Option<String>,
    /// Bundle id of the terminal or editor it runs in, when known.
    #[serde(default)]
    pub app: Option<String>,
    /// The terminal device it runs on (`ttys003`), when known.
    #[serde(default)]
    pub tty: Option<String>,
}

/// A tool permission prompt waiting for the user.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PermissionRequest {
    pub id: String,
    pub session_id: String,
    pub project: String,
    pub tool_name: String,
    pub summary: String,
    pub detail: String,
    /// `detail` is cut short; the UI must not offer "Allow".
    #[serde(default)]
    pub truncated: bool,
    pub created_ms: u64,
    pub expires_ms: u64,
    /// The questions of an `AskUserQuestion` call, empty for any other tool.
    /// The UI shows them instead of Allow / Deny.
    #[serde(default)]
    pub questions: Vec<Question>,
    /// The tool input as received; never sent to the shell. An answer is this
    /// input plus an `answers` object.
    #[serde(skip)]
    input: Value,
}

/// One question Claude asks, with its choices, cleaned for display.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Question {
    pub header: String,
    pub question: String,
    pub multi_select: bool,
    pub options: Vec<QuestionOption>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionOption {
    pub label: String,
    pub description: String,
}

const MAX_QUESTIONS: usize = 4;
const MAX_OPTIONS: usize = 8;
const MAX_QUESTION_CHARS: usize = 300;
const MAX_HEADER_CHARS: usize = 30;
const MAX_LABEL_CHARS: usize = 80;
/// The shell shows the first 200 and a "More" button for the rest.
const MAX_OPTION_NOTE_CHARS: usize = 1000;
/// Most answers one multiple-choice question takes: its options plus the user's own.
const MAX_ANSWERS: usize = 16;
/// Longest typed answer, in chars.
pub const MAX_ANSWER_CHARS: usize = 500;

/// The questions of an `AskUserQuestion` input, or none if it is not shaped
/// as expected (the prompt then falls back to the plain detail view). Also
/// none when the question, a header or a label would be cut short: those must
/// be read in full. An option's note is only a hint (the answer is its
/// label), so a long one is shortened with an ellipsis instead.
fn parse_questions(input: &Value) -> Vec<Question> {
    let Some(items) = input.get("questions").and_then(Value::as_array) else {
        return Vec::new();
    };
    if items.is_empty() || items.len() > MAX_QUESTIONS {
        return Vec::new();
    }
    let mut out = Vec::new();
    for item in items {
        let text = |v: Option<&Value>, max: usize| -> Option<String> {
            let raw = v.and_then(Value::as_str).unwrap_or_default();
            let clean = sanitize(raw);
            (clean.chars().count() <= max).then_some(clean)
        };
        let Some(question) =
            text(item.get("question"), MAX_QUESTION_CHARS).filter(|q| !q.is_empty())
        else {
            return Vec::new();
        };
        let Some(header) = text(item.get("header"), MAX_HEADER_CHARS) else {
            return Vec::new();
        };
        let raw_options = item
            .get("options")
            .and_then(Value::as_array)
            .map_or(&[][..], Vec::as_slice);
        if raw_options.len() > MAX_OPTIONS {
            return Vec::new();
        }
        let mut options = Vec::new();
        for o in raw_options {
            let Some(label) = text(o.get("label"), MAX_LABEL_CHARS).filter(|l| !l.is_empty())
            else {
                return Vec::new();
            };
            let description = shorten(
                &sanitize(
                    o.get("description")
                        .and_then(Value::as_str)
                        .unwrap_or_default(),
                ),
                MAX_OPTION_NOTE_CHARS,
            );
            options.push(QuestionOption { label, description });
        }
        out.push(Question {
            header,
            question,
            multi_select: item
                .get("multiSelect")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            options,
        });
    }
    out
}

/// `s` cut to `max` chars, the last one an ellipsis, if it is longer.
fn shorten(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let head: String = s.chars().take(max.saturating_sub(1)).collect();
    format!("{}\u{2026}", head.trim_end())
}

/// The hook is registered with a 130 s timeout, after which the agent kills
/// the waiting CLI. A request must expire before that, or the notch would
/// show a prompt whose answer goes nowhere.
pub const MAX_APPROVAL_TIMEOUT_SECS: u64 = 120;
const MIN_APPROVAL_TIMEOUT_SECS: u64 = 5;

/// The user's answer to a permission prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Allow,
    Deny,
    /// Print nothing so the agent shows its normal prompt.
    Pass,
}

/// Agent module settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct AgentConfig {
    pub enabled: bool,
    pub approval_timeout_secs: u64,
    /// A session that is shown as working but has sent no hook event for this
    /// long is shown as idle: it is most likely waiting on a long tool or on
    /// the user, and `Stop` never came (idle compaction, a sleeping Mac).
    pub session_ttl_secs: u64,
    /// A session with no event for this long is forgotten. Claude Code sends
    /// `SessionEnd` when a session closes, so this only cleans up after
    /// sessions that died without saying so. Never shorter than the TTL.
    pub session_keep_secs: u64,
    /// Tool names allowed without asking.
    pub auto_allow_tools: Vec<String>,
}

impl Default for AgentConfig {
    fn default() -> Self {
        AgentConfig {
            enabled: true,
            approval_timeout_secs: 120,
            session_ttl_secs: 1800,
            session_keep_secs: 12 * 3600,
            auto_allow_tools: Vec::new(),
        }
    }
}

/// What `on_hook` tells the caller to do.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HookOutcome {
    /// Nothing to answer.
    Ack,
    /// Hold the hook open until this request is resolved.
    Pending(String),
    /// Answer immediately (auto-allow list).
    Decided(Decision),
}

/// A request that has been answered or has expired.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Resolved {
    pub request_id: String,
    pub decision: Decision,
    /// With `Allow`: the tool input to run with instead (an answered
    /// question carries its `answers`).
    #[serde(default)]
    pub updated_input: Option<Value>,
}

/// Tracks agent sessions and pending permission requests.
#[derive(Debug, Clone)]
pub struct Agents {
    cfg: AgentConfig,
    sessions: Vec<AgentSession>,
    pending: Vec<PermissionRequest>,
    /// Requests whose session ended; handed out by the next `tick`.
    orphaned: Vec<Resolved>,
    next_id: u64,
}

fn clamp_cfg(mut cfg: AgentConfig) -> AgentConfig {
    cfg.approval_timeout_secs = cfg
        .approval_timeout_secs
        .clamp(MIN_APPROVAL_TIMEOUT_SECS, MAX_APPROVAL_TIMEOUT_SECS);
    cfg.session_keep_secs = cfg.session_keep_secs.max(cfg.session_ttl_secs);
    cfg
}

/// Last non-empty path component, accepting `/` and `\` separators.
fn project_of(cwd: &str) -> String {
    let name = cwd
        .rsplit(['/', '\\'])
        .find(|c| !c.is_empty())
        .unwrap_or("");
    hooks::truncate_chars(&sanitize(name), MAX_PROJECT_CHARS)
}

fn clip(s: &str) -> String {
    hooks::truncate_chars(&sanitize(s), MAX_MESSAGE_CHARS)
}

impl Agents {
    /// Creates an empty tracker.
    pub fn new(cfg: AgentConfig) -> Self {
        Agents {
            cfg: clamp_cfg(cfg),
            sessions: Vec::new(),
            pending: Vec::new(),
            orphaned: Vec::new(),
            next_id: 1,
        }
    }

    /// Replaces the config; existing requests keep their expiry.
    pub fn set_config(&mut self, cfg: AgentConfig) {
        self.cfg = clamp_cfg(cfg);
    }

    /// Current config.
    pub fn config(&self) -> &AgentConfig {
        &self.cfg
    }

    /// Sessions in first-seen order.
    pub fn sessions(&self) -> &[AgentSession] {
        &self.sessions
    }

    /// Unanswered requests, oldest first.
    pub fn pending(&self) -> &[PermissionRequest] {
        &self.pending
    }

    /// Applies a hook event. A disabled tracker ignores everything.
    pub fn on_hook(&mut self, ev: &HookEvent, now_ms: u64) -> HookOutcome {
        if !self.cfg.enabled {
            return HookOutcome::Ack;
        }
        if ev.kind == HookKind::SessionEnd {
            // Nobody is left to act on the answer; release any waiting CLI on the next tick.
            let orphaned = &mut self.orphaned;
            self.pending.retain(|r| {
                if r.session_id == ev.session_id {
                    orphaned.push(Resolved {
                        request_id: r.id.clone(),
                        decision: Decision::Pass,
                        updated_input: None,
                    });
                    false
                } else {
                    true
                }
            });
            self.sessions.retain(|s| s.id != ev.session_id);
            return HookOutcome::Ack;
        }
        let idx = self.upsert(ev, now_ms);
        if ev.kind != HookKind::PermissionRequest {
            return HookOutcome::Ack;
        }
        let tool = ev.tool_name.clone().unwrap_or_else(|| "unknown".to_owned());
        if self.cfg.auto_allow_tools.contains(&tool) {
            self.sessions[idx].status = AgentStatus::Working;
            return HookOutcome::Decided(Decision::Allow);
        }
        let Description {
            summary,
            detail,
            truncated,
        } = describe(&tool, &ev.tool_input);
        let tool = sanitize(&tool);
        let questions = if tool == "AskUserQuestion" {
            parse_questions(&ev.tool_input)
        } else {
            Vec::new()
        };
        let id = format!("req-{}", self.next_id);
        self.next_id = self.next_id.saturating_add(1);
        self.pending.push(PermissionRequest {
            id: id.clone(),
            session_id: ev.session_id.clone(),
            project: self.sessions[idx].project.clone(),
            tool_name: tool,
            summary,
            detail,
            truncated,
            created_ms: now_ms,
            expires_ms: now_ms.saturating_add(self.cfg.approval_timeout_secs.saturating_mul(1000)),
            questions,
            input: ev.tool_input.clone(),
        });
        HookOutcome::Pending(id)
    }

    /// Creates or updates the session for `ev` and returns its index.
    fn upsert(&mut self, ev: &HookEvent, now_ms: u64) -> usize {
        let idx = match self.sessions.iter().position(|s| s.id == ev.session_id) {
            Some(i) => i,
            None => {
                if self.sessions.len() >= MAX_SESSIONS {
                    let pending = &self.pending;
                    let oldest = self
                        .sessions
                        .iter()
                        .enumerate()
                        .filter(|(_, s)| !pending.iter().any(|r| r.session_id == s.id))
                        .min_by_key(|(_, s)| s.last_event_ms)
                        .map(|(i, _)| i);
                    // If every session has a pending request, replace the first.
                    self.sessions.remove(oldest.unwrap_or(0));
                }
                self.sessions.push(AgentSession {
                    id: ev.session_id.clone(),
                    project: project_of(&ev.cwd),
                    cwd: ev.cwd.clone(),
                    status: AgentStatus::Idle,
                    last_event_ms: now_ms,
                    last_message: None,
                    app: None,
                    tty: None,
                });
                self.sessions.len() - 1
            }
        };
        let s = &mut self.sessions[idx];
        if !ev.cwd.is_empty() && ev.cwd != s.cwd {
            s.cwd = ev.cwd.clone();
            s.project = project_of(&ev.cwd);
        }
        if ev.app.is_some() {
            s.app = ev.app.clone();
        }
        if ev.tty.is_some() {
            s.tty = ev.tty.clone();
        }
        if let Some(st) = ev.status() {
            s.status = st;
        }
        let msg = match ev.kind {
            HookKind::Stop => ev.last_assistant_message.as_deref(),
            HookKind::Notification => ev.message.as_deref(),
            HookKind::UserPromptSubmit => ev.prompt.as_deref(),
            _ => None,
        };
        if let Some(m) = msg {
            s.last_message = Some(clip(m));
        }
        s.last_event_ms = now_ms;
        idx
    }

    /// Answers a pending request; `None` if it is unknown or already resolved.
    pub fn decide(
        &mut self,
        request_id: &str,
        decision: Decision,
        now_ms: u64,
    ) -> Option<Resolved> {
        let pos = self.pending.iter().position(|r| r.id == request_id)?;
        let req = self.pending.remove(pos);
        if let Some(s) = self.sessions.iter_mut().find(|s| s.id == req.session_id) {
            // Pass leaves the agent's own prompt up, so the status stays as it was.
            if decision != Decision::Pass {
                s.status = AgentStatus::Working;
            }
            s.last_event_ms = now_ms;
        }
        Some(Resolved {
            request_id: req.id,
            decision,
            updated_input: None,
        })
    }

    /// Answers a pending `AskUserQuestion`: one entry per question, each the
    /// chosen option labels or typed text. Anything that does not fit (no such
    /// request, not a question, wrong count, an empty or over-long answer, more
    /// than one answer to a single-choice question) changes nothing and returns
    /// `None`, so the request stays pending.
    pub fn answer(
        &mut self,
        request_id: &str,
        answers: &[Vec<String>],
        now_ms: u64,
    ) -> Option<Resolved> {
        let req = self.pending.iter().find(|r| r.id == request_id)?;
        if req.questions.is_empty() || answers.len() != req.questions.len() {
            return None;
        }
        let raw = req.input.get("questions")?.as_array()?;
        let mut map = serde_json::Map::new();
        for ((q, raw_q), given) in req.questions.iter().zip(raw).zip(answers) {
            if given.is_empty() || (!q.multi_select && given.len() > 1) || given.len() > MAX_ANSWERS
            {
                return None;
            }
            let mut parts = Vec::new();
            for a in given {
                let clean = sanitize(a.trim());
                if clean.is_empty() || clean.chars().count() > MAX_ANSWER_CHARS {
                    return None;
                }
                parts.push(clean);
            }
            let key = raw_q.get("question")?.as_str()?;
            map.insert(key.to_owned(), Value::String(parts.join(", ")));
        }
        let mut input = req.input.clone();
        input
            .as_object_mut()?
            .insert("answers".into(), Value::Object(map));
        let mut resolved = self.decide(request_id, Decision::Allow, now_ms)?;
        resolved.updated_input = Some(input);
        Some(resolved)
    }

    /// Expires requests (as `Pass`) and drops stale sessions; idempotent per `now_ms`.
    pub fn tick(&mut self, now_ms: u64) -> Vec<Resolved> {
        let mut out = std::mem::take(&mut self.orphaned);
        self.pending.retain(|r| {
            if r.expires_ms <= now_ms {
                out.push(Resolved {
                    request_id: r.id.clone(),
                    decision: Decision::Pass,
                    updated_input: None,
                });
                false
            } else {
                true
            }
        });
        let ttl_ms = self.cfg.session_ttl_secs.saturating_mul(1000);
        let keep_ms = self.cfg.session_keep_secs.saturating_mul(1000);
        let pending = &self.pending;
        self.sessions.retain(|s| {
            pending.iter().any(|r| r.session_id == s.id)
                || now_ms.saturating_sub(s.last_event_ms) < keep_ms
        });
        for s in &mut self.sessions {
            let quiet = now_ms.saturating_sub(s.last_event_ms) >= ttl_ms;
            if quiet
                && s.status == AgentStatus::Working
                && !pending.iter().any(|r| r.session_id == s.id)
            {
                s.status = AgentStatus::Idle;
            }
        }
        out
    }

    /// Earliest time `tick` will change something.
    pub fn next_deadline(&self) -> Option<u64> {
        let ttl_ms = self.cfg.session_ttl_secs.saturating_mul(1000);
        let keep_ms = self.cfg.session_keep_secs.saturating_mul(1000);
        let req = self.pending.iter().map(|r| r.expires_ms);
        let ses = self
            .sessions
            .iter()
            .filter(|s| !self.pending.iter().any(|r| r.session_id == s.id))
            .map(|s| {
                let after = if s.status == AgentStatus::Working {
                    ttl_ms
                } else {
                    keep_ms
                };
                s.last_event_ms.saturating_add(after)
            });
        let orphaned = (!self.orphaned.is_empty()).then_some(0);
        req.chain(ses).chain(orphaned).min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ev(name: &str, sid: &str, cwd: &str) -> HookEvent {
        HookEvent::parse(&json!({"hook_event_name":name,"session_id":sid,"cwd":cwd}).to_string())
            .unwrap()
    }

    fn perm(sid: &str, tool: &str, input: serde_json::Value) -> HookEvent {
        HookEvent::parse(
            &json!({"hook_event_name":"PermissionRequest","session_id":sid,
                "cwd":"/w/proj","tool_name":tool,"tool_input":input})
            .to_string(),
        )
        .unwrap()
    }

    fn agents() -> Agents {
        Agents::new(AgentConfig::default())
    }

    fn pending_id(o: HookOutcome) -> String {
        match o {
            HookOutcome::Pending(id) => id,
            other => panic!("expected Pending, got {other:?}"),
        }
    }

    #[test]
    fn config_defaults_match_contract() {
        let c = AgentConfig::default();
        assert!(c.enabled);
        assert_eq!(c.approval_timeout_secs, 120);
        assert_eq!(c.session_ttl_secs, 1800);
        assert_eq!(c.session_keep_secs, 12 * 3600);
        assert!(c.auto_allow_tools.is_empty());
    }

    #[test]
    fn config_deserializes_partial_json_with_defaults() {
        let c: AgentConfig = serde_json::from_str(r#"{"approval_timeout_secs":9}"#).unwrap();
        assert_eq!(c.approval_timeout_secs, 9);
        assert_eq!(c.session_ttl_secs, 1800);
        assert!(c.enabled);
    }

    #[test]
    fn serde_names_are_snake_case() {
        assert_eq!(
            serde_json::to_string(&AgentStatus::WaitingApproval).unwrap(),
            "\"waiting_approval\""
        );
        assert_eq!(serde_json::to_string(&Decision::Pass).unwrap(), "\"pass\"");
        assert_eq!(
            serde_json::to_string(&HookOutcome::Pending("r".into())).unwrap(),
            r#"{"pending":"r"}"#
        );
    }

    #[test]
    fn session_start_creates_idle_session_with_project() {
        let mut a = agents();
        assert_eq!(
            a.on_hook(&ev("SessionStart", "s1", "/Users/me/code/app"), 10),
            HookOutcome::Ack
        );
        let s = &a.sessions()[0];
        assert_eq!(s.id, "s1");
        assert_eq!(s.project, "app");
        assert_eq!(s.cwd, "/Users/me/code/app");
        assert_eq!(s.status, AgentStatus::Idle);
        assert_eq!(s.last_event_ms, 10);
        assert_eq!(s.last_message, None);
    }

    #[test]
    fn project_handles_trailing_slash_windows_and_empty() {
        assert_eq!(project_of("/a/b/"), "b");
        assert_eq!(project_of("C:\\x\\proj"), "proj");
        assert_eq!(project_of("/"), "");
        assert_eq!(project_of(""), "");
        assert_eq!(project_of("single"), "single");
        assert_eq!(project_of("/home/ณัฐ/โปรเจกต์"), "โปรเจกต์");
    }

    #[test]
    fn status_transitions_follow_hooks() {
        let mut a = agents();
        a.on_hook(&ev("SessionStart", "s", "/p"), 1);
        a.on_hook(&ev("UserPromptSubmit", "s", "/p"), 2);
        assert_eq!(a.sessions()[0].status, AgentStatus::Working);
        a.on_hook(&ev("PreToolUse", "s", "/p"), 3);
        assert_eq!(a.sessions()[0].status, AgentStatus::Working);
        a.on_hook(&ev("Stop", "s", "/p"), 4);
        assert_eq!(a.sessions()[0].status, AgentStatus::Idle);
        let mut n = ev("Notification", "s", "/p");
        n.notification_type = Some("idle_prompt".into());
        a.on_hook(&n, 5);
        assert_eq!(a.sessions()[0].status, AgentStatus::WaitingInput);
        assert_eq!(a.sessions()[0].last_event_ms, 5);
    }

    #[test]
    fn unrelated_notification_and_other_events_keep_status_but_refresh_time() {
        let mut a = agents();
        a.on_hook(&ev("UserPromptSubmit", "s", "/p"), 1);
        a.on_hook(&ev("Notification", "s", "/p"), 7);
        a.on_hook(&ev("PreCompact", "s", "/p"), 9);
        let s = &a.sessions()[0];
        assert_eq!(s.status, AgentStatus::Working);
        assert_eq!(s.last_event_ms, 9);
    }

    #[test]
    fn first_event_of_unknown_session_creates_it() {
        let mut a = agents();
        a.on_hook(&ev("PostToolUse", "late", "/p"), 1);
        assert_eq!(a.sessions().len(), 1);
        assert_eq!(a.sessions()[0].status, AgentStatus::Working);
    }

    #[test]
    fn unknown_event_for_new_session_starts_idle() {
        let mut a = agents();
        a.on_hook(&ev("Whatever", "s", "/p"), 1);
        assert_eq!(a.sessions()[0].status, AgentStatus::Idle);
    }

    #[test]
    fn last_message_tracks_prompt_notification_and_stop() {
        let mut a = agents();
        let mut e = ev("UserPromptSubmit", "s", "/p");
        e.prompt = Some("fix bug".into());
        a.on_hook(&e, 1);
        assert_eq!(a.sessions()[0].last_message.as_deref(), Some("fix bug"));
        let mut e = ev("Notification", "s", "/p");
        e.message = Some("needs you".into());
        a.on_hook(&e, 2);
        assert_eq!(a.sessions()[0].last_message.as_deref(), Some("needs you"));
        let mut e = ev("Stop", "s", "/p");
        e.last_assistant_message = Some("done ✅".into());
        a.on_hook(&e, 3);
        assert_eq!(a.sessions()[0].last_message.as_deref(), Some("done ✅"));
        a.on_hook(&ev("PreToolUse", "s", "/p"), 4);
        assert_eq!(a.sessions()[0].last_message.as_deref(), Some("done ✅"));
    }

    #[test]
    fn last_message_is_clipped_by_chars() {
        let mut a = agents();
        let mut e = ev("Stop", "s", "/p");
        e.last_assistant_message = Some("ก".repeat(500));
        a.on_hook(&e, 1);
        let m = a.sessions()[0].last_message.clone().unwrap();
        assert_eq!(m.chars().count(), MAX_MESSAGE_CHARS);
    }

    #[test]
    fn cwd_change_updates_project_and_empty_cwd_is_ignored() {
        let mut a = agents();
        a.on_hook(&ev("SessionStart", "s", "/a/one"), 1);
        a.on_hook(&ev("PreToolUse", "s", "/a/two"), 2);
        assert_eq!(a.sessions()[0].project, "two");
        a.on_hook(&ev("PreToolUse", "s", ""), 3);
        assert_eq!(a.sessions()[0].project, "two");
        assert_eq!(a.sessions()[0].cwd, "/a/two");
    }

    #[test]
    fn session_end_removes_session() {
        let mut a = agents();
        a.on_hook(&ev("SessionStart", "s", "/p"), 1);
        a.on_hook(&ev("SessionStart", "t", "/q"), 1);
        assert_eq!(a.on_hook(&ev("SessionEnd", "s", "/p"), 2), HookOutcome::Ack);
        assert_eq!(a.sessions().len(), 1);
        assert_eq!(a.sessions()[0].id, "t");
        // Ending an unknown session is a no-op.
        a.on_hook(&ev("SessionEnd", "zzz", "/p"), 3);
        assert_eq!(a.sessions().len(), 1);
    }

    #[test]
    fn permission_request_becomes_pending() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "Bash", json!({"command":"rm -rf x"})), 1000));
        let r = &a.pending()[0];
        assert_eq!(r.id, id);
        assert_eq!(r.session_id, "s");
        assert_eq!(r.project, "proj");
        assert_eq!(r.tool_name, "Bash");
        assert_eq!(r.summary, "rm -rf x");
        assert_eq!(r.created_ms, 1000);
        assert_eq!(r.expires_ms, 1000 + 120_000);
        assert_eq!(a.sessions()[0].status, AgentStatus::WaitingApproval);
    }

    #[test]
    fn request_ids_are_unique() {
        let mut a = agents();
        let i1 = pending_id(a.on_hook(&perm("s", "Bash", json!({})), 1));
        let i2 = pending_id(a.on_hook(&perm("s", "Bash", json!({})), 1));
        assert_ne!(i1, i2);
        assert_eq!(a.pending().len(), 2);
    }

    #[test]
    fn permission_request_without_tool_name_uses_unknown() {
        let mut a = agents();
        a.on_hook(&ev("PermissionRequest", "s", "/p"), 1);
        assert_eq!(a.pending()[0].tool_name, "unknown");
    }

    #[test]
    fn auto_allow_decides_immediately_and_keeps_working() {
        let mut a = Agents::new(AgentConfig {
            auto_allow_tools: vec!["Read".into()],
            ..AgentConfig::default()
        });
        let o = a.on_hook(&perm("s", "Read", json!({"file_path":"/x"})), 1);
        assert_eq!(o, HookOutcome::Decided(Decision::Allow));
        assert!(a.pending().is_empty());
        assert_eq!(a.sessions()[0].status, AgentStatus::Working);
        // A tool not on the list still prompts.
        assert!(matches!(
            a.on_hook(&perm("s", "Bash", json!({})), 2),
            HookOutcome::Pending(_)
        ));
    }

    #[test]
    fn disabled_agents_ignore_everything() {
        let mut a = Agents::new(AgentConfig {
            enabled: false,
            ..AgentConfig::default()
        });
        assert_eq!(
            a.on_hook(&perm("s", "Bash", json!({})), 1),
            HookOutcome::Ack
        );
        assert_eq!(
            a.on_hook(&ev("SessionStart", "s", "/p"), 1),
            HookOutcome::Ack
        );
        assert!(a.sessions().is_empty());
        assert!(a.pending().is_empty());
        assert_eq!(a.next_deadline(), None);
    }

    #[test]
    fn decide_allow_resolves_and_marks_working() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "Bash", json!({})), 1));
        let r = a.decide(&id, Decision::Allow, 50).unwrap();
        assert_eq!(
            r,
            Resolved {
                request_id: id.clone(),
                decision: Decision::Allow,
                updated_input: None
            }
        );
        assert!(a.pending().is_empty());
        assert_eq!(a.sessions()[0].status, AgentStatus::Working);
        assert_eq!(a.sessions()[0].last_event_ms, 50);
        // Second decide on the same request is None.
        assert_eq!(a.decide(&id, Decision::Deny, 51), None);
    }

    #[test]
    fn decide_deny_marks_working() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "Bash", json!({})), 1));
        assert_eq!(
            a.decide(&id, Decision::Deny, 2).unwrap().decision,
            Decision::Deny
        );
        assert_eq!(a.sessions()[0].status, AgentStatus::Working);
    }

    #[test]
    fn decide_pass_keeps_waiting_status() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "Bash", json!({})), 1));
        a.decide(&id, Decision::Pass, 2);
        assert_eq!(a.sessions()[0].status, AgentStatus::WaitingApproval);
    }

    #[test]
    fn decide_unknown_id_is_none() {
        let mut a = agents();
        assert_eq!(a.decide("nope", Decision::Allow, 1), None);
    }

    #[test]
    fn deciding_after_the_session_ended_does_nothing() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "Bash", json!({})), 1));
        a.on_hook(&ev("SessionEnd", "s", "/p"), 2);
        assert!(a.pending().is_empty());
        assert!(a.decide(&id, Decision::Allow, 3).is_none());
        assert!(a.sessions().is_empty());
    }

    #[test]
    fn tick_expires_requests_as_pass_once() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "Bash", json!({})), 0));
        assert!(a.tick(119_999).is_empty());
        let out = a.tick(120_000);
        assert_eq!(
            out,
            vec![Resolved {
                request_id: id,
                decision: Decision::Pass,
                updated_input: None
            }]
        );
        assert!(a.pending().is_empty());
        // Idempotent for the same instant.
        assert!(a.tick(120_000).is_empty());
    }

    #[test]
    fn tick_expires_in_creation_order() {
        let mut a = agents();
        let i1 = pending_id(a.on_hook(&perm("s", "Bash", json!({})), 0));
        let i2 = pending_id(a.on_hook(&perm("s", "Bash", json!({})), 5));
        let out = a.tick(10_000_000);
        assert_eq!(out[0].request_id, i1);
        assert_eq!(out[1].request_id, i2);
    }

    #[test]
    fn tick_with_clock_going_backwards_changes_nothing() {
        let mut a = agents();
        a.on_hook(&perm("s", "Bash", json!({})), 1_000_000);
        assert!(a.tick(5).is_empty());
        assert_eq!(a.pending().len(), 1);
        assert_eq!(a.sessions().len(), 1);
    }

    #[test]
    fn idle_session_outlives_the_ttl_and_is_dropped_only_after_keep() {
        // A session waiting at its prompt, or one that just compacted, sends
        // nothing for a long time. It must stay listed (a Mac that slept for
        // hours used to lose every session at wake).
        let mut a = agents();
        a.on_hook(&ev("Stop", "s", "/p"), 0);
        a.tick(1_800_000);
        a.tick(6 * 3_600_000);
        assert_eq!(a.sessions().len(), 1);
        assert_eq!(a.sessions()[0].status, AgentStatus::Idle);
        a.tick(12 * 3_600_000 - 1);
        assert_eq!(a.sessions().len(), 1);
        a.tick(12 * 3_600_000);
        assert!(a.sessions().is_empty());
    }

    #[test]
    fn working_session_goes_idle_after_ttl_but_is_kept() {
        let mut a = agents();
        a.on_hook(&ev("UserPromptSubmit", "s", "/p"), 0);
        assert_eq!(a.sessions()[0].status, AgentStatus::Working);
        a.tick(1_799_999);
        assert_eq!(a.sessions()[0].status, AgentStatus::Working);
        a.tick(1_800_000);
        assert_eq!(a.sessions().len(), 1);
        assert_eq!(a.sessions()[0].status, AgentStatus::Idle);
    }

    #[test]
    fn waiting_input_session_is_not_demoted() {
        let mut a = agents();
        let n = HookEvent::parse(
            &json!({"hook_event_name":"Notification","session_id":"s","cwd":"/p",
                "message":"Claude needs your input"})
            .to_string(),
        )
        .unwrap();
        a.on_hook(&n, 0);
        let before = a.sessions()[0].status;
        a.tick(3_600_000);
        assert_eq!(a.sessions()[0].status, before);
    }

    #[test]
    fn keep_is_never_shorter_than_ttl() {
        let a = Agents::new(AgentConfig {
            session_ttl_secs: 100,
            session_keep_secs: 5,
            ..AgentConfig::default()
        });
        assert_eq!(a.config().session_keep_secs, 100);
    }

    #[test]
    fn session_activity_refreshes_ttl() {
        let mut a = agents();
        a.on_hook(&ev("SessionStart", "s", "/p"), 0);
        a.on_hook(&ev("PreToolUse", "s", "/p"), 1_000_000);
        a.tick(2_000_000);
        assert_eq!(a.sessions().len(), 1);
    }

    #[test]
    fn session_with_pending_request_survives_ttl() {
        let mut a = Agents::new(AgentConfig {
            approval_timeout_secs: 120,
            session_ttl_secs: 10,
            ..AgentConfig::default()
        });
        a.on_hook(&perm("s", "Bash", json!({})), 0);
        a.tick(50_000);
        assert_eq!(a.sessions().len(), 1);
        assert_eq!(a.next_deadline(), Some(120_000));
    }

    #[test]
    fn next_deadline_is_earliest_of_requests_and_sessions() {
        let mut a = agents();
        assert_eq!(a.next_deadline(), None);
        a.on_hook(&ev("SessionStart", "s", "/p"), 1000);
        assert_eq!(a.next_deadline(), Some(1000 + 12 * 3_600_000));
        let mut b = agents();
        b.on_hook(&ev("UserPromptSubmit", "s", "/p"), 1000);
        assert_eq!(b.next_deadline(), Some(1000 + 1_800_000));
        a.on_hook(&perm("t", "Bash", json!({})), 2000);
        assert_eq!(a.next_deadline(), Some(2000 + 120_000));
    }

    #[test]
    fn huge_values_saturate() {
        let mut a = Agents::new(AgentConfig {
            approval_timeout_secs: u64::MAX,
            session_ttl_secs: u64::MAX,
            ..AgentConfig::default()
        });
        a.on_hook(&perm("s", "Bash", json!({})), u64::MAX - 1);
        assert_eq!(a.pending()[0].expires_ms, u64::MAX);
        a.on_hook(&ev("SessionStart", "t", "/p"), u64::MAX);
        assert_eq!(a.next_deadline(), Some(u64::MAX));
        assert!(a.tick(u64::MAX).len() == 1);
    }

    #[test]
    fn zero_timeout_is_raised_to_the_minimum() {
        let mut a = Agents::new(AgentConfig {
            approval_timeout_secs: 0,
            ..AgentConfig::default()
        });
        // Zero is clamped to the 5 s minimum.
        a.on_hook(&perm("s", "Bash", json!({})), 5);
        assert!(a.tick(5_004).is_empty());
        assert_eq!(a.tick(5_005).len(), 1);
    }

    #[test]
    fn set_config_applies_to_new_requests_only() {
        let mut a = agents();
        a.on_hook(&perm("s", "Bash", json!({})), 0);
        a.set_config(AgentConfig {
            approval_timeout_secs: 30,
            ..AgentConfig::default()
        });
        assert_eq!(a.config().approval_timeout_secs, 30);
        assert_eq!(a.pending()[0].expires_ms, 120_000);
        a.on_hook(&perm("s", "Bash", json!({})), 0);
        assert_eq!(a.pending()[1].expires_ms, 30_000);
    }

    #[test]
    fn unicode_project_and_summary_round_trip() {
        let mut a = agents();
        let e = HookEvent::parse(
            &json!({"hook_event_name":"PermissionRequest","session_id":"ส","cwd":"/โปรเจกต์",
                "tool_name":"Bash","tool_input":{"command":"echo สวัสดี"}})
            .to_string(),
        )
        .unwrap();
        a.on_hook(&e, 1);
        assert_eq!(a.pending()[0].project, "โปรเจกต์");
        assert_eq!(a.pending()[0].summary, "echo สวัสดี");
    }

    #[test]
    fn repeated_identical_hooks_do_not_duplicate_sessions() {
        let mut a = agents();
        for t in 0..5 {
            a.on_hook(&ev("PreToolUse", "s", "/p"), t);
        }
        assert_eq!(a.sessions().len(), 1);
    }

    #[test]
    fn session_end_releases_its_pending_requests_on_the_next_tick() {
        let mut a = Agents::new(AgentConfig::default());
        let HookOutcome::Pending(r1) = a.on_hook(&perm("s1", "Bash", json!({"command":"ls"})), 0)
        else {
            panic!()
        };
        let HookOutcome::Pending(r2) = a.on_hook(&perm("s2", "Bash", json!({"command":"ls"})), 0)
        else {
            panic!()
        };
        assert_eq!(
            a.on_hook(&ev("SessionEnd", "s1", "/w/proj"), 10),
            HookOutcome::Ack
        );
        assert_eq!(a.pending().len(), 1);
        assert_eq!(a.next_deadline(), Some(0), "the release is due immediately");
        assert_eq!(
            a.tick(10),
            vec![Resolved {
                request_id: r1,
                decision: Decision::Pass,
                updated_input: None
            }]
        );
        assert!(a.tick(10).is_empty());
        assert_eq!(a.pending()[0].id, r2);
        assert_eq!(a.sessions().len(), 1);
    }

    #[test]
    fn approval_timeout_is_clamped_below_the_hook_timeout() {
        let mut a = Agents::new(AgentConfig {
            approval_timeout_secs: 9999,
            ..Default::default()
        });
        assert_eq!(a.config().approval_timeout_secs, MAX_APPROVAL_TIMEOUT_SECS);
        a.on_hook(&perm("s1", "Bash", json!({"command":"ls"})), 1000);
        assert_eq!(
            a.pending()[0].expires_ms,
            1000 + MAX_APPROVAL_TIMEOUT_SECS * 1000
        );
        a.set_config(AgentConfig {
            approval_timeout_secs: 0,
            ..Default::default()
        });
        assert_eq!(a.config().approval_timeout_secs, 5);
    }

    #[test]
    fn oversized_commands_are_flagged_and_text_is_sanitized() {
        let mut a = Agents::new(AgentConfig::default());
        let long = "x".repeat(hooks::MAX_DETAIL_CHARS + 1);
        a.on_hook(&perm("s1", "Bash", json!({"command": long})), 0);
        a.on_hook(
            &perm("s1", "Ba\u{202E}sh", json!({"command": "ls\u{200B}"})),
            0,
        );
        assert!(a.pending()[0].truncated);
        assert!(!a.pending()[1].truncated);
        assert_eq!(a.pending()[1].tool_name, "Ba\u{FFFD}sh");
        // A tool name that only looks like "Bash" gets no special treatment:
        // its whole input is shown.
        assert_eq!(a.pending()[1].detail, "{\n  command: \"ls\u{FFFD}\"\n}");
    }

    #[test]
    fn the_number_of_sessions_is_capped_dropping_the_least_recent_idle_one() {
        let mut a = agents();
        let waiting = pending_id(a.on_hook(&perm("keep", "Bash", json!({"command":"ls"})), 0));
        for n in 0..MAX_SESSIONS as u64 + 5 {
            a.on_hook(&ev("SessionStart", &format!("s{n}"), "/p"), 10 + n);
        }
        assert_eq!(a.sessions().len(), MAX_SESSIONS);
        assert!(
            a.sessions().iter().any(|s| s.id == "keep"),
            "a session with a pending request stays"
        );
        assert!(
            !a.sessions().iter().any(|s| s.id == "s0"),
            "the oldest idle session went first"
        );
        assert!(a.decide(&waiting, Decision::Deny, 999).is_some());
    }

    #[test]
    fn project_names_and_messages_are_sanitized() {
        let mut a = agents();
        let e = HookEvent::parse(
            &json!({"hook_event_name":"Stop","session_id":"s","cwd":"/w/pro\u{202E}ject",
                    "last_assistant_message":"done\u{200B}"})
            .to_string(),
        )
        .unwrap();
        a.on_hook(&e, 1);
        assert_eq!(a.sessions()[0].project, "pro\u{FFFD}ject");
        assert_eq!(
            a.sessions()[0].last_message.as_deref(),
            Some("done\u{FFFD}")
        );
    }

    fn ask(multi: bool) -> serde_json::Value {
        json!({"questions":[
            {"question":"Which DB?","header":"Database","multiSelect":multi,
             "options":[{"label":"Postgres","description":"relational"},
                        {"label":"SQLite","description":"embedded"}]},
            {"question":"Add tests?","header":"Tests","multiSelect":false,
             "options":[{"label":"Yes","description":""},{"label":"No","description":""}]}
        ]})
    }

    #[test]
    fn a_question_tool_shows_its_questions_and_choices() {
        let mut a = agents();
        a.on_hook(&perm("s", "AskUserQuestion", ask(false)), 0);
        let q = &a.pending()[0].questions;
        assert_eq!(q.len(), 2);
        assert_eq!(q[0].header, "Database");
        assert_eq!(q[0].options[1].label, "SQLite");
        assert!(!q[0].multi_select);
        // Other tools never carry questions, even with the same input.
        a.on_hook(&perm("t", "Bash", ask(false)), 0);
        assert!(a.pending()[1].questions.is_empty());
    }

    #[test]
    fn an_answer_allows_with_the_input_plus_answers_by_question_text() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "AskUserQuestion", ask(true)), 0));
        let r = a
            .answer(
                &id,
                &[vec!["Postgres".into(), "SQLite".into()], vec!["No".into()]],
                5,
            )
            .unwrap();
        assert_eq!(r.decision, Decision::Allow);
        let input = r.updated_input.unwrap();
        assert_eq!(input["answers"]["Which DB?"], "Postgres, SQLite");
        assert_eq!(input["answers"]["Add tests?"], "No");
        assert_eq!(input["questions"], ask(true)["questions"]);
        assert!(a.pending().is_empty());
    }

    #[test]
    fn typed_text_is_a_valid_answer_and_is_made_safe() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "AskUserQuestion", ask(false)), 0));
        let r = a
            .answer(
                &id,
                &[vec!["  MySQL\u{202e}  ".into()], vec!["Yes".into()]],
                1,
            )
            .unwrap();
        assert_eq!(
            r.updated_input.unwrap()["answers"]["Which DB?"],
            "MySQL\u{FFFD}"
        );
    }

    #[test]
    fn an_answer_that_does_not_fit_leaves_the_request_waiting() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "AskUserQuestion", ask(false)), 0));
        let long = "x".repeat(MAX_ANSWER_CHARS + 1);
        let bad: Vec<Vec<Vec<String>>> = vec![
            vec![],                                                 // wrong count
            vec![vec!["Postgres".into()]],                          // wrong count
            vec![vec![], vec!["Yes".into()]],                       // nothing chosen
            vec![vec!["  ".into()], vec!["Yes".into()]],            // blank
            vec![vec!["A".into(), "B".into()], vec!["Yes".into()]], // two for single choice
            vec![vec![long], vec!["Yes".into()]],                   // too long
        ];
        for answers in bad {
            assert!(a.answer(&id, &answers, 1).is_none(), "{answers:?}");
            assert_eq!(a.pending().len(), 1);
        }
        assert!(a.answer("nope", &[], 1).is_none());
    }

    #[test]
    fn only_a_question_can_be_answered() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "Bash", json!({"command":"ls"})), 0));
        assert!(a.answer(&id, &[vec!["x".into()]], 1).is_none());
        assert_eq!(a.pending().len(), 1);
    }

    #[test]
    fn a_question_that_cannot_be_shown_in_full_falls_back_to_the_plain_prompt() {
        let mut a = agents();
        let mut input = ask(false);
        input["questions"][0]["question"] = json!("q".repeat(MAX_QUESTION_CHARS + 1));
        a.on_hook(&perm("s", "AskUserQuestion", input), 0);
        assert!(a.pending()[0].questions.is_empty());
        a.on_hook(
            &perm("t", "AskUserQuestion", json!({"questions": "nope"})),
            0,
        );
        assert!(a.pending()[1].questions.is_empty());
        let many = json!({"questions": (0..5).map(|i| json!({"question": format!("q{i}"),
            "header":"h","options":[]})).collect::<Vec<_>>()});
        a.on_hook(&perm("u", "AskUserQuestion", many), 0);
        assert!(a.pending()[2].questions.is_empty());
    }

    #[test]
    fn a_long_option_note_is_shortened_not_a_reason_to_drop_the_choices() {
        let mut a = agents();
        let mut input = ask(false);
        input["questions"][0]["options"][0]["description"] =
            json!("word ".repeat(MAX_OPTION_NOTE_CHARS));
        a.on_hook(&perm("s", "AskUserQuestion", input), 0);
        let q = &a.pending()[0].questions;
        assert_eq!(q.len(), 2, "still shown as questions");
        let note = &q[0].options[0].description;
        assert!(note.chars().count() <= MAX_OPTION_NOTE_CHARS);
        assert!(note.ends_with('\u{2026}'));
        assert_eq!(q[0].options[1].description, "embedded");
    }

    #[test]
    fn a_multiple_choice_takes_several_answers_of_the_users_own_up_to_a_limit() {
        let mut a = agents();
        let id = pending_id(a.on_hook(&perm("s", "AskUserQuestion", ask(true)), 0));
        let own: Vec<String> = (0..MAX_ANSWERS + 1).map(|i| format!("mine {i}")).collect();
        let second = vec!["No".to_string()];
        assert!(a.answer(&id, &[own.clone(), second.clone()], 1).is_none());
        let r = a
            .answer(
                &id,
                &[
                    vec!["Postgres".into(), "my own".into(), "another".into()],
                    second,
                ],
                1,
            )
            .unwrap();
        assert_eq!(
            r.updated_input.unwrap()["answers"]["Which DB?"],
            "Postgres, my own, another"
        );
    }
}
