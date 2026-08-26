#!/bin/sh
# Assemble build/Opname.app around an already-built build/opname.
#
# The bundle exists to make the menu-bar app launchable and Dock-less:
# LSUIElement keeps it out of the Dock, and CFBundleIdentifier gives it a
# stable identity for anything that keys off one. It does NOT decide the
# Screen Recording grant — TCC keys that on the code signature of the
# process that actually asks, which here is Contents/MacOS/opname-bin, not
# the bundle. See docs/deployment.md. The binary keeps its CLI:
# CFBundleExecutable points at a two-line launcher
# that execs the real binary with the `app` subcommand, so `opname` with no
# arguments still prints help. The two live side by side under
# Contents/MacOS and must not differ only in case — the default macOS
# volume is case-insensitive, and `Opname` would overwrite `opname`.
#
# Usage: tools/make-app.sh [path-to-opname-binary]
# Run `lwpt build` (or `lwpt build --mode release`) first.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BINARY=${1:-$ROOT/build/opname}
APP=$ROOT/build/Opname.app
CONTENTS=$APP/Contents
MACOS=$CONTENTS/MacOS

BUNDLE_IDENTIFIER=org.opname.app
BUNDLE_NAME=Opname
LAUNCHER=Opname
RECORDER=opname-bin

if [ ! -x "$BINARY" ]; then
  echo "make-app.sh: no built binary at $BINARY (run: lwpt build)" >&2
  exit 1
fi

VERSION=$(sed -n "s/^ *OpnameVersion = '\\(.*\\)';.*/\\1/p" \
  "$ROOT/source/Opname.Options.pas" | head -n 1)
[ -n "$VERSION" ] || VERSION=0.0.0

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BINARY" "$MACOS/$RECORDER"
chmod +x "$MACOS/$RECORDER"

cat > "$MACOS/$LAUNCHER" <<LAUNCH
#!/bin/sh
exec "\$(dirname "\$0")/$RECORDER" app
LAUNCH
chmod +x "$MACOS/$LAUNCHER"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$LAUNCHER</string>
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
