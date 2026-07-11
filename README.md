# Temple

A native macOS app that wraps CLI coding agents (**Claude Code**, **Codex**) and
presents their sessions as a chat-like, project-grouped index. Recent sessions
per project; click one to open a tab with a **real terminal** (libghostty) that
auto-resumes that session.

> Status: **v0.1 MVP** — live-updating sidebar, per-project terminal tabs with an
> embedded libghostty surface, new-session launcher (Claude/Codex + Choose
> folder…), graceful process lifecycle, notifications, ⌘K palette, Settings tab,
> System/Light/Dark theme, signed `.app`. See [docs/FEATURES.md](docs/FEATURES.md).

## Why / what / how

- **Product & feature spec:** [docs/FEATURES.md](docs/FEATURES.md)
- **UX & interaction spec:** [docs/UX.md](docs/UX.md)
- **Decisions & rationale:** [docs/DECISIONS.md](docs/DECISIONS.md)
- **Build plan (parallel tracks):** [docs/PLAN.md](docs/PLAN.md)
- **Session storage formats:** [docs/SESSION-FORMATS.md](docs/SESSION-FORMATS.md)
- **Building libghostty:** [docs/BUILDING-GHOSTTY.md](docs/BUILDING-GHOSTTY.md)

## Stack

- **Swift + AppKit/SwiftUI**, native, macOS-first (Linux later, not Windows).
- **libghostty** (Ghostty's engine, C API) as the embedded terminal — pinned
  ghostty v1.3.1 / zig 0.15.2, built by `Scripts/build-ghostty.sh`.
- **GRDB/SQLite** for app state (pins, tab restore, process registry); the
  filesystem session files remain the source of truth (ADR-009).
- **No Rust, no webview** — see ADR-005 for why.

## Layout

```
Sources/
  TempleCore/         session index, stores, watcher, search, filter, DB — no AppKit
  TempleTerminalAPI/  the TerminalSurface seam (protocol + stub)
  TempleTerminal/     libghostty runtime + GhosttyTerminalSurface
  TempleUI/           the app experience (sidebar, tabs, lifecycle, settings)
  Temple/             thin @main (SwiftPM dev run)
  templectl/          CLI: real project→session index (--watch/--search/--all)
  terminal-demo/      dev harness: one window, one ghostty surface
App/                  Xcode app-target entry (Info.plist, entitlements, icon)
Scripts/              build-ghostty.sh · build-app.sh · make-icon.sh
Tests/                TempleCoreTests · TempleUITests · TempleTerminalTests
docs/                 FEATURES · UX · DECISIONS · PLAN · SESSION-FORMATS · BUILDING-GHOSTTY
```

## Quickstart

```sh
# One-time: build the embedded terminal engine (pins zig + ghostty; 10–30 min)
./Scripts/build-ghostty.sh

swift build && swift test

# Print your real projects + recent sessions from ~/.claude and ~/.codex:
swift run templectl            # also: --watch, --search <q>, --all

# Run the app from the checkout:
swift run temple

# Build the signed Temple.app (xcodegen + xcodebuild; bundles ghostty resources):
./Scripts/build-app.sh         # → dist/Temple.app
```

Requires Swift 6+ / Xcode 26+ (plus `brew install xcodegen` for the app bundle).
Zig is self-provisioned by `build-ghostty.sh` at the pinned version.

## Debugging

Inspect recent Temple logs with `log show --last 1h --predicate 'subsystem BEGINSWITH "com.sriramb.temple"'`, or stream debug logs with `log stream --predicate 'subsystem BEGINSWITH "com.sriramb.temple"' --level debug`.
