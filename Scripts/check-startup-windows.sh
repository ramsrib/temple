#!/usr/bin/env bash
# Integration regression check for the bundled SwiftUI @main, not SwiftPM.
# Build with Scripts/build-app.sh first. Requires an unlocked macOS desktop,
# System Events accessibility access, and the fixture made by demo-data.py.
# Like make demo, the launch uses the real UserDefaults domain; the window and
# split-view frames it autosaves there are put back as they were on exit.
set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=window-frame-prefs.sh
source "$ROOT/Scripts/window-frame-prefs.sh"
PREFS_DOMAIN=com.sriramb.temple
BINARY="$ROOT/dist/Temple.app/Contents/MacOS/Temple"
DEMO=/private/tmp/temple-demo
if [[ "$(ioreg -n Root -d1)" == *'"CGSSessionScreenIsLocked"=Yes'* ]]; then
  echo "error: unlock the Mac before checking startup windows" >&2
  exit 1
fi
[[ -x "$BINARY" ]] || { echo "error: build the bundle first" >&2; exit 1; }
[[ -f "$DEMO/state/temple.sqlite" ]] || { echo "error: create the demo fixture first" >&2; exit 1; }

CHECK_DIR="$(mktemp -d /private/tmp/temple-startup-check.XXXXXX)"
CHECK_PID=""
cleanup() {
  if [[ -n "$CHECK_PID" ]]; then
    kill "$CHECK_PID" 2>/dev/null || true
    wait "$CHECK_PID" 2>/dev/null || true
  fi
  # Only after the launched app is dead: it can autosave geometry until then.
  frame_prefs_restore "$PREFS_DOMAIN" "$CHECK_DIR/frame-prefs.plist" \
    || echo "warning: window-frame preferences in $PREFS_DOMAIN were not fully restored" >&2
  rm -rf "$CHECK_DIR"
}
trap cleanup EXIT
# The launch shares the real defaults domain; its window geometry is undone
# on exit (Scripts/window-frame-prefs.sh). No other key is touched.
frame_prefs_save "$PREFS_DOMAIN" "$CHECK_DIR/frame-prefs.plist"

# SQLite backup includes any committed WAL contents without changing the demo.
python3 - "$DEMO/state/temple.sqlite" "$CHECK_DIR/newer" <<'PY'
import pathlib, sqlite3, sys
directory = pathlib.Path(sys.argv[2])
directory.mkdir()
with sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True) as source:
    with sqlite3.connect(directory / "temple.sqlite") as newer:
        source.backup(newer)
        newer.execute("INSERT INTO grdb_migrations(identifier) VALUES ('startup-window-future-schema')")
PY

check_window() {
  local state="$1" expected="$2"
  TEMPLE_CLAUDE_ROOT="$DEMO/claude-store" \
    TEMPLE_CODEX_ROOT="$DEMO/codex-store" \
    TEMPLE_STATE_DIR="$state" \
    "$BINARY" > "$CHECK_DIR/$expected.log" 2>&1 &
  CHECK_PID=$!
  sleep 8
  osascript - "$CHECK_PID" "$expected" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set expected to item 2 of argv
  tell application "System Events"
    tell (first process whose unix id is targetPID)
      if (count of windows) is not 1 then error expected & ": expected one window, got " & (count of windows)
      set windowNames to name of windows
      if expected is "newer-schema" then
        -- Query scalar values under the PID selector. System Events' returned
        -- UI references use process names, which are ambiguous with two Temples.
        set messages to value of every static text of group 1 of first window
        if messages does not contain "This Temple is older than the data it found. Update Temple to continue." then error "newer-schema: missing update-required message"
        if (count of buttons of group 1 of first window) is not 1 then error "newer-schema: missing Quit button"
        -- No model means no Temple commands, but SwiftUI's default File ▸ New
        -- Window (⌘N) would still open a second update-required window.
        if exists menu bar item "File" of menu bar 1 then
          if (name of every menu item of menu 1 of menu bar item "File" of menu bar 1) contains "New Window" then error "newer-schema: File menu offers New Window"
        end if
        click button 1 of group 1 of first window
      else
        -- The same query must see Temple's own File menu, or the check above
        -- proves nothing.
        if (name of every menu item of menu 1 of menu bar item "File" of menu bar 1) does not contain "New Session" then error "normal: File menu lacks New Session"
      end if
      return expected & ": " & windowNames
    end tell
  end tell
end run
APPLESCRIPT
  if [[ "$expected" == newer-schema ]]; then
    # Quit must exit, including the no-AppModel termination path.
    for attempt in {1..50}; do
      if ! kill -0 "$CHECK_PID" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$CHECK_PID" 2>/dev/null; then
      echo "error: update-required Quit did not terminate the app" >&2
      exit 1
    fi
  else
    kill "$CHECK_PID"
  fi
  wait "$CHECK_PID" 2>/dev/null || true
  CHECK_PID=""
}

check_window "$DEMO/state" normal
check_window "$CHECK_DIR/newer" newer-schema
