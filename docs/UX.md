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
  content** area.
- Native macOS feel throughout (vibrancy on the sidebar, system fonts).

```
┌──────────────┬──────────────────────────────────────┐
│ ● ● ●        │                                        │  ← no window header
│ Temple    🔍 │                                        │
│ + New session│         MAIN CONTENT                   │
│              │   (empty launcher  ·OR·  terminal)     │
│ Pinned       │                                        │
│  · …         │                                        │
│ Projects     │                                        │
│  �¬ raven     │                                        │
│    · Analyze…│                                        │
│    · Inspect…│                                        │
│  ▸ mentes-web│                                        │
│              │                                        │
│ ◐ Sri     ⚙  │                                        │
└──────────────┴──────────────────────────────────────┘
```

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
- If multiple sessions are open, a **tab strip** sits at the top of the content
  area; each tab = one open session (agent dot + title).

---

## Core interaction flows

### Open an existing session
Click a session in the sidebar →
- if it's **already open**, focus its tab (never duplicate);
- else open a **new tab** and spawn its resume command in the session's `cwd`.

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

## Open questions (design)
- Empty-state composer: full compose (prompt + agent + project) at launch, or
  just spawn a blank terminal and let the user type into the CLI? *(leaning:
  spawn terminal for MVP; rich composer later.)*
- Tab strip vs. one-session-at-a-time (sidebar selection drives a single pane)?
  *(leaning: tabs, to match "maintain all running processes".)*
- Should closing a tab default to graceful-exit or background-detach (keep
  running, just hide)? *(leaning: graceful-exit; offer "keep running" later.)*
