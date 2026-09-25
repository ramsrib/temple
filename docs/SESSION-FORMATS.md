# Agent session storage — reverse-engineered reference

First written 2026-07-10; re-verified **2026-09-25** against Claude Code 2.1.282
and codex-cli 0.156.1 on macOS, from the real stores (structure and counts only).
Both CLIs evolve; treat this as "current best-known," re-verify on version
bumps. This is the ground truth behind `TempleCore`'s stores.

What Temple reads today is marked **(read)**. Everything else is recorded
because a future feature will need it: sessions forked or continued from a
Temple session, background agents, and importing sessions started elsewhere
(ADR-023).

---

## Claude Code

**Location:** `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` **(read)**

- One directory per working directory. The dir name is the `cwd` with `/` → `-`
  (leading `-`). **Lossy** — real paths containing `-` or spaces collide and
  aren't reversible. → *Do not decode the dir name; read `cwd` from file
  contents.* (A leading `-` also makes the name read as a flag to `ls`/`stat`;
  use `./` paths in shell.)
- One `.jsonl` **file per session**; filename stem = **session id** (a UUID).
  Temple enumerates this level only — which is what keeps subagents out.
- `sessions-index.json` still exists in a few project dirs but was last written
  in 2026-02: abandoned, do not read. `mailbox` / `mailbox.done` — ignore.

**Lines** are newline-delimited JSON events. Conversation lines carry `uuid`,
`parentUuid`, `sessionId`, `cwd`, `timestamp`, `gitBranch`, `version`,
`entrypoint`, `isSidechain`, `userType`. Shapes seen:
- `{"type":"user","message":{"role":"user","content": <string | [{"type":"text","text":"..."}]>}, …}`
- `{"type":"assistant","message":{…}, …}`
- `{"type":"queue-operation","operation":"enqueue","content":"…", …}`
- `{"type":"summary","summary":"…"}` (rare)
- `{"type":"ai-title","aiTitle":"…","sessionId":"…"}` — rare: 5 of ~1,900
  transcripts, repeated hundreds of times in each; 4 are background sessions,
  the fifth has an `agent-name` line but no `sessionKind:"bg"` lines. Treat it
  as a background-session feature; ADR-011 still holds for what Temple
  launches.
- `{"type":"custom-title","customTitle":"…","sessionId":"…"}` — a `/rename` or
  `--name`; rare.
- `{"type":"agent-name","agentName":"…"}` — the name agent view shows.
- Plus bookkeeping Temple ignores: `attachment` (hook output), `mode`,
  `permission-mode`, `file-history-snapshot`, `last-prompt`, `pr-link`,
  `system`, `cost-state`, …

**What TempleCore extracts (from the file head only):**
- `id` = filename stem
- `cwd` = first line carrying a `cwd`
- `createdAt` = first line's `timestamp`
- `updatedAt` = file modification time
- `title` = first `type:"user"` message's text (fallback: first top-level
  `content` string)

**Resume:** `claude --resume <session-id>` run in `cwd`. **New:** `claude
--session-id <uuid>` (Temple mints the id, ADR-008).

### Branches — same session, same file

Rewinding or editing an earlier prompt makes the conversation a **tree inside
one file**: a message whose `uuid` is the `parentUuid` of two or more later
messages is a branch point (6 of 60 recent Temple transcripts had one). The
session id does not change, so there is nothing for Temple to track.

### Subagents — not sessions

`<session-id>/subagents/agent-<agentId>.jsonl`, next to the parent transcript.
Every line has `isSidechain: true`, `agentId`, and the **parent's**
`sessionId`. A sidecar `agent-<agentId>.meta.json` holds `agentType`,
`description`, `model`, `spawnDepth`, and `toolUseId` (the parent's Agent tool
call). A subagent runs inside the parent's process and dies with it; it never
appears in `claude agents`. Temple does not index these.

### Background sessions and the fork behind `←`

A background session is an ordinary transcript whose conversation lines carry
`"sessionKind":"bg"` (interactive lines have no `sessionKind`; `entrypoint` is
`"cli"` either way), usually with an `agent-name` line. How one comes to exist
decides its id:

| How | Session id |
|---|---|
| `←` on an empty prompt, `/bg`, `/background` in a running session | **new** — the CLI runs `--session-id <new> --fork-session --resume <old>` |
| `claude --bg`, or a prompt typed in agent view | fresh |
| `claude --bg --resume <id>` | **same** id ("or starts a copy and says so when the session is already running") |
| resumed from agent view, or `claude respawn` | same |

The fork copies the history into `<new>.jsonl`, rewriting `sessionId` on every
line, and **appends to the old transcript**
`{"type":"continued-in","continuedInSessionId":"<new>","sessionId":"<old>","timestamp":…}`.
The old file then stops growing; `claude --resume <old>` opens the conversation
as it was before backgrounding, not the live agent.

**The link runs parent → child only.** The child has no field naming its
parent. (One observed child kept the old id in the snake_case `session_id` of
its copied API lines; another had no trace of it — not dependable.) To find a
session's continuation, read the tail of the parent for `continued-in`.

The fork lands in the project dir of the worker's cwd — the same dir in both
observed cases, but a session backgrounded from a worktree can land under the
main repo's dir.

`/fork` also spawns a background copy but leaves the original running; no
marker for it was observed on disk. An explicit `--resume <id> --fork-session`
gives a new id with no recorded parent either.

`claude attach <short-id>` opens a background session in a terminal **without
changing its id** — the way to open one in a Temple tab, rather than
`--resume`, which would start a copy of a session that is still running.

### Live state (not session files)

- `claude agents --json` — every **running** session: `{kind: "interactive",
  sessionId, cwd, pid, name, status: idle|busy, startedAt}` and `{kind:
  "background", id (short), sessionId, cwd, name, state, startedAt}`. `--all`
  adds finished background sessions.
- `~/.claude/sessions/<pid>.json` — one per live interactive process:
  `pid`, `sessionId`, `cwd`, `status`, `name`, `kind`, `entrypoint`,
  `startedAt`, `messagingSocketPath`, … This is where `claude agents` gets its
  interactive rows, and the way to ask which session a given process (a Temple
  tab's) is on *now*.
- `~/.claude/jobs/<short-id>/state.json` — one per background job, finished
  ones included: `sessionId`, `resumeSessionId`, `state` (`done`, `blocked`,
  …), `cwd`, `name`, `intent`, `interactiveLineage` (a **boolean**: forked from
  an interactive session — it does not say which), `children` (links: `kind`,
  `href`, `id`). `timeline.jsonl` beside it logs state changes.
- `~/.claude/daemon/roster.json` — the supervisor's **live** workers only
  (empty when none are running).

---

## Codex

**Location:** `~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl` **(read)**
**Legacy (also present):** flat `~/.codex/sessions/rollout-<date>-<uuid>.json`
(a dozen, pre-2026; Temple does not parse them).
**Archived by Codex:** `~/.codex/archived_sessions/` (`codex archive`); not read.

**First line** is session metadata:
```json
{"timestamp":"ISO8601","type":"session_meta","payload":{
  "id":"019f…","session_id":"019f…","cwd":"/Users/…/project",
  "originator":"codex-tui","source":"cli","thread_source":"user",
  "history_mode":"paginated","cli_version":"0.156.1","model_provider":"openai", ...}}
```
Subsequent lines are turn/event records.

- **`id` is the thread's own id** and matches the file name. **`session_id` is
  the root thread's**: equal to `id` for a thread a person started, but a
  subagent's names its parent. Temple reads `id` first (it used to read
  `session_id`, which filed every subagent under its parent's id).
- `source`: `exec`, `cli`, `vscode` (any app-server client — the desktop app,
  IDE plugins, the Claude Code plugin), or an object for subagents (below).
- `originator`: `codex_exec`, `codex-tui`, `Codex Desktop`, `Claude Code`,
  `codex_work_desktop`, `t3code_desktop`, … Temple's noise filter hides
  `codex_exec` and `codex_sdk_ts`.
- `thread_source`: `user`, `subagent`, `realtime_voice`, `voice_chat`, or
  absent.
- `history_mode`: `paginated` on every recent rollout. `codex
  migrate-rollouts` moves legacy sessions to the paginated history in
  `~/.codex/thread_history_1.sqlite`. Rollouts are still complete today; **if
  they ever stop being, Temple's reader breaks** — re-check on upgrades.

### Subagents and forks — separate rollouts, with explicit parents

A thread spawned by another agent is its own top-level rollout:
```json
"source": {"subagent": {"thread_spawn": {
  "parent_thread_id": "019f…", "depth": 1,
  "agent_path": "/root/review", "agent_nickname": "Kant", "agent_role": null}}},
"thread_source": "subagent", "session_id": "<parent>", "forked_from_id": "<parent>",
"agent_nickname": "…", "agent_path": "…", "multi_agent_version": …
```
`forked_from_id` is set on 20 of 38 observed subagents (presumably those
started from a copy of the parent's history — inferred, not confirmed). Temple skips subagent rollouts
(`CodexSessionStore.isSubagentThread`), as it skips Claude's.

`codex fork [SESSION_ID]` forks a person's session; the rollout carries
`forked_from_id`. No user fork was on disk to confirm the rest of its shape.

### Codex's own index — `~/.codex/state_5.sqlite`

- `threads` (~12k rows): `id`, `rollout_path`, `cwd`, `source`,
  `thread_source`, `originator`, `title`, `name`, `first_user_message`,
  `preview`, `archived`, `is_pinned`, `agent_nickname`, `agent_path`,
  `created_at_ms`, `updated_at_ms`, `recency_at_ms`, `git_branch`, …
- `thread_spawn_edges(parent_thread_id, child_thread_id, status)` — every
  subagent link, `open` or `closed`.

Richer than the rollouts (titles, names, archive, lineage in one query), but the
file name carries a schema version (`state_5`) and it is Codex's private
store: read-only, and only with a fallback to the rollouts.

### Titles

Codex never generates one; the best available is the first prompt, recorded in
different places depending on how the session started. Temple tries each in
order (skipping entries that clean to empty):

1. `~/.codex/history.jsonl` — written only by the interactive TUI:
   ```json
   {"session_id":"019b…","ts":1769387854,"text":"first prompt text"}
   ```
   Build `session_id → earliest text` once.
2. `~/.codex/session_index.jsonl` — written only by app-server clients
   (IDE companions, plugins); `{"id":"019b…","thread_name":"…"}`, last entry
   per id wins.
3. The rollout itself — the first `user_message` event payload's text. This is
   the only source for plain `codex exec` runs, which write neither file above.
   (The role-`user` `response_item` lines can't title: the first one is the
   injected AGENTS.md instructions blob, not the prompt.)
4. `"(no prompt)"`.

**What TempleCore extracts:**
- `id` = `payload.id` (fallback `payload.session_id`)
- `cwd` = `payload.cwd`
- `createdAt` = `payload.timestamp` (or session line `timestamp`)
- `updatedAt` = file modification time
- `title` = fallback chain above

**Resume:** `codex resume <session-id>` run in `cwd`. Background: threads on
the shared daemon (`codex agents`, `codex queue --thread <id>`) keep their id —
there is no fork-on-background step.

> ⚠️ Verify resume subcommands/flags against the installed CLI version before
> wiring the launch path — both tools change quickly.
