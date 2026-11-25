# Changelog

What changed in each release. The release workflow copies the section whose
heading is the version (`## 0.2.4-beta`) into the GitHub release notes, so add
the section in the pull request that bumps the version in `Cargo.toml`.

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
