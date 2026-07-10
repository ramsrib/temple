# Temple — Build Plan

Phased so the one genuinely unknown risk (embedding libghostty) is proven
*before* we invest in polish, and so there's something runnable at every step.

Legend: ✅ done · 🔨 in progress · ⬜ todo

---

## Phase 0 — Prove the risk: libghostty in a Swift window ⬜
**Goal:** a throwaway spike — one libghostty surface in a bare `NSWindow` running
`claude` — that validates the render-ownership assumption (ADR-003) and the
C-interop. **Nothing else gets built until this works.**

- ⬜ Install Zig; clone Ghostty; build `libghostty` (static/dylib + `ghostty.h`).
- ⬜ Read Ghostty's `macos/Sources/Ghostty` to learn the surface lifecycle.
- ⬜ SwiftPM/Xcode C-interop target (`CGhostty`) wrapping `ghostty.h` + module map.
- ⬜ Host the Metal-backed surface as an `NSView` subview; pump input/resize.
- ⬜ Spawn `claude` in it; confirm rendering, keyboard, scrollback, resize.
- ⬜ **Decision gate:** if render-ownership holds → proceed. If libghostty turns
  out to need a mode we can't drive → revisit ADR-003 before continuing.

**Exit:** a window with a working, interactive Ghostty terminal running an agent.

---

## Phase 1 — TempleCore: the session index ✅ (v0)
**Goal:** read both agents' on-disk stores into a project→session model. No UI,
no terminal — pure logic, testable, runnable via `templectl`.

- ✅ Models: `Agent`, `AgentSession`, `Project`, `SessionIndex`.
- ✅ `ClaudeSessionStore` — scan `~/.claude/projects`, read `cwd` + first prompt.
- ✅ `CodexSessionStore` — scan `~/.codex/sessions`, `session_meta` + history titles.
- ✅ `templectl` CLI prints the grouped index from real data.
- ⬜ Live updates: `FSEvents`/`DispatchSource` watcher → incremental re-index.
- ⬜ Robustness: huge-file handling, malformed lines, permission errors.
- ⬜ Richer metadata: message count, model, git branch, last-message preview.

**Exit:** `templectl` lists your real projects and recent sessions. ✅

---

## Phase 2 — TempleUI: the chat-like shell ⬜
**Goal:** the Codex-desktop-style sidebar, driven by `TempleCore`. Terminal pane
still stubbed.

- 🔨 `NavigationSplitView`: projects (grouped) → recent sessions; search.
- ⬜ Detail: session header (agent, cwd, times) + placeholder terminal pane.
- ⬜ "New task" and per-agent affordances; pinned/recent sections.
- ⬜ Wire the live watcher from Phase 1 so the list updates as sessions change.
- ⬜ App bundle: migrate to an Xcode app target (entitlements, signing, Metal).

**Exit:** click a session → detail opens with the correct resume command shown.

---

## Phase 3 — Fuse them: tabs of live terminals ⬜
**Goal:** clicking a session opens a **tab** with a libghostty surface that
auto-resumes it. This is the product.

- ⬜ Tab model: N terminal surfaces, one per open session; lifecycle mgmt.
- ⬜ Launch path: `AgentSession.resumeCommand` → spawn in a new surface at `cwd`.
- ⬜ Reconcile a live terminal's session id back to the index (new sessions).
- ⬜ Reuse-or-open: clicking an already-open session focuses its tab.
- ⬜ State: closed tabs remembered; reopen restores.

**Exit:** click "raven / Analyze project setup" → tab opens, agent resumed, live.

---

## Phase 4 — Make it a real app ⬜
- ⬜ New-session flow (pick agent + project + branch → launch fresh).
- ⬜ Keyboard-first nav (⌘K palette, tab switching, quick-open).
- ⬜ Session actions: rename, pin, archive, delete, reveal file, copy id.
- ⬜ Preferences: agent binary paths, scan roots, theme, font.
- ⬜ Identity pass (ADR-001): icon, wordmark, the monk/acolyte motif or not.
- ⬜ Packaging: notarized `.dmg`, auto-update.

---

## Phase 5 — Linux (deferred) ⬜
Only when it's a real target. Decision from ADR-006: port `TempleCore` to Rust
behind an FFI, or run it as portable Swift; UI in GTK4 (gtk-rs likely). libghostty
embeds cleanly in GTK the same way it does in AppKit.

---

## Risks & unknowns
- **libghostty standalone embed is frontier** — Phase 0 exists to de-risk it.
- **libghostty build** needs Zig + tracking Ghostty's source; pin a version.
- **Resume flags / CLI drift** — verify `claude --resume` / `codex resume` per
  installed version; both CLIs evolve fast.
- **Session-id reconciliation** — a freshly launched agent mints its id at
  runtime; map the live terminal back to the file it creates.
- **Large session files** — read heads only for metadata (done in v0); never load
  whole multi-MB JSONL just for a title.
