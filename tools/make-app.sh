#!/bin/sh
# Assemble build/Knips.app around an already-built build/knips.
#
# The bundle exists to make the menu-bar app launchable and Dock-less:
# LSUIElement keeps it out of the Dock, and CFBundleIdentifier gives it a
# stable identity for anything that keys off one. It does NOT decide the
# Screen Recording grant — TCC keys that on the code signature of the
# process that actually asks, which here is Contents/MacOS/knips-bin, not
# the bundle. See docs/deployment.md.
#
# CFBundleExecutable is the binary itself, NOT a launcher script: a
# script that execs the binary breaks the LaunchServices handshake
# AppKit needs before the menu bar will adopt a status item (seen on
# device — height-0, invisible item). The binary detects a bundle launch
# from its own path and runs app mode with no arguments; from a shell it
# keeps the full CLI.
#
# Usage: tools/make-app.sh [path-to-knips-binary]
# Run `lwpt build` (or `lwpt build --mode release`) first.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BINARY=${1:-$ROOT/build/knips}
APP=$ROOT/build/Knips.app
CONTENTS=$APP/Contents
MACOS=$CONTENTS/MacOS

BUNDLE_IDENTIFIER=org.knips.app
BUNDLE_NAME=Knips
RECORDER=knips-bin

if [ ! -x "$BINARY" ]; then
  echo "make-app.sh: no built binary at $BINARY (run: lwpt build)" >&2
  exit 1
fi

VERSION=$(sed -n "s/^ *KnipsVersion = '\\(.*\\)';.*/\\1/p" \
  "$ROOT/source/Knips.Options.pas" | head -n 1)
[ -n "$VERSION" ] || VERSION=0.0.0

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BINARY" "$MACOS/$RECORDER"
chmod +x "$MACOS/$RECORDER"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$RECORDER</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_IDENTIFIER</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$BUNDLE_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "$APP"
