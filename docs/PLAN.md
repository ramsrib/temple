# Temple — Build Plan

Structured as **three concurrent tracks** decoupled by one small interface
package, so the risky libghostty integration proceeds as real, committed work on
its own track while the rest of the app is built and tested in parallel against a
stub terminal surface.

> This supersedes the earlier serial plan (a throwaway "Phase 0" libghostty spike
> gating everything). The libghostty risk is still front-loaded — but as the
> first tasks of a production track, with the ADR-003 render-ownership check
> expressed as assertions + a kept dev harness, not a spike to discard.

Legend: ✅ done · 🔨 in progress · ⬜ todo · **S/M/L** = rough size.

---

## Current state (ground truth)

- `swift build` passes; `swift run templectl` works on real data (46 projects,
  2238 sessions).
- **TempleCore session index — done (v0):** models, `ClaudeSessionStore`,
  `CodexSessionStore`, grouping, first-human-prompt titles.
- **UI shell — partial:** `Sources/Temple/ContentView.swift` has a
  `NavigationSplitView` sidebar + a detail view with a *placeholder* terminal
  rectangle (`ContentView.swift:82`). `AppModel` is defined inline in
  `Sources/Temple/TempleApp.swift:19`.
- **Terminal engine — not started, not provisioned:** `zig` not installed,
  Ghostty source not cloned.
- Toolchain: Swift 6.3.3, Xcode 26.6, macOS (darwin 25.5). `claude`, `codex`
  installed. Resume flags verified current: `claude --resume <id>` /
  `--session-id <uuid>` / `-n/--name`; `codex resume [SESSION_ID] [PROMPT]`
  (matches ADR-008).

---

## Track breakdown

| Track | Charter | Independent because… |
|---|---|---|
| **T — Terminal Engine** | Build, link, and wrap libghostty as a production `TerminalSurface` implementation. | Everything sits *behind* the `TerminalSurface` protocol. Touches only new targets (`CGhostty`/`GhosttyKit`, `TempleTerminal`) plus one `Package.swift` append. Zero dependence on TempleCore. |
| **C — Core Data & Live Index** | Make `TempleCore` live and durable: FS watcher, search, noise filtering, richer metadata, GRDB session DB (ADR-009). | Pure `TempleCore` (no AppKit, ADR-006). Provable via `templectl` + unit tests; no UI or terminal needed. |
| **U — UI Shell & Session Lifecycle** | The full app experience minus the terminal pixels: sidebar per UX.md, per-project tab model, launch/lifecycle controller (ADR-010), new-session flow (ADR-008/012), notifications & attention (U7) — against a stub surface. | Consumes `TerminalSurface` (stub impl) + TempleCore's existing public API. Where it needs Track C outputs, the seam is a plain protocol/closure it defaults trivially until C lands. |

**T0/U0 — the interface package** is the only thing that precedes the tracks
(§ *The one serial dependency*). After it lands, all three tracks run fully in
parallel.

---

## The one serial dependency — T0 / U0 ⬜ **S**

The `TempleTerminalAPI` package + `AppModel` extraction. ~½ day; everything hangs
off it, so it is commit #1 (ideally authored by whoever runs Track U).

- ⬜ New `TempleTerminalAPI` target: `TerminalSurface` protocol, delegate,
  factory, `StubTerminalSurface` (see § *Decoupling interfaces*).
- ⬜ Extract `AppModel` from `TempleApp.swift:19` into
  `Sources/Temple/AppModel.swift`.
- ⬜ Detail pane hosts the stub surface where the placeholder `RoundedRectangle`
  (`ContentView.swift:82`) is today.

**Exit:** builds; app behaves identically; the stub renders the resume argv + cwd
in the detail pane. After this, libghostty gates *nothing* except the final
pixels — lifecycle, tabs, launch, reconciliation, watcher, DB, and search are all
built and tested against the stub/fake.

---

## Track T — Terminal Engine

### T1 — Provision the toolchain (real, checked-in) ⬜ **M**
- ⬜ Install Zig at the exact version Ghostty's `build.zig.zon` demands (pin it;
  zig drift is the #1 build breaker). Clone `ghostty-org/ghostty` pinned to a
  release tag; record tag + zig version in a new `docs/BUILDING-GHOSTTY.md`.
- ⬜ Check in `Scripts/build-ghostty.sh` that produces the embeddable artifact —
  Ghostty's own mac app consumes a `GhosttyKit.xcframework` built by zig; use
  that same battle-tested path, emitting into a git-ignored `Vendor/` dir.
- **Exit:** running the script from a clean clone yields the xcframework +
  `ghostty.h` reproducibly.

### T2 — `CGhostty` SwiftPM interop target ⬜ **M**
- ⬜ `Package.swift`: add a `.binaryTarget` for `GhosttyKit.xcframework` (or, if
  T1 emits a static lib + header, a C target with `module.modulemap` + linker
  settings — decide from what T1 actually produces).
- ⬜ Smoke-test target calling `ghostty_init()` + constructing an app/config
  handle.
- **Exit:** `swift build` links; the init call succeeds in a test.

### T3 — `TempleTerminal` runtime wrapper ⬜ **M**
- ⬜ Study `macos/Sources/Ghostty` in the ghostty repo (`Ghostty.App`,
  `SurfaceView` are the reference impl, MIT) **and [cmux](https://github.com/manaflow-ai/cmux)**
  (manaflow-ai, MIT) — a standalone Swift/AppKit app that already embeds
  libghostty as a library in almost exactly Temple's shape; it's the closest
  working reference for this task (see ADR-003 and the risk table). Write
  `Sources/TempleTerminal/GhosttyApp.swift`: one-per-process runtime init, config
  load, C-callback trampolines into Swift.
- **Exit:** runtime initializes and shuts down cleanly under a unit test.

### T4 — `GhosttySurfaceView: NSView` + render-ownership validation ⬜ **L**
- ⬜ Host the Metal-backed surface as an NSView subview; plumb keyboard, mouse,
  resize, focus, scrollback.
- ⬜ **ADR-003 validation lives here as production assertions**: precondition that
  libghostty hands us a drawable native surface (log/fail loudly if the API
  forces a mode we can't drive). Keep a small, permanent `terminal-demo` dev
  executable target (like `templectl` is for TempleCore) that opens one window
  with one surface running `$SHELL`.
- **Exit:** interactive shell in the demo window — typing, resize, scrollback all
  work. If this fails structurally → decision gate: revisit ADR-003 (see *Risks*).

### T5 — Process spawn + exit wiring ⬜ **M**
- ⬜ Surface config carries `argv` + `cwd` (libghostty owns the PTY); wire the
  child-exit callback out.
- **Exit:** demo runs `claude --resume <real-id>` in the right cwd, interactively.

### T6 — `GhosttyTerminalSurface: TerminalSurface` conformance ⬜ **M**
- ⬜ Adapt T4/T5 to the protocol, including `requestGracefulExit()` /
  `terminate()` semantics (signal via libghostty's process control or the child
  pid) and delegate events (exit, title).
- **Exit — the fuse milestone:** swapping the factory in `TempleApp.swift` from
  stub → ghostty makes Track U's tab UI live.

### T7 — Resources & packaging ⬜ **M**
- ⬜ Bundle ghostty's runtime resources (terminfo, shaders, themes) into the app
  bundle; set `GHOSTTY_RESOURCES_DIR`. Coordinates with U6 (Xcode target).
- **Exit:** the built `.app` runs on a machine without a ghostty checkout.

---

## Track C — Core Data & Live Index

### C1 — `SessionWatcher` (live updates) ⬜ **L**
- ⬜ New `Sources/TempleCore/SessionWatcher.swift`: FSEvents (or `DispatchSource`)
  on `~/.claude/projects`, `~/.codex/sessions`, `~/.codex/history.jsonl`;
  debounced; re-parses *only* changed files; emits an `AsyncStream<SessionIndex>`
  (or delta events).
- ⬜ Add `templectl --watch` as the proof harness.
- **Exit:** start `templectl --watch`, run a `claude` prompt elsewhere, see the
  index update within ~1s.

### C2 — Noise filtering ⬜ **S/M**
- ⬜ `SessionFilter` in TempleCore: classify ambient/automation sessions (the
  1,864 `cwd:/` Codex runs; `session_meta.payload.originator` distinguishes
  `codex-tui` vs exec-style; nonexistent cwds). Pure function + fixture tests.
- **Exit:** default `templectl` drops the noise; `--all` shows it.

### C3 — Search ⬜ **S**
- ⬜ `SessionIndex.search(_:)`: ranked match over title / project name / agent.
  Unit tests.
- **Exit:** `templectl --search "foo"` returns sensible ranked hits.

### C4 — Richer metadata ⬜ **M**
- ⬜ Extend both stores: message count, model, last-message preview (tail-read,
  bounded like `StoreIO.readHead`), git branch (from claude's per-line
  `gitBranch` field if present; else skip). Extend `AgentSession` additively.
- **Exit:** fields populated on real data via `templectl`; fixture tests cover it.

### C5 — `TempleDB` (GRDB, ADR-009) ⬜ **M**
- ⬜ Add GRDB dependency (coordinate the `Package.swift` merge). Schema v1:
  `session_state` (id PK = CLI id, pinned, archived, custom_name, last_opened_at),
  `open_tabs` (restore order), `process_registry` (pid, session_id, started_at —
  for ADR-010 crash recovery). Rebuildable-cache semantics: never contradicts
  disk.
- **Exit:** round-trip unit tests; DB file at
  `~/Library/Application Support/Temple/`.

### C6 — Robustness pass ⬜ **S/M**
- ⬜ Malformed JSONL lines, permission errors, huge files, empty stores — fixture
  tests; never crash, always degrade to a partial index.
- **Exit:** fixture suite green; `templectl` exits 0 on adversarial fixture dirs.

---

## Track U — UI Shell & Session Lifecycle

*(U0 = T0, the serial item above — do it first.)*

### U1 — Sidebar per UX.md ⬜ **M**
- ⬜ Search field (⌘F focus, **title-only** filter per UX), agent badges (Claude ◆
  / Codex ◇ — upgrade the colored `Circle()` in `SessionRow`), project disclosure
  groups with per-project "Show more", relative timestamps, noise-filter toggle.
  Wire search/filter to C3/C2 when they land; until then a local
  `title.localizedCaseInsensitiveContains` predicate keeps U1 unblocked (one-line
  swap later).
- ⬜ **Select ≠ open:** arrow keys move a highlight only; **Enter / double-click**
  opens (spawns). The sidebar highlight **follows the active tab**. Right-click
  context menu (copy resume cmd / id, reveal in Finder, rename, pin, close).
- **Exit:** matches the UX.md wireframe; filtering/search work on real data;
  arrowing the list spawns nothing.

### U2 — Tab model + reuse-or-focus ⬜ **M**
- ⬜ `OpenSessionsModel` (ObservableObject): ordered open tabs, each owning a
  `TerminalSurface` from the injected factory; clicking an open session focuses,
  never duplicates. Tabs carry their `projectPath`; an `activeProjectPath`
  (derived from the active tab) drives a **per-project horizontal tab bar** in the
  content header — it renders only the active project's open terminals (Codex
  sidebar + cmux-style per-project tabs; see UX.md).
- ⬜ `+` opens a **New Claude / New Codex** menu (active project); **⌘T** = new
  empty session with the **default agent**; **⌘W** = close current tab; **⌘1–9** /
  **⌃⇥** switch tabs; drag-reorder persists to C5's `open_tabs`.
- ⬜ **Lazy restore:** on launch, rebuild the per-project tab set + order from
  `open_tabs` as **inert chips** — a `TerminalSurface` is created only on click
  (no process storm).
- **Exit:** with the stub factory, multiple tabs across ≥2 projects open/focus/
  close correctly; the tab bar shows only the active project's tabs and swaps when
  a session in another project is opened/focused; ⌘T/⌘W/⌘1–9 work; restored chips
  stay inert until clicked; each stub shows its session's resume argv + cwd.

### U3 — `SessionRuntimeController` (ADR-010 lifecycle) ⬜ **M**
- ⬜ Written *against the protocol*: close-tab → `requestGracefulExit()` → bounded
  wait → `terminate()`; app-quit path drains all runtimes via
  `NSApplicationDelegate` termination delay; registers pids in C5's
  `process_registry` (until C5 lands, an in-memory registry behind the same tiny
  protocol).
- **Exit:** unit-tested with a `FakeTerminalSurface` scripting exit timing
  (graceful, slow, hung).

### U4 — New-session flow (ADR-008 · ADR-012) ⬜ **M/L**
- ⬜ Empty-state launcher (project chip + agent selector, per UX.md — MVP-lean
  spawn-terminal variant). The project picker includes a **"Choose folder…"**
  (NSOpenPanel) option so a *new*, un-indexed directory can be targeted — **agent +
  directory only, no branch/worktree** (ADR-012). ⌘T / `+` / empty-tab default to
  the configured **default agent** (Claude). Claude path: mint UUID →
  `claude --session-id <uuid> [-n name]`, id known immediately. Codex path:
  launch `codex [prompt]`, then `CodexReconciler` (in TempleCore — pure logic:
  match new rollout file by `cwd` + creation-time window, adopt
  `payload.session_id`); unit-test the matcher against fixtures without running
  codex.
- **Exit:** stub-mode — new session (including one started via Choose folder…)
  appears in sidebar with the correct adopted id after the CLI writes its file;
  ghostty-mode after the fuse — fully in-app.

### U5 — Watcher + DB wiring ⬜ **S**
- ⬜ `AppModel` consumes C1's `AsyncStream` (interim: a 5s poll timer, three
  lines, deleted on merge) and overlays C5 state (pins, custom names) onto the
  index for display.
- **Exit:** sidebar updates live while an agent runs; pins survive restart.

### U6 — Xcode app-target migration ⬜ **M**
- ⬜ Real `.app`: Xcode target (or xcodegen) wrapping the package — Info.plist,
  entitlements, signing, hidden-titlebar/vibrancy chrome that SwiftPM
  `swift run` can't fully deliver. Do this *mid-track* (after T2 exists, so the
  CGhostty linking model is known; before T7, which needs a bundle for
  resources).
- **Exit:** `Temple.app` builds, signs, launches from Finder.

### U7 — Notifications & attention state ⬜ **M**
- ⬜ Consume the `TerminalSurface` delegate **bell** (`surfaceDidRing`) +
  **desktop-notification** (`didPostNotification`, OSC 9/777) callbacks and
  **process-exit**; derive a per-session activity state (running / idle /
  needs-attention). Render an activity dot on the tab chip + sidebar row; raise a
  native **`UNUserNotification`** ("project · session" + message) whose click
  **focuses that tab** (via `OpenSessionsModel` + active-project switch).
- ⬜ Depends on Track T wiring libghostty's bell/OSC-notification callbacks into
  the two new delegate methods; until then drive it from `FakeTerminalSurface`
  firing scripted bell/notification/exit events.
- **Exit:** stub/fake-mode — a scripted attention event lights the dot and posts a
  notification; clicking it focuses the right tab. Real bell/OSC after the fuse.

### U8 — ⌘K command palette ⬜ **S** *(v1)*
- ⬜ Global quick-open over the full index (title match, reuses C3's ranker);
  selecting a result opens/focuses that session's tab (switching active project).
- **Exit:** ⌘K → type → Enter jumps to the session's tab.

---

## Decoupling interfaces

New target `TempleTerminalAPI` (imports AppKit — it can't live in TempleCore per
ADR-006; it stays free of both ghostty and TempleCore):

```swift
public struct TerminalCommand: Sendable {
    public var argv: [String]          // e.g. AgentSession.resume.argv
    public var cwd: String             // AgentSession.resume.cwd
    public var env: [String: String]
}

public enum TerminalProcessState: Sendable, Equatable {
    case notStarted
    case running(pid: pid_t)
    case exited(status: Int32)
}

@MainActor
public protocol TerminalSurface: AnyObject {
    var view: NSView { get }                       // the render-owning subview (ADR-003)
    var delegate: TerminalSurfaceDelegate? { get set }
    var processState: TerminalProcessState { get }

    func start(_ command: TerminalCommand) throws  // spawn in the surface's PTY
    func focus()
    func requestGracefulExit()                     // polite: exit sequence / SIGTERM
    func terminate()                               // escalation: SIGKILL + reap
}

@MainActor
public protocol TerminalSurfaceDelegate: AnyObject {
    func surface(_ surface: TerminalSurface, didChangeState state: TerminalProcessState)
    func surface(_ surface: TerminalSurface, didUpdateTitle title: String)

    // Attention signals → activity dots + native notifications (UX "Notifications").
    func surfaceDidRing(_ surface: TerminalSurface)                                    // terminal bell
    func surface(_ surface: TerminalSurface, didPostNotification title: String, body: String)  // OSC 9 / OSC 777
}

@MainActor
public protocol TerminalSurfaceFactory {
    func makeSurface() -> TerminalSurface
}
```

Three implementations:

- **`StubTerminalSurface`** (in `TempleTerminalAPI`): an NSView rendering the
  command + a scripted/manual state machine — what the current placeholder
  rectangle becomes.
- **`FakeTerminalSurface`** (test-only): scriptable exit timing for U3's
  lifecycle tests, and scriptable bell / notification / exit events for U7.
- **`GhosttyTerminalSurface`** (Track T, in `TempleTerminal`).

`TempleApp` picks the factory at startup — **the fuse is one line.**

Secondary seams (keep Track U unblocked by Track C): search/filter as plain
functions with trivial local defaults; process-registry persistence behind a
two-method protocol until C5's GRDB store implements it.

---

## Sequencing & merge notes

- **`Package.swift` is the contended file.** Merge order: T0 (adds
  `TempleTerminalAPI`) → then T2 (CGhostty/GhosttyKit) and C5 (GRDB) append
  independently. Small, additive diffs; trivial conflicts.
- **Fuse milestone (≈ old Phase 3):** T6 done + U2/U3 done → swap factory → click
  "raven / Analyze project setup" → live resumed terminal in a tab. U4's Codex
  reconcile then gets its in-app end-to-end run.
- **ADR-008 reconciliation convergence:** three components meet here — U4's
  `CodexReconciler` (matcher), C1's `SessionWatcher` (detects the new rollout
  file), U2's tab model (rebinds the tab's provisional session to the adopted
  id). Make the rebind an explicit `OpenSessionsModel.adopt(sessionID:for:)` so
  the seam is visible.
- **Xcode migration (U6):** after T2, before T7 — the binaryTarget/link model must
  be known before creating the app target; resources bundling needs the app
  target to exist.
- **Titles for launched sessions:** pass `-n/--name` for claude at launch
  (ADR-011 option) — decide during U4, it's free.

---

## Risks & fallbacks

| Risk | Track | Fallback |
|---|---|---|
| libghostty standalone embed is frontier; C-API churn or an undriveable surface mode (ADR-003 breaks) | T | Lower than it looks — [cmux](https://github.com/manaflow-ai/cmux) and [muxy](https://github.com/muxy-app/muxy) are working standalone Swift embeds to crib from (ADR-003). Still, the protocol is the insurance: slot **SwiftTerm** in as an interim `TerminalSurface` impl (pure Swift, proven embeddable) so the product ships while ADR-003 is revisited; or vendor ghostty's own `macos/Sources/Ghostty` Swift wrapper wholesale (MIT). |
| Zig/ghostty version drift breaks the build | T | Pin both in T1's script + doc; upgrade deliberately, never implicitly. |
| Ghostty runtime resources missing outside a bundle | T | T7 exists for this; until then the demo sets `GHOSTTY_RESOURCES_DIR` to the checkout. |
| FSEvents storms from multi-MB JSONL appends | C | Debounce + head-only re-parse (already the store pattern); coalesce per-file. |
| `codex` reconcile mismatches (two sessions started near-simultaneously in one cwd) | U | Narrow match window + retry; worst case the tab shows "unlinked" until the watcher's next pass — never adopt ambiguously. |
| CLI flag drift (`--session-id`, `codex resume`) | U | Verified against installed versions today; add a launch-time `--help`/version sniff before spawn; keep `Agent.resumeArgv` the single choke point. |
| SwiftPM `swift run` can't express entitlements/signing | U | That's U6; nothing before it needs a signed bundle. |

---

## Deferred — Linux (post-1.0)

Only when it's a real target. Per ADR-006: port `TempleCore` to Rust behind an
FFI, or run it as portable Swift; UI in GTK4 (gtk-rs likely). libghostty embeds
into GTK the same way it does into AppKit.
