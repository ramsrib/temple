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
#   4. Create the GitHub release as a draft with both artifacts (its notes from
#      docs/releases/<version>.md), push the tag <version>, then publish the
#      draft. A run that failed partway is finished by running it again.
#
# Env knobs: VERSION (required, e.g. v0.1.0) · NOTES (default
# docs/releases/<version>.md) · DRAFT=1 · NO_PUBLISH=1 (stop after packaging:
# nothing tagged or published, no notes needed) · notarization creds
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

# 0. preflight ---------------------------------------------------------------
# VERSION is typed by hand, so check the two claims the record can't recover
# from: releasing a version that was already released, and skipping one (a gap
# in the tags is indistinguishable from a release whose artifacts went
# missing). Set FORCE_VERSION=1 to jump on purpose, e.g. to leave 0.2.0 for a
# feature that is still landing.
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "error: VERSION must look like v1.2.3 (got '$VERSION')" >&2; exit 1; }

git fetch --tags --quiet origin 2>/dev/null || true
HEAD_SHA="$(git rev-parse HEAD)"

# What already exists for VERSION decides whether this run may go on:
#   a published release              never: releases are immutable
#   a tag at another commit          never: the version names other code
#   a tag at HEAD, nothing published a run that failed after tagging (or a
#                                    draft): this run finishes it
#   a draft without a tag            a run that failed before tagging: this
#                                    run replaces the draft
# GitHub's tag is the one that counts; a local tag only matters when GitHub
# has none (a push that failed), and then it must be at HEAD too.
release_state() {   # none | draft | published
  # A lookup that fails reads as "none". That is safe: step 4 looks again
  # before it changes anything, and creates the release before the tag, so a
  # wrong "none" fails there, tagless.
  gh release view "$VERSION" --json isDraft \
    -q 'if .isDraft then "draft" else "published" end' 2>/dev/null || echo none
}
remote_tag_commit() {   # the commit GitHub's tag VERSION names, or nothing
  local refs
  refs="$(git ls-remote --tags origin "refs/tags/$VERSION" "refs/tags/$VERSION^{}")" \
    || { echo "error: could not read tags from origin" >&2; return 1; }
  # An annotated tag lists the tag object, then the commit as <tag>^{}.
  awk -v p="refs/tags/$VERSION^{}" '$2 == p { peeled = $1 } { any = $1 }
    END { print (peeled != "" ? peeled : any) }' <<< "$refs"
}

RELEASE_STATE="$(release_state)"
if [[ "$RELEASE_STATE" == published ]]; then
  echo "error: $VERSION is already released; releases are immutable, so cut the next version" >&2
  exit 1
fi
REMOTE_TAG="$(remote_tag_commit)"
TAG_STATE=none   # none | remote (GitHub has it, at HEAD) | local (only here, at HEAD)
if [[ -n "$REMOTE_TAG" ]]; then
  if [[ "$REMOTE_TAG" != "$HEAD_SHA" ]]; then
    echo "error: $VERSION is tagged at ${REMOTE_TAG:0:7} on GitHub, not at HEAD (${HEAD_SHA:0:7});" >&2
    echo "       the version names other code: cut the next one, or finish it by hand (RELEASE.md)" >&2
    exit 1
  fi
  TAG_STATE=remote
elif git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
  if [[ "$(git rev-parse "$VERSION^{commit}")" != "$HEAD_SHA" ]]; then
    echo "error: a local tag $VERSION names $(git rev-parse --short "$VERSION^{commit}"), not HEAD, and GitHub has" >&2
    echo "       no such tag; if it is a leftover, delete it (git tag -d $VERSION) and run again" >&2
    exit 1
  fi
  TAG_STATE=local
fi

if [[ "$TAG_STATE" != none || "$RELEASE_STATE" == draft ]]; then
  # Finishing a version that was started: its number was checked when it was.
  # (A newer version may have shipped since; that must not strand this one.)
  echo "==> $VERSION was started and not published (tag: $TAG_STATE, release: $RELEASE_STATE); this run finishes it"
else
  LAST_TAG="$(git tag -l 'v*' --sort=-v:refname | head -1)"
  if [[ -n "$LAST_TAG" ]]; then
    IFS=. read -r lm ln lp <<< "${LAST_TAG#v}"
    EXPECTED=("v$lm.$ln.$((lp + 1))" "v$lm.$((ln + 1)).0" "v$((lm + 1)).0.0")
    if [[ ! " ${EXPECTED[*]} " =~ " $VERSION " && -z "${FORCE_VERSION:-}" ]]; then
      echo "error: $VERSION does not follow $LAST_TAG — expected one of: ${EXPECTED[*]}" >&2
      echo "       (FORCE_VERSION=1 to skip a version deliberately)" >&2
      exit 1
    fi
  fi
fi

# A release says what is in it. GitHub's generated notes list merged PRs, and
# Temple lands on main without them, so 24 releases went out saying only
# "Full Changelog". The notes are committed with the code (the dirty-tree
# check below holds them to that), and are published as written.
NOTES="${NOTES:-docs/releases/$VERSION.md}"
if [[ -n "${NO_PUBLISH:-}" ]]; then
  echo "==> NO_PUBLISH: building, signing, notarizing and packaging only (notes not needed)"
elif [[ ! -e "$NOTES" ]]; then
  # Draft them, then stop: what is published is what was read and committed.
  echo "==> no release notes at $NOTES; drafting them"
  NOTES="$NOTES" ./Scripts/release-notes.sh
  echo "    (release stopped for the review; nothing was built, tagged or published)"
  exit 1
fi
if [[ -z "${NO_PUBLISH:-}" ]]; then
  [[ -s "$NOTES" ]] || { echo "error: $NOTES is empty" >&2; exit 1; }
  DASHES="$(grep -nE '—| -- ' -- "$NOTES")" && rc=0 || rc=$?
  case $rc in
    0) echo "error: $NOTES has an em-dash; release notes go out as Sri, who writes without them:" >&2
       echo "$DASHES" >&2
       exit 1 ;;
    1) ;;  # none
    *) echo "error: could not read $NOTES" >&2; exit 1 ;;
  esac
fi

# The tag must name code that others can actually get.
[[ -z "$(git status --porcelain)" ]] \
  || { echo "error: working tree is dirty — commit or stash before releasing" >&2; exit 1; }
git fetch --quiet origin main 2>/dev/null || true
if [[ -n "$(git log --oneline origin/main..HEAD 2>/dev/null)" ]]; then
  echo "error: HEAD is ahead of origin/main — push before releasing, or the tag" >&2
  echo "       points at code nobody else has" >&2
  exit 1
fi
echo "==> releasing $VERSION (previous: ${LAST_TAG:-none})"

# 1. build ---------------------------------------------------------------
echo "==> building Temple.app ($VERSION)"
MARKETING_VERSION="${VERSION#v}" ./Scripts/build-app.sh

# The version is what a user sees in About, and a wrong one is invisible to us
# and permanent to them (it shipped as 0.1.0 for the whole of v0.1.1, because
# Info.plist hardcoded it and quietly won over the build setting). Assert it
# before anything is notarized, tagged, or published.
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [[ "$BUILT_VERSION" != "${VERSION#v}" ]]; then
  echo "error: built app says $BUILT_VERSION but this release is ${VERSION#v}" >&2
  echo "       (App/Info.plist must take \$(MARKETING_VERSION), not a literal)" >&2
  exit 1
fi
echo "    version: $BUILT_VERSION ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"

# The two checks RELEASE.md asks of every release build, run here so a release
# cannot skip them: the shipped binary carries the remote code and gives the
# host list no default, and each binary records the SDK it was built with
# (AGENTS.md, "Two entry points").
./Scripts/check-remote-code.sh "$APP"
./Scripts/check-sdk-linkage.sh "$APP/Contents/MacOS/Temple" "$APP/Contents/Helpers/temple"

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

if [[ -n "${NO_PUBLISH:-}" ]]; then
  echo "✓ $VERSION built, signed, notarized and packaged; NO_PUBLISH, so nothing was tagged or published"
  exit 0
fi

# 4. release, tag, publish ---------------------------------------------------
# In this order so that no failure leaves a public tag whose release is
# missing: until the tag is pushed, a failure leaves at most a draft, which the
# next run replaces; after it, the next run finds the tag at HEAD with nothing
# published and finishes the release.
#
# Look again before changing anything: the build took minutes, and another
# run or a person may have published this version meanwhile. This narrows the
# race, it cannot close it: GitHub has no "delete only if still a draft", so a
# publish landing between this look and the delete is lost. Workflow runs are
# serialized (concurrency: release); what remains is a person publishing the
# draft, or a Mac run, at the same moment as a run of the same version. A lock
# shared by both paths would close it, at the price of a stale lock blocking
# the very rerun that finishes a failed release; not worth it here.
case "$(release_state)" in
  published)
    echo "error: $VERSION was published while this run was building; nothing was changed" >&2
    exit 1 ;;
  draft)
    echo "==> replacing the unpublished draft of $VERSION"
    gh release delete "$VERSION" --yes ;;   # the release only; a tag stays
esac
echo "==> creating the draft release $VERSION with its assets"
gh release create "$VERSION" "$ZIP" "$DMG" \
  --draft \
  --target "$HEAD_SHA" \
  --title "Temple $VERSION" \
  --notes-file "$NOTES" \
  --generate-notes  # appended after the notes: the Full Changelog link

REMOTE_TAG="$(remote_tag_commit)"
if [[ "$REMOTE_TAG" == "$HEAD_SHA" ]]; then
  # GitHub's tag counts, even if a local one carries another annotation.
  echo "==> $VERSION is already tagged on GitHub at HEAD"
elif [[ -n "$REMOTE_TAG" ]]; then
  echo "error: $VERSION was tagged at ${REMOTE_TAG:0:7} on GitHub while this run was building;" >&2
  echo "       its draft release is left unpublished" >&2
  exit 1
else
  if [[ "$TAG_STATE" != local ]]; then
    echo "==> tagging $VERSION"
    git tag -a "$VERSION" -m "Temple $VERSION"
  fi
  git push origin "refs/tags/$VERSION"
fi

if [[ -n "${DRAFT:-}" ]]; then
  echo "✓ $VERSION is tagged and its release is a draft: publish it with"
  echo "  gh release edit $VERSION --draft=false, or run this release again"
  exit 0
fi
echo "==> publishing $VERSION"
gh release edit "$VERSION" --draft=false
echo "✓ released $VERSION"
