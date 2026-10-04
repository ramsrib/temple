#!/usr/bin/env bash
# Integration regression check for the bundled SwiftUI @main, not SwiftPM.
# Build with Scripts/build-app.sh first. Requires an unlocked macOS desktop,
# System Events accessibility access, and the fixture made by demo-data.py.
# The ⌘W step brings the failure window to the front for a moment: anything
# typed then goes to it. Like make demo, the launch uses the real UserDefaults
# domain; the window and split-view frames it autosaves there are put back as
# they were on exit.
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

# A directory where the database file should be: opening it fails with
# SQLite's own error, and its folder exists, so Reveal in Finder is offered.
mkdir -p "$CHECK_DIR/broken/temple.sqlite"

# expected: normal | newer-schema | broken. action: how the failure window is
# left — its Quit button, its red close button, or Window ▸ Close (⌘W). Each
# must end the process: a failure window has no model and no New Window, so a
# close that left the app running would leave a menu bar with no way back.
check_window() {
  local state="$1" expected="$2" action="${3:-quit}"
  TEMPLE_CLAUDE_ROOT="$DEMO/claude-store" \
    TEMPLE_CODEX_ROOT="$DEMO/codex-store" \
    TEMPLE_STATE_DIR="$state" \
    "$BINARY" > "$CHECK_DIR/$expected-$action.log" 2>&1 &
  CHECK_PID=$!
  sleep 8
  osascript - "$CHECK_PID" "$expected" "$action" <<'APPLESCRIPT'
on run argv
  set targetPID to (item 1 of argv) as integer
  set expected to item 2 of argv
  -- Not "action": inside a System Events tell that names its AXAction class.
  set how to item 3 of argv
  tell application "System Events"
    -- A launch right after another Temple quit can take a moment to appear.
    repeat 20 times
      if exists (first process whose unix id is targetPID) then exit repeat
      delay 0.5
    end repeat
    tell (first process whose unix id is targetPID)
      if (count of windows) is not 1 then error expected & ": expected one window, got " & (count of windows)
      set windowNames to name of windows
      if expected is not "normal" then
        -- Query scalar values under the PID selector. System Events' returned
        -- UI references use process names, which are ambiguous with two Temples.
        -- SwiftUI exposes no button titles here, so buttons are counted; they
        -- are in view order, Quit last.
        set messages to value of every static text of group 1 of first window
        set buttonCount to count of buttons of group 1 of first window
        if expected is "newer-schema" then
          if messages does not contain "Update Temple to continue" then error "newer-schema: missing update-required title"
          if buttonCount is not 1 then error "newer-schema: expected only Quit, got " & buttonCount & " buttons"
        else
          if messages does not contain "Temple couldn't open its data" then error "broken: missing couldn't-open title"
          -- Reveal in Finder (its folder exists), Copy Details, Quit.
          if buttonCount is not 3 then error "broken: expected 3 buttons, got " & buttonCount
        end if
        if name of first window is not "Temple" then error expected & ": window is not titled Temple"
        -- No model means no Temple commands, but SwiftUI's default File ▸ New
        -- Window (⌘N) would still open a second failure window.
        -- (With New Window gone the File menu is empty and SwiftUI drops it;
        -- Close then lives in the Window menu.)
        if (name of every menu bar item of menu bar 1) contains "File" then
          if (name of every menu item of menu 1 of menu bar item "File" of menu bar 1) contains "New Window" then error expected & ": File menu offers New Window"
        end if
        -- The process may be gone before the click returns; whether it exited
        -- is checked from the shell, so an error here proves nothing.
        try
          if how is "quit" then
            click button buttonCount of group 1 of first window
          else if how is "close-button" then
            click (first button of first window whose subrole is "AXCloseButton")
          else
            -- ⌘W acts on the key window, so this one case brings Temple forward.
            set frontmost to true
            delay 0.5
            click menu item "Close" of menu 1 of menu bar item "Window" of menu bar 1
          end if
        end try
        return expected & " (" & how & "): " & windowNames
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
  if [[ "$expected" != normal ]]; then
    # Every way out must exit, including the no-AppModel termination path.
    for attempt in {1..50}; do
      if ! kill -0 "$CHECK_PID" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if kill -0 "$CHECK_PID" 2>/dev/null; then
      echo "error: $expected window: $action did not terminate the app" >&2
      exit 1
    fi
  else
    kill "$CHECK_PID"
  fi
  wait "$CHECK_PID" 2>/dev/null || true
  CHECK_PID=""
}

check_window "$DEMO/state" normal
check_window "$CHECK_DIR/newer" newer-schema quit
check_window "$CHECK_DIR/newer" newer-schema close-button
check_window "$CHECK_DIR/broken" broken quit
# Last: the only step that brings a Temple to the front (⌘W needs a key
# window), so nothing launched after it can catch the keystrokes it steals.
check_window "$CHECK_DIR/broken" broken close-menu
