#!/usr/bin/env bash
# Window-frame preference save/restore for the check scripts.
#
# The bundled checks launch dist/Temple.app with the real UserDefaults domain
# (com.sriramb.temple), and AppKit autosaves window and split-view geometry
# there: `NSWindow Frame <name>` (a string) and `NSSplitView Subview Frames
# <name>` (an array of strings). Without this, every check run leaves the
# geometry of its throwaway window behind in Sri's preferences.
#
# Source this file, then:
#   frame_prefs_save    <domain> <file>   before the first launch
#   frame_prefs_restore <domain> <file>   after the last launched PID is dead
# Restore deletes every such key that did not exist at save time and writes
# back the saved value (type and all) of every one that did, if it differs or
# is gone. No other key is read for writing, written or deleted.
#
# Known limit: a key the user's own running Temple rewrites between save and
# restore is put back to its value at save time too — the two processes share
# the domain and their writes are indistinguishable. That Temple holds its
# frames in memory and saves them again on its next move or resize.
#
# Run directly with --self-test to exercise both functions on a scratch
# domain (com.sriramb.temple.scripttest), never on the real one.

# Prints the matching keys of a domain as an XML plist dict (an empty dict
# for a domain that does not exist). Fails, printing nothing, if the domain
# cannot be read: an unreadable domain must never pass for an empty one.
frame_prefs__snapshot() {
  local raw
  raw="$(defaults export "$1" -)" || return 1
  printf '%s' "$raw" | /usr/bin/python3 -c '
import plistlib, sys
prefs = plistlib.loads(sys.stdin.buffer.read())
keep = {k: v for k, v in prefs.items()
        if k.startswith("NSWindow Frame ") or k.startswith("NSSplitView Subview Frames ")}
sys.stdout.buffer.write(plistlib.dumps(keep, fmt=plistlib.FMT_XML))
'
}

# Fails without leaving a snapshot, so a later restore touches nothing.
frame_prefs_save() {
  local domain="$1" file="$2"
  if ! { frame_prefs__snapshot "$domain" > "$file.partial" && mv "$file.partial" "$file"; }; then
    rm -f "$file.partial"
    echo "error: could not snapshot window frames in $domain" >&2
    return 1
  fi
}

frame_prefs_restore() {
  local domain="$1" file="$2"
  [[ -s "$file" ]] || return 0   # nothing was saved: nothing was launched
  local current ops op key value status=0
  current="$(mktemp /private/tmp/temple-frame-prefs.XXXXXX)"
  ops="$(mktemp /private/tmp/temple-frame-prefs-ops.XXXXXX)"
  # NUL-separated ops: "delete" key | "write" key xml-fragment. Computed into
  # a file first, so a failed snapshot or diff is an error, not "no changes".
  if ! frame_prefs__snapshot "$domain" > "$current" || ! /usr/bin/python3 - "$file" "$current" > "$ops" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f: saved = plistlib.load(f)
with open(sys.argv[2], "rb") as f: now = plistlib.load(f)
def fragment(value):
    xml = plistlib.dumps(value, fmt=plistlib.FMT_XML).decode()
    return xml.split('<plist version="1.0">', 1)[1].rsplit("</plist>", 1)[0].strip()
out = sys.stdout.buffer
for key in sorted(now):
    if key not in saved:
        out.write(b"delete\0" + key.encode() + b"\0")
for key in sorted(saved):
    if now.get(key) != saved[key]:
        out.write(b"write\0" + key.encode() + b"\0" + fragment(saved[key]).encode() + b"\0")
PY
  then
    rm -f "$current" "$ops"
    return 1
  fi
  while IFS= read -r -d '' op && IFS= read -r -d '' key; do
    if [[ "$op" == write ]]; then
      IFS= read -r -d '' value
      defaults write "$domain" "$key" "$value" || status=1
    else
      defaults delete "$domain" "$key" || status=1
    fi
  done < "$ops"
  rm -f "$current" "$ops"
  return "$status"
}

frame_prefs__self_test() {
  set -euo pipefail
  local domain=com.sriramb.temple.scripttest dir fail=0
  dir="$(mktemp -d /private/tmp/temple-frame-prefs-test.XXXXXX)"
  defaults delete "$domain" >/dev/null 2>&1 || true
  # `defaults delete` empties the scratch domain but leaves its file behind.
  trap 'defaults delete '"$domain"' >/dev/null 2>&1 || true; rm -f "$HOME/Library/Preferences/'"$domain"'.plist"; rm -rf '"$dir" EXIT

  check() { # description, expected, actual
    if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: expected [$2], got [$3]"; fail=1; fi
  }
  read_or_none() { defaults read "$domain" "$1" 2>/dev/null || echo "<none>"; }
  type_or_none() { defaults read-type "$domain" "$1" 2>/dev/null || echo "<none>"; }

  # An empty domain: save then restore deletes whatever appeared.
  frame_prefs_save "$domain" "$dir/empty.plist"
  defaults write "$domain" "NSWindow Frame fresh" '<string>{{5, 5}, {10, 10}}</string>'
  frame_prefs_restore "$domain" "$dir/empty.plist"
  check "absent domain: new frame key deleted" "<none>" "$(read_or_none "NSWindow Frame fresh")"

  # Before the run.
  defaults write "$domain" "NSWindow Frame main-AppWindow-1" '<string>{{100, 200}, {800, 600}}</string>'
  defaults write "$domain" "NSSplitView Subview Frames main, SidebarNavigationSplitView" \
    '<array><string>0.000000, 0.000000, 240.000000, 600.000000, NO, NO</string><string>241.000000, 0.000000, 559.000000, 600.000000, NO, NO</string></array>'
  defaults write "$domain" "NSSplitView Subview Frames gone-during-run" '<array><string>a</string></array>'
  defaults write "$domain" "fontSize" -int 13
  defaults write "$domain" "NSWindow Frameless" '<string>not a frame key</string>'
  local split_before
  split_before="$(defaults read "$domain" "NSSplitView Subview Frames main, SidebarNavigationSplitView")"
  frame_prefs_save "$domain" "$dir/saved.plist"

  # What a run does: move the window, add new geometry, drop a key, and
  # change keys that are not window geometry.
  defaults write "$domain" "NSWindow Frame main-AppWindow-1" '<string>{{0, 0}, {1200, 900}}</string>'
  defaults write "$domain" "NSSplitView Subview Frames main, SidebarNavigationSplitView" '<array><string>changed</string></array>'
  defaults delete "$domain" "NSSplitView Subview Frames gone-during-run"
  defaults write "$domain" "NSWindow Frame main-AppWindow-2" '<string>{{1, 1}, {2, 2}}</string>'
  defaults write "$domain" "NSSplitView Subview Frames new split" '<array><string>x</string></array>'
  defaults write "$domain" "fontSize" -int 15
  defaults write "$domain" "NSWindow Frameless" '<string>changed too</string>'
  defaults write "$domain" "addedDuringRun" -bool true

  frame_prefs_restore "$domain" "$dir/saved.plist"

  check "existing frame restored" "{{100, 200}, {800, 600}}" "$(read_or_none "NSWindow Frame main-AppWindow-1")"
  check "existing frame stays a string" "Type is string" "$(type_or_none "NSWindow Frame main-AppWindow-1")"
  check "existing split restored exactly" "$split_before" "$(read_or_none "NSSplitView Subview Frames main, SidebarNavigationSplitView")"
  check "existing split stays an array" "Type is array" "$(type_or_none "NSSplitView Subview Frames main, SidebarNavigationSplitView")"
  check "split deleted during the run comes back" "Type is array" "$(type_or_none "NSSplitView Subview Frames gone-during-run")"
  check "new frame key deleted" "<none>" "$(read_or_none "NSWindow Frame main-AppWindow-2")"
  check "new split key deleted" "<none>" "$(read_or_none "NSSplitView Subview Frames new split")"
  check "unrelated key untouched" "15" "$(read_or_none fontSize)"
  check "look-alike key untouched" "changed too" "$(read_or_none "NSWindow Frameless")"
  check "unrelated new key untouched" "1" "$(read_or_none addedDuringRun)"

  # A second restore is a no-op.
  frame_prefs_restore "$domain" "$dir/saved.plist"
  check "restore is idempotent" "{{100, 200}, {800, 600}}" "$(read_or_none "NSWindow Frame main-AppWindow-1")"
  # A corrupt snapshot is an error, and nothing is written or deleted.
  echo "not a plist" > "$dir/corrupt.plist"
  if frame_prefs_restore "$domain" "$dir/corrupt.plist" 2>/dev/null; then check "corrupt snapshot fails" "failure" "success"
  else check "corrupt snapshot fails" "failure" "failure"; fi
  check "corrupt snapshot writes nothing" "{{100, 200}, {800, 600}}" "$(read_or_none "NSWindow Frame main-AppWindow-1")"
  # No saved file (the script died before saving): restore touches nothing.
  defaults write "$domain" "NSWindow Frame main-AppWindow-3" '<string>{{3, 3}, {3, 3}}</string>'
  frame_prefs_restore "$domain" "$dir/never-saved.plist"
  check "no snapshot, no restore" "{{3, 3}, {3, 3}}" "$(read_or_none "NSWindow Frame main-AppWindow-3")"

  if [[ "$fail" != 0 ]]; then echo "frame prefs self-test FAILED"; return 1; fi
  echo "frame prefs self-test passed"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --self-test) frame_prefs__self_test ;;
    *) echo "usage: source $0 (frame_prefs_save / frame_prefs_restore), or $0 --self-test" >&2; exit 2 ;;
  esac
fi
