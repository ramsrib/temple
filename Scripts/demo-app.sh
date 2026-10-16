#!/usr/bin/env bash
# Makes the bundled demo app: a copy of dist/Temple.app that macOS treats as a
# different app, so a demo run never writes the owner's preferences.
#
# Temple's own settings follow TEMPLE_DEFAULTS_SUITE, but AppKit's autosaves
# (the window frame, the split view's widths, the open panel's last folder)
# and the saved window state can only use the app's own defaults domain and
# bundle id. Launched from dist/Temple.app with the demo's variables, those
# still land in com.sriramb.temple. This copy is com.sriramb.temple.demo,
# named "Temple Demo", with the executable TempleDemo (so `ps` and System
# Events tell it from the owner's Temple), signed ad hoc.
#
# Usage: Scripts/demo-app.sh [source.app] [dest.app]
#   defaults: dist/Temple.app → /private/tmp/temple-demo/Temple Demo.app
# Prints the executable to launch. Builds nothing and launches nothing.
#
# The copy is a separate app to TCC: a grant given to Temple (Screen
# Recording, Automation) does not carry over. The snapshot hook
# (TEMPLE_SNAPSHOT_DIR, WindowSnapshot.swift) needs none.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/dist/Temple.app}"
DEST="${2:-/private/tmp/temple-demo/Temple Demo.app}"
DEMO_ID=com.sriramb.temple.demo

case "$DEST" in
  *.app) ;;
  *) echo "error: destination must be a .app path: $DEST" >&2; exit 1 ;;
esac
[ -x "$SRC/Contents/MacOS/Temple" ] || { echo "error: no Temple executable in $SRC" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
ditto "$SRC" "$DEST"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier $DEMO_ID" \
  -c "Set :CFBundleName Temple Demo" \
  -c "Set :CFBundleDisplayName Temple Demo" \
  -c "Set :CFBundleExecutable TempleDemo" \
  "$DEST/Contents/Info.plist"
mv "$DEST/Contents/MacOS/Temple" "$DEST/Contents/MacOS/TempleDemo"
codesign --force --sign - --entitlements "$ROOT/App/Temple.entitlements" "$DEST" 2>/dev/null
codesign --verify --strict "$DEST"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")" = "$DEMO_ID" ]
echo "$DEST/Contents/MacOS/TempleDemo"
