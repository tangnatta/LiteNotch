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
crates/platform  litenotch-platform  macOS calls: pasteboard, IOKit power assertion, pmset, osascript, closed-lid helper, now-playing helper process
crates/files     litenotch-files     saved state + editing ~/.claude/settings.json (shared by app and CLI)
crates/app       litenotch-app       runtime thread, socket server, transcript scanner, C FFI (staticlib)
crates/cli       litenotch (bin)     hook | statusline | notify | status | hooks install/uninstall/status
macos/           SwiftPM package     LiteNotchUI (views, panel, models), LiteNotch (app), LiteNotchSnapshot
macos/NowPlayingHelper  nowplaying.m, built into Contents/Helpers/libnowplaying.dylib
macos/Fixtures   generated view-model JSON used by shell tests and snapshots
macos/Icon       AppIcon.png: 1024 px full-bleed master (macOS applies the rounded mask; transparent corners get a grey frame on macOS 26+); build-app.sh makes AppIcon.icns from it
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
  Two notch styles (`appearance.notch_style`, Settings → General): Attached
  (default, the original geometry; keep it pixel-identical for existing
  users) and Floating, a capsule inset 3 pt inside the menu bar or notch
  band, with the toast overlapping it by 12 pt and the panel just below.
  Floating sizes derive from the measured menu bar height; all geometry
  lives in `NotchLayout` (`Geometry.swift`).
  The theme (`appearance.theme`) styles the open panel. The closed notch
  and the toast stay black unless `appearance.closed_notch` is `theme`
  (Settings → General → Closed notch: Always dark | Match theme); the
  default keeps them pixel-identical to before. On a display with a
  hardware notch (`safeAreaInsets.top > 0`, `PanelState.hasNotch`)
  they are always black and that row is hidden, since the camera housing
  cannot turn white.
  `appearance.material` (Settings → General → Panel): Solid (default) or
  Glass, macOS 26 Liquid Glass for the open panel only; the closed notch
  and toast stay black to blend with the hardware notch. Glass needs a
  build with the macOS 26 SDK (`#if compiler(>=6.2)`) and macOS 26 at run
  time (`GlassSupport`); otherwise the row is disabled with the reason and
  the panel draws Solid. `ImageRenderer` snapshots never show glass.
  Glass is always Apple's Frosted (`regular`) glass, untinted; there are
  no style or tint options (tried and dropped), so the system's own glass
  setting applies.
  While an approval is waiting the panel is drawn Solid even with Glass
  chosen: its text is contrast-tested against the solid colour only.
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
- **Clipboard files**: copied images (`img-*`) and the formatting of rich
  text (`rich-*`, RTF or HTML) are saved in `<data dir>/clips`, named by a
  hash of their content. The runtime deletes any such file the history no
  longer refers to (`Core::clip_file_paths`). Copying a rich item back
  writes the text plus its formatting; `clip_copy_plain` writes text only.
- **Click targets**: each notification in the view carries `open`
  (`notify::OpenTarget`): another app by bundle id or name, or a tab and
  pane. The core picks it from the source (`Core::open_target`). Agent
  notifications and session rows open the session's terminal, whose bundle
  id the CLI adds to each hook payload as `litenotch_app` (from
  `__CFBundleIdentifier`). Other apps' banners get a unique group starting
  with NUL, which the socket path strips, so nothing else can pose as one.
  The CLI also adds the session's terminal device as `litenotch_tty`
  (`ttys003`; its own or the nearest ancestor's, from `proc_pidinfo`), and
  the target carries it as `tty`. For Terminal and iTerm2 the shell asks the
  app, by AppleScript through `osascript`, to raise the window and tab on
  that device (`TerminalWindow.swift`); macOS asks the user once whether
  LiteNotch may control the terminal. Other terminals have no such
  interface: there, and whenever the script fails or is not allowed, only
  the app is activated.
- **Accessibility and ad-hoc signing**: an ad-hoc signed app's identity is
  its cdhash, so every rebuild loses the Accessibility permission even
  though System Settings still shows it on. "Reset and ask again" runs
  `tccutil reset Accessibility dev.litenotch.app` and asks again.
- **Usage history**: the transcript scanner reads the last 7 days of
  session transcripts off the core thread and passes only compact
  `UsageRecord`s (a transcript line can be hundreds of kilobytes). The core
  keeps per-day totals, today's totals by model and project, and writes the
  one-sentence summary (`usage::Usage::snapshot`). "Tokens" there means
  input + output; cache tokens are tracked separately in `today`.
- **Closed-lid keep-awake** needs root (`pmset -a disablesleep 1`). One admin
  prompt per run of LiteNotch starts a root shell loop, the helper, which
  sets the flag and then sleeps in `read` on a named pipe that LiteNotch
  holds open. A line `0` restores sleep and `1` disables it again, so
  turning the mode off and on asks for no second password. The helper
  restores sleep and exits when the pipe closes (LiteNotch quit or crashed:
  at once), when the LiteNotch process (pid + start time) is gone (checked
  every 30 s, for the case of something else holding the pipe), after
  12 h 10 min in one stretch with sleep disabled (measured on the shell's
  clock from the last off-to-on change, so repeating `1` does not stretch
  it), or when it reads anything but `0` or `1`. It opens the pipe before
  it first sets the flag, so a failure there changes nothing. The core
  ends the mode itself after 12 h (`caffeine::LID_MAX_HOURS`) with a
  notification, so in normal use the helper's cap never fires and the
  helper stays for the next enable. If the helper is gone anyway, two
  things notice: closing the lid (the runtime checks the flag once, then
  `Input::LidLost` ends the mode with a notification), and the next enable
  (the flag does not change within 2 s, so it asks for the password
  again). The pipe is in the user's private temp
  dir with a fresh name per helper, and the value to restore is read once
  per process; both matter (see the comments in `crates/platform/src/lid.rs`).

## Releasing

- `.github/workflows/ci.yml` runs on every push and pull request: fmt,
  clippy, tests under coverage, the app build, Swift tests, the footprint
  budget, and keeps the built app as an artifact for 14 days.
- `.github/workflows/release.yml` runs on a `v*` tag. The tag must equal the
  `version` in the root `Cargo.toml`. It tests, builds, zips
  `LiteNotch-<version>-arm64.zip`, publishes a GitHub pre-release, then
  rewrites `version` and `sha256` in `Casks/litenotch.rb` of the tap
  repository `tangnatta/homebrew-litenotch` and pushes that.
- `main` is protected: every change goes through a branch and a pull request
  that passes CI (`rust`, `app`) and is reviewed; never push to `main`.
- To release: bump `version` in `Cargo.toml` in a pull request, merge it,
  then tag the merged commit:
  `git fetch origin && git tag v<version> origin/main && git push origin v<version>`.
- The cask lives in the tap repository (`brew install --cask
  tangnatta/litenotch/litenotch`). The release job writes to it with a
  deploy key that can reach only that repository (secret `TAP_DEPLOY_KEY`;
  to rotate it, add a new write deploy key to the tap and replace the
  secret). Edit the cask there by hand except `version` and `sha256`.
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
    the root helper command. The helper reads the pipe four characters at a
    time and only compares them with `0` and `1`; it never runs what it
    read, and anything else ends it with sleep restored. What remains: while
    LiteNotch runs and after the user gave the password once, another
    process of the same user could write to the pipe and keep the Mac awake
    with the lid closed (by switching it off and on it can do so beyond the
    cap, which guards against forgetting, not against such a process). It
    cannot do more than that.
  - Copies the clipboard history would not keep (off, concealed, excluded
    app) never reach disk; files of dropped copies are pruned at once, and
    with "Keep on restart" off the clips folder is emptied on quit.
  - Socket notifications cannot use the core's own sources (`agent`,
    `litenotch`, …) or the captured-banner group; they get "(script)".
  - The app and CLI are signed with the hardened runtime (no `DYLD_*`
    injection to borrow the Accessibility permission). Keep it on. The app
    has one entitlement, `com.apple.security.automation.apple-events`, so
    macOS can ask whether it may control the terminal.
  - With that permission LiteNotch could tell the terminal to do anything,
    so the scripts it sends are fixed text that only select a tab and raise
    a window (no `do script`, no `write text`; tested). The terminal device
    is accepted only as `ttys` plus one to four digits, in the core and
    again in the shell, and is passed to `osascript` as an argument, never
    written into a script. The CLI drops any `litenotch_tty` already in a
    payload and adds its own.
  - The socket lives in a 0700 directory with mode 0600; server and CLI both
    check the peer uid. A request line must arrive within 5 s in total.
- Anything that moves continuously in the shell (the equaliser bars) must be
  a Core Animation layer animation, not a SwiftUI animation: the SwiftUI
  version re-rendered the notch every frame and cost 9 % CPU while music
  played. `scripts/bench.sh` only measures idle, so check by hand with
  something playing after touching the closed-notch views.
- Read only pasteboard types the copying app declared (its first item's
  `types`). Asking for another type (PNG when it copied TIFF, RTF when it
  copied HTML) makes the system convert the data, which cost seconds of CPU
  on large content.
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

`scripts/bench.sh` runs the app in fixed scenarios, each in its own empty
data directory, measures CPU over a 20 s window after an 8 s settle, and
the physical memory footprint:

| Scenario | What runs | CPU | Memory |
|---|---|---|---|
| idle | nothing | ≤ 0.5 % | ≤ 30 MB |
| timer | countdown running (digits redraw each second) | ≤ 1.0 % | ≤ 30 MB |
| music | a stand-in track playing (`scripts/bench/nowplaying-fake.c`) | ≤ 1.0 % | ≤ 30 MB |
| panel | the panel open on Home | ≤ 1.5 % | ≤ 40 MB |

Bundle ≤ 15 MB; Rust line coverage ≥ 90 %. The app reads a few
`LITENOTCH_BENCH_*` variables (start-up commands, open the panel, a stand-in
now-playing library) only when `LITENOTCH_DATA_DIR` is set too; see `Bench`
in `macos/Sources/LiteNotch/main.swift`. Add a scenario here when a feature
adds steady work (a timer, an animation, a poll). RSS is about 65 MB but
mostly shared framework pages, so the budget is on physical footprint.
Single runs occasionally show a short burst (an outside event such as a
copy landing in the window); a real regression repeats.

A feature was removed for cost: bars that followed the music through a
Core Audio tap cost about 3 % CPU and 7 MB while playing, against 0 % for
the plain animation.

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

- Before a public release (security review, Nov 2026): compile the
  `LITENOTCH_BENCH_*` switches out of release builds (bench a separate
  build), stop `LITENOTCH_DATA_DIR` from chmod-ing a folder LiteNotch did
  not create, downsample now-playing artwork and bound pasteboard text
  before converting it, Developer ID signing + notarization (then drop the
  cask's quarantine removal), and `cargo audit` in CI.
- Closed-lid mode asks for the password once per run of LiteNotch. Asking
  only once ever needs a launchd daemon via SMAppService, which needs a
  Developer ID; it would replace the prompt and the helper.

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
- Raising a session's own terminal window: the Terminal script was run by
  hand (it finds a tab by its device and raises it), and the CLI finds the
  device. Not exercised: the click in the real app, macOS's "LiteNotch wants
  to control Terminal" question (which, like Accessibility, an ad-hoc signed
  build has to be asked again after an update), and the iTerm2 script
  (written from its scripting dictionary, never run).
- The Floating notch style has been seen on a Mac without a notch only, not
  on one with a notch.

- Unverified against a live Claude Code session: whether the terminal's own
  permission dialog is delayed while the hook waits for the notch.
- Closed-lid mode's helper is tested as the real shell loop with `pmset`
  swapped for a log (on, off, on again, pipe closed, process gone, junk, the
  cap, a pipe that cannot be opened). The real admin prompt and the real flag have not been exercised
  since the helper moved from a polled sentinel file to the pipe.
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
