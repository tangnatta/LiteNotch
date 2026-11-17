//! Asks GitHub for the newest LiteNotch release.
//!
//! The one outgoing request the app makes, and only when the user asks for
//! it (or has turned on the daily check). It goes through `/usr/bin/curl`
//! rather than an HTTP library, which keeps the app small, and it sends
//! nothing about the user or the Mac: no identifier, no version, a generic
//! client name. What comes back is only read as text and checked again by the
//! core before anything uses it.

use std::process::{Command, Stdio};

const CURL: &str = "/usr/bin/curl";
/// The newest release, drafts excluded. `releases/latest` is not used: it
/// skips pre-releases, which is all this app has had.
const API: &str = "https://api.github.com/repos/tangnatta/LiteNotch/releases?per_page=1";

/// The arguments: HTTPS only, a short timeout, a size limit.
pub fn curl_args() -> Vec<String> {
    [
        "--silent",
        "--show-error",
        "--fail",
        "--location",
        "--proto",
        "=https",
        "--tlsv1.2",
        "--max-time",
        "10",
        "--max-filesize",
        "500000",
        "--header",
        "Accept: application/vnd.github+json",
        "--user-agent",
        "LiteNotch-update-check",
        API,
    ]
    .map(String::from)
    .to_vec()
}

/// The version tag and release page of the newest release in GitHub's answer.
pub fn parse_latest(body: &str) -> Result<(String, String), String> {
    let releases: serde_json::Value =
        serde_json::from_str(body).map_err(|_| "GitHub's answer was not understood".to_string())?;
    let release = releases
        .as_array()
        .and_then(|a| a.iter().find(|r| r["draft"] != true))
        .ok_or("no release was found")?;
    let text = |key: &str| release.get(key).and_then(|v| v.as_str()).map(str::to_owned);
    match (text("tag_name"), text("html_url")) {
        (Some(tag), Some(url)) => Ok((tag, url)),
        _ => Err("the release had no version".to_string()),
    }
}

/// Asks GitHub. Blocks for up to ten seconds, so call it off the runtime thread.
pub fn latest() -> Result<(String, String), String> {
    let out = Command::new(CURL)
        .args(curl_args())
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|_| "curl could not be started".to_string())?;
    if !out.status.success() {
        return Err("GitHub could not be reached".to_string());
    }
    parse_latest(&String::from_utf8_lossy(&out.stdout))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_newest_release_is_read_and_drafts_are_skipped() {
        let body = r#"[{"tag_name":"v9.9.9","draft":true,"html_url":"https://x"},
            {"tag_name":"v0.3.0-beta","draft":false,"prerelease":true,
             "html_url":"https://github.com/tangnatta/LiteNotch/releases/tag/v0.3.0-beta"}]"#;
        assert_eq!(
            parse_latest(body).unwrap(),
            (
                "v0.3.0-beta".to_string(),
                "https://github.com/tangnatta/LiteNotch/releases/tag/v0.3.0-beta".to_string()
            )
        );
    }

    #[test]
    fn an_answer_that_is_not_a_release_is_an_error() {
        for body in [
            "",
            "[]",
            "{}",
            "null",
            "not json",
            r#"[{"draft":false}]"#,
            r#"[{"tag_name":"v1"}]"#,
        ] {
            assert!(parse_latest(body).is_err(), "{body:?}");
        }
    }

    #[test]
    fn the_request_is_https_only_and_sends_nothing_about_the_user() {
        let args = curl_args();
        assert!(args.windows(2).any(|w| w == ["--proto", "=https"]));
        assert_eq!(args.last().map(String::as_str), Some(API));
        assert!(API.starts_with("https://api.github.com/repos/tangnatta/LiteNotch/"));
        let joined = args.join(" ");
        for private in ["@", "Authorization", "Cookie", "version"] {
            assert!(!joined.contains(private), "{private}");
        }
    }
}
