//! Now-playing tracking for whatever macOS reports as the current media
//! (any app: a music player, a browser tab, a video).
//!
//! Pure state: the runtime feeds in the lines printed by the now-playing
//! helper and sends the transport commands this module asks for.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent::hooks::truncate_chars;
use crate::agent::sanitize;

const TEXT_CHARS: usize = 200;
const APP_CHARS: usize = 60;
const PATH_CHARS: usize = 1024;

/// What is currently playing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct NowPlaying {
    pub app: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub playing: bool,
    pub duration_ms: Option<u64>,
    /// Position at `updated_ms`; extrapolated by [`Media::snapshot`].
    pub position_ms: Option<u64>,
    pub updated_ms: u64,
    /// Image file written by the helper; replaced when the artwork changes.
    pub artwork_path: Option<String>,
}

/// Transport command sent to the playing app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaCommand {
    PlayPause,
    Next,
    Previous,
}

impl MediaCommand {
    /// The system's command number, as the helper expects it.
    pub fn code(self) -> u32 {
        match self {
            MediaCommand::PlayPause => 2,
            MediaCommand::Next => 4,
            MediaCommand::Previous => 5,
        }
    }
}

/// View-model of the active track at a given instant.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MediaSnapshot {
    pub app: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub playing: bool,
    pub duration_ms: Option<u64>,
    pub position_ms: Option<u64>,
    /// 0.0..=1.0 when both position and a non-zero duration are known.
    pub progress: Option<f32>,
}

/// Holds the latest now-playing state.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
pub struct Media {
    current: Option<NowPlaying>,
}

impl Media {
    /// Creates an empty tracker.
    pub fn new() -> Self {
        Self::default()
    }

    /// Replaces the state; `None` means nothing is playing.
    pub fn set(&mut self, np: Option<NowPlaying>) {
        self.current = np;
    }

    pub fn active(&self) -> Option<&NowPlaying> {
        self.current.as_ref()
    }

    /// Active track with position extrapolated to `now` while playing.
    pub fn snapshot(&self, now: u64) -> Option<MediaSnapshot> {
        let n = self.active()?;
        let mut position = n.position_ms;
        if n.playing {
            // Saturating: a clock that went backwards adds nothing.
            position = position.map(|p| p.saturating_add(now.saturating_sub(n.updated_ms)));
        }
        if let (Some(p), Some(d)) = (position, n.duration_ms) {
            position = Some(p.min(d));
        }
        let progress = match (position, n.duration_ms) {
            (Some(p), Some(d)) if d > 0 => Some((p as f64 / d as f64).clamp(0.0, 1.0) as f32),
            _ => None,
        };
        Some(MediaSnapshot {
            app: n.app.clone(),
            title: n.title.clone(),
            artist: n.artist.clone(),
            album: n.album.clone(),
            playing: n.playing,
            duration_ms: n.duration_ms,
            position_ms: position,
            progress,
        })
    }
}

/// Parses one line from the now-playing helper.
///
/// `None`: the line is not usable and the current state should be kept.
/// `Some(None)`: nothing is playing. `Some(Some(_))`: the new state.
///
/// Text comes from other apps (a web page can set its own title), so it is
/// sanitized and capped here.
pub fn parse_helper_line(line: &str, now: u64) -> Option<Option<NowPlaying>> {
    let v: Value = serde_json::from_str(line).ok()?;
    let object = v.as_object()?;
    if object.get("stopped").and_then(Value::as_bool) == Some(true) {
        return Some(None);
    }
    let text = |key: &str, max: usize| {
        object
            .get(key)
            .and_then(Value::as_str)
            .map(|s| sanitize(s).replace(['\n', '\r', '\t'], " "))
            .map(|s| truncate_chars(s.trim(), max))
            .unwrap_or_default()
    };
    let title = text("title", TEXT_CHARS);
    if title.is_empty() {
        return Some(None);
    }
    let number = |key: &str| {
        object
            .get(key)
            .and_then(Value::as_f64)
            .filter(|n| n.is_finite() && *n >= 0.0)
            .map(|n| n as u64)
    };
    let playing = object
        .get("playing")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let duration_ms = number("duration_ms").filter(|d| *d > 0);
    // The position was measured at `timestamp_ms`; bring it forward to now.
    let position_ms = number("elapsed_ms").map(|elapsed| {
        let since = match number("timestamp_ms") {
            Some(at) if playing => now.saturating_sub(at),
            _ => 0,
        };
        let position = elapsed.saturating_add(since);
        duration_ms.map_or(position, |d| position.min(d))
    });
    let artwork_path = object
        .get("artwork_path")
        .and_then(Value::as_str)
        .filter(|p| !p.is_empty() && p.chars().count() <= PATH_CHARS)
        .map(str::to_owned);
    let app = text("app", APP_CHARS);
    Some(Some(NowPlaying {
        app,
        title,
        artist: text("artist", TEXT_CHARS),
        album: text("album", TEXT_CHARS),
        playing,
        duration_ms,
        position_ms,
        updated_ms: now,
        artwork_path,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_700_000_100_000;

    fn parse(json: &str) -> Option<Option<NowPlaying>> {
        parse_helper_line(json, NOW)
    }

    #[test]
    fn a_full_line_becomes_now_playing() {
        let np = parse(
            r#"{"album":"Blue","app":"Spotify","artist":"Joni","artwork_path":"/d/artwork/art-1",
                "duration_ms":200000,"elapsed_ms":5000,"pid":10,"playing":true,
                "timestamp_ms":1700000099000,"title":"River"}"#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(np.app, "Spotify");
        assert_eq!(np.title, "River");
        assert_eq!(np.artist, "Joni");
        assert_eq!(np.album, "Blue");
        assert!(np.playing);
        assert_eq!(np.duration_ms, Some(200_000));
        // One second passed between the measurement and now.
        assert_eq!(np.position_ms, Some(6_000));
        assert_eq!(np.updated_ms, NOW);
        assert_eq!(np.artwork_path.as_deref(), Some("/d/artwork/art-1"));
    }

    #[test]
    fn a_paused_track_does_not_advance() {
        let np = parse(
            r#"{"title":"T","playing":false,"elapsed_ms":5000,"timestamp_ms":1700000000000,"duration_ms":9000}"#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(np.position_ms, Some(5_000));
        assert!(!np.playing);
    }

    #[test]
    fn position_never_passes_the_duration() {
        let np = parse(
            r#"{"title":"T","playing":true,"elapsed_ms":8000,"timestamp_ms":1700000000000,"duration_ms":9000}"#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(np.position_ms, Some(9_000));
    }

    #[test]
    fn a_timestamp_in_the_future_adds_nothing() {
        let np =
            parse(r#"{"title":"T","playing":true,"elapsed_ms":8000,"timestamp_ms":1900000000000}"#)
                .unwrap()
                .unwrap();
        assert_eq!(np.position_ms, Some(8_000));
        assert_eq!(np.duration_ms, None);
    }

    #[test]
    fn stopped_and_untitled_mean_nothing_is_playing() {
        assert_eq!(parse(r#"{"stopped":true}"#), Some(None));
        assert_eq!(parse(r#"{"title":"  ","playing":true}"#), Some(None));
        assert_eq!(parse(r#"{"playing":true}"#), Some(None));
    }

    #[test]
    fn garbage_keeps_the_current_state() {
        assert_eq!(parse("not json"), None);
        assert_eq!(parse("[1,2]"), None);
        assert_eq!(parse(""), None);
    }

    #[test]
    fn text_from_other_apps_is_sanitized_and_capped() {
        let long = "x".repeat(500);
        let line = serde_json::json!({
            "title": format!("a\u{202e}b{long}"),
            "artist": "line\nbreak",
            "app": "y".repeat(100),
            "playing": true,
        })
        .to_string();
        let np = parse(&line).unwrap().unwrap();
        assert_eq!(np.title.chars().count(), TEXT_CHARS);
        assert!(!np.title.contains('\u{202e}'));
        assert!(!np.artist.contains('\n'));
        assert_eq!(np.app.chars().count(), APP_CHARS);
    }

    #[test]
    fn odd_numbers_and_paths_are_dropped() {
        let np = parse(
            r#"{"title":"T","duration_ms":-5,"elapsed_ms":"x","artwork_path":"","playing":"yes"}"#,
        )
        .unwrap()
        .unwrap();
        assert_eq!(np.duration_ms, None);
        assert_eq!(np.position_ms, None);
        assert_eq!(np.artwork_path, None);
        assert!(!np.playing);
        let long_path = format!(r#"{{"title":"T","artwork_path":"/{}"}}"#, "p".repeat(2000));
        assert_eq!(parse(&long_path).unwrap().unwrap().artwork_path, None);
        assert_eq!(
            parse(r#"{"title":"T","duration_ms":0}"#)
                .unwrap()
                .unwrap()
                .duration_ms,
            None
        );
    }

    #[test]
    fn snapshot_extrapolates_only_while_playing() {
        let mut m = Media::new();
        assert!(m.snapshot(NOW).is_none());
        m.set(Some(NowPlaying {
            title: "T".into(),
            playing: true,
            duration_ms: Some(10_000),
            position_ms: Some(2_000),
            updated_ms: NOW,
            ..NowPlaying::default()
        }));
        let s = m.snapshot(NOW + 3_000).unwrap();
        assert_eq!(s.position_ms, Some(5_000));
        assert_eq!(s.progress, Some(0.5));
        assert_eq!(m.snapshot(NOW + 60_000).unwrap().position_ms, Some(10_000));
        // A clock that went backwards adds nothing.
        assert_eq!(m.snapshot(NOW - 5_000).unwrap().position_ms, Some(2_000));

        m.set(Some(NowPlaying {
            title: "T".into(),
            playing: false,
            position_ms: Some(2_000),
            updated_ms: NOW,
            ..NowPlaying::default()
        }));
        let s = m.snapshot(NOW + 3_000).unwrap();
        assert_eq!(s.position_ms, Some(2_000));
        assert_eq!(s.progress, None);
        m.set(None);
        assert!(m.active().is_none());
    }

    #[test]
    fn command_codes_match_the_system_numbers() {
        assert_eq!(MediaCommand::PlayPause.code(), 2);
        assert_eq!(MediaCommand::Next.code(), 4);
        assert_eq!(MediaCommand::Previous.code(), 5);
    }
}
