# LiteNotch

LiteNotch turns the notch on your MacBook into a small control centre: what's
playing, a focus timer, your clipboard history, notifications, and, if you
code with Claude Code, your AI agent's questions and usage, all one hover
away. It stays out of the way the rest of the time and uses almost no
battery.

> **Early beta.** It works day to day on the developer's Mac, but expect rough
> edges. Apple silicon, macOS 14 or later.

| | LiteNotch |
|---|---|
| App size | 4 MB |
| Memory while idle | 15 MB |
| CPU while idle | under 0.1 % |

## Install

### With Homebrew

```sh
brew tap tangnatta/litenotch https://github.com/tangnatta/LiteNotch
brew install --cask litenotch
open -a LiteNotch
```

Update with `brew upgrade --cask litenotch`. Uninstall with
`brew uninstall --cask litenotch` (add `--zap` to also delete settings and
history).

Because this beta isn't notarized by Apple, the cask removes macOS's
"downloaded from the internet" flag after installing, so Gatekeeper doesn't
check the app. If you'd rather check it yourself, compare
`shasum -a 256` of the zip with the `.sha256` file on the release page, or
build from source.

### Download

1. Download `LiteNotch-<version>-arm64.zip` from the
   [latest release](https://github.com/tangnatta/LiteNotch/releases).
2. Unzip it and drag **LiteNotch** into **Applications**.
3. Open it. The app isn't notarized by Apple yet, so the first time macOS
   refuses. Go to **System Settings › Privacy & Security**, scroll down and
   click **Open Anyway** next to LiteNotch. After that it opens normally.
   (Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/LiteNotch.app`.)

LiteNotch has no Dock icon. It lives in the notch; quit it from
**Settings › General**.

## Using it

**Open the notch** by moving the pointer onto it, or by clicking it. Move
away or click anywhere else to close it. Tabs on the left side of the bar
switch views; the icons on the right are quick controls.

| Where | What it does |
|---|---|
| **Home** | Everything at a glance: what's playing, your timer, your AI sessions and the latest notification. Click any of them to go there. |
| **Music** | Artwork, progress and play / pause / skip for whatever is playing, in any app: Music, Spotify, or a browser tab. While something plays, the closed notch shows its artwork. |
| **Timer** | Three timers. **Focus** is a pomodoro: work, short break, repeat. **Meeting** runs an agenda item by item (stand-up, sprint review, planning, retro, or your own) and shows when an item runs over. **Timer** is a plain countdown: click the time in the circle and type `25`, `1:30` or `1h 30m`. |
| **Clipboard** | Everything you copy, searchable. Click an item to copy it again. Text copied with formatting keeps it; the **Aa** button copies it as plain text. Images and files show a preview. Pin what you want to keep. Password-manager copies are skipped. |
| **Agents** | For Claude Code users: see each session's status, approve or deny its requests without switching windows, and see your usage limits and a 7-day summary. See [Claude Code](#claude-code). |
| **Inbox** | Notifications from LiteNotch, Claude Code, and, if you allow it, other apps. Click one to open where it came from. |
| **Settings** | Everything adjustable, by feature: appearance (light, dark or automatic, plus your accent colour), timer lengths, clipboard size, keep-awake options, and more. |

Quick controls on the right of the bar:

- **Eyedropper:** pick a colour from anywhere on screen. It's copied as
  `#RRGGBB`, and recent colours sit at the top of Clipboard.
- **Cup:** keep the Mac awake. Options in **Settings › Keep awake** include a
  timer, a battery limit, and staying awake with the lid closed (asks for your
  password; turns itself off when LiteNotch quits).
- **Bell:** the inbox. **Gear:** settings.

### What macOS may ask for

LiteNotch works without any permission. Two optional features need one:

- **Other apps' notifications:** turn on in **Inbox**, then allow LiteNotch
  in **System Settings › Privacy & Security › Accessibility**. macOS forgets
  this permission when LiteNotch is updated; use **Reset and ask again** in
  the inbox to restore it.
- **Keep awake with the lid closed:** asks for your administrator password
  each time you turn it on.

## Claude Code

LiteNotch can show Claude Code's permission requests in the notch, so you
can approve or deny them without finding the right terminal window.

1. Open **Agents** and click **Connect Claude Code**, or run
   `litenotch hooks install`.
2. Start a new Claude Code session. It appears under **Agents**, and its
   requests open the notch with **Allow**, **Deny**, or **Answer in Terminal**.

Clicking a session brings its terminal to the front. If LiteNotch isn't
running, Claude Code behaves exactly as before. **Disconnect** undoes it (a
backup of your settings is kept as `settings.json.litenotch-backup`).

To also see your **usage limits**, make LiteNotch your Claude Code status
line, wrapping the one you already have if you like:

```json
{ "statusLine": { "type": "command",
    "command": "'/Applications/LiteNotch.app/Contents/Helpers/litenotch' statusline -- your-existing-command" } }
```

The command-line tool can post to the notch from scripts too:

```sh
litenotch notify "Deploy finished" "main → production" --priority high --source ci
```

## Privacy

Everything stays on your Mac. Clipboard history is kept in memory unless you
turn on **Keep on restart**. LiteNotch counts how often each feature is used
(never what you copy, play or type) so you can see the counts in
**Settings › Privacy**; nothing is sent anywhere.

Now playing uses a private macOS interface (the same approach other notch
apps use). If a macOS update breaks it, the Music tab stays empty and
nothing else is affected.

## Known limits of this beta

- Apple silicon only; not notarized yet.
- Other apps' notifications are read from the banners on screen, so they
  need the Accessibility permission, which resets on each update.
- Closed-lid mode needs your password each time.

Found a problem? [Open an issue](https://github.com/tangnatta/LiteNotch/issues).

## Build from source

```sh
brew install rustup && rustup default stable   # once
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
scripts/build-app.sh          # → dist/LiteNotch.app
open dist/LiteNotch.app
```

Developers: [CLAUDE.md](CLAUDE.md) covers the architecture, commands,
tests, performance budgets (`scripts/bench.sh`) and the release process.
Tests: `cargo test --workspace` and `swift test --package-path macos`.
