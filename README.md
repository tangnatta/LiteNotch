<img src="macos/Icon/icon-256.png" width="128" alt="LiteNotch icon: a feather inside a screen with a notch">

# LiteNotch

LiteNotch turns the notch on your MacBook into a small control centre: what's
playing, a focus timer, your next meeting, your clipboard history,
notifications, and, if you code with Claude Code, your AI agent's questions and usage, all one hover
away. It stays out of the way the rest of the time and uses almost no
battery.

> **Early beta.** It works day to day on the developer's Mac, but expect rough
> edges. Apple silicon, macOS 14 or later.

| | LiteNotch |
|---|---|
| App size | 7 MB |
| Memory while idle | 15 MB |
| CPU while idle | under 0.5 % |

## Install

### With Homebrew

```sh
brew install --cask tangnatta/litenotch/litenotch
open -a LiteNotch
```

To update to the latest release:

```sh
brew update
brew upgrade --cask litenotch
```

`brew update` fetches the newest version from the tap first; without it,
Homebrew may still think the version you have is the latest. After an
update, macOS forgets LiteNotch's Accessibility permission: if you read other
apps' notifications, use **Reset and ask again** in the inbox once.

Uninstall with `brew uninstall --cask litenotch` (add `--zap` to also delete
settings and history).

Because this beta isn't notarized by Apple, the cask removes macOS's
"downloaded from the internet" flag after installing, so Gatekeeper doesn't
check the app. If you'd rather check it yourself, compare
`shasum -a 256` of the zip with the `.sha256` file on the release page, or
build from source. Recent Homebrew versions print a warning that the cask's
`postflight` is deprecated; that is this step, and it still works.

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

<img src="docs/preview/overview.gif" width="680" alt="The closed notch showing what's playing, then opening on Home, Timer, Clipboard and Agents">

**Open the notch** by moving the pointer onto it, or by clicking it. Move
away or click anywhere else to close it. Tabs on the left side of the bar
switch views; the icons on the right are quick controls. **Home** shows
everything at a glance: what's playing, your timer, your next calendar
event, your AI sessions and the latest notification. Click any of them to go
there.

The previews on this page are drawn by the app's own screens with sample
data, a second at a time. They leave out motion: in the app the notch
springs open, the bars move with the music and long titles scroll.

### Music

<img src="docs/preview/music.gif" width="680" alt="A new song's title shown for a moment in the closed notch, then the Music tab">

Artwork, progress and play / pause / skip for whatever is playing, in any
app: Music, Spotify, or a browser tab. While something plays, the closed
notch shows its artwork, and a new song shows its title for a moment.

### Focus timer

<img src="docs/preview/focus.gif" width="680" alt="A focus session counting down in the closed notch and on the Timer tab, then the five-minutes-left heads-up and the line after a break">

**Focus** is a pomodoro: work, short break, repeat. The closed notch counts
down, with a timer icon while you focus and a leaf during a break. A sound
plays when a session or a break ends (choose it, or turn it off, in
**Settings › Timer**).

### Meeting timer

<img src="docs/preview/meeting.gif" width="680" alt="A sprint review agenda, running item by item, then an item running over in red">

**Meeting** runs an agenda item by item (stand-up, sprint review, planning,
retro, or your own) and shows when an item runs over.

### Countdown

<img src="docs/preview/countdown.gif" width="680" alt="A plain countdown set, started and shown in the closed notch">

**Timer** is a plain countdown: click the time in the circle and type `25`,
`1:30` or `1h 30m`. Any `− 12 +` number (an agenda item's minutes, a timer
length) can be clicked and typed too.

### Clipboard

<img src="docs/preview/clipboard.gif" width="680" alt="Clipboard history with previews of an image and of copied files, and recent colours">

Everything you copy, searchable. Click an item to copy it again. Text copied
with formatting keeps it; the **Aa** button copies it as plain text. Images
and files show a preview. Pin what you want to keep. Password-manager copies
are skipped. The **eyedropper** in the bar picks a colour from anywhere on
screen: it's copied as `#RRGGBB`, and recent colours sit at the top.

### Agents

<img src="docs/preview/agents.gif" width="680" alt="A Claude Code permission request with Deny, Answer in Terminal and Allow, the session list, the waiting dot and the usage page">

For Claude Code users: approve or deny each session's requests without
switching windows, see what every session is doing, and see your usage
limits and a 7-day summary. See [Claude Code](#claude-code).

### Inbox

<img src="docs/preview/inbox.gif" width="680" alt="A notification dropping from the notch, then the inbox">

Notifications from LiteNotch, Claude Code, and, if you allow it, other apps
(the **bell**). Click one to open where it came from.

### Keep awake

<img src="docs/preview/keep-awake.gif" width="680" alt="The cup in the closed notch while the Mac is kept awake, then the keep-awake settings">

The **cup** keeps the Mac awake. Options in **Settings › Keep awake** include
a timer, a battery limit, and staying awake with the lid closed (asks for
your password once; turns itself off when LiteNotch quits).

The **gear** opens Settings: everything adjustable, by feature.

### What the closed notch shows

<img src="docs/preview/notch-priority.gif" width="680" alt="The closed notch counting down to a meeting with the focus session beside it, then Settings › Notch with its preview">

When several things are running, the closed notch shows the most pressing
one on the left and the next one, dimmed, on the right. Out of the box the
order is: a meeting agenda you are running, an event about to start, a
countdown timer, a focus session, music, keep awake, a working agent. So
with a focus session running and a meeting five minutes away, you see the
countdown to the meeting first and your focus time beside it.

- A permission request or a notification still takes the whole notch while
  it is up.
- A small dot appears while a Claude Code session is waiting for you. It
  goes when you click that session in the notch, answer it, or bring its
  terminal window to the front.
- When a meeting starts during a focus session, its notification has a
  **Pause focus** button.
- During a focus session only what cannot wait comes through: permission
  requests, meeting reminders, finished timers and the last usage warning.
  The rest is delivered at the break.

Change any of this in **Settings › Notch**: reorder the list, switch an
activity off to keep it on Home only, show one activity instead of two, or
turn the dot off. The preview at the top shows the result for a few typical
situations.

### Heads-ups and reminders

<img src="docs/preview/peeks.gif" width="680" alt="The closed notch showing, one after another: a new song, five minutes left, the eye break face, a reminder to walk, and a line after a break">

For a few seconds the closed notch can show one thing, then go back to what
it was showing. These never land in the inbox. All are set in
**Settings › Timer** (the song one in **Settings › Music**):

- **Heads-up before it ends:** a focus session or countdown shows the time
  left 1, 3, 5 or 10 minutes before it ends.
- **A new song:** its title, when the track changes.
- **A line after a break:** a short line of encouragement when a break
  ends.
- **Eye break** (off unless you turn it on): every few minutes at the
  screen, a blinking face and "Look away".
- **Move** (off unless you turn it on): stretch, walk or drink water, counted
  either from the start of a focus session or from time at the Mac.

Reminders pause while the screen is locked or asleep.

### Calendar

<img src="docs/preview/calendar.gif" width="680" alt="Home showing the next event, the closed notch counting down to it, and the notification with a Pause focus button when it starts">

Turn on **Settings › Calendar › Show calendar events** and LiteNotch follows
the calendars you have in the Calendar app (iCloud, Google, Exchange, and so
on):

- **Home** shows your next event, when it starts and where. Click it to open
  Calendar.
- A notification appears a few minutes before an event (5 by default; set
  it from 0 to 60) and again when it starts. These come through even during
  a focus session.
- From the reminder until the start, the closed notch counts down to the
  event.

All-day events, cancelled events and invitations you declined are left out.
LiteNotch only reads your calendars; it never changes them.

### Appearance

<img src="docs/preview/appearance.gif" width="680" alt="The attached notch, the floating capsule, one row on a display without a notch, the shrunk strip, the light theme and other accent colours">

All under **Settings › General**. The defaults are the original look.

| Setting | Choices |
|---|---|
| **Theme** | System, Dark or Light, for the open panel. |
| **Accent** | The accent colour you chose in macOS (it follows when you change it there), plain black/white to match the theme, one of four presets, or your own: the rainbow swatch opens a strip to drag along, with an eyedropper beside it to take a colour from the screen. |
| **Notch** | **Attached** hangs from the top edge in the notch's own shape. **Floating** is a small capsule inside the menu bar, with notifications and the open panel floating just below it; it suits a Mac or an external display without a notch. Without a notch, both styles show what's running in one row across the middle, since there is no camera to leave room for. |
| **Closed notch** | **Always dark**, or **Match theme** so the closed notch and notifications turn white in the light theme. Offered only on a display without a notch: around a real notch, which is always black, it stays dark. |
| **Shrink** | On a Mac with a notch: **Always** keeps the sides of the notch clear while it is closed (peeks, notifications and permission requests still show). On a display without a notch: **Default** keeps the closed notch as it is. **When empty** shrinks it to a thin strip at the top edge while it has nothing to show. **Always** keeps it a strip whenever it is closed, except for the few seconds of a new song or a timer about to end. |
| **Panel** | **Solid**, or **Glass** to draw the open panel with macOS 26's Liquid Glass. Approval requests are always shown on the solid panel so they stay readable. |

### What macOS may ask for

LiteNotch works without any permission. Four optional features need one:

- **Other apps' notifications:** turn on in **Inbox**, then allow LiteNotch
  in **System Settings › Privacy & Security › Accessibility**. macOS forgets
  this permission when LiteNotch is updated; use **Reset and ask again** in
  the inbox to restore it.
- **Going to a session's own terminal window:** the first time you click a
  Claude Code session, macOS asks whether LiteNotch may control Terminal (or
  iTerm2). Allow it and the click raises that session's window and tab. If
  you don't, the click still brings the terminal app forward.
- **Calendar:** the first time you turn it on, macOS asks whether LiteNotch
  may see your calendars. If you said no, allow it under **System Settings ›
  Privacy & Security › Calendars** (choose **Full Access**; LiteNotch only
  reads). Like Accessibility, macOS may ask again after an update.
- **Keep awake with the lid closed:** asks for your administrator password
  the first time you turn it on. After that you can normally switch it off
  and on without typing it again until you quit LiteNotch. The mode turns
  itself off after 12 hours, and if macOS stops honouring it for any reason
  LiteNotch tells you and asks for the password the next time.

## Claude Code

LiteNotch can show Claude Code's permission requests in the notch, so you
can approve or deny them without finding the right terminal window.

1. Open **Agents** and click **Connect Claude Code**, or run
   `litenotch hooks install`.
2. Start a new Claude Code session. It appears under **Agents**, and its
   requests open the notch with **Allow**, **Deny**, or **Answer in Terminal**.

Clicking a session brings its terminal window to the front (the exact
window and tab in Terminal and iTerm2, the app in other terminals). Sessions
that were already running pick this up at their next prompt. If LiteNotch isn't
running, Claude Code behaves exactly as before. **Disconnect** undoes it (a
backup of your settings is kept as `settings.json.litenotch-backup`).

Only one copy of LiteNotch should be connected. If you have run other
copies (a test build, the app from a different folder), LiteNotch tells you
at start and **Settings › Agents** offers **Remove them**; connecting also
replaces any other copy's hooks.

To also see your **usage limits**, click **Show usage limits** in
**Settings › Agents**. It makes LiteNotch your Claude Code status line and
keeps the one you already have; **Stop showing usage limits** gives it back.

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
- Closed-lid mode needs your password once each time LiteNotch is started.

Found a problem? [Open an issue](https://github.com/tangnatta/LiteNotch/issues).

## Build from source

```sh
brew install rustup && rustup default stable   # once
export PATH=/opt/homebrew/opt/rustup/bin:$PATH
scripts/build-app.sh          # → dist/LiteNotch.app
open dist/LiteNotch.app
```

`scripts/previews.sh` redraws the previews on this page (needs `ffmpeg`).

Developers: [CLAUDE.md](CLAUDE.md) covers the architecture, commands,
tests, performance budgets (`scripts/bench.sh`) and the release process.
Tests: `cargo test --workspace` and `swift test --package-path macos`.

## License

LiteNotch is free software under the [GNU General Public License v3.0](LICENSE).
You can use, change and share it; if you distribute a modified version, you
must share its source under the same license.
