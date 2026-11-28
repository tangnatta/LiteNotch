# Changelog

What changed in each release. The release workflow copies the section whose
heading is the version (`## 0.2.4`) into the GitHub release notes, so add
the section in the pull request that bumps the version in `Cargo.toml`.

## 0.2.7-beta

### New
- **A Calendar tab.** With Settings › Calendar on, a calendar icon sits
  beside the inbox. It lists the next two days by day; click an event to see
  everything in it: when and how long, the calendar, the place, its link,
  the organizer, who is coming and who has not answered, and the notes.
  - **New event, Edit and Delete** change your calendar from the notch:
    title, start, end, calendar and place. Moving the start keeps the length.
    For a repeating event, a change or delete applies to that one occurrence.
    Delete asks once more before it acts.
  - An event with guests (yours or someone else's invitation), or one in a
    calendar that cannot be changed, shows **Open Calendar** instead: changing
    a meeting sends every guest an update, which Calendar asks you about.
  - Clicking a calendar reminder, or the event on Home, opens that event.
  - A link in an invitation is shown with a **Copy** button; LiteNotch never
    opens it.
- **Water and stretch gauges** (Settings › Day, each off by default). They
  run down while you are at the Mac and stand still while it is locked,
  asleep or shut. Click the tank (or **Drank** / **Stretch**) to fill it: a
  cup adds 200 ml to a 400 ml tank, or as little as 50 ml right after the
  last one, so spaced-out cups count more. The notch says so once below
  20 % and once when empty. Home's big card can show them (**Body**: water
  alone, or water and stretch), and the closed notch can show the one that
  empties first (Settings › Notch). No daily total, no warning colours.
  They replace the **Move** reminder; its setting carries over.
- **Two-finger swipe** in the open panel: left or right moves one tab (round
  from Settings back to Home); up or down over Home's big card moves between
  the day, the gauges and now playing, with page dots on the card. A page you
  picked, or a tap on Drank, Stretch or a music button, keeps that card until
  the panel closes.
- **Day progress**: the day now turns over at 03:00, so a late night still
  counts as the day it started. With the sun icon, Home's day card is a sky
  for the time of day. **Animate** (Settings › Day) lets the sun turn and the
  tree sway, and the icon choice shows its icons.
- **Codex's usage limits** in Agents › Usage, read from Codex's own session
  logs (no request leaves your Mac).
- **A welcome on first launch**: the panel opens once and says how to open,
  close and quit LiteNotch.

### Improved
- Settings lists its sections most-used first, and General folds the choices
  that need explaining under **More options**. **Settings › Day** holds day
  progress, the eye break, water, stretch and Home's big card; the separate
  Home section is gone.
- The eye break's face is `O-O`, blinking to `>-<`.
- The colour eyedropper moved to the Clipboard tab, where picked colours land.
- The README is shorter, with the details in a separate guide.

### Fixed and under the hood
- **Day progress cost about 3 % CPU every evening.** Once the work day had
  ended, the closed notch's sun, moon or tree kept redrawing until the next
  day started. It now redraws only when the icon changes. A new benchmark
  scenario measures a day that is already over.
- **A question with a paragraph of context showed as raw text** in the notch
  instead of the question form: questions over 300 characters were refused.
  Now any up to 2000 characters is a question; a long one shows its start with
  an inline **More / Less**, so the choices stay in sight.
- Calendar text from invitations (notes, links, names) is cleaned of
  invisible and direction-changing characters and capped before it is shown,
  like event titles already were.
- The macOS permission prompt for calendars now says LiteNotch can change
  events, and when.
- `litenotch status` no longer includes the text the closed notch shows
  (a notification's or an event's title), only what kind of thing it is:
  any program of yours could ask it, including ones without the calendar or
  Accessibility permission.
- Reading Codex's logs skips anything that is not a plain file, and a log
  dated in the future no longer holds back the real limits.
- The README's previews show the Calendar tab and the gauges, in one locale
  whatever the Mac's (a Thai Mac drew Buddhist-era years in the edit form),
  and a long Settings page in a preview no longer squeezes its rows together.
- Hover tests wait for the panel instead of a fixed time; one failed on a busy
  CI runner.

## 0.2.6-beta

### New
- **Codex, Gemini CLI and Antigravity in the notch.** Each shows its sessions
  like Claude Code does: working, waiting for you, finished, with a click to
  bring the terminal forward. Connect them in Settings › Agents (a row each,
  with Connect / Disconnect), or from the terminal with
  `litenotch hooks install --agent codex|gemini|antigravity` (or `--agent all`
  for every one that is installed); `uninstall` and `status` take the same
  option. Plain `litenotch hooks install` is still Claude Code.
  - **Codex** also gets Allow / Deny in the notch: it answers a permission
    request the way Claude Code does.
  - **Gemini CLI and Antigravity** have no hook that can answer an approval
    from outside, so the notch shows activity and "needs input" only; their
    own prompts stay in charge. Installing says so.
  - Your own hooks in those files are kept, and the first backup of each file
    is left beside it. Settings › Agents says which agents have no approval
    hook, so nobody looks for buttons that are not there.

### Improved
- **Updates know about both Homebrew channels.** Settings › General › Check
  for updates now follows your own channel: a beta build looks for the newest
  beta and copies `brew upgrade --cask litenotch@beta`; a stable build looks
  for the newest stable release and copies `brew upgrade --cask litenotch`.
  Before, a stable build would have been offered a beta it could not install,
  and a beta build a command for the wrong cask.
- **Long answer notes in questions are kept.** A choice's note over the old
  limit is no longer dropped: the notch shows the first 200 characters with an
  inline More / Less.

### Fixed and under the hood
- Tests check every connector against the payloads and config layouts in each
  agent's documentation.

## 0.2.5

### New
- **Launch at login.** Settings › General › Launch at login starts LiteNotch
  when you log in (off by default). macOS's own Login Items list stays in
  charge: a change made there shows up here too, and if macOS wants your
  approval the row offers a button to open Login Items.
- **Glass for the closed notch on a display without a notch.** With Panel:
  Glass and Closed notch: Match theme, the closed notch and the toast are
  Liquid Glass too, and the glass stays through opening and closing instead
  of fading out and back. With a hardware notch, Always dark or the default
  settings nothing changes; an approval is still drawn on the solid colour,
  and the Shrink strip stays solid.

### Fixed and under the hood
- The footprint benchmark covers two more cases (the closed notch in glass,
  and the panel open in the Island style with glass) and runs its scenarios
  side by side, so a full run takes about 35 s instead of about 5 minutes.
- README: new previews for 0.2.4-beta, a Day progress section and a
  Contributors section.

## 0.2.4-beta

### New
- **Progress ring around the music artwork.** While a song plays, the closed
  notch's artwork sits inside a ring that fills as the song goes: a rounded
  square in Attached, a circle in Island. It takes its space from the artwork,
  so nothing around it moves. Settings › Music › Progress ring turns it off
  (on by default).
- **Day progress has its own Settings section**, with an Icon choice: the sun
  and moon by the time of day, or a tree that grows through the day (seed,
  leaves, sapling, young tree, full tree; it never withers).

### Improved
- **Clipboard rows say they can be copied.** Under the pointer a row shows a
  pointing hand and "Copy" in place of its age.
- **Clear history also clears the colours you picked** from the screen. The
  button stays available when only colours are left.

### Fixed and under the hood
- Building the app uses Xcode's Swift when the selected tools are too old for
  Liquid Glass, and records the real SDK version.
- A socket server test no longer fails on a slow CI runner.
