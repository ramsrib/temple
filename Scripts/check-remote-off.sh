#!/bin/sh
# Remote (SSH) sessions ship dark (docs/designs/remote-ssh.md, phase 0).
# Run against a built .app before a release while the flag is still off:
#
#   Scripts/check-remote-off.sh [dist/Temple.app]
#
# 1. The binary carries the remote code. AGENTS.md "Two entry points": the
#    .app is built by xcodebuild from App/TempleApp.swift, not the binary
#    `make demo` runs, so the flag-off tests (RemoteHostsTests) speak for
#    the .app only if the same code is in it. The marker is the flag's key,
#    longer than 15 bytes so `strings` can see it.
# 2. The flag defaults to off: nothing in the bundle registers a value for
#    it, and no source registers a default (only an explicit true in the
#    user's settings domain turns it on, RemoteHostsModel.featureEnabled).
set -eu
APP=${1:-dist/Temple.app}
BIN="$APP/Contents/MacOS/Temple"
KEY=temple.feature.remoteHosts
REPO=$(cd "$(dirname "$0")/.." && pwd)

[ -x "$BIN" ] || { echo "✗ no binary at $BIN (make app first)"; exit 1; }
strings "$BIN" | grep -q "$KEY" || { echo "✗ $BIN does not carry $KEY: the remote code is not in this build"; exit 1; }
if /usr/libexec/PlistBuddy -c Print "$APP/Contents/Info.plist" | grep -q "$KEY"; then
    echo "✗ Info.plist sets $KEY"; exit 1
fi
if grep -rn "register(defaults" "$REPO/Sources" "$REPO/App" | grep -q remoteHosts; then
    echo "✗ a source registers a default for $KEY"; exit 1
fi
echo "✓ $BIN carries the remote code, and $KEY defaults to off"
