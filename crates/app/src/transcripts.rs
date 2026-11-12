//! Reads this week's token usage out of Claude Code's session transcripts
//! (`~/.claude/projects/<project>/<session>.jsonl`).
//!
//! The transcript format is internal to Claude Code and may change; lines
//! that do not look like an assistant message with usage are skipped, so a
//! format change degrades to "no token totals" rather than an error.
//! Files are read incrementally: each scan continues where the last stopped.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

pub use litenotch_core::usage::local_day_start_ms as day_start_ms;
use litenotch_core::usage::{parse_record_in, UsageRecord, HISTORY_DAYS};

/// Most bytes read from one file in one scan.
const MAX_BYTES_PER_FILE: u64 = 32 * 1024 * 1024;
/// Longest line considered. Usage lines are a few kilobytes.
const MAX_LINE_BYTES: usize = 256 * 1024;

pub struct TranscriptScanner {
    projects_dir: PathBuf,
    offsets: HashMap<PathBuf, u64>,
    day_start_ms: Option<u64>,
}

pub struct Scan {
    /// The day changed since the last scan: discard earlier totals first.
    pub reset: bool,
    /// Only the usage fields: a transcript line itself can be very large.
    pub records: Vec<UsageRecord>,
}

/// Reads one complete line into `line`, returning how many bytes it took
/// and whether it was kept. Lines longer than `MAX_LINE_BYTES` (transcripts
/// also hold whole API requests) are skipped without being held in memory.
/// `None` means there is no complete line left; nothing is consumed then.
fn read_line_bounded(reader: &mut BufReader<File>, line: &mut Vec<u8>) -> Option<(u64, bool)> {
    line.clear();
    let start = reader.stream_position().ok()?;
    let (mut consumed, mut kept) = (0u64, true);
    loop {
        let available = match reader.fill_buf() {
            Ok(bytes) if !bytes.is_empty() => bytes,
            _ => {
                // No newline before the end: leave the partial line for next time.
                let _ = reader.seek(SeekFrom::Start(start));
                return None;
            }
        };
        let newline = available.iter().position(|b| *b == b'\n');
        let take = newline.map_or(available.len(), |i| i + 1);
        if kept {
            if line.len() + take > MAX_LINE_BYTES {
                kept = false;
                line.clear();
            } else {
                line.extend_from_slice(&available[..take]);
            }
        }
        reader.consume(take);
        consumed += take as u64;
        if newline.is_some() {
            return Some((consumed, kept));
        }
    }
}

fn is_candidate(line: &str) -> bool {
    line.contains("\"usage\"") && line.contains("\"assistant\"")
}

impl TranscriptScanner {
    pub fn new(projects_dir: PathBuf) -> Self {
        Self {
            projects_dir,
            offsets: HashMap::new(),
            day_start_ms: None,
        }
    }

    pub fn scan(&mut self, day_start_ms: u64) -> Scan {
        let reset = self.day_start_ms != Some(day_start_ms);
        if reset {
            self.offsets.clear();
            self.day_start_ms = Some(day_start_ms);
        }
        let mut records = Vec::new();
        // The usage chart covers the days before today as well.
        let since = day_start_ms.saturating_sub(86_400_000 * (HISTORY_DAYS as u64 - 1));
        for file in self.files_touched_since(since) {
            self.read_new_lines(&file, &mut records);
        }
        Scan { reset, records }
    }

    fn files_touched_since(&self, since_ms: u64) -> Vec<PathBuf> {
        let mut out = Vec::new();
        let Ok(projects) = fs::read_dir(&self.projects_dir) else {
            return out;
        };
        for project in projects.flatten() {
            let Ok(files) = fs::read_dir(project.path()) else {
                continue;
            };
            for file in files.flatten() {
                let path = file.path();
                if path.extension().and_then(|e| e.to_str()) != Some("jsonl") {
                    continue;
                }
                let modified_ms = file
                    .metadata()
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                    .map_or(0, |d| d.as_millis() as u64);
                if modified_ms >= since_ms {
                    out.push(path);
                }
            }
        }
        out.sort();
        out
    }

    fn read_new_lines(&mut self, path: &Path, records: &mut Vec<UsageRecord>) {
        let Ok(file) = File::open(path) else { return };
        let len = file.metadata().map_or(0, |m| m.len());
        let mut offset = self.offsets.get(path).copied().unwrap_or(0);
        if len < offset {
            // The file was replaced or truncated.
            offset = 0;
        }
        let mut reader = BufReader::new(file);
        if reader.seek(SeekFrom::Start(offset)).is_err() {
            return;
        }
        let limit = offset.saturating_add(MAX_BYTES_PER_FILE);
        let project_dir = path
            .parent()
            .and_then(Path::file_name)
            .map(|name| name.to_string_lossy().into_owned());
        let mut line = Vec::new();
        while offset < limit {
            // `None`: end of file, or a last line that is still being written.
            let Some((consumed, kept)) = read_line_bounded(&mut reader, &mut line) else {
                break;
            };
            offset += consumed;
            if !kept {
                continue;
            }
            if let Ok(text) = std::str::from_utf8(&line) {
                if is_candidate(text) {
                    records.extend(parse_record_in(text, project_dir.as_deref()));
                }
            }
        }
        self.offsets.insert(path.to_path_buf(), offset);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::temp_dir;
    use std::io::Write;

    const USAGE: &str = r#"{"type":"assistant","timestamp":"2023-11-14T22:14:00Z","message":{"usage":{"input_tokens":1}}}"#;

    fn project(dir: &Path, name: &str) -> PathBuf {
        let p = dir.join(name);
        fs::create_dir_all(&p).unwrap();
        p
    }

    fn append(path: &Path, text: &str) {
        fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap()
            .write_all(text.as_bytes())
            .unwrap();
    }

    #[test]
    fn day_start_follows_the_local_day() {
        assert_eq!(day_start_ms(0, 0), 0);
        assert_eq!(day_start_ms(86_400_000 + 5, 0), 86_400_000);
        // 01:00 UTC on day 1 is 08:00 local at UTC+7; local midnight was 17:00 UTC on day 0.
        assert_eq!(
            day_start_ms(86_400_000 + 3_600_000, 7 * 3600),
            86_400_000 - 7 * 3_600_000
        );
        // West of UTC early on day 0 would be before the epoch: clamped.
        assert_eq!(day_start_ms(1000, -3600), 0);
    }

    #[test]
    fn reads_only_usage_lines_and_continues_where_it_stopped() {
        let dir = temp_dir("tr-inc");
        let file = project(&dir, "proj-a").join("s1.jsonl");
        append(&file, &format!("{{\"type\":\"user\"}}\n{USAGE}\n"));
        let mut scanner = TranscriptScanner::new(dir.clone());
        let first = scanner.scan(0);
        assert!(first.reset, "the first scan starts a day");
        assert_eq!(first.records.len(), 1);
        assert_eq!(first.records[0].input, 1);

        let second = scanner.scan(0);
        assert!(!second.reset);
        assert!(second.records.is_empty(), "nothing new");

        append(
            &file,
            &format!(
                "{USAGE}\n{{\"type\":\"assistant\",\"timestamp\":\"2023-11-14T22:14:00Z\",\"message\":{{\"partial"
            ),
        );
        assert_eq!(
            scanner.scan(0).records.len(),
            1,
            "the unfinished last line waits"
        );
        append(&file, "\":1,\"usage\":{}}}\n");
        assert_eq!(
            scanner.scan(0).records.len(),
            1,
            "and is read once complete"
        );
    }

    #[test]
    fn a_new_day_starts_over() {
        let dir = temp_dir("tr-day");
        append(&project(&dir, "p").join("s.jsonl"), &format!("{USAGE}\n"));
        let mut scanner = TranscriptScanner::new(dir);
        assert_eq!(scanner.scan(0).records.len(), 1);
        let next = scanner.scan(1);
        assert!(next.reset);
        assert_eq!(next.records.len(), 1, "offsets are forgotten with the day");
    }

    #[test]
    fn old_files_other_extensions_and_missing_dirs_are_skipped() {
        let dir = temp_dir("tr-skip");
        let p = project(&dir, "p");
        append(&p.join("notes.txt"), &format!("{USAGE}\n"));
        append(&p.join("s.jsonl"), &format!("{USAGE}\n"));
        fs::write(dir.join("stray-file"), "x").unwrap();
        let mut scanner = TranscriptScanner::new(dir.clone());
        assert_eq!(scanner.scan(0).records.len(), 1);
        // Everything was modified before a day that starts in the future.
        let mut scanner = TranscriptScanner::new(dir);
        assert!(scanner.scan(u64::MAX).records.is_empty());
        let mut scanner = TranscriptScanner::new(PathBuf::from("/nonexistent/litenotch"));
        assert!(scanner.scan(0).records.is_empty());
    }

    #[test]
    fn a_truncated_file_is_read_again_from_the_start() {
        let dir = temp_dir("tr-trunc");
        let file = project(&dir, "p").join("s.jsonl");
        append(&file, &format!("{USAGE}\n{USAGE}\n"));
        let mut scanner = TranscriptScanner::new(dir);
        assert_eq!(scanner.scan(0).records.len(), 2);
        fs::write(&file, format!("{USAGE}\n")).unwrap();
        assert_eq!(scanner.scan(0).records.len(), 1);
    }

    #[test]
    fn oversized_lines_are_skipped_without_losing_the_ones_after_them() {
        let dir = temp_dir("tr-big");
        let file = project(&dir, "p").join("s.jsonl");
        let blob = format!(
            "{{\"type\":\"assistant\",\"usage\":1,\"blob\":\"{}\"}}",
            "x".repeat(MAX_LINE_BYTES * 2)
        );
        append(&file, &format!("{USAGE}\n{blob}\n{USAGE}\n"));
        let mut scanner = TranscriptScanner::new(dir);
        assert_eq!(scanner.scan(0).records.len(), 2);
        // A huge line still being written is not consumed until it is complete.
        append(&file, &blob);
        assert!(scanner.scan(0).records.is_empty());
        append(&file, &format!("\n{USAGE}\n"));
        assert_eq!(scanner.scan(0).records.len(), 1);
    }

    #[test]
    fn invalid_utf8_lines_are_skipped() {
        let dir = temp_dir("tr-utf8");
        let file = project(&dir, "p").join("s.jsonl");
        fs::write(
            &file,
            [
                b"\"usage\" \"assistant\" \xff\n".as_slice(),
                USAGE.as_bytes(),
                b"\n",
            ]
            .concat(),
        )
        .unwrap();
        let mut scanner = TranscriptScanner::new(dir);
        assert_eq!(scanner.scan(0).records.len(), 1);
    }
}
