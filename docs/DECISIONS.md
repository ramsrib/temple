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
