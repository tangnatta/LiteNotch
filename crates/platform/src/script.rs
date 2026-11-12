//! Run a helper process with a hard timeout.

use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

#[derive(Debug, PartialEq, Eq)]
pub enum ScriptError {
    Spawn(String),
    Timeout,
    Failed { code: Option<i32>, stderr: String },
}

impl std::fmt::Display for ScriptError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ScriptError::Spawn(e) => write!(f, "could not start process: {e}"),
            ScriptError::Timeout => write!(f, "process timed out"),
            ScriptError::Failed { code, stderr } => {
                write!(f, "process failed ({code:?}): {}", stderr.trim())
            }
        }
    }
}

impl std::error::Error for ScriptError {}

/// Runs `program` with `args`, returning trimmed stdout. The child is killed
/// if it outlives `timeout`. Output is expected to be small (it is read after
/// exit), which holds for every helper LiteNotch runs.
pub fn run(program: &str, args: &[&str], timeout: Duration) -> Result<String, ScriptError> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| ScriptError::Spawn(e.to_string()))?;
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(ScriptError::Timeout);
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(15)),
            Err(e) => return Err(ScriptError::Spawn(e.to_string())),
        }
    };
    let mut stdout = String::new();
    let mut stderr = String::new();
    if let Some(mut out) = child.stdout.take() {
        let _ = out.read_to_string(&mut stdout);
    }
    if let Some(mut err) = child.stderr.take() {
        let _ = err.read_to_string(&mut stderr);
    }
    if status.success() {
        Ok(stdout.trim().to_string())
    } else {
        Err(ScriptError::Failed {
            code: status.code(),
            stderr,
        })
    }
}

/// Runs one AppleScript source string through `osascript`.
pub fn osascript(source: &str, timeout: Duration) -> Result<String, ScriptError> {
    run("/usr/bin/osascript", &["-e", source], timeout)
}

/// Quotes `s` as an AppleScript string literal.
pub fn applescript_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        if c == '"' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn returns_trimmed_stdout() {
        let out = run("/bin/echo", &["  hi  "], Duration::from_secs(5)).unwrap();
        assert_eq!(out, "hi");
    }

    #[test]
    fn reports_failure_with_exit_code_and_stderr() {
        let err = run(
            "/bin/sh",
            &["-c", "echo oops >&2; exit 3"],
            Duration::from_secs(5),
        )
        .unwrap_err();
        assert_eq!(
            err,
            ScriptError::Failed {
                code: Some(3),
                stderr: "oops\n".into()
            }
        );
        assert!(err.to_string().contains("oops"));
    }

    #[test]
    fn kills_a_process_that_outlives_the_timeout() {
        let start = Instant::now();
        let err = run("/bin/sleep", &["5"], Duration::from_millis(100)).unwrap_err();
        assert_eq!(err, ScriptError::Timeout);
        assert!(start.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn missing_program_is_a_spawn_error() {
        let err = run("/nonexistent/litenotch-test", &[], Duration::from_secs(1)).unwrap_err();
        assert!(matches!(err, ScriptError::Spawn(_)));
        assert!(err.to_string().contains("could not start"));
    }

    #[test]
    fn applescript_quote_escapes_quotes_and_backslashes() {
        assert_eq!(applescript_quote(r#"a"b\c"#), r#""a\"b\\c""#);
        assert_eq!(applescript_quote(""), "\"\"");
    }
}
