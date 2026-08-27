#!/bin/sh
# Assemble build/Knips.app around an already-built build/knips.
#
# The bundle exists to make the menu-bar app launchable and Dock-less:
# LSUIElement keeps it out of the Dock, and CFBundleIdentifier gives it a
# stable identity — including for TCC, whose grants key on the signing
# step's identifier-anchored designated requirement (see the codesign
# comment at the bottom and docs/deployment.md).
#
# NSMicrophoneUsageDescription and NSCameraUsageDescription are the keys
# TCC reads from this plist: a bundled process asking for the microphone
# without its key is killed rather than prompted, and the camera key is
# what lets macOS prompt for Knips by name when the camera window is
# switched on. Measured on device (docs/spikes/0001): a bundle-less
# binary without the camera key is NOT killed — it is silently refused,
# which is worse to debug. The plain CLI binary has no Info.plist, so it
# inherits the grants of whichever app is responsible for it (the
# terminal). Screen Recording needs no usage key.
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

ICON_SOURCE=$ROOT/assets/knips-icon-1024.png

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
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSCameraUsageDescription</key>
  <string>Knips shows your camera in a floating window so it can be part of your recording.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Knips records the microphone when you choose to include it in a recording.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"

# The app icon: generated from the one committed 1024px source at build
# time (sips + iconutil are stock macOS), so the repo carries a single
# PNG rather than ten derived sizes.
# In a subshell with || so a cosmetic failure cannot abort the script
# under set -e before the SIGNING below - an unsigned bundle silently
# loses its camera permission prompts, which is a far worse failure
# than a generic icon.
if [ -f "$ICON_SOURCE" ]; then
  ICONTMP=$(mktemp -d)
  (
    set -e
    RESOURCES=$CONTENTS/Resources
    ICONSET=$ICONTMP/AppIcon.iconset
    mkdir -p "$RESOURCES" "$ICONSET"
    for SIZE in 16 32 128 256 512; do
      sips -z "$SIZE" "$SIZE" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${SIZE}x${SIZE}.png" > /dev/null
      DOUBLE=$((SIZE * 2))
      sips -z "$DOUBLE" "$DOUBLE" "$ICON_SOURCE" \
        --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" > /dev/null
    done
    iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
  ) || echo "make-app.sh: icon generation failed, continuing unsigned-icon" >&2
  rm -rf "$ICONTMP"
fi

# Ad-hoc sign the finished bundle. An UNSIGNED bundle gets a limbo TCC
# identity: requestAccessForMediaType for the camera is silently dropped
# — no prompt, no error, status stays NotDetermined (measured on device;
# Screen Recording, oddly, still prompts).
#
# The explicit identifier-only DESIGNATED REQUIREMENT is what makes TCC
# grants survive rebuilds: without it an ad-hoc signature's requirement
# is `cdhash H"…"` — the fingerprint of that exact binary — so every
# rebuild orphaned the user's Screen Recording and Camera grants and
# re-prompted (measured on device, painfully). Anchored to the bundle
# identifier instead, the requirement is identical build after build.
# The trade: any ad-hoc binary claiming this identifier inherits the
# grant — fine on a development machine, and a real Developer ID
# signature replaces this wholesale for distribution.
codesign --force -s - \
  --identifier "$BUNDLE_IDENTIFIER" \
  --requirements "=designated => identifier \"$BUNDLE_IDENTIFIER\"" \
  "$APP"

echo "$APP"
