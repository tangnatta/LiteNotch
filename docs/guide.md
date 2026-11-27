# LiteNotch guide

The [README](../README.md) shows what LiteNotch does. This page has the
details: the rules behind the closed notch, every appearance option, coding
agents, and what LiteNotch asks of macOS.

- [The closed notch](#the-closed-notch)
- [Heads-ups and reminders](#heads-ups-and-reminders)
- [Appearance](#appearance)
- [Coding agent details](#coding-agent-details)
- [Permissions and privacy](#permissions-and-privacy)
- [Installing without Homebrew's checks](#installing-without-homebrews-checks)

## The closed notch

With several things running, the closed notch shows the most pressing one on
the left and the next, dimmed, on the right. The order out of the box: a
meeting agenda you are running, an event about to start, a countdown, a focus
session, music, keep awake, a working agent, then the work day.

- A permission request or a notification takes the whole notch while it is up.
- A dot means a Claude Code session is waiting for you.
- During a focus session only what cannot wait comes through: permission
  requests, calendar reminders, finished timers and the last usage warning.
  The rest arrives in the break.

**Settings › Notch** reorders the list, keeps an activity on Home only, shows
one activity instead of two, or turns the dot off. Its preview shows the
result for a few typical situations.

## Heads-ups and reminders

For a few seconds the closed notch can show one thing, then go back. These
never land in the inbox. They are set in **Settings › Timer** (the new song in
**Settings › Music**; eye break, water and stretch in **Settings › Day**):

| Heads-up | When |
|---|---|
| **Heads-up before it ends** | A focus session or countdown has 1, 3, 5 or 10 minutes left. |
| **A new song** | The track changes. |
| **A few words after a break** | A break ends (not when you skip it). |
| **Eye break** (off by default) | Every few minutes at the screen: a blinking face and "Look away". |
| **Water** and **Stretch** (off by default) | A gauge falls below 20 %, and again when it runs empty. |
| **Still working on a break** | A break is running and the keyboard or mouse is in use. |

Water and stretch are two gauges that run down while you are at the Mac.
Fill water with **Drank**: a 200 ml cup fills half the tank, and a cup right
after another counts as 50 ml, so spacing them out (15 minutes) counts more.
Fill stretch by tapping **Stretch** once per movement. Show them on Home with
**Settings › Day › Home's big card: Body** (water alone, or water and stretch
side by side). **Auto** shows the gauges when one is low (below 20 %), a new
song for a minute, the gauges again below 50 %, then the day or music. They
replace the older Move reminder; its setting carries over.

Eye break and the gauges count only minutes you are at the Mac: screen on and
unlocked, lid open (or an external display connected). The eye break starts
over and the gauges stand still when you lock the screen, the Mac sleeps or
the lid closes.

## Appearance

All in **Settings › General**; the defaults are the original look. The last
four rows are under **More options**.

| Setting | Choices |
|---|---|
| **Theme** | System, Dark or Light, for the open panel. |
| **Accent** | macOS's accent colour, black/white to match the theme, four presets, or any colour (the rainbow swatch opens a strip and an eyedropper). |
| **Notch** | **Attached** hangs from the top edge in the notch's shape. **Island** is a small capsule inside the menu bar, with notifications and the panel just below it. Without a notch, both show what's running in one row. |
| **Closed notch** | Without a notch only: **Always dark**, or **Match theme** so it turns white in the light theme. A real notch is always black. |
| **Shrink** | With a notch: **Always** keeps the sides of the notch clear while closed. Without one: **When empty** or **Always** turns the closed notch into a thin strip at the top edge. Peeks, notifications and requests still show. |
| **Panel** | **Solid**, or **Glass** for macOS 26's Liquid Glass. Permission requests always use Solid so they stay readable. |

## Coding agent details

Which agent supports what is in the [README](../README.md#coding-agents).

- Connecting adds LiteNotch's hooks to the agent's own settings file:
  `~/.claude/settings.json` (with a backup, `settings.json.litenotch-backup`),
  `~/.codex/hooks.json`, `~/.gemini/settings.json`, or
  `~/.gemini/config/hooks.json` for Antigravity. Sessions already running
  pick it up at their next prompt.
- The command line does the same as **Settings › Agents**:
  `litenotch hooks install|uninstall|status --agent codex` (or `claude`,
  `gemini`, `antigravity`, `all`).
- Codex's usage limits are read from its own session logs, which it updates
  with every reply. After a quiet spell they show as reset until Codex's next
  reply. That log format is Codex's own and may change; if it does, the limits
  stop showing and nothing else is affected.
- **Allow** stays inert for a moment after a request appears, so a click
  already on its way can't approve something you haven't read.
- **Settings › Agents › Wait for my answer** sets how long a request waits
  before the agent asks in its terminal instead.
- Only one copy of LiteNotch should be connected to Claude Code. If you ran
  others (a test build, a copy in another folder), LiteNotch says so at start
  and **Settings › Agents** offers **Remove them**.
- Claude Code sessions started from the Claude desktop app's Code tab use the
  same settings file, so they should appear too (not yet tried). Ordinary
  Claude Desktop chats have no hooks.
- Gemini CLI may need hooks turned on in its settings in some versions.
  Antigravity's connector is built from its documentation and has not been
  run against the real app yet.

## Permissions and privacy

LiteNotch works without any permission. Four optional features need one:

- **Other apps' notifications** (Settings › Notifications): Accessibility, in
  **System Settings › Privacy & Security › Accessibility**. macOS forgets it
  after every LiteNotch update; **Reset and ask again** restores it.
- **Raising a session's terminal tab**: the first click on a session asks
  whether LiteNotch may control Terminal or iTerm2. Without it, the terminal
  app still comes forward.
- **Calendar**: macOS asks when you turn it on. If you said no, choose **Full
  Access** under **Privacy & Security › Calendars**. LiteNotch writes to a
  calendar only when you add, edit or delete an event in its Calendar tab.
- **Keep awake with the lid closed**: your administrator password, once each
  time LiteNotch starts. It turns itself off after 12 hours and when
  LiteNotch quits.

Everything stays on your Mac. Clipboard history is kept in memory unless you
turn on **Keep after restart**. **Settings › Privacy** shows how often each
feature was used (counts only, never what you copy, play or type); nothing is
sent anywhere.

The one exception is the update check: **Check for updates**, or **Check
automatically** (off until you turn it on), asks `api.github.com` for the
newest release. It sends no version or identifier, and never downloads or
installs anything.

## Installing without Homebrew's checks

The app isn't notarized yet, so the Homebrew cask removes macOS's "downloaded
from the internet" flag after installing (recent Homebrew warns that this
`postflight` step is deprecated; it still works). To check the download
yourself, compare `shasum -a 256` of the zip with the `.sha256` file on the
release page, or build from source. `brew uninstall --cask --zap litenotch`
also deletes settings and history.
