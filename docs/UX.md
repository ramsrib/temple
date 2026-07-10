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
  title + a close ✕** (on hover); the active tab is highlighted. A trailing **`+`**
  starts a new session *in the active project* (quick launch).
- Tabs are **drag-reorderable** within the bar (native drag, live insertion
  gap/animation). Order is per-project and **persisted** to the session DB
  (`open_tabs` order, ADR-009) so it survives restarts. Dragging only reorders —
  it does not move a tab between projects (a tab's project is fixed by its `cwd`).
- The tab bar is **scoped to the active project**: it never shows another
  project's tabs. With nothing open, there is no tab bar and the pane shows the
  launcher (A).

---

## Core interaction flows

### Open an existing session
Click a session in the sidebar →
- if it's **already open**, focus its tab (never duplicate);
- else open a **new tab** and spawn its resume command in the session's `cwd`.

Either way, the session's project becomes the **active project**, and the
horizontal tab bar swaps to show that project's open terminals (with the just-
opened/focused one active). Clicking a session in a *different* project therefore
switches the whole tab-bar context to that project.

### New session
`+ New session` (or submit the launcher composer) → pick agent + project (+
optional branch + initial prompt) → open a tab and launch:
- **Claude:** Temple generates a UUID and runs
  `claude --session-id <uuid> [--name <n>] [prompt]` in `cwd`. **The id is known
  immediately** and stored at once. *(ADR-008)*
- **Codex:** run `codex [prompt]` in `cwd`, then **watch** `~/.codex/sessions`
  for the new rollout file and **adopt** its `session_id` (bare `codex` mints its
  own id — no injection). *(ADR-008)*

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
cursor, etc.) lands here incrementally.

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
- **Tabs vs. one-session-at-a-time** → **horizontal, per-project tabs.** The tab
  bar lives in the content header and shows only the *active project's* open
  terminals; the sidebar stays the full browse index. (Codex sidebar + cmux-style
  per-project tabs.) *See "Window & layout" above.*

## Open questions (design)
- Empty-state composer: full compose (prompt + agent + project) at launch, or
  just spawn a blank terminal and let the user type into the CLI? *(leaning:
  spawn terminal for MVP; rich composer later.)*
- Tab-bar overflow when a project has many open terminals: scroll, shrink-to-fit,
  or an overflow "▾" menu? *(leaning: scroll + shrink, native-tab behavior.)*
- Should closing a tab default to graceful-exit or background-detach (keep
  running, just hide)? *(leaning: graceful-exit; offer "keep running" later.)*
