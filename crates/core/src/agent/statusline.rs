//! Pure JSON editing of Claude Code's `statusLine` setting, so usage limits
//! reach LiteNotch (`litenotch statusline` reads them from the status line
//! JSON and prints the status text).
//!
//! A status line the user already has is kept: its command is wrapped
//! (`'<cli>' statusline -- /bin/sh -c '<their command>'`), so it keeps
//! printing what it printed before. Other keys of the object (padding, …)
//! are left alone. Removing it restores their command exactly.

use serde_json::{json, Map, Value};

use super::install::InstallError;

const WRAP: &str = " statusline -- /bin/sh -c ";

fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Inverse of [`quote`] for a string it produced; `None` otherwise.
fn unquote(s: &str) -> Option<String> {
    let inner = s.strip_prefix('\'')?.strip_suffix('\'')?;
    let mut out = String::new();
    let mut rest = inner;
    while let Some(i) = rest.find('\'') {
        out.push_str(&rest[..i]);
        rest = rest[i..].strip_prefix("'\\''")?;
        out.push('\'');
    }
    out.push_str(rest);
    Some(out)
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
    serde_json::to_string_pretty(&Value::Object(root)).unwrap_or_else(|_| "{}".to_owned())
}

fn current_command(root: &Map<String, Value>) -> Option<&str> {
    root.get("statusLine")?.get("command")?.as_str()
}

/// What LiteNotch's own command starts with.
fn ours(cli_path: &str) -> String {
    format!("{} statusline", quote(cli_path))
}

/// True when the status line goes through LiteNotch.
pub fn is_statusline_installed(settings_json: &str, cli_path: &str) -> bool {
    let Ok(root) = parse_root(settings_json) else {
        return false;
    };
    current_command(&root).is_some_and(|c| c.starts_with(&ours(cli_path)))
}

/// Routes the status line through LiteNotch, keeping any existing one.
pub fn install_statusline(settings_json: &str, cli_path: &str) -> Result<String, InstallError> {
    if cli_path.is_empty() {
        return Err(InstallError::EmptyCliPath);
    }
    let mut root = parse_root(settings_json)?;
    if current_command(&root).is_some_and(|c| c.starts_with(&ours(cli_path))) {
        return Ok(render(root));
    }
    match root.get_mut("statusLine") {
        Some(Value::Object(line)) => {
            let command = match line.get("command").and_then(Value::as_str) {
                Some(theirs) if !theirs.trim().is_empty() => {
                    format!("{}{WRAP}{}", quote(cli_path), quote(theirs))
                }
                _ => ours(cli_path),
            };
            line.insert("type".into(), json!("command"));
            line.insert("command".into(), json!(command));
        }
        Some(_) => return Err(InstallError::BadHooksShape),
        None => {
            root.insert(
                "statusLine".into(),
                json!({"type": "command", "command": ours(cli_path)}),
            );
        }
    }
    Ok(render(root))
}

/// Undoes [`install_statusline`]: restores the wrapped command, or removes
/// the status line if LiteNotch added it. Anything else is left alone.
pub fn uninstall_statusline(settings_json: &str, cli_path: &str) -> Result<String, InstallError> {
    let mut root = parse_root(settings_json)?;
    let Some(command) = current_command(&root).map(str::to_owned) else {
        return Ok(render(root));
    };
    let wrapped_prefix = format!("{}{WRAP}", quote(cli_path));
    if let Some(theirs) = command.strip_prefix(&wrapped_prefix).and_then(unquote) {
        if let Some(Value::Object(line)) = root.get_mut("statusLine") {
            line.insert("command".into(), json!(theirs));
        }
    } else if command == ours(cli_path) {
        root.remove("statusLine");
    }
    Ok(render(root))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CLI: &str = "/Applications/LiteNotch.app/Contents/Helpers/litenotch";

    fn line(json: &str) -> Value {
        serde_json::from_str::<Value>(json).unwrap()["statusLine"].clone()
    }

    #[test]
    fn adds_a_status_line_when_there_is_none_and_removes_it_again() {
        let out = install_statusline("{\"model\":\"x\"}", CLI).unwrap();
        assert_eq!(
            line(&out),
            json!({"type":"command","command": format!("'{CLI}' statusline")})
        );
        assert!(is_statusline_installed(&out, CLI));
        let back = uninstall_statusline(&out, CLI).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&back).unwrap(),
            json!({"model":"x"})
        );
        assert!(!is_statusline_installed(&back, CLI));
        assert!(install_statusline("", CLI).is_ok());
    }

    #[test]
    fn an_existing_status_line_is_wrapped_and_restored_exactly() {
        let theirs = r#"bash -c 'echo "$(whoami)"' && printf '%s' it's"#;
        let settings =
            json!({"statusLine": {"type":"command","command": theirs, "padding": 2}}).to_string();
        let out = install_statusline(&settings, CLI).unwrap();
        let l = line(&out);
        assert_eq!(l["padding"], 2);
        let cmd = l["command"].as_str().unwrap();
        assert!(cmd.starts_with(&format!("'{CLI}' statusline -- /bin/sh -c '")));
        assert!(is_statusline_installed(&out, CLI));
        // Installing twice changes nothing.
        assert_eq!(install_statusline(&out, CLI).unwrap(), out);
        let back = uninstall_statusline(&out, CLI).unwrap();
        assert_eq!(
            line(&back),
            json!({"type":"command","command": theirs, "padding": 2})
        );
    }

    #[test]
    fn the_wrapped_command_runs_the_original_unchanged_in_a_shell() {
        let theirs = "printf '%s|%s' \"a b\" it\\'s";
        let settings = json!({"statusLine": {"type":"command","command": theirs}}).to_string();
        let cmd = line(&install_statusline(&settings, CLI).unwrap())["command"]
            .as_str()
            .unwrap()
            .to_owned();
        let quoted = cmd.split_once(" -- /bin/sh -c ").unwrap().1;
        // What the shell sees for the argument is exactly their command.
        let direct = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(theirs)
            .output()
            .unwrap();
        let via = std::process::Command::new("/bin/sh")
            .arg("-c")
            .arg(format!("/bin/sh -c {quoted}"))
            .output()
            .unwrap();
        assert_eq!(direct.stdout, via.stdout);
    }

    #[test]
    fn other_status_lines_and_bad_settings_are_left_alone() {
        let other = json!({"statusLine": {"type":"command","command":"my-line"}}).to_string();
        assert!(!is_statusline_installed(&other, CLI));
        let back = uninstall_statusline(&other, CLI).unwrap();
        assert_eq!(line(&back)["command"], "my-line");
        assert!(matches!(
            install_statusline("[1]", CLI),
            Err(InstallError::NotObject)
        ));
        assert!(matches!(
            install_statusline("{", CLI),
            Err(InstallError::InvalidJson(_))
        ));
        assert!(matches!(
            install_statusline(r#"{"statusLine":"x"}"#, CLI),
            Err(InstallError::BadHooksShape)
        ));
        assert!(matches!(
            install_statusline("{}", ""),
            Err(InstallError::EmptyCliPath)
        ));
        assert!(!is_statusline_installed("not json", CLI));
        // An object without a command just gets ours.
        let out = install_statusline(r#"{"statusLine":{"padding":1}}"#, CLI).unwrap();
        assert_eq!(line(&out)["command"], format!("'{CLI}' statusline"));
    }

    #[test]
    fn quoting_round_trips() {
        for s in ["plain", "it's", "''", "a'b'c", ""] {
            assert_eq!(unquote(&quote(s)).as_deref(), Some(s));
        }
        assert_eq!(unquote("no quotes"), None);
        assert_eq!(unquote("'bad'quote'"), None);
    }
}
