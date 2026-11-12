#!/bin/sh
# Builds dist/LiteNotch.app: Rust core (static library) + CLI + SwiftUI shell
# + the now-playing helper library.
# Usage: scripts/build-app.sh [--debug]
set -eu
cd "$(dirname "$0")/.."
ROOT=$(pwd)
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"

PROFILE=release
CARGO_FLAGS=--release
SWIFT_CONFIG=release
if [ "${1:-}" = "--debug" ]; then
    PROFILE=debug
    CARGO_FLAGS=
    SWIFT_CONFIG=debug
fi

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
APP=dist/LiteNotch.app

echo "==> Rust core and CLI ($PROFILE)"
# The CLI is built on its own so it does not pick up the app's frameworks.
cargo build $CARGO_FLAGS -p litenotch-app
cargo build $CARGO_FLAGS -p litenotch

echo "==> Shell ($SWIFT_CONFIG)"
LITENOTCH_RUST_LIB="$ROOT/target/$PROFILE" \
    swift build --package-path macos -c "$SWIFT_CONFIG" --product LiteNotch
BIN_DIR=$(LITENOTCH_RUST_LIB="$ROOT/target/$PROFILE" \
    swift build --package-path macos -c "$SWIFT_CONFIG" --show-bin-path)

echo "==> Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/LiteNotch" "$APP/Contents/MacOS/LiteNotch"
# Not in MacOS/: the default filesystem is case-insensitive, so `litenotch`
# and `LiteNotch` cannot share a directory.
cp "target/$PROFILE/litenotch" "$APP/Contents/Helpers/litenotch"
# The now-playing helper is loaded into /usr/bin/perl at run time (see the
# comment at the top of the source file).
clang -dynamiclib -fobjc-arc -Os -fvisibility=hidden -framework Foundation \
    -o "$APP/Contents/Helpers/libnowplaying.dylib" macos/NowPlayingHelper/nowplaying.m
sed "s/@VERSION@/$VERSION/g" macos/Info.plist > "$APP/Contents/Info.plist"
if [ "$PROFILE" = release ]; then
    strip -x "$APP/Contents/MacOS/LiteNotch"
fi
# Ad-hoc signature: enough to run locally. Distribution needs a Developer ID
# identity and notarization.
codesign --force --sign - "$APP/Contents/Helpers/litenotch"
codesign --force --sign - "$APP/Contents/Helpers/libnowplaying.dylib"
codesign --force --sign - "$APP"

du -sh "$APP" | awk '{print "==> " $2 " (" $1 ")"}'
