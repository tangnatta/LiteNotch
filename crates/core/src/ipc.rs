//! Wire protocol between the `litenotch` CLI and the running app: one JSON
//! object per line in each direction over a Unix socket.
//!
//! The socket deliberately has no way to answer a permission request or to
//! change settings. Decisions come only from the user through the shell, so
//! another local process cannot approve an agent's command.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::agent::Decision;
use crate::notify::Priority;

/// Longest request line the server will read.
pub const MAX_REQUEST_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Request {
    /// A Claude Code hook payload, passed through unmodified.
    Hook { payload: Value },
    /// The status line command's stdin JSON.
    Statusline { payload: Value },
    Notify {
        title: String,
        #[serde(default)]
        body: String,
        #[serde(default)]
        source: String,
        #[serde(default)]
        priority: Priority,
        #[serde(default)]
        group: Option<String>,
        #[serde(default)]
        ttl_secs: Option<u32>,
    },
    /// Ask for a one-line summary of what the app is doing.
    Status,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Response {
    Ok,
    Decision {
        decision: Decision,
    },
    /// Usage text for the status line, e.g. `5h 42% · 7d 18%`.
    Statusline {
        text: String,
    },
    Status {
        view: Value,
    },
    Error {
        message: String,
    },
}

/// Directory holding the socket and saved state, given the user's home.
pub fn data_dir(home: &str) -> String {
    format!(
        "{}/Library/Application Support/LiteNotch",
        home.trim_end_matches('/')
    )
}

/// Path of the app's socket inside `data_dir`.
pub fn socket_path(data_dir: &str) -> String {
    format!("{data_dir}/litenotch.sock")
}

impl Request {
    pub fn to_line(&self) -> String {
        let mut line = serde_json::to_string(self).unwrap_or_else(|_| "{}".to_string());
        line.push('\n');
        line
    }

    pub fn parse(line: &str) -> Result<Request, String> {
        if line.len() > MAX_REQUEST_BYTES {
            return Err("request too large".to_string());
        }
        serde_json::from_str(line.trim()).map_err(|e| e.to_string())
    }
}

impl Response {
    pub fn to_line(&self) -> String {
        let mut line = serde_json::to_string(self).unwrap_or_else(|_| "{}".to_string());
        line.push('\n');
        line
    }

    pub fn parse(line: &str) -> Result<Response, String> {
        serde_json::from_str(line.trim()).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn requests_round_trip_as_single_lines() {
        let requests = [
            Request::Hook {
                payload: json!({"hook_event_name":"Stop","text":"a\nb"}),
            },
            Request::Statusline {
                payload: json!({"rate_limits":{}}),
            },
            Request::Notify {
                title: "t".into(),
                body: "b".into(),
                source: "ci".into(),
                priority: Priority::High,
                group: Some("g".into()),
                ttl_secs: Some(3),
            },
            Request::Status,
        ];
        for request in requests {
            let line = request.to_line();
            assert!(line.ends_with('\n'));
            assert_eq!(
                line.matches('\n').count(),
                1,
                "embedded newlines must be escaped"
            );
            assert_eq!(Request::parse(&line).unwrap(), request);
        }
    }

    #[test]
    fn paths_are_under_application_support() {
        let dir = data_dir("/Users/me/");
        assert_eq!(dir, "/Users/me/Library/Application Support/LiteNotch");
        assert_eq!(
            socket_path(&dir),
            "/Users/me/Library/Application Support/LiteNotch/litenotch.sock"
        );
    }

    #[test]
    fn notify_needs_only_a_title() {
        let request = Request::parse(r#"{"type":"notify","title":"Build done"}"#).unwrap();
        assert_eq!(
            request,
            Request::Notify {
                title: "Build done".into(),
                body: String::new(),
                source: String::new(),
                priority: Priority::Normal,
                group: None,
                ttl_secs: None
            }
        );
    }

    #[test]
    fn responses_round_trip() {
        let responses = [
            Response::Ok,
            Response::Decision {
                decision: Decision::Deny,
            },
            Response::Statusline {
                text: "5h 42%".into(),
            },
            Response::Status {
                view: json!({"compact":{}}),
            },
            Response::Error {
                message: "nope".into(),
            },
        ];
        for response in responses {
            assert_eq!(Response::parse(&response.to_line()).unwrap(), response);
        }
        assert_eq!(
            Response::Decision {
                decision: Decision::Allow
            }
            .to_line(),
            "{\"type\":\"decision\",\"decision\":\"allow\"}\n"
        );
    }

    #[test]
    fn there_is_no_request_that_decides_or_reconfigures() {
        for forbidden in [
            r#"{"type":"decide","request_id":"req-1","decision":"allow"}"#,
            r#"{"type":"command","cmd":"agent_decide","request_id":"req-1","decision":"allow"}"#,
            r#"{"type":"set_settings","settings":{}}"#,
        ] {
            assert!(Request::parse(forbidden).is_err(), "{forbidden}");
        }
    }

    #[test]
    fn malformed_and_oversized_input_is_rejected() {
        assert!(Request::parse("").is_err());
        assert!(Request::parse("{").is_err());
        assert!(
            Request::parse(r#"{"type":"notify"}"#).is_err(),
            "title is required"
        );
        let huge = format!(
            r#"{{"type":"notify","title":"{}"}}"#,
            "x".repeat(MAX_REQUEST_BYTES)
        );
        assert_eq!(Request::parse(&huge).unwrap_err(), "request too large");
        assert!(Response::parse("garbage").is_err());
    }
}
