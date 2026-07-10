#!/usr/bin/env bash
#
# build-ghostty.sh — produce Vendor/GhosttyKit.xcframework from a clean clone.
#
# Track T (Temple Terminal Engine). This is the single, reproducible entry point
# for building libghostty into the embeddable artifact SwiftPM links against
# (see Package.swift's `GhosttyKit` binaryTarget and docs/BUILDING-GHOSTTY.md).
#
# Pins (bump deliberately — zig/ghostty drift is the #1 build breaker):
#   - Ghostty tag:  v1.3.1
#   - Zig version:  0.15.2   (build.zig.zon `minimum_zig_version` for v1.3.1)
#
# It:
#   1. Ensures Vendor/ghostty is checked out at the pinned tag (clones if absent).
#   2. Ensures the pinned zig is available (uses PATH zig if it already matches;
#      otherwise ~/.local/zig-<ver>/zig, downloading it if missing).
#   3. Runs `zig build -Demit-xcframework` and copies the result to
#      Vendor/GhosttyKit.xcframework.
#
# Env overrides:
#   GHOSTTY_XCFRAMEWORK_TARGET=universal|native   (default: universal)
#       'universal' = macOS (x86_64+arm64) + iOS + iOS-sim slices — what Ghostty's
#       own mac app ships; portable but slow (~30–60 min cold).
#       'native'    = single macOS slice for the host arch — much faster
#       (~10–15 min), sufficient for local dev/CI on the same arch.
#
set -euo pipefail

GHOSTTY_TAG="v1.3.1"
ZIG_VERSION="0.15.2"
XCFRAMEWORK_TARGET="${GHOSTTY_XCFRAMEWORK_TARGET:-universal}"

# Repo root = parent of this script's dir.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR="$ROOT/Vendor"
GHOSTTY_SRC="$VENDOR/ghostty"
OUT_XCFRAMEWORK="$VENDOR/GhosttyKit.xcframework"

log() { printf '\033[1;34m[build-ghostty]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Ghostty source at the pinned tag.
# ---------------------------------------------------------------------------
mkdir -p "$VENDOR"
if [ ! -d "$GHOSTTY_SRC/.git" ]; then
    log "Cloning ghostty $GHOSTTY_TAG into $GHOSTTY_SRC"
    git clone --depth 1 --branch "$GHOSTTY_TAG" \
        https://github.com/ghostty-org/ghostty "$GHOSTTY_SRC"
else
    current="$(git -C "$GHOSTTY_SRC" describe --tags --always 2>/dev/null || echo unknown)"
    log "ghostty already present at: $current (expected $GHOSTTY_TAG)"
fi

# ---------------------------------------------------------------------------
# 2. Zig toolchain at the pinned version.
# ---------------------------------------------------------------------------
ZIG=""
if command -v zig >/dev/null 2>&1 && [ "$(zig version)" = "$ZIG_VERSION" ]; then
    ZIG="$(command -v zig)"
    log "Using zig from PATH: $ZIG ($ZIG_VERSION)"
else
    ZIG_HOME="$HOME/.local/zig-$ZIG_VERSION"
    ZIG="$ZIG_HOME/zig"
    if [ ! -x "$ZIG" ]; then
        arch="$(uname -m)"   # arm64 -> aarch64
        [ "$arch" = "arm64" ] && arch="aarch64"
        tarball="zig-${arch}-macos-${ZIG_VERSION}.tar.xz"
        url="https://ziglang.org/download/${ZIG_VERSION}/${tarball}"
        log "Downloading zig $ZIG_VERSION from $url"
        mkdir -p "$HOME/.local"
        tmp="$(mktemp -d)"
        curl -fsSL "$url" -o "$tmp/zig.tar.xz"
        tar -xf "$tmp/zig.tar.xz" -C "$tmp"
        mv "$tmp/zig-${arch}-macos-${ZIG_VERSION}" "$ZIG_HOME"
        rm -rf "$tmp"
    fi
    log "Using pinned zig: $ZIG ($("$ZIG" version))"
fi

# ---------------------------------------------------------------------------
# 2b. Pick a macOS SDK that zig can link, and route zig to it via an `xcrun` shim.
#
# macOS 26 (Tahoe) / Xcode 26 SDKs list only `arm64e-macos` (not plain
# `arm64-macos`) in their libSystem `.tbd` targets. Zig 0.15.2 compiles for
# `arm64` and filters the tbd for `arm64-macos`, finds nothing, and every
# libSystem symbol comes up undefined — this breaks even the internal
# "build runner" compile before ghostty's own code is touched.
#
# Neither `SDKROOT` nor `zig build --sysroot` fixes the build-runner compile:
# zig locates the native SDK by running `xcrun --sdk macosx --show-sdk-path`,
# and `--sdk macosx` makes xcrun ignore SDKROOT (it always resolves to the
# active 26.5 SDK). The reliable fix is a PATH shim: a fake `xcrun` that
# answers `--show-sdk-path` with an arm64-capable SDK and delegates everything
# else to the real xcrun. Zig then links the runner *and* every artifact
# against a macOS 15.x SDK. Override the SDK with GHOSTTY_SDKROOT.
# ---------------------------------------------------------------------------
sdk_has_arm64() {
    local tbd="$1/usr/lib/libSystem.B.tbd"
    [ -f "$tbd" ] || return 1
    # Only the top-level `targets:` line decides which slices the library
    # provides. `arm64-macos` also appears in unrelated sub-sections, so a naive
    # whole-file grep false-matches arm64e-only SDKs — anchor to that line and
    # match `arm64-macos` as a whole token (grep -w rejects `arm64e-macos`).
    grep -m1 '^targets:' "$tbd" | grep -qw 'arm64-macos'
}

pick_sdk() {
    # 1. Explicit override.
    if [ -n "${GHOSTTY_SDKROOT:-}" ]; then echo "$GHOSTTY_SDKROOT"; return; fi
    # 2. The currently-active SDK, if it works.
    local active; active="$(xcrun --show-sdk-path 2>/dev/null || true)"
    if [ -n "$active" ] && sdk_has_arm64 "$active"; then echo "$active"; return; fi
    # 3. Any installed SDK that still exposes arm64-macos (prefer newest).
    local dir sdk
    for dir in \
        /Library/Developer/CommandLineTools/SDKs \
        /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs
    do
        [ -d "$dir" ] || continue
        for sdk in $(ls -1d "$dir"/MacOSX*.sdk 2>/dev/null | sort -Vr); do
            if sdk_has_arm64 "$sdk"; then echo "$sdk"; return; fi
        done
    done
}

SDKROOT_PICK="$(pick_sdk)"
if [ -z "$SDKROOT_PICK" ]; then
    cat >&2 <<'EOF'
ERROR: could not find a macOS SDK exposing `arm64-macos` in its libSystem tbd.
Zig 0.15.2 cannot link against arm64e-only SDKs (macOS 26 / Xcode 26).
Install the Command Line Tools that carry a macOS 15.x SDK, or set
GHOSTTY_SDKROOT to a suitable SDK path.
EOF
    exit 1
fi
export SDKROOT="$SDKROOT_PICK"
log "Using macOS SDK: $SDKROOT"

# Build the xcrun shim.
SHIM_DIR="$(mktemp -d)"
trap 'rm -rf "$SHIM_DIR"' EXIT
cat > "$SHIM_DIR/xcrun" <<EOF
#!/bin/bash
# Shim: answer SDK-path queries with an arm64-capable SDK (see build-ghostty.sh).
for a in "\$@"; do
    if [ "\$a" = "--show-sdk-path" ]; then echo "$SDKROOT_PICK"; exit 0; fi
done
exec /usr/bin/xcrun "\$@"
EOF
chmod +x "$SHIM_DIR/xcrun"

# libtool shim: Xcode 26's libtool silently DROPS archive members that are not
# 8-byte aligned ("warning: 64-bit mach-o member 'x.o' not 8-byte aligned").
# Zig 0.15's archive writer emits 2-byte alignment, so ghostty's LibtoolStep
# (which combines libghostty.a + all C deps into libghostty-fat.a) would lose
# the core libghostty_zcu.o — every ghostty_* symbol — without any build error.
# Fix: re-pack each input archive with Apple `ar` (correct alignment, and it
# also normalizes zig's mode-000 members) before invoking the real libtool.
cat > "$SHIM_DIR/libtool" <<'EOF'
#!/bin/bash
# NOTE: no `set -e` — Apple ar exits non-zero while extracting zig's mode-000
# archive members even though extraction succeeds; success is verified by
# comparing member counts instead.
set -uo pipefail
args=("$@")
# Only intervene on `libtool -static ... <inputs.a>` invocations.
if [ "${1:-}" != "-static" ]; then exec /usr/bin/libtool "$@"; fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out_args=()
i=0
n=${#args[@]}
while [ $i -lt $n ]; do
    a="${args[$i]}"
    repack_ok=""
    case "$a" in
        *.a)
            if [ -f "$a" ]; then
                # Absolutize: extraction happens after cd into a temp dir.
                abs="$a"
                case "$abs" in /*) ;; *) abs="$PWD/$abs" ;; esac
                d="$work/$i"; mkdir -p "$d"
                # Duplicate member names within one archive would be lost by
                # extract+repack; pass such archives through untouched.
                total="$(/usr/bin/ar t "$abs" 2>/dev/null | grep -cv '^__\.SYMDEF' || true)"
                uniqc="$(/usr/bin/ar t "$abs" 2>/dev/null | grep -v '^__\.SYMDEF' | sort -u | wc -l | tr -d ' ')"
                if [ -n "$total" ] && [ "$total" = "$uniqc" ] && [ "$total" != "0" ]; then
                    (cd "$d" && /usr/bin/ar x "$abs" 2>/dev/null || true
                     chmod u+rw ./* 2>/dev/null || true
                     rm -f __.SYMDEF)
                    got="$(ls -1 "$d" | wc -l | tr -d ' ')"
                    if [ "$got" = "$total" ]; then
                        repacked="$work/repacked-$i.a"
                        if (cd "$d" && /usr/bin/ar cr "$repacked" ./*) 2>/dev/null; then
                            out_args+=("$repacked")
                            repack_ok=1
                        fi
                    fi
                fi
            fi
            [ -n "$repack_ok" ] || out_args+=("$a")
            ;;
        *) out_args+=("$a") ;;
    esac
    i=$((i+1))
done
exec /usr/bin/libtool "${out_args[@]}"
EOF
chmod +x "$SHIM_DIR/libtool"

# ---------------------------------------------------------------------------
# 3. Build the xcframework.
# ---------------------------------------------------------------------------
BUILT="$GHOSTTY_SRC/macos/GhosttyKit.xcframework"

run_zig_build() {
    # -Demit-macos-app=false: emitting the xcframework otherwise also builds
    # Ghostty's own macOS app bundle (xcodebuild), which we don't need and which
    # fails to link under Xcode 26; we only want the library artifact.
    PATH="$SHIM_DIR:$PATH" "$ZIG" build \
        -Doptimize=ReleaseFast \
        -Dxcframework-target="$XCFRAMEWORK_TARGET" \
        -Demit-xcframework=true \
        -Demit-macos-app=false
}

# Sanity: the combined archive must actually contain the core libghostty
# symbols (see the libtool shim above for how they can silently go missing).
symbols_ok() {
    # NB: `grep -q` here would exit at first match, SIGPIPE-killing nm and (via
    # `set -o pipefail`) failing the check on a *good* archive. `grep -c` reads
    # all input.
    local lib count
    for lib in "$BUILT"/*/libghostty-fat.a; do
        [ -f "$lib" ] || return 1
        count="$(/usr/bin/nm "$lib" 2>/dev/null | grep -c "T _ghostty_app_new" || true)"
        [ "${count:-0}" -gt 0 ] || return 1
    done
    return 0
}

log "Building GhosttyKit.xcframework (target=$XCFRAMEWORK_TARGET) — this can take 10–60 min"
cd "$GHOSTTY_SRC"
run_zig_build

if [ ! -d "$BUILT" ]; then
    echo "ERROR: expected xcframework not found at $BUILT" >&2
    exit 1
fi

if ! symbols_ok; then
    # A pre-shim broken libtool output can be cached (zig's cache key does not
    # cover PATH shims). Clear the project cache and rebuild once.
    log "Cached archive is missing core symbols — clearing .zig-cache and rebuilding once"
    rm -rf "$GHOSTTY_SRC/.zig-cache" "$BUILT"
    run_zig_build
    if ! symbols_ok; then
        echo "ERROR: libghostty-fat.a is missing core ghostty symbols (ghostty_app_new)" >&2
        echo "       even after a clean rebuild. See the libtool shim comments above." >&2
        exit 1
    fi
fi
log "Symbol check passed (ghostty_app_new present)"

log "Installing artifact -> $OUT_XCFRAMEWORK"
rm -rf "$OUT_XCFRAMEWORK"
cp -R "$BUILT" "$OUT_XCFRAMEWORK"

log "Done. Slices:"
ls -1 "$OUT_XCFRAMEWORK"
