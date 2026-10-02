#!/usr/bin/env bash
#
# ghostty-stamp.sh — is Vendor/GhosttyKit.xcframework built from what this
# checkout says it should be (ADR-026)?
#
#   ghostty-stamp.sh expected   print the stamp this checkout calls for
#   ghostty-stamp.sh check      exit 1, saying why, if the installed artifact's
#                               stamp differs or is missing
#
# The stamp is the pinned Ghostty tag, the pinned Zig, and each patch in
# Patches/ghostty by name and content digest. build-ghostty.sh writes it into
# the xcframework it installs (plus the slice target, which is recorded but not
# compared), so replacing the artifact replaces the stamp with it.
#
# Why: Vendor/ is git-ignored and survives `make clean`, and nothing else
# rebuilds it. A checkout that gains a patch keeps linking the old artifact —
# same C API, so it compiles, tests, signs and notarizes fine — and a release
# ships without the fix. This makes that a build error instead.
#
# Every value is captured and validated before use: a stamp is only as good as
# its inputs, and `echo "$(failing command)"` succeeds with an empty field.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$ROOT/Vendor/GhosttyKit.xcframework/.temple-build-stamp"

die() { echo "error: $*" >&2; exit 1; }

# The pins live in build-ghostty.sh; read them rather than restate them.
pin() {
    local value
    value="$(sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$ROOT/Scripts/build-ghostty.sh" | head -1)" \
        || die "could not read Scripts/build-ghostty.sh"
    [ -n "$value" ] || die "could not read $1 from Scripts/build-ghostty.sh (expected a line $1=\"...\")"
    printf '%s' "$value"
}

# Runs inside $(...), where bash drops errexit: every step propagates by hand.
expected() {
    local tag zig patch digest
    tag="$(pin GHOSTTY_TAG)" || return 1
    zig="$(pin ZIG_VERSION)" || return 1
    printf 'ghostty-tag %s\nzig %s\n' "$tag" "$zig"
    for patch in "$ROOT"/Patches/ghostty/*.patch; do
        [ -e "$patch" ] || continue
        digest="$(shasum -a 256 "$patch")" || die "could not hash $patch"
        digest="${digest%% *}"
        [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "bad digest for $patch: '$digest'"
        printf 'patch %s %s\n' "$digest" "$(basename "$patch")"
    done
}

check() {
    local fix="run ./Scripts/build-ghostty.sh (GHOSTTY_XCFRAMEWORK_TARGET=native is enough for local builds)"
    local want have
    want="$(expected)"
    if [ ! -f "$STAMP" ]; then
        echo "error: Vendor/GhosttyKit.xcframework has no build stamp — it predates" >&2
        echo "       Patches/ghostty (ADR-026) or was not built by build-ghostty.sh;" >&2
        echo "       $fix" >&2
        exit 1
    fi
    have="$(grep -v '^target ' "$STAMP" || true)"
    if [ "$want" != "$have" ]; then
        echo "error: Vendor/GhosttyKit.xcframework is stale — built from a different" >&2
        echo "       Ghostty tag, Zig, or patch set than this checkout pins." >&2
        echo "       this checkout:" >&2
        printf '%s\n' "$want" | sed 's/^/         /' >&2
        echo "       the artifact:" >&2
        printf '%s\n' "$have" | sed 's/^/         /' >&2
        echo "       $fix" >&2
        exit 1
    fi
    # Temple ships for Apple Silicon: whatever the target, a macOS slice must carry arm64.
    if ! ls -d "$ROOT"/Vendor/GhosttyKit.xcframework/macos-*arm64* >/dev/null 2>&1; then
        die "Vendor/GhosttyKit.xcframework has no macOS arm64 slice; $fix"
    fi
}

case "${1:-}" in
    expected) out="$(expected)"; printf '%s\n' "$out" ;;
    check) check ;;
    *) echo "usage: $0 expected|check" >&2; exit 2 ;;
esac
