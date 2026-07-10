#!/usr/bin/env bash
#
# build-app.sh — build the signed Temple.app from a clean checkout (PLAN U6).
#
#   1. generate the app icon if missing              (Scripts/make-icon.sh)
#   2. regenerate Temple.xcodeproj from project.yml   (xcodegen)
#   3. xcodebuild -scheme Temple -configuration Release build
#   4. copy the built Temple.app into dist/ and report its path
#
# Idempotent and runnable from a fresh clone. Signing defaults to the local
# "Apple Development" identity (project.yml); override for ad-hoc signing:
#
#   CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="" ./Scripts/build-app.sh
#
# Env knobs:
#   CONFIGURATION       Release (default) | Debug
#   CODE_SIGN_IDENTITY  overrides project.yml's "Apple Development"
#   DEVELOPMENT_TEAM    overrides project.yml's team
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
SCHEME="Temple"
DERIVED="$ROOT/.build/xcode-derived"
DIST="$ROOT/dist"

# 1. icon --------------------------------------------------------------------
if [[ ! -f "$ROOT/App/AppIcon.icns" ]]; then
  echo "==> app icon missing; generating"
  "$ROOT/Scripts/make-icon.sh"
fi

# 2. project -----------------------------------------------------------------
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi
echo "==> xcodegen generate"
xcodegen generate --spec "$ROOT/project.yml"

# 3. resolve signing ---------------------------------------------------------
# Manual signing needs an exact cert. Prefer a local "Apple Development" identity
# (matched by its SHA-1 hash — the string "Apple Development" makes xcodebuild
# look up a nonexistent "Mac Development" cert). Fall back to ad-hoc ("-"), which
# builds and launches locally but fails Gatekeeper assessment.
if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
  DEV_LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development' | head -1 || true)"
  if [[ -n "$DEV_LINE" ]]; then
    CODE_SIGN_IDENTITY="$(echo "$DEV_LINE" | awk '{print $2}')"
    echo "==> signing with Apple Development identity ($CODE_SIGN_IDENTITY)"
  else
    CODE_SIGN_IDENTITY="-"
    echo "==> no Apple Development identity found; signing ad-hoc (-)"
  fi
fi

# 4. build -------------------------------------------------------------------
echo "==> xcodebuild ($CONFIGURATION)"
XCB_ARGS=(
  -project "$ROOT/Temple.xcodeproj"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -derivedDataPath "$DERIVED"
  build
  "CODE_SIGN_STYLE=Manual"
  "CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY"
  "CODE_SIGNING_REQUIRED=YES"
  "CODE_SIGNING_ALLOWED=YES"
  "PROVISIONING_PROFILE_SPECIFIER="
)
if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  # ad-hoc: no team, and hardened runtime can't apply without a real identity
  XCB_ARGS+=("DEVELOPMENT_TEAM=" "ENABLE_HARDENED_RUNTIME=NO")
else
  [[ -n "${DEVELOPMENT_TEAM+x}" ]] && XCB_ARGS+=("DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}")
fi

set -o pipefail
if command -v xcbeautify >/dev/null 2>&1; then
  xcodebuild "${XCB_ARGS[@]}" | xcbeautify
else
  xcodebuild "${XCB_ARGS[@]}"
fi

# 5. collect -----------------------------------------------------------------
APP_SRC="$DERIVED/Build/Products/$CONFIGURATION/$SCHEME.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "error: build succeeded but $APP_SRC not found" >&2
  exit 1
fi
mkdir -p "$DIST"
rm -rf "$DIST/$SCHEME.app"
cp -R "$APP_SRC" "$DIST/$SCHEME.app"

echo ""
echo "==> built: $DIST/$SCHEME.app"
echo "==> signature:"
codesign -dv "$DIST/$SCHEME.app" 2>&1 | sed 's/^/      /' || true
echo ""
echo "Launch with:  open \"$DIST/$SCHEME.app\""
