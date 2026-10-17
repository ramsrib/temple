#!/bin/sh
# Sessions on hosts have no flag: they stay invisible until a host is
# enabled in Settings ▸ Hosts (docs/designs/remote-ssh.md, ADR-036). Run
# against a built .app before a release:
#
#   Scripts/check-remote-code.sh [dist/Temple.app]
#
# 1. The binary carries the remote code. AGENTS.md "Two entry points": the
#    .app is built by xcodebuild from App/TempleApp.swift, not the binary
#    `make demo` runs, so the no-host tests (RemoteHostsTests) speak for the
#    .app only if the same code is in it. The marker is the host list's key,
#    longer than 15 bytes so `strings` can see it.
# 2. The host list starts empty: nothing in the bundle sets it, and no
#    source registers a default for it (only the user's own Settings ▸ Hosts
#    writes it, RemoteHostsModel), so a fresh install shows no remote UI.
set -eu
APP=${1:-dist/Temple.app}
BIN="$APP/Contents/MacOS/Temple"
KEY=temple.settings.remoteHosts
REPO=$(cd "$(dirname "$0")/.." && pwd)

[ -x "$BIN" ] || { echo "✗ no binary at $BIN (make app first)"; exit 1; }
strings "$BIN" | grep -q "$KEY" || { echo "✗ $BIN does not carry $KEY: the remote code is not in this build"; exit 1; }
if /usr/libexec/PlistBuddy -c Print "$APP/Contents/Info.plist" | grep -q "$KEY"; then
    echo "✗ Info.plist sets $KEY"; exit 1
fi
if grep -rn "register(defaults" "$REPO/Sources" "$REPO/App" | grep -q remoteHosts; then
    echo "✗ a source registers a default for $KEY"; exit 1
fi
echo "✓ $BIN carries the remote code, and $KEY starts empty"
