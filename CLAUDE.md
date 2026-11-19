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
crates/platform  litenotch-platform  macOS calls: pasteboard, IOKit power assertion, pmset, osascript, closed-lid helper, now-playing helper process, afplay
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
  feature modules (pomodoro, timer, meeting, clipboard, colours, notify,
  caffeine, media, agent, usage, calendar, analytics). Inputs go in with a timestamp (`apply(Input, now_ms)`,
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
- **What the closed notch shows** (`Core::compact`, `settings.notch`). A
  pending approval, then a banner, then a peek, take it alone. Otherwise the running
  activities are ranked by `notch.order` (default `LIVE_ORDER`: meeting
  agenda, event about to start, countdown, pomodoro, media, keep awake,
  working agent; deadlines other people wait on, then ones the user set,
  then things that are merely on), those in `notch.hidden` left out. The
  first is `compact`; with `notch.two_places` the second is
  `compact_secondary`. `waiting` (the dot, `notch.waiting_dot`, agents only) is true
  while a session is `WaitingInput` or an agent notification is unread.
  `agent_seen` clears it for one session until that session's next hook
  event: the shell sends it when the session or its notice is clicked,
  and when the session's terminal comes to the front
  (`AgentAttentionObserver`: on app activation and when a session starts
  waiting, never on a timer). For Terminal and iTerm2 it asks which tab
  is in front and clears only the session on that device; where that
  cannot be told (another terminal, or control not yet allowed, which is
  checked without ever raising the permission question) the app being in
  front counts for all its waiting sessions. Switching tabs inside a
  terminal that is already in front is not noticed.
  The shell draws one activity exactly as before (icon left, value right);
  two as icon + time on each side, the second dimmed
  (`ClosedActivityView`, widths in `NotchGeometry.wingWidth(for:island:)`).
  On a display without a notch there is no camera to keep clear, so in
  both styles the same content is one row with no gap in the middle
  (`NotchLayout.oneRow`, `NotchGeometry.rowWidth`): one activity is its
  icon then its value through the middle, two sit side by side; never
  narrower than the idle shape.
  Nothing rotates. Settings › Notch (`NotchPriority.swift`) edits the
  order with a preview drawn by the real closed-notch view; its
  `NotchPriority.resolve` repeats the core's rule and both are tested
  against the same cases. The banner that an event is starting carries
  `action: pause_focus` while a focus session runs; its button sends
  `pomodoro_pause` (pause only, never resume).
  Focus policy: only High passes a focus session. High are approvals'
  own path, calendar notices, finished timers and pomodoro phases, and the
  95 % usage warning; agent "needs input"/"finished" and the 80 % warning
  are Normal and arrive in the "While you were focusing" summary.
  Peeks (`state/presentation.rs`): about 4 s on one of the user's own
  activities, then gone: the track changed (`peek.track_change`) or a
  running countdown has `peek.time_warning_secs` left. Never in the inbox,
  not held by focus. A countdown peek fires when time left crosses the
  mark while running; pausing keeps time left still, so it never repeats.
  Warning times join `next_deadline`, so peeks add no polling.
  Three wellbeing peeks (`ActivityKind::Nudge`), each with an Off choice
  in Settings › Timer. The eye break and Move both count screen time only
  (`Core::is_away`: the shell's `screen_away` or `lid_shut`, which is the lid
  shut in closed-lid mode with no other display, so caffeine holding a shut
  Mac awake does not count); they never follow the focus timer (an earlier
  `move_counts` choice is gone, old files still load):
  the eye break (`peek.eye_break_mins`, 0 = off, the default; every few
  minutes of screen time), a quick blinking `>_<` with "Look away" for 3 s
  (`EYE_MS`) so the user blinks; the Move reminder (`peek.move_mins`, 0 =
  off, the default), one of
  `MOVE_LINES` (stretch, walk, water) picked from `now_ms` and never the
  same kind twice in a row, 8 s (`NUDGE_MS`) so its line can scroll; and a
  line after a completed (not skipped) break (`peek.break_quote`, on by
  default), one of `BREAK_LINES` picked from `now_ms`, which waits until
  the "Break over" banner (or an approval) is gone and is dropped after
  60 s. A nudge is not cut short: a countdown or track peek arriving
  meanwhile waits and follows it (with a 25-minute focus and Move every
  20, the Move and the 5-minute warning both fall at 20 minutes); when
  the eye break and Move fall together, Move shows. The shell reports the
  screen locked, the displays or the Mac asleep, or another user's
  session in front (`ScreenPresenceObserver`, system notifications, no
  polling) as `screen_away`; reminders are skipped then and screen-time
  counts start over. A mark seen over 60 s late was slept through and is
  skipped too, so it needs no word from the shell.
  Still working on a break (`peek.still_working`, on by default, Settings ›
  Timer): at 1:00, 2:30, 4:00 … into a running break the core sets
  `wants_idle`; the runtime then reads the keyboard and mouse idle time
  once (`platform::idle`, `CGEventSourceSecondsSinceLastEventType`, no
  permission) and sends `Input::InputIdle`. Used within 30 s counts as
  working: the first two times a `StillWorking` nudge, after that a banner
  whose `skip_break` button sends `pomodoro_skip`. An idle user gets
  nothing; a new break starts gently again. No polling: a 5-minute break
  costs three readings. Reading the screen without touching the keyboard
  or mouse counts as being on the break.
- **Day progress** (`settings.day`, off by default, `core::day`): fixed
  office hours (default 10:00–18:00, Mon–Fri). On a working day the view
  model carries today's `day: {start_ms, end_ms, line}` and the closed
  notch can rank `ActivityKind::Day` last in `LIVE_ORDER` (`ends_at_ms` =
  end, `total_secs` = length). The shell works out the percentage:
  `−12%` before the start, `37%`, `+19%` past the end
  (`Format.dayProgress`), and redraws only when the whole percent changes
  (`DaySchedule`). The core wakes once at local midnight. Settings › Day
  holds it all. The icon (`day.icons`) is Default, the time of day
  (`Format.daySymbol`): horizon before the start, sun until 3 h before
  the end, horizon, then moon; or Grow a tree (`GrowthIcon.swift`,
  `Format.growthStage`): seed before the start, two leaves to 33 %,
  sapling to 66 %, young tree, then a full tree after the end. It never
  withers. With the tree the closed notch's icon and value are green
  (`NT.grow`), the same all day; Home stays grey. Home's big left card (Settings › Home,
  `day.home_card`: Auto, Day, Music) shows the day instead of now
  playing; Auto gives way to music while it plays. The line under the
  number is one of `DAY_LINES`, one per day.
  The principle: people have a life before and after work, so nothing
  here limits or judges their time. No bar, no colour, no overtime
  warning, no line that says to finish or stop.
- **Sound** (`settings.sound`, on by default, "Glass"): one of the 14
  system alert sounds when the countdown timer, a focus session or a break
  ends (not on skip, reset or pause). The core emits `Effect::PlaySound`
  with a name from `SOUNDS`; the platform layer starts `afplay` on that
  file in `/System/Library/Sounds` and lets it finish. `sound_preview`
  plays one while the user chooses. Names are letters only, checked in
  the core and again when the path is built.
  The pomodoro's icon is a timer while focusing and a leaf during a break
  (`ClosedActivityView.pomodoroSymbol`, from the core's phase label).
- **Shell layout.** Tabs: Home (dashboard: now playing, timer, agents,
  inbox), Music, Timer, Clipboard, Agents (Sessions | Usage) on the left of
  the notch; keep-awake toggle (cup icon), Inbox, Settings on the right.
  Settings is a sidebar of feature categories (`AppModel.settingsSection`,
  so other tabs can deep-link). Hover opens after a delay, a click opens at
  once, a click on the tab-bar background closes.
  Opening (hover or click) lands on the page of a banner that showed since
  the panel last closed (within 5 min; agent banners → Agents › Sessions,
  others without a tab → Inbox), else on Home once the panel has been
  closed 5 min, else on the last tab (`PanelState.landing`).
  Two notch styles (`appearance.notch_style`, Settings → General): Attached
  (default, the original geometry; keep it pixel-identical for existing
  users on a display with a notch; without one it uses the one row above) and Island (called Floating before; saved settings with `floating` still load, `serde(alias)`), a capsule inset 3 pt inside the menu bar or notch
  band, with the toast overlapping it by 8 pt and the panel 6 pt below
  (`islandPanelDrop`; at 0 it looked hung from the bar).
  Island sizes derive from the measured menu bar height; all geometry
  lives in `NotchLayout` (`Geometry.swift`).
  The accent (`appearance.accent`) is `#RRGGBB`, `system` (macOS's accent,
  re-read on `NSColor.systemColorsDidChangeNotification`) or `mono` (the
  primary text colour of each scheme: white on dark, black on light).
  `NT.accent` is one global, so tests that change it must put it back.
  Settings offers system, mono, four presets and a hue strip (fixed
  saturation, `ColorMath.fromHue`) with the screen eyedropper beside it.
  The theme (`appearance.theme`) styles the open panel. The closed notch
  and the toast stay black unless `appearance.closed_notch` is `theme`
  (Settings → General → Closed notch: Always dark | Match theme); the
  default keeps them pixel-identical to before. On a display with a
  hardware notch (`safeAreaInsets.top > 0`, `PanelState.hasNotch`)
  they are always black and that row is hidden, since the camera housing
  cannot turn white.
  `appearance.shrink` (Settings › General › Shrink, also only without a notch):
  Off (default), WhenEmpty (nothing to show and no waiting dot) or Always
  (except during a peek) turns the closed shape into a 120 x 8 pt strip
  flush with the top edge, in either style (`NotchLayout.minimized`,
  decided by `NotchLayout.shrinks`). With a hardware notch only Always
  is offered and it means "nothing beside the notch while closed": the
  shrunk shape there is the bare notch, full height, because an empty
  notch already is just the notch and a strip thinner than the camera
  housing could not be found with the pointer. Peeks, banners and
  approvals still show.
  Four layouts exist (camera housing or not, Attached or Island) and
  the user can choose either style on either machine. In each, what the
  closed notch draws must fit the shape `NotchLayout.size(for:content:)`
  gives it; `ClosedSpaceTests` measures the drawn content for every
  activity, pair and the dot in all four, and for the Settings preview.
  The preview once sized the shape by one rule and laid the content out
  by another, which put the icons outside the capsule.
  `appearance.material` (Settings → General → Panel): Solid (default) or
  Glass, macOS 26 Liquid Glass for the open panel. The closed notch and
  the toast are glass too only without a hardware notch and with Closed
  notch: Match theme (`closedDrawsGlass`), and the glass then stays through
  opening and closing; with a notch, or Always dark, they stay black to
  blend with the camera housing, and the Shrink strip stays solid. Glass needs a
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
- **Questions** (`AskUserQuestion`): the `PermissionRequest` for that tool
  carries `questions` (`agent::Question`: header, text, `multi_select`,
  options), parsed and sanitized by `parse_questions`; anything that would be
  cut short (over 4 questions, 8 options, or the length caps) gives none and
  the prompt falls back to the plain detail view. The shell answers with
  `agent_answer` (one list of labels or typed text per question); the core
  checks the shape and lengths (`Agents::answer`, no answer = request stays
  pending) and the CLI prints `allow` with `updatedInput` = the original input
  plus `answers` keyed by question text (`Response::Answer`; multi-select
  joins labels with ", "). The raw input stays in the core (`#[serde(skip)]`).
  Verified against a live Claude Code (Nov 2026): it accepts `updatedInput.answers`
  from the hook, for single, multiple and several questions, including typed
  answers of the user's own (single choice takes one; multiple choice up to
  `MAX_ANSWERS` = 16 in all). Its own question tool always has 2+ options, so the
  no-option (open) layout is only exercised with a hand-made hook payload.
  The shell form is `QuestionView.swift` (`QuestionDraft` holds the rules:
  single choice sends on click, several questions are a stepper, an open
  question is a typing box).
- **One copy's hooks only.** Each copy of the app registers its own CLI
  path, so test builds and moved installs used to pile up in
  `~/.claude/settings.json`: five hook processes per Claude Code event,
  all reporting to whichever LiteNotch was running, and the status line
  wrapped once per copy. Now `install` removes every other LiteNotch hook
  first (`'<any path>/litenotch' hook`), `install_statusline` wraps the
  user's own command after peeling off every LiteNotch layer, and
  uninstalling restores that command. `hooks_file::other_copies` lists the
  other copies found in hooks or status line and which no longer exist on
  disk; the runtime reports the count in `agents.other_copies` (and
  `_missing`), posts one notice at start, and `hooks_clean` (Settings ›
  Agents › Remove them) takes them out while leaving this copy and
  everything that is not LiteNotch's alone. A command counts as
  LiteNotch's only in exactly the form LiteNotch writes it.
- **Progress ring** (`settings.media.progress_ring`, on by default, Settings ›
  Music): while a track with a known length plays, the closed notch's artwork
  sits inside a ring that fills clockwise from the top (`ClosedArtwork`,
  `ProgressRing`): a rounded square in Attached, a circle in Island. The ring
  takes its space from the artwork (artwork 20 pt → 15 pt inside the same 20 pt),
  so nothing around it moves. It is one Core Animation `strokeEnd` animation from
  where the song is to its end, started again only when the position, play state
  or length in the view model changes; no timer, no SwiftUI animation. Paused,
  it stands still. The core only keeps the choice.
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
- **Calendar** (off by default, `settings.calendar`): the shell reads the
  system's calendars with EventKit (`CalendarObserver.swift`) and sends the
  timed events of the next 48 hours as one `calendar_events` command, which
  replaces the core's list. It reads again only when EventKit says the
  database changed, at midnight, after waking and when the setting turns
  on; there is no poll, and an unchanged list is not sent. The core
  (`core::calendar`) owns the alerts: a reminder `alert_minutes` before
  (0 to 60, 0 = none) and a notice at the start (not later than 2 minutes
  after it, so nothing stale follows a long sleep), both High priority so
  they pass a focus session, the second replacing the first. Which notices
  were given is kept per event id and start time, so a re-read repeats
  nothing and a moved event is announced again. From the reminder to the
  start the closed notch shows `ActivityKind::Calendar` with the start as
  `ends_at_ms`. The view model lists up to 12 events with absolute times;
  the shell works out "in 5m" and skips ended ones itself. All-day,
  cancelled and declined events are left out (the last two in the shell).
  Needs the calendar permission (`NSCalendarsFullAccessUsageDescription`,
  entitlement `com.apple.security.personal-information.calendars`); full
  access is the only level that allows reading. Nothing is written to the
  calendar and no event text is stored on disk.
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
- **Launch at login** (Settings › General, `LoginItem.swift`): the shell only,
  through `SMAppService.mainApp`; the core and saved settings know nothing
  of it, because the user can also change it in System Settings › Login
  Items and macOS is the one source of truth. `AppModel.launchAtLogin` is
  re-read whenever the row appears, and a failed register shows what the
  system really reports. Off by default and never registered by the app on
  its own (a benchmark run cannot enrol anything). `requiresApproval`
  shows an Open button for Login Items. macOS may refuse a copy outside
  /Applications (`.notFound`); not yet tried with a real login, and it is
  tied to the app's path, so a Homebrew upgrade that replaces the bundle
  in place keeps it.
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
- **Lid choice and battery limit** (`caffeine::CaffeineConfig`): `lid_closed`
  is a saved setting, not an action. Turning keep awake on (`activate` from off)
  brings the lid with it when it is set (`apply_lid`), turning it off takes
  both away, and changing the choice while keep awake is on applies at once;
  while it is off, changing it only saves it. Picking another duration is not
  turning it on, so it never asks for the password again. One
  `battery_floor_pct` covers every mode (0 = no limit); there is no lid-only
  limit and no AC-only switch (settings saved with `lid_battery_floor_pct` or
  `lid_requires_ac` still load, the keys are ignored). The `caffeine_lid`
  command sets the choice.
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
- `.github/workflows/codeql.yml` is code scanning (Actions, C, Rust, Swift)
  of `main`, weekly (Mondays) and on demand from the Actions tab; not on
  pull requests, because the Swift scan takes about 18 minutes. Run it by
  hand before a release. It exists because GitHub's
  default CodeQL setup cannot build the Swift shell: that needs the Rust
  static library first, which this workflow builds before CodeQL starts
  tracing. Default setup has to stay off, or GitHub rejects these results.
- `.github/workflows/release.yml` runs on a `v*` tag. The tag must equal the
  `version` in the root `Cargo.toml`. It tests, builds, zips
  `LiteNotch-<version>-arm64.zip`, publishes a GitHub pre-release, then
  rewrites `version` and `sha256` in `Casks/litenotch.rb` of the tap
  repository `tangnatta/homebrew-litenotch` and pushes that.
- `main` is protected: every change goes through a branch and a pull request
  that passes CI (`rust`, `app`) and is reviewed; never push to `main`.
- To release: bump `version` in `Cargo.toml` and add a `## <version>` section to
  `CHANGELOG.md` (what is new, improved, fixed) in a pull request; the release
  fails early without the section and copies it into the GitHub release notes. Merge it,
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

## Core and shell are held to each other

`core::schema` writes `macos/Fixtures/schema.json` with the fixtures: the
limits the core really keeps (measured by saving extreme values through
`SetSettings`), the sounds, and every enum's variants (listed with an
exhaustive `match`, so a new variant does not compile until listed).
`ParityTests` (Swift) compares the shell with it: the same enum values, sounds
from the core, every Settings control inside what the core keeps
(`SettingsLimits`, the one place the ranges are written), every setting the
core writes surviving a decode and encode unchanged, and every top-level
view-model field known to the shell. A core setting with no control must be in
`ParityTests.withoutControl` with a reason. Regenerate with the fixtures
command after changing the core.

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
    the same way. So is calendar event text: anyone can send an invitation.
    A calendar notification only opens Home; no link from an event is
    followed.
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
    has two entitlements: `com.apple.security.automation.apple-events`, so
    macOS can ask whether it may control the terminal, and
    `com.apple.security.personal-information.calendars`, so it can ask
    whether LiteNotch may read the calendars.
  - With that permission LiteNotch could tell the terminal to do anything,
    so the scripts it sends are fixed text that only select a tab and raise
    a window, or only read which tab is in front (no `do script`, no
    `write text`; tested). The terminal device
    is accepted only as `ttys` plus one to four digits, in the core and
    again in the shell, and is passed to `osascript` as an argument, never
    written into a script. The CLI drops any `litenotch_tty` already in a
    payload and adds its own.
  - The socket lives in a 0700 directory with mode 0600; server and CLI both
    check the peer uid. A request line must arrive within 5 s in total.
- Every tab must fit the space the open panel gives it (220 pt high);
  anything longer scrolls inside a `NotchScroll`. A fixed column that is
  too tall pushes the whole tab past the bottom edge, and the scroll view
  beside it then cannot reach its last rows: the Settings section list
  did this once it had ten entries. `OverflowTests` checks every tab,
  pane and Settings section; add new ones there.
- Anything that moves continuously in the shell (the equaliser bars, the
  scrolling title of a track-change peek, `MarqueeText`, the eye-break
  face's blink, `BlinkingFaceNSView`) must be
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
- **The one outgoing request is the update check** (`core::update`,
  `platform::update`): `Effect::CheckUpdate` runs `/usr/bin/curl` (HTTPS only,
  10 s, size-limited, a generic user agent, no identifier or version sent) against
  GitHub's releases API for this repository only, from the "Check for updates"
  button or the opt-in `general.check_updates` daily check (off by default). What
  comes back is only data: `update::checked` accepts a version and a release page
  under `RELEASES_PAGE` with a plain character set, and the shell opens only such a
  page and copies only its own fixed `brew update && brew upgrade --cask
  litenotch` (same text as the core's `BREW_COMMAND`, checked by `ParityTests`).
  Nothing is downloaded or run; the "update" notification source is reserved.
  There is no in-app updater (a Developer ID and notarization come first).
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
| island | the Island style with a countdown running | ≤ 1.0 % | ≤ 30 MB |
| glass | the panel open on Home, drawn with Liquid Glass | ≤ 1.5 % | ≤ 40 MB |
| calendar | an event about to start (the closed notch counts down to it) | ≤ 1.0 % | ≤ 30 MB |
| pair | two countdowns side by side in the closed notch | ≤ 1.0 % | ≤ 30 MB |
| closedglass | the closed notch drawn with glass (Island, Match theme, light) and a countdown; needs a display without a notch | ≤ 1.0 % | ≤ 30 MB |

Bundle ≤ 15 MB; Rust line coverage ≥ 90 %. The app reads a few
`LITENOTCH_BENCH_*` variables (start-up commands, open the panel, a stand-in
now-playing library) only when `LITENOTCH_DATA_DIR` is set too; see `Bench`
in `macos/Sources/LiteNotch/main.swift`. Add a scenario here when a feature
adds steady work (a timer, an animation, a poll). RSS is about 65 MB but
mostly shared framework pages, so the budget is on physical footprint.
Single runs occasionally show a short burst (an outside event such as a
copy landing in the window); a real regression repeats. Measured Nov 2026
on an M-series MacBook: idle 0.05–0.30 % and 15–16 MB, timer 0.15–0.35 %,
music 0.45 %, panel 0.70 % and 22 MB, island 0.35 %, glass 0.25 % and
28 MB, calendar 0.20–0.25 % and 16 MB, bundle 6.5 MB (EventKit added 0.2). (One run right after a build showed idle at 2.9 % and
timer at 5.5 %; two repeats of each did not.) Glass is measured over a
still desktop only, not over moving content.

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

- Two activities in the closed notch, the waiting dot, the Pause focus
  button and Settings › Notch are covered by unit tests and snapshots
  only; none has been used in the running app.
- The calendar: the core's alerts and the observer's logic are unit-tested
  (the observer against a fake store). Not exercised: the real EventKit
  store, macOS's permission question, and a real event coming due in the
  running app. A benchmark run with start-up commands does not start the
  observer, so it never raises that question. Not built: a "Join" button for
  the meeting link, choosing which calendars count, and all-day events.
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
- The Island notch style has been seen on a Mac without a notch only, not
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
  app small: file shelf, Codex usage, listening ports.
