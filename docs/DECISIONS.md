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

> **Since ADR-023 (2026-09-25):** the on-disk index is still the source of what
> sessions *exist*, but which of them Temple *shows* is Temple's own record —
> the rows in its DB — not the index.

> **Since ADR-029 (2026-10-03):** the sidebar is not built from these files at
> all. Rows are Temple's `session_state` records; a transcript fills a row's
> missing facts once and is otherwise read only to verify identity.

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

> **No longer wholly true (ADR-023, 2026-09-25):** which sessions are Temple's —
> the `session_state` rows, and how each joined — is authoritative and cannot be
> rebuilt from disk: nothing the CLIs write says Temple touched a session. Losing
> the DB now empties the default sidebar until sessions are opened again. The
> rest of this ADR stands.

> **Since ADR-029 (2026-10-03):** the DB is also the authority for a session's
> core fields (directory, title, last activity, host). The files remain the
> truth for what a session contains, and fill a field only where Temple has
> none.

> v0 note: `TempleCore` currently derives everything directly from disk with no
> DB. The DB lands when we add pins/tab-restore/process-registry (Phase 2–3).

---

## ADR-010 — Temple owns the agent processes; graceful lifecycle
**Date:** 2026-07-10 · **Status:** Accepted; amended by ADR-036 (an agent on another machine is not Temple's child process: an idle close ends it, a working one detaches, an unconfirmed end is listed and never performed later, and a quit leaves every one running)

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

> **Re-checked 2026-09-25 (Claude Code 2.1.282):** Claude now writes
> `{"type":"ai-title"}` lines, but in only 5 of ~1,900 transcripts — 4 of them
> background sessions, the fifth with an agent name — and `{"type":"custom-title"}`
> in one, after a rename.
> The rule above still holds for what Temple launches. Codex keeps titles in its
> private `state_5.sqlite` `threads` table; see SESSION-FORMATS.md.

> **Since ADR-029 (2026-10-03):** the row's own `title` is what shows: the
> agent's terminal title as it runs, filled once from the transcript's
> recorded title facts (`titleFact`) when Temple has none.

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
**Date:** 2026-09-06 · **Status:** Accepted; amended by ADR-030 (Temple archives a session nobody can resume, its transcript or its folder gone) and ADR-031 (archive is a scope of History; opening or restoring brings back one session, Restore project is named)

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
  "N more projects" is the one path that could make that felt.
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

## ADR-022 — A dead usage meter says why, and never prompts on its own
**Date:** 2026-09-24 · **Status:** Accepted

A Claude meter stuck on "Couldn't refresh" for days on one machine, with the
refresh control doing nothing, while `ccmeter` — the tool the reader was
ported from — read the same Keychain and the same endpoint fine. Nothing
Temple recorded could say which failure it was: the reader collapsed every
non-200 into one outcome, which Keychain item it chose and whether that
token was past its expiry went unrecorded, and the credential lookup ran
`/usr/bin/security` as a child process — whose Keychain prompts are
attributed to `security`, so "Always Allow" never stuck to Temple, and
which, blocked on a prompt nobody answered, would have blocked the whole
refresh with nothing logged. A read-only look at the stuck instance found
no such child, no pending prompt, no thread parked in the usage path, and a
freshly rotated token; the best remaining explanation is the old breaker,
tripped by one failed read, with the refresh click dropped by its
five-second floor — unproven, because nothing was persisted. Both of those
are changed below, and the file exists so the next time is not a guess.

**Decisions.**

- **The Keychain is read in-process** with the Security framework:
  attributes of every generic password are listed (no secret, no prompt),
  the Claude Code service variants are read newest-modified first, the first
  one carrying a token wins, and the credentials file is the fallback. Two
  deliberate differences from ccmeter, which reads every variant and keeps
  the latest expiry: the walk stops at the first token, because each read
  can be its own prompt and the token-less stubs Claude Code leaves behind
  are long-lived (2026-10-02: two July stubs ahead of the live item meant
  three dialogs per click; the user approved the two that held nothing and
  refused the third); and an item that needs a prompt stops the walk and
  the fallback, because older items and the file may both hold credentials
  the CLI no longer refreshes, and after a Deny the next read would raise a
  second dialog behind the refused one. No child process, so nothing to time out,
  signal or reap. The lookup runs on one serial queue, and the interaction
  switch is saved and put back rather than assumed.
- **Unattended polls never prompt.** `SecKeychainSetUserInteractionAllowed`
  is switched off around every lookup except the one the refresh control
  starts. It has been deprecated since macOS 10.10 and is still the only
  switch that governs login-keychain items — the per-query `kSecUseAuthenticationUI`
  covers the data-protection keychain alone (SecItem.h says so). It is
  process-wide; one lookup runs at a time, its previous value is read and
  put back, and an unattended lookup that cannot establish "no prompts" —
  the switch cannot be set, or its previous value cannot be read — does not
  read at all and reports the permission state instead. An item Temple may
  not read fails with `errSecInteractionNotAllowed`,
  which is a new outcome, `needsPermission`: it trips the same breaker as
  no credentials, and the card says "Temple needs permission to read the
  Claude Code sign-in. Refresh to allow." The refresh control is the one
  place a prompt may appear, attributed to Temple — one prompt per item that
  needs it — where "Always Allow" makes every later poll silent, and it
  bypasses the click floor so a click seconds after opening the card still
  asks. Any answer from the endpoint, a 401 included, clears the permission
  state: the token was read, whatever it was worth. Consequence on first
  launch after this change: no Claude number until that click, because
  Temple itself was never in the items' access lists; the card, reached
  through the Codex figure or View → Refresh Usage, carries the line.
- **The footer never alarms.** It shows numbers or nothing: the footer is
  glanced at all day, a stale number is easy to ignore and a colored symbol
  is not, and pulling attention to something the user may not be able to
  fix is the worst trade the sidebar can make. Explanations live in the
  card, opened on purpose, and the record lives in a file. Because a meter
  that has never shown a number has no footer to click, the View menu
  carries "Refresh Usage", the same interactive refresh as the card's
  control — the route to the Keychain prompt for a Claude-only user.
- **A log file, not just the unified log.** `UsageLog` writes every lookup
  and every fetch outcome — successes included, as one line of figures —
  timestamped, to `<state dir>/logs/usage.log` (trimmed to its newer half
  past 512 KB) as well as to the unified log. Only the app turns the file
  on, at launch; the test suite drives the same model and must not write
  one. A file that cannot be written is reported once through the unified
  log rather than failing silently.
  Info-level unified-log lines are gone within hours and the persisted ones
  take a predicate to find; "it happened last week on my other Mac" needs a
  file a person can open and hand over. Never the token, never the Keychain
  account. Under the state directory, so a demo run writes its own.
- **The HTTP status rides in the reader's outcome**, and the model's
  per-outcome log line prints it; a 401 is its own outcome. The model keeps
  polling on a 401 (a new sign-in lands in the Keychain without any action
  in Temple) but the card says "Sign-in rejected. Run claude auth login." at
  once — a refused token is definitive, not a hiccup.
- **The reader logs its credential choice**: which item, how many were
  enumerated, how many newer ones held no token, which item needed a prompt,
  and the token's expiry relative to now (Claude Code writes epoch milliseconds; seconds are
  read as such). The service name is public — a fixed label plus an opaque
  suffix — the account is not. Never the token.
- **Transitions at notice, polls at info** in the unified log — notice is
  the level it keeps on disk — and everything in the file.

Not changed: which credential wins. The reader takes the latest `expiresAt`,
so "skip expired items" would be a no-op — if the winner is expired, every
item is (assuming one unit; Claude Code has only ever written milliseconds).

Reviewed by gpt-6-astra over nine rounds and then, as one diff, by Claude
Fable. The mechanism changed twice on the way — a subprocess runner with
deadlines and signals, then the framework — because findings kept landing in
the same function, which is the signal that the mechanism, not the patch,
is wrong (`dotfiles/docs/review-escalation.md`).

## ADR-023 — Temple browses its own sessions by default
**Date:** 2026-09-25 · **Status:** Accepted; the *All on disk* setting is superseded by ADR-027

ADR-007 built the sidebar from everything the CLIs write to disk. On a machine
that runs agents from other terminals, scripts and editors, that is most of
the rail: 1,976 sessions in 42 projects on Sri's, most of them work that
happened elsewhere and was browsed, never opened.

- **A Temple session is one with a row in `session_state`.** Temple writes a
  row the first time it touches a session: starts it, resumes or restores it
  in a tab, or pins, renames, colors or archives it. That is the whole rule —
  no flag beside the row saying "but was it really Temple's". A project is
  shown when it holds a Temple session. Membership follows the row, never
  the attempt: if the join's write fails, the session stays out and the
  action that asked for it does nothing; whatever touches it next joins it.
  A failed write is not retried, like every other write in the overlay — a
  retry ledger was tried and grew a new edge case each review round, for
  local SQLite writes that fail essentially never. Failure may lose a record;
  it never shows the wrong sessions.
- **Every row records how it joined, once.** `joined_via` is `created`
  (Temple started it: a minted Claude id, or the Codex id adopted for a
  session it launched), `opened` (an existing session first resumed here) or
  `imported` (brought in without running it — acted on while browsing all
  sessions). `joined_at` is when. The first join is the one kept (`ON
  CONFLICT DO NOTHING`). Rows from before this ADR stay `NULL`: nothing Temple
  kept says whether it started those or resumed them, and a later open does
  not get to claim them. It never decides visibility; it is there because it
  can never be reconstructed later.
- **How a session joined is not where it came from.** Lineage — continued or
  forked from another session — is a separate fact and gets its own columns
  or table (`parent_id`, `relation`) when it lands, never a `JoinedVia` value.
  The case that forces the split: `←` in a Temple tab continues the session
  under a new id *and* that new id was created in Temple's tab — both true at
  once. And the link on disk runs parent → child, so the row that changes when
  a session is continued is the parent's ("superseded; show my child"); the
  sidebar shows the tip of a continued chain.
- **Built to grow in one place.** A continued or forked session, a background
  agent's session, and an explicit "Import" / "Open in Temple" on a session
  from elsewhere all become Temple's through the same `join`, not a new flag,
  and none of them may change the visibility rule above. The on-disk hooks
  each needs are in SESSION-FORMATS.md; the load-bearing ones:
  - **Claude `←` / `/bg`** forks the conversation to a **new id** run by a
    background worker. The link runs parent → child only: the old transcript
    ends with `{"type":"continued-in","continuedInSessionId":…}`. Until this is
    followed, the tab and its `open_tabs` row keep pointing at the frozen
    parent, and a relaunch resumes that copy rather than the live agent.
  - **A live Claude background session** opens in a tab with `claude attach
    <short-id>`, which keeps the id; `--resume` would start a copy.
  - **Which session a tab's process is on now** is in
    `~/.claude/sessions/<pid>.json` — the way to rebind a tab after `←`.
  - **Codex** records lineage itself: `forked_from_id`, and
    `source.subagent.thread_spawn.parent_thread_id` (also
    `thread_spawn_edges` in its `state_5.sqlite`). Background threads on its
    daemon keep their id.
  Subagents are not sessions for either CLI (ADR-024) and never join.
- **Outside sessions are nowhere, not demoted.** The scope is a stage between
  the noise filter and the archive mask (`AppModel.scopedProjects`), so the
  sidebar, `⌘K`, `⌘Y`, the launcher, the `⌘N` picker and the `⌘⇧Y` archive all
  agree. Archiving a whole project writes a project row, not one per session,
  so it does not import the project's sessions.
- **"All on disk" writes nothing.** Settings ▸ Sessions ▸ Show: *Temple
  sessions* (the shipped default) / *All on disk*. The full index already lives
  in memory (and the launch cache file); switching scope only changes which of
  it is listed, so toggling the setting cannot bloat the table however many
  sessions are on disk. Only acting on a session imports it. Like every
  setting, only the user's choice is persisted (`temple.settings.sessionScope`).
- **Upgrading shows only what Temple already has a row for.** No migration
  guesses at the past (ADR-009's rule; `recordOpened` was never called, so
  `last_opened_at` holds nothing). A session has a row from before only if it
  was pinned, renamed, colored, archived, or retitled itself in a Temple tab;
  open tabs join when they are restored. On Sri's machine that is 180 sessions
  in 8 projects. A session Temple started that left none of those behind is
  not shown until it is opened again — and then it joins as `opened`, not
  `created`. That is the rule working, not data lost.
- **`make demo` imports its seeded sessions** with `templectl --import-all`,
  which refuses unless `TEMPLE_STATE_DIR` names a directory other than the
  real one (an empty value, or the real path spelled differently, is refused):
  a row for every session on the real disk would erase the line the sidebar
  draws, and could not be told apart from the rows the user made.

## ADR-024 — Subagent transcripts are not sessions
**Date:** 2026-09-25 · **Status:** Accepted

Both CLIs keep a transcript for every subagent, and neither is a session a
person opens: it runs inside its parent, for its parent, and ends with it.

- **Claude** files them under `<session>/subagents/agent-<id>.jsonl`, below the
  level the index reads. Already excluded, now on purpose.
- **Codex** writes each as a top-level rollout with
  `source.subagent.thread_spawn.parent_thread_id`. `CodexSessionStore` now skips
  those (`isSubagentThread`). It also reads the thread's id from `payload.id`,
  not `payload.session_id`: `session_id` is the *root* thread's, so for a
  subagent it is the parent's, and reading it first filed each of the 42
  subagent rollouts on Sri's machine as a second copy of its parent — the
  duplicate ids `AppModel` had been deduping in the palettes, and that the
  sidebar did not. Resume, reveal-in-Finder and titles could each land on the
  subagent's file instead of the parent's.

Showing subagents under their parent is a possible later feature; if it comes,
they are rows *of* a session, never sessions of their own.

## ADR-025 — A failed probe is retried, and says why it failed
**Date:** 2026-09-27 · **Status:** Accepted

Temple 0.3.0, installed through Homebrew at 22:44, launched a June 2025 npm
Claude Code for every new session the next morning ("unknown option
--session-id"), while six sessions restored at launch ran the current
2.1.283. Settings showed why: "Also found ~/.local/bin/claude — can't be
launched." The system log around that second, as observed: at 22:44:25
Apple's system policy daemon logged that it could not apply a provenance
sandbox to a child of Temple; at 22:44:26 syspolicyd logged a Gatekeeper
scan result for com.anthropic.claude-code and the creation of its provenance
record. The likely explanation — not established, since the probe threw the
error away — is that the first exec of a freshly downloaded binary by a
freshly installed app failed while macOS evaluated it. What is established:
the probe recorded the failure without the reason, detection ran once, and
the verdict stood until opening Settings happened to re-run it. Both binaries
probed fine the next morning.

**Decisions.**

- **The launch error is kept.** `CommandCapture.launch` throws the OS error;
  the probe's verdict reads "can't be launched: <reason>", in Settings and in
  the log. "Can't be launched" alone read as a broken install and sent the
  first look past the real cause.
- **A flawed verdict is retried.** When something on the PATH was skipped
  ahead of what was chosen, or installs exist and none ran, `ToolchainModel`
  detects again — successive waits of 10, 30 and 60 seconds after each
  detection completes — then stops; a user-initiated detection restarts the
  schedule. A clean verdict is never retried, and a failed install *behind*
  a healthy winner does not count as flawed: it cannot change what launches.
  A permanently broken earlier install costs three extra detections per
  launch, which is accepted. The schedule covers the observed gap (the log
  events above are two seconds apart) without turning detection into a poll.
- **The automatic resolution is logged** at notice level — for each agent
  with any install found, the chosen path and version (or that nothing runs)
  and each skipped install with its reason — so "why did it launch that" is
  answerable from `log show` days later. Override checks are shown in
  Settings and not logged.

Not changed: which install wins (PATH order, first that runs), and that a
user override is taken as-is.


## ADR-026 — Upstream Ghostty fixes are carried as patches until a release has them
**Date:** 2026-10-01 · **Status:** Accepted

Temple 0.3.x, nine days up with 37 tabs open: 25–55% CPU in Temple itself.
A sample put every background tab's renderer thread to work. Only the active
tab's view is in the window, but nothing told libghostty, which assumes a
surface is visible and focused; the host now sends occlusion (commit
35d3a88). That stops drawing, not the cost: stock v1.3.1 still rebuilds a
hidden surface's frame (shaping, link matching) on every output, and that is
where the CPU went. Upstream fixed exactly this on 2026-05-21 (`14d9e600ac`,
"renderer: skip updateFrame when surface is not visible"), after v1.3.1, and
no release has shipped since. Measured with 21 surfaces redrawing 4×/s, one
visible, occlusion on in both: ~39% of a core stock, ~5% patched; a tab
hidden for 5s while its output changed showed current output 300ms after
being shown again.

**Decisions.**

- **Carry the fix as a patch on the pinned tag**, not a bump to ghostty
  `main`. `main` has moved to Zig 0.16 and much else; the fix is 14 lines
  that apply cleanly to v1.3.1. `Patches/ghostty/` holds upstream commits
  verbatim, and `build-ghostty.sh` applies them (BUILDING-GHOSTTY.md).
- **Only upstream commits, as temporary backports.** This narrows ADR-003's
  "a library, not a fork" rather than giving it up: every patch is code
  Ghostty has already merged, and a change upstream hasn't taken is not a
  patch here. Upstream merging it is not proof it works on our older base;
  Temple checks each one on the pinned tag (BUILDING-GHOSTTY.md).
- **Patches expire.** A bump drops every patch the new tag contains; the
  build stops on one that neither applies nor reverse-applies.
- **A stale artifact is a build error.** `Vendor/` is git-ignored and outlives
  `make clean`, so a checkout gaining a patch would otherwise keep linking the
  old xcframework and ship without it. The artifact carries a stamp of what it
  was built from, written only after the build has checked its source is the
  tag plus the series and nothing else; the app build and `make build` refuse
  a mismatch. The build script itself is deliberately not in the stamp (a
  comment edit would force a rebuild); if a build-flag change must invalidate
  artifacts, add an explicit recipe revision to the stamp then.

Accepted side effects, all shared with upstream `main` and bounded: on
showing a tab, one frame can come from before it was hidden (Core Animation
can redraw the layer before the renderer catches up), search highlights can
sit at old positions until the next search refresh, and a tab shown in the
middle of a synchronized-output frame keeps its hidden-time cells until that
frame ends.

Not taken yet: upstream `c4e16970a8` (2026-08-25), which frees a hidden
surface's GPU memory (upstream measured 385 → 18 MiB at 1 visible + 20
hidden tabs). It is a larger change across four files; it goes through the
same door if it applies and measures.

## ADR-027 — Temple indexes only its own sessions, and hears about them through FSEvents
**Date:** 2026-10-02 · **Status:** Accepted; the launch cache and per-write parsing are superseded by ADR-029

Temple 0.3.3 after two hours: 5,220 open files, 4,106 of them session logs, one
`O_EVTONLY` watch per `.jsonl` on disk (Claude 1,354 with subagents, Codex
2,751), and the session-watcher thread at two thirds of the app's CPU. Every
reload, at most every 0.4s while anything wrote, re-read the size and date of
all ~4,100 logs and re-walked both trees; the event said which agent changed,
never which file. All of it fed a sidebar that, since ADR-023, shows the 337
sessions in `session_state`. The whole disk was also parsed at launch and kept
in memory, and a 2.2 MB `index-cache.json` was rewritten every five seconds.

**Decisions.**

- **"All on disk" goes.** Every surface lists Temple sessions only. Outside
  sessions are read in one place, on demand: `SessionCatalog`, used today by
  `templectl` and built for the History tab, which is how an outside session
  is imported. The setting's removal does not ship in a release before that
  tab does: without it, someone who browsed All on disk would lose those
  sessions with no way to bring one in. Nothing outside Temple is watched.
- **The live index holds members, nothing else.** Members are the
  `session_state` rows, any `joined_via` including the legacy NULL ones, plus
  runtime joins. AppModel's membership filter stays as a guard.
- **Where a member's log is: a hint, then a map.** `session_state` gains
  nullable `agent` and `transcript_path` (migration `v9-session-transcript`),
  written when a session joins with a known file and after a legacy row first
  resolves. A hint is validated by parsing; it never decides membership. Rows
  without one fall back to a filename map built at launch from the real
  directories (Claude's cwd encoding is lossy and is never reconstructed;
  Codex filenames give the thread id, including the `thread/revert` form, see
  SESSION-FORMATS). A member found by neither is absent, rechecked when a file
  with its id appears. There is no search of file contents for it: a first
  version read every rollout's header to find rows whose filename id might
  differ from the id inside, and it cost launch time, then steady CPU on every
  outside write, while finding nothing. On the real stores, 0 of 2,761
  rollouts had such a mismatch and 0 of the 173 unresolved rows were in any
  file; they were deleted logs. Sessions joined from now on carry a path hint,
  which covers a renamed file.
- **One FSEvents stream replaces the watches.** File events over both roots,
  started before the launch listing (Apple's required order) with events
  buffered and reconciled after. An event means "reconcile this path": flags
  are tested as bits, current existence decides. Paths are mapped through the
  resolved roots (`/tmp`, `/var`, symlinks). Under `~/.codex`, anything that is
  not a rollout or one of the two title files is dropped before any stat. A
  member's write reparses that file; a non-member's costs nothing. Folder
  moves, `MustScanSubDirs`, dropped events and a changed or missing root each
  have a reconcile rule.
- **Each member has a resolution state:** resolving, awaiting creation (a
  Claude session Temple just launched), loaded, confirmed absent, unreadable.
  Only a finished resolution establishes absence. "Awaiting creation" exists
  only for a join made in this launch for a file not written yet; a restored
  row whose log is gone (Claude prunes old transcripts) is absent, so a failed
  resume still says why. A deleted log never removes membership. Every
  committed join goes through one path that loads the session at once (an
  import has no file activity to wait for). Joins committed by another process
  (`templectl --import-all`) are seen at the next launch.
- **Codex adoption is registered before the process spawns,** sweeps only
  rollouts whose time falls in its ±5s window, and is decided when that window
  closes, over every candidate seen: one candidate per request, ambiguity
  refused. A rollout whose header can't be read yet blocks the decision rather
  than counting as "not a candidate". Adopting at the first unique match was
  tried and dropped: a second session started in the same folder moments
  later could then no longer prevent a wrong match, and a wrong match is saved
  as the id the tab resumes. The cost is a tab without its id for ~5 s.
  Candidates never reach the index.
- **The launch cache holds members** (schema 3, filtered by membership on
  load), and AppModel compares index content, so a title-only change reaches
  the UI.

**Measured** with `templectl --watch` on APFS clones of the real stores (337
members, 164 with a log on disk; 1,355 Claude and 2,761 Codex logs), one member
written 4×/s and one outside Codex log 2×/s, over 60s:

| | before | after |
|---|---|---|
| CPU | 50–53% of a core | 2.8% |
| open files | 5,081 | 47 |
| first index | 9.0–9.2 s | 1.5 s cold, 1.3 s warm |
| memory | 326–505 MB | 36–38 MB |

80 writes to the outside log produced no index publication.

Launch still lists file names across the whole disk; everything after that
scales with the sessions Temple manages. Not changed: the usage meter's own
scan of recent Codex logs, and continuation following (`←` / `/bg`, ADR-023),
which is still to be built; the event classifier is where it lands.

## ADR-028 — History is a tab over the whole disk, and the one way in
**Date:** 2026-10-02 · **Status:** Accepted; Temple's rows no longer take a live-index copy (ADR-029); scopes All / In Temple / Archived / Not in Temple, In Temple excluding archived rows (ADR-031); ⌘Y no longer goes back when pressed on History (amended 2026-10-06, below)

With *All on disk* gone (ADR-027), sessions run elsewhere are on no surface,
and ADR-023's "imported" join had no way to happen. The ⌘Y overlay also read
as a search box over Temple's own sessions, not as history.

**Decisions.**

- **History is a tab**, a singleton beside Settings: ⌘Y opens or focuses it,
  ⌘Y on it goes back to the previous tab and leaves it open (*superseded
  2026-10-06: ⌘Y on History stays; see the amendment below*). The overlay is
  gone. It lists **every session on disk**, newest first in day groups, one
  line each; Temple's own rows at full strength with the gate mark, the rest a
  step quieter with **Import**, archived ones tagged. Search and the All / In
  Temple / Not in Temple, agent and project filters narrow the page in place.
  Noise stays hidden.
- **It reads the disk when shown and on ⌘R, never watches it.** Through
  `SessionCatalog.stream`, newest first, cancelled when the tab goes. Temple's
  own rows take the live index's copy. Watching the whole disk is exactly
  what ADR-027 removed; a page you look at for a minute does not need it.
- **Import is explicit and confirmed.** A row's Import, ⌘I or the selection
  bar asks first ("Nothing runs until you open one, and the session files on
  disk are not changed"), then joins as `imported` through the same committed
  join path as every other join, so the session loads at once. Opening an
  outside row (Return) joins it as `opened`, as anywhere else.
- **Import can be undone, narrowly.** `TempleDB.leave` deletes a row only while
  it still says nothing but "imported": not pinned, named, colored, retitled,
  archived, opened since, or in a restorable tab. It is the only write that
  removes membership; a committed leave tells the engine, which drops the
  session. ADR-023's "first join is kept" is untouched: an undone row was
  never kept.
- **⌘K stays the quick switcher over Temple's sessions.** When it finds
  nothing it offers "Search history for …", which opens the tab searching.
  (Since 2026-10-05 that row ends every typed query, not only one that finds
  nothing: archived sessions are not in ⌘K, and a query that matched a live
  one had no way on to the archived one in History.)

**Amended 2026-10-06: a command that names a place goes there.** ⌘Y going
back when pressed on History was the overlay's toggle carried over into a
tab, and it read as a bug: View ▸ Session History, chosen while History was
on screen, took you somewhere else, or to the launcher with no other tab
open. ⌘Y (View ▸ Session History, the launcher's Session history) and ⌘⇧Y
(View ▸ Archived Sessions) now only ever open or focus History; repeating
one changes nothing, except that ⌘⇧Y switches History to the Archived scope
when another scope is showing. Over a floating panel, either one puts the
panel away and stays. ⌃⇥, or Esc once History's search and selection are
clear, is the way back. Panels keep their toggles (⌘K, ⌘/ and the ⌘N
picker close on their own key); tab destinations (⌘, Settings, ⌘⇧H Home,
History) never navigate away on a repeat.

---

## ADR-029 — The row is the session; the transcript is enrichment
**Date:** 2026-10-03 · **Status:** Accepted; amends ADR-007, ADR-009, ADR-011, ADR-027, ADR-028; "the rest are kept" is amended by ADR-030; "What remote needs" is amended by ADR-036 (no v13-project-host; a restored chip's host is its row's; a host's project archive and order persist in the remote store)

Temple began as a browser over the CLIs' stores (ADR-007), so a sidebar row
was a parsed transcript. ADR-023 made membership Temple's own record and
ADR-027 parsed members only, but a row was still assembled from the file and
merely let through by its `session_state` row: a member whose transcript could
not be read had no row at all (ADR-027 counted 173 of 337 members without a
log on disk). The plumbing outlived the premise, and it tied every surface to
files on this Mac, which a session on another machine will never have.

**Decisions.**

- **The `session_state` row is the session.** `v10-session-core` adds `host`,
  `directory` (with `directory_source`), `title` and `last_active_at`. Temple
  writes them: the agent's terminal title becomes the title; spawn, retitle,
  input, exit and close are activity (in memory at once, on disk at most every
  30 s per session, never backwards, and quitting is not activity); a
  successful spawn in an existing directory records that directory as
  `tab`-sourced, replacing whatever was there. Copying a row into a restored
  chip writes nothing; a chip joins and records the open when it spawns.
  Where the row lacks the agent or directory (every legacy row, on the first
  launch), the chip's own saved tab facts stand in, so the spawn is a real
  launch that records its folder; a chip neither can place says so on screen,
  and a restored active one opens as soon as its row learns a folder. Every surface renders rows grouped by
  `ProjectKey(host, directory)`, and opening resumes from the row's agent,
  directory and id without waiting for a file.
- **The transcript is enrichment, and parsers never invent.** A parser returns
  nil for what a file does not state; "(untitled)", "(no prompt)", "(unknown)"
  and Claude's lossy directory decode are display hints, never stored. A row's
  NULL field is filled once from a transcript's facts (cwd, mtime, and one
  title chain, `TranscriptSummary.titleFact`: Claude's recorded summary,
  Codex's shared title, the first prompt, the history prompt — the same chain
  History and templectl show before any hint), with the fill checked against the
  row's host inside the write; a filled field is never overwritten by a file.
- **The engine verifies, then enriches, then stats — and never writes.**
  `SessionEngine` is an actor, one per host, that owns the whole per-member
  machine: locate, verify identity, parse only while the row still lacks a
  field (backing off 1 s → 60 s), and decide the verdict. `mismatch` and
  `unreadable` never become `absent`; only a completed enumeration of every
  eligible agent proves absence. It reads the database (membership and the
  fields each row still wants) but writes nothing: it publishes, in every
  snapshot, the facts it currently stands behind for each member, authorized
  by `(run epoch, operation revision, incarnation)`. The app applies them on
  the main actor through `FactPersister`, whose SQL carries
  `WHERE id = ? AND host = ? AND incarnation = ?`, so a leave and rejoin
  between publish and write cannot let stale facts land. Facts are revoked —
  dropped from the next snapshot, and any pending retry with them — on every
  invalidation: a transcript change to a member that still wants a field, a
  coverage reset or reconnect, a shared-facts change, an explicit open, a new
  candidate, a membership change. A member whose row is complete holds no
  facts, and an append to its file is a stat that publishes nothing; it is
  re-verified only on a new file identity, a shrink, a same-size rewrite or a
  new locator (accepted: a file rewritten in place to another session and
  grown on the same inode stays loaded until one of those happens).
  `index-cache.json` is gone (removed once, so an older build installed
  alongside keeps its own): SQLite is the fast launch path, and the sidebar
  draws from it before the engine runs. (History's catalog keeps a cache of
  its own, for browsing only: ADR-032.)
- **One primitive seam per host.** `HostSessionSource` lists and stats
  (`locate`), reads one transcript (`read`, identity and facts with the
  signature the read saw), reports changes (`changes`, with a coverage reset
  on reconnect), lists the whole store (`catalog`), adopts a new Codex
  session (`adopt`) and answers folder evidence asynchronously; a transport
  failure never proves absence. The agent formats — filename selection
  (including Codex's revert rule), identity, bounded parsing with head/tail
  provenance, shared facts, adoption headers — are pure functions in
  `TempleCore/Formats`, so a remote source feeds them bytes rather than
  reimplementing them. A contract suite runs against the local source and a
  fake remote alike. Local transcript I/O is the `TempleLocalHost`
  module; its stores are internal and `LocalSessionSource` is its only public
  type; `TempleUI` imports it in one composition file (a test asserts the
  import list; it cannot police new Foundation reads — that is a review rule).
  `SessionEngine` is host-agnostic, one per host from `HostRegistry`. Each
  registry entry also carries a `HostLauncher`, which builds the command from
  intent (`AgentLaunchSpec`: agent, new or resume, id, directory): the host
  picks its own executable and arguments, so this Mac's detected `claude` path
  never reaches another machine. Directory existence is the owning host's
  evidence (exists, missing or unknown), and unknown neither hides a row nor
  claims a folder is gone. What a tab may record is the launch's own report:
  `prepare` returns the command and a result channel, and only its
  `.directoryEstablished`, after a started spawn, records the folder
  tab-sourced. Locally the agent runs behind a `cd`-then-`exec` shell
  wrapper that writes a per-launch marker, so it never runs in Temple's cwd
  when its folder is gone, and the failure is shown whenever the process
  exits. A launcher with no channel (a future ssh one, until it relays the
  same report) records nothing; its command must still `cd` or exit, and a
  remote new session's folder then comes from its transcript. The session id
  stays the key and `host` an attribute: a join refuses an id already in
  Temple on another host (`hostConflict`) or as another agent
  (`agentConflict`), inside one transaction, and opens, fills, hints,
  activity, launch folders and undo all carry the host predicate.
- **Catalogs are host-tagged and pick before they parse.** Hosts are listed
  concurrently and each batch names its host; a failed host reports itself.
  History takes each host's batches in a lane of its own, folder checks
  included, so a host that answers slowly holds up only its own rows, and
  ending the read (Refresh, leaving the tab) cancels its checks in flight.
  The local catalog chooses each thread's authoritative rollout by the same
  rule member resolution uses, before parsing, and shows nothing for a thread
  whose chosen file is unreadable rather than an older rollout. A file is
  read as a member's is, identity before facts: one named for a session
  that records another, or none, shows nothing (a name is not an identity,
  and an import's fills are never overwritten). History keys
  every row by `(host, agent, session id)`; a catalog row for an id that is a
  member on another host or as another agent is shown, not importable, with
  the reason.
- **Older builds keep working on the file; newer ones stop this build.** v10
  only adds columns and keeps `generated_title`, written alongside `title` and
  reconciled on open (open-time only: an older process's later writes arrive
  on the next open). A database carrying a migration this build does not know
  is neither migrated nor written: both entry points show an update-required
  window before any model, overlay or tab restore exists, and `templectl`
  exits non-zero. Open, check, migration and reconcile run under a
  cross-process lock (`<db>.migrate-lock`, waited on for at most 15 s), so a
  future incompatible migration cannot land in the gap. The writer opens
  first and checks the schema before any write: only a writer can roll back
  a hot journal a crash left behind, and a read-only probe would fail on it
  every launch. Any other open failure shows a "couldn't open its data"
  window, never an in-memory database that silently forgets. Builds before this one have neither
  guard, which is why v10 is additive. `v11-session-incarnation` is additive
  too: an opaque membership identity per row, backfilled and set by an
  insert trigger, so every insertion path — this build's join, a setter, an
  older build's own SQL — gets one, and a rejoin after a leave gets a new
  one. `v13-project-host` (host in `project_state`/`open_tabs` keys) waits
  for remote, with process exclusion as its precondition.
- **Recency is Temple's activity, not the file's.** A session resumed in
  another terminal does not move here, as it already did not un-archive
  (ADR-017). History still shows the disk's time: it is the disk's view.
- **Members are not noise.** The noise filter classifies non-members in
  History only. A member whose directory is gone keeps its row; opening it
  starts nothing (the terminal would otherwise run the agent in Temple's own
  cwd) and the banner says the folder no longer exists, on its own line.
- **Legacy rows are completed from facts, and the rest are kept.** v10 copies
  `generated_title` to `title` and nothing else. The standing fill completes
  every legacy row whose transcript exists on the first launch, through the
  same path an import uses; there is no migration mode. A row that never
  resolves stays: no sidebar group without a directory, found by ⌘K, listed
  in History under In Temple and tagged "No transcript" only once a
  completed resolution says so, and archivable from there.

**Known limitations, kept:** Claude's in-process id rotation (`/clear`,
in-session `/resume`) is not followed, so titles and activity land on the
tab's original row; a rebind is now a row write and is next. Codex adoption
still correlates cwd and time, not process identity, and stays noncommittal
when in doubt. The Codex usage meter reads the local store only.

**What remote needs, and only needs:** `RemoteSessionSource` passing the
contract suite; an ssh `HostLauncher` (`prepare` and `availability`, with a
`cd -- dir || exit` command so the agent never runs elsewhere); host entries
in `HostRegistry` and a host picker; and `v13-project-host` (host in
`project_state`/`open_tabs` keys and `PersistedTab.host`; until then non-local
project archive and order are memory-only and a restored chip takes its host
from its row). The engine, the database's conflict handling and the sidebar,
History and ⌘K consumers do not change. Kept local-only: the Codex usage
meter, Reveal in Finder, and toolchain detection in Settings.

**Measured** with `templectl --watch --metrics` (`Scripts/bench-member-engine.py`)
on synthetic APFS clones shaped like ADR-027's (337 members, 164 with a log;
1,355 Claude and 2,761 Codex logs), one member written 4×/s and one outside
Codex log 2×/s, over 60 s, with the harness rejecting any run whose watcher
delivered no events:

| | upgrade (fields NULL) | filled |
|---|---|---|
| parses at startup | 164 | 0 |
| reads / locates / enumerations at startup | 164 / 2 / 1 | 164 / 2 / 1 |
| parses / reads / publications / enumerations while writing | 0 / 0 / 0 / 0 | 0 / 0 / 0 / 0 |
| open files | 12 | 12 |
| first engine publication | 0.02 s | 0.02 s |
| rows readable from SQLite | 0.01 s | 0.01 s |

Steady CPU while writing, in a release build: 0.61–0.72% of a core; the
engine before this decision, re-run on the same machine, used 0.55%. Synthetic stores, so not directly comparable with ADR-027's
real-store figures; they show the shape (no work per member write once filled),
not a benchmark result to quote.

---

## ADR-030 — Temple archives what nobody can resume any more
**Date:** 2026-10-05 · **Status:** Accepted; amends ADR-017 and ADR-029

ADR-029 kept every row that never resolved: 173 of Sri's 337 members had no
transcript on disk, most of them removed by Claude Code's retention cleanup,
the rest ids that never got a file. Each sat dimmed in the rail, could not be
resumed (`claude --resume <id>` answers "No conversation found"), and could
only be archived a click at a time. A session whose project folder was deleted
is the same: Temple will not launch an agent in a folder that is gone. ADR-017
said archive is something you do. It still is, with one addition: when the
CLI has already deleted the session, or the user the folder, Temple is
reacting to that, not initiating anything.

**Decisions.**

- **The proof is taken when the sweep decides, through the host seam.**
  The engine's `.confirmedAbsent` is a hint: it makes an idle row a
  candidate, arms a sweep and dims the row, and it may lag the truth by a
  sweep (accepted). Right before it writes, the sweep asks the owning host's
  `proveAbsent`: one call per host and agent for that sweep's hinted
  candidates, every agent for a row that never recorded one. Every host's
  proofs run at once, and each host's archives are written, in one
  transaction, as soon as its own proofs are in, so a slow host does not
  widen the accepted window for another.
- **What proves absence.** An id the proof says is missing from a listing
  that was exhaustive (ADR-032's rule) and quiescent: from before the
  listing to the change stream's latency after it, nothing happened that
  could make a file named for an asked id appear or change what the listing
  covers (`AbsenceProof.decide` has the table). Writes to other sessions'
  transcripts do not count, since FSEvents reports even an append as a
  creation and live sessions would otherwise starve the sweep. The proof is
  taken only for a store whose root, and every volume mounted inside it, is
  a local filesystem (`MNT_LOCAL`, and not NFS, SMB, AFP, WebDAV or FUSE).
  The window ends at a delivery barrier: a sentinel file made in a folder of
  Temple's own that the stream also watches, and the wait for its event.
  Within this Mac's per-host stream, on local volumes, event IDs increase in
  the order events enter the stream (Apple's FSEvents guide), so the
  sentinel's arrival means every event the stream already held has been
  delivered. That bounds delivery; it is not a completeness proof: a
  mutation that had not yet entered the stream when the sentinel did is not
  seen. (A flush alone is not even that barrier: measured, an event made
  just before `FSEventStreamFlushSync` arrives after it returns.)
- **What never proves absence.** A network volume, which changes behind
  this Mac's event stream. A notification that says the stream lost track
  (dropped events, a root changed, subdirectories to rescan, wrapped event
  IDs), wherever it points, the sentinel included: it invalidates every
  running proof and pending barrier and is never a barrier's evidence. A
  sentinel folder deleted or moved, which fails what relied on it and is
  replaced. No barrier, a stream stopped or re-armed, a dropped transport, a
  cancelled proof (up to its very last step), or an agent with no store
  configured on the host. A proof is for the memberships it was asked
  about: a leave and rejoin while it runs proves nothing about the rejoin.
  A proof that was not quiescent is tried again a bounded number of times
  (15 s, 1 min, 5 min), then left to the hourly sweep; sweeps run at launch,
  on hints (coalesced) and hourly. An unproven hint leaves the folder to
  decide.
- **The idle week bounds what is left.** Two kinds of residue are accepted:
  a file created in the gap after the window and before the write, and a
  mutation not yet in the stream when the sentinel landed. Both are bounded
  in practice by the seven-day idle guard (a session nobody has touched in a
  week is rarely being written to that second). There is no automatic
  un-archive (decided against); Undo or Restore brings the row back.
- **Only on proof, only what nobody is using.** A row is archived by Temple
  when its transcript is proven gone at decision time, or its owning host
  says its folder is `.missing`, and it is not pinned, has no tab open or restored, has had no
  Temple activity for seven days, and was not kept by a person. A failed,
  partial or cancelled listing, `unreadable`, `mismatch`, `incomplete`,
  `awaitingCreation` and a folder that is `unknown` prove nothing and archive
  nothing; a transport failure never does. A verdict is about one
  membership: each snapshot names the host and incarnation it read, and an
  absence proven for an earlier membership of an id says nothing about a
  rejoin. A store root that does not exist, Claude's or Codex's, is a failed
  listing, not an empty store (History still shows it as empty), and a
  folder or file gone under a root that is gone proves nothing even when
  its event arrives before the root's; so a row
  that names no agent stays unproven while either store is unavailable, and
  only its folder or a person can archive it. Soundness over coverage. A
  folder is `missing` only when its nearest existing ancestor, resolved
  through its symlinks, is on the filesystem the path should be on: under
  `/Volumes/<name>/` that is the volume mounted at exactly that point, so an
  unplugged drive, a leftover empty mount point and a symlink whose target
  is gone are all `unknown`. An unplugged drive is not a deleted project.
  The launcher asks the same question the same way (one implementation), so
  it no longer says such a folder "no longer exists"; the launch goes ahead
  and the wrapper's own `cd` decides.
  When both reasons hold, the transcript is the reason. Seven days is
  for the causes the cleanup is not (it removes only transcripts idle a month):
  an id that never got a file, a deletion, a transcript under another config
  dir. Nothing touched this week leaves on its own.
- **Recorded, and reversed by a person.** `v12-archive-provenance` adds
  `archive_reason` (NULL for the user's archive, `transcript_missing` or
  `folder_missing` for Temple's), `kept_at` and `archived_at` (stamped by every
  archive write, NULL for an archive from before it). The way back is the
  notice's Undo or Restore, as for any archive; a file that turns up again
  changes nothing, because a file is not a decision (ADR-017). Any unarchive a
  person performs stamps `kept_at`, and a kept row is left alone until
  activity that happened after that stamp (not activity from before it that
  is only written later), after which the idle week protects it: a Restore is
  never undone by the next sweep. Undo Import still removes a row Temple
  archived, which was not the user's decision, but not one a person restored
  since, which was (including an older build's restore, which leaves the
  reason on an unarchived row). The activity that spends a keep is dated
  when it happened, not when it was written.
- **Archived rows are not watched.** The engine's members are the rows that
  are not archived. Archiving one, by anyone, takes it out the way a leave
  does (facts and verdict revoked); restoring it brings it back the way a join
  does, freshly resolved. Watching what nobody can see, and whose files are
  gone, buys nothing.
- **Told once, undone from the notice.** One sweep is one line at the foot of
  the sidebar ("Archived 172 sessions whose transcripts are gone", or folders,
  or both) with Undo, merged if a second batch lands; it is not on the window's
  undo stack, because the sweep was not the user's action. The archive tags
  Temple's rows "No transcript" or "No folder" and says why.
- **The engine still never writes.** The sweep gathers folder evidence for the
  few rows that pass every other guard (no folder watching), then makes a pure
  plan over the rows as they are after that wait, the merged snapshot and that
  evidence, on the main actor a second after verdicts, memberships or rows
  change, at launch and when the app comes forward. The overlay writes it in
  one transaction under `id, host, incarnation`, and the SQL rechecks what
  another connection could have changed since: pinned, kept, archived, an
  open tab, the idle cutoff (by the same dates the plan reads) and, for a
  missing folder, that the row still names that folder. Only the app runs it:
  a model a test or a tool builds never sweeps.

**Amends ADR-017:** "archiving is something you do" gains "or something the
CLI or the user's own deletion did, which Temple records". **Amends ADR-029:**
"the rest are kept" becomes "the rest are kept until a completed enumeration
proves them gone and a week has passed; then they are archived, labelled, and
come back when a person restores them." The `v12-project-host` migration it
reserved is `v13-project-host`.

---

## ADR-031 — Archive is a scope of History
**Date:** 2026-10-05 · **Status:** Accepted; amends ADR-017 and ADR-028

After ADR-030, 173 of 337 members were archived, and the way back was a
separate ⌘⇧Y popup shaped like the sidebar, while History listed the same
sessions tagged "Archived" under In Temple. Two places to look for one lost
session, and an In Temple scope that was half put-away rows. The rule now:
the sidebar shows what is in play; History shows every session Temple or the
disk knows about, one status per row. If a session is not in the sidebar,
⌘Y and its name find it, and the row says why and what to do.

**Decisions.**

- **Archived is a scope, not a section or a sibling tab.** The control reads
  All · In Temple · Archived · Not in Temple. In Temple means in Temple and not
  archived (what the sidebar and ⌘K show), Archived means in Temple and put
  away (by the row's flag or its project's mask), and the three narrow scopes
  partition All, so the header says exactly that, "3,812 sessions · 164 in
  Temple · 173 archived", and nothing more: a condition (no transcript, no
  folder) is the row's tag and the sidebar notice's, not the header's. One
  list, one sort, one search, one selection model. A section
  at the foot would break chronology and grow without bound, which is why
  ADR-017 refused one in the sidebar; a sibling tab is the popup relocated.
  The popup is gone. ⌘⇧Y (View ▸ Archived Sessions, the launcher's Archived
  sessions) opens History in the Archived scope, leaving search and filters
  as they are; pressed there, it stays, like ⌘Y (until 2026-10-06 both went
  back; see ADR-028's amendment). It is no longer one of the
  mutually exclusive panels.
- **One status per row.** The fixed status column holds the relationship or
  the verb, never a condition: the gate mark (in Temple), **Restore**
  (archived), **Import** (outside). Conditions are a tag after the title, for
  any member: **No transcript**, **No folder**. The Restore tooltip states who
  archived it and why, then what Restore does.
- **Restore acts on one session.** History is a list of sessions, so archive
  is a per-session status, and the project mask survives as one named verb,
  **Restore project**. Restore on a session whose project is archived brings
  back that session only: in one transaction the mask is converted lazily
  into the row flag of every other member of that project not already
  archived (reason, date and keep cleared, pins untouched), then lifted. No
  migration, and nothing is rewritten for a project nobody touches; older
  builds read the result as they read any archive. A converted row's
  `archived_at` is NULL, because when the project was archived is not
  recorded. Opening an archived session (ADR-017's implicit unarchive) uses
  the same conversion, so opening one session of an archived project no
  longer floods the sidebar with the rest. Restore project lifts the mask and
  leaves every row's own flag as it is.
- **Undo of a Restore is exact.** A Restore records the archive columns of
  every row it touched (archived, reason, `archived_at`, `kept_at`) and Undo
  writes them back under the row's incarnation, and puts a lifted mask back
  on: a session Temple archived stays Temple's archive, with its reason and
  date, rather than becoming the user's. Restore names memberships, not
  ids: History hands over the membership each row showed (id, host,
  incarnation), Redo hands over the same ones again, and the write checks
  each. One that left and joined again in between is not the session
  restored, and is skipped with its project. The page says what the write
  did: the number actually restored, Undo only when this operation put a
  step on the undo stack, and "Nothing to restore; it changed since the list
  loaded." with no Undo when it restored nothing (Redo the same). Every
  person's restore stamps `kept_at` (ADR-030), including one that only
  lifted a mask.
- **An archived member's missing transcript needs a completed listing that
  found no file.** The engine does not watch archived rows (ADR-030), so for
  a user-archived member "No transcript" can only come from the catalog's
  completion, which names, per host and per completed agent (an agent it
  does not name proves nothing), every session id that agent's listing found
  a candidate file for (ADR-032's `.completed(candidates:)`), ids compared in
  the host's candidate spelling (`provesNoTranscript`). The member's
  transcript is missing only when its agent's listing completed and named no
  file for its id (every agent's, for an agentless row). A missing usable
  summary is not absence: a file that was unreadable, belonged to another
  session, or changed under the read is a candidate, and the row keeps Open.
  Another agent's file under the same id hides nothing, and an older read's
  evidence is replaced by the latest. A host that sends no completion (a
  failed or missing store, a lost transport, a cancelled read) proves
  nothing, and History drops a row it showed before only within a completed
  listing too. Folders come from the read's folder answers, asked for
  members' projects too.
- **The ways in.** The auto-archive notice gains **View**: History, Archived
  scope. It is two rows, the sentence ("3 sessions archived: no transcript
  on disk", "…: folder gone", "…: transcript or folder gone") with its
  dismiss, then View and Undo, so the sentence never shares a line with its
  verbs; it sits below the rail's list, never over it. View opens with an
  "Archived just now" chip that filters exactly the notice's
  memberships (cleared by its ×, any scope pick, or Esc, whose ladder is
  search, chip, selection, leave). The sidebar's project header and session
  row gain **Show in History**. A project filter on an archived project shows
  "raven is archived · Restore project". ⌘⌫ archives the selection when every
  row can be archived; Return on an all-archived selection restores it. The
  import sheet says a session bound for an archived project "will appear in
  History under Archived".
- **History is instant for members, and stays smooth at 10,000 rows.** "Look
  in History" only holds if History answers at once. Members, archived ones
  included, come from SQLite rows and are on the page before any file is
  read. The page's data outlives the tab: closing History clears its search,
  filters, selection and notices, and keeps the prepared rows, so reopening
  shows them at once and refreshes underneath. Everything that shapes the
  list (the membership union, noise, the chronology, counts, filtering,
  search, day grouping, and each row's text, tags and tooltips) runs in a
  projection off the main actor, fed immutable values, and keeps keyed rows,
  merging a batch into the chronology rather than sorting it all again. It
  publishes one coherent snapshot; the main actor installs it and checks the
  selection against its index, nothing else. A snapshot built for a query the
  page has moved past never lands. Catalog batches after a read's first are
  coalesced (about 100 ms). Each host's stream is consumed on its own, so a
  stalled host never holds up another; a host's lane waits only while the
  rows handed to the page and not yet projected are over their bound, so
  that backlog stays bounded and nothing is dropped. The hand-off from the
  source to a lane is not bounded: batches are small (200 summaries) and a
  10,000-row read is a few megabytes, so it is accepted rather than pushed
  back to the host. An unchanged projection publishes
  nothing; a new day, time zone or locale re-formats the page even when
  nothing else arrives. Every way into History (Show in History, the ⌘K
  bridge, which asks in All) clears the "Archived just now" chip.
- **Commands on the selection follow one rule.** A command (arrows, ⌘A,
  Return, ⌘⌫, Restore N, the selection's Import) goes to the model
  unconditionally, and acts only on the page that answers what was typed
  when it was given: newer input cancels it, and it does nothing where it
  does not apply. So typing then Return opens the first match, ⌘A then ⌘⌫
  after a filter archives what the filter shows, one Return opens one tab,
  and nothing acts on rows the user never saw. The protocol (when a command
  is recorded, what cancels it, how a replay stops) is a comment on
  `HistoryKeys.perform`, beside the code that keeps it.

  *Amended 2026-10-16:* which keys are commands depends on who has the
  keyboard. While a text field has it, History's search included, every key
  that edits or selects text is the field's: ⌘A, ⌘C, ⌘X, ⌘V, ⌘Z, ⌘⌫ and
  any arrow with ⇧. Typing a query and pressing ⌘A selected the rows, which
  the owner reported as a bug. From History's search, ↑ and ↓ (with ⌥ or ⌘
  too), Return, Esc, ⌘I, ⌘R and ⌘F still drive the page, and Tab gives the
  list the keyboard, as a click on a row does. So "⌘A then ⌘⌫ after a filter"
  is now from the list.
- **The page lays out by the pane it is given.** Its width is read from what
  the detail pane offers, never from the page's own content, and the page is
  clipped to it: a page that measured itself reported its overflow as its
  width, never compacted, and pushed the split view (and the sidebar) left.
  From 1000 pt the toolbar is one row; below, search has its own row with
  the scope control and the filter menus under it; below 692 pt the agent
  and project menus are one Filter menu. A row's fixed status column (where
  Restore is) always shows; its project column is a fixed width that
  truncates before the title, and is hidden below 600 pt.
- **Rows draw prepared.** A row looks nothing up when it draws, and the
  page observes History alone, not the app model; tab activity reaches it as
  a small map. The list stays a `LazyVStack`: the measured stalls were in
  the model, not the container.

**Amends ADR-017:** archived things "live only in the ⌘⇧Y archive browser"
becomes "are a scope of History"; "starting a session in an archived project
brings it back" becomes "opening a session brings back that session; Restore
project is the one verb that acts on many, and it is named". **Amends
ADR-028:** the scopes are All, In Temple, Archived and Not in Temple, and In
Temple excludes archived rows; History reads members from the database
before the disk, and keeps its rows when the tab closes.

---

## ADR-032 — History's catalog cache
**Date:** 2026-10-05 · **Status:** Accepted; amends ADR-029

History read every transcript on disk every time it was shown. On synthetic
stores shaped like real ones (about 280 KB per transcript, half Claude, half
Codex), a full read of 10,000 transcripts took 67–110 s and one of 2,000 took
14–23 s, and closing the tab threw the result away, so the next open paid it
again. ADR-029 had just retired `index-cache.json`, and for a good reason: the
sidebar drew from it, so a stale entry was a wrong sidebar, and SQLite had
become the launch path. A catalog cache had to be something that file was not.

**Decisions.**

- **The host source keeps what its catalog read.** `LocalSessionSource` owns a
  `CatalogSummaryCache`, as long-lived as the source (the app), so closing and
  reopening History, or refreshing it, parses only what changed. One entry per
  transcript the catalog read, keyed by agent, store root and normalized
  transcript path; each holds the summary and the stamp its read saw. A store
  root is its normalized path and the inode it resolves to *on its
  filesystem*: an inode number means nothing off its own volume, so within a
  run the device (`st_dev`) is part of it, and on disk, where device numbers
  are not stable across reboots, the volume's UUID is. A volume that reports
  no UUID has no identity that survives a relaunch, so its summaries are
  reused within the run and never written to disk. A moved store, or
  another volume mounted at the path, is another root, and drops everything
  kept for the old one.
- **A stamp is the whole validation, and it includes the change time.** Size,
  modification time and change time to the nanosecond, and the inode, from
  one `lstat` taken at lookup — not the listing's, which may be many batches
  old and only orders the read. An entry answers only for exactly that stamp.
  The change time is what makes this safe: it moves on every write,
  truncation, chmod or rename onto the path, and no ordinary process can set
  it, so a same-size rewrite that puts the old modification time back is
  still seen. Not the device, which is not stable across reboots on every
  volume (the store root's identity carries the filesystem). A transcript that is a symbolic link is never kept: its `lstat`
  describes the link, its read the target, so it is read every time.
- **Pick first, then look up; keep only what verified and read whole.** The
  catalog chooses each thread's file by member resolution's rule
  (`TranscriptCandidates`) before anything kept is consulted, so a new revert
  is read at once and an older rollout's entry stands in only when the rule
  picks it again. Only a read whose identity verified and whose stamps before
  and after agreed is kept, and only when every read its facts needed
  succeeded: the catalog's parse says what it came to (`CatalogParse`), and
  a summary missing its tail, its wider head or its stat is shown as it
  always was but read again next time, while a failed head keeps and shows
  nothing. An unreadable file, one that records another session's identity
  or none, and one whose head cannot be read show nothing, keep nothing and
  lose what was kept for them; they are read again every time, and never
  show their old summary or an older rollout. A file found missing loses
  nothing until a completed listing says it is gone (below). A verified file
  read whole whose bytes state no session (a Codex subagent rollout) is kept
  as such, a proven exclusion, so it is not reparsed; a failed read never
  becomes one.
- **Shared inputs are applied, never kept.** `TranscriptFormat.withShared` is
  the one way facts carry Codex's `history.jsonl` and `session_index.jsonl`
  fields, so an entry is kept without them and every use applies the current
  ones. Codex appends to `history.jsonl` on every prompt; keying entries on
  its signature would have reparsed every rollout after any Codex use. A
  shared-title change now costs no transcript read at all.
- **Absence needs completed coverage, in the catalog too.** A catalog ends
  with `.completed(candidates:)`, one mapping whose keys are the agents whose
  listing finished and whose every thread was decided, with the store root
  still there and still the same directory on the same filesystem when the
  read ends. An agent without a key proves nothing; there is no separate
  list of agents for a missing key to disagree with. A failed listing, a
  store root that is not there (ADR-030) or that went away or was replaced
  during the read, a cancelled read and a lost transport complete nothing.
  Nor does a listing that is not exhaustive. Browsing keeps its exclusions
  (Codex skips hidden entries; neither store follows a symbolic link to a
  directory), so what a listing lists cannot be the evidence; one
  conservative rule (`ListingAudit`), applied in the same pass to every entry
  either store's listing meets under its root, decides instead:

  | the listing met                                        | exhaustive |
  |--------------------------------------------------------|------------|
  | a plain directory or file                              | yes        |
  | `.DS_Store`                                            | yes        |
  | any other hidden entry (dot name or hidden flag)       | no         |
  | any symbolic link: to a file or a directory, hidden or not, dangling or not | no |
  | an error reading an entry's metadata, or metadata that does not say | no |
  | an error from the enumerator                           | no (the listing fails, as it did) |

  Scope: exactly the entries the candidate listing walks. Claude's walks the
  root's entries and the entries directly inside each project folder
  (transcripts are `<root>/<project>/<id>.jsonl`) and no deeper, so the links
  Claude Code itself keeps in `<project>/<session>/subagents/` decide
  nothing; Codex's walks everything under `sessions/`, to any depth.

  One rule for both of its consumers: History's per-read completion
  (`.completed(candidates:)`, below) and the absence proof ADR-030's sweep
  takes at decision time (`HostSessionSource.proveAbsent`). The engine's own
  completeness stays what it was (complete after a successful full listing);
  its `.confirmedAbsent` is a hint that dims a row and arms the sweep, and
  nothing destructive rests on it.

  A link's target is never inspected. Two review rounds found new holes in
  classifying what a hidden entry or a link could hold; this rule does not
  classify, and costs only completeness on stores that keep links or hidden
  entries under their roots, which then browse as before and prove nothing
  absent. The cache forgets a path, and History drops a
  row it showed before, only within completed coverage; until this, History
  pruned every row a read had not seen, so one failed store emptied that
  agent's history from the page.
- **No summary is not no transcript.** A completed read that shows nothing
  for a session has not shown the session has no transcript: the picked file
  may be unreadable, another session's, or changing under the read. So the
  completion also carries `candidates`: per completed agent, every session
  id the listing found a transcript file named for, whatever reading it came
  to. That a session has no transcript on a host is proven only by its id
  missing from the candidate set of an agent the completion covers
  (`CatalogBatch.provesNoTranscript`) — the one fact History may use to say
  an archived member has none. Ids on both sides are spelled by the agent's
  `candidateKey` (lowercased: Codex reads its UUIDs in any case, and a
  case-insensitive volume finds a Claude file in any case), so a spelling
  the agent would read as the same session never proves absence. Every
  host's catalog reports it; the contract suite checks unreadable and
  mismatched files are candidates, a mixed-case rollout is found in either
  case, and a removed file, after a completed listing, is not a candidate.
- **On disk: `history-catalog-cache.s<layout>-f<facts>.sqlite`, in the state
  directory.** The first History read after a relaunch takes every unchanged
  summary from it. This is safe where `index-cache.json` was not, for four
  reasons. It caches summaries of external transcripts for browsing and
  nothing else: the catalog is its only reader, and it holds no membership,
  never fills a row and never populates `session_state`; membership, member
  titles and archive state always come from current rows. Every entry is
  checked against the file's current stamp before use, exactly like one kept
  in memory, so a stale entry costs a parse, never a wrong row. It is
  disposable, without ever being deleted under someone: the installed app
  and a dev build share the state directory, so the name carries the table
  layout (`schemaVersion`) and the facts version
  (`TranscriptFormats.factsVersion`, which **moves with any change to what a
  format's facts produce**), and a build with other parsers uses its own
  file and never touches this one while it is in use. Any contention (a busy or locked
  database, a held transaction, a write that times out), or a file whose own
  record disagrees with its name makes the process keep its summaries in
  memory for the run, and leaves the file as it is. Only a file SQLite
  reports corrupt is deleted and rebuilt, and only while no other process
  has it open: every user holds a shared `flock` on `<file>.lock` while it
  has the file open, and the rebuild takes it exclusively without waiting,
  or does not happen. And it is written only with what a read changed, in
  one transaction when the read ends: an unchanged refresh writes nothing,
  and there is no timer (`index-cache.json` rewrote 2.2 MB every five
  seconds). It loads off the main thread while the stores are listed; a read
  waits for it at most once, under one deadline (2 s) for the whole read,
  ends the wait if it is cancelled, and a load that stalled once is not
  waited on again.
- **The seam carries the contract, not the cache.** Caching is host-internal;
  `HostSessionSource.catalog` states what any source's catalog must honour
  (pick before lookup, a kept summary only under the stamp it was read at,
  shared inputs applied fresh, `.completed` only for completed listings), and
  `withShared` and `factsVersion` live in `TempleCore/Formats` so a remote
  source caches the same way. The contract suite checks it against the local
  source and `FakeHostSource`, whose stamp carries a change counter as a
  remote host's `stat` would carry a change time.
- **Cold reads got cheaper too.** Parsers keep the last message's raw text and
  clean it once, not once per message; `cleanTitle` stops collapsing a long
  message once its capped result is decided; and lines are split on bytes,
  not by walking grapheme clusters. All three are byte-identical to before:
  the format golden file was re-recorded with the parsers as they stood
  before this change, with new long-Unicode fixtures, and randomized parity
  tests pin `cleanTitle` and the line splitter against the old code.

**Known limitations, kept:** a stamp cannot see a change made with the system
clock set back to the old change time (root only), or, on a filesystem that
reports no change time, a same-size rewrite within the modification time's
resolution. The first read after a relaunch still lists every store before it
shows anything (0.1 s at 2,000 transcripts, 0.4 s at 10,000); showing the
last snapshot at once is History's to do, not the catalog's. A corrupt file
that another Temple has open is not rebuilt: this process keeps memory only
for the run, and the next one alone with it rebuilds it. An older version's
database (lower layout or facts version, neither higher) is deleted, with its
journal files, when a newer build opens its own and can take that version's
lock exclusively without waiting (amended 2026-10-16; until then every old
file stayed, a few MB each). Its lock file is never deleted: unlinked, a lock
file a process had already opened and one created under the same name would
be two locks, each holder sure it was alone. A file an older build still has
open stays until a later launch finds it free. A downgraded build leaves a
newer version's cache untouched; going back to the newer build reuses that
cache, and it can then sweep the older ones.

**Measured** with a release-built harness calling `LocalSessionSource.catalog`
on the synthetic stores (`/private/tmp/history-perf`, one process per launch,
caches warm, ranges over three launches; "before" is the same harness on the
previous commit, whose every read is a full parse):

| | 2,000 transcripts | 10,000 transcripts |
|---|---|---|
| full read, before | 13.6–19.7 s | 67.2–104.0 s |
| first launch, cold (first batch / whole) | 0.12–0.15 s / 0.40–0.51 s | 0.42–0.67 s / 1.98–2.67 s |
| refresh, one transcript changed | 0.07 s, 1 parse | 0.36–0.38 s, 1 parse |
| refresh, nothing changed | 0.07 s, 0 parses | 0.34 s, 0 parses |
| relaunch, first read from disk (first batch / whole) | 0.10 s / 0.11 s, 0 parses | 0.43–0.44 s / 0.49–0.50 s, 0 parses |
| disk cache size | 1.3 MB | 6.5 MB |

## ADR-033 — An overlay panel owns the keyboard from the call that presents it
**Date:** 2026-10-05 · **Status:** Accepted

A hands-on UI test found that typing straight after `⌘K` split the keys
between History's search field and the palette. SwiftUI builds a panel's
field a turn or more after the chord, so for that interval the keyboard
belongs to whatever was focused underneath: History's search, a sidebar
field, or a terminal. The same gap let a key meant for the `⌘N` picker, or a
`⌘⌫` under the shortcuts card, reach a terminal.

**Decision: one invariant, focus ownership.** In the same call that presents
a panel (`⌘K`, the `⌘N` picker, the `⌘/` card), `OverlayFocus` records who
had the keyboard and makes an inert responder the first responder. The
panel's field takes the keyboard when it is ready (`PanelHostingView`
readiness, once per presentation token, counted only when it really holds
it); a click inside the current panel always may. While a panel holds the
keyboard, nothing else may take it: terminal surfaces refuse first
responder, and every terminal and field focus request goes through the
`OverlayKeyboard` gate in `TempleTerminalAPI` (the one UI concept the
terminal module knows). A request refused while held is kept, latest wins,
and made again on release only if nobody else has taken the keyboard since.
Dismissal restores by intent: where the panel's action sent focus, else the
recorded control. Modal windows (the `⌘O` chooser) get the keyboard because
panels are put away before they open.

**Rejected, each after two or three review rounds that kept finding new
cases:** holding keys typed before the field had focus and replaying them
(IME and dead keys, ordering, reentrancy, replay racing SwiftUI's state,
keys landing in a terminal if focus moved mid-replay); and classifying keys
with a deny list, then an allow list (each leaked chords such as `⌘⌫`,
`⌘←`, `⌘⇧F` to a terminal, and neither covered the interval before the panel
existed). Do not reintroduce either: a key never needs judging when the
terminal is simply not first responder.

**Consequence, accepted:** a key typed before the panel's field is ready is
dropped, never delivered elsewhere. Esc and Temple's own shortcuts still work
throughout, because menus and the key router act before a key reaches the
inert responder.

---

## ADR-034 — A `temple` command line for the sessions you have open
**Date:** 2026-10-13 · **Status:** Accepted; amended by ADR-036 (sessions close refuses a working session on a host, --force detaches; sessions new is this Mac only)

Temple's job is managing many Claude and Codex sessions at once: projects
scope them, each project holds its tabs, History keeps the rest, and nothing
is lost. The app is the only way in. This adds a command line over the
same model, so the sessions can be listed, found, opened and closed from any
terminal or script, and later by an agent. It adds no new concepts: project,
session, tab and History mean what they mean in the app.

**Shape: noun, then verb.**

```
temple projects ls                          # projects with an open tab
temple projects get <dir>

temple sessions ls [--project DIR] [--cli NAME]
temple sessions search <term> [--cli NAME]
temple sessions get <id>
temple sessions new [DIR] [--cli NAME]      # default: Settings' default
temple sessions open <id>                   # resume, or focus its tab
temple sessions close <id> [--force]

temple history ls [--project DIR] [--cli NAME]
temple history search <term> [--cli NAME]
temple history get <id>
```

**Two scopes.**

- **`sessions` and `projects` are what has a tab.** A session is listed when
  a tab holds it, a restored chip included (state `restored`), and a project
  when it has one. This is the tab strip, not the sidebar: a sidebar row
  without a tab (pinned, recent) is found through `history`. Chosen on
  purpose: the command line is for the work in hand, the way a browser's
  tab API lists tabs and leaves history to history. (Review proposed the
  sidebar's population instead; rejected for that reason, and noted here so
  the choice is not mistaken for an oversight.)
- **`history` is the app's History: every session**, open ones included,
  exactly what its All scope shows. It is the catalog of the agents' stores
  on disk joined with Temple's membership, not the database alone, so it
  finds sessions Temple never imported. The catalog's disk cache is shared
  between processes by design (ADR-032), so the command line reads it with
  Temple closed; a cold read is a full scan and can take seconds.

**Rules.**

- **History is read-only.** Every action is on `sessions`.
- **Only `sessions new` starts a fresh session.** Every other command acts on
  a session that already exists, and an unknown id is an error ("no open
  session has the id …" for the live verbs, which points to `history get`;
  "no session has the id …" for `open` and `history`).
- **`sessions open` is the app's Open: resume, or focus the tab.** It takes
  any id `history` shows. One that is not yet Temple's joins as opened; an
  archived one is restored on the way (ADR-017); one that cannot resume (no
  transcript, folder or CLI) is refused with the reason, and nothing changes.
  It is not "what Return does": Return on an archived row that cannot resume
  restores it without opening a tab, and `open` must never succeed without a
  tab to show for it.
- **Every command is an action the app already has, with the app's guards.**
  `close` on a running agent asks in the app; the command line cannot ask,
  so it refuses and names `--force`. A verb with no app equivalent does not
  belong here.
- **`ls`, `search` and `get` mean the same on every noun**, and all three
  take `--json`. `search` matches what the app's search matches (title,
  project, CLI), not transcript content.

**Identity.** `<id>` is the CLI's own session id (Claude's UUID, Codex's
thread id), the one its resume command takes. It is never a tab's UUID,
which lives only as long as the tab. Ids are host-local; every key in the
code already carries a host (`SessionKey`, `ProjectKey`, `HistoryKey`), so a
host qualifier can be added later without changing what a bare id means.
Until then an id that matches more than one session is refused, not guessed.
`<dir>` is resolved the way Temple stores project paths, so `/tmp/x` and
`/private/tmp/x` name one project.

**A session can exist before its id does.** Claude's id is minted at launch;
a Codex tab is provisional, with no id, until its rollout appears
(`SessionTab`, U4), which may be after its first turn. So `sessions new`
does not wait for one: it prints the id when it has one, and otherwise
reports the session as `pending` with no id (`"id": null` in JSON).
`sessions ls` lists a pending session the same way, and it is addressable by
id once Codex has written it. Nothing invents a placeholder id: an id the
CLI did not issue would be a promise the agent never made.

**`--cli`, not `--agent`.** The flag names the CLI Temple launches for the
session, and nothing else. Each alternative collided with something:
`--agent` with the agents that will call this command line (`--agent codex`,
run by Claude, reads as the caller); `--type` with every other way a session
will differ (background, subagent, proxied), which would all want it;
`--provider` and `--model` with proxied backends, where `claude` runs on a
non-Anthropic model (FEATURES roadmap), so the CLI, the provider and the
model are three different answers. A future harness is one more value
(`--cli gemini`), not a new flag. The values are `Agent`'s raw values
(`claude`, `codex`). Whether the app's own "Default agent" setting and
History's "Agent" filter are renamed to match is open.

**Transport.** `history` reads the catalog and the database itself, as
above. `sessions` and `projects` ask the running app, and say "Temple isn't
running" rather than print an empty list. The database does keep a copy of
the open tabs (`open_tabs`, for restoring them at launch), but it is not the
source: it never holds a provisional Codex tab (`TabPersistence`) or any
activity state, so a list built from it would disagree with the window.
Actions (`new`, `open`, `close`) go to the app, and the app stays the only
writer. `new` and `open` start Temple first when it is not running; `close`
does not, since a Temple that is not running has nothing open. The channel is a Unix socket under the state
directory, mode 0600, answered only for a peer running as this user, and
close-on-exec, so no agent Temple launches inherits it. The
server is `AppModel.startControlServer()`, called from `StartupRootView`
beside the archive sweep: that view is shared by both `TempleApp.swift`
files, so the `.app` and `make demo` cannot disagree (AGENTS.md, "Two entry
points"), and a model built by a test or a tool never opens a socket. Only
one process serves a state directory, decided by a lock (`control.sock.lock`,
held for as long as it listens), never by whether a connect succeeds: a busy
Temple's full accept queue refuses connections too. Only the holder creates
or removes the socket file, so a stale one is replaced exactly when its owner
is gone. The server stops when the quit drain begins, and from
`prepareForQuit` on the app refuses `new`, `open` and `close`.

**A new binary, not `templectl`.** `templectl` stays the developer harness it
is: `--import-all`, `--init-db`, `--watch --metrics` and the benchmark
control are refused outside a redirected state dir or exist for scripts in
`Scripts/`, and none of them belongs in a shipped command. The new `temple`
is a thin `main.swift` over `TempleCLIKit`, which links `TempleCore` and
`TempleUI`: History's catalog read and projection live in `TempleUI`, and
`HistoryReader` runs them without a page, so a session reads on the command
line exactly as the History tab shows it. Moving them to `TempleCore` would
be the cleaner boundary; it was not worth the churn for one caller. SwiftPM's
app product is renamed `temple-app` (`make run`, `make demo`). In the `.app` the binary cannot sit
beside `Contents/MacOS/Temple`, because the volume is case-insensitive; it
gets a directory of its own (`Contents/Helpers/temple`) and reaches the PATH
through the Homebrew cask's `binary` stanza.

**Rejected.**

- **`temple [dir]`, like `code .`.** For a folder Temple has never seen it
  could only do what `⌘O` does, start a session, so one command would focus
  a tab or launch an agent (with the default
  `--dangerously-skip-permissions`) depending on state the terminal cannot
  see. `⌘O` gets away with it because a person chose the folder in a
  chooser.
- **Flat verbs (`temple ls`, `temple open`).** `ls` had to mean projects and
  sessions at once, and listing only projects had no spelling.

**Deferred.** Agent-facing verbs (`whoami` from an injected session id,
`wait` on a session's activity state, notifying for the caller's own tab),
which depend on that state being accurate first. Sending input into a
session's terminal, which is the one verb here that reaches inside a session
rather than managing it; Chrome gates the equivalent (`execute javascript`,
CDP attach) separately from tab management, and so should this.

**As built.**

- `new` and `open` start Temple only when no Temple is running at all, and
  only the app the binary ships in (`…/Temple.app/Contents/Helpers/temple`,
  through any symlink), as a new instance of that bundle: LaunchServices
  asked to open a bundle id that is running activates the running copy. A
  Temple that runs but does not answer (an older version, most likely) is
  reported after a few seconds' grace, never joined by a second instance.
  Never for a redirected state directory; a dev build starts nothing. Both
  commands bring the window forward; a snapshot run (`TEMPLE_SNAPSHOT_DIR`)
  does not.
- `open` focuses a session that has a tab, as clicking its chip does.
  Everything else is judged by History's rule for its id
  (`HistoryProjector.rows(member:disk:…)`, the function the History page
  itself uses), so the command line has no resume rule of its own. The slow
  part comes first: `HistoryReader.lookup` reads the catalog and returns what
  it says about the id, without a verdict. Then, in one synchronous
  main-actor turn, the id's rows are built against membership, archived
  projects and tabs as they are at that moment, and the open acts on that
  verdict or refuses with its reason. Nothing that changes during the read
  can be missed, because nothing is judged until it ends. More than one row
  is ambiguous; a store that failed to read makes "not found" a refusal with
  the store's error, since it proves nothing. The read can take seconds
  cold; the command waits up to two minutes.
- Every action (`new`, `open`, `close`) claims the request's
  `ControlCommit` in the same turn as its change; the server's deadline (150
  seconds) claims it before answering "did not answer in time, and changed
  nothing". One wins, so that answer is always true. A request that
  committed and still has not answered ten seconds after its deadline is
  told "Temple acted but did not finish answering", never "changed nothing".
- The server keeps every connection on one serial queue, each descriptor
  owned by a `DispatchIO`, which closes it exactly once after its last
  operation: no path closes a number another may still use. Requests and
  answers each have a five-second transfer deadline, and more than 32
  connections at once are closed unanswered. Network.framework was the other
  candidate; it would have dropped the peer-uid check and any say over
  close-on-exec. Close-on-exec is set right after `socket`/`accept` (Darwin
  has no atomic form for sockets), so an agent forked in that instant can
  inherit one descriptor; ownership is the lock, not the socket, so even
  then a restarted Temple serves.
- `sessions search` is ⌘K's ranking (`SessionRowSearch`) over the open
  sessions with rows, then any tab without one whose title has the term.
  `history search` is History's own match: title, folder, branch, last
  message, or an id prefix.
- Text output is a table, `*` marking the tab or project on screen; `--json`
  is camelCase, dates ISO 8601, and a pending session's `id` is `null`. Exit
  status: 0 done, 1 failed or refused (the message on stderr), 2 usage.
- Requests and responses both carry the protocol version, read before
  anything else; any other version is refused in either direction, not
  guessed at. Old versions, when there are any, get adapters on purpose.

## ADR-035 — The usage meter keeps the token it read
**Date:** 2026-10-15 · **Status:** Accepted (amends ADR-022)

ADR-022 assumed one "Always Allow" on the refresh control would make every
later poll silent. usage.log says it does not last. Every mid-run loss of
access (2026-10-02 09:38 and 17:35, 10-05 17:02) came within minutes of the
token's own expiry, which is when Claude Code refreshes it and rewrites the
item through `/usr/bin/security`; after the rewrite Temple is off the
item's access list and `security`, the writer, is still on it. Every launch
after a rewrite starts the same way. And each click cost two dialogs: the
click's read was allowed (a one-time "Allow" is spent by that read), the
next poll seconds later read the Keychain again and was refused, and the
user clicked again.

**Decisions.**

- **Unattended polls reuse the token the last lookup found** until it is
  within five minutes of its own expiry or the endpoint says 401. A 401 on a
  reused token reads the store at once (the CLI has usually refreshed it);
  a token the store still holds after a 401 is not sent again, and a refused
  token is never kept, so a new sign-in is still seen by the next poll. The
  token lives in memory only, and is never logged.
- **A token with no recorded expiry is kept for an hour at most.** Claude
  Code always writes one; without it nothing else says the token went
  stale, and an hour bounds how long an account change can go unseen by the
  polls, at the cost of one Keychain read an hour.
- **The click never reuses, and replaces what was kept.** It is the user
  asking for now, and a new sign-in must not wait out the old token's
  lifetime. What it reads is kept; a click that reads nothing (denied, no
  credentials) leaves nothing kept, so a token from before an account change
  does not carry on in the polls behind a click that could not find the new
  one.

What this does not fix: Claude Code's rewrite still drops Temple from the
item, so after a token refresh the next read can still need a prompt. It
now needs one at most once per refresh, not twice per click, and not on
every poll after a one-time "Allow". Why the rewrite drops Temple is not
established: Apple's `security` source calls `SecKeychainItemSetAccess` on
`add-generic-password -U` only when `-T` or `-A` is given, and Claude Code
passes neither. The timing in the log is the evidence.

**Considered and rejected: reading through `/usr/bin/security` where the
item already trusts it.** The item always trusts the tool that writes it,
so running `security find-generic-password -w` when the access list let it
decrypt and the keychain was unlocked would have read without Temple
needing a grant. Two reasons against, from review:

- It cannot be made prompt-free. The access-list and lock checks and the
  child's read are separate operations; the keychain can lock or the item
  be rewritten between them, and the process-wide interaction switch that
  keeps Temple's own reads silent does not reach into the child — so an
  unattended poll could still raise a dialog, attributed to `security`,
  and a deadline only bounds how long Temple waits once it is up. (Also
  found: matching trusted applications by path drops the code requirement
  the entry actually stores.)
- It sidesteps the user's choice. A Keychain approval is consent given to
  the app that asks; reading through the tool Claude Code trusted for
  itself takes the secret without that consent. Temple reads with its own
  identity, silently where it has been allowed, and asks only on the click.

---

## ADR-036 — Sessions on another machine, through the user's own ssh
**Date:** 2026-10-16 · **Status:** Accepted; amends ADR-010, ADR-029 and ADR-034; revised 2026-10-18 (close a wrong link as any tab, with no undo; Discard never stops; Remove asks; the launch notice after a quit); shipped in v0.6.0; revised 2026-10-26 after the remote audit (a restored chip's close asks; an archived active tab restores inert; the command line's open reconnects; notices take turns; ⌘T keeps the tmux rule). Detail, review history and the as-built notes: [designs/remote-ssh.md](./designs/remote-ssh.md)

The owner's goal, verbatim: "I have a remote machine that runs Claude and
Codex. I want to connect to it and run from that machine." What matters is
creating and working in sessions on a host, and reopening the ones Temple
created there; finding sessions Temple did not start is not a requirement.
The hosts are Linux boxes behind `~/.ssh/config` aliases. Remote is an
experiment: everything it adds must be deletable without touching core
rows ("Removing remote", below).

**Decisions.**

- **The user's own ssh, never a credential.** A tab runs the user's `ssh`
  with a PTY. Every other question to the host is a short non-interactive
  query (`BatchMode`, a deadline). Only a tab or Test connection creates a
  ControlMaster. An ordinary query (`.query`) rides the master when one is
  up and otherwise makes its own `BatchMode` connection, which can never
  ask anything; a query that must use the exact connection a tab was
  planned on (`.overMaster`: staging a launch, the Test connection's checks)
  rides that master or fails, and never connects on its own. The master's
  socket lives under the state directory, keyed by the state directory and
  the connection as `ssh -G` resolves it. Temple never sends `-O exit`;
  masters expire through `ControlPersist`.
  Hosts come from `~/.ssh/config` (read-only, enabled per alias) or are
  added in Settings as `-o` options on the command line, never a generated
  config file (`-F` would drop the system config). Temple never writes ssh
  config, and never passes a password, `-i`, `StrictHostKeyChecking`,
  `UserKnownHostsFile` or `IdentitiesOnly`; an identity file is a path the
  user typed. Test connection is a terminal sheet where ssh asks what it
  asks, then checks by execution: `claude`, `codex`, the exact tmux chain
  the launch sends (run detached, on a throwaway socket), and logind's
  `KillUserProcesses`. An attached client under Temple's `TERM` is proven
  by the Linux acceptance, not by the sheet. Every command line is
  a short fixed bootstrap; programs travel on stdin and launches are staged
  on the host first (macOS ssh's mux fails requests near multiples of
  8 KiB).
- **One remote environment.** One bounded query reads the login shell's
  `PATH`, `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, framed so rc output is
  discarded; the probe, the launch, tmux, the pane and every transcript
  read use it, and the pane is told each value explicitly. The login
  environment is cached in memory per connection and never persisted;
  what a pane actually ran with (its config root, its Codex home) is run
  evidence and is persisted with the run.
- **The keep-alive is a hidden tmux server of Temple's own, `tmux -L
  temple`.** tmux 3.2 or newer; configured in the same command queue that
  creates the session, with `-f /dev/null`: no status line, no prefix,
  mouse on, 50,000 lines of history. The first open of a run creates its
  session (`new-session`, never `-A`); every later open only attaches. The
  pane enters the folder, records `ok` with its canonical folder (`pwd -P`),
  its pid and start time and the server it runs on, then `exec`s the agent,
  so evidence comes only from a created pane and pins the server every
  later query asks. Temple never touches the user's own tmux server, never
  `kill-server`s its own, and `kill-session`s only a name built from one of
  its handles. Scrollback belongs to tmux: the wheel scrolls tmux's
  history, the first key returns to the prompt, and `⌘F` stays libghostty's
  (ADR-016) over what the tab has shown since it connected, as the find bar
  says. shpool is the runner-up behind the module's `KeepAlive` protocol.
- **The row is still the session; the run is remote-only.** A run is one
  agent process under one tmux session, keyed by a handle Temple mints,
  in remote-owned storage. A Claude run joins its row before it spawns
  (Temple mints the id, ADR-008). Nothing remote-specific enters
  `session_state`: the row id stays the CLI's id, and `host` (ADR-029) is
  the only host-aware column.
- **Only a positive absence ends a run.** Liveness is `has-session` on the
  pinned socket. Only tmux's own `can't find session: <name>` for that name
  is absence; no server, a missing socket, a transport failure or a deadline
  are unknown. From unknown every open only attaches, and the way out is an
  explicit button, **Resume anyway** (or **Start a new session** for a Codex
  session with no id yet), whose copy says the original may still be
  running and how to stop it on the host. Repairing a lost socket is
  deferred until it is seen in practice.
- **Close means what it means locally; nothing is stopped later.** The
  tab's activity gate decides, as for a local tab, plus an early rest rule
  for tabs on a host only (⌘W and the CLI take a running tab there as at
  rest when its agent has received nothing since it started and its title
  is quiet; a local tab keeps the settle timer's reading, as before
  remote). Idle: Stop, at once and without a
  prompt. Working: "<agent> is running on <host>." with Detach (the
  default), Stop and Cancel. To stop, Temple first ends its own tmux client
  on this Mac (the tab's ssh) and waits briefly for the session's attached
  count to reach zero; then one tmux command queue on the host checks that
  the session exists and that no client is attached, and kills it in the
  same queue, or prints `temple-not-killed`. A successful answer without
  the marker is the end evidence; the marker means another terminal is
  attached; no answer means unconfirmed. A stop Temple could not carry out
  and confirm at that moment leaves the session **left running**: the tab
  closes with one notice (an explicit Stop from the working prompt keeps
  the tab, saying why in its band, until it is closed again), the reason
  is on the run, and a row waits in
  **Running sessions on <host>**
  with Open (or Show tab) and Stop, and Dismiss on a flagged row (it clears
  the flag; the session keeps running either way); the sidebar's "N
  sessions you closed are still running on <host>." line shows once per
  flag, one line at a time: a line that arrives while another shows (a
  second host answering at launch) waits its turn, and a line, shown or
  waiting, counts a run no more once its stop is confirmed (a line left
  with nothing goes). Stopping a working agent from that sheet or a row's menu asks
  first; one waiting for input stops at once. There is no deferred
  stop, sweep, lock or retry: two review rounds found that any kill decided
  after the fact needs idle evidence Temple cannot get remotely. Temple
  never stops anything without a live user action.
- **Quit stops nothing on a host and never waits on one.** The question in
  `windowShouldClose` counts local working agents ("An agent on this Mac
  is still working.") and adds "Sessions on <host> keep running; their tabs
  reconnect when you open them next launch." Inside the existing
  3 s drain every live client of a tab on a host is detached (no exit
  input, which tmux would deliver to the agent), working or idle (owner,
  round 2: an idle stop at quit could only be decided from the settle
  timer's reading, which can take a long, quiet tool call for idle). Every
  run, pending Codex ones included, is left as it is and comes back as a
  tab next launch, where closing it stops it: a chip not yet opened that
  run, of a session whose run is not Ended, asks first ("may still be
  working", since nothing has said), Detach leaving the run and Stop
  stopping it by row with no client attached; the command line refuses
  such a chip without `--force`, which removes the chip and stops nothing
  (revised 2026-10-26: closing the chip had removed it and left the run
  running, unlisted until the next launch). That stop, its lookup of the
  run included, is one owned stop from the moment it is asked for, so a
  quit lets it run inside its window. A creation the quit (or a Detach)
  catches before its launch reached the host is recorded failed, and one
  that may have run unproven, as a Cancel or Stop records it, so the next
  open creates again or attaches, never attaches for good to a session
  that never existed. Each run whose tab was
  connected is flagged `detached at quit` (a left-running reason in the
  remote store, no migration), so the next launch says once, for a host
  that answers, how many sessions from before the quit still run there and
  are not open in a tab (cleared by attaching, Running sessions… or ×). Only a stop a close started
  before the quit runs inside the window; one unacknowledged at the
  deadline is left running (`quit deadline`). Remote store writes share
  the engine barrier's 2 s. So agents on hosts outlive Temple, by design.
- **Temple never discovers or stops a session it did not start.**
  Sessions on <host> lists the runs Temple tracks, each asked about on its
  own pinned server; the private server is never listed. There is no remote
  catalog: History's on-disk lane lists nothing for a host, and nothing on
  a host can be imported.
- **Codex identity: the pane's own process, else the user's word.** Codex
  mints its id, so a new Codex session on a host is pending (a tab or a chip,
  reopenable and restorable by handle, never a fabricated row) until
  identified. Temple adopts on its own only when the process the launch
  `exec`ed (pid and start time verified, tmux's `#{pane_pid}` agreeing)
  holds exactly one rollout open for writing under the run's Codex home,
  whose header id is its file name's and whose `cwd` is the run's folder.
  Any other writer (a child, a launcher's native binary, Codex's shared app
  server, which writes every rollout by default) proves nothing. Then the
  candidates by folder and time on the host's clock decide. Exactly one,
  for a connected tab that was typed into and never asked about: Temple
  says yes on its own (owner, round 2), through the yes's exact path
  (`confirm`, a claim `how: .automatic`, the same recheck, uniqueness and
  core join; a run that ended meanwhile concludes as a yes does). The only
  addition is a display-only note in the tab, "Linked this tab to
  “<first prompt>”, the only Codex session started in this folder since
  the tab opened.", and a wrong one is closed as any tab is (owner's
  decision, 2026-10-18: no undo in the tab; the row, a real session on the
  host, stays until a person archives it; feedback decides whether an undo
  returns). "Asked" is the question shown this launch, or any declined
  candidate for the run, which the claim's own transaction checks, so a
  decline holds across relaunches. Nor while another new Codex session
  Temple started on the host in the same folder is still unidentified and
  running (its window overlaps; the lone candidate may be the other's; a
  folder not yet resolved counts as the same, resolved ones compare by
  bytes), checked again in the claim's transaction over every run on the
  host.
  Two or more, an ended tab, or once asked: the tab asks, **Yes, that's it** or **Not this one**, declined
  ones never offered again. A
  claim is unique per host before the core join, and core's refusal
  (`hostConflict`, `agentConflict`) is shown. Temple passes no
  `--no-daemon` (AGENTS.md: no opinion on how a CLI runs); the Hosts card
  says that with it in Codex's arguments, Temple identifies the session on
  its own.
  A host without `/proc` is question-only. A pending session's own
  lifecycle: closing it while idle checks its identity once more, then
  stops it; identified, the tab closes (at once, while the stop is still
  out: it never becomes a resumable tab a save, or the quit's, could
  restore and resume after the stop); unidentified and typed into, the
  tab stays with "Codex ended on <host> before Temple learned which session
  this was." and
  the question, **Start a new session here** and **Remove from Temple**
  (Discard: one meaning, a session that is not running; it never stops
  anything, and its link says whether the row is removed or archived);
  never typed into,
  Temple stops tracking it. Quit treats pending runs like any: detached,
  left running, back as chips next launch. A saved tab whose row is
  archived (a link to an archived row keeps the archive) restores inert
  even when it was the active one: the launch opens it for nobody, since
  an open is what brings an archived row back. Saying yes to an ended session
  records which session it was and closes the tab, as a local exit does;
  its row is the way back, and nothing launches until asked.
  Claims are made unique per host by a partial unique index on claimed
  runs (`runs_claim`), so a session's later resumes may share its id.
- **Enrichment by known id; a transport failure is never absence.**
  `RemoteSessionSource` locates a row's transcript by id under the root its
  latest run's pane recorded (the login environment's for a row with no
  run), and reads it framed and budgeted, through the engine and
  `FactPersister` like any host. Its listing is never complete, it has no
  change stream, folder evidence is unknown, `proveAbsent` is unproven,
  `adopt` is inconclusive (identity is the run store's) and `catalog` is not
  offered. After three transport failures a breaker spawns nothing for ten
  minutes; an explicit open gets through once. So a remote row is never
  `confirmedAbsent`, dimmed, tagged "No transcript" or archived by Temple
  (ADR-030 applies unchanged and never fires); only a person archives one.
- **Paths: byte-exact at the remote boundaries, `String` in core.** Every
  comparison of remote paths in `TempleRemoteHost` (roots, listed files,
  hints and their stats, store containment, Codex homes, the identity
  check's folders, declined and seen rollouts, suggestions) is on
  `RemotePath`, equal by UTF-8 bytes, because a Linux host keeps
  precomposed and decomposed spellings apart. Fields stored as text in the
  run store keep their bytes and are compared as `RemotePath` when read. Core's `TranscriptLocator` and `TranscriptCandidates.assign` keep
  `String` equality: APFS folds the spellings (measured), and locally one
  file reaches core from enumeration, FSEvents and stored hints, where byte
  equality would split it. On a host the residue is one candidate where a
  session's file sits in two spellings of a folder neither agent writes
  (Claude's folder names are ASCII); it is read by its own bytes and
  identity verification decides, so the cost is at most a missed fill.
- **remote-state.sqlite, and no core schema change.** `TempleRemoteHost`
  owns `remote-state.sqlite` in the state directory, with its own migrator
  (`r1-runs` to `r5-input`): `runs`, `declined_candidates`,
  `remote_project_state` (a host's project archive and order). A run
  persists its evidence: the pane's folder, pid and start time, the pinned
  socket path and server, the config root and Codex home it ran with. The
  host list is the user layer, `temple.settings.remoteHosts`, through
  `TempleState.settingsDefaults`. Memory only: test results, the login
  environment, `ssh -G` resolutions and the breaker. On this Mac the
  masters' socket files live in `<state dir>/ssh/` (or a short fallback
  under `$TMPDIR` or `/tmp`). On a host Temple writes `~/.temple/launch/`
  (records and staged launches, checked private before every use), the
  `-L temple` socket, and short-lived `umask 077` temporary files under
  `$TMPDIR` for the environment query and transcript reads
  (`temple-env.*`, `temple-read.*`, removed on exit); Test connection's
  tmux check uses a throwaway socket it kills. Core migrations
  still end at `v12-archive-provenance`. A restored tab's host is its row's
  host (ids are globally unique), a pending Codex tab restores from `runs`,
  and `open_tabs` positions are numbered per path across hosts, so
  `v13-project-host` is not needed: it stays reserved and unused. The two
  files are not one transaction; a remote archive mask left out of step by
  a crash is rewritten by the next Restore or Undo (accepted).
- **One module, one import, no flag.** `TempleUI` imports
  `TempleRemoteHost` only in `Sources/TempleUI/Hosts/RemoteHost.swift`
  (`ModuleBoundaryTests`), and the remote tab logic is
  `RemoteTabController`, behind thin seams in `OpenSessionsModel`. Remote
  is invisible until a host is enabled (owner, round 2; the
  `temple.feature.remoteHosts` flag it replaced is ignored): with none the
  registry holds this Mac only, no ssh config is read until Settings'
  Hosts card is shown, nothing is spawned, no remote store is created, and
  no remote UI appears but that card. Remote UI appears for an enabled host
  only, and nothing remote changes a local tab's behaviour or looks.

**Amends ADR-010 for remote hosts:** *an agent on another machine is not
Temple's child process. Closing its tab still ends it when it is idle, as
locally; an agent that is working is detached, not killed, unless the user
chooses Stop; and an end Temple could not carry out and confirm at that
moment is recorded as left running and listed for the user, never performed
later on Temple's own initiative; quitting Temple stops no agent there,
working or idle.* The tab's ssh is a tmux client, and its exit proves
nothing about the agent. "Quit never orphans an agent" holds for this Mac
only.

**Amends ADR-029:** its "What remote needs" no longer includes
`v13-project-host`; the interim rule that a restored chip takes its host from
its row is the rule; a host's project archive and order persist in the
remote store, not in memory. The ssh launcher does relay the folder: the
pane's `ok` record is its `.directoryEstablished`, `tab`-sourced and
replacing what was there, so the pane's folder takes precedence. A
transcript on the host may still fill a row whose directory is NULL (an
imported row, or one from before its first pane report), through
`FactPersister` like any host's fill.

**Amends ADR-034:** `temple sessions close` on a session working on a host
is refused; `--force` detaches it and never stops it. `sessions new` starts
sessions on this Mac only; the command line lists, opens and closes remote
rows because it reads rows.

**Removing remote.** Code: the `TempleRemoteHost` module,
`Hosts/RemoteHost.swift`, the Hosts card and its Test connection sheet, the
host rows in `⌘N` and the launcher, `RemoteTabController`.
Storage: `remote-state.sqlite`, the `temple.settings.remoteHosts` key, and
the socket files in `<state dir>/ssh/` and the fallbacks for a long path,
`$TMPDIR/temple-ssh-<uid>/` and `/tmp/temple-ssh-<uid>/` (masters expire on
their own). Agents still on a
host are not stopped by removing anything, and must not be stopped silently:
Running sessions on <host> before an uninstall, per session Stop; or on the
host, `tmux -L temple ls`, `tmux -L temple kill-session -t temple-<handle>`,
`tmux -L temple attach -t temple-<handle>`. Core rows a user keeps stay
(History's In Temple, search, rename, archive) and open to "<name> is not
in Temple's hosts, so this session can't open. Add the host in Settings."
Removing a host asks first when sessions Temple started still run there:
leave them running (out of Temple's reach until the host is added again)
or stop them, then remove; a stop that fails keeps the host. `open_tabs` and `project_state` never changed, so nothing
migrates back. What stays in core by design: `host` in `session_state`,
`HostID`, `ProjectKey`, and the `HostSessionSource`/`HostLauncher` seams.

**Out of v1, said so:** a host without tmux 3.2 (Test connection says so,
and, one rule everywhere, it leaves the launcher and ⌘N, is greyed in the
`+` menu, the folder sheet won't start and ⌘T starts nothing there); tmux before 3.3 has no OSC 52 passthrough and
no colour reports (Codex there uses its default palette); importing or
listing sessions Temple did not start; per-host arguments (Settings'
arguments apply on hosts too, `--dangerously-skip-permissions` included, as
the Hosts card says); the usage meter and Reveal in Finder; routing `⌘F` to
tmux; non-Linux hosts beyond a tested BSD fallback. Known gaps: Claude on a host must be logged in there (the per-box status
is the design doc's acceptance checklist, optional coverage, not a gate);
every unarchived remote row with a transcript costs one read at startup.

**Rejected:** sshfs (ADR-030 cannot prove anything on a network volume), a
bundled ssh library, a generated ssh config, a Temple-shipped helper daemon,
dtach and abduco (no screen on reattach), mosh, and screen; adopting a Codex
rollout by folder and time, or by uniqueness of a match, without saying so
(Temple's own yes to a lone candidate is said in the tab);
deferred stops of any kind; stopping anything at quit; listing the private server's sessions as "Not in Temple";
`open_tabs.host`; Temple passing `--no-daemon`; a byte-exact core locator.

---

## ADR-037 — Keyboard shortcuts follow the Mac apps people come from
**Date:** 2026-10-19 · **Status:** Accepted

Temple is for developers, so its keys should be the best of the two places
they come from: the browser (Chrome) and the editor (Cursor, VS Code). An
audit of every binding against Safari, Chrome, Terminal, Xcode, Finder,
Cursor, VS Code and Ghostty (`ghostty +list-keybinds --default`, the terminal Temple
is built on) found Temple alone in using `⌘⇧[` / `⌘⇧]` for something other
than tabs, with no key at all that steps through tabs in order. The keys a
user leans on daily (`⌃⇥`, `⌘P`, `⌘T`, `⌘W`, `⌘⇧T`, `⌘K`) already matched
and are unchanged.

**Decisions.**

- **`⌥` means "the other agent".** `⌥⌘T` starts the non-default agent in
  the active project, `⌥⌘N` opens the picker for it (was `⌘⇧N`). `⌘⇧T` is
  Reopen Closed Tab in every browser, so the T variant could only take `⌥`,
  and one modifier for one idea beats `⇧` on N and `⌥` on T. `⌥` is also
  macOS's own alternate-command modifier (`⌥⌘W` Close All, `⌥⌘H` Hide
  Others). With no active project, `⌥⌘T` opens that picker: `⌘T` falls back
  to the launcher, which starts only the default agent.
- **`⌘⇧[` / `⌘⇧]` step through tabs**, the strip's chips in the order shown,
  wrapping; projects move to `⌥⌘[` / `⌥⌘]`. `⌃⇥` stays the most-recent
  switcher (VS Code's reading of it), so tabs have both an order key and a
  recency key.
- **`⌘9` is the last session tab**, as in Safari, Chrome and Ghostty;
  `⌘1`–`⌘8` are positional. Both count the active project's session tabs
  only, as before; the bracket walk includes History and Settings, because
  it follows the strip as drawn.
- **`⌘⇧P` also opens the palette**, Cursor's and VS Code's command palette
  key, beside `⌘K`. `⌘P` stays the project switcher, the editors' "go to"
  key. It is not Print: Temple has nothing to print.
- **Every global binding checks `⌃` and `⌥` itself.** `charactersIgnoringModifiers`
  drops both, so the key monitor answered `⌃⌘F` (the system's Enter Full
  Screen) with the terminal's find bar, and would have answered `⌥⌘T` as
  `⌘T`; `⌃⇥` likewise answered `⌃⌥⇥` and `⌃⌘⇥`. No `⌃⌘` chord is
  Temple's; the only `⌥⌘` chords are the ones above. A switcher that is
  up owns every key until it closes, which is focus, not a binding.
  Caps lock without `⇧` is the plain key. The bracket chords match the
  character the layout gives, as the menu's key equivalents do, not the US
  key position (on a German layout that key is `+`).

**The agents' keys come first.** Audited 2026-10-19 against Claude Code
2.1.304 ([interactive mode](https://code.claude.com/docs/en/interactive-mode),
[keybindings](https://code.claude.com/docs/en/keybindings),
[fullscreen](https://code.claude.com/docs/en/fullscreen#clear-the-conversation))
and Codex 0.163.0 (built-in defaults in
[`codex-rs/tui/src/keymap.rs` at 0910087](https://github.com/openai/codex/blob/0910087/codex-rs/tui/src/keymap.rs)).
By default they bind `⌃` letters (`⌃R` history search, `⌃T`, `⌃O`, `⌃G`, `⌃L`,
`⌃K` / `⌃Y` kill and yank, `⌃B`, `⌃S`, `⌃/`, `⌃]`), plain `⌥` (Claude Code
`⌥P` model, `⌥T` thinking, `⌥O` fast mode; Codex `⌥R`, `⌥,` / `⌥.` effort,
`⌥B` / `⌥F` / `⌥D` words), Esc and Esc Esc, `⇧⇥` (Claude Code's permission
modes) and `F2`, `F3`, `F4`, `F8`, `F9` (Codex). Their only `⌘` keys are `⌘K` (Claude Code:
clear, the same as `⌃L`), `⌘C` / `⌘V`, and `⌘←` / `⌘→` / `⌘⌫` (Codex; the
terminal turns those into `⌃A` / `⌃E` / `⌃U`, which both honor). Neither
binds `⌃⇥`. So while a terminal has the keyboard Temple's global shortcuts
are `⌘` chords and `⌃⇥` / `⌃⇧⇥`, and nothing else. That avoids every
audited default except one deliberate override: `⌘K` stays the palette, and
inside an agent `⌃L` does the job (Claude Code: a full redraw keeping input
and conversation; Codex: `clear_terminal`). It cannot rule out a clash
with a default added later, or a user's own `cmd` binding in Claude Code's
`keybindings.json` (honored only where the terminal reports ⌘); keeping
Temple off plain `⌃` and `⌥` keeps that surface to `⌘`.

**The left `⌥` is Meta.** Temple's terminal config set no
`macos-option-as-alt`, so `⌥P` typed `π` and the agents' Meta shortcuts
were unavailable (Claude Code's `⌥T` is documented to work without Meta;
`⌥P` is documented to need it). `macos-option-as-alt = left` makes the left `⌥` the
terminal's Alt and keeps the right one for `⌥`-characters, which non-US
layouts type with it. In an embedder the line alone does nothing:
`GhosttySurfaceView.keyDown` now asks the core which modifiers shape the
text (`ghostty_surface_key_translation_mods`) and composes from an event
without the `⌥` it takes, and `NSEvent.ghosttyMods` sends the side bits
(`GHOSTTY_MODS_ALT_RIGHT` and kin), without which both `⌥` keys are
"left". A key that ends a composition (a dead key, an IME preedit) now
sends the committed text bare, with no key or modifiers, so a right-`⌥`
dead key finished with the left `⌥` gives "é", not Alt-E. All three are
ported from Ghostty's macOS app. Not a setting yet: the
shipped default until someone needs the other one.

The menu bar and the `⌘/` card follow: Window ▸ Show Previous / Next Tab,
File's other-agent items, Refresh retitled on Settings (where `⌘R`
already worked under a greyed item), and a History section on the card for
the keys that page owns. A cold read (docs/copy-review.md) then named both
agents in File's items and on the card, where "New Session" beside "New
Codex Session" and "the other agent" left the default to be inferred, and
named what ⌘R checks on Settings ("Check for Claude Code and Codex Again"):
"Check Agents Again" read as the running sessions.

---

## ADR-038 — A row that was never a session is dropped, not archived
**Date:** 2026-10-26 · **Status:** Accepted; amends ADR-030

Six rows archived over a week with "6 sessions archived: no transcript on
disk". Each was a ⌘T closed before anything was typed: Temple had joined
the minted id as `created`, Claude Code writes a transcript only on the
first message, and the close that should have dropped the row never did.
The path that drops it (the tab's close, a fresh completed absence from the
owning engine, then `discardUnstartedCreation`) ran only for a tab that
was new *this run*: a tab that outlived a relaunch (three installs that
week) came back as a restored chip (`isResume`), and a chip's close was
not that path. The sweep then found a row idle a week with no transcript
and did what ADR-030 says: archived it and told.

**Decisions.**

- **The row decides eligibility; the tab only says nothing was sent this
  run.** `startedNothing` no longer requires a tab started this run. Its
  handler asks the row: Temple created it (`joined_via = created`) and no
  transcript was ever recorded for it (`transcript_path IS NULL`). Only
  then is the engine asked for a fresh completed absence, and only on
  that is the row dropped. A row with a transcript on record is never
  asked about, so a History open or a restored chip of a real session
  needs no transcript lookup when closed unused.
- **One boundary for both drops, named by membership.** The tab's close
  and the sweep delete through the same statement
  (`TempleDB.discardNeverStarted`): Temple created the row, no transcript
  was ever recorded for it, it carries none of a person's marks as they
  stand now (pin, name, colour, an open from History, a keep, an archive),
  and it is in no restorable tab; the sweep adds its idle cutoff. Both
  name the membership (`id, host, incarnation`) the absence was confirmed
  for: a row that left and joined again during the check is another
  session.
- **The close decides on durable state, and writes nothing that could
  change it meanwhile.** Closing or ending a tab the person never used
  this run — nothing submitted, and no terminal input (a key, committed
  text, a paste, a click delivered to the program) since its latest spawn:
  `unusedThisRun`, local and remote exits alike — touches nothing: no
  recency bump, because a touch dated after a person's restore would
  spend the keep, and such a close is not the person using the session.
  Input without Return keeps the touch (it may be the only record of that
  use) and protects nothing else. The handler writes this process's
  pending activity for the row, then reads the row from the database
  rather than from the overlay, whose view another process on the same
  file (the installed Temple beside a dev build) does not update; the
  whole boundary is read there and rechecked in the statement. The engine
  confirms absence for a `MembershipRef`, re-reading the row first, so a
  membership it still holds from before a leave and rejoin answers
  neither for the new one nor for itself (`confirmAbsence(_:)`; a row read
  that fails leaves the member as it was, which is why the statement's
  incarnation check stays). After the proof, a tab of the row open in
  this process (⌘⇧T while the check was out) keeps it, since another
  process saving its tab set replaces this one's rows in `open_tabs`.
- **The sweep drops what was never a session, with no notice.** Of the
  rows ADR-030's sweep would archive for a missing transcript, those that
  match the boundary above are deleted instead; the notice counts the
  rest, and folder-only evidence still archives. ADR-030 counted "ids
  that never got a file" among what it archives, so this is a change to
  it, not a gap in it: its "only reversibly" is for sessions, and there
  was nothing to restore here — Restore would have launched a resume of an
  id the CLI never wrote a conversation for, and ⌘W already dropped the
  same rows outright. The predicate is provenance plus the absence of a
  record, not proof that no conversation happened: `transcript_path IS
  NULL` says Temple never recorded a locator. The accepted edge is a
  `created` session typed into whose file was gone before Temple ever read
  it (Temple not running for the month the CLI's retention waits, or a
  deletion in between); its row held an id, a title and a folder, and
  nothing on disk to resume, and it is dropped rather than archived. No
  "input was submitted" marker is persisted to veto that case; the case is
  accepted.
- **Hosts.** A session on a host is never dropped today: `RemoteSessionSource`
  supplies no completed absence (ADR-036). A host that one day does must
  first settle live-run ownership — a remote tab's close or detach leaves
  its agent running, able to write the transcript after the drop — and
  "the tab's process is gone by now" is a local fact, not a general one.

**Amends ADR-030:** "archived, labelled, and come back when a person
restores them" gains "a row that was never a session is dropped instead,
and not counted in the notice".
