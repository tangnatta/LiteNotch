//! Asks GitHub for the newest LiteNotch release of one channel.
//!
//! The one outgoing request the app makes, and only when the user asks for
//! it (or has turned on the daily check). It goes through `/usr/bin/curl`
//! rather than an HTTP library, which keeps the app small, and it sends
//! nothing about the user or the Mac: no identifier, no version, a generic
//! client name. What comes back is only read as text and checked again by the
//! core before anything uses it.

use std::process::{Command, Stdio};

const CURL: &str = "/usr/bin/curl";
/// The newest releases, drafts included in the answer (and skipped when
/// reading it). A channel's newest release is not always the newest one: a
/// stable build has to look past the betas, so several are asked for.
/// `releases/latest` is not used: it knows nothing of the beta channel.
const API: &str = "https://api.github.com/repos/tangnatta/LiteNotch/releases?per_page=20";

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

/// Whether a tag is a beta-channel version: it carries a label (`-beta`,
/// `-rc.1`). The same rule the core and the release workflow use.
fn is_beta_tag(tag: &str) -> bool {
    tag.trim_start_matches('v').contains('-')
}

/// The version tag and release page of the newest release of the channel
/// (`beta`: labelled versions; otherwise plain ones), in GitHub's answer,
/// which lists the newest first. Drafts are skipped. The tag decides the
/// channel, not GitHub's `prerelease` flag: the casks are filed by the tag.
pub fn parse_latest(body: &str, beta: bool) -> Result<(String, String), String> {
    let releases: serde_json::Value =
        serde_json::from_str(body).map_err(|_| "GitHub's answer was not understood".to_string())?;
    let list = releases.as_array().ok_or("no release was found")?;
    let mut seen_any = false;
    for release in list.iter().filter(|r| r["draft"] != true) {
        let text = |key: &str| release.get(key).and_then(|v| v.as_str()).map(str::to_owned);
        let (Some(tag), Some(url)) = (text("tag_name"), text("html_url")) else {
            return Err("the release had no version".to_string());
        };
        seen_any = true;
        if is_beta_tag(&tag) == beta {
            return Ok((tag, url));
        }
    }
    Err(if seen_any {
        "no release was found for this channel"
    } else {
        "no release was found"
    }
    .to_string())
}

/// Asks GitHub for the newest release of the beta channel (`beta`) or the
/// stable one. Blocks for up to ten seconds, so call it off the runtime thread.
pub fn latest(beta: bool) -> Result<(String, String), String> {
    let out = Command::new(CURL)
        .args(curl_args())
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .map_err(|_| "curl could not be started".to_string())?;
    if !out.status.success() {
        return Err("GitHub could not be reached".to_string());
    }
    parse_latest(&String::from_utf8_lossy(&out.stdout), beta)
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
            parse_latest(body, true).unwrap(),
            (
                "v0.3.0-beta".to_string(),
                "https://github.com/tangnatta/LiteNotch/releases/tag/v0.3.0-beta".to_string()
            )
        );
    }

    /// GitHub's list, newest first, as it will look once both channels exist:
    /// a beta on top of the stable release it came after.
    fn both_channels() -> String {
        let release = |tag: &str, prerelease: bool, draft: bool| {
            serde_json::json!({
                "tag_name": tag, "draft": draft, "prerelease": prerelease,
                "html_url": format!("https://github.com/tangnatta/LiteNotch/releases/tag/{tag}"),
            })
        };
        serde_json::json!([
            release("v9.9.9", false, true),
            release("v0.2.6-beta", true, false),
            release("v0.2.5", false, false),
            release("v0.2.5-beta", true, false),
            release("v0.2.4-beta", true, false),
        ])
        .to_string()
    }

    #[test]
    fn each_channel_gets_the_newest_release_of_its_own() {
        let body = both_channels();
        assert_eq!(parse_latest(&body, true).unwrap().0, "v0.2.6-beta");
        assert_eq!(
            parse_latest(&body, false).unwrap().0,
            "v0.2.5",
            "a stable build looks past the beta on top"
        );
    }

    #[test]
    fn the_tag_decides_the_channel_not_githubs_prerelease_flag() {
        // The workflow filed every early release as a pre-release; the cask
        // is chosen by the tag, so the tag is what counts.
        let body = r#"[{"tag_name":"v0.2.6-beta","prerelease":false,"draft":false,
              "html_url":"https://github.com/tangnatta/LiteNotch/releases/tag/v0.2.6-beta"},
            {"tag_name":"v0.2.5","prerelease":true,"draft":false,
              "html_url":"https://github.com/tangnatta/LiteNotch/releases/tag/v0.2.5"}]"#;
        assert_eq!(parse_latest(body, true).unwrap().0, "v0.2.6-beta");
        assert_eq!(parse_latest(body, false).unwrap().0, "v0.2.5");
    }

    #[test]
    fn a_channel_with_no_release_is_an_error_that_says_so() {
        let only_betas = r#"[{"tag_name":"v0.2.5-beta","draft":false,
              "html_url":"https://github.com/tangnatta/LiteNotch/releases/tag/v0.2.5-beta"}]"#;
        assert_eq!(
            parse_latest(only_betas, false).unwrap_err(),
            "no release was found for this channel"
        );
        assert_eq!(
            parse_latest("[]", false).unwrap_err(),
            "no release was found"
        );
        // Drafts never count, in either channel.
        let draft = r#"[{"tag_name":"v1.0.0","draft":true,"html_url":"https://x"}]"#;
        for beta in [false, true] {
            assert!(parse_latest(draft, beta).is_err());
        }
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
            for beta in [false, true] {
                assert!(parse_latest(body, beta).is_err(), "{body:?}");
            }
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

    /// Not run by default (it needs the network): the real answer, once.
    /// `cargo test -p litenotch-platform -- --ignored live_answer`
    #[test]
    #[ignore = "asks GitHub"]
    fn live_answer_has_a_release_for_each_channel() {
        let stable = latest(false).expect("a stable release");
        let beta = latest(true).expect("a beta release");
        assert!(!is_beta_tag(&stable.0), "{stable:?}");
        assert!(is_beta_tag(&beta.0), "{beta:?}");
        eprintln!("stable {stable:?}\nbeta   {beta:?}");
    }
}
