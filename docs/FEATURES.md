# Temple — Product & Feature Spec

*What* Temple does, as a product. Companion to [PLAN.md](./PLAN.md) (the *how* /
engineering phases) and [DECISIONS.md](./DECISIONS.md) (the *why*).

Tiers: **MVP** (first usable release) · **v1** (rounds it out) · **Later**
(post-1.0 / nice-to-have). Each feature notes the PLAN phase that delivers it.

---

## 0. The core idea (north star)

> Your CLI coding agents, as a chat app. Every Claude Code / Codex session is a
> resumable "conversation," grouped by project. Click one → a real terminal tab
> opens and auto-resumes it. One home for everything you're working on across
> agents and repos.

Three primitives: **Agent** (Claude Code, Codex, …) · **Project** (a working
directory) · **Session** (one resumable agent run, with a title = first prompt).

---

## 1. Session index & sidebar — *the left rail*

The heart of the app: turn scattered on-disk agent sessions into an organized,
browsable index.

| Feature | Tier | Phase |
|---|---|---|
| Auto-discover sessions from Claude Code (`~/.claude`) + Codex (`~/.codex`) | **MVP** | 1 ✅ |
| Group by **project** (true `cwd`), projects sorted by recent activity | **MVP** | 1 ✅ |
| Recent sessions per project, newest-first, with human-prompt titles | **MVP** | 1 ✅ |
| Agent badge per session (Claude ◆ / Codex ◇) | **MVP** | 2 |
| **Live updates** — filesystem watcher re-indexes as sessions change | **MVP** | 1/2 |
| **Search** across sessions (title, project, agent) | **MVP** | 2 |
| Collapse/hide **ambient & automation noise** (e.g. the 1,864 `cwd:/` Codex runs) | **MVP** | 2 |
| Filters: by agent, by time range, active-only | v1 | 2 |
| **Pinned** projects & sessions (sticky top section) | v1 | 4 |
| Rich metadata: message count, model, git branch, last-message preview | v1 | 1/2 |
| "Recents" flat view across all projects (most-recent-first) | v1 | 2 |
| Manual scan roots / exclude paths (config) | v1 | 4 |
| Session grouping by git repo (not just raw cwd) | Later | 4 |

---

## 2. Terminal tabs — *the working surface*

Where the actual agent runs, powered by an embedded libghostty terminal.

| Feature | Tier | Phase |
|---|---|---|
| Embed a **libghostty terminal** surface (Metal-backed) | **MVP** | 0/3 |
| Click a session → open a **tab** that auto-resumes it | **MVP** | 3 |
| **Reuse-or-focus**: clicking an open session focuses its tab, no duplicate | **MVP** | 3 |
| Multiple concurrent tabs, one per open session | **MVP** | 3 |
| **Horizontal tab bar, scoped per project** — shows only the active project's open terminals (Codex sidebar + cmux-style tabs) | **MVP** | 3 |
| **`+` in tab bar** — quick-launch a new session in the active project | v1 | 4 |
| **Drag-reorder tabs** in the bar (per-project order, persisted across restarts) | v1 | 3 |
| Tab shows agent + project + session title | **MVP** | 3 |
| Working directory set to the session's `cwd` on launch | **MVP** | 3 |
| **Restore tabs** across app restarts | v1 | 3 |
| Running/idle/exited state indicator per tab | v1 | 3 |
| Split panes (two terminals side by side) | Later | 4 |
| Scrollback search, copy-mode, font/theme controls | Later | 4 |

---

## 3. Session lifecycle — *create, resume, manage*

| Feature | Tier | Phase |
|---|---|---|
| **Tab == agent process** — terminal always runs claude/codex (never a bare shell) | **MVP** | 3 |
| **Process-exit → auto-close tab** — agent quits (Ctrl+C, `/exit`, crash) → tab closes | **MVP** | 3 |
| **Resume** an existing session (the primary action) | **MVP** | 3 |
| **New session** flow: pick agent + project (+ git branch) → launch fresh | **MVP** | 4 |
| Reconcile a freshly-launched session's runtime id back into the index | **MVP** | 3 |
| Copy resume command / copy session id | **MVP** | 2 ✅(shell) |
| Reveal session file in Finder | v1 | 4 |
| **Rename** a session (custom title overriding first-prompt) | v1 | 4 |
| **Pin / archive / delete** a session | v1 | 4 |
| Duplicate / fork a session into a new branch | Later | 4 |
| Quick "new task in <project>" from a project header | v1 | 4 |

---

## 4. Multi-agent support — *pluggable backends*

| Feature | Tier | Phase |
|---|---|---|
| Claude Code + Codex, first-class | **MVP** | 1 ✅ |
| **Agent adapter** abstraction (store location, title rule, resume argv) | **MVP** | 1 ✅(SessionStore) |
| Per-agent config: binary path, extra launch flags | v1 | 4 |
| Add a 3rd agent (e.g. Gemini CLI, aider) via a new adapter | Later | — |
| Per-agent capabilities surfaced in UI (models, permissions) | Later | 4 |

---

## 5. Navigation & UX — *fast, keyboard-first*

| Feature | Tier | Phase |
|---|---|---|
| Sidebar ↔ detail split layout (Codex-desktop aesthetic) | **MVP** | 2 |
| **Toggle sidebar** (native show/hide, `⌘\`; content expands full-width) | **MVP** | 2 |
| **⌘K command palette / quick-open** (jump to any session) | v1 | 4 |
| Keyboard tab switching (⌘1–9, ⌘[/]) | v1 | 4 |
| Global keyboard search focus (⌘F) | v1 | 2 |
| Empty / onboarding states | v1 | 2 |
| **Theme: System / Light / Dark** (follows macOS by default; user override) | v1 | 4 |

---

## 6. Settings & preferences

| Feature | Tier | Phase |
|---|---|---|
| **Settings surfaced as an app-level tab** (singleton, project-agnostic — not a `⌘,` window) | **MVP** | 4 |
| **Terminal font size** (the first-cut variable; refine the rest later) | **MVP** | 4 |
| Agent binary paths (auto-detect + override) | **MVP** | 4 |
| Scan roots / excluded paths | v1 | 4 |
| Terminal: font family, theme, cursor | v1 | 4 |
| Startup behavior (restore tabs, default agent) | v1 | 3/4 |

---

## 7. Platform & packaging

| Feature | Tier | Phase |
|---|---|---|
| Native macOS `.app` bundle (Xcode target, entitlements, Metal) | **MVP** | 2/3 |
| Code-signed, notarized `.dmg` | v1 | 4 |
| Auto-update | v1 | 4 |
| Menu-bar / dock integration | v1 | 4 |
| Linux (GTK) build | Later | 5 |

---

## MVP definition (v0.1 — "it replaces my terminal-tab juggling")

The smallest thing that's genuinely better than manually running
`claude --resume`:

1. Sidebar lists my real projects + recent sessions, live-updating. *(core done)*
2. I can **search** and **filter out the automation noise**.
3. Clicking a session opens a **tab with a live, auto-resumed terminal**.
4. Clicking an already-open session **focuses** its tab.
5. I can start a **new session** in a project from the UI.
6. It's a real signed app I can leave running.

Everything in §§1–3 marked **MVP** plus the terminal embed (Phase 0/3) = v0.1.

---

## Explicit non-goals (for now)

- Not a terminal *emulator* to replace Ghostty/iTerm — it's a session manager
  that *hosts* terminals.
- Not a chat UI that reformats agent output into bubbles — the terminal is the
  source of truth; the "chat" framing is the *index/navigation*, not the render.
- No cloud sync / accounts / multi-machine (local-first).
- No Windows (see ADR-004).
