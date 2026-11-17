//! Checking for a newer LiteNotch.
//!
//! Pure rules and state; the platform layer does the one network request
//! (`Effect::CheckUpdate`) and hands back the newest release's version and
//! page (`Input::UpdateChecked`). Nothing is fetched unless the user presses
//! "Check for updates" or has turned on the daily check (off by default).

use serde::{Deserialize, Serialize};

/// The version of this build.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Where releases are published; a release page must be under it.
pub const RELEASES_PAGE: &str = "https://github.com/tangnatta/LiteNotch/releases";

/// What updates a Homebrew install. Fixed text: the shell copies it, it is
/// never built from anything received.
pub const BREW_COMMAND: &str = "brew update && brew upgrade --cask litenotch";

/// The daily check, and the retry after a failed one.
const EVERY_MS: u64 = 24 * 3_600_000;
const RETRY_MS: u64 = 3_600_000;

/// A published release: its version and the page about it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Release {
    pub version: String,
    pub url: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum UpdateStatus {
    /// Not checked yet this run.
    #[default]
    Idle,
    Checking,
    /// The newest release is not newer than this build.
    UpToDate,
    Available,
    /// The check did not work (offline, rate limited, an odd answer).
    Failed,
}

/// What the shell shows.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UpdateView {
    /// This build's version.
    pub current: String,
    pub status: UpdateStatus,
    /// The newest version found, when `Available`.
    pub latest: Option<String>,
    /// Its release page, when `Available`.
    pub url: Option<String>,
    /// When the last answer came.
    pub checked_ms: Option<u64>,
    /// What to run to update a Homebrew install.
    pub command: String,
}

/// `major.minor.patch` with an optional `-pre` label.
type Parsed = (u64, u64, u64, Option<String>);

fn parse(version: &str) -> Option<Parsed> {
    let v = version.trim().trim_start_matches('v');
    let (core, pre) = match v.split_once('-') {
        Some((core, pre)) => (core, Some(pre)),
        None => (v, None),
    };
    let mut numbers = core.split('.');
    let mut next = || -> Option<u64> {
        let part = numbers.next()?;
        (!part.is_empty() && part.len() <= 9 && part.chars().all(|c| c.is_ascii_digit()))
            .then(|| part.parse().ok())?
    };
    let (major, minor, patch) = (next()?, next()?, next()?);
    if numbers.next().is_some() {
        return None;
    }
    let pre = match pre {
        None => None,
        Some(p)
            if !p.is_empty()
                && p.len() <= 32
                && p.chars().all(|c| c.is_ascii_alphanumeric() || c == '.') =>
        {
            Some(p.to_owned())
        }
        Some(_) => return None,
    };
    Some((major, minor, patch, pre))
}

/// Whether `candidate` is a later version than `current`. A version with no
/// label is later than the same numbers with one (`0.3.0` > `0.3.0-beta`);
/// labels compare as text. Anything that is not a version is never newer.
pub fn is_newer(candidate: &str, current: &str) -> bool {
    let (Some(a), Some(b)) = (parse(candidate), parse(current)) else {
        return false;
    };
    match (a.0, a.1, a.2).cmp(&(b.0, b.1, b.2)) {
        std::cmp::Ordering::Equal => match (&a.3, &b.3) {
            (None, Some(_)) => true,
            (Some(x), Some(y)) => x > y,
            _ => false,
        },
        other => other == std::cmp::Ordering::Greater,
    }
}

/// A release as the shell may use it: a version and a page under
/// `RELEASES_PAGE`. The version is written without a leading `v`.
pub fn checked(release: Release) -> Option<Release> {
    parse(&release.version)?;
    let url = release.url.trim();
    let ok = url.len() <= 300
        && url.starts_with(RELEASES_PAGE)
        && url[RELEASES_PAGE.len()..]
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "/._-".contains(c));
    ok.then(|| Release {
        version: release.version.trim().trim_start_matches('v').to_owned(),
        url: url.to_owned(),
    })
}

/// The state of the check.
#[derive(Debug, Clone, Default)]
pub struct Update {
    status: UpdateStatus,
    latest: Option<Release>,
    checked_ms: Option<u64>,
    /// When the daily check is next due, once it has been scheduled.
    next_auto_ms: Option<u64>,
    /// The version a notice was already posted for.
    announced: Option<String>,
    /// The check running now was the daily one, not the user's.
    by_timer: bool,
}

impl Update {
    /// Starts a check unless one is running; true when the platform should
    /// be asked.
    pub fn start(&mut self, by_timer: bool) -> bool {
        if self.status == UpdateStatus::Checking {
            return false;
        }
        self.status = UpdateStatus::Checking;
        self.by_timer = by_timer;
        true
    }

    /// Whether the daily check is due. Turning it off forgets the schedule;
    /// turning it on is due at once (the first reading after start-up).
    pub fn auto_due(&mut self, on: bool, now_ms: u64) -> bool {
        if !on {
            self.next_auto_ms = None;
            return false;
        }
        let due = *self.next_auto_ms.get_or_insert(now_ms);
        now_ms >= due && self.status != UpdateStatus::Checking
    }

    /// When the runtime should next wake for the daily check.
    pub fn next_deadline(&self, on: bool) -> Option<u64> {
        if !on || self.status == UpdateStatus::Checking {
            return None;
        }
        self.next_auto_ms
    }

    /// Takes the answer. Returns the release when it is newer than this build
    /// and found by the daily check for the first time, so a notice can be
    /// posted once.
    pub fn finish(
        &mut self,
        answer: Result<Release, String>,
        on: bool,
        now_ms: u64,
    ) -> Option<Release> {
        self.checked_ms = Some(now_ms);
        let by_timer = std::mem::take(&mut self.by_timer);
        let release = answer.ok().and_then(checked);
        let wait = if release.is_some() {
            EVERY_MS
        } else {
            RETRY_MS
        };
        self.next_auto_ms = on.then(|| now_ms.saturating_add(wait));
        match release {
            Some(r) if is_newer(&r.version, VERSION) => {
                self.status = UpdateStatus::Available;
                let first = self.announced.as_deref() != Some(r.version.as_str());
                self.latest = Some(r.clone());
                if first {
                    self.announced = Some(r.version.clone());
                }
                (first && by_timer).then_some(r)
            }
            Some(_) => {
                self.status = UpdateStatus::UpToDate;
                self.latest = None;
                None
            }
            None => {
                self.status = UpdateStatus::Failed;
                None
            }
        }
    }

    pub fn view(&self) -> UpdateView {
        let available = self.status == UpdateStatus::Available;
        UpdateView {
            current: VERSION.to_owned(),
            status: self.status,
            latest: self
                .latest
                .as_ref()
                .filter(|_| available)
                .map(|r| r.version.clone()),
            url: self
                .latest
                .as_ref()
                .filter(|_| available)
                .map(|r| r.url.clone()),
            checked_ms: self.checked_ms,
            command: BREW_COMMAND.to_owned(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn release(v: &str) -> Release {
        Release {
            version: v.into(),
            url: format!("{RELEASES_PAGE}/tag/v{v}"),
        }
    }

    #[test]
    fn versions_compare_by_number_then_label() {
        assert!(is_newer("0.2.4-beta", "0.2.3-beta"));
        assert!(is_newer("v0.3.0-beta", "0.2.9-beta"));
        assert!(is_newer("1.0.0", "0.9.9"));
        assert!(!is_newer("0.2.3-beta", "0.2.3-beta"), "same is not newer");
        assert!(!is_newer("0.2.2-beta", "0.2.3-beta"));
        assert!(
            is_newer("0.3.0", "0.3.0-beta"),
            "a final release follows its beta"
        );
        assert!(!is_newer("0.3.0-beta", "0.3.0"));
        assert!(is_newer("0.3.0-rc", "0.3.0-beta"));
        assert!(is_newer("0.10.0", "0.9.0"), "numbers, not text");
    }

    #[test]
    fn what_is_not_a_version_is_never_newer() {
        for bad in [
            "",
            "latest",
            "1.2",
            "1.2.3.4",
            "1.2.x",
            "v",
            "1.2.3-",
            "1..3",
            "1.2.3-b a",
            "99999999999.0.0",
        ] {
            assert!(!is_newer(bad, "0.0.1"), "{bad:?}");
            assert!(!is_newer("9.9.9", bad), "{bad:?}");
        }
    }

    #[test]
    fn the_build_knows_its_own_version() {
        assert!(parse(VERSION).is_some(), "{VERSION}");
    }

    #[test]
    fn only_a_release_page_of_ours_is_accepted() {
        assert!(checked(release("9.0.0")).is_some());
        let tagged = checked(Release {
            version: "v9.0.0".into(),
            url: format!("{RELEASES_PAGE}/tag/v9.0.0"),
        })
        .unwrap();
        assert_eq!(tagged.version, "9.0.0", "no leading v");
        for url in [
            "https://evil.example/releases/tag/v9.0.0",
            "http://github.com/tangnatta/LiteNotch/releases/tag/v9",
            "https://github.com/tangnatta/LiteNotch/releases/tag/v9?x=1",
            "https://github.com/tangnatta/LiteNotch/releases/tag/v9 && rm -rf",
            "https://github.com/tangnatta/LiteNotchEvil/releases",
            "",
        ] {
            let r = Release {
                version: "9.0.0".into(),
                url: url.into(),
            };
            assert!(checked(r).is_none(), "{url:?}");
        }
        let r = Release {
            version: "not-a-version".into(),
            url: format!("{RELEASES_PAGE}/tag/x"),
        };
        assert!(checked(r).is_none());
    }

    #[test]
    fn a_newer_release_is_shown_and_an_equal_one_is_up_to_date() {
        let mut u = Update::default();
        assert!(u.start(false));
        assert!(!u.start(false), "one check at a time");
        assert_eq!(u.view().status, UpdateStatus::Checking);
        u.finish(Ok(release("999.0.0")), false, 10);
        let v = u.view();
        assert_eq!(
            (v.status, v.latest.as_deref(), v.checked_ms),
            (UpdateStatus::Available, Some("999.0.0"), Some(10))
        );
        assert!(v
            .url
            .as_deref()
            .is_some_and(|u| u.starts_with(RELEASES_PAGE)));
        assert_eq!(v.command, BREW_COMMAND);

        assert!(u.start(false));
        u.finish(Ok(release(VERSION)), false, 20);
        let v = u.view();
        assert_eq!(
            (v.status, v.latest, v.url),
            (UpdateStatus::UpToDate, None, None)
        );
    }

    #[test]
    fn a_bad_answer_is_a_failure_not_an_update() {
        let mut u = Update::default();
        for answer in [
            Err("offline".to_string()),
            Ok(Release {
                version: "999.0.0".into(),
                url: "https://evil.example/".into(),
            }),
        ] {
            u.start(false);
            assert_eq!(u.finish(answer, false, 5), None);
            assert_eq!(u.view().status, UpdateStatus::Failed);
        }
    }

    #[test]
    fn the_daily_check_is_off_unless_turned_on_then_due_at_once_then_daily() {
        let mut u = Update::default();
        assert!(!u.auto_due(false, 0));
        assert_eq!(u.next_deadline(false), None);
        assert!(
            u.auto_due(true, 1_000),
            "due the first time it is looked at"
        );
        assert!(u.start(true));
        assert!(!u.auto_due(true, 1_001), "not while one runs");
        assert_eq!(u.next_deadline(true), None);
        u.finish(Ok(release(VERSION)), true, 2_000);
        assert_eq!(u.next_deadline(true), Some(2_000 + 24 * 3_600_000));
        assert!(!u.auto_due(true, 3_000));
        // A failed check is tried again within the hour, not the day.
        assert!(u.auto_due(true, 2_000 + 24 * 3_600_000));
        u.start(true);
        u.finish(Err("offline".into()), true, 5_000_000_000);
        assert_eq!(u.next_deadline(true), Some(5_000_000_000 + 3_600_000));
        // Turning it off forgets the schedule.
        assert!(!u.auto_due(false, 1));
        assert_eq!(u.next_deadline(true), None);
    }

    #[test]
    fn a_new_version_is_announced_once_and_only_by_the_daily_check() {
        let mut u = Update::default();
        u.start(false);
        assert_eq!(
            u.finish(Ok(release("999.0.0")), true, 1),
            None,
            "the user is looking"
        );
        u.start(true);
        assert_eq!(
            u.finish(Ok(release("999.0.0")), true, 2),
            None,
            "the manual check already showed it: announced"
        );
        let mut u = Update::default();
        u.start(true);
        assert!(u.finish(Ok(release("999.0.0")), true, 1).is_some());
        u.start(true);
        assert_eq!(
            u.finish(Ok(release("999.0.0")), true, 2),
            None,
            "once per version"
        );
        u.start(true);
        assert!(
            u.finish(Ok(release("999.0.1")), true, 3).is_some(),
            "a later one is new again"
        );
    }
}
