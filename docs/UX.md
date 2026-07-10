# Temple — UX & Interaction Spec

How Temple looks and behaves. Companion to [FEATURES.md](./FEATURES.md) (what),
[DECISIONS.md](./DECISIONS.md) (why), [PLAN.md](./PLAN.md) (how/when).

Design inspiration: the ChatGPT-Codex desktop app — a chat-style sidebar with a
frameless, header-less native window.

---

## Window & layout

- **Frameless / hidden title bar** (unified toolbar). Traffic-light buttons float
  over the top of the sidebar; there is **no separate window header/chrome**.
- **Two panes:** a **Sidebar** (~280pt) and a flexible **Main content** area. The
  main content carries a **horizontal tab bar** in its window-header strip (see
  below).
- **The sidebar is toggleable** — a native show/hide toggle (the standard macOS
  sidebar button in the header, `⌘\` /  `⌥⌘S`, same gesture as Codex/Xcode/Mail);
  hidden, the main content + tab bar expand full-width. Uses
  `NSSplitViewController`'s native collapse for the real system look & animation,
  not a hand-rolled panel.
- Native macOS feel throughout (vibrancy on the sidebar, system fonts, native tabs).
- **Single main window** for MVP (multi-window is later). Traffic lights sit over
  the sidebar; **when the sidebar is collapsed the tab bar insets ~70pt at its
  leading edge** so it clears the reflowed traffic lights.
- **Right-click context menu** on a sidebar row *and* a tab chip: open/focus, copy
  resume command, copy session id, reveal session file in Finder, rename, pin,
  close.

### Theme
Three modes: **System / Light / Dark** — default **System** (follows the macOS
appearance live), with a user override in Settings. The whole app respects it
(sidebar, tab bar, chrome via standard AppKit/SwiftUI appearance). The **libghostty
terminal palette tracks the active theme too** — a light and a dark color scheme
that switch with the app so the terminal never looks foreign against the window.

```
┌──────────────┬──────────────────────────────────────────┐
│ ● ● ●        │ [◆ Analyze ✕][◇ Inspect ✕][ + ]      ▢ ▢ │  ← horizontal tab bar
│ Temple    🔍 ├──────────────────────────────────────────┤     (active project's
│ + New session│                                          │      OPEN terminals only)
│              │                                          │
│ Pinned       │            MAIN CONTENT                  │
│  · …         │       (empty launcher ·OR· the           │
│ Projects     │        active tab's libghostty           │
│  ▾ raven     │              terminal)                   │
│    · Analyze │                                          │
│    · Inspect │                                          │
│  ▸ mentes-web│                                          │
│              │                                          │
│ ◐ Sri     ⚙  │                                          │
└──────────────┴──────────────────────────────────────────┘
```

**The two-part navigation model** — the sidebar and the tab bar are distinct
things, not two renderings of the same list:

- The **sidebar is the full browse index**: *every* project, *every* recent
  session, Codex-style (fully expanded, no accordion). A row here is *browsable*
  — click it to open/focus.
- A **"tab" is an *open terminal*** — a session you've actually launched or
  resumed. The **horizontal tab bar** (native look, in the header strip above the
  terminal) shows **only the open terminals of the active tab's project**. This is
  the fast switcher between the live terminals in the project you're working in.
- The **active project == the active tab's project.** Opening/focusing a session
  in another project swaps the tab bar to *that* project's open terminals.
  Switching projects never kills the other project's terminals — they live on
  off-screen until you return *(ADR-010)*.

So one open session has two representations: a browsable row in the sidebar **and**
a chip in the tab bar. Design inspiration is explicit here: **Codex sidebar +
cmux-style per-project horizontal tabs** — the tab bar is the piece Codex lacks.

### Sidebar (top → bottom)
1. **Wordmark** "Temple" + **search** affordance.
2. **Primary action:** `+ New session`.
3. **Pinned** — sticky user-pinned sessions.
4. **Projects** — each project (folder) is a disclosure group listing its recent
   sessions by title; per-project "Show more". Projects ordered by recent
   activity; a session row shows an agent dot (Claude ◆ / Codex ◇).
5. **Footer** — user avatar + settings.

> We deliberately do *not* copy Codex's `Scheduled / Plugins / Sites` items —
> those are ChatGPT-specific. Temple's top items are its own (New session,
> Search, Settings).

---

## Main content — two states

### A. Empty / launcher state (no active session)
A centered composer to start work — Temple's version of "What should we build in
`<project>`?":
- Project chip (defaults to last-used / selected sidebar project).
- **Agent selector** (Claude Code / Codex).
- Optional model/effort selector.
- A prompt input ("Do anything…") + optional quick-start suggestion cards.
- Submitting **creates a new session** and swaps this pane to the terminal
  (see *New session* flow).

### B. Terminal state (a session is open)
- The **libghostty terminal** fills the content area, running the live CLI
  session (resumed or freshly started), ready to type into.
- Unlike Codex, there is **no bottom composer** in this state — you type directly
  *into* the terminal. The composer only exists in the empty/launcher state (A).
- The **horizontal tab bar** in the header strip lists the **active project's open
  terminals** — one chip per open session. Each chip = **agent dot (◆/◇) + session
  title + a close ✕** (on hover) + an **activity dot** (running / needs-attention —
  see *Notifications*); the active tab is highlighted. A trailing **`+`** opens a
  menu — **New Claude Session** / **New Codex Session** — creating an empty session
  in the active project (⌘T does the same with the default agent, no menu).
- Tabs are **drag-reorderable** within the bar (native drag, live insertion
  gap/animation). Order is per-project and **persisted** to the session DB
  (`open_tabs` order, ADR-009). Dragging only reorders — it does not move a tab
  between projects (a tab's project is fixed by its `cwd`).
- **Restore across restarts is lazy:** on relaunch the per-project tab set + order
  come back as **inert chips**; a terminal **spawns only when you click a chip** —
  never a process storm at launch.
- The tab bar is **scoped to the active project**: it never shows another
  project's tabs. With nothing open, there is no tab bar and the pane shows the
  launcher (A).

---

## Core interaction flows

### Open an existing session
**Click** a session in the sidebar →
- if it's **already open**, focus its tab (never duplicate);
- else open a **new tab** and spawn its resume command in the session's `cwd`.

Either way, the session's project becomes the **active project**, and the
horizontal tab bar swaps to show that project's open terminals (with the just-
opened/focused one active). Clicking a session in a *different* project therefore
switches the whole tab-bar context to that project.

**Select vs. open (important):** opening a session **spawns a real agent process**,
so browsing must not. Keyboard **arrow keys move a highlight only** (no spawn);
**Enter** or **double-click** opens/focuses the highlighted session. "Highlighted
in the sidebar" and "has a live process" are independent states — and the sidebar
highlight **follows the active tab**, so the two views never disagree.

### New session
Every new session is an **empty agent session** — the agent launched fresh in the
target `cwd`, ready to type into (no initial prompt required). Three entry points:

- **`+ New session` (sidebar / ⌘N)** → the launcher: pick **agent** + **project**.
  The project picker lists indexed projects **and a "Choose folder…"** item
  (NSOpenPanel) — the *only* path that can target a directory Temple hasn't seen
  before (every other entry operates within already-indexed projects).
- **`+` (tab bar)** → a click opens a menu: **New Claude Session** /
  **New Codex Session**, created in the **active project**. Mouse path = explicit
  agent choice.
- **⌘T** → a new empty session in the **current project** using the **default
  agent** (Claude; configurable in Settings). Keyboard path = fast, no menu.

Launch mechanics per agent:
- **Claude:** Temple generates a UUID and runs
  `claude --session-id <uuid> [--name <n>] [prompt]` in `cwd`. **The id is known
  immediately** and stored at once. *(ADR-008)*
- **Codex:** run `codex [prompt]` in `cwd`, then **watch** `~/.codex/sessions`
  for the new rollout file and **adopt** its `session_id` (bare `codex` mints its
  own id — no injection). *(ADR-008)*

Temple never touches git or the filesystem — no branch, worktree, or checkout. A
"project" is just a working directory; a session is just an agent process running
in it. *(ADR-012)*

### A tab **is** its agent process (1:1, both directions)
*(This governs **session tabs** — the normal case. There is one exception: the
**Settings** utility tab, which has no agent and no project — see "Settings" below.)*

The terminal never hosts a bare shell — a session tab **always** runs a
claude/codex process directly (a "new" tab is an *empty agent session*, not a
shell prompt). So the tab and the agent process share one lifetime:

- **Close the tab (UI)** → gracefully end the process *(see below)*.
- **The agent process exits** — the user quits it (e.g. Ctrl+C to quit, `/exit`),
  it finishes, or it crashes → Temple **detects the child exit** (via the
  `TerminalSurface` delegate, `processState → .exited`) and **auto-closes the
  tab.** The session still lives in the sidebar (it's on disk).
- **Ctrl+D (EOF)** is passed straight through to the agent — Temple adds *no*
  detach/background semantics. There is no "detached process" state: an agent is
  always attached to a tab, and a live tab always has an attached agent. If the
  agent chooses to exit on EOF, that's an ordinary process-exit → the tab closes
  like any other.
- **Never orphan, never detach** *(ADR-010)*: no agent without a tab, no *session*
  tab without an agent.

### Close a tab
**Gracefully end the session, don't just kill it** *(ADR-010)*:
1. Signal the CLI to exit cleanly (so it flushes its session file) — e.g. send
   the interrupt/exit sequence, then `SIGTERM`.
2. Wait briefly for the child to exit; force-kill only stragglers past a timeout.
3. Reap the PTY/process; free the surface.
4. The session **stays in the sidebar** (it's persisted on disk) — closing a tab
   ends the *process*, not the *session*.

### Quit the app
Iterate **all** live sessions → graceful shutdown each → wait (bounded) →
force-kill stragglers → exit. Temple never leaves orphaned agent processes and
never quits mid-write (which could corrupt a session file). *(ADR-010)*

### Settings
Preferences open **as a tab**, not a separate `⌘,` window (VS-Code-style rather
than the classic macOS Settings window) — reachable from the footer **gear** (and
`⌘,`). It is a distinct kind of tab:

- **App-level & project-agnostic** — a Settings tab is *not* bound to a project
  and has *no* agent process (the "tab == agent process" invariant covers *session*
  tabs only; this is the deliberate exception).
- **Singleton** — reuse-or-focus: opening Settings again focuses the existing tab,
  never a second one.
- It stays available in the tab bar (independent of the active project) until
  closed; closing it just closes the pane — nothing to shut down gracefully.

**Contents — start small, refine later.** v0 exposes a handful of variables and we
grow it over time. First cut:

- **Terminal font size** (the explicit starter) + font family.
- **Theme:** System / Light / Dark *(see Theme, above)*.
- **Agent binary paths** (auto-detected, overridable) *(FEATURES §6)*.

Everything else in FEATURES §6 (scan roots, startup behavior, per-agent flags,
cursor, etc.) lands here incrementally. The default agent (Claude) lives here too.

### Search
- **Sidebar search (⌘F)** filters the sidebar in place, matching **session title
  only** (MVP — no project / agent / content search).
- **⌘K command palette** — global quick-open across **all** projects and sessions
  (title match). Pick a result → focus jumps to that project **and** session
  (opens or focuses its tab, switching project context as needed). *(v1)*

### Notifications & attention
The reason to run a session *manager*: know which one needs you. Each open session
carries an **activity state** — *running* (output flowing / agent working), *idle*,
or **needs attention** (agent finished, or is waiting for your input).

- **Signal source:** the terminal **bell** and the desktop-notification escape
  sequences (OSC 9 / OSC 777) that Claude/Codex already emit — surfaced by
  libghostty via delegate callbacks — plus **process exit** (session ended).
- **Surfaces:** an **activity dot** on the tab chip *and* the sidebar row; and a
  **native macOS notification** ("project · session" + message). Clicking the
  notification **focuses that tab** (switching project context as needed).
- Per-session / per-project **mute** and a Do-Not-Disturb toggle come later.

## Keyboard shortcuts
Temple's users live in terminals and editors (VS Code / Cursor), so it adopts
their conventions — tabs behave like editor/browser tabs.

| Shortcut | Action |
|---|---|
| **⌘T** | New empty session (tab) in the current project, **default agent** |
| **⌘W** | Close the current tab (graceful end, ADR-010) |
| **⌘N** | New session launcher (pick agent + project / choose folder) |
| **⌘1–9** | Switch to tab *N* in the active project |
| **⌃⇥ / ⌃⇧⇥** | Next / previous tab |
| **⌘F** | Focus sidebar search |
| **⌘K** | Command palette (quick-open any session) |
| **⌘\\** | Toggle sidebar |
| **⌘,** | Open Settings (as a tab) |

*(⌘⇧T "reopen last-closed tab" and multi-window support are later.)*

---

## Session identity, storage & titles (summary; see ADRs)

- **Our session id == the CLI's session id**, and we record the **type**
  (`claude` | `codex`). *(ADR-008)*
- A local **session DB** holds Temple's own state (pinned, custom order/name, tab
  restore, last-opened, running-process registry). The **filesystem session
  files are the source of truth** for content + discovery; a watcher keeps the DB
  in sync. *(ADR-009)*
- **Chat title** = the session's first human prompt (CLI-generated summaries are
  not reliably present in-file today); prefer a CLI summary if one appears, and
  allow a user rename. *(ADR-011)*

---

## Resolved
- **Tabs vs. one-session-at-a-time** → **horizontal, per-project tabs.** *See
  "Window & layout".*
- **Search scope** → **session title only** (MVP); ⌘K palette adds global
  quick-open. *See "Search".*
- **Tab restore** → **lazy inert chips**; a process spawns only on click. *See §B.*
- **Close a tab** → **graceful exit** (no background-detach state). *(ADR-010)*
- **Select vs. open** → click / Enter opens (spawns); arrow-keys only highlight.
- **Git / worktrees** → **out of scope**; sessions only. *(ADR-012)*

## Open questions (design)
- Empty-state composer: full compose (prompt + agent + project) at launch, or
  just spawn a blank terminal and let the user type into the CLI? *(leaning:
  spawn terminal for MVP; rich composer later.)*
- Tab-bar overflow when a project has many open terminals: scroll, shrink-to-fit,
  or an overflow "▾" menu? *(leaning: scroll + shrink, native-tab behavior.)*
