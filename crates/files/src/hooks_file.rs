//! Registers and removes the LiteNotch hooks in Claude Code's user settings
//! file. The JSON editing itself is pure and lives in the core; this module
//! does the file I/O and keeps a backup of the file as it was.

use std::fs;
use std::path::{Path, PathBuf};

use litenotch_core::agent::statusline::{
    install_statusline, is_statusline_installed, uninstall_statusline,
};
use litenotch_core::agent::{install, is_installed, uninstall};

pub const BACKUP_SUFFIX: &str = "litenotch-backup";

#[derive(Debug, PartialEq, Eq)]
pub enum HooksFileError {
    Io(String),
    Settings(String),
}

impl std::fmt::Display for HooksFileError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HooksFileError::Io(e) => write!(f, "could not update Claude Code settings: {e}"),
            HooksFileError::Settings(e) => write!(f, "Claude Code settings are not usable: {e}"),
        }
    }
}

impl std::error::Error for HooksFileError {}

pub fn settings_path(claude_dir: &Path) -> PathBuf {
    claude_dir.join("settings.json")
}

fn read(claude_dir: &Path) -> Result<String, HooksFileError> {
    match fs::read_to_string(settings_path(claude_dir)) {
        Ok(text) => Ok(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(HooksFileError::Io(e.to_string())),
    }
}

/// `None` when the settings file cannot be read.
pub fn installed(claude_dir: &Path, cli_path: &str) -> Option<bool> {
    read(claude_dir)
        .ok()
        .map(|text| is_installed(&text, cli_path))
}

pub fn install_hooks(claude_dir: &Path, cli_path: &str) -> Result<(), HooksFileError> {
    rewrite(claude_dir, |text| {
        install(text, cli_path).map_err(|e| e.to_string())
    })
}

pub fn uninstall_hooks(claude_dir: &Path, cli_path: &str) -> Result<(), HooksFileError> {
    rewrite(claude_dir, |text| {
        uninstall(text, cli_path).map_err(|e| e.to_string())
    })
}

/// Whether Claude Code's status line goes through LiteNotch (usage limits).
pub fn statusline_installed(claude_dir: &Path, cli_path: &str) -> Option<bool> {
    read(claude_dir)
        .ok()
        .map(|text| is_statusline_installed(&text, cli_path))
}

pub fn install_statusline_file(claude_dir: &Path, cli_path: &str) -> Result<(), HooksFileError> {
    rewrite(claude_dir, |text| {
        install_statusline(text, cli_path).map_err(|e| e.to_string())
    })
}

pub fn uninstall_statusline_file(claude_dir: &Path, cli_path: &str) -> Result<(), HooksFileError> {
    rewrite(claude_dir, |text| {
        uninstall_statusline(text, cli_path).map_err(|e| e.to_string())
    })
}

fn rewrite(
    claude_dir: &Path,
    edit: impl FnOnce(&str) -> Result<String, String>,
) -> Result<(), HooksFileError> {
    let before = read(claude_dir)?;
    let after = edit(&before).map_err(HooksFileError::Settings)?;
    // Compare as JSON so a no-op edit never rewrites (or creates) the file.
    let parse = |text: &str| {
        serde_json::from_str::<serde_json::Value>(if text.trim().is_empty() { "{}" } else { text })
            .ok()
    };
    if parse(&before) == parse(&after) {
        return Ok(());
    }
    let io = |e: std::io::Error| HooksFileError::Io(e.to_string());
    fs::create_dir_all(claude_dir).map_err(io)?;
    let path = settings_path(claude_dir);
    let backup = path.with_extension(format!("json.{BACKUP_SUFFIX}"));
    // Keep the first backup: it is the file from before LiteNotch touched it.
    // Settings can hold credentials, so the copy is private like the rest.
    if !before.is_empty() && !backup.exists() {
        crate::store::write_atomic(&backup, before.as_bytes()).map_err(io)?;
    }
    // Dotfile managers symlink this file; write to what the link points at
    // instead of replacing the link with a regular file.
    let target = fs::canonicalize(&path).unwrap_or(path);
    crate::store::write_atomic(&target, after.as_bytes()).map_err(io)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::temp_dir;

    const CLI: &str = "/Applications/LiteNotch.app/Contents/MacOS/litenotch";

    #[test]
    fn installs_into_a_missing_file_without_a_backup() {
        let dir = temp_dir("hooks-new").join("claude");
        assert_eq!(installed(&dir, CLI), Some(false));
        install_hooks(&dir, CLI).unwrap();
        assert_eq!(installed(&dir, CLI), Some(true));
        let text = fs::read_to_string(settings_path(&dir)).unwrap();
        assert!(text.contains("PermissionRequest"));
        assert!(!dir.join("settings.json.litenotch-backup").exists());
    }

    #[test]
    fn keeps_existing_settings_and_backs_up_the_original_once() {
        let dir = temp_dir("hooks-existing");
        let original = r#"{"model":"opus","hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"say done"}]}]}}"#;
        fs::write(settings_path(&dir), original).unwrap();
        install_hooks(&dir, CLI).unwrap();
        let text = fs::read_to_string(settings_path(&dir)).unwrap();
        assert!(text.contains("\"model\"") && text.contains("say done"));
        let backup = dir.join("settings.json.litenotch-backup");
        assert_eq!(fs::read_to_string(&backup).unwrap(), original);

        // Installing again changes nothing; uninstalling does not overwrite the backup.
        install_hooks(&dir, CLI).unwrap();
        assert_eq!(fs::read_to_string(settings_path(&dir)).unwrap(), text);
        uninstall_hooks(&dir, CLI).unwrap();
        assert_eq!(installed(&dir, CLI), Some(false));
        let after = fs::read_to_string(settings_path(&dir)).unwrap();
        assert!(after.contains("say done") && !after.contains("litenotch"));
        assert_eq!(fs::read_to_string(&backup).unwrap(), original);
    }

    #[test]
    fn the_backup_is_private_and_a_symlinked_settings_file_stays_a_symlink() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir("hooks-symlink");
        let real = dir.join("dotfiles-settings.json");
        fs::write(&real, r#"{"env":{"TOKEN":"secret"}}"#).unwrap();
        std::os::unix::fs::symlink(&real, settings_path(&dir)).unwrap();
        install_hooks(&dir, CLI).unwrap();
        assert!(fs::symlink_metadata(settings_path(&dir))
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(fs::read_to_string(&real)
            .unwrap()
            .contains("PermissionRequest"));
        let backup = dir.join("settings.json.litenotch-backup");
        assert_eq!(
            fs::metadata(&backup).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert!(fs::read_to_string(&backup).unwrap().contains("secret"));
    }

    #[test]
    fn refuses_settings_that_are_not_a_json_object() {
        let dir = temp_dir("hooks-bad");
        fs::write(settings_path(&dir), "[1,2]").unwrap();
        let err = install_hooks(&dir, CLI).unwrap_err();
        assert!(matches!(err, HooksFileError::Settings(_)));
        assert!(err.to_string().contains("not usable"));
        assert_eq!(
            fs::read_to_string(settings_path(&dir)).unwrap(),
            "[1,2]",
            "file is untouched"
        );
    }

    #[test]
    fn unreadable_settings_report_unknown() {
        let dir = temp_dir("hooks-unreadable");
        fs::create_dir_all(settings_path(&dir)).unwrap();
        assert_eq!(installed(&dir, CLI), None);
        let err = install_hooks(&dir, CLI).unwrap_err();
        assert!(matches!(err, HooksFileError::Io(_)));
        assert!(err.to_string().contains("could not update"));
    }

    #[test]
    fn uninstalling_when_nothing_is_installed_does_not_create_a_file() {
        let dir = temp_dir("hooks-none").join("claude");
        uninstall_hooks(&dir, CLI).unwrap();
        assert!(!settings_path(&dir).exists());
    }
}
