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

# Liquid Glass is compiled in only with Swift 6.2+ (the macOS 26 SDK; see
# Glass.swift). `xcode-select` often still points at old Command Line Tools
# while a newer Xcode is installed, which silently builds an app without
# Glass. Use that Xcode then, unless DEVELOPER_DIR was set on purpose.
swift_version() {
    swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -1
}
swift_has_glass() {
    V=$(swift_version)
    [ -n "$V" ] || return 1
    [ "${V%%.*}" -gt 6 ] || { [ "${V%%.*}" -eq 6 ] && [ "${V#*.}" -ge 2 ]; }
}
if [ -z "${DEVELOPER_DIR:-}" ] && ! swift_has_glass &&
    [ -d /Applications/Xcode.app/Contents/Developer ]; then
    OLD=$(swift_version)
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    echo "==> Using Xcode's Swift $(swift_version); the selected tools have Swift ${OLD:-unknown}"
fi
if ! swift_has_glass; then
    echo "warning: Swift $(swift_version) is older than 6.2; this build will have no Liquid Glass." >&2
    echo "         Install Xcode 26 or later, or run: sudo xcode-select -s /path/to/Xcode.app" >&2
fi

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
APP=dist/LiteNotch.app

echo "==> Rust core and CLI ($PROFILE)"
# The CLI is built on its own so it does not pick up the app's frameworks.
cargo build --locked $CARGO_FLAGS -p litenotch-app
cargo build --locked $CARGO_FLAGS -p litenotch

echo "==> Shell ($SWIFT_CONFIG)"
# macOS gives an app the look and behaviour of the SDK recorded in its
# binary (LC_BUILD_VERSION). SwiftPM's newer build system (default from
# Swift 6.4) records the deployment target there instead of the SDK, so
# macOS 26+ treated the app as one built for macOS 14. State both.
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' macos/Info.plist)
SDK_VERSION=$(xcrun --show-sdk-version)
SDK_FLAGS="-Xlinker -platform_version -Xlinker macos -Xlinker $MIN_OS -Xlinker $SDK_VERSION"
# shellcheck disable=SC2086
LITENOTCH_RUST_LIB="$ROOT/target/$PROFILE" \
    swift build --package-path macos -c "$SWIFT_CONFIG" --product LiteNotch $SDK_FLAGS
# shellcheck disable=SC2086
BIN_DIR=$(LITENOTCH_RUST_LIB="$ROOT/target/$PROFILE" \
    swift build --package-path macos -c "$SWIFT_CONFIG" --show-bin-path $SDK_FLAGS)
BUILT_SDK=$(vtool -show-build "$BIN_DIR/LiteNotch" | awk '$1 == "sdk" { print $2; exit }')
if [ "$BUILT_SDK" != "$SDK_VERSION" ]; then
    echo "error: the app records SDK ${BUILT_SDK:-none}, expected $SDK_VERSION" >&2
    exit 1
fi

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
# The app icon: every size macOS asks for, from one 1024 px master.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE macos/Icon/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z $((SIZE * 2)) $((SIZE * 2)) macos/Icon/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
# macOS wants plain numbers in the bundle version; a pre-release suffix such
# as -beta.1 stays in the release name and the Homebrew cask.
BUNDLE_VERSION=${VERSION%%-*}
sed "s/@VERSION@/$BUNDLE_VERSION/g" macos/Info.plist > "$APP/Contents/Info.plist"
if [ "$PROFILE" = release ]; then
    strip -x "$APP/Contents/MacOS/LiteNotch"
fi
# Ad-hoc signature: enough to run locally. Distribution needs a Developer ID
# identity and notarization.
# The hardened runtime makes macOS refuse DYLD_* injection, so code that
# launches LiteNotch cannot borrow its Accessibility permission. The
# now-playing library is loaded by /usr/bin/perl, not by the app, so it is
# signed without it.
codesign --force --options runtime --sign - "$APP/Contents/Helpers/litenotch"
codesign --force --sign - "$APP/Contents/Helpers/libnowplaying.dylib"
# The two entitlements let macOS ask whether LiteNotch may control the
# terminal (to raise a session's window) and read the calendars; see
# macos/LiteNotch.entitlements.
codesign --force --options runtime --entitlements macos/LiteNotch.entitlements --sign - "$APP"

du -sh "$APP" | awk '{print "==> " $2 " (" $1 ")"}'
