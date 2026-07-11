# Building libghostty

Temple's terminal engine is Ghostty's renderer embedded via its C API
(`ghostty.h`), per ADR-003. This doc pins the toolchain and explains how the
embeddable artifact is produced and consumed.

## Pins (bump deliberately — drift is the #1 build breaker)

| Thing | Version | Source of truth |
|---|---|---|
| Ghostty | **v1.3.1** | `Scripts/build-ghostty.sh` (`GHOSTTY_TAG`) |
| Zig | **0.15.2** | `Scripts/build-ghostty.sh` (`ZIG_VERSION`); matches ghostty's `build.zig.zon` `minimum_zig_version` |

## One command, from a clean checkout

```sh
./Scripts/build-ghostty.sh
```

This is reproducible and self-provisioning. It:

1. Clones `ghostty-org/ghostty` at the pinned tag into `Vendor/ghostty`
   (git-ignored) if not already present.
2. Ensures the pinned Zig is available: uses `zig` on `PATH` if it already
   matches `0.15.2`, else `~/.local/zig-<ver>/zig`, downloading the tarball from
   ziglang.org into `~/.local/` if missing. No sudo, no Homebrew (brew's zig
   drifts).
3. Runs `zig build -Demit-xcframework` and copies the result to
   **`Vendor/GhosttyKit.xcframework`** — the same battle-tested artifact
   Ghostty's own macOS app consumes.

Output: `Vendor/GhosttyKit.xcframework` (a binary target in `Package.swift`) plus
ghostty's runtime resources under `Vendor/ghostty/zig-out/share/ghostty`.

### Slice target

`GHOSTTY_XCFRAMEWORK_TARGET` selects what slices are built:

- `universal` (**default**) — macOS x86_64+arm64 + iOS + iOS-sim. Portable;
  what Ghostty ships. Slow (~30–60 min cold).
- `native` — one macOS slice for the host arch. Much faster (~10–15 min);
  sufficient for local dev/CI on the same arch.

```sh
GHOSTTY_XCFRAMEWORK_TARGET=native ./Scripts/build-ghostty.sh
```

The artifact *shape* is identical either way, so nothing downstream changes.

## Toolchain gotchas on macOS 26 (Tahoe) / Xcode 26

Two things bite a clean build on current macOS; the script handles both
automatically. Documented here so the failure modes are recognizable.

1. **arm64e-only SDK.** The macOS 26 SDK's `libSystem.B.tbd` lists only
   `arm64e-macos` (and x86_64), not plain `arm64-macos`. Zig 0.15.2 compiles for
   `arm64`, filters the tbd for `arm64-macos`, finds nothing, and fails to link
   even its internal build runner (`undefined symbol: _clock_gettime`, `_fork`,
   …). Neither `SDKROOT` nor `zig build --sysroot` fixes the build-runner
   compile, because zig resolves the native SDK by running
   `xcrun --sdk macosx --show-sdk-path` — and `--sdk macosx` makes xcrun ignore
   `SDKROOT`. **Fix:** the script builds against a macOS 15.x SDK that still
   exposes `arm64-macos` (it auto-discovers one under CommandLineTools /
   Xcode; override with `GHOSTTY_SDKROOT`), routed in via a temporary `xcrun`
   PATH shim that answers `--show-sdk-path` with that SDK. This affects **build
   time only** — the resulting library still targets the normal deployment
   version. A macOS 15.x SDK must be present (ship with the Command Line Tools);
   if none is found the script errors with instructions.

2. **Metal Toolchain not installed.** Xcode 26 makes the Metal compiler an
   optional component, so compiling ghostty's shaders fails with
   `cannot execute tool 'metal' due to missing Metal Toolchain`. Install it once
   (no sudo):

   ```sh
   xcodebuild -downloadComponent MetalToolchain
   ```

3. **Xcode 26 `libtool` silently drops zig-written archive members.** Ghostty's
   build combines `libghostty.a` + all C deps into `libghostty-fat.a` with
   `libtool -static`. Xcode 26's libtool warns
   `64-bit mach-o member 'x.o' not 8-byte aligned` for members written by zig
   0.15's archive writer (2-byte alignment) — and then **omits them from the
   output while still exiting 0**. The dropped members include
   `libghostty_zcu.o`, i.e. every `ghostty_*` symbol: the build "succeeds" but
   the artifact is unlinkable. **Fix:** the script's `libtool` PATH shim
   re-packs each input archive with Apple `ar` (which writes correct alignment)
   before invoking the real libtool, and a post-build `nm` check asserts
   `ghostty_app_new` is present in the final archive (auto-clearing the zig
   cache and rebuilding once if a pre-shim broken output was cached).

## How SwiftPM consumes it

`Package.swift` declares:

```swift
.binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework")
```

The xcframework carries `ghostty.h` + `module.modulemap` (module `GhosttyKit`),
so Swift code does `import GhosttyKit`. `TempleTerminal` depends on `GhosttyKit`
+ `TempleTerminalAPI` and provides the production `GhosttyTerminalSurface`.

## Runtime resources (T7)

libghostty needs its runtime resources — **terminfo** (the `xterm-ghostty`
entry), **shell integration** scripts, **themes**, and compiled **Metal
shaders** are baked into the library — located via the `GHOSTTY_RESOURCES_DIR`
environment variable. The `zig build` step installs them to:

```
Vendor/ghostty/zig-out/share/ghostty/
```

Contents that the eventual `.app` bundle must carry (and that
`GHOSTTY_RESOURCES_DIR` must point at):

- `terminfo/` — the `xterm-ghostty` terminfo database. Without it, `TERM=xterm-ghostty`
  programs misbehave; ghostty also auto-installs it into `~/.terminfo` at runtime
  in some cases, but the bundle should carry it.
- `shell-integration/` — per-shell (bash/zsh/fish/elvish) integration scripts
  for prompt marking, cwd reporting (OSC 7), etc.
- `themes/` — bundled color themes referenced by config.

**Un-bundled (dev):** `terminal-demo` and the test suite set
`GHOSTTY_RESOURCES_DIR` to the checkout path above automatically, so they work
without an `.app` bundle.

**Bundled (later, integration phase):** the Xcode app target (U6) copies
`share/ghostty` into `Temple.app/Contents/Resources/ghostty` and sets
`GHOSTTY_RESOURCES_DIR` to that path at launch. Actual bundling is out of Track
T's scope; this section is the contract for whoever does U6/T7 integration.

## Rebuilding after a bump

1. Edit `GHOSTTY_TAG` / `ZIG_VERSION` in `Scripts/build-ghostty.sh` and the pin
   table above.
2. `rm -rf Vendor/ghostty Vendor/GhosttyKit.xcframework`
3. `./Scripts/build-ghostty.sh`
4. `swift build && swift test`
5. Re-check `ghostty.h` for C API changes against `Sources/TempleTerminal`.
