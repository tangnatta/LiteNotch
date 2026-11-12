//! Saved state: one JSON file, written atomically and readable only by the user.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use litenotch_core::state::Persisted;

pub const STATE_FILE: &str = "state.json";

pub fn state_path(dir: &Path) -> PathBuf {
    dir.join(STATE_FILE)
}

/// Creates the data directory, private to the user.
pub fn ensure_dir(dir: &Path) -> std::io::Result<()> {
    fs::create_dir_all(dir)?;
    set_mode(dir, 0o700)
}

/// Loads saved state. A missing file gives defaults; an unreadable one is
/// moved aside (so it can be inspected) and also gives defaults.
pub fn load(dir: &Path) -> Persisted {
    let path = state_path(dir);
    let Ok(text) = fs::read_to_string(&path) else {
        return Persisted::default();
    };
    match serde_json::from_str(&text) {
        Ok(saved) => saved,
        Err(_) => {
            let _ = fs::rename(&path, dir.join(format!("{STATE_FILE}.corrupt")));
            Persisted::default()
        }
    }
}

pub fn save(dir: &Path, state: &Persisted) -> std::io::Result<()> {
    let json = serde_json::to_vec_pretty(state)?;
    write_atomic(&state_path(dir), &json)
}

/// Writes `bytes` to a temporary file beside `path` and renames it into
/// place, so a crash never leaves a half-written file.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    let result = (|| {
        let mut file = open_private(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

#[cfg(unix)]
fn open_private(path: &Path) -> std::io::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)
}

#[cfg(not(unix))]
fn open_private(path: &Path) -> std::io::Result<fs::File> {
    fs::File::create(path)
}

#[cfg(unix)]
pub fn set_mode(path: &Path, mode: u32) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode))
}

#[cfg(not(unix))]
pub fn set_mode(_path: &Path, _mode: u32) -> std::io::Result<()> {
    Ok(())
}

/// A fresh, empty directory for a test. The path is short because Unix
/// socket paths are limited to about 100 bytes.
pub fn temp_dir(name: &str) -> PathBuf {
    use std::sync::atomic::{AtomicU32, Ordering};
    static NEXT: AtomicU32 = AtomicU32::new(0);
    let dir = PathBuf::from(format!(
        "/tmp/ln-{}-{}-{}",
        name,
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = fs::remove_dir_all(&dir);
    let _ = fs::create_dir_all(&dir);
    dir
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn missing_file_gives_defaults() {
        let dir = temp_dir("store-missing");
        assert_eq!(load(&dir), Persisted::default());
    }

    #[test]
    fn save_then_load_round_trips_and_is_private() {
        let dir = temp_dir("store-rt");
        ensure_dir(&dir).unwrap();
        let mut state = Persisted::default();
        state.settings.pomodoro.focus_secs = 900;
        state.version = 1;
        save(&dir, &state).unwrap();
        assert_eq!(load(&dir), state);
        let file_mode = fs::metadata(state_path(&dir)).unwrap().permissions().mode() & 0o777;
        assert_eq!(file_mode, 0o600);
        let dir_mode = fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700);
        let leftovers: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name())
            .collect();
        assert_eq!(
            leftovers,
            [std::ffi::OsString::from(STATE_FILE)],
            "no temp file remains"
        );
    }

    #[test]
    fn corrupt_file_is_moved_aside() {
        let dir = temp_dir("store-corrupt");
        fs::write(state_path(&dir), b"{ not json").unwrap();
        assert_eq!(load(&dir), Persisted::default());
        assert!(!state_path(&dir).exists());
        assert_eq!(
            fs::read(dir.join("state.json.corrupt")).unwrap(),
            b"{ not json"
        );
    }

    #[test]
    fn saving_over_an_existing_file_replaces_it() {
        let dir = temp_dir("store-replace");
        save(&dir, &Persisted::default()).unwrap();
        let mut state = Persisted::default();
        state.settings.general.hover_to_expand = false;
        save(&dir, &state).unwrap();
        assert!(!load(&dir).settings.general.hover_to_expand);
    }

    #[test]
    fn a_failed_write_reports_the_error_and_leaves_no_temp_file() {
        let dir = temp_dir("store-fail");
        let target = dir.join("missing-subdir").join("state.json");
        assert!(write_atomic(&target, b"x").is_err());
        // Renaming onto a directory fails after the temp file was written.
        let blocked = dir.join("blocked");
        fs::create_dir_all(blocked.join("child")).unwrap();
        assert!(write_atomic(&blocked, b"x").is_err());
        let names: Vec<String> = fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, ["blocked"], "{names:?}");
    }
}
