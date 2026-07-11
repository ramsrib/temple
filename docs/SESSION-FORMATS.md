# Agent session storage — reverse-engineered reference

Observed on macOS on 2026-07-10 from installed Claude Code + Codex. Both CLIs
evolve; treat this as "current best-known," re-verify on version bumps. This is
the ground truth behind `TempleCore`'s stores.

---

## Claude Code

**Location:** `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`

- One directory per working directory. The dir name is the `cwd` with `/` → `-`
  (leading `-`). **Lossy** — real paths containing `-` or spaces collide and
  aren't reversible. → *Do not decode the dir name; read `cwd` from file
  contents.*
- One `.jsonl` **file per session**; filename stem = **session id** (a UUID).
- Sibling `mailbox` / `mailbox.done` files exist in some dirs — ignore.

**Lines** are newline-delimited JSON events. Shapes seen:
- `{"type":"user","message":{"role":"user","content": <string | [{"type":"text","text":"..."}]>}, "cwd":"…", "timestamp":"ISO8601", "sessionId":"…"}`
- `{"type":"assistant","message":{…}, …}`
- `{"type":"queue-operation","operation":"enqueue","content":"…", "timestamp":"…", "sessionId":"…"}`
- `{"type":"summary","summary":"…"}`

**What TempleCore extracts (from the file head only):**
- `id` = filename stem
- `cwd` = first line carrying a `cwd`
- `createdAt` = first line's `timestamp`
- `updatedAt` = file modification time
- `title` = first `type:"user"` message's text (fallback: first top-level
  `content` string)

**Resume:** `claude --resume <session-id>` run in `cwd`.

---

## Codex

**Location (current):** `~/.codex/sessions/YYYY/MM/DD/rollout-<iso>-<uuid>.jsonl`
**Legacy (also present):** flat `~/.codex/sessions/rollout-<date>-<uuid>.json`

**First line** is session metadata:
```json
{"timestamp":"ISO8601","type":"session_meta","payload":{
  "session_id":"019f…","cwd":"/Users/…/project","originator":"codex-tui",
  "cli_version":"0.142.5","model_provider":"openai", ...}}
```
Subsequent lines are turn/event records.

**Titles** come from `~/.codex/history.jsonl`, whose lines are:
```json
{"session_id":"019b…","ts":1769387854,"text":"first prompt text"}
```
Build `session_id → earliest text` once and use it as the session title. (Fallback
if absent: first user turn in the rollout, or "(no prompt)".)

**What TempleCore extracts:**
- `id` = `payload.session_id`
- `cwd` = `payload.cwd`
- `createdAt` = `payload.timestamp` (or session line `timestamp`)
- `updatedAt` = file modification time
- `title` = history-map lookup by id

**Resume:** `codex resume <session-id>` run in `cwd`.

> ⚠️ Verify resume subcommands/flags against the installed CLI version before
> wiring the launch path — both tools change quickly.
