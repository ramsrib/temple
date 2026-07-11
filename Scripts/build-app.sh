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

# 0. version -----------------------------------------------------------------
# Info.plist takes these from the build settings ($(MARKETING_VERSION) /
# $(CURRENT_PROJECT_VERSION)), so they are the single source of the version the
# About box shows. release.sh passes MARKETING_VERSION; a local build derives it
# from the last tag, so `make install` never claims to be some other release.
MARKETING_VERSION="${MARKETING_VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
MARKETING_VERSION="${MARKETING_VERSION:-0.0.0}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

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
# Manual signing needs an exact cert (matched by SHA-1 hash — name strings make
# xcodebuild resolve unpredictably). Preference order:
#   1. "Developer ID Application" — the real distribution identity
#   2. "Apple Development"        — local dev signing
#   3. ad-hoc ("-")               — builds and launches locally only
if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
  for KIND in "Developer ID Application" "Apple Development"; do
    LINE="$(security find-identity -v -p codesigning 2>/dev/null | grep "\"$KIND" | head -1 || true)"
    if [[ -n "$LINE" ]]; then
      CODE_SIGN_IDENTITY="$(echo "$LINE" | awk '{print $2}')"
      # Team id is the parenthesized suffix of the identity name.
      DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(echo "$LINE" | sed -n 's/.*(\([A-Z0-9]*\))".*/\1/p')}"
      echo "==> signing with $KIND identity ($CODE_SIGN_IDENTITY, team ${DEVELOPMENT_TEAM:-n/a})"
      break
    fi
  done
  if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
    CODE_SIGN_IDENTITY="-"
    echo "==> no signing identity found; signing ad-hoc (-)"
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
XCB_ARGS+=("MARKETING_VERSION=${MARKETING_VERSION}"
           "CURRENT_PROJECT_VERSION=${CURRENT_PROJECT_VERSION}")
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

# 6. bundle ghostty runtime resources (T7) ------------------------------------
# terminfo, shell integration, themes — GhosttyResources.configure() looks for
# Contents/Resources/ghostty inside the bundle. Produced by build-ghostty.sh.
GHOSTTY_SHARE="$ROOT/Vendor/ghostty/zig-out/share/ghostty"
if [[ -d "$GHOSTTY_SHARE" ]]; then
  echo "==> bundling ghostty resources"
  cp -R "$GHOSTTY_SHARE" "$DIST/$SCHEME.app/Contents/Resources/ghostty"
  # The bundle changed after xcodebuild's signature — re-sign.
  RESIGN_ARGS=(--force -s "$CODE_SIGN_IDENTITY" --entitlements "$ROOT/App/Temple.entitlements")
  [[ "$CODE_SIGN_IDENTITY" != "-" ]] && RESIGN_ARGS+=(--options runtime)
  codesign "${RESIGN_ARGS[@]}" "$DIST/$SCHEME.app"
else
  echo "warning: $GHOSTTY_SHARE missing — run Scripts/build-ghostty.sh first;" >&2
  echo "         the app will fall back to a dev checkout at runtime (degraded outside this machine)" >&2
fi

echo ""
echo "==> built: $DIST/$SCHEME.app"
echo "==> signature:"
codesign -dv "$DIST/$SCHEME.app" 2>&1 | sed 's/^/      /' || true
echo ""
echo "Launch with:  open \"$DIST/$SCHEME.app\""
