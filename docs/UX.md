# Temple — UX & Interaction Spec

How Temple looks and behaves. Companion to [FEATURES.md](./FEATURES.md) (what),
[DECISIONS.md](./DECISIONS.md) (why), [PLAN.md](./PLAN.md) (how/when).

Design inspiration: the ChatGPT-Codex desktop app — a chat-style sidebar with a
frameless, header-less native window.

---

## Window & layout

- **Frameless / hidden title bar** (unified toolbar). Traffic-light buttons float
  over the top of the sidebar; there is **no separate window header/chrome**.
- **Two panes:** a fixed **Sidebar** (~280pt, collapsible) and a flexible **Main
  content** area. The main content carries a **horizontal tab bar** in its
  window-header strip (see below).
- Native macOS feel throughout (vibrancy on the sidebar, system fonts, native tabs).

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
