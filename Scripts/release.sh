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
#   2. Notarize + staple when credentials are available (an App Store Connect
#      key in .env, or a notarytool keychain profile). Skipped otherwise — the
#      zip still works, but downloaders must right-click → Open the first time.
#   3. Package: Temple-<version>.zip (ditto) + Temple-<version>.dmg (hdiutil).
#   4. Tag <version> (if missing) and create the GitHub release with both
#      artifacts via `gh release create`.
#
# Env knobs: VERSION (required, e.g. v0.1.0) · DRAFT=1 · notarization creds
# from .env (NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER, or NOTARY_PROFILE)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Local credentials (gitignored; see .env.example) — notarization is on by
# default because of them.
if [[ -f "$ROOT/.env" ]]; then
  set -a; source "$ROOT/.env"; set +a
fi

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
# notarytool only accepts .zip/.dmg/.pkg uploads; stapler only writes tickets to
# the .app/.dmg itself — so submit and staple are deliberately separate.
#
# Auth: the App Store Connect key directly when .env provides one, else a
# notarytool keychain profile. Key-first because the keychain profile needs a
# GUI login session to read back — store-credentials happily reports success in
# a headless shell (CI, an agent, ssh) and then the item is nowhere to be found.
NOTARY_KEY_PATH="${NOTARY_KEY_PATH/#\~/$HOME}"
if [[ -f "${NOTARY_KEY_PATH:-}" && -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER:-}" ]]; then
  NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  NOTARY_HOW="App Store Connect key $NOTARY_KEY_ID"
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  NOTARY_HOW="keychain profile $NOTARY_PROFILE"
fi

submit_for_notarization() {
  xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait \
    || { echo "error: notarization of $1 was not accepted" >&2; exit 1; }
}

if [[ -n "${NOTARY_HOW:-}" ]]; then
  echo "==> notarizing the app ($NOTARY_HOW)"
  ditto -c -k --keepParent "$APP" "$OUT/notarize-upload.zip"
  submit_for_notarization "$OUT/notarize-upload.zip"
  rm -f "$OUT/notarize-upload.zip"
  xcrun stapler staple "$APP"                      # ticket goes on the .app
  spctl --assess -vv "$APP" 2>&1 | sed 's/^/      /'
else
  echo "==> no notarization credentials (.env) — skipping notarization"
  echo "    (downloaders must approve the app in System Settings → Privacy & Security)"
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

if [[ -n "${NOTARY_HOW:-}" ]]; then
  echo "==> notarizing the dmg"
  submit_for_notarization "$DMG"
  xcrun stapler staple "$DMG"                      # ticket goes on the .dmg
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
