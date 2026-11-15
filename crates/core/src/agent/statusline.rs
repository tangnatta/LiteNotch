//! Pure JSON editing of Claude Code's `statusLine` setting, so usage limits
//! reach LiteNotch (`litenotch statusline` reads them from the status line
//! JSON and prints the status text).
//!
//! A status line the user already has is kept: its command is wrapped
//! (`'<cli>' statusline -- /bin/sh -c '<their command>'`), so it keeps
//! printing what it printed before. Other keys of the object (padding, …)
//! are left alone. Removing it restores their command exactly.

use serde_json::{json, Map, Value};

use super::install::{is_litenotch_cli, leading_quoted, InstallError};

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

/// One layer of LiteNotch around a status line: whose it is, and the command
/// underneath (`None` when LiteNotch is all there is). `None` for a command
/// that is not LiteNotch's.
fn layer(command: &str) -> Option<(String, Option<String>)> {
    let (cli, rest) = leading_quoted(command)?;
    if !is_litenotch_cli(&cli) {
        return None;
    }
    if rest == " statusline" {
        return Some((cli, None));
    }
    let inner = unquote(rest.strip_prefix(WRAP)?)?;
    Some((cli, Some(inner)))
}

/// `command` with every LiteNotch layer taken off: the user's own status
/// line (`None` if there is none), and the copies of LiteNotch that were
/// around it, outermost first. Each copy that was ever connected used to
/// wrap the one before, so there can be several.
fn unwrapped(command: &str) -> (Option<String>, Vec<String>) {
    let mut layers = Vec::new();
    let mut current = command.to_owned();
    // The depth is bounded by the length of the text; the limit only makes
    // that obvious.
    for _ in 0..64 {
        match layer(&current) {
            Some((cli, Some(inner))) => {
                layers.push(cli);
                current = inner;
            }
            Some((cli, None)) => {
                layers.push(cli);
                return (None, layers);
            }
            None => break,
        }
    }
    (Some(current).filter(|c| !c.trim().is_empty()), layers)
}

/// Other copies of LiteNotch the status line passes through, each once,
/// sorted.
pub fn other_statusline_clis(settings_json: &str, cli_path: &str) -> Vec<String> {
    let Ok(root) = parse_root(settings_json) else {
        return Vec::new();
    };
    let layers = current_command(&root)
        .map(|c| unwrapped(c).1)
        .unwrap_or_default();
    let found: std::collections::BTreeSet<String> =
        layers.into_iter().filter(|cli| cli != cli_path).collect();
    found.into_iter().collect()
}

/// Takes other copies of LiteNotch out of the status line. If this copy is
/// in it, it then wraps the user's own command directly; if not, the user's
/// own command is restored (or the status line removed when LiteNotch was
/// all there was). Idempotent.
pub fn remove_other_statuslines(
    settings_json: &str,
    cli_path: &str,
) -> Result<String, InstallError> {
    let mut root = parse_root(settings_json)?;
    let Some(command) = current_command(&root).map(str::to_owned) else {
        return Ok(render(root));
    };
    let (theirs, layers) = unwrapped(&command);
    if !layers.iter().any(|cli| cli != cli_path) {
        return Ok(render(root));
    }
    let keep_ours = layers.iter().any(|cli| cli == cli_path);
    let replacement = match (keep_ours, theirs) {
        (true, Some(theirs)) => Some(format!("{}{WRAP}{}", quote(cli_path), quote(&theirs))),
        (true, None) => Some(ours(cli_path)),
        (false, theirs) => theirs,
    };
    match replacement {
        Some(command) => {
            if let Some(Value::Object(line)) = root.get_mut("statusLine") {
                line.insert("command".into(), json!(command));
            }
        }
        None => {
            root.remove("statusLine");
        }
    }
    Ok(render(root))
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
    // Wrap the user's own command, never another copy of LiteNotch: a copy
    // connected earlier is taken out, not wrapped again.
    let theirs = current_command(&root).and_then(|c| unwrapped(c).0);
    match root.get_mut("statusLine") {
        Some(Value::Object(line)) => {
            let command = match theirs {
                Some(theirs) => format!("{}{WRAP}{}", quote(cli_path), quote(&theirs)),
                None => ours(cli_path),
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
    if !command.starts_with(&ours(cli_path)) {
        return Ok(render(root));
    }
    // Back to the user's own command, not to an older copy of LiteNotch
    // that this one may have been wrapped around.
    match unwrapped(&command).0 {
        Some(theirs) => {
            if let Some(Value::Object(line)) = root.get_mut("statusLine") {
                line.insert("command".into(), json!(theirs));
            }
        }
        None => {
            root.remove("statusLine");
        }
    }
    Ok(render(root))
}

#[cfg(test)]
mod tests {
    use super::*;

    const CLI: &str = "/Applications/LiteNotch.app/Contents/Helpers/litenotch";

    const OLD: &str = "/Users/me/Downloads/LiteNotch-old.app/Contents/Helpers/litenotch";
    const DEV: &str = "/Users/me/it's here/LiteNotch.app/Contents/Helpers/litenotch";

    fn command(settings: &str) -> String {
        line(settings)["command"].as_str().unwrap().to_owned()
    }

    fn wrapping(cli: &str, theirs: &str) -> String {
        format!("{}{WRAP}{}", quote(cli), quote(theirs))
    }

    /// Reported together with the duplicated hooks: each copy of LiteNotch
    /// wrapped the status line of the copy before it, several layers deep.
    #[test]
    fn connecting_wraps_the_users_own_command_not_another_copy() {
        let theirs = r#"{"statusLine":{"type":"command","command":"echo 'hi there'","padding":1}}"#;
        let one = install_statusline(theirs, OLD).unwrap();
        let two = install_statusline(&one, DEV).unwrap();
        let three = install_statusline(&two, CLI).unwrap();
        assert_eq!(command(&three), wrapping(CLI, "echo 'hi there'"));
        assert_eq!(line(&three)["padding"], 1);
        assert!(other_statusline_clis(&three, CLI).is_empty());
        assert_eq!(
            install_statusline(&three, CLI).unwrap(),
            three,
            "idempotent"
        );
        // Turning it off gives back exactly what the user had.
        let back = uninstall_statusline(&three, CLI).unwrap();
        assert_eq!(command(&back), "echo 'hi there'");
    }

    /// The layers an older version left behind, built the way it built them.
    fn nested(theirs: Option<&str>, clis: &[&str]) -> String {
        let mut command = theirs.map(str::to_owned);
        for cli in clis {
            command = Some(match command {
                Some(inner) => wrapping(cli, &inner),
                None => ours(cli),
            });
        }
        json!({"statusLine": {"type": "command", "command": command}}).to_string()
    }

    #[test]
    fn layers_left_by_older_versions_are_found_and_flattened() {
        let deep = nested(Some("echo 'hi'"), &[OLD, DEV, CLI]);
        assert_eq!(other_statusline_clis(&deep, CLI), [OLD, DEV]);
        assert!(is_statusline_installed(&deep, CLI));
        let flat = remove_other_statuslines(&deep, CLI).unwrap();
        assert_eq!(command(&flat), wrapping(CLI, "echo 'hi'"));
        assert_eq!(
            remove_other_statuslines(&flat, CLI).unwrap(),
            flat,
            "idempotent"
        );

        // This copy is not in it: the user's own command comes back.
        let others = nested(Some("echo 'hi'"), &[OLD, DEV]);
        assert_eq!(other_statusline_clis(&others, CLI).len(), 2);
        let restored = remove_other_statuslines(&others, CLI).unwrap();
        assert_eq!(command(&restored), "echo 'hi'");

        // LiteNotch was all there was: nothing is left behind.
        let only = nested(None, &[OLD, DEV]);
        let gone = remove_other_statuslines(&only, CLI).unwrap();
        assert!(serde_json::from_str::<Value>(&gone)
            .unwrap()
            .get("statusLine")
            .is_none());
        let ours_on_top = nested(None, &[OLD, CLI]);
        let kept = remove_other_statuslines(&ours_on_top, CLI).unwrap();
        assert_eq!(command(&kept), ours(CLI));

        // Uninstalling from a deep stack restores the user's command, not
        // an older copy of LiteNotch.
        assert_eq!(
            command(&uninstall_statusline(&deep, CLI).unwrap()),
            "echo 'hi'"
        );
    }

    #[test]
    fn a_status_line_that_is_not_litenotchs_is_left_alone() {
        for theirs in [
            "echo hi",
            "'/usr/bin/starship' statusline",
            "'/a/litenotch' something else",
            "'/a/litenotch' statusline -- /bin/sh -c not-quoted",
        ] {
            let settings =
                json!({"statusLine": {"type": "command", "command": theirs}}).to_string();
            assert!(other_statusline_clis(&settings, CLI).is_empty(), "{theirs}");
            let same = remove_other_statuslines(&settings, CLI).unwrap();
            assert_eq!(command(&same), theirs);
        }
        assert!(other_statusline_clis("{}", CLI).is_empty());
        assert!(other_statusline_clis("not json", CLI).is_empty());
    }

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
