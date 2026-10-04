#!/usr/bin/env bash
# Fails unless the SwiftPM executables record the SDK they were built with.
#
# A binary that records an older SDK runs with that SDK's compatibility
# behaviour, and nothing says so: under Swift Build's link (Swift 6.4) the
# demo recorded 14.0, and its sidebar drew 52pt below where it took clicks
# (see the comment above `linkAgainstBuildSDK` in Package.swift). `make build`
# runs this, so `make demo` never launches such a binary.
#
#   Scripts/check-sdk-linkage.sh [binary ...]   default: .build/debug/{temple,templectl,terminal-demo}
set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
want="$(xcrun --sdk macosx --show-sdk-version)"
if (($# == 0)); then
  set -- "$ROOT"/.build/debug/{temple,templectl,terminal-demo}
fi

status=0
for binary in "$@"; do
  [[ -f "$binary" ]] || { echo "error: no binary at $binary" >&2; status=1; continue; }
  got="$(otool -l "$binary" | awk '$1 == "cmd" { build = ($2 == "LC_BUILD_VERSION") } build && $1 == "sdk" { print $2; exit }')"
  if [[ "$got" != "$want" ]]; then
    echo "error: $(basename "$binary") records SDK ${got:-none}, built with SDK $want — it would run with that older SDK's AppKit/SwiftUI behaviour" >&2
    status=1
  fi
done
exit "$status"
