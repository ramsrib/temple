#!/usr/bin/env bash
#
# release-notes.sh — draft docs/releases/<version>.md from the log since the
# last tag, with a headless Claude agent (claude-run, Sri's dotfiles).
#
#   VERSION=v0.x.y ./Scripts/release-notes.sh     # or: make release-notes VERSION=…
#
# A draft, never a release: it writes the file and stops. Read it, edit it,
# commit it; `make release` publishes what is committed. The agent also says
# whether VERSION fits what is in the release: v0.5.0 first went out as patch
# v0.4.1 because "the CLI is new" hid an unreleased engine rewrite in the log.
#
# Env knobs: VERSION (required) · NOTES (default docs/releases/<version>.md)
# · SINCE (the previous tag; default the latest)
# · MODEL (default opus: the notes are read by users, so taste decides)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:?set VERSION, e.g. VERSION=v0.1.0}"
NOTES="${NOTES:-docs/releases/$VERSION.md}"
MODEL="${MODEL:-opus}"
command -v claude-run >/dev/null \
  || { echo "error: claude-run not found (dotfiles/bin); write $NOTES by hand instead" >&2; exit 1; }
[[ -e "$NOTES" ]] && { echo "error: $NOTES exists; delete it to draft again" >&2; exit 1; }

git fetch --tags --quiet origin 2>/dev/null || true
LAST_TAG="${SINCE:-$(git tag -l 'v*' --sort=-v:refname | head -1)}"
RANGE="${LAST_TAG:+$LAST_TAG..}HEAD"
[[ -n "$(git log --oneline "$RANGE")" ]] || { echo "error: nothing since $LAST_TAG" >&2; exit 1; }
mkdir -p "$(dirname "$NOTES")"

EXAMPLE="$(ls docs/releases/*.md 2>/dev/null | sort -V | tail -1 || true)"
PROMPT="$(mktemp)"; trap 'rm -f "$PROMPT"' EXIT
cat > "$PROMPT" <<EOF
Draft the release notes for Temple $VERSION (previous release: ${LAST_TAG:-none}).
You are in the Temple repo. Write exactly one file, $NOTES, and change nothing
else: no commits, no other edits, no release, no tag.

Read first:
- The "Release notes" section of RELEASE.md: the rules, followed exactly.
- ${EXAMPLE:-docs/releases/} : a published example; match its voice and shape.
- \`git log --format='%h %s%n%b' $RANGE\` and \`git diff --stat $RANGE\`.
  Open a commit's diff whenever its subject leaves unclear what a user sees.

Every bullet traces to commits in $RANGE; never invent a feature. Name menus,
shortcuts and commands as the source spells them. No em-dashes, and no
"Full Changelog" line (GitHub appends it).

Then end your turn with a short report, not the notes:
1. NEW IN THIS RELEASE: the user-visible features that ship for the first
   time, one line each.
2. VERSION: does $VERSION fit them? A new feature or a reworked area wants a
   minor bump; fixes alone, a patch. If $VERSION looks wrong, say which
   version you would pick and why, first and plainly.
3. UNSURE: anything you left out or worded loosely because the log was unclear.
EOF

echo "==> drafting $NOTES from $RANGE ($(git rev-list --count "$RANGE") commits, model $MODEL)"
claude-run -m "$MODEL" -C "$ROOT" -f "$PROMPT" --print

[[ -s "$NOTES" ]] || { echo "error: the agent wrote no $NOTES" >&2; exit 1; }
if grep -nE '—| -- ' -- "$NOTES" >&2; then
  echo "warning: the draft has em-dashes (above); make release will refuse them" >&2
fi
echo ""
echo "==> drafted $NOTES; read it, edit, commit, then: make release VERSION=$VERSION"
