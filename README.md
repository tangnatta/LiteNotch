# LiteNotch

A notch utility for macOS that stays out of the way: focus timer, clipboard
history, media controls, keep-awake, and a place to answer your coding
agent's permission prompts. Rust core, thin SwiftUI shell.

| | LiteNotch |
|---|---|
| App bundle | 3.8 MB |
| Memory while idle | 18 MB |
| CPU while idle | 0.1 % |

Measured with `scripts/bench.sh` on an M5 MacBook Pro, macOS 27.2. "Memory"
is the physical footprint, the figure Activity Monitor shows.

Status: early prototype for early adopters. Apple silicon, macOS 14 or
later. Ad-hoc signed, not notarized yet.

## What it does

- **Pomodoro.** Focus / break cycles with a live countdown in the notch.
  While a focus session runs, low-priority notifications are held and
  summarised afterwards.
- **Agent approvals.** When Claude Code asks for permission to run a tool,
  the notch opens with the complete tool input and Allow / Deny / "Answer in
  terminal". Sessions show as working, waiting, or done.
- **Usage.** 5-hour and 7-day Claude limits with reset times, an alert at
  80 % and 95 %, and a usage page: a 7-day token chart, today's tokens by
  model and by project, and a one-line summary of how today compares with
  your week.
- **Notifications.** A priority queue: an important notification replaces a
  minor one, never the other way round. Anything can post with
  `litenotch notify`. Optionally also shows other apps' banners (see
  below).
- **Clipboard history.** Search, pin, copy back. Skips password-manager
  entries. In memory only unless you turn persistence on.
- **Music.** Whatever macOS reports as playing, from any app including
  browser tabs: artwork in the closed notch, and a page with artwork,
  progress, and play/pause/skip.
- **Keep awake.** A cup icon in the notch's tab bar turns it on and off.
  Timer, battery floor, and an optional closed-lid mode (turns itself off
  if LiteNotch quits or the battery runs low) are in Settings.

**Other apps' notifications.** macOS has no public API for these, so
LiteNotch reads the banners as they appear on screen, which needs the
Accessibility permission. Turn it on in Inbox or Settings › Notifications
and allow LiteNotch under System Settings › Privacy & Security ›
Accessibility. Because the build is ad-hoc signed, macOS asks again after
each rebuild.

**Now playing** relies on a private macOS interface, reached through
`/usr/bin/perl` the way other notch apps do it. If a macOS update closes
that door the Music page stays empty; nothing else is affected. It costs one
small helper process (about 4 MB), which stops when you turn Music off in
Settings.

## Install with Homebrew

```sh
brew tap tangnatta/litenotch https://github.com/tangnatta/LiteNotch
brew install --cask litenotch
open -a LiteNotch
```

This installs `LiteNotch.app` into `/Applications` and the `litenotch`
command-line tool onto your `PATH`.

- **Update:** `brew update && brew upgrade --cask litenotch`
- **Uninstall:** `brew uninstall --cask litenotch` (add `--zap` to also
  delete settings and history in `~/Library/Application Support/LiteNotch`)

Because the app is not notarized, the cask removes macOS's quarantine flag
after installing so that it opens. If you would rather not do that, build
from source instead.

Other apps' notifications need the Accessibility permission (see above).
macOS ties that permission to the app's signature, so you may have to grant
it again after an upgrade.

## Build from source

```sh
brew install rustup && rustup default stable   # once
export PATH=/opt/homebrew/opt/rustup/bin:$PATH

scripts/build-app.sh          # → dist/LiteNotch.app
open dist/LiteNotch.app
```

Quit from the Settings tab.

## Connect Claude Code

In the notch, open **Agents → Install hooks**, or run:

```sh
dist/LiteNotch.app/Contents/Helpers/litenotch hooks install
```

This adds LiteNotch to `~/.claude/settings.json` (the original is kept as
`settings.json.litenotch-backup`) and applies to new Claude Code sessions.
`hooks uninstall` removes it. If LiteNotch is not running, Claude Code
behaves exactly as before.

To show usage limits, make LiteNotch your status line, wrapping the one you
already have if you like:

```json
{ "statusLine": { "type": "command",
    "command": "'/path/to/LiteNotch.app/Contents/Helpers/litenotch' statusline -- your-existing-command" } }
```

## Command line

```sh
litenotch notify "Deploy finished" "main → production" --priority high --source ci
litenotch status            # what the notch is doing, as JSON
litenotch hooks status
```

## Privacy

Everything stays on your Mac. LiteNotch counts how often each feature is
used (never content) so the counts can be shown in Settings; sending them
anywhere is opt-in, off by default, and not implemented yet.

## Development

See [CLAUDE.md](CLAUDE.md) for the architecture, commands, and the rules the
code relies on. Tests: `cargo test --workspace` and
`swift test --package-path macos`.
