# Temple — Architecture Decision Records

Short, dated records of the choices that shape the project and *why*. Append new
ADRs; supersede rather than delete.

---

## ADR-001 — Name: **Temple**
**Date:** 2026-07-10 · **Status:** Accepted

A place you enter to do focused work — a home your agent sessions live in.
One word, weighty, memorable; reads clean as a verb-of-place ("it's in my
Temple"). Bonus meaning: *temple* = the side of the head, by the mind — a place
for thinking. Only dev-world echo is TempleOS (unrelated); no meaningful
collision.

Identity direction still open: sleek-minimal vs. a light "monks/acolytes do the
work" motif. Deferred — does not block engineering.

---

## ADR-002 — What Temple is
**Date:** 2026-07-10 · **Status:** Accepted

A native desktop app that wraps CLI coding agents (**Claude Code**, **Codex**)
and presents their sessions as a **chat-like, project-grouped index** — recent
sessions per project, click to open a tab with a **real terminal** that
auto-resumes that session. Think "Codex desktop / ChatGPT sidebar" as the shell,
a true terminal as the working surface.

---

## ADR-003 — Terminal engine: **libghostty** (hard requirement)
**Date:** 2026-07-10 · **Status:** Accepted

The terminal surface is Ghostty's engine embedded via its C API (`ghostty.h`).

**Consequence that drives everything else:** libghostty is not just a VT parser —
it is a **GPU renderer that owns a native OS surface** (Metal-backed `NSView` on
macOS; a GTK GL widget on Linux). The host *hosts that native surface as a
subview*. This is why the stack must be a native per-widget toolkit, not a
single-surface GPU framework or a webview.

> ⚠️ Assumption to validate in the Phase 0 spike: that libghostty is
> render-owning and exposes no "headless, you-draw-the-cells" mode. The whole
> architecture rests on this — confirm against Ghostty's source first.

libghostty is Zig; building it needs the Zig toolchain + Ghostty source. It is
frontier as a *standalone* embed, but no longer unproven — see the reference
implementations below.

**Update 2026-07-10 — standalone Swift embeds exist; risk materially lower.**
Beyond Ghostty's own macOS/Linux apps, third-party apps already embed libghostty
in a standalone Swift/AppKit host — closely validating this ADR's central
assumption *and* Temple's overall shape:

- **[cmux](https://github.com/manaflow-ai/cmux)** (manaflow-ai, MIT) — a native
  macOS Swift/AppKit terminal that uses **libghostty as a library (not a fork)**,
  with vertical tabs purpose-built for AI coding agents (git branch, PR status,
  cwd, ports, notifications per workspace) and a `cmux notify` CLI wired into
  agent hooks. This is essentially Temple's architecture and near-adjacent
  product — the single most relevant reference for Track T, and notable prior art
  worth studying for what it does and doesn't solve (see ADR-002).
- **[muxy](https://github.com/muxy-app/muxy)** — a lightweight **SwiftUI +
  libghostty** terminal; a second standalone-embed reference.
- **[awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty)** — curated
  list of libghostty embedding projects and API notes.

Consequence: the "frontier standalone embed" risk in PLAN.md drops from *unknown*
to *demonstrated* — cmux/muxy are working proofs and readable source, alongside
Ghostty's own app.

---

## ADR-004 — Platforms: **macOS first; Linux later; not Windows**
**Date:** 2026-07-10 · **Status:** Accepted

Ghostty targets macOS + Linux only. A hard libghostty requirement therefore caps
us at **mac + Linux** — Windows is out of scope until Ghostty supports it (if
Windows ever becomes a must, *that* requirement collides with libghostty and one
has to give). We ship macOS first and treat Linux as a deferred second target.

---

## ADR-005 — Stack: **Swift + AppKit/SwiftUI, native** (no Rust, no webview)
**Date:** 2026-07-10 · **Status:** Accepted

Ranked by how cleanly each hosts libghostty's render-owning native surface:

| Option | libghostty embed | Verdict |
|---|---|---|
| **AppKit (Swift)** | add its `NSView` as a subview — trivial, = Ghostty's mac app | ✅ **chosen** |
| GTK (Linux, later) | add its widget to the tree — trivial, = Ghostty's Linux app | ✅ later |
| Webview (Tauri) | float a native view under a "hole" in the page | ❌ awkward |
| Single-surface Rust GPU UI (GPUI/iced/egui) | inject a foreign `NSView` over a wgpu window — fights the framework | ❌ hardest |

Swift/AppKit is the proven, lowest-risk path and gives the best native feel and
the Codex-desktop aesthetic we want.

**Why no Rust:** for a native Swift mac app, Rust earns its place *only* to share
non-visual logic with a **non-Swift (gtk-rs) Linux frontend** — a soft "someday."
The core here is light glue (watch dirs, parse JSONL, spawn processes, hold a
model); Swift does all of it natively with no hot path Rust would improve. An FFI
boundary now would tax mac iteration while the design is fluid. So: **no Rust
today.** See ADR-006 for how we keep the door open cheaply.

---

## ADR-006 — Internal layering: `TempleCore` (no AppKit) + `TempleUI`
**Date:** 2026-07-10 · **Status:** Accepted

Split the app into a **`TempleCore`** module — session index, file watching,
process spawning, data models, *zero* AppKit/SwiftUI imports — and the UI on top.
Costs nothing now, and makes any future Linux job well-bounded: either port
`TempleCore` to Rust behind an FFI, or run it as portable Swift under a GTK
shell. Decide *then*, with real information.

---

## ADR-007 — Session index is built from the CLIs' on-disk stores
**Date:** 2026-07-10 · **Status:** Accepted

The sidebar (projects → recent sessions) is driven by **reading the agents' own
session files**, not by scraping terminal scrollback. This decouples the nice UI
from any terminal-parsing fragility and is most of the app's value.

- **Claude Code** → `~/.claude/projects/<encoded-cwd>/<uuid>.jsonl`. One file per
  session; filename stem = session id; the *true* `cwd` is a field inside the
  file (the dir-name encoding is lossy — collides on paths with `-`/spaces —
  so we read `cwd` from the contents). Resume: `claude --resume <id>`.
- **Codex** → `~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl`. First
  line is `type: session_meta` with `payload.session_id` + `payload.cwd`.
  `~/.codex/history.jsonl` lines `{session_id, ts, text}` give the first prompt
  (used as the session title). Resume: `codex resume <id>`.

"Resume" = spawn the agent's resume command in a new libghostty surface, with the
surface's working directory set to the session's `cwd`.

> ⚠️ Verify exact resume flags against installed CLI versions before wiring the
> launch path (`claude --resume` and `codex resume` are current best-known).

Full reverse-engineered schemas: [SESSION-FORMATS.md](./SESSION-FORMATS.md).

---

## ADR-008 — Session identity: id == CLI id; asymmetric minting
**Date:** 2026-07-10 · **Status:** Accepted

Temple's session id **is** the underlying CLI's session id (UUID), and each
session records its **type** (`claude` | `codex`). This keeps Temple's records
1:1 with the CLIs' own session files — no separate id space to reconcile.

Minting a *new* session's id differs by agent (verified against installed CLIs):

- **Claude Code — inject.** `claude --session-id <uuid>` accepts a caller-chosen
  id. Temple generates the UUID, passes it in, and **knows the id immediately**.
  (Also available: `-r/--resume <id>`, `-n/--name <name>`, `--fork-session`.)
- **Codex — reconcile.** Bare `codex` mints its own id (no injection flag). For a
  new Codex session Temple launches `codex [prompt]` then **watches
  `~/.codex/sessions` for the newly created rollout file** (match by `cwd` +
  creation time) and **adopts** its `payload.session_id`. Resume is direct:
  `codex resume <id> [prompt]`.

Consequence: the launch layer needs a small **reconciliation watcher** for the
Codex new-session case; everything else is deterministic.

---

## ADR-009 — Persistence: session DB for app state; filesystem is source of truth
**Date:** 2026-07-10 · **Status:** Accepted

Two stores with clear ownership:

- **Filesystem session files** (`~/.claude/projects/**`, `~/.codex/sessions/**`)
  are the **source of truth** for session existence, content, `cwd`, and titles.
  Temple never writes them.
- **Temple's own session DB** (local, SQLite via GRDB.swift is the intended
  choice) holds **app state the CLIs don't track**: pinned/archived flags, custom
  name/order, tab-restore state, last-opened, and a fast cached index. Keyed by
  the CLI session id (ADR-008).

A **filesystem watcher** (FSEvents/`DispatchSource`) keeps the DB/index in sync as
session files appear/change. The DB is a cache + app-state layer, never the
authority — it can be rebuilt from disk at any time.

> v0 note: `TempleCore` currently derives everything directly from disk with no
> DB. The DB lands when we add pins/tab-restore/process-registry (Phase 2–3).

---

## ADR-010 — Temple owns the agent processes; graceful lifecycle
**Date:** 2026-07-10 · **Status:** Accepted

Temple maintains the set of **running agent processes** (each a CLI in a
libghostty PTY surface) and is responsible for their clean lifecycle:

- **A tab *is* its agent process** (1:1, both directions). The terminal never
  hosts a bare shell — it always runs a claude/codex process directly, so there is
  no "detached process" state (an agent is always attached to a tab; a live tab
  always has an agent).
- **Close a tab** → gracefully end that session: signal the CLI to exit (flush its
  session file), `SIGTERM`, wait, force-kill only past a timeout, then reap. The
  session remains in the sidebar (it lives on disk) — closing a tab ends the
  *process*, not the *session*.
- **Process exits on its own** (user quits the agent — Ctrl+C, `/exit`; it
  finishes; or it crashes) → Temple detects the child exit and **auto-closes the
  tab.** Ctrl+D (EOF) is passed through to the agent unmodified — Temple never
  interprets it as detach/background. The session stays in the sidebar.
- **Quit the app** → shut down **all** live processes the same way before exiting;
  never orphan an agent, never quit mid-write (avoids corrupting session files).
- A **process registry** (in the DB, ADR-009) tracks live pids/sessions so a
  crash-restart can detect and adopt or clean up stragglers.

---

## ADR-011 — Title source: first human prompt (CLI summaries unreliable)
**Date:** 2026-07-10 · **Status:** Accepted

Ideal is the CLI-generated session title, but empirically Claude Code sessions do
**not** reliably carry a `summary`/title line in-file (0/40 recent sessions
sampled). So the working rule:

1. Use a CLI-generated **summary** if present (prefer it).
2. Else the **first human prompt** (skipping synthetic wrappers — slash-command
   echoes, `<local-command-caveat>`, `<bash-input>`; see
   `ClaudeSessionStore.isLikelyHumanPrompt`). *(implemented)*
3. Allow a **user rename**, stored in Temple's DB (ADR-009).

Optionally, Temple may set a name at launch (`claude --name` / Codex session
names) to influence the CLI's own display.

---

## ADR-012 — Scope boundary: agent **sessions** only — not git, not the filesystem
**Date:** 2026-07-10 · **Status:** Accepted

Temple manages **terminal agent sessions** and nothing else. It does **not** run
git (no branch / checkout / worktree creation), does **not** create or edit files,
and does **not** manage repositories. A "project" is simply a **working directory**
an agent runs in; a "session" is an agent **process** in that directory.

Consequence: the new-session flow picks an **agent** + a **directory** (an existing
indexed project, or a "Choose folder…" pick) — never a branch or worktree. Any
git/worktree workflow a user wants is the *agent's* job inside its terminal, not
Temple's. This keeps Temple a thin, safe session manager with no destructive
filesystem/git surface area, and is revisited only if a concrete need appears.

---

## ADR-013 — v0.1 UX revisions from live use
**Date:** 2026-07-10 · **Status:** Accepted

Live use of v0.1 supersedes several speculative interaction choices in the
original UX spec. The shipped app favors stable spatial memory, project-scoped
actions, native window behavior, and visible failure over extra creation chrome.

- **Launcher-as-home** replaces the modal new-session composer. The empty-state
  launcher is the only general new-session UI; there is no separate sheet,
  dialog, or prompt composer. It launches empty agent terminals in a project or
  chosen directory *(ADR-008, ADR-012)*.
- A per-project **`+` menu** replaces the global “+ New session” primary action.
  Creation is scoped to each project header (plus the launcher's action rows,
  the tab-bar `+`, and `⌘T` for the default-agent fast path).
- Project and session order is frozen by recency at launch. New discoveries
  prepend, but existing rows never live-resort under the user *(ADR-009)*.
- The tab bar lives in the native unified title-bar toolbar band,
  ChatGPT/Codex-desktop-style, rather than in a separate strip below a custom
  frameless titlebar.
- **`⌘B` toggles the sidebar**, superseding the earlier `⌘\` choice in UX.md.
- Closing a busy tab asks for native confirmation before interrupting its agent.
  A non-user-initiated exit within roughly five seconds of spawn remains visible
  with a red exited dot so launch failures cannot flash away *(extends ADR-010)*.
- Per-agent arguments apply to every new and resumed launch. Defaults deliberately
  bypass permission/sandbox gates — `--dangerously-skip-permissions` for Claude
  and `--dangerously-bypass-approvals-and-sandbox` for Codex — accepting that risk
  for this local single-user app; either value is overridable or clearable in
  Settings *(ADR-008)*.
- The v0.1 app identity is settled as **`com.sriramb.temple`**, for both the
  bundle identifier and the `os.Logger` subsystem prefix. The app adopts the
  login-shell `PATH`, raises `RLIMIT_NOFILE`, caches the session index, and
  retries files observed mid-write so sessions appear promptly. Its embedded
  terminal uses a Temple-owned Adwaita/Adwaita Dark config and never reads the
  user's Ghostty config.
- Distribution is a deliberately monochrome/no-blue, Developer-ID signed app;
  `make install` provides the local installation path. Notarized `.dmg`
  packaging remains later.

---

## ADR-014 — Docs consolidation for the public repo
**Date:** 2026-07-10 · **Status:** Accepted

FEATURES.md is now the single product document: what Temple is, its shipped
behavior, and its roadmap. UX.md and PLAN.md are retired, with their live content
absorbed into FEATURES.md; DECISIONS.md remains the append-only “why” record,
while SESSION-FORMATS.md and BUILDING-GHOSTTY.md remain technical references.
Historical references to UX.md and PLAN.md in older ADRs remain intact as history.

---

## ADR-015 — The window is the app: closing it quits, and a relaunch returns to the active tab
**Date:** 2026-08-24 · **Status:** Accepted

Temple is a single-window, document-less app, so the window's lifetime *is* the
app's. Closing it now quits through the normal `applicationShouldTerminate` path
*(ADR-010)* rather than leaving a windowless process behind.

Keeping the process alive was not the safe option it appeared to be. The agents
kept running with no way to see or reach them, and the moment a new window was
created SwiftUI rebuilt `RootView` — which recreates the terminal surface views
and drops the old ones, killing every attached agent within seconds and skipping
the graceful drain entirely. Measured: alive 60s after the window was shut, gone
5s after reopening it. The alternative fix (make the surfaces survive window
re-creation, plus an `applicationShouldHandleReopen`) is strictly more machinery
in service of a state — an invisible app holding live agents — that we do not
want to offer.

Because the close button is one stray click, quitting now **asks** when any agent
is mid-task, and cancels cleanly without freezing the tab set. Idle sessions
never prompt: they resume from disk with nothing lost. This applies to `⌘Q` too,
so both routes out of the app behave identically *(extends ADR-010, and the
busy-tab confirmation in ADR-013)*.

**The question must be asked before the window closes, from `windowShouldClose`.**
v0.1.13 shipped it in `applicationShouldTerminate`, which AppKit only reaches once
the window is already destroyed: the prompt appeared over nothing, Cancel had no
window to return to, and SwiftUI — its `WindowGroup` now empty — tore the scene
down and exited regardless of `.terminateCancel`. Cancel lost exactly the work it
offered to protect. Nor may the close handler answer by starting a termination and
letting *that* ask: `NSApp.terminate()` re-enters the close callback, and one click
produced two prompts. The close handler decides in place, and a close it approved
marks the quit as already-confirmed so the drain does not re-ask. Deciding there
means displacing SwiftUI's window delegate, so Temple interposes a forwarding
proxy that answers this one selector and passes everything else through,
reinstalled whenever the window becomes main or key, swept once at launch for a
window that became main before the observers existed, and dropped when the window
closes.

Two traps found by review, both real. The prompt must not be gated on a window
being *visible*: `isVisible` and `canBecomeMain` are false for a minimized or
⌘H-hidden window, so that test skipped the warning for an app the user could
restore perfectly well, and killed the agent in silence. The gate is the window's
lifetime instead — it exists until it posts `willClose`. And the "already asked"
approval is scoped to the window that was closing and expires on the next run-loop
turn; a global flag would be banked by a close that never terminated and spent
later by an unrelated ⌘Q.

Restore is the other half of making an accidental quit cheap. Lazy restore
*(ADR-009)* rebuilt the chips but left no tab active, so every relaunch landed on
the launcher and read as "Temple lost my session". The persisted tab set now
records **which** tab was active (`open_tabs.active`), and restore reactivates
exactly that one — resuming a single agent, not the whole set. Quitting from the
launcher (`⌘⇧H`) still returns to the launcher: an empty active tab is a
deliberate choice by the user, not missing state to be filled in.

---

## ADR-016 — Find in the terminal is libghostty's search; Temple draws the bar
**Date:** 2026-09-02 · **Status:** Accepted

`⌘F` finds text in the active terminal. Matching, highlighting and scrolling to
a match are libghostty's own search (1.3+), driven through its binding actions
(`search:<needle>`, `navigate_search:next|previous`, `end_search`) and reported
back through the `start_search` / `end_search` / `search_total` /
`search_selected` actions. Temple contributes only the bar over the terminal's
top-right corner and the per-tab state behind it. Reimplementing search over
the scrollback in Temple was never on the table: the terminal already has an
indexed, thread-off-main search that tracks content as it scrolls, and a second
one could only disagree with it.

Consequences and choices:

- **The bar is a view of `TerminalFindModel`, which lives on the `SessionTab`,
  not in the view.** `MainContentView` rebuilds the terminal view on every tab
  switch (`.id(tab.id)`), so view-owned state would close the search each time.
  The bar claims the keyboard only when the model was asked to open (a focus
  request consumed once), never on a plain rebuild — returning to a tab with a
  search open leaves the keyboard with the terminal.
- **The surface API stays optional.** `TerminalSurface` gained `search`,
  `navigateSearch`, `endSearch` and four delegate callbacks, all with default
  no-ops, so the stub and test doubles need nothing and the UI shows no count
  for a surface that cannot search.
- **`⌘F` moved off the sidebar.** Focusing sidebar search was the only thing
  the key did before; the sidebar field is now click-only and has no shortcut.
  `⌘F` with no terminal on screen does nothing (the Edit menu item is disabled).
- **Keys stay with `KeyCatcher`.** `⌘F`, `⌘G`, `⌘⇧G` are handled by Temple's
  event monitor so they work from the field and from the terminal alike; the
  Edit menu's system Find submenu is replaced by items that mirror them, per the
  menu-mirrors-KeyCatcher rule (the placement covers the whole text-editing
  group — Spelling, Substitutions, Transformations, Speech go too; none applies
  to a terminal). Find Next / Previous act only while the bar is open, as the
  keys do. A floating panel (`⌘K` / `⌘Y` / `⌘N` / `⌘/`) swallows `⌘F` and `⌘G`:
  it owns the keyboard and the bar must not take focus underneath it. libghostty's own `⌘E` (search the selection) and
  `Esc` (end an active search) still fire when the terminal has focus, and the
  bar follows them through the callbacks.
- **Ghostty's defaults are kept where they matter.** Short needles (1–2 chars)
  are debounced 300 ms; the count uses the compact `3/12` form inside the field
  and is silent when nothing matches; `Esc` in a focused terminal during an
  active search ends the search rather than reaching the agent (the next `Esc`
  goes through). Navigation does not wrap at the last match — libghostty does
  not, and a "select first" action does not exist to fake it with.

---

## ADR-017 — Archive is a visibility mask Temple owns; manual project order sits above recency
**Date:** 2026-09-06 · **Status:** Accepted

The sidebar had grown past the point where "grouped by project, newest first"
found anything: too many finished sessions, too many projects in an order nobody
chose. Two additions, both Temple-side state in the session DB (ADR-009), neither
touching a session file (ADR-007).

- **Archiving hides; it never deletes or moves.** A session or a whole project
  can be archived. Archived things leave every browse surface — sidebar, `⌘K`,
  `⌘Y`, launcher recents, the `⌘N` picker — and live only in the `⌘⇧Y` archive
  browser, a sibling of `⌘Y`. The sidebar carries **no** archive section: the
  point was a tidier rail, and an "Archived" group at the bottom would grow
  without bound and undo it. A project is a visibility mask over its sessions:
  archiving one hides the pins inside it, unarchiving brings them back; archiving
  a single session clears its pin, because pinned-and-put-away is a
  contradiction.
- **Opening is the only implicit unarchive.** Resuming an archived session from
  the browser, or starting a session in an archived project, brings it back — you
  went looking for it. Activity on disk does not: a session resumed in some other
  terminal updates its file and stays archived, because a file changing is not a
  decision. Archive is refused while the session (or any session in the project)
  has an open tab; the alternative — closing through the busy-agent prompt and
  archiving on completion — made a menu item asynchronous.
- **Manual project order wins over recency, and unplaced projects float above
  it.** A project header is a drag handle: drop it on another header to land
  above that project, or anywhere in that project's body to land below it (a
  collapsed project has no body, so the lower half of its header means below),
  with an insertion line marking the slot. The launcher's Recent Projects are
  the sidebar's first five, so they follow the same order. The whole visible order persists; projects
  the user has never placed — every newly discovered one — sort above the placed
  block in the launch-frozen recency order, so new work surfaces at the top
  instead of falling under the eight-project cap. Hidden (archived, noise)
  projects keep the slot they held; a move rewrites the visible slots through
  them. The drag payload is a private in-process type, never text, so a drop that
  misses the rail cannot paste a path into a live terminal. Move Up/Down menu
  items were tried first and rejected as too clumsy for a list this long. "Move
  to Top" by drag is therefore not a permanent top — a new project will still
  appear above it until placed. Accepted on purpose.

## ADR-018 — The sidebar owns its layout; its actions live in the title bar
**Date:** 2026-09-22 · **Status:** Accepted

A redesign pass on the rail, aimed at readability and structure, not density
(a first attempt that shrank rows was rejected: "compaction is not the goal").
Four decisions came out of it.

- **The rail is a plain `ScrollView { VStack }`, not a `.sidebar` List.** The
  List is an AppKit source list whose row height comes from the system "Sidebar
  icon size" through SwiftUI's own delegate — `defaultMinListRowHeight`,
  `controlSize` and the table's `rowHeight` were each tried and none moved a
  row — and a `LazyVStack` animated children it re-created from its own origin,
  so a collapsing project's rows flew up over the header. Owning the layout
  made the pitch ours and retired the negative row insets that fought the
  List's indent. The disclosure is `if expanded { rows }` inside a clipped
  stack: rows leave the tree when folded and are swallowed inside the group's
  box while they fade. Cost accepted: nothing is lazy; the rail is capped, and
  "Show all projects" is the one path that could make that felt.
- **Project headers speak the launcher's section language.** Uppercase,
  letter-spaced, a hairline rule, a chevron — one vocabulary across the rail
  and the home pane, and the rows become the primary items, which is what you
  click. Known cost, kept on purpose: caps and tracking cost long kebab-case
  names width and case. Sessions are two-tone (open at full strength, history a
  step back) with badges faded until open or hovered; a resting fill on open
  rows was tried and removed — in dark mode it read as selection. The dot that
  pulses is the one asking for you (needs attention), never running.
- **The rail's actions are title-bar items, and the sidebar toggle is ours.**
  Open-folder, search and the toggle sit as one `ToolbarItem` at the trailing
  edge of the sidebar's section, opted out of macOS 26's shared glass capsule:
  AppKit only forms the capsule once the items have slid into the bare band on
  collapse, and forming it compacts their spacing in one unanimated step. The
  system toggle cannot opt out, so it is removed (`.toolbar(removing:)`) and
  replaced by a button with the same glyph and ⌘B's action. Consequence: the
  title-bar tab strip measures the items parked beside the traffic lights
  instead of budgeting a fixed inset for one toggle. Search unfolds from the
  magnifier and folds when empty and unfocused; a permanent field was the
  strongest element at the top and its removal was asked for.
- **Colour tokens adapt, including the colour-mark wash.** A mark's wash over
  a panel row is a `Palette` token with light and dark alphas, because a fixed
  alpha of a saturated colour is a strong pastel on white next to the grey
  selection and a faint band on the dark panel. The sidebar row keeps a 3pt
  capsule as its density-appropriate rendering.

Verification changed with it. Snapshots come from the in-process hook; the same
gate installs `USR2` (toggle sidebar), `INFO` (fold the first project),
`TEMPLE_SNAPSHOT_PRESENT` (open a panel through its real toggle) and
`TEMPLE_SNAPSHOT_APPEARANCE` (force a theme through `AppModel.effectiveTheme`,
never the persisted setting), because two of the day's bugs — rows drawn over
the title bar, a fill that read as selection only in dark mode — were invisible
to code review and to a light-mode, one-tab snapshot.

## ADR-019 — The sidebar is not spring-loaded
**Date:** 2026-09-24 · **Status:** Accepted

Reported as the collapsed sidebar opening by itself, at random, while working.
The one clue that survived was a screenshot: the sidebar fully open while the
rail's title-bar buttons still sat beside the traffic lights, where they belong
only when it is collapsed — an open the toolbar had not been told about.

`NavigationSplitView` builds the sidebar as an `NSSplitViewItem` with sidebar
behavior, and AppKit ships those spring-loaded (`NSSplitViewItem.h`: the item
"can be temporarily uncollapsed during a drag by hovering or deep clicking on
its neighboring divider"). Measured in a scratch app and pinned by a test: the
SwiftUI item has `behavior == .sidebar`, `isSpringLoaded == true`. So a drag —
a file into the terminal, a chip, a row — that hovers the left edge expands
the sidebar through spring-loading. Inference from the screenshot, not
instrumented: that path leaves the item's collapsed flag and the toolbar alone,
and never writes `sidebarVisibility` — which is why the persisted state still
said hidden, why the didSet trace behind ADR-015's follow-up (which found only
the relaunch) saw nothing, and why the next ⌘B visibly does nothing (it assigns
shown to a sidebar the model already believes is hidden).

Ruled out on the way, so nobody re-walks them: dragging the collapsed divider
(hit-testing at the edge lands on the detail pane; a simulated drag leaves it
collapsed), Ghostty keybinds (Temple loads only its own generated config), a
stray ⌘B (one toggle, no hotkey tool or script sends it), and relaunch
(persistence was already installed). Not covered by this flag, and not seen:
AppKit's own size-driven collapse/expand and the full-screen overlay sidebar.

**Decision:** clear `isSpringLoaded` on the sidebar item. SwiftUI's
`.springLoadingBehavior(.disabled)` was measured first, on the split view and
on the sidebar column: neither reaches the item, the flag stays on. So
`SidebarSpringLoadingDisabler` reaches the `NSSplitViewController` through the
split view's delegate, from a background view of the split view (the sidebar
column may not be loaded while collapsed; the split view always is). It
re-applies rather than latches — on `viewDidMoveToWindow`, on layout, on every
SwiftUI update, and on `NSSplitView.didResizeSubviewsNotification` for its
window — because SwiftUI can rebuild the controller (a detail-pane layout
change rewraps the split view; see AGENTS.md) and a rebuilt item is
spring-loaded again. The split view is cached weakly, so a re-apply is a
delegate cast and a short loop; the window is walked only when the cache is
stale. The tests pin the premise, the fix through the static walk and through
the mounted representable, and the re-apply and its teardown; the walk reports
how many items it changed so a version that misses the split view fails
instead of passing quietly.

Cost accepted: a drag can no longer reveal the hidden sidebar to drop on it.
Nothing in Temple accepts a drop there from outside the sidebar, and the
sidebar's own reorder drags start from rows that are visible.

## ADR-020 — Spawned shells identify as Temple
**Date:** 2026-09-24 · **Status:** Accepted

An agent running in a Temple tab read `TERM_PROGRAM=ghostty` and told Sri to
grant Full Disk Access to Ghostty. The grant belonged to Temple: the process
tree was Temple → login → claude → zsh. Nothing was inherited — Temple is
launched by launchd — libghostty itself sets `TERM_PROGRAM` and
`TERM_PROGRAM_VERSION` for every PTY it spawns.

**Decision:** Temple overrides both, in one place, for every spawn.
`TerminalIdentity` supplies `TERM_PROGRAM=Temple` and the bundle's marketing
version (`0.0.0` for a bare SwiftPM binary, matching the app build script's
fallback), and `OpenSessionsModel.ensureSurface` merges it into the command's
environment with the command's own values winning. libghostty applies the
surface config's environment after its defaults — the block is commented
"override any others" — which is what makes a config-level override enough.

Deliberately not done: clearing `GHOSTTY_*`. `GHOSTTY_RESOURCES_DIR` is where
the shell integration scripts live (and `TERMINFO`, set beside it, is what
resolves `xterm-ghostty`); `GHOSTTY_BIN_DIR` feeds the PATH and helper
integration. Removing them breaks cursor, title and path features in every
tab. Nothing in the shell integration or the config tests for the value
`ghostty`; the one check in `Config.zig` asks only whether `TERM_PROGRAM` is
non-empty. Foreign identity variables (`ITERM_*`, `TERM_SESSION_ID`) only
appear when Temple is started from another terminal, and the surface config
can add variables but never remove one — if that case ever matters, the place
is an `unsetenv` at app startup, since libghostty copies Temple's own process
environment.

## ADR-021 — A freed surface does not hand its messages to its successor
**Date:** 2026-09-24 · **Status:** Accepted

Live terminal titles occasionally appeared on the wrong tab, across projects
and within one. Temple's attribution was checked and correct; the cross was
at runtime. Root cause, confirmed in the vendored libghostty and unchanged on
upstream main as of today: a surface's queued messages (`set_title` is a
256-byte copy) are tagged with the raw surface pointer, and the app-thread
drain validates them by pointer equality against the live surface list.
Surface A queues a title; A is freed before the drain; B is allocated at A's
address; the drain accepts A's message for B. Upstream has since added a
64-bit `Surface.id`, but the message and its validation still use the pointer,
so there was no fix to pull.

The sequence that produced it here ran entirely inside one tick: libghostty's
child-exited callback → the tab's `.exited` → the tab is removed → its surface
freed by ARC → the neighbour is selected → a new surface spawned, all before
the drain reached A's message.

**Decision:** Temple orders frees, drains and creations in `GhosttyApp`, and
tabs release their surface explicitly. Three rules, and all three are needed.

- **Never free inside a drain.** A release requested while the mailbox is
  draining is held until `ghostty_app_tick` returns. While A is alive its
  address cannot be reused, so nothing spawned by the drain's callbacks can
  inherit it.
- **Drain after every free, before returning.** Once `ghostty_surface_free`
  returns, A's IO, renderer and search threads are joined and can queue
  nothing more; the drain then finds A gone from the live list and drops
  what was left. The drain's own callbacks may release more; each round
  frees before it drains again.
- **Create nothing while a drain is on the stack.** The first two rules are
  not enough on their own: a drain that pops another tab's child-exited
  message closes that tab and spawns its neighbour from inside the drain,
  and that spawn could take A's freed address before A's leftovers were
  popped. So `GhosttySurfaceView.startSurface` goes through
  `GhosttyApp.spawn`, which runs the creation at once normally and, from
  inside a drain, only after every release the drain triggered has been
  freed and drained. A `ghostty_surface_new` that returns nil is still
  thrown to the caller when creation ran at once; deferred, there is no
  caller left (it was told "running", as it always was — the pid was
  never real), so the failure is reported through the child-exited path and
  the tab keeps its terminal with the launch-failure header, the way any
  early death does.

Two lifetime consequences of freeing early, both found in review:

- libghostty calls back into the view through the surface's `userdata`
  (close-surface, clipboard) until the surface is gone, not through Temple's
  registry. A held release retains its owning view until the free.
- libghostty installs its render layer as the view's layer, with a display
  callback holding a raw pointer to the renderer. SwiftUI can keep the view
  in the tree for a render pass after the tab is gone, so `closeSurface`
  swaps in a plain layer before the free. That removes the view-tree
  display path; the raw callback inside the detached layer is not cleared
  (only libghostty could), and no other path that would invoke it has been
  identified.

`removeTab` calls `TerminalSurface.release()`, so teardown happens at a known
point on the main actor; `GhosttySurfaceView.deinit` still frees as a
fallback but cannot drain and is documented as still carrying the race.
`closeSurface` now unregisters on every path, closing the older
deinit/unregister asymmetry. Ticks are non-re-entrant (`tick()` ignores a
nested call): a wakeup landing mid-drain is not lost, its `wakeup_cb` has
already queued the next tick on the main queue.

Not covered, and documented rather than claimed: libghostty's drain stops
early on an error or a quit message, so leftovers can survive one drain and
be delivered by the next; a surface freed through `deinit` rather than
`release()` (model destruction, never a continuing session) keeps the race.
The categorical fix is in the library — validate queued messages by a
monotonic surface id rather than the address, which upstream's `Surface.id`
now makes a small patch — and is the next step if these rules prove fragile.
It was not taken now because the vendored tree is untracked and rebuilt by
`Scripts/build-ghostty.sh`, so it needs patch plumbing and a toolchain this
change did not want to add.

Review ledger for this change (gpt-6-astra): round 1 found three defects in
the release path — the held release did not retain the view, the drain's
callbacks could spawn at the freed address, and the render layer outlived
the renderer — all in `GhosttyApp.release`/`closeSurface`. Each is a rule or
consequence above; the tests pin the ordering of free, drain and spawn and
the owner's lifetime through the runtime's injectable seams.
