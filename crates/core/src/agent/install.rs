//! Pure JSON-in/JSON-out editing of Claude Code `settings.json` hooks.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::fmt;

/// Events registered with their timeout in seconds.
const EVENTS: [(&str, u64); 6] = [
    ("PermissionRequest", 130),
    ("SessionStart", 5),
    ("SessionEnd", 5),
    ("UserPromptSubmit", 5),
    ("Stop", 5),
    ("Notification", 5),
];

/// Why settings could not be edited.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InstallError {
    /// The settings text is not valid JSON.
    InvalidJson(String),
    /// The settings root is not an object.
    NotObject,
    /// `hooks` (or one event inside it) has an unexpected type.
    BadHooksShape,
    /// The CLI path is empty.
    EmptyCliPath,
}

impl fmt::Display for InstallError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            InstallError::InvalidJson(e) => write!(f, "settings are not valid JSON: {e}"),
            InstallError::NotObject => write!(f, "settings root is not a JSON object"),
            InstallError::BadHooksShape => write!(f, "settings `hooks` has an unexpected shape"),
            InstallError::EmptyCliPath => write!(f, "CLI path is empty"),
        }
    }
}

impl std::error::Error for InstallError {}

/// The hook command line. The path is single-quoted so the shell takes it
/// literally, whatever characters the install location contains.
fn command_for(cli_path: &str) -> String {
    format!("'{}' hook", cli_path.replace('\'', "'\\''"))
}

fn parse_root(settings_json: &str) -> Result<Map<String, Value>, InstallError> {
    if settings_json.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<Value>(settings_json) {
        Ok(Value::Object(m)) => Ok(m),
        Ok(_) => Err(InstallError::NotObject),
        Err(e) => Err(InstallError::InvalidJson(e.to_string())),
    }
}

fn render(root: Map<String, Value>) -> String {
    // Serializing a Value cannot fail; the fallback only avoids an unwrap.
    serde_json::to_string_pretty(&Value::Object(root)).unwrap_or_else(|_| "{}".to_owned())
}

fn group_has_command(group: &Value, cmd: &str) -> bool {
    group
        .get("hooks")
        .and_then(Value::as_array)
        .is_some_and(|hs| {
            hs.iter()
                .any(|h| h.get("command").and_then(Value::as_str) == Some(cmd))
        })
}

/// Adds LiteNotch hooks to `settings_json`, keeping everything else; idempotent.
pub fn install(settings_json: &str, cli_path: &str) -> Result<String, InstallError> {
    if cli_path.is_empty() {
        return Err(InstallError::EmptyCliPath);
    }
    let cmd = command_for(cli_path);
    let mut root = parse_root(settings_json)?;
    let hooks = root
        .entry("hooks")
        .or_insert_with(|| Value::Object(Map::new()))
        .as_object_mut()
        .ok_or(InstallError::BadHooksShape)?;
    for (event, timeout) in EVENTS {
        let groups = hooks
            .entry(event)
            .or_insert_with(|| Value::Array(Vec::new()))
            .as_array_mut()
            .ok_or(InstallError::BadHooksShape)?;
        if groups.iter().any(|g| group_has_command(g, &cmd)) {
            continue;
        }
        groups.push(json!({
            "matcher": "*",
            "hooks": [{"type": "command", "command": cmd, "timeout": timeout}]
        }));
    }
    Ok(render(root))
}

/// Removes LiteNotch hooks for `cli_path`, keeping everything else; idempotent.
pub fn uninstall(settings_json: &str, cli_path: &str) -> Result<String, InstallError> {
    let cmd = command_for(cli_path);
    let mut root = parse_root(settings_json)?;
    let mut hooks_now_empty = false;
    if let Some(hooks) = root.get_mut("hooks").and_then(Value::as_object_mut) {
        let mut changed = false;
        let mut empty_events = Vec::new();
        for (event, groups) in hooks.iter_mut() {
            let Some(groups) = groups.as_array_mut() else {
                continue;
            };
            let mut event_changed = false;
            groups.retain_mut(|g| {
                let Some(hs) = g.get_mut("hooks").and_then(Value::as_array_mut) else {
                    return true;
                };
                let before = hs.len();
                hs.retain(|h| h.get("command").and_then(Value::as_str) != Some(cmd.as_str()));
                let removed = hs.len() != before;
                event_changed |= removed;
                // Drop only groups we emptied, never ones that were already empty.
                !(removed && hs.is_empty())
            });
            changed |= event_changed;
            if groups.is_empty() && event_changed {
                empty_events.push(event.clone());
            }
        }
        for e in empty_events {
            hooks.remove(&e);
        }
        hooks_now_empty = changed && hooks.is_empty();
    }
    if hooks_now_empty {
        root.remove("hooks");
    }
    Ok(render(root))
}

/// True when every LiteNotch event is registered for `cli_path`.
pub fn is_installed(settings_json: &str, cli_path: &str) -> bool {
    let cmd = command_for(cli_path);
    let Ok(root) = parse_root(settings_json) else {
        return false;
    };
    let Some(hooks) = root.get("hooks").and_then(Value::as_object) else {
        return false;
    };
    EVENTS.iter().all(|(event, _)| {
        hooks
            .get(*event)
            .and_then(Value::as_array)
            .is_some_and(|gs| gs.iter().any(|g| group_has_command(g, &cmd)))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const CLI: &str = "/usr/local/bin/litenotch";

    fn val(s: &str) -> Value {
        serde_json::from_str(s).unwrap()
    }

    #[test]
    fn install_into_empty_string_registers_all_events() {
        let out = install("", CLI).unwrap();
        let v = val(&out);
        for (event, timeout) in EVENTS {
            let g = &v["hooks"][event][0];
            assert_eq!(g["matcher"], "*");
            assert_eq!(g["hooks"][0]["type"], "command");
            assert_eq!(g["hooks"][0]["command"], "'/usr/local/bin/litenotch' hook");
            assert_eq!(g["hooks"][0]["timeout"], timeout);
        }
        assert_eq!(
            v["hooks"]["PermissionRequest"][0]["hooks"][0]["timeout"],
            130
        );
        assert_eq!(v["hooks"]["Notification"][0]["hooks"][0]["timeout"], 5);
        assert!(is_installed(&out, CLI));
    }

    #[test]
    fn install_treats_whitespace_as_empty() {
        assert!(is_installed(&install("  \n", CLI).unwrap(), CLI));
    }

    #[test]
    fn install_is_idempotent() {
        let once = install("{}", CLI).unwrap();
        let twice = install(&once, CLI).unwrap();
        assert_eq!(once, twice);
        assert_eq!(val(&twice)["hooks"]["Stop"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn install_preserves_unrelated_keys_and_hooks() {
        let src = r#"{"theme":"dark","permissions":{"allow":["Bash(ls)"]},
            "hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"echo hi"}]}],
                     "PreToolUse":[{"matcher":"Bash","hooks":[]}]}}"#;
        let v = val(&install(src, CLI).unwrap());
        assert_eq!(v["theme"], "dark");
        assert_eq!(v["permissions"]["allow"][0], "Bash(ls)");
        assert_eq!(v["hooks"]["PreToolUse"][0]["matcher"], "Bash");
        let stop = v["hooks"]["Stop"].as_array().unwrap();
        assert_eq!(stop.len(), 2);
        assert_eq!(stop[0]["hooks"][0]["command"], "echo hi");
    }

    #[test]
    fn install_different_cli_paths_coexist() {
        let a = install("{}", "/a/ln").unwrap();
        let b = install(&a, "/b/ln").unwrap();
        assert!(is_installed(&b, "/a/ln"));
        assert!(is_installed(&b, "/b/ln"));
        assert_eq!(val(&b)["hooks"]["Stop"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn install_adds_only_missing_events() {
        let partial = install("{}", CLI).unwrap();
        let mut v = val(&partial);
        v["hooks"].as_object_mut().unwrap().remove("Stop");
        let fixed = install(&v.to_string(), CLI).unwrap();
        assert!(is_installed(&fixed, CLI));
        assert_eq!(
            val(&fixed)["hooks"]["SessionEnd"].as_array().unwrap().len(),
            1
        );
    }

    #[test]
    fn install_rejects_bad_input() {
        assert_eq!(install("[]", CLI), Err(InstallError::NotObject));
        assert_eq!(install("3", CLI), Err(InstallError::NotObject));
        assert!(matches!(
            install("{x", CLI),
            Err(InstallError::InvalidJson(_))
        ));
        assert_eq!(install("{}", ""), Err(InstallError::EmptyCliPath));
        assert_eq!(
            install(r#"{"hooks":[]}"#, CLI),
            Err(InstallError::BadHooksShape)
        );
        assert_eq!(
            install(r#"{"hooks":{"Stop":{}}}"#, CLI),
            Err(InstallError::BadHooksShape)
        );
    }

    #[test]
    fn install_handles_unicode_and_spaces_in_path() {
        let cli = "/Users/ณัฐ/My Apps/litenotch";
        let out = install("{}", cli).unwrap();
        assert!(is_installed(&out, cli));
        assert!(val(&out)["hooks"]["Stop"][0]["hooks"][0]["command"]
            .as_str()
            .unwrap()
            .starts_with("'/Users/ณัฐ/My Apps/litenotch'"));
    }

    #[test]
    fn uninstall_reverses_install_on_empty() {
        let out = uninstall(&install("{}", CLI).unwrap(), CLI).unwrap();
        assert_eq!(val(&out), json!({}));
        assert!(!is_installed(&out, CLI));
    }

    #[test]
    fn uninstall_keeps_other_hooks_and_keys() {
        let src = r#"{"theme":"dark","hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"echo hi"}]}]}}"#;
        let installed = install(src, CLI).unwrap();
        let v = val(&uninstall(&installed, CLI).unwrap());
        assert_eq!(v["theme"], "dark");
        assert_eq!(v["hooks"]["Stop"].as_array().unwrap().len(), 1);
        assert_eq!(v["hooks"]["Stop"][0]["hooks"][0]["command"], "echo hi");
        assert!(v["hooks"].get("SessionEnd").is_none());
    }

    #[test]
    fn uninstall_only_removes_our_command_from_shared_group() {
        let cmd = command_for(CLI);
        let src = json!({"hooks":{"Stop":[{"matcher":"*","hooks":[
            {"type":"command","command":"echo hi"},
            {"type":"command","command":cmd}]}]}});
        let v = val(&uninstall(&src.to_string(), CLI).unwrap());
        let hs = v["hooks"]["Stop"][0]["hooks"].as_array().unwrap();
        assert_eq!(hs.len(), 1);
        assert_eq!(hs[0]["command"], "echo hi");
    }

    #[test]
    fn uninstall_leaves_other_cli_path_alone() {
        let both = install(&install("{}", "/a/ln").unwrap(), "/b/ln").unwrap();
        let out = uninstall(&both, "/a/ln").unwrap();
        assert!(!is_installed(&out, "/a/ln"));
        assert!(is_installed(&out, "/b/ln"));
    }

    #[test]
    fn uninstall_is_idempotent_and_ok_without_hooks() {
        let once = uninstall(&install("{}", CLI).unwrap(), CLI).unwrap();
        assert_eq!(uninstall(&once, CLI).unwrap(), once);
        assert_eq!(val(&uninstall("", CLI).unwrap()), json!({}));
        assert_eq!(val(&uninstall(r#"{"a":1}"#, CLI).unwrap()), json!({"a":1}));
    }

    #[test]
    fn uninstall_keeps_pre_existing_empty_structures() {
        let src = r#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[]}],"Foo":"x","Bar":[{"matcher":"*"}]}}"#;
        let v = val(&uninstall(src, CLI).unwrap());
        assert_eq!(v, val(src));
    }

    #[test]
    fn uninstall_tolerates_non_object_hooks() {
        let v = val(&uninstall(r#"{"hooks":5}"#, CLI).unwrap());
        assert_eq!(v, json!({"hooks":5}));
    }

    #[test]
    fn uninstall_rejects_bad_roots() {
        assert_eq!(uninstall("[]", CLI), Err(InstallError::NotObject));
        assert!(matches!(
            uninstall("{", CLI),
            Err(InstallError::InvalidJson(_))
        ));
    }

    #[test]
    fn is_installed_false_for_partial_or_bad_input() {
        assert!(!is_installed("", CLI));
        assert!(!is_installed("garbage", CLI));
        assert!(!is_installed("[]", CLI));
        assert!(!is_installed(r#"{"hooks":3}"#, CLI));
        let mut v = val(&install("{}", CLI).unwrap());
        v["hooks"].as_object_mut().unwrap().remove("Notification");
        assert!(!is_installed(&v.to_string(), CLI));
        v["hooks"]["Notification"] = json!("x");
        assert!(!is_installed(&v.to_string(), CLI));
        assert!(!is_installed(&install("{}", "/a").unwrap(), "/b"));
    }

    #[test]
    fn error_display_is_readable() {
        assert!(InstallError::InvalidJson("e".into())
            .to_string()
            .contains('e'));
        assert!(InstallError::NotObject.to_string().contains("object"));
        assert!(InstallError::BadHooksShape.to_string().contains("hooks"));
        assert!(InstallError::EmptyCliPath.to_string().contains("empty"));
    }

    #[test]
    fn shell_metacharacters_in_the_install_path_are_taken_literally() {
        assert_eq!(
            command_for("/Apps/$HOME `id`/litenotch"),
            "'/Apps/$HOME `id`/litenotch' hook"
        );
        assert_eq!(
            command_for("/Apps/it's/litenotch"),
            "'/Apps/it'\\''s/litenotch' hook"
        );
        let out = install("{}", "/Apps/it's/litenotch").unwrap();
        assert!(is_installed(&out, "/Apps/it's/litenotch"));
    }
}
