#!/usr/bin/env bash
# Proves source -> engine -> fill in the bundled binary (dist/Temple.app),
# which is built from App/TempleApp.swift, not the SwiftPM entry point the
# tests and `make demo` run. Build first with Scripts/build-app.sh.
#
# Everything lives under a private mktemp root in /private/tmp: two agent
# stores and a state dir. The schema comes from the production migrator
# (`templectl --init-db`); then three bare legacy rows (id, joined_via, host
# only — the shape an older build leaves) are inserted with sqlite3:
#   A  a Claude session whose transcript exists before launch
#   B  a Codex session whose rollout exists before launch
#   C  a Claude session with no transcript yet
# The app must fill A and B at startup (directory, title, transcript path,
# transcript-sourced), leave C alone, then fill C once its transcript is
# created after launch (live observation), and leave A unchanged when its
# transcript grows. Only this script's own PID is ever signalled.
#
# Requires an unlocked desktop, like check-startup-windows.sh (set
# TEMPLE_CHECK_ALLOW_LOCKED=1 to run it anyway: it drives no UI, but a run on
# a locked session is evidence, not the check). Like `make demo`, the launch
# still uses the real UserDefaults domain.
set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$ROOT/dist/Temple.app/Contents/MacOS/Temple"
CTL="$ROOT/.build/debug/templectl"
if [[ "$(ioreg -n Root -d1)" == *'"CGSSessionScreenIsLocked"=Yes'* && "${TEMPLE_CHECK_ALLOW_LOCKED:-}" != 1 ]]; then
  echo "error: unlock the Mac before checking the bundled engine" >&2
  exit 1
fi
[[ -x "$BINARY" ]] || { echo "error: build the bundle first (Scripts/build-app.sh)" >&2; exit 1; }
if [[ ! -x "$CTL" ]]; then (cd "$ROOT" && swift build --product templectl >/dev/null); fi

CHECK_DIR="$(mktemp -d /private/tmp/temple-bundled-engine.XXXXXX)"
APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
  rm -rf "$CHECK_DIR"
}
trap cleanup EXIT

CLAUDE="$CHECK_DIR/claude-store"
CODEX="$CHECK_DIR/codex-store"
STATE="$CHECK_DIR/state"
PROJECT="$CHECK_DIR/project"
mkdir -p "$CLAUDE/-project" "$CODEX/sessions/2026/10/04" "$STATE" "$PROJECT"
DB="$STATE/temple.sqlite"

A="$(uuidgen | tr 'A-Z' 'a-z')"
B="$(uuidgen | tr 'A-Z' 'a-z')"
C="$(uuidgen | tr 'A-Z' 'a-z')"
A_FILE="$CLAUDE/-project/$A.jsonl"
B_FILE="$CODEX/sessions/2026/10/04/rollout-2026-10-04T10-00-00-$B.jsonl"
C_FILE="$CLAUDE/-project/$C.jsonl"

claude_line() {
  printf '{"type":"user","sessionId":"%s","cwd":"%s","timestamp":"2026-10-04T10:00:00Z","message":{"content":"%s"}}\n' "$1" "$PROJECT" "$2"
}
claude_line "$A" "Bundled Claude prompt" > "$A_FILE"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","timestamp":"2026-10-04T10:00:00Z"}}\n{"type":"event_msg","payload":{"type":"user_message","message":"Bundled Codex prompt"}}\n' \
  "$B" "$PROJECT" > "$B_FILE"

run_env=(TEMPLE_CLAUDE_ROOT="$CLAUDE" TEMPLE_CODEX_ROOT="$CODEX" TEMPLE_STATE_DIR="$STATE")
env "${run_env[@]}" "$CTL" --init-db >/dev/null
for id in "$A" "$B" "$C"; do
  sqlite3 "$DB" "INSERT INTO session_state (id, joined_via, host) VALUES ('$id', 'imported', '');"
done
row() { sqlite3 -separator '|' "$DB" "SELECT agent, directory, directory_source, title, transcript_path FROM session_state WHERE id = '$1';"; }
filled() {
  local r; r="$(row "$1")"
  IFS='|' read -r agent directory source title path <<< "$r"
  [[ -n "$agent" && "$directory" == "$PROJECT" && "$source" == transcript && -n "$title" && "$path" == "$2" ]]
}
wait_for() {
  local what="$1"; shift
  for _ in $(seq 1 200); do
    if "$@"; then return 0; fi
    if ! kill -0 "$APP_PID" 2>/dev/null; then echo "error: the app exited (see $CHECK_DIR/app.log)" >&2; cat "$CHECK_DIR/app.log" >&2; exit 1; fi
    sleep 0.1
  done
  echo "error: $what within 20 s" >&2
  for id in "$A" "$B" "$C"; do echo "  $id: $(row "$id")" >&2; done
  exit 1
}

env "${run_env[@]}" "$BINARY" > "$CHECK_DIR/app.log" 2>&1 &
APP_PID=$!

both_filled() { filled "$A" "$A_FILE" && filled "$B" "$B_FILE"; }
wait_for "rows A and B filled at startup" both_filled
echo "startup fill: A $(row "$A")"
echo "startup fill: B $(row "$B")"
[[ "$(row "$C")" == "||||" ]] || { echo "error: C was written before it had a transcript: $(row "$C")" >&2; exit 1; }
echo "no transcript: C stays bare"

claude_line "$C" "Created after launch" > "$C_FILE"
c_filled() { filled "$C" "$C_FILE"; }
wait_for "row C filled after its transcript appeared" c_filled
echo "live fill: C $(row "$C")"

before="$(row "$A")"
claude_line "$A" "A later prompt" >> "$A_FILE"
sleep 2
[[ "$(row "$A")" == "$before" ]] || { echo "error: a transcript append changed a filled row: $(row "$A")" >&2; exit 1; }
echo "append: A unchanged"
echo "bundled engine check passed"
