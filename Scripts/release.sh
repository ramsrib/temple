#!/usr/bin/env bash
#
# release.sh — build, sign, (optionally) notarize, package, and publish a
# Temple release to GitHub.
#
#   VERSION=v0.1.0 ./Scripts/release.sh
#
# Steps:
#   1. Clean release build of Temple.app (Scripts/build-app.sh — Developer ID
#      signing preferred; ghostty resources bundled).
#   2. Notarize + staple when a notarytool keychain profile is available
#      (store one once with:
#        xcrun notarytool store-credentials temple-notary \
#          --apple-id <id> --team-id <team> --password <app-specific-pw>
#      and pass NOTARY_PROFILE=temple-notary). Skipped otherwise — the zip
#      still works, but downloaders must right-click → Open the first time.
#   3. Package: Temple-<version>.zip (ditto) + Temple-<version>.dmg (hdiutil).
#   4. Tag <version> (if missing) and create the GitHub release with both
#      artifacts via `gh release create`.
#
# Env knobs: VERSION (required, e.g. v0.1.0) · NOTARY_PROFILE · DRAFT=1
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:?set VERSION, e.g. VERSION=v0.1.0}"
APP="$ROOT/dist/Temple.app"
OUT="$ROOT/dist"
ARCH="$(uname -m)"   # arm64 — explicit in artifact names
ZIP="$OUT/Temple-$VERSION-$ARCH.zip"
DMG="$OUT/Temple-$VERSION-$ARCH.dmg"

command -v gh >/dev/null || { echo "error: gh CLI required" >&2; exit 1; }

# 1. build ---------------------------------------------------------------
echo "==> building Temple.app ($VERSION)"
MARKETING_VERSION="${VERSION#v}" ./Scripts/build-app.sh

# 2. notarize (optional) --------------------------------------------------
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> notarizing (profile: $NOTARY_PROFILE)"
  ditto -c -k --keepParent "$APP" "$OUT/notarize-upload.zip"
  xcrun notarytool submit "$OUT/notarize-upload.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$OUT/notarize-upload.zip"
else
  echo "==> NOTARY_PROFILE not set — skipping notarization"
  echo "    (downloaders must right-click → Open on first launch)"
fi

# 3. package ---------------------------------------------------------------
echo "==> packaging"
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

if command -v create-dmg >/dev/null 2>&1; then
  # Polished drag-to-install layout: background arrow, positioned icons.
  create-dmg \
    --volname "Temple" \
    --background "$ROOT/assets/dmg/background.png" \
    --window-size 660 420 \
    --icon-size 110 \
    --icon "Temple.app" 180 190 \
    --app-drop-link 480 190 \
    --hide-extension "Temple.app" \
    "$DMG" "$APP" >/dev/null
else
  echo "    (create-dmg not installed — plain dmg; brew install create-dmg for the styled one)"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Temple" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
fi

echo "    $(du -h "$ZIP" | cut -f1)  $ZIP"
echo "    $(du -h "$DMG" | cut -f1)  $DMG"

# 4. tag + release -----------------------------------------------------------
if ! git rev-parse "$VERSION" >/dev/null 2>&1; then
  echo "==> tagging $VERSION"
  git tag -a "$VERSION" -m "Temple $VERSION"
  git push origin "$VERSION"
fi

echo "==> creating GitHub release $VERSION"
GH_ARGS=(release create "$VERSION" "$ZIP" "$DMG"
  --title "Temple $VERSION"
  --generate-notes)
[[ -n "${DRAFT:-}" ]] && GH_ARGS+=(--draft)
gh "${GH_ARGS[@]}"

echo "✓ released $VERSION"
