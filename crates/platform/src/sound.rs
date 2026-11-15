//! Plays one of the system's alert sounds.
//!
//! `afplay` is started and left to finish by itself: the sounds are a second
//! or two long, and nothing waits for them.

use std::path::PathBuf;
use std::process::{Command, Stdio};

const SOUND_DIR: &str = "/System/Library/Sounds";
const PLAYER: &str = "/usr/bin/afplay";

/// The file for a sound name, if the name is a plain word (letters only), so
/// that nothing but a file directly inside the system's sound folder can be
/// named.
pub fn sound_path(name: &str) -> Option<PathBuf> {
    let plain =
        !name.is_empty() && name.len() <= 32 && name.chars().all(|c| c.is_ascii_alphabetic());
    plain.then(|| PathBuf::from(SOUND_DIR).join(format!("{name}.aiff")))
}

/// Starts playing `name`; does nothing if there is no such sound.
pub fn play(name: &str) {
    let Some(path) = sound_path(name).filter(|p| p.is_file()) else {
        return;
    };
    let child = Command::new(PLAYER)
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    if let Ok(mut child) = child {
        // Collect the exit status so the finished player does not linger.
        std::thread::spawn(move || {
            let _ = child.wait();
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_plain_name_becomes_a_path_in_the_sound_folder() {
        assert_eq!(
            sound_path("Glass"),
            Some(PathBuf::from("/System/Library/Sounds/Glass.aiff"))
        );
        for bad in [
            "",
            "../Glass",
            "Glass.aiff",
            "a/b",
            "Glass ",
            "Gläss",
            "x;y",
            &"a".repeat(33),
        ] {
            assert_eq!(sound_path(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn a_sound_that_does_not_exist_is_not_played() {
        // Returns without starting anything; there is nothing to observe
        // but that it does not panic or block.
        play("NoSuchSoundAnywhere");
        play("../../etc/passwd");
    }
}
