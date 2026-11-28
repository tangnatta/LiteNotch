#!/bin/sh
# Rebuilds the README's previews (docs/preview/*.gif).
# The frames are drawn by the app's own views from macos/Fixtures, one per
# second of the clock; ffmpeg (brew install ffmpeg) joins them with a short
# cross-fade. Nothing is recorded from the screen.
set -eu
cd "$(dirname "$0")/.."
OUT=docs/preview
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# One locale for everyone (dates, the calendar system), not this Mac's.
swift run --package-path macos LiteNotchSnapshot --previews macos/Fixtures "$TMP" \
    -AppleLocale en_GB -AppleLanguages '(en-GB)' >/dev/null
mkdir -p "$OUT"
for dir in "$TMP"/*/; do
    name=$(basename "$dir")
    ffmpeg -loglevel error -y -framerate 1 -i "$dir/f-%04d.png" -filter_complex \
        "fps=4,framerate=fps=12,scale=680:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
        "$OUT/$name.gif"
    echo "$OUT/$name.gif"
done
