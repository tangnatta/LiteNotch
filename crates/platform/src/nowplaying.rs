//! Runs the now-playing helper (`macos/NowPlayingHelper/nowplaying.m`).
//!
//! macOS only answers now-playing queries from processes with an Apple
//! entitlement, and `/usr/bin/perl` is one. The helper library is therefore
//! loaded into perl; this module starts that process and reads its output.

use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::JoinHandle;
use std::time::Duration;

const PERL: &str = "/usr/bin/perl";
/// Loads the library named by the first argument and calls the entry point
/// chosen by the second.
const LOADER: &str = r#"use DynaLoader;
my ($lib, $mode) = @ARGV;
my $handle = DynaLoader::dl_load_file($lib, 0) or exit 3;
my $name = $mode eq "send" ? "ln_np_send" : "ln_np_stream";
my $symbol = DynaLoader::dl_find_symbol($handle, $name) or exit 4;
DynaLoader::dl_install_xsub("main::run", $symbol);
main::run();
"#;
/// A line from the helper is a few hundred bytes; anything huge is dropped.
const MAX_LINE_BYTES: usize = 16 * 1024;

fn perl(lib: &Path, mode: &str) -> Command {
    let mut command = Command::new(PERL);
    // A clean environment: PERL5OPT / PERL5LIB from the user's session must
    // not change what perl loads.
    command
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .arg("-e")
        .arg(LOADER)
        .arg(lib)
        .arg(mode)
        .stdin(Stdio::null())
        .stderr(Stdio::null());
    command
}

/// The running helper. Dropping it stops the process.
pub struct NowPlayingStream {
    child: Child,
    reader: Option<JoinHandle<()>>,
}

impl NowPlayingStream {
    /// Starts the helper; `sink` receives each line it prints, on another
    /// thread. Artwork files are written into `artwork_dir`.
    pub fn start(
        lib: &Path,
        artwork_dir: &Path,
        sink: impl Fn(String) + Send + 'static,
    ) -> std::io::Result<NowPlayingStream> {
        Self::spawn(
            perl(lib, "stream").env("LN_NP_ARTWORK_DIR", artwork_dir),
            sink,
        )
    }

    fn spawn(
        command: &mut Command,
        sink: impl Fn(String) + Send + 'static,
    ) -> std::io::Result<NowPlayingStream> {
        let mut child = command.stdout(Stdio::piped()).spawn()?;
        let Some(stdout) = child.stdout.take() else {
            let _ = child.kill();
            let _ = child.wait();
            return Err(std::io::Error::other("no stdout"));
        };
        let reader = std::thread::Builder::new()
            .name("litenotch-nowplaying".into())
            .spawn(move || {
                let mut lines = BufReader::new(stdout);
                let mut line = Vec::new();
                loop {
                    line.clear();
                    // Never hold more than a line's limit in memory: a web
                    // page chooses its own media title.
                    let read = (&mut lines)
                        .take(MAX_LINE_BYTES as u64 + 1)
                        .read_until(b'\n', &mut line);
                    match read {
                        Ok(0) | Err(_) => break,
                        Ok(_) if line.len() > MAX_LINE_BYTES => {
                            // Too long: drop the rest of it, then go on.
                            if line.last() != Some(&b'\n')
                                && lines.skip_until(b'\n').map_or(true, |n| n == 0)
                            {
                                break;
                            }
                        }
                        Ok(_) => {
                            if let Ok(text) = std::str::from_utf8(&line) {
                                sink(text.trim_end().to_string());
                            }
                        }
                    }
                }
            });
        let reader = match reader {
            Ok(reader) => reader,
            Err(e) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(e);
            }
        };
        Ok(NowPlayingStream {
            child,
            reader: Some(reader),
        })
    }
}

impl Drop for NowPlayingStream {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        // The pipe is closed now, so the reader sees end of file.
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

/// Sends a transport command (2 toggle, 4 next, 5 previous) to whatever is
/// playing. Returns at once; the short-lived process runs in the background.
pub fn send_command(lib: &Path, code: u32) {
    let lib: PathBuf = lib.to_path_buf();
    let _ = std::thread::Builder::new()
        .name("litenotch-media".into())
        .spawn(move || {
            let Ok(mut child) = perl(&lib, "send")
                .env("LN_NP_COMMAND", code.to_string())
                .stdout(Stdio::null())
                .spawn()
            else {
                return;
            };
            // The helper exits by itself well within this.
            for _ in 0..100 {
                if matches!(child.try_wait(), Ok(Some(_)) | Err(_)) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(30));
            }
            let _ = child.kill();
            let _ = child.wait();
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    fn shell(script: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command.arg("-c").arg(script).stdin(Stdio::null());
        command
    }

    #[test]
    fn lines_are_delivered_and_oversized_ones_dropped() {
        let (tx, rx) = mpsc::channel();
        let script = format!(
            // `exec`, so the shell becomes `sleep`: a child `sleep` would
            // keep the pipe open after the shell is killed (the real helper
            // is a single perl process).
            "echo one; printf '%s\\n' \"$(head -c {} /dev/zero | tr '\\0' x)\"; echo two; exec sleep 30",
            MAX_LINE_BYTES + 10
        );
        let stream = NowPlayingStream::spawn(&mut shell(&script), move |line| {
            let _ = tx.send(line);
        })
        .unwrap();
        let wait = Duration::from_secs(5);
        assert_eq!(rx.recv_timeout(wait).unwrap(), "one");
        assert_eq!(rx.recv_timeout(wait).unwrap(), "two");
        // Dropping stops the process (it would otherwise sleep for 30 s) and
        // ends the reader, which closes the channel.
        let started = std::time::Instant::now();
        drop(stream);
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(rx.recv_timeout(wait).is_err());
    }

    #[test]
    fn a_helper_that_exits_just_ends_the_stream() {
        let (tx, rx) = mpsc::channel();
        let stream = NowPlayingStream::spawn(&mut shell("echo only"), move |line| {
            let _ = tx.send(line);
        })
        .unwrap();
        assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), "only");
        assert!(rx.recv_timeout(Duration::from_secs(5)).is_err());
        drop(stream);
    }

    #[test]
    fn a_missing_program_is_an_error() {
        let mut command = Command::new("/nonexistent/litenotch-helper");
        assert!(NowPlayingStream::spawn(&mut command, |_| {}).is_err());
    }

    #[test]
    fn the_loader_is_started_with_the_library_and_mode() {
        let command = perl(Path::new("/x/lib.dylib"), "stream");
        let args: Vec<_> = command
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert_eq!(command.get_program(), PERL);
        assert_eq!(args[0], "-e");
        assert!(args[1].contains("ln_np_stream") && args[1].contains("ln_np_send"));
        assert_eq!(&args[2..], ["/x/lib.dylib", "stream"]);
    }

    #[test]
    fn sending_with_a_missing_library_does_not_hang_or_panic() {
        send_command(Path::new("/nonexistent/lib.dylib"), 2);
    }
}
