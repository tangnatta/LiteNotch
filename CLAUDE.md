# LiteNotch

A notch / dynamic-island utility for macOS with a Rust core and a thin SwiftUI
shell. Positioning: fewer features than Notchy (notchy.dev), aimed at
productivity and agentic coding, with a measured memory/CPU budget.
Stage: prototype for early adopters. Windows is a later goal; nothing
Windows-specific exists yet.

## Commands

Rust is installed through Homebrew's keg-only `rustup`, so it is not on PATH
by default:

```sh
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH

cargo test --workspace                      # all Rust tests (~5 s)
cargo clippy --workspace --all-targets -- -D warnings
cargo fmt --all
scripts/coverage.sh                         # tests under coverage, fails < 90 % lines
swift test --package-path macos             # shell tests
scripts/build-app.sh                        # → dist/LiteNotch.app (release, ad-hoc signed)
scripts/bench.sh                            # idle memory / CPU / bundle size vs budget (launches the app ~25 s)
open dist/LiteNotch.app
```

Run one Rust test: `cargo test -p litenotch-core state::tests::<name>`.
Regenerate the shell's fixtures after changing the view model:
`cargo run -p litenotch-core --example fixtures -- macos/Fixtures`.
Drive the real runtime without the UI (end-to-end checks of hooks/CLI):
`cargo run -p litenotch-app --example headless -- /tmp/ln-e2e allow`, then
`LITENOTCH_SOCKET=/tmp/ln-e2e/litenotch.sock target/debug/litenotch status`.

## Layout

```
crates/core      litenotch-core      all logic; no I/O, no clock, no threads, forbid(unsafe)
crates/platform  litenotch-platform  macOS calls: pasteboard, IOKit power assertion, pmset, osascript, lid watchdog, now-playing helper process
crates/files     litenotch-files     saved state + editing ~/.claude/settings.json (shared by app and CLI)
crates/app       litenotch-app       runtime thread, socket server, transcript scanner, C FFI (staticlib)
crates/cli       litenotch (bin)     hook | statusline | notify | status | hooks install/uninstall/status
macos/           SwiftPM package     LiteNotchUI (views, panel, models), LiteNotch (app), LiteNotchSnapshot
macos/NowPlayingHelper  nowplaying.m, built into Contents/Helpers/libnowplaying.dylib
macos/Fixtures   generated view-model JSON used by shell tests and snapshots
scripts/         build-app.sh, bench.sh, coverage.sh
```

## How it works

- **Rust owns everything except pixels.** `core::state::Core` holds the
  feature modules (pomodoro, clipboard, notify, caffeine, media, agent, usage,
  analytics). Inputs go in with a timestamp (`apply(Input, now_ms)`,
  `hook(json, now_ms)`); `Effect`s come out for the platform layer; `view(now)`
  builds the `ViewModel` the shell renders.
- **Shell ⇄ core** is JSON over three C functions (`crates/app/src/ffi.rs`,
  header in `macos/Sources/CLiteNotch`): `ln_start(config, callback, ctx)`,
  `ln_send(command_json)`, `ln_stop()`. Commands are `state::Command`
  (`{"cmd":"pomodoro_toggle"}`) plus `hooks_install` / `hooks_uninstall`.
  The callback delivers the whole view model whenever it changes.
- **The runtime thread sleeps until the next deadline** (`Core::next_deadline`).
  The view model carries end times (`ends_at_ms`), not remaining seconds, and
  the shell draws countdowns itself, so a running timer causes no wakeups in
  the core and no view-model pushes. The only poll is the pasteboard change
  counter (500 ms, off when clipboard history is disabled). Keep it that way:
  anything that changes every second must not go into the view model.
- **Shell layout.** Tabs: Home (dashboard: now playing, timer, agents,
  inbox), Music, Timer, Clipboard, Agents (Sessions | Usage) on the left of
  the notch; keep-awake toggle (cup icon), Inbox, Settings on the right.
  Settings is a sidebar of feature categories (`AppModel.settingsSection`,
  so other tabs can deep-link). Hover opens after a delay, a click opens at
  once, a click on the tab-bar background closes.
- **Agent integration** is Claude Code hooks → `litenotch hook` (reads the
  hook JSON on stdin) → Unix socket → runtime. A `PermissionRequest` is held
  open until the user clicks Allow/Deny in the notch, the request expires
  (120 s, below the 130 s hook timeout), the session ends, or the CLI
  disconnects. Printing nothing means "show the normal prompt", which is also
  what happens whenever the app is not running. Usage limits come from the
  status line JSON (`litenotch statusline`, the only documented source of
  `rate_limits`); today's token totals are read from the session transcripts,
  whose format is internal to Claude Code and may change.
- **Now playing** is system-wide (any app, including browser tabs). macOS
  answers MediaRemote queries only for Apple-entitled processes since 15.4,
  so the runtime starts `/usr/bin/perl` (which is entitled) with a small
  loader that pulls in our own `libnowplaying.dylib`
  (`crates/platform/src/nowplaying.rs`, `macos/NowPlayingHelper`). The
  helper prints one JSON line per change and exits when LiteNotch does;
  artwork is written to `<data dir>/artwork/art-<hash>` and only the path
  travels in the view model. Transport commands start the same helper in
  `send` mode. `settings.media.enabled = false` stops the process. This is
  the same approach Notchy uses (via mediaremote-adapter); it depends on
  private API and may break in a macOS update, in which case nothing shows
  as playing and nothing else is affected.
- **Other apps' notifications** are read by the shell through the
  Accessibility API (`SystemNotificationObserver`: an `AXObserver` on the
  Notification Center process) and sent to the core as `notify_system`.
  Off by default (`settings.notify.system`); needs the Accessibility
  permission, which for an ad-hoc signed build must be granted again after
  every rebuild.
- **Usage history**: the transcript scanner reads the last 7 days of
  session transcripts off the core thread and passes only compact
  `UsageRecord`s (a transcript line can be hundreds of kilobytes). The core
  keeps per-day totals, today's totals by model and project, and writes the
  one-sentence summary (`usage::Usage::snapshot`). "Tokens" there means
  input + output; cache tokens are tracked separately in `today`.
- **Closed-lid keep-awake** needs root (`pmset -a disablesleep 1`). One admin
  prompt starts a root shell loop that sets the flag and restores it when the
  LiteNotch process (pid + start time) is gone, the sentinel file is removed,
  or 12 h pass. The sentinel is in the user's private temp dir with a
  per-session name, and the value to restore is read once per process; both
  matter (see the comments in `crates/platform/src/lid.rs`).

## Releasing

- `.github/workflows/ci.yml` runs on every push and pull request: fmt,
  clippy, tests under coverage, the app build, Swift tests, the footprint
  budget, and keeps the built app as an artifact for 14 days.
- `.github/workflows/release.yml` runs on a `v*` tag. The tag must equal the
  `version` in the root `Cargo.toml`. It tests, builds, zips
  `LiteNotch-<version>-arm64.zip`, publishes a GitHub pre-release, then
  rewrites `version` and `sha256` in `Casks/litenotch.rb` and pushes that to
  `main`.
- To release: bump `version` in `Cargo.toml`, commit, then
  `git tag v<version> && git push origin main v<version>`.
- The cask lives in this repository, so users tap it with an explicit URL
  (`brew tap tangnatta/litenotch https://github.com/tangnatta/LiteNotch`).
  It removes the quarantine flag in `postflight` because the app is not
  notarized; notarization needs a Developer ID certificate.
- Only Apple silicon is built: every Mac with a notch is Apple silicon.

## Rules that are easy to break

- Core modules take `now_ms: u64` and never read a clock; tests rely on it.
  The runtime's `SteadyClock` follows wall time but never goes backwards.
- No `unwrap`/`expect`/`panic!` outside tests (release builds use
  `panic = "abort"`).
- **Security invariants** (each has a test; do not weaken them):
  - The socket protocol (`core::ipc::Request`) has no request that answers an
    approval or changes settings. Decisions come only from the shell.
  - An approval shows the whole tool input (`agent::describe`: main argument,
    then every other field), sanitized (`agent::sanitize`: control, invisible
    and bidi characters become U+FFFD). If it cannot be reviewed in full —
    over 4000 chars or 60 lines, or padded with blank lines — it is
    `truncated` and cannot be allowed from the notch: the core turns Allow
    into Pass, and the shell hides the button. The shell renders such text
    with `Text(verbatim:)`.
  - Notifications arriving over the socket are capped in length, limited to
    High priority and a 60 s ttl. Text captured from other apps' banners and
    now-playing titles (a web page chooses its own) is sanitized and capped
    the same way.
  - An artwork path is passed to the shell only if it is an `art-*` file
    directly inside the data directory's `artwork` folder.
  - Only validated integers and a `[A-Za-z0-9/._-]` path are interpolated into
    the root watchdog command.
  - The socket lives in a 0700 directory with mode 0600; server and CLI both
    check the peer uid. A request line must arrive within 5 s in total.
- Anything that moves continuously in the shell (the equaliser bars) must be
  a Core Animation layer animation, not a SwiftUI animation: the SwiftUI
  version re-rendered the notch every frame and cost 9 % CPU while music
  played. `scripts/bench.sh` only measures idle, so check by hand with
  something playing after touching the closed-notch views.
- The CLI must stay cheap and silent: it runs on every hook. It depends on
  `core` and `files` only (not `platform`/`app`, which link AppKit), exits 0
  and prints nothing on any failure in `hook`/`statusline`.
- Tests must not write to the user's real pasteboard, `~/.claude`, or
  `~/Library/Application Support/LiteNotch`; use `store::temp_dir` and the
  `FakePorts` harness in `crates/app/src/runtime.rs`.
- Analytics record feature-use counters per day only (`analytics::Feature`
  enum; no free-form strings). Uploading is opt-in and not implemented.
- Clipboard history is in memory unless `general.persist_clipboard` is on.
  Files and images are stored as descriptions, not data.

## Budgets (checked by `scripts/bench.sh --check` and `scripts/coverage.sh`)

Idle memory footprint ≤ 30 MB (measured 18), idle CPU ≤ 0.5 % (0.1; 0.07
with a track playing), bundle ≤ 15 MB (3.8), Rust line coverage ≥ 90 % (97).
RSS is about 65 MB but mostly shared system-framework pages, so the budget
is on physical footprint. The now-playing helper is a separate perl process
of about 4 MB that the benchmark does not count.

## Decisions and why

- SwiftUI shell instead of a Rust GUI toolkit or Tauri: the notch needs an
  `NSPanel` above the menu bar with native animation, and a webview would
  cost more memory than the whole budget. The shell holds no logic, so a
  Windows shell can reuse the core unchanged.
- No async runtime: one thread and channels are enough and keep the binary
  and idle footprint small.
- Other apps' notifications have no public API. Reading the banners off
  the screen with Accessibility was chosen over reading the Notification
  Center database, which needs Full Disk Access.
- Now playing goes through the perl-hosted helper rather than per-app
  AppleScript (the first version, Spotify and Music only), because most
  listening happens in a browser.
- Notifications are a priority queue (higher preempts, lower waits; focus
  time holds anything below High), in contrast to Notchy's "newest wins".

## Not done yet

- Reading other apps' notifications (`SystemNotificationObserver`) is
  unit-tested against a fake accessibility tree only. It has never run
  against the real Notification Center, because that needs the user to grant
  Accessibility; the banner subroles and identifiers it looks for may need
  adjusting on a given macOS version.
- Hover-to-open and hover-to-close were checked in the real window; clicking
  (open, close on the tab-bar background, buttons) is covered by `AppModel`
  tests but not by a real click.
- Media transport commands (play/pause/next) are sent through the helper but
  were not exercised against a real player.

- Unverified against a live Claude Code session: whether the terminal's own
  permission dialog is delayed while the hook waits for the notch.
- Closed-lid mode's privileged step is tested with `pmset` stubbed out; the
  real admin prompt has not been exercised.
- In-app updates and the analytics backend. Releases already go to GitHub
  Releases with a Homebrew cask (see Releasing); in-app updates would read a
  static JSON manifest (version, URL, sha256, minimum OS) next to those
  archives. Analytics upload needs an HTTPS endpoint that accepts
  `analytics::UploadBatch`. Both want a Developer ID certificate and
  notarization first; today the app is ad-hoc signed.
- Closed-lid mode turns the display off when the lid closes. The lid is
  not polled: `platform::display::LidWatcher` listens for the power
  manager's clamshell-changed message, only while the mode is on. Checked
  with a fake lid in tests and the watcher's start/stop on this Mac, not yet
  with a real lid closing.
- Shortlist from the Notchy comparison, deliberately not built to keep the
  app small: file shelf, next calendar event, Codex usage, listening ports.
