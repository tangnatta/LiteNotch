//! The runtime's view of the operating system. The real implementation
//! calls into `litenotch-platform`; tests substitute a recording fake.

use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use litenotch_core::caffeine::{AwakeMode, PowerStatus};
use litenotch_core::clipboard::{ClipCapture, ClipKind};
use litenotch_platform::clipboard::{self as pasteboard, ImageFormat, RawClip, RawKind};
use litenotch_platform::lid::LidGuard;
use litenotch_platform::nowplaying::{self, NowPlayingStream};
use litenotch_platform::power::{Awake, PowerAssertion};
use litenotch_platform::{battery, display};

pub trait Ports: Send {
    fn set_assertion(&mut self, mode: AwakeMode);
    /// Starts the privileged closed-lid step; `done` is called from another
    /// thread once the user has answered the password prompt.
    fn enable_lid(&mut self, done: Box<dyn FnOnce(bool) + Send>);
    fn disable_lid(&mut self);
    fn write_clipboard(&mut self, text: &str);
    /// `Some`: start reporting what is playing, one helper line per call of
    /// the sink (from another thread). `None`: stop.
    fn now_playing(&mut self, sink: Option<Box<dyn Fn(String) + Send>>);
    /// Sends a transport command to whatever is playing.
    fn media_command(&mut self, code: u32);
    fn power(&mut self) -> Option<PowerStatus>;
    /// The new pasteboard content if it changed since the last call.
    fn poll_clipboard(&mut self) -> Option<ClipCapture>;
    /// Puts the image saved in `path` back on the pasteboard.
    fn write_clipboard_image(&mut self, path: &str);
    /// Deletes saved clipboard images other than `keep`.
    fn prune_clip_images(&mut self, keep: &[String]);
    /// `Some`: report the lid's state now and on every change, from another
    /// thread. `None`: stop.
    fn watch_lid(&mut self, sink: Option<Box<dyn Fn(display::Clamshell) + Send>>);
    fn sleep_display(&mut self);
}

pub fn capture_from(raw: RawClip) -> ClipCapture {
    ClipCapture {
        kind: match raw.kind {
            RawKind::Text => ClipKind::Text,
            RawKind::Files => ClipKind::Files,
            RawKind::Image => ClipKind::Image,
        },
        text: raw.text,
        source_app: raw.source_app,
        concealed: raw.concealed,
        image_path: None,
    }
}

/// Saves a copied image as `img-<hash>.<ext>` in `dir` (once per distinct
/// image) and returns the path.
pub fn save_clip_image(dir: &Path, bytes: &[u8], format: ImageFormat) -> Option<PathBuf> {
    let mut hasher = DefaultHasher::new();
    bytes.hash(&mut hasher);
    let path = dir.join(format!(
        "img-{:016x}.{}",
        hasher.finish(),
        format.extension()
    ));
    if !path.exists() {
        crate::store::ensure_dir(dir).ok()?;
        crate::store::write_atomic(&path, bytes).ok()?;
    }
    Some(path)
}

/// Deletes `img-*` files in `dir` that are not in `keep`.
pub fn prune_images(dir: &Path, keep: &[String]) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name();
        if name.to_string_lossy().starts_with("img-") && !keep.iter().any(|k| Path::new(k) == path)
        {
            let _ = std::fs::remove_file(&path);
        }
    }
}

#[derive(Default)]
struct LidShared {
    guard: Option<LidGuard>,
    /// A password prompt is open.
    in_flight: bool,
    /// What the core last asked for; a prompt answered after a cancel is dropped.
    wanted: bool,
}

pub struct MacPorts {
    assertion: PowerAssertion,
    last_change: i64,
    lid: Arc<Mutex<LidShared>>,
    /// The now-playing helper library, when the app bundle has one.
    now_playing_lib: Option<PathBuf>,
    artwork_dir: PathBuf,
    stream: Option<NowPlayingStream>,
    /// Where copied images are saved; empty means images are not kept.
    clips_dir: PathBuf,
    lid_watcher: Option<display::LidWatcher>,
}

impl Default for MacPorts {
    fn default() -> Self {
        Self::new()
    }
}

impl MacPorts {
    pub fn new() -> Self {
        litenotch_platform::lid::cleanup_stale();
        MacPorts {
            assertion: PowerAssertion::new(),
            // Start from the current count so what is already on the
            // pasteboard at launch is not recorded.
            last_change: pasteboard::change_count(),
            lid: Arc::default(),
            now_playing_lib: None,
            artwork_dir: PathBuf::new(),
            stream: None,
            clips_dir: PathBuf::new(),
            lid_watcher: None,
        }
    }

    /// For the app: the now-playing helper library, and the data directory
    /// that artwork and copied images are written under.
    pub fn for_app(now_playing_lib: Option<PathBuf>, data_dir: &Path) -> Self {
        MacPorts {
            now_playing_lib: now_playing_lib.filter(|path| path.is_file()),
            artwork_dir: crate::runtime::artwork_dir(data_dir),
            clips_dir: crate::runtime::clips_dir(data_dir),
            ..Self::new()
        }
    }

    /// Artwork files are replaced one at a time while running; whatever is
    /// left when the helper starts or stops is stale.
    fn clear_artwork(&self) {
        let Ok(entries) = std::fs::read_dir(&self.artwork_dir) else {
            return;
        };
        for entry in entries.flatten() {
            if entry.file_name().to_string_lossy().starts_with("art-") {
                let _ = std::fs::remove_file(entry.path());
            }
        }
    }
}

fn lock(lid: &Mutex<LidShared>) -> std::sync::MutexGuard<'_, LidShared> {
    lid.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl Ports for MacPorts {
    fn set_assertion(&mut self, mode: AwakeMode) {
        let _ = self.assertion.set(match mode {
            AwakeMode::Off => Awake::Off,
            AwakeMode::System => Awake::System,
            AwakeMode::Display => Awake::Display,
        });
    }

    fn enable_lid(&mut self, done: Box<dyn FnOnce(bool) + Send>) {
        let mut state = lock(&self.lid);
        state.wanted = true;
        if state.guard.is_some() {
            drop(state);
            done(true);
            return;
        }
        if state.in_flight {
            // The open prompt will report for this request too.
            return;
        }
        state.in_flight = true;
        drop(state);
        let lid = Arc::clone(&self.lid);
        std::thread::spawn(move || {
            let result = LidGuard::enable();
            let mut state = lock(&lid);
            state.in_flight = false;
            let ok = match result {
                Ok(guard) if state.wanted => {
                    state.guard = Some(guard);
                    true
                }
                // Cancelled while the prompt was open: dropping the guard reverts it.
                Ok(_) | Err(_) => false,
            };
            let wanted = state.wanted;
            drop(state);
            if wanted {
                done(ok);
            }
        });
    }

    fn disable_lid(&mut self) {
        let mut state = lock(&self.lid);
        state.wanted = false;
        state.guard = None;
    }

    fn write_clipboard(&mut self, text: &str) {
        pasteboard::write_text(text);
    }

    fn now_playing(&mut self, sink: Option<Box<dyn Fn(String) + Send>>) {
        let Some(sink) = sink else {
            self.stream = None;
            self.clear_artwork();
            return;
        };
        let Some(lib) = &self.now_playing_lib else {
            return;
        };
        if self.stream.is_some() || crate::store::ensure_dir(&self.artwork_dir).is_err() {
            return;
        }
        self.clear_artwork();
        self.stream = NowPlayingStream::start(lib, &self.artwork_dir, sink).ok();
    }

    fn media_command(&mut self, code: u32) {
        if let Some(lib) = &self.now_playing_lib {
            nowplaying::send_command(lib, code);
        }
    }

    fn power(&mut self) -> Option<PowerStatus> {
        battery::read().map(|p| PowerStatus {
            on_ac: p.on_ac,
            battery_pct: p.battery_pct,
        })
    }

    fn poll_clipboard(&mut self) -> Option<ClipCapture> {
        let count = pasteboard::change_count();
        if count == self.last_change {
            return None;
        }
        self.last_change = count;
        let mut capture = pasteboard::read().map(capture_from)?;
        if capture.kind == ClipKind::Image && !self.clips_dir.as_os_str().is_empty() {
            if let Some((bytes, format)) = pasteboard::read_image() {
                capture.text = pasteboard::describe_image(&bytes, format);
                capture.image_path = save_clip_image(&self.clips_dir, &bytes, format)
                    .map(|p| p.to_string_lossy().into_owned());
            }
        }
        Some(capture)
    }

    fn write_clipboard_image(&mut self, path: &str) {
        let path = Path::new(path);
        // Only files this app saved are read back.
        if path.parent() != Some(self.clips_dir.as_path()) {
            return;
        }
        let format = path
            .extension()
            .and_then(|e| e.to_str())
            .and_then(ImageFormat::from_extension);
        if let (Some(format), Ok(bytes)) = (format, std::fs::read(path)) {
            pasteboard::write_image(&bytes, format);
        }
    }

    fn watch_lid(&mut self, sink: Option<Box<dyn Fn(display::Clamshell) + Send>>) {
        self.lid_watcher = sink.and_then(display::LidWatcher::start);
    }

    fn sleep_display(&mut self) {
        std::thread::spawn(display::sleep_display);
    }

    fn prune_clip_images(&mut self, keep: &[String]) {
        if !self.clips_dir.as_os_str().is_empty() {
            prune_images(&self.clips_dir, keep);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_clips_map_to_core_captures() {
        for (raw, kind) in [
            (RawKind::Text, ClipKind::Text),
            (RawKind::Files, ClipKind::Files),
            (RawKind::Image, ClipKind::Image),
        ] {
            let capture = capture_from(RawClip {
                kind: raw,
                text: "t".into(),
                source_app: Some("App".into()),
                concealed: true,
            });
            assert_eq!(
                capture,
                ClipCapture {
                    kind,
                    text: "t".into(),
                    source_app: Some("App".into()),
                    concealed: true,
                    image_path: None,
                }
            );
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn mac_ports_hold_an_assertion_and_do_not_replay_the_existing_pasteboard() {
        let mut ports = MacPorts::default();
        // Whatever is on the pasteboard at launch is not reported. (Another
        // app copying during the test would legitimately produce a capture,
        // so only the immediate first poll is checked.)
        assert_eq!(ports.poll_clipboard(), None);
        ports.set_assertion(AwakeMode::System);
        assert_eq!(ports.assertion.mode(), Awake::System);
        ports.set_assertion(AwakeMode::Display);
        ports.set_assertion(AwakeMode::Off);
        assert_eq!(ports.assertion.mode(), Awake::Off);
        assert!(ports.power().is_some());
        // Disabling lid mode that was never enabled is harmless.
        ports.disable_lid();
        assert!(!lock(&ports.lid).wanted);
    }

    #[test]
    fn images_are_saved_once_and_unreferenced_ones_pruned() {
        let dir = crate::store::temp_dir("ports-img");
        let clips = dir.join("clips");
        let a = save_clip_image(&clips, b"aaa", ImageFormat::Png).unwrap();
        let again = save_clip_image(&clips, b"aaa", ImageFormat::Png).unwrap();
        let b = save_clip_image(&clips, b"bbb", ImageFormat::Tiff).unwrap();
        assert_eq!(a, again);
        assert_ne!(a, b);
        assert!(a.to_string_lossy().ends_with(".png") && b.to_string_lossy().ends_with(".tiff"));
        assert_eq!(std::fs::read(&a).unwrap(), b"aaa");
        std::fs::write(clips.join("other.txt"), "x").unwrap();
        prune_images(&clips, &[a.to_string_lossy().into_owned()]);
        assert!(a.exists() && !b.exists());
        assert!(
            clips.join("other.txt").exists(),
            "only img-* files are touched"
        );
        prune_images(&dir.join("missing"), &[]);
    }
}
