# Changelog

What changed in each release. The release workflow copies the section whose
heading is the version (`## 0.2.4-beta`) into the GitHub release notes, so add
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
- **Settings › Agents connects Codex, Gemini CLI and Antigravity** with a
  button each, next to Claude Code, and says which are installed on this Mac.
- **Codex's usage limits** in Agents › Usage, read from Codex's own session
  logs (no request leaves your Mac).
- **A welcome on first launch**: the panel opens once and says how to open,
  close and quit LiteNotch.

### Improved
- Settings lists its sections most-used first, and General folds the choices
  that need explaining under **More options**.
- The colour eyedropper moved to the Clipboard tab, where picked colours land.
- The README is shorter, with the details in a separate guide.

### Fixed and under the hood
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
- Connecting an agent that is not installed no longer creates its folder.

## 0.2.6-beta

### New
- **Codex, Gemini CLI and Antigravity in the notch.** Each shows its sessions
  like Claude Code does: working, waiting for you, finished, with a click to
  bring the terminal forward. Register one from the terminal with
  `litenotch hooks install --agent codex|gemini|antigravity` (or `--agent all`
  for every one that is installed); `uninstall` and `status` take the same
  option. Plain `litenotch hooks install` is still Claude Code.
  - **Codex** also gets Allow / Deny in the notch: it answers a permission
    request the way Claude Code does.
  - **Gemini CLI and Antigravity** have no hook that can answer an approval
    from outside, so the notch shows activity and "needs input" only; their
    own prompts stay in charge. Installing says so.
  - Your own hooks in those files are kept, and the first backup of each file
    is left beside it. Settings has no switch for these yet.

### Improved
- **Long answer notes in questions are kept.** A choice's note over the old
  limit is no longer dropped: the notch shows the first 200 characters with an
  inline More / Less.

### Fixed and under the hood
- Tests check every connector against the payloads and config layouts in each
  agent's documentation.

## 0.2.5-beta

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
