# Temple

A native macOS app that wraps CLI coding agents (**Claude Code**, **Codex**) and
presents their sessions as a chat-like, project-grouped index. Recent sessions
per project; click one to open a tab with a **real terminal** (libghostty) that
auto-resumes that session.

> Status: early scaffold. `TempleCore` reads real session data today; the UI and
> the libghostty terminal are in progress. See [docs/PLAN.md](docs/PLAN.md).

## Why / what / how

- **Product & feature spec:** [docs/FEATURES.md](docs/FEATURES.md)
- **Decisions & rationale:** [docs/DECISIONS.md](docs/DECISIONS.md)
- **Build plan (phased):** [docs/PLAN.md](docs/PLAN.md)
- **Session storage formats:** [docs/SESSION-FORMATS.md](docs/SESSION-FORMATS.md)

## Stack

- **Swift + AppKit/SwiftUI**, native, macOS-first (Linux later, not Windows).
- **libghostty** (Ghostty's engine, C API) as the embedded terminal.
- **No Rust, no webview** — see ADR-005 for why.
- Split into `TempleCore` (pure logic, no AppKit) + `TempleUI` (the app).

## Layout

```
Sources/
  TempleCore/     session index, stores, models — no AppKit
  Temple/         the SwiftUI/AppKit app (shell; terminal pane WIP)
  templectl/      CLI that prints the real project→session index
Tests/TempleCoreTests/
docs/             DECISIONS · PLAN · SESSION-FORMATS
```

## Quickstart

```sh
swift build

# Print your real projects + recent sessions from ~/.claude and ~/.codex:
swift run templectl

# Run the (early) app shell:
swift run temple
```

Requires Swift 6+ / Xcode 26+. Building the embedded terminal (Phase 0) will
additionally require the Zig toolchain + a libghostty build — see the plan.
