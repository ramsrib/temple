# Remote (SSH) sessions for Temple: design

> **Decided in [ADR-036](../DECISIONS.md#adr-036--sessions-on-another-machine-through-the-users-own-ssh); built in phases 0 to 2, documented in phase 3.**
> Sections 1 to 12 describe what is built: where the original design and the
> implementation differed, the text there was corrected in place and says
> "As built". Everything from "Review changes" on is history, kept as it was
> written; a note that later work overrode is marked **Superseded** with a
> pointer to what replaced it. The as-built notes for each phase are the
> detail behind sections 1 to 12.

Status (history): proposal for ADR-036, revision 9 (two review rounds clustered in
the deferred-stop mechanism, so it is removed rather than patched: Temple
never kills anything without a live user action; a stop it could not carry
out and confirm at that moment is recorded as "left running" and listed
with a Stop button; revision 5 approved by astra and
by a fable final read; revision 6 applied the final read's must-fixes: no
core schema change at all, the socket-repair path deferred, user-facing
copy without "run", phase 1 split into Claude then Codex; revision 7 answers
the owner's question "how do we clean up the remote tmux sessions when we
close the tab": close means what it means locally, long work stays alive). Revision 2 answered gpt-6-astra's
first review; revision 3 made Hosts a connection manager (owner); revision 4
answered astra's second review at altitude (the launch model and the
keep-alive layer redesigned, not patched) and folded in three owner
directives; revision 5 answers astra's third review (no automatic heuristic
adoption; attach-only while liveness is unknown; run identity apart from
attachment; the record locator persisted; terminal, removal and isolation
contracts finished). The review maps are the last sections. Read against ADR-029
(host seam), ADR-030 (proof at decision time), ADR-032 (catalog cache),
ADR-034 (`temple` CLI) and the AGENTS.md rules.

Owner's goal, verbatim: "I have a remote machine that runs Claude and Codex. I
want to connect to it and run from that machine." What he cares about:
"creating and working on remote sessions, and reopening the old sessions that
were created/managed via Temple." Transcript discovery on the remote is not a
requirement. His hosts are Linux boxes behind `~/.ssh/config` aliases, and he
already uses tmux there for long jobs. Remote is an experiment: if its UX is
not good it may be dropped, so everything remote-only must be deletable
without touching core rows (section 9, "Removing remote").

---

## 1. Scope of v1

**In.**

- Add a host in Settings' Hosts connection manager: pick a `~/.ssh/config`
  alias, or enter name, address, user, port and optionally an identity file
  and a jump host; test the connection in a small terminal sheet (host key,
  password, 2FA, whatever ssh asks), which then checks that `claude`, `codex`
  and a supported `tmux` run there and shows each tool's own output.
- Start a Claude or Codex session in a folder on that host from ⌘N, the
  launcher and a project's `+`; work in it in a Temple tab, exactly as local.
- The agent runs inside a Temple-owned, hidden tmux server on the host, so it
  survives a dropped connection, a closed lid and a Temple quit (while it is
  working, as designed; working or idle, as built since the owner's round 2). Closing a tab means what it means locally (ADR-010): an idle
  agent is stopped, a working one is detached or stopped as you choose, and
  reopening a stopped session resumes it from its transcript. A stop that
  Temple could not carry out and confirm at that moment (the host did not
  answer) leaves the session running and lists it under "Sessions on
  <host>" with a Stop button; Temple never stops anything without a live
  user action.
- Reopen later from the sidebar, ⌘K, History's In Temple scope, and tab
  restore after relaunch. A Codex launch whose id Temple has not learned yet
  is still reopenable (by its launch handle) and restorable (as a chip).
- The row lives under `ProjectKey(host, directory)`; the sidebar section says
  the host; everything host-keyed today just works.
- Enrichment of a remote row from its own transcript (title, recency,
  directory for a row that lacks them), by known path, through ssh, at
  startup and on open, with a circuit breaker for unreachable hosts.

**Out, said in the ADR.**

- A host without tmux 3.2 or newer: the test says so and the host cannot
  start sessions. One execution mode, one lifecycle.
- Discovery or import of remote sessions Temple did not start or open: no
  remote `catalog`. History's on-disk lane lists nothing for a remote host.
- Auto-archive on a remote host: `proveAbsent` is `.unproven`, folder
  evidence is never `.missing`, and a remote row is never `confirmedAbsent`
  (its listing is never audited as complete). A remote row is archived only
  by a person and never tagged "No transcript".
- Background "running on host" marks, continuous transcript polling, routing
  ⌘F to tmux's search, browsing the remote filesystem in the folder sheet.
- The usage meter, Reveal in Finder, `temple sessions new` on a remote folder
  (the CLI lists, opens and closes remote rows, since it reads rows; it
  starts sessions locally only).
- Per-host agent arguments or command overrides.
- Non-Linux remotes: the listing uses GNU `find -printf` (a BSD fallback is
  tested, not an acceptance target); Codex identity by process uses `/proc`,
  and a host without it is identified by the question only (as built, phase
  1b decision 2: there is no non-`/proc` walk).

---

## 2. Transport

### The user's ssh in the tab, a Temple-owned ControlMaster for queries

The terminal tab runs the user's own `ssh` (from the adopted login-shell
PATH, `/usr/bin/ssh` if none) with a PTY, under libghostty. Every metadata
query (environment, probe, record, adopt, has-session, kill-session, locate,
read, evidence) is a separate short `ssh` exec that rides the master when one
is up and otherwise connects on its own, non-interactively.

Rejected: plain `ssh -t` only (every query re-authenticates; a passphrase or
2FA host makes background reads prompt or fail); sshfs (ADR-030 treats
network volumes as unprovable); a bundled ssh library (the user's ssh does
keys, agents, config and jump hosts; Temple would store things it must not).
A Temple-shipped remote helper is weighed in section 4 and rejected there.

### How a Temple-added host reaches ssh: per-host `-o` options, no config file

A host picked from `~/.ssh/config` is reached by its alias and nothing else.
A host entered in Temple is reached by the same alias mechanism plus options
on the command line, derived from its record by one function
(`SSHConnection.arguments(for:)`) and passed identically by the tab, the
test sheet and every query:

```
ssh -o HostName=<address> -o User=<user> -o Port=<port>
    [-o IdentityFile=<path>] [-o ProxyJump=<jump>] <Temple options> -- <name>
```

Why not a generated config file: command-line options are read first, so
they win for that host, while the user's `~/.ssh/config` and
`/etc/ssh/ssh_config` still apply for everything else (`Host *` defaults,
`IdentityAgent`, Apple's keychain settings, the jump host's own entry).
`ssh -F <temple file>` replaces the user's config *and* makes ssh ignore
`/etc/ssh/ssh_config`; `Include ~/.ssh/config` inside it brings back only the
user's file and adds the first-obtained ordering trap (a user `Host *` block
included ahead of Temple's host block overrides Temple's `User` and `Port`).
`ssh -G <name> <options>` prints exactly what will be used, which the tests
and the sheet's details show. The name must not be a config alias (the form
refuses it). `IdentityFile` adds a key to the ones ssh would try; Temple
never sets `IdentitiesOnly`; the record holds a path, never key material.
**Copy as ssh config** puts the block on the clipboard for people who want
it in their own file; Temple never writes there.

### Options, ownership and recovery of the master

Tab and Test-connection connections (the only ones allowed to *create* a
master):

```
-o ControlMaster=auto -o ControlPath=<socket dir>/<socket key> -o ControlPersist=600
-o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10
```

Queries: the same `ControlPath` with `-o ControlMaster=no -o BatchMode=yes
-o ClearAllForwardings=yes -T` and a wall-clock deadline. As built there are
two kinds: `.query` rides the master when one is up and otherwise connects
on its own, non-interactively; `.overMaster` (the Test connection's checks,
and staging a pending launch over the connection its tab was planned on)
rides that master or fails, never connecting by itself (phase 0 note 1,
phase 1a note 22). Deadlines (5 s has-session and
record, 10 s evidence and probe, 20 s locate, read and adopt). On the
deadline Temple kills the query's ssh process, a client of the master, never
the master.

- **Socket key** = `m-<16 hex of sha256(state dir, name, address, user,
  port, identity file, jump host)>`. The state dir in the hash keeps two
  isolated instances (a `TEMPLE_STATE_DIR` demo beside the installed app)
  from sharing a master even in the fallback dir; the connection parameters
  in the hash mean an Edit yields a new socket path at once, so a changed
  port is tested against the new address, and the old master expires on its
  own. Socket dir `<state dir>/ssh/` (0700); when the path would exceed 86
  bytes (as built, phase 0 note 3: ssh binds at `<ControlPath>.<16 random
  characters>` and `sun_path` is 104 with its NUL), `$TMPDIR/temple-ssh-<uid>/`,
  and `/tmp/temple-ssh-<uid>/` when that is still too long.
- **Shared masters are never killed by Temple.** Two Temple processes with
  one state dir share sockets (user-owned, the user's ssh). Quit, Remove,
  Disable and Edit all do the same thing: cancel this instance's queries to
  the host, terminate this instance's clients (its tabs detach), and let the
  master expire through `ControlPersist`. No `-O exit` anywhere.
- **Stale sockets**: Temple tracks the exact paths it named. A path is
  removed only on a positive sign that nothing listens (`connect()` returns
  `ECONNREFUSED`); a failed or timed-out `-O check` is inconclusive and
  leaves the file. ssh copes with a stale socket on its own anyway
  (`auto` falls through to a fresh connection; `no` falls back to direct).
- **After sleep**, ServerAlive on the master notices a dead peer within 45 s
  and the master exits; until then queries hang to their deadline and read as
  transport failures, which prove nothing.
- **Concurrent first connections** are arbitrated by ssh; queries never
  create a master, so a BatchMode exec cannot race a tab for it.

### One remote environment policy

ssh runs a remote command through the login shell non-interactively, which
often has not read the rc file that builds the real PATH. Temple resolves the
remote PATH the way `LoginShellEnvironment` resolves the local one and uses
it for **everything**: probe, launch, tmux management, transcript reads, and
the agent itself (tmux spawns a pane with the unattached client's
environment, and `new-session -e PATH=…` sets it explicitly besides, so a
running server cannot hand the agent a different one).

- Resolution: one query running `exec "$SHELL" -lic '<frame; printenv PATH;
  frame>'` with the same fallbacks and 5 s timeout, parsed between frame
  markers so rc chatter, motd and prompts are discarded. Kept in memory per
  host per run, re-resolved on Test connection and on the first query after
  a transport failure. The login environment is never persisted (what a
  pane ran with is run evidence, section 8). As built, the resolver runs in
  its own process group under one 5 s budget (phase 1a note 10).
- Use: as built (phase 1a notes 22 and 23), every command line is a short
  fixed bootstrap (`sh -c '<bootstrap>' temple <end>`, under 1 KiB); the
  program (`set --` with its arguments, the resolved PATH, the script) and
  any input travel on stdin, and a launch is staged on the host first.
- When resolution fails, probe and launch both use ssh's default command
  environment and the Hosts list says so. The rule is only that the two
  agree.

### First use: Test connection

A host added for the first time usually needs ssh to ask something. BatchMode
queries cannot answer, so the connection manager's **Test connection** runs
in a small terminal sheet, and every place a query fails with an
authentication or host-key error offers the same button.

1. **Connect, interactively.** A libghostty surface in the sheet runs
   `ssh <arguments> -- <name> true` (creating the master) as its own
   process, nothing wrapped around it; the user answers ssh there; the
   surface stays visible for the whole test, so the fingerprint ssh showed
   is still on screen with the result.
2. **Check, when a master is up.** However the terminal's process ends,
   its exit status is not the evidence (libghostty launches through
   `/usr/bin/login`, whose status is not ssh's); the master the connect
   created is: `ssh -O check` on Temple's socket. Master up: environment
   resolution, then the tool checks (section 7), as `BatchMode` queries
   over the master through `RemoteExec` with their deadlines. Results
   render under the surface, one row each (login shell and PATH, `claude`,
   `codex`, `tmux`, logind), each with the verdict and that tool's own
   first line, expandable. No master: no checks and no second connection;
   the sheet reads "Couldn't connect. See ssh's message above." with ssh's
   own words kept on the terminal. (Phase 0 as built; see the end notes.)

Host-key copy: unknown key ("Host key verification failed." without the
banner) reads "ssh hasn't seen this host's key before. Test the connection to
check it and confirm it."; changed key ("WARNING: REMOTE HOST IDENTIFICATION
HAS CHANGED!") reads "ssh says this host's key has changed and will not
connect. Temple won't change your known_hosts; check the host first. ssh
named the line: <the `Offending … key in …:N` line>." with Close only.

The sheet is agent-less and modal to the Settings tab; never persisted.
Temple never passes `StrictHostKeyChecking`, `UserKnownHostsFile`, `-i` or a
password; the only identity it names is the path the user typed, as
`-o IdentityFile`.

---

## 3. The launch model

### Altitude: what must be true, in the fewest states

Three facts of a remote session arrive at different times and must not be
confused: the **handle** (Temple's, known before anything runs), the
**keep-alive session** on the host (exists or not, and whether Temple can
tell), and the **CLI session id** (Claude: Temple-minted, known at spawn;
Codex: minted by `codex`, learned later or never). Round 1 and round 2 both
found bugs where the id was load-bearing for reattach or for persistence.
The redesign makes the id a *fact discovered lazily*, never a precondition:

- **Attach needs only the handle.** The tmux session is named by the
  handle; the first Open of a run creates it (`new-session`, which fails
  loudly on a duplicate name rather than attaching to something Temple did
  not start), and every later Open is `attach-session` only. Nothing is
  ever created from a state where the original might still be running; no
  rename, no id.
- **The id is needed for exactly two things**: showing the session as a row
  (sidebar, ⌘K, History, the title and folder fills) and starting a *new
  run* of it (`claude --resume`, `codex resume`), which happens
  automatically only when the original run is positively gone, and
  otherwise only when the user asks for it knowing the original may still
  be running. Both tolerate lateness.
- **Could adoption be removed outright?** Checked read-only against the
  installed `codex-cli 0.162.1`: there is no flag that starts a session with
  a caller-chosen id or rollout path (`resume` takes an id or a session
  name; `-C` is a worktree option; `-c` overrides config keys, none of which
  names a new session's id). So Codex keeps a discovery step; Claude never
  had one (`--session-id`).
- **Could the handle be the row's id?** No: ADR-008 makes the row id the
  CLI's id, every surface and the CLI's `sessions get <id>` depend on it,
  and a rebind is a core write for a remote-only need. The owner's
  removability rule settles it: nothing remote-specific enters
  `session_state`.

So: the unit Temple tracks is the **run**, keyed by handle, in remote-owned
storage (section 8). A run is one agent process on one host under one tmux
session name, however many times Temple attaches to it. A Claude run has its
id from the start and joins its row before spawning. A Codex run is
**pending** until its id is verified; while pending it is a tab or a chip,
not a row, and it is reopenable and restorable by handle. A session may have
several runs over time (one ends, the user starts another); the row is one,
the runs are many, and only the latest run that is not Ended is what Open
attaches to.

Two identities, kept apart: the **run** (durable: handle, created once,
named on the host) and the **attachment** (one ssh client; `attachment`
increments on every Open and is what asynchronous results are bound to). An
attachment never produces launch evidence; only the run's creation does.

### Every state of a remote run

A run's state is three facts: `id` (known or pending), the keep-alive
session (`present`, `absent`, `unknown`, as last established, and `unproven`
right after a creation attempt whose tmux client failed), and whether a tab
is attached. The user-visible states and every transition:

| state | id | keep-alive | tab | what persists (remote store unless said) | leaves by |
|---|---|---|---|---|---|
| **Creating** (first Open of a run) | Claude: known; Codex: pending | not yet created | ssh running `new-session`, no record yet | run row (handle, host, agent, mode, session name, directory intent, record path, attachment 1, started_at); Claude: `session_state` row joined with host and agent | `ok` record → Running; `failed cd` → Failed (never created); `failed tmux` or ssh exit with no record → exit check with `creation unproven` |
| **Attaching** (every later Open) | known or pending | last established | ssh running `attach-session` | attachment incremented; nothing else | client connected (tmux draws) → Running; tmux `can't find session` / `no server running` → exit check; other failure → Unknown |
| **Running** | known or pending | present | attached | `ok` evidence (remote epoch, canonical dir, pane pid and start time, the server's socket path from `$TMUX`) written before the record is acknowledged; row directory `tab`-sourced (Claude, or Codex once verified); an `open_tabs` row as for any tab (id known; its host comes from the `session_state` row on restore) or nothing in core (pending) | ssh exits → exit check; Close idle → Stop now: one attached-checked kill, acknowledged → Ended, not acknowledged → **left running** (Detached or Unknown with the flag); Close working → Detach (Detached) or Stop; verified id → id known (same state) |
| **Detached** | known or pending | present (last established) | none; a chip, or a kept tab with the "Disconnected" header | run row; `open_tabs` (id known) or the run row alone (pending, restored as a chip) | Open → Attaching; Stop → kill then exit check; closing the kept "Disconnected" tab → Stop now if the host answers, otherwise **left running** (flag set, listed); Discard (pending) → run row `dismissed_at` |
| **Left running** (a flag on Detached or Unknown: `left_running_at`, `left_running_reason`) | known or pending | last established | none | run row: when and why (`host did not answer`, `stop not acknowledged`, `another client attached`, `quit deadline`) | nothing automatic, ever: listed in "Sessions on <host>" with the notice, **Stop** and **Keep** (Keep clears the flag: an ordinary Detached session); Open → Attaching (attaches if it survived; a positive `can't find session` → Ended → new run with `resume`), which clears the flag; the user's Stop → the same one-command kill → acknowledged → Ended |
| **Ended** | known or pending | absent, **proven** by either: the pinned server answered `can't find session`, or Temple's own targeted `kill-session` for this run was **acknowledged** (exit 0) | closed (id known) or a chip saying it ended (pending) | run row `ended_at` and `end_evidence` (`absent` or `killed`); row untouched | Open with id → a new run (Creating with `resume`), automatic because the end was proven; pending: **Start a new session** (new handle, a new Codex session) or Discard |
| **Unknown** | known or pending | unknown, or `creation unproven` | kept tab with the uncertainty header, or a chip | run row unchanged | Open → Attaching only, never a creation; **Resume anyway** (id known) or **Start a new session** (pending) are explicit buttons whose copy says the original may still be running (section 5); Stop → exit check |
| **Failed** | known or pending | absent (never created: the pane's own `cd` failed, which only a created pane can report) | kept tab with the launch-failure header | run row with the failure record, `ended_at` | Open → a new run (Creating); close → gone (pending: Discard) |

**Exit check** = the final record collection, then one `has-session` query
against the pinned socket, bound to the attachment that issued it; its
answers map to Ended / Detached / Unknown (section 5). **Attachment
binding**: every asynchronous result (record fetch, exit check, identity
check, Stop) carries the attachment it was issued for and is dropped if the
run has a newer attachment, the tab was closed by the user, or the app is
quitting.

**Recovering the record.** The record path is persisted in the run row at
spawn, so an `ok` written on the host but never collected (quit or crash
before the first fetch, a dropped connection) is fetched on the next Open
*before* the attach, over a query, and applied as if it had arrived in
time; records live 24 h on the host (the stale sweep). A creation whose
record never arrives in that time stays `creation unproven`: Open is
attach-only and the user may choose Resume anyway (or Start a new session
for a pending Codex launch).

**`failed tmux` means "creation not proven", not "never created".** The tmux
client can exit non-zero after the session and pane exist (a terminal
problem, a client-side error). The run therefore goes to Unknown with
`creation unproven`, the next Open attaches, and the record, if the pane
did run, is recovered as above.

Persistence happens *before* the step that needs it: the run row before the
spawn (a write that fails refuses the open with the error, nothing spawns);
the `ok` evidence before the record is acknowledged and deleted on the host;
the id before the join. A run-store read failure refuses the open with its
error; it never reads as "no run, mint another".

### Codex identity: verified ownership, or the user's word

Temple adopts a Codex id automatically only on **launch-specific evidence**
that ties a rollout to this run's own process. Uniqueness of a match is not
ownership: two pending runs in one folder can both match one rollout, and an
unrelated `codex` can be the sole match, so no directory or time heuristic
ever adopts on its own.

**Automatic, by the pane's own process** (as built: phase 1b round 2
ruling 1 replaced the descendant walk designed here). The pane script
records `$$` and its `/proc/$$/stat` start time in the `ok` record and
`exec`s the agent command, so the pane pid is the run's agent. The identity
query, on a bounded schedule (2, 5, 15, 60 s after `ok`, then each minute
while attached, at the exit check, and on each activation, not twice in
5 s):

1. verifies the pane pid is alive with the recorded start time (pid reuse
   defeated), and that tmux's `#{pane_pid}` for the run's session agrees;
2. collects every `/proc/<pane pid>/fd/*` link under the run's Codex home's
   `sessions/` named `rollout-*.jsonl` whose `fdinfo` access mode is write
   or read-write, and re-reads the start time after;
3. adopts only when the pane's own process holds exactly one such rollout,
   its header's id equals its filename's id, its `cwd` is the run's folder
   and it is not a subagent's thread. A rollout held only by another process
   (a child, a launcher's native binary, Codex's shared app server, which
   writes every rollout by default) proves nothing: lastingly inconclusive,
   and the question takes over. Anything unclear (none open at that instant,
   more than one, an unreadable `fd`, `fdinfo` or `stat`, a process gone
   mid-check) is **inconclusive**: no claim, try again on schedule. A host
   with no `/proc` is lastingly inconclusive.

With Codex's default app server the candidates identify the session; with
`--no-daemon` in the user's Codex arguments the pane's process holds its
own rollout and is adopted at the first check. Temple passes no flag of its
own; the Hosts card's notes say so (as built in the owner's round 2: the
hint left the tab's bands).

**Suggested, by launch evidence, confirmed by the user.** When the automatic
check stays inconclusive (the file is not held open between writes, the
process has exited, the host has no `/proc`), Temple looks up rollouts whose
header `cwd` is the run's canonical directory and whose header timestamp
lies in [`ok` epoch, exit time or now] on the remote clock, and shows the
candidates in the tab or chip as a question, never a fact: "Is this the
session? <first prompt or "(no prompt)">, started in <folder> <when>."
(as built: <when> is relative to the tab's open, "4 s after this tab opened",
or the clock time)
[Yes, that's it] [Not this one]. Several, the user picks or declines; a
declined candidate is not offered again for that run.

**As built (owner, round 2; Fable's decision after two clustered Sol
rounds): a lone candidate gets Temple's own yes.** When the lookup finds
exactly one eligible candidate for a connected run that was typed into and
never asked about, Temple says yes through the yes's exact path
(`RemoteTabController.claim(automatic:)` → `RemoteSessions.confirm`, a
claim `how: .automatic`, the same recheck at decision time, uniqueness and
core join; a run that ended meanwhile concludes as a yes does, `.known` is
simply the session, and a failed claim asks the question). The only
addition is a display-only note in the tab, gated with the rest of the
tab's part ("Linked to “<first prompt>”, the only Codex session started
in this folder since this tab opened. If that’s wrong, Discard stops it and
removes it from Temple.", or "the Codex session started <time>, the only
one started in this folder since this tab opened" with no prompt). A wrong one is corrected by Discard: the
agent is stopped first (Temple's client, then the one-command stop), and
a confirmed stop dismisses that run alone (`dismissStoppedRun`, one
immediate transaction, refused while another run of the session is live
or newer, as after a reopen during the stop) before the row is let go or
archived under its incarnation; a stop Temple can't confirm leaves it
running and listed, nothing discarded. An automatic yes that can't be
written says why and asks; it is not tried again on its own. "Asked" is the question shown
this launch (memory, per handle) or any declined candidate for the run,
which the claim's own transaction checks: the only durable decline is a
decline. Nor while another new Codex session Temple started on the host
in the same folder is still unidentified, not ended and not dismissed (the
computer-use pass on dd60e31: two tabs typed into within seconds each saw
one candidate, perhaps the other's); the tab's gate checks this Temple's
tabs, and the claim's transaction checks every run on the host
(`ClaimOutcome.contended`), so both ask. Folders compare only once both
panes reported theirs (canonical, by bytes); a neighbour whose folder is
not resolved yet (`~/p` before its pane says `/home/u/p`, detached or
not) counts as the same folder (Sol round 5). An ended tab, two or more
candidates, an untyped run, or a run already asked about: the question; with the last candidate declined, the
tab says Temple couldn't tell.

**Uniqueness after the fact.** As built (astra's implementation note 1,
phase 1b note 10): a verified or confirmed id is a **claim**, written in
one immediate transaction before the core join, and a partial unique index
(`runs_claim`, `(host, session_id) WHERE claim IS NOT NULL`) makes two
claims of one id impossible, while a session's later runs (its resumes) may
share its id. A second run that arrives at an id already claimed is refused and
stays pending ("Temple couldn't tell which Codex session this is."). A join
refused by core (`hostConflict`, `agentConflict`) clears the claim and shows
core's reason. Identity checks for one host run serially.

**Startup reconciliation** (two stores, not one transaction): a run with an
id and no core row → join again (idempotent); a core row whose run rows are
all Ended or missing → the next Open creates a new run with `resume`, which
is the "Ended with id" path.

A pending run that is **Ended** without an id shows "Codex ended before
Temple learned its session ID. Its transcript is still on <host>." with the
suggestion question above when there are candidates, and **Start a new
session** and **Discard** always. Temple never fabricates a row from a handle.

---

## 4. The keep-alive layer

### Evaluation

Criteria from the owner: the agent survives disconnect, sleep and Temple
quit; reattach shows the live TUI; native scrollback and ⌘F in Temple's
terminal; availability on stock Linux x86_64 and ARM64 (installable by the
user, or shipped by Temple); exit-status and liveness proof; simplicity.

| candidate | survives | reattach shows live TUI | native scrollback / ⌘F | availability | liveness proof | simplicity | verdict |
|---|---|---|---|---|---|---|---|
| **tmux, hidden** (private server, no status, no prefix) | yes | yes: tmux keeps the screen and its own history, redraws at once | no: tmux owns scrollback; mitigated by mouse mode (below); ⌘F sees what the tab has received | `apt`/`dnf`/`pacman` everywhere, both arches; 3.2+ needed (Debian 12 and Ubuntu 24.04 ship 3.3+, Ubuntu 22.04 ships 3.2a) | `has-session`, with a three-valued contract | one binary, one command chain, mature under both TUIs | **chosen** |
| shpool | yes | yes: replays recent output and keeps a vt state | yes: replay fills the terminal's own scrollback, so ⌘F works | not packaged; `cargo install` or a release binary; Temple shipping a Linux binary is the helper path | `shpool list`, `kill` | simple CLI; its daemon needs starting; TUI restore under alternate-screen apps unverified by us | runner-up: the experiment to run if tmux's scrollback feel disappoints |
| dtach / abduco | yes | no: no screen state; a `SIGWINCH` redraw shows only the current viewport, Claude Code's inline history is gone | yes while attached | packaged, tiny | socket present | simplest | rejected on reattach |
| GNU screen | yes | yes | no, worse controls than tmux | packaged | `-ls` | older, fewer knobs | dominated by tmux |
| Temple-shipped helper (own daemon with replay buffer) | yes | yes | yes | Temple copies a binary per arch to each host; version skew; Temple's own code runs on the host | exact (it is ours) | a new program to build and maintain, the worst fit for an experiment that may be dropped | rejected |
| agent-native backgrounds (`claude --bg` + `claude attach`, Codex's app-server `--remote`) | partly | per agent | yes | built in | per agent | two mechanisms, two lifecycles, Claude-only semantics documented | after v1, the direction if the CLIs converge |
| mosh | transport only; no scrollback at all | n/a | no | packaged | none | n/a | rejected |

tmux wins on availability, maturity and proof; it loses on native scrollback,
which the mouse-mode design below turns into "the wheel scrolls history and
drag copies", with ⇧-drag for Temple's own selection. The keep-alive sits
behind one small protocol in the remote module (`KeepAlive`: start-or-attach
command, attach-only command, liveness query, kill), so trying shpool later is
a module change, not a redesign, and so is deleting the whole thing.

### The tmux design, in one command queue

tmux floor **3.2** (`new-session -e`, `prefix None`); `allow-passthrough`
(3.3) is set with `-q`, so 3.2 lacks only OSC 52 passthrough and says so in
the test. A creation is one client invocation, one command queue on one
server: configure, then `new-session`. There is no gap in which an empty
server could exit and a second invocation start another one without `-f
/dev/null`. An attach is a separate, smaller invocation that creates nothing.

**The local side.** `RemoteHostLauncher.prepare` is pure given the spec, the
run row and the resolved environment. Local argv:

```
/usr/bin/env TERM=xterm-256color ssh -t <arguments for the host> -- <name> <remote string>
```

with `TerminalCommand.cwd` = the user's home directory (a valid local
folder; the remote path never becomes a local cwd). `TERM`: Temple's own
terminal identifies as `xterm-ghostty`, which has no terminfo on a stock
host; `xterm-256color` is on every host and is what the attached tmux client
sees, while the pane gets `tmux-256color` from `default-terminal`. The
attached-client test in the sheet (below) proves the pair works on that
host. The remote string is `env PATH='…' TEMPLE_HANDLE='…' sh -c '<script>'
temple-launch <mode> <dir> <marker> [<pane command>]`, every argument
single-quoted with `'\''` for an embedded quote, the one form bash, zsh and
fish read the same way; the handle travels in an environment assignment,
never in a shell word; ids and handles pass a `[A-Za-z0-9._-]` allowlist.
(As built, round 4: the script and its values are staged on the host
first and the remote string is a short runner naming the staged file;
see phase 1a note 22. The script below is the design's first form.)

**Fixed launch script**, arguments `mode dir marker [pane-command]`, in
the design's first form. As built, records live in `~/.temple/launch/<marker>`
(checked private before every use; phase 1a note 6), not under `$TMPDIR`;
the pane is told its config root and Codex home explicitly; the session is
created with `-c /` and the pane enters the folder itself (note 7); and the
script is staged on the host and run by a short executor (notes 22, 23).

```sh
mode=$1; d=$2; m=$3; pane=$4
mdir=${TMPDIR:-/tmp}/temple-launch-$(id -u); umask 077
mkdir -p "$mdir" && find "$mdir" -type f -mmin +1440 -delete 2>/dev/null || m=
rec() { [ -n "$m" ] || return 0; printf '%s\n' "$1" > "$mdir/$m.tmp" && mv -f "$mdir/$m.tmp" "$mdir/$m"; }
s=temple-$TEMPLE_HANDLE
case $mode in
attach)
  exec tmux -L temple attach-session -t "=$s" ;;
create)
  tmux -L temple -f /dev/null \
    start-server \; \
    set -g default-shell /bin/sh \; set -g default-terminal tmux-256color \; \
    set -g status off \; set -g prefix None \; set -g prefix2 None \; \
    set -g set-titles on \; set -g set-titles-string '#T' \; \
    set -g mouse on \; set -g history-limit 50000 \; set -g set-clipboard on \; \
    set -gq allow-passthrough on \; \
    set -g detach-on-destroy on \; set -g destroy-unattached off \; \
    bind -T copy-mode Any send-keys -X cancel \; \
    new-session -s "$s" -c "$HOME" -e PATH="$PATH" "$pane" \
    2>"$mdir/$m.err"
  st=$?
  if [ $st -ne 0 ]; then rec "failed	tmux	$st	$(head -n1 "$mdir/$m.err" 2>/dev/null)"; fi
  rm -f "$mdir/$m.err"; exit $st ;;
esac
```

`new-session` without `-A`: a fresh handle has no session on the host, and
if one is there anyway (a handle reused by mistake), "duplicate session" is
a loud `failed tmux`, not a silent attach to something Temple did not start.

The **pane command** (`$pane`, built by the launcher with the same quoting,
run by the server's `/bin/sh -c`) is `exec sh -c '<pane script>' temple-pane
<dir as typed> <mdir/marker> <agent command>`; the pane does the whole job,
tilde expansion included, so what the test runs through the pane is what
the launch runs:

```sh
d=$1; m=$2; cmd=$3
case $d in "~") d=$HOME;; "~/"*) d=$HOME/${d#"~/"};; esac
rec() { printf '%s\n' "$1" > "$m.tmp" && mv -f "$m.tmp" "$m"; }
cd -- "$d" || { rec "failed	cd	$?"; exit 1; }
rec "ok	$(date +%s)	$(pwd -P)	$$	$(cut -d' ' -f22 /proc/$$/stat 2>/dev/null)	$TMUX	$(cut -d' ' -f22 /proc/${TMUX##*,*,}/stat 2>/dev/null; true)"
exec sh -c "$cmd"
```

`$TMUX` is `<socket path>,<server pid>,<session index>`; the record carries
it, plus the server's start time, so the run row **pins the server** it was
created on: the socket path used for every later attach, `has-session`,
identity check and Stop, and the server pid that negative evidence is
checked against (section 5). The agent command begins with `exec`: `exec
claude <extra args> --session-id <id>` / `--resume <id>`, `exec codex <extra
args>` / `resume <id>`, so the pane pid is the run's first process (Codex's
own launcher may spawn the real binary beneath it; section 3 walks that).

What this guarantees:

- **Evidence comes only from a created pane.** An attach runs no pane
  command and produces no record; a tab that attached gets no
  `.directoryEstablished` and claims no folder. The enforcing `cd`, the
  tilde rule, the remote timestamp, the canonical directory (`pwd -P`), the
  server pin and the exec are all inside the pane, so `ok` means the agent
  is running in that directory, on that server, and nowhere else.
- **Creation and attachment are different commands**, chosen by Temple from
  the run's state, never by a racy pre-check on the host.
- **Configuration failures keep their reason**: tmux's stderr goes to a file
  and the first line travels in the `failed tmux` record, which the
  launch-failure header shows, and which means "creation not proven"
  (section 3).
- **Records are atomic** (`mv` over a temp file in the same directory).

The Hosts test executes **this exact chain** detached (phase 0); the
attached run below is the Linux acceptance's, not the Test sheet's (as
built, phase 0 note 2: the sheet's terminal runs the user's ssh and nothing
else). Detached, on a throwaway socket, from the sheet's query
phase: `tmux -L
temple-check-<nonce> -f /dev/null <the same configure commands> \;
new-session -d -s check -c "$HOME" -e PATH="$PATH" 'exit 0' \;
kill-server`, stderr captured. Attached (as built, the Linux acceptance's,
not the sheet's; phase 0 note 2): the acceptance launches and attaches a
real session through Temple's own chain, reads the attached client's
`client_termname` from tmux and the pane's `TERM` from its
`/proc/<pid>/environ`, and runs `tput -T xterm-256color colors` and
`tput -T tmux-256color colors` on the host, so an attached client under
`TERM=xterm-256color` outside and `tmux-256color` inside is proven on that
host; it then stops the session. The detached check passes only when
every command the launcher will send is accepted; the row shows tmux's own
line when one is not (including "allow-passthrough: not on this version,
clipboard passthrough off" when `-q` had to swallow it, detected by
`tmux -V` after the chain passed).

### Scrolling, selection, find under tmux

The trade-off the owner accepted: scrollback belongs to tmux. Making it feel
natural:

- `mouse on` with tmux's default root bindings: a wheel in a pane running an
  alternate-screen app that asked for the mouse (Codex's TUI) goes to the
  app; otherwise (Claude Code's inline output) `WheelUp` enters copy-mode
  with `-e`, so the wheel scrolls tmux's 50,000-line history and scrolling
  back to the bottom leaves copy-mode by itself.
- `bind -T copy-mode Any send-keys -X cancel`: the first key typed while
  scrolled back returns to the live screen; that key is consumed, the next
  one types. Said in the Shortcuts card: "In a session on a host, scrolling
  up shows history; the first key you type returns to the prompt."
- Drag-select is tmux's: the release copies to tmux's buffer and, with
  `set-clipboard on` and libghostty's `clipboard-write = allow` for remote
  tabs, to the Mac clipboard through OSC 52. ⇧-drag selects in Temple's own
  terminal (libghostty's default `mouse-shift-capture`), for the rare case.
- **⌘F stays libghostty's find (ADR-016)** over what the tab has received
  since it connected; tmux redraws only the visible screen on attach, so
  earlier output is in tmux's history, not the tab's. The find bar in a
  remote tab carries one line: "Searching what this tab has shown since it
  connected to <host>." Routing ⌘F to tmux's search is after v1.
- Resize: tmux follows the attached client; one client per session in
  Temple's model, so no size fights.

---

## 5. Lifecycle: exit proof, close, stop, quit

Amends ADR-010 for remote hosts: *an agent on another machine is not
Temple's child process. Closing its tab still ends it when it is idle, as
locally; an agent that is working is detached, not killed, unless the user
chooses Stop; and an end Temple could not carry out and confirm at that
moment is recorded as left running and listed for the user, never performed
later on Temple's own initiative.* The tab's ssh
process is a tmux client; its exit proves nothing about the agent, whatever
its status.

**The liveness contract**, from `tmux -S <pinned socket path> has-session -t
"=temple-<handle>"` (the socket the run was created on; `-L temple` only
when a run has no pin yet) with stderr captured, bound to the attachment
that asked:

| result | meaning | authorizes |
|---|---|---|
| exit 0 | **present** | nothing automatic; the tab is kept with "Disconnected from <host>. Open the session again to reconnect." |
| exit 1, stderr `can't find session` | **positively absent**: the pinned server answered and does not have it | automatic close of a tab that was running; `ended_at`; the next Open with an id creates a new run with `resume` |
| exit 1, stderr `no server running on <socket>` or (tmux 3.2a) `error connecting to <socket> (No such file or directory)` | **unknown** in v1: tmux can lose its socket while the server lives (it documents `SIGUSR1` to recreate it), so a missing socket is not proof that the agent is gone | nothing automatic; attach-only plus the explicit button. A repair path (pin the server pid and start time, send `SIGUSR1`, retry, auto-resume when the pid is gone) is designed but **deferred** until acceptance shows the case occurs in practice |
| anything else: 127 (no tmux on PATH), ssh 255, deadline, `protocol version mismatch`, `error connecting to … (Permission denied)`, an unreadable `/proc` | **unknown** | nothing; the tab is kept with "Disconnected from <host>. Temple can't tell whether <agent> is still running there: <first stderr line>." |

Only a positive absence closes a tab or marks a run Ended; unknown never
does, and from Unknown every Open is attach-only. The launch wrapper never
consults liveness (section 4). Results are dropped if the attachment moved
on, the user closed the tab meanwhile, or the app is quitting.

The explicit way out of Unknown (and of a pending Codex launch that Ended)
is a button in the kept tab's header and the chip's menu. "Run" is internal
vocabulary and never appears on screen. As built (phase 1b decision 5 and
Fable's final copy), each confirms in a sheet with a short title, one
sentence, and the stop command apart and selectable ("To stop the original
on <host>, run:" `tmux -L temple kill-session -t temple-<handle>`). With a
known id: **Resume anyway?**, "Temple can't reach this session on <host>
and can't tell whether it is still running. If it is, it keeps running."
For a pending Codex launch: **Start a new session?**, "Temple can't tell
whether Codex is still running on <host>. If it is, it keeps running, and a
new session starts beside it."  Internally both create a new run under a new handle
(`resume <id>`, or a fresh `codex`); the old run row is kept (not Ended) so
the hint stays truthful and Stop can still reach it when the host answers
again.

**When the tab's ssh exits**: the final record collection (one bounded
fetch, 5 s), then the exit check, then the table above. The early-exit grace
and the launch-failure header apply as today when a `failed` record exists.

**Close tab** (⌘W, ✕, CLI `close`), the same meaning as a local close:

- Agent idle (today's activity gate on the live tab, the same signal a
  local tab uses to decide whether to ask "still working"), host reachable
  → **Stop**: the kill-session query below; its acknowledgement (exit 0) is
  the end evidence, the client exits, `ended_at` is set, the tab goes. No
  prompt, exactly as an idle local tab closes. Reopening later is a new run
  with `resume` from the transcript. A pending Codex launch that is idle
  (as built, phase 1b note 12) gets one more identity check, then the same
  stop: identified, its tab closes like any; unidentified and typed into,
  the tab stays with one band, "Codex ended on <host> before Temple learned
  which session this was. Is it “<first prompt>” (<time>)?", Yes, Not this
  one and Start a new session after it and Discard at the edge (remote UX
  round 1), and where its terminal was one line, "Codex's last screen on
  <host> isn't kept after it ends." (simplification round); never typed into,
  Temple stops tracking it. The decision is made from what
  Temple observed on the connected tab; nothing on the host is asked to
  judge idleness.
- Agent working → "Claude Code is running on <host>." (as built since the
  owner's round 2 visual review; it was "is still working on") with the
  message "Detach leaves it running; Stop ends it." (remote UX
  round 1, the same alert shape as local's) [Detach]
  (default) [Stop] [Cancel], decided synchronously in the tab's own prompt.
  Detach is `terminate()` on the local ssh client; the agent keeps working
  and the session becomes Detached (a chip, or nothing visible beyond the
  sidebar row).
- Host unreachable at close (the tab already shows "Disconnected", or the
  stop query fails, times out, or reports another client attached) → the
  session is **left running**: `left_running_at` and the reason on the run
  row, the tab goes, one notice: "Left running: <host> didn't answer when
  you closed it. Stop it under Sessions on <host>." (or "…someone else is
  attached to it."). Nothing is scheduled; nothing happens later without
  the user pressing Stop.

**Nothing is stopped later.** There is no deferred stop, no sweep, no
request to carry out at the next contact, and no lock: two review rounds
showed that any automatic kill decided after the fact needs idle evidence
Temple cannot obtain remotely (silence is not idleness) and fencing Temple
cannot guarantee across processes and a network. The one destructive action
is a Stop the user performs, carried out at once or not at all, and the
Sessions on <host> sheet is where what was left is seen and stopped.

**Disconnect without close** (sleep, network): nothing changes on the host;
the tab stays "Disconnected" and the next Open attaches. Closing that kept
tab is a Close as above (Stop now if the host answers, left running if not).

**The Remote sessions sheet** (Hosts card → "Sessions…", a host project
heading's context menu → "Sessions on <host>…", and
offered by every notice above): per enabled host, the sessions **Temple
started and still tracks** there (runs not Ended), each with its row's
title (the tmux name `temple-<handle>` as its tooltip), each asked about on
its own pinned server, its state in a slot of its own ("In a tab"
when this Temple has a connected tab of it, "Running" otherwise, even with
another client attached, or "Unknown"; remote UX round 1), with
Stop / Keep (Keep clears a left-running flag, Fable's must-fix 6; a
pending Codex session also has Open); a session flagged left running shows
its notice ("Left running: <host> didn't answer when you closed it.") and
the same Stop button, which runs the one-command kill below. A run that its pinned
server says is gone is Ended and leaves the list; one Temple can't check
stays, and the sheet says "Temple couldn't check these sessions"; an empty
tracked list reads "No sessions started from Temple." (as built, phase 1b
decision 5). The sheet is offered by
every left-running notice; at launch it is never opened by itself: a host
with left-running flags that answers gets one line in the sidebar's notice
area, "2 sessions left running on <host>", with Show and a dismiss, shown
once per flag (Fable's must-fix 6). **Temple
never discovers or stops a session it did not start** (owner's decision,
phase 1a review): there is no listing of the private server and no "Not in
Temple" row, and it never lists or touches the user's own tmux server.

**Stop**, as built (astra's implementation notes 4 and 5, phase 1a note
8). Temple first ends its own client on this Mac (the tab's ssh), then one
query waits up to a moment for the session's attached count to reach zero,
and runs one non-yielding tmux command queue in one client, so nothing can
attach between the check and the kill:

```
tmux -S <pinned socket> has-session -t "=temple-<handle>" \; \
  if-shell -F -t "=temple-<handle>:" '#{==:#{session_attached},0}' \
  'kill-session -t =temple-<handle>' \
  'display-message -p temple-not-killed'
```

The condition is always zero attached clients: an attachment count is not
a client's identity, so Temple never counts its own client as allowed.
`has-session` comes first because `if-shell` on a missing session does not
fail. `if-shell -F` evaluates the format inside the server and runs the
chosen command in the same queue. **Its acknowledgement is the end
evidence**: a successful query with no `temple-not-killed` output sets
`ended_at` with `end_evidence: killed`, whatever a follow-up check would
say. That matters in the ordinary case: stopping the last session makes the
private server exit, and a later check reads "no server running", which is
Unknown in v1 (section 5's liveness table). Never "exit 0" alone: the
false branch exits 0 too. `temple-not-killed` means another client is
attached: the session is left running with that reason and the notice says
so. A lost acknowledgement (deadline, ssh dropped mid-query) also leaves it
running, and it is never retried automatically (a cancelled query may
already have taken effect): the tab's header, or the notice, reads
"Temple couldn't stop <agent> on <host>: <reason>. It may still be running;
see Sessions on <host>." No fencing follows: a later Open simply attaches
if the session survived, or resumes if the pinned server says it is gone.
Also in a remote row's context menu as "Stop on <host>" when a run row
exists. CLI `close` on a working remote tab is refused ("Its agent is
working on <host>. Pass --force to detach, or stop it in Temple."); `--force`
detaches, never stops.

**Quit** (`windowShouldClose` → `applicationShouldTerminate` → drain, per
AGENTS.md): the question is asked in `windowShouldClose`, synchronously,
and counts **local** working tabs only; when remote tabs are connected the
text gains one line, "Sessions on <host> keep running; Temple will
reconnect to them." **As built (owner, round 2): Temple stops no agent on a
host at quit, working or idle.** Every live client of a tab on a host is
detached; every run, pending Codex ones included, is left as it is and
comes back as a tab next launch, where closing it stops it. The idle stop
described in step 2 below, its live-master check and its `host did not
answer` record are gone (they were decided from the settle timer's reading,
which can take a long, quiet tool call for idle). The quit sequence as it
exists in code today is kept, with remote work fitted inside it:

1. `openSessions.prepareForQuit()` freezes the open-tab set, as today.
2. `drainAll(graceful:detach:stops:completion:)`, the existing 3 s surface
   drain: graceful surfaces (local) get today's exit request, wait,
   terminate; detach surfaces (as built since round 2: every live remote
   client, working or idle) get
   `terminate()` at once and no graceful-exit input (that input would reach
   the agent through tmux); **superseded by round 2**: `stops` were **remote stop operations** for the
   remote tabs whose gate is idle and whose host has a live master, and that
   this launch attached to (a chip restored and never opened is never
   stopped, phase 1b round 2 ruling 2). Pending Codex runs follow the same
   policy (round 1 ruling 5); a stopped one that was typed into keeps its
   ended record so the next launch still asks, and an unused one is
   dismissed. Each stop is the one-command Stop above, dispatched in
   parallel, one query per run, inside the same window. The tab's own client
   is terminated first, before the stop is sent, so the server-side
   zero-attached check can succeed (as built, `startQuitStop`). At the
   window's deadline every outstanding query client is cancelled (killed),
   exactly as a local straggler is terminated, and its session is recorded
   **left running** with reason `quit deadline`; a host with no live master
   is not asked at all (left running, `host did not answer`). As built since
   round 2, the only stops in the window are ones a close started before the
   quit; one outstanding at the deadline is left running, `quit deadline`.
3. The engine shutdown barrier as it exists (`engineSet.stopListening()`,
   then `engineSet.shutDown(timeout: 2 s)` on main, commit 4dc203a) runs
   unchanged after the drain; the remote store's pending writes are flushed
   inside that same 2 s, sharing its deadline and never extending it. A
   write that misses the deadline is a left-running row that may lack its
   flag; the session stays a tracked, detached run, listed by its row in
   the sheet with Stop / Keep, so nothing is lost but the notice.

**Durable completion is separate from UI callbacks.** Section 3's rule that
asynchronous results are dropped during quit applies to tab-side effects
(headers, activity, chips). A stop's acknowledgement is a **durable
completion**: it writes `ended_at` in the remote store whenever it arrives
before the barrier closes, whether or not any tab still exists to show it.
An acknowledgement that arrives after its client was cancelled cannot arrive
(the process is gone). Completion is always asynchronous, even with no tabs
at all. Quit is never delayed beyond today's 3 s drain plus the 2 s barrier
by any host.

After relaunch, a chip for a session still running attaches (as built since
round 2, every session on a host that had a tab is still running unless it
ended by itself); a chip for a stopped or ended session starts a new run at
once and resumes from the transcript, exactly as a local tab is respawned
with `--resume`.

**Canonical directory reconciliation.** When `ok` arrives, its `pwd -P` may
differ from the intent (`~/project` → `/home/mentes/project`, a symlink
resolved). One operation, `OpenSessionsModel.applyLaunchDirectory(tab,
canonical)`, does all of it: the row (today's `launchDirectoryHandler`, the
`tab`-sourced fill), `SessionTab.projectPath` and so its `projectKey`, the
active-project bookkeeping and project recency, the launch row's
`directory`, and the next `open_tabs` save. Sidebar and History keep
deriving grouping from `session_state`; the launch row's copy is launch
intent and a restore fallback, never a competing fact.

**Restored chips** for remote tabs carry host and handle and attach on
activation; a pending Codex launch restores as "New Codex session" under its
host project from the launch row alone, with its chip title and intent
directory.

---

## 6. `RemoteSessionSource`

One type in the new `TempleRemoteHost` module (same boundary rule as
`TempleLocalHost`: `TempleUI` imports it in `Sources/TempleUI/Hosts/
RemoteHost.swift` only; `ModuleBoundaryTests` gets the second allowed
import). Built on `RemoteExec` (`run(script:args:deadline:) async throws ->
Output`), production `SSHExec`, test `LocalShellExec` (the same scripts under
`/bin/sh` against a temp `HOME`). One actor per host, concurrency 2,
`locate`s within 250 ms coalesced.

`capabilities`: `[]`; `isMonitoring` false.

**What enrichment actually does, with the engine as it is.** `SessionEngine`
loads every unarchived member of its host at startup and locates them in one
batch; a transport failure defers the batch with a backoff that doubles to a
60 s cap and retries until it succeeds; an explicit open locates with
`refresh: true`; a listing that completed with nothing for a member settles
it `incomplete` when its agent's listing is not in `complete`, and nothing
schedules a retry after that. So, honestly:

- At startup, one locate exec per remote host for every unarchived member
  (as built: the engine locates and verifies every member, not only rows
  that want a field), and one identity read per member with a candidate,
  two execs at a time and 64 KiB each; facts are parsed only for rows that
  still want a field. Accepted for v1 (phase 2 round 1, astra's decision;
  the engine stays generic). Then nothing until an open, an import, a
  membership change or a relaunch.
- A host that is unreachable costs one failed exec per backoff step. The
  source adds a **circuit breaker**: after 3 consecutive transport failures
  it answers `.transport("<host> unreachable since <time>; next try at
  <time>")` without spawning ssh for 10 minutes; an explicit open
  (`refresh: true`) bypasses the breaker once. The engine's cadence is
  unchanged; what changes is that it stops costing processes.
- `complete` is always empty: a `find` over ssh is not an audited listing
  (ADR-032), and without a change stream a row that settled `absent` would
  stay dimmed until the next open. Consequence, stated in the ADR: remote
  rows are never `confirmedAbsent`, never dimmed, never tagged "No
  transcript", and never auto-archived for it.

Primitives:

- **`locate`**: one exec; per `(agent, id)`: Claude `find "$HOME/.claude/
  projects" -mindepth 2 -maxdepth 2 -name "<id>.jsonl"`, Codex `find
  "$HOME/.codex/sessions" -name "rollout-*-<id>.jsonl"`. As built (phase 2
  notes 3 and 5, round 1 notes 2 and 5) the answer is typed and byte-safe:
  each group's records are `type TAB size TAB mtime TAB inode TAB path`
  (GNU `-printf` with `%y`, or `test -L`/`-f` and `stat -f` under BSD), each
  NUL-terminated, followed by `S<find's status>`, the whole hex-encoded on
  one `list <group> <hex>` line after a `root <group> ok <hex>` line; hints
  answer `hint <hex path> …`; the answer ends with `done`, and anything not
  well formed is a transport failure (`RemoteTranscripts.locateScript` and
  `parseLocate`). The
  roots are the ones the session's latest run recorded (or the login
  environment's for a row with no run), Codex also matches reverts
  (`rollout-*-<id>_*.jsonl`), links are unreadable, and the row's recorded
  path is stat'ed as a hint inside its store. Paths compare by bytes
  (`RemotePath`).
  Candidates get roles from `TranscriptCandidates.assign`; `coverage` bumps
  on the first locate after a transport failure; a thrown exec is
  `LocateError.transport(<first stderr line>)`.
- **`read`**: one exec printing a framed record, each part length-prefixed:
  opening stat, identity bytes, when `facts` the head and tail windows and
  the agent's shared inputs (Codex: the lines of `session_index.jsonl` and
  of `history.jsonl` that contain the id, `grep -F`; as built, phase 2),
  closing stat, under a 6 MiB response budget checked on the host. Formats stay pure; a
  `needsWiderHead` is one more exec; stats that differ are retried three
  times then `.changedDuringRead`. `identity` is the inode.
- **`changes()`**: yields nothing; ends only with the consumer.
- **`adopt`**: as built, always inconclusive. Codex identity on a host is
  the run store's (`RemoteSessions`: section 3's check by the pane's own
  process, and the suggestions the user confirms), not the source's.
- **`directoryEvidence`**: as built, always `.unknown`, never `.missing`
  (phase 2: History and the folder sweep ask it per project, and no remote
  decision uses `.exists`).
- **`proveAbsent`**: `.unproven`, always.
- **`catalog`**: not offered; yields one `.storeFailed` and ends if called.

Transport failure is never absence: locate throws, read throws, evidence is
unknown, proof is unproven, adoption is inconclusive.

---

## 7. Hosts in the interface

### The Hosts connection manager (Settings, under Agents)

- **The list** (as built, UX round 2): one **In use** list of every enabled
  host, whichever source it came from, sorted by name. Each row: the name
  (13 medium), a mono 11 secondary caption saying where it came from (the
  address summary for a host added in Temple, `~/.ssh/config` for an
  alias, orange "No longer in ~/.ssh/config" for an enabled alias the config
  no longer names, once the config has been read), then **Test
  connection**, **Sessions…**, and **Edit** and **Remove** (added in
  Temple) or **Turn off** (an alias); the status line under it. Empty:
  "No hosts in use." Hosts not in use are not listed. Last, **Add host…**.
- **Add host…** (as built, UX round 3, Fable's option 3) is a sheet in the
  folder sheet's shape (`AddHostSheet`): 520 pt, padding 20, "Add host" at
  15 semibold, one autofocused **Host** field (mono 13 on the control fill,
  placeholder "alias from ~/.ssh/config, or user@address"). Under it, the
  config's aliases not in use (every `Host` entry, one level of `Include`,
  wildcards and `Match` skipped; a host added in Temple under an alias's
  name takes that alias out too) as rows, mono 12, each one click target:
  the alias in the link colour in a fixed 200 pt column (middle truncation,
  so the next column stays put as rows filter or expand), then in
  secondary the `user@hostname` the alias's own `User` and `HostName` set
  (`%h` expanded; the alias as hostname when only `User` is; nothing when
  neither is). "Own" is read as ssh reads the file for that name: statements
  in order through `Include` (an included file continues the block it
  appears in, which is restored after it; one included where nothing
  applies matches nothing), first value wins, and only a `Host` line
  naming the alias makes its lines the alias's own (`Host *` and `Match`
  don't; a `Match` is never evaluated). Ranked: an alias whose own
  blocks set `User` or `IdentityFile` first, a bare one (no login set, its
  `HostName` absent or the alias itself, like `github.com`) last, the rest
  between, the config's order within each; nothing is hidden. The field
  filters live, ignoring case (aliases it starts, then those it is inside
  of). Six rows (filtered or not), then **Show N more** (the number
  hidden, as the sidebar says it), which shows every match (the sheet
  grows; no scroll view). A row turns its alias on at once and closes the
  sheet. Return (or **Add**, disabled while the field is empty) adds what
  the field holds, a name matched exactly first, then ignoring case when
  only one matches: an offered alias turns on; a host already in use says
  "<name> is already in use." and the sheet stays; anything else is read as
  `user@address[:port]` (an IPv6 address in brackets for a port; the
  bracket must end the text or come right before the port) and opens the
  form below prefilled, the name from a host name's first label. Text that
  can't be read so stays in the field with a note. A Return while the
  config is still being read waits for the read (a spinner by Add, which
  is disabled meanwhile) and is then decided against the new list, so an
  alias not yet listed is never taken for an address; typing again drops
  the wait. Esc
  cancels. Under the list: "Not in ~/.ssh/config? **Enter details…**" (the
  form, empty) and **Edit ~/.ssh/config** (the file, in the user's editor;
  the sheet closes, and reopening it reads the file again). With no alias
  to offer: "No hosts in ~/.ssh/config." or "Every host in ~/.ssh/config is
  in use.", field and footer only. The config is read when the card is
  shown and again as the sheet opens, never at launch, off the main actor
  (the newest read wins; the sheet shows the last read's rows until it
  ends), in one pass over the statements for every alias (a walk per
  alias was quadratic: seconds for 5,000 aliases). **Opening the sheet
  runs nothing.** A first build ran `ssh -G` per row shown; Sol's review
  pointed out that `ssh -G` evaluates a config's `Match exec` commands, so
  merely opening the chooser ran them for aliases nobody chose. `ssh -G`
  runs only where it did before: a Test connection, or a host in use.
  **Superseded**: the AppKit menu at the
  click (UX round 2: the unused aliases, or disabled why there were none,
  a divider, Enter details… and Edit ~/.ssh/config); the owner found it
  looked bad.
- **Superseded** (the card): the earlier card's two lists by source, **Added in
  Temple** and **From ~/.ssh/config** (every alias with a switch). The
  owner read "Added in Temple: No hosts added yet." as no hosts while a
  config host was on; Fable's next design (one In use list, the config list
  reduced to a chooser of unused aliases with switches) was overridden by
  the owner, who found listing hosts not in use unnecessary, so the
  chooser became the Add host… menu (itself superseded by the sheet above).
- **Enter details… / Edit**: **Name** (the `HostID`; `[A-Za-z0-9._-]`, not
  starting with `-`, not an existing config alias; fixed once saved: "The
  name can't be changed later. Address, user and port can."), **Address**,
  **User** (optional), **Port** (optional, 1 to 65535), **Identity file**
  (optional path, chooser, "Adds this key to the ones ssh tries"), **Jump
  host** (optional `ProxyJump`). **Save**, **Save and test**, **Copy as ssh
  config**. Note: "Temple passes these to your own ssh. Passwords and keys
  are never stored; ssh asks for them when it connects."
- **Enabled hosts are registered whether or not they were tested.** The
  registry is rebuilt from the enabled list whenever it changes (added or
  removed entries get their engine started or stopped; the local engine is
  untouched). Test results are diagnostics and proven incompatibilities;
  an enabled host with expired authentication after a relaunch still has
  its launcher, so opening its row shows ssh's prompt in the tab, which is
  the recovery route.

The check (sheet, after a successful connect; re-run by Test connection):

1. `command -v claude`, `claude --version`; the same for `codex`; each with
   status, framed.
2. tmux by executing the exact launch chain, detached, on a throwaway
   socket (section 4). The row reads "Detached tmux check passed"; an
   attached client is phase 1a's acceptance.
3. logind: `busctl get-property org.freedesktop.login1
   /org/freedesktop/login1 org.freedesktop.login1.Manager KillUserProcesses`
   where `busctl` exists; `true` → an advisory row: "This host ends your
   processes when your last login ends (KillUserProcesses=yes). Sessions
   won't survive a disconnect unless lingering is enabled (loginctl
   enable-linger)." Temple changes nothing.

Status copy (what Temple knows; no em-dashes): "Not tested yet. Test the
connection to check this host." / "Connected as <user>@<address>. Claude Code
2.1.283, Codex 0.52.0, tmux 3.4." (from `ssh -G`) / "No claude on PATH." /
"claude is there but didn't run: <its first line>." / "tmux 3.0a: Temple
needs tmux 3.2 or newer to keep sessions running." / "No tmux on this host.
Install tmux 3.2 or newer to start sessions here." / "tmux 3.2a: clipboard
passthrough is off on this version." / "Couldn't connect: <ssh's first
line>." (with the host-key variants) / "Didn't answer within 10 seconds." /
"Couldn't read the login shell's PATH: <reason>; using ssh's default
environment." Sheet rows: "Login shell: /usr/bin/zsh, PATH read." /
"claude: 2.1.283 at /home/mentes/.local/bin/claude" / "codex: not on PATH" /
"tmux: 3.4, launch chain accepted" / "tmux: 3.0a, `prefix None`: <tmux's
line>".

`availability(agent)` is `.unavailable(reason:)` only when a test
*connected* and the CLI or tmux did not run; `.available` otherwise,
including "not tested yet" and "couldn't connect". Only a failure can be
proven; no tick. ⌘N and the launcher list every enabled host whose last
test did not prove tmux missing.

### Starting a session on a host

- ⌘N: remote project rows read "project @host"; below **Choose folder…**,
  **Folder on <host>…** per listed host. Launcher: **New session on
  <host>…**. Project `+` and ⌘T are host-aware already.
- The folder sheet: a text field ("Folder" since remote UX round 1, the
  sheet's title naming the host; placeholder
  `/home/<user>/Projects/…` or `~/…`), the host's recent folders beneath,
  Return to confirm. Confirm runs an advisory `cd -- <path> && pwd -P` query
  (same `~` rule as the pane): success shows the resolved path and starts;
  "No folder <path> on <host>." stops; a transport failure offers **Start
  anyway** and **Test connection**. Whatever the sheet resolved is intent;
  the row records a folder only from the `ok` record, through
  `applyLaunchDirectory`. Meanwhile the sidebar shows the
  project heading from the tab's folder as a display hint (remote UX round
  1), never written anywhere.
- A remote folder path means an absolute path on that host as the ssh login
  user sees it, spelled as the host's `pwd -P` spells it.

### How a remote row and tab look

Sidebar section (as built, UX round 2): one 28pt line for every heading,
local or not. After the name (unchanged), `@host` as the host spells
itself, 11pt regular, tertiary, no tracking, never uppercased, truncated in
the middle; then the rule. Room gives way in order: the rule first (down
to 12pt), then the host, the name last (the host showed only "…" at the
default width while the rule split the line evenly with name and host;
computer-use pass on 99eb8e8). Tooltip
`host:/absolute/path`. The hands-on T1 design (a second line under the
name with the globe and the host) is **superseded**: the owner found the
host line read like a session row. Remote tab headers: the exit table's lines, "Claude
Code failed to start on <host>." with the agent's argv (never the wrapper),
the pending-Codex lines. A row whose host was removed: "Host <name> is not
set up. Add it in Settings to open this session."; no query goes to a host
not in the list.

---

## 8. Data

**Host identity is the host's name**, `HostID(rawValue: name)`: the config
alias or the form's Name; the empty string stays this Mac. Fixed once saved;
address, user, port, identity file and jump host change freely without
touching a row. Rejected: a host UUID (a table and an indirection for a
property the name has); `user@hostname` (changes when the box moves).

**Session ids stay globally unique in `session_state`**; host is an
attribute, and a join or adoption for an id already present on another host
or as another agent is refused and shown. "Already host-keyed" means
`ProjectKey` and the row's host, not the primary key.

### Core (generic, meaningful with no remote at all)

- **The core schema does not change.** `session_state` is untouched
  (`host`, since v10, is the only host-aware column); `open_tabs` and
  `project_state` are untouched; no migration lands, so no older-build
  window exists and the AGENTS.md "additive until remote ships" rule stands
  as written. `v13-project-host` stays reserved and unused.
- Why no `open_tabs.host` is needed: session ids are globally unique in
  `session_state`, so a restored tab's host is its row's host, which is the
  rule the ADR-029 interim already states and phase 1 uses; a pending Codex
  tab has no id and no `open_tabs` row, and restores from the remote
  store's `runs`. No case survives in which an `open_tabs` row needs a host
  of its own. Two projects with the same path on two hosts still share the
  `(project_path, position)` primary key, so `position` is numbered per
  `project_path` across hosts on save and the key never collides. Remote
  project archive and order live in the remote store (below), so
  `project_state`'s `path` key never meets two hosts.

### Remote-owned storage (deletable without touching core)

- **Host definitions**: `UserDefaults` `temple.settings.remoteHosts`, JSON
  `[{name, source: "config" | "temple", address?, user?, port?,
  identityFile?, proxyJump?}]`, explicit decoder (`decodeIfPresent`, an
  entry without `source` reads as `config`). The user layer; nothing
  detected is written back. Read and written through
  `TempleState.settingsDefaults`, like every setting, so a demo's host list
  follows `TEMPLE_DEFAULTS_SUITE` and never touches the installed app's.
- **`remote-state.sqlite`** in the state dir, owned by `TempleRemoteHost`
  with its own GRDB migrator (`r1-runs`), the ADR-032 precedent of a
  feature-owned SQLite file beside the core one:
  - `runs(handle TEXT PRIMARY KEY, host, agent, mode, session_name,
    directory_intent, directory, session_id, attachment, record_path,
    started_at, ok_at, pane_pid, pane_start, socket_path, server_pid,
    server_start, creation ('proven' | 'unproven' | 'failed'), ended_at,
    end_evidence ('absent' | 'killed'), left_running_at,
    left_running_reason ('host did not answer' | 'stop not acknowledged' |
    'another client attached' | 'quit deadline'), dismissed_at, failure)`.
    As built, migrations `r2-conversation` to `r5-input` add the
    conversation flag, the config root and Codex home the pane ran with,
    `claim` (`verified`, `confirmed` or `automatic`), `joined_at`,
    `tab_closed_at` and `input_seen_at`; uniqueness is
    on claims (`runs_claim`, section 3), not on every row.
  - `declined_candidates(handle, rollout_path, PRIMARY KEY (handle,
    rollout_path))`: suggestions the user said no to.
  - `remote_project_state(host, path, archived, position, PRIMARY KEY
    (host, path))`: remote project archive masks and their part of the
    manual order. The overlay writes the local part to `project_state` and
    the remote part here in the same operation; restore/undo of a remote
    row's siblings writes this table where today it writes `project_state`
    for local ones. The two files are not one transaction. The crash window
    is a remote mask out of step with its rows; there is no remote sweep,
    so **recovery is another user action**: Restore (or Undo) rewrites the
    mask from the rows as it always does. Said in the ADR as an accepted
    limitation of the experimental store.
  - Per-row read-modify-write inside `remote-state.sqlite` transactions; no
    whole-array rewrites, so two Temple processes cannot erase each other's
    handles.
- **Memory only**: the login-environment cache (PATH, `CLAUDE_CONFIG_DIR`,
  `CODEX_HOME` as the login shell reports them, per connection), test
  results, `ssh -G` resolution and the ControlPath derived from it, breaker
  state. **Persisted with each run** (above, `runs`), by contrast: the
  pane's evidence, its pinned socket path and server, and the config root
  and Codex home it ran with.
- **On this Mac**: the masters' socket files in `<state dir>/ssh/` (or the
  short fallbacks, section 2).
- **On the host**: `~/.temple/launch/` records and staged launches (a
  private directory, checked before every record operation; see the phase
  1a notes), the `-L temple` tmux socket, and short-lived `umask 077`
  temporary files under `$TMPDIR` for the environment query and transcript
  reads (`temple-env.*`, `temple-read.*`, removed on exit). Test
  connection's tmux check uses a throwaway socket it kills.

---

## 9. Removing remote

Deleting the feature, should the experiment end:

- **Code**: the `TempleRemoteHost` module and `Sources/TempleUI/Hosts/
  RemoteHost.swift`; the Hosts connection manager and the Test connection
  sheet; the remote rows in ⌘N and the launcher; `RemoteTabController`
  (every remote tab's open, exit, close, quit plan, identity and
  retirement; as built in phase 1b it holds what were the remote branches
  of `OpenSessionsModel`, which keeps only thin seams into it). (There
  was a feature flag until the owner's round 2; there is none now.)
- **Storage**: `remote-state.sqlite` (deleted), `UserDefaults`
  `temple.settings.remoteHosts` (removed), `<state dir>/ssh/` and the
  fallbacks `$TMPDIR/temple-ssh-<uid>/` and `/tmp/temple-ssh-<uid>/`
  (socket files removed; masters are never terminated, they expire through
  `ControlPersist`).
- **Agents left on hosts**: deleting the mappings does not stop anything on
  a host, and must not do so silently. With close meaning stop (section 5),
  what can remain are working agents the user detached from, sessions left
  running because a host did not answer when they were closed. The **Remote sessions
  sheet** (section 5), a standing part of the Hosts card, is the right thing
  to open before an uninstall: Stop or Keep, per session (as built; there is
  no Stop all). The manual form for anyone
  reading the release notes later: `tmux -L temple ls` and `tmux -L temple
  kill-session -t temple-<handle>` on the host, or `tmux -L temple attach -t
  temple-<handle>` to pick one up in any terminal. Keep is the default: a
  kept session keeps working and is reachable by its name; what is lost is
  only Temple's map from row to handle.
- **Core rows a user keeps**: every `session_state` row, including those
  with a non-empty `host`, exactly as ADR-029 keeps rows whose transcripts
  are elsewhere: they list in History under In Temple, can be searched,
  renamed, archived, and open to "Host <name> is not set up" (which is what
  a removed host shows today). `open_tabs` rows whose session row names a
  host restore as those "not set up" chips and are dropped on the next
  save once closed. `open_tabs` and `project_state` were never changed, so
  there is nothing to migrate back.
- **What remains in core by design**: `host` in `session_state`, `HostID`
  and `ProjectKey` (all pre-existing, ADR-029), the
  `HostSessionSource`/`HostLauncher` seams. Nothing else.

---

## 10. Security and safety

- **No credentials, ever.** Temple runs the user's `ssh`; keys, agents,
  passphrases, 2FA and jump hosts are ssh's business. A Temple-added host
  contributes `HostName`, `User`, `Port`, optionally an `IdentityFile`
  *path* and a `ProxyJump` value, as `-o` options; the record holds those
  strings and nothing else. No `-i`, no password, no passphrase, no
  `StrictHostKeyChecking`, no `UserKnownHostsFile`, no `IdentitiesOnly`.
  Nothing secret in `UserDefaults`, either database or logs.
- **The user's ssh config is never written.**
- **Interaction only where the user can see it.** Background queries are
  `BatchMode=yes`; the test sheet and session tabs are the places ssh may
  ask.
- **Never on a host the user didn't pick.** Queries go only to enabled
  hosts, and only for a user action or for rows and launch rows that name
  that host. Removing or disabling a host stops every query to it at once.
- **Fixed script text, positional arguments, one quoting function**, tested
  on quotes, spaces, newlines, `'\''` and the nested pane command; ids and
  handles pass an allowlist; the handle travels in an environment
  assignment.
- **What Temple writes on a host**: the record dir and the `-L temple`
  socket, umask 077. Temple never kills the user's own tmux server, never
  `kill-server`s its own, and `kill-session`s only a session named by one
  of its own handles.
- **Shared masters are never terminated by Temple.**
- **Extra arguments apply remotely too**, `--dangerously-skip-permissions`
  included; the Hosts card says so.

---

## 11. Testing

**Execution over goldens.**

- `RemoteScriptsTests`: the launch script, the pane script, the locate,
  read, adopt, evidence, probe and environment scripts run under `/bin/sh`
  with `HOME` in a temp tree and a stub `tmux` on `PATH` that records its
  argv and simulates exit codes and stderr; covers the single command
  queue, `ok` with pid and start time, `failed cd`, `failed tmux` carrying
  stderr's first line, atomic records, `~` expansion, `pwd -P`, the stale
  sweep. With a real tmux ≥ 3.2 installed (`brew install tmux`), the same
  tests run against a private `-L temple-test-<pid>` server: first launch
  after the last session exited (no empty-server gap), launch against an
  already-running server, attach produces no record, two launches in one
  folder, kill-session, the three `has-session` answers (present; `can't
  find session`; `no server running on`; a bogus socket dir for
  `Permission denied` → unknown), PATH reaching the pane from the client
  and from `-e` against a server started with another PATH; `XCTSkip`
  otherwise.
- `RemoteSourceContractTests: HostSessionSourceContract` over
  `LocalShellExec`; live-stream and proof tests assert the v1 answers;
  `breakTransport` is a flag on the exec; the breaker (3 failures → no
  spawn for 10 minutes, `refresh` bypasses once).
- Launch model: the state table as a test matrix: every row's entry, every
  listed transition, attachment binding (a late exit check or identity
  result for an older attachment is dropped; after user close; during
  quit), persistence order (run row before spawn, a failing write refuses
  the open; `ok` evidence before acknowledgement; id before join; a read
  failure refuses rather than minting), startup reconciliation (id without
  row → join; row without a live run → new run with `resume`). Recovery
  across attachments: quit before the first fetch, then Open recovers the
  record by its persisted path before attaching and applies it; a record
  older than the sweep → `creation unproven`, attach-only, Resume anyway
  offered; a detached pending run whose session is gone → Open attaches,
  fails with `can't find session`, Ended, never a creation under the old
  handle; `failed tmux` after a successful creation (stub client exits 1
  after creating) → Unknown, next Open attaches and finds it.
- Liveness: the four-row contract from captured stderr of tmux 3.2a and
  3.4 (`can't find session`, `no server running on`, `error connecting to …
  (No such file or directory)`, `protocol version mismatch`, `Permission
  denied`, 127, 255, deadline); the socket-missing messages of both tmux
  versions classified as unknown (attach-only, button offered, nothing
  closed, nothing created); `-S <pinned socket>` on every management
  command. The deferred repair path has its tests written when it is
  taken up, not before.
- Identity (as built, phase 1b round 2): `/proc`-style fixtures and each
  box's real `/proc` for the ownership check: exactly one writable rollout
  held by the **pane's own process** (pid and start time verified, tmux's
  `#{pane_pid}` agreeing, header id equal to the file name's, `cwd` the
  run's folder) → adopted; a rollout written by a child, a grandchild (an
  npm launcher's native binary), a nested codex or Codex's shared app
  server → lastingly inconclusive, never a claim; pid reuse, an unreadable
  `fd`, `fdinfo` or `stat`, a process gone mid-check, no `/proc` →
  inconclusive. Suggestions: candidates by directory and time (remote
  epochs ahead of and behind the Mac's clock, delayed rollout creation, a
  login prompt past 5 s), two runs in one folder both shown the same
  candidate (the user's Yes on one makes it unavailable to the other
  through the claim index `runs_claim`; the other keeps asking), a declined
  candidate not offered again, a core conflict on confirm.
- Lifecycle (`OpenSessionsModelTests`, `RuntimeControllerTests`,
  `AppLifecycleTests`): the exit table; close idle → the one-command
  attached-checked kill acknowledged → Ended (`killed`), reopen → new run
  with `resume`, for the last session on the server (a follow-up would read
  "no server running") and for one of several; `temple-not-killed` (another
  client attached, with a real tmux where installed: a second client
  attached from the test) → left running with that reason, nothing killed;
  a lost acknowledgement → left running, `stop not acknowledged`; close with
  the host away → left running, `host did not answer`, tab gone, the notice
  text; close of a "Disconnected" tab both ways; close working →
  Detach/Stop/Cancel; **no automatic kill anywhere**: a scripted contact
  after any left-running flag issues no kill command (counted on the exec
  seam), the flag only lists; Open of a left-running session attaches and
  clears the flag, or on `can't find session` goes Ended and resumes; the
  sheet's Stop runs the same zero-attached command and only for a
  tracked run; nothing untracked is listed or killed; the user's own server never
  queried;
  `drainAll(graceful:detach:stops:)`: parallel one-command stops inside the
  3 s window, each after Temple's own client is ended, a hung query cancelled at the deadline and its
  session flagged `quit deadline`, a host without a live master not asked
  and flagged `host did not answer`, a late acknowledgement inside the
  barrier written and one after it not, the remote store flush bounded by
  the barrier's 2 s, no tabs at all still completing asynchronously, the
  engine barrier running after the drain as today; the quit prompt counting
  local only and naming hosts with working agents; CLI `close` (idle → stop
  now, working → refused, `--force` → detach);
  `applyLaunchDirectory` updating row, tab, recency, launch row and the next
  save together.
- Persistence: a remote tab saved in `open_tabs` restores with the host
  taken from its `session_state` row (the ADR-029 interim rule, now the
  rule), including the same session id never appearing on two hosts; the
  core schema is asserted unchanged (the migration list ends at
  `v12-archive-provenance`); `open_tabs` save with the same path on two
  hosts (positions per path, no PK collision); restore under the host project; a
  pending Codex run restored from the run row alone; `remote_project_state`
  written by archive, restore and undo for remote siblings while
  `project_state` is untouched, and a mask left out of step by a simulated
  crash repaired by the next Restore; the remote store's own migrator;
  deleting `remote-state.sqlite` leaves every core test green ("Removing
  remote" as a test); the hosts setting read through
  `TempleState.settingsDefaults` under a `TEMPLE_DEFAULTS_SUITE`.
- Terminal: the launch script with a `~/…` directory through the complete
  pane command (expansion happens in the pane, `pwd -P` in the record); an
  attached tmux client under `TERM=xterm-256color` with a `tmux-256color`
  pane (`tput colors`, `tput cup`) where a real tmux is installed.
- Transport and connection manager: `SSHExec` argv (a real `ssh -G` run
  against a fixture config proving precedence and survival of `Host *`),
  socket key changes on Edit and differs per state dir, long-path fallback,
  deadline kills only the query process, stale-socket removal only on
  `ECONNREFUSED`, no `-O exit` on Quit/Remove/Disable/Edit (counted on the
  exec seam), form validation, decoder on old and partial JSON, the sheet's
  state machine, host-key classification from captured stderr samples,
  registry rebuilt on list change independent of test results.
- **No host, both entry points** (as built in round 2; it was "flag off"):
  `AppStartup` builds the registry for both `@main`s; with no host enabled
  the registry has one entry, the exec seam ran nothing, no ssh config is
  read until the Hosts card is shown, no remote store file is created or
  attached, and no remote UI input exists (no ⌘N or launcher host rows, no
  shortcuts note, no sidebar notice); local close, quit and title behaviour
  equal v0.5.2's (`RemoteHostsTests`, `NotificationStateTests`,
  `ControlServiceTests`). `Scripts/check-remote-code.sh` runs `strings` on
  the `.app` binary for a remote-only marker (the host list's key) and
  asserts nothing gives the host list a default.

**Linux acceptance (required before shipping):** `make
remote-acceptance HOST=<alias>` copies the script suite to the host and
runs it there under the host's `sh`, GNU find, `/proc` and real tmux, on
both boxes as they are: `masterblaster-mentes` (Ubuntu 24.04, x86_64, tmux
3.4) and `jetson-mentes` (Ubuntu 22.04, aarch64, tmux 3.2a, the `-gq
allow-passthrough` path). Beyond the `RemoteScripts` matrix: the
**installed CLIs** at `~/.local/bin` found through the resolved login PATH
and not through ssh's default; a real `claude --session-id` run in a pane
(the agent's pid is the pane pid) and a real `codex` run (the npm launcher
spawns the native child: the process-tree walk finds the writer, or reports
inconclusive, and the acceptance log records which, per box); the attached
client under `TERM=xterm-256color`; the socket-missing case observed and
logged as it presents on each tmux version (`rm` the socket, run
`has-session`, record the message; this is the evidence that decides whether
the deferred repair path is ever needed); `KillUserProcesses` detection.

**Acceptance status per box** (as of phase 3; update when it changes):

- [x] `masterblaster-mentes`: phases 0, 1a, 1b and 2 pass, a logged-in
  Claude conversation and `--resume` included.
- [x] `jetson-mentes`: everything passes except the Claude conversation and
  `--resume` check, which is optional coverage, not a gate (owner, round
  2): `claude` there is not logged in (it stops at onboarding; `claude -p`
  says "Not logged in"). Logging Claude in on jetson and rerunning phase
  1a's acceptance adds that coverage (phase 1a note 5). Codex and
  enrichment pass there.

**Manual plan on `masterblaster-mentes`** (screen unlocked, Codex computer
use per the memory rule; no synthetic input):

1. Hosts → enable `masterblaster-mentes` → Test connection (answer ssh in
   the sheet) → rows for login shell, claude, codex, tmux, logind. Add the
   same box by address under a new name; test; `ssh -G` details match. Edit
   the port to a wrong one: the next test fails with ssh's line; fix it.
2. ⌘N → Folder on masterblaster-mentes → `~/Projects/<x>` → resolved path,
   a Claude tab, the prompt within seconds, section "x @masterblaster-mentes",
   `templectl sessions get <id>` shows directory source `tab` and the
   `pwd -P` spelling; the tab's project switched to it.
3. Type a prompt; the title follows; on the host `ps` shows `tmux -L temple`
   and `claude` as the pane pid; `env` inside shows the resolved PATH.
   Wheel up: history scrolls; type a key: back at the prompt. Drag-select:
   on the clipboard. ⌘F: finds recent output, shows the note.
4. Close while idle: no prompt; `tmux -L temple ls` on the host no longer
   lists it; reopen: a new `claude --resume`, the conversation is back, the
   folder recorded again from the new pane.
4b. Close while working, Detach: `tmux -L temple ls` still lists it; reopen:
   attached, no second `claude`, no new folder record.
5. Close while working, Stop: session gone, tab closed. Repeat with Wi-Fi
   off during Stop: the tab closes with the notice that the session was
   left running ("Temple couldn't stop … It may still be running; see
   Sessions on <host>."), and the sheet lists it.
5b. Wi-Fi off, then close the "Disconnected" tab of an idle session: the
   notice says it was left running; Wi-Fi on; open a tab to that host: the
   sidebar notice says "1 session left running on masterblaster-mentes",
   `tmux -L temple ls` still lists it; Show → the sheet → Stop: gone, and
   the row resumes from its transcript on the next open. Repeat but attach
   to the session from a terminal on the host first, then press Stop in
   the sheet: "temple-not-killed", the notice says another terminal is
   attached, the session survives.
5c. Stop the only session on the host: the tab closes and the sidebar row
   reopens with `--resume` although the private server has exited; `tmux
   -L temple ls` says no server running.
6. Wi-Fi off with a tab open: "Disconnected" kept; on; reopen: attached.
7. Quit with an idle remote tab, a working remote tab and a local working
   agent: the prompt names the host whose session keeps running; after
   quit, `tmux -L temple ls` shows only the working one; relaunch: both
   chips under the host project; activate each: the idle one resumes from
   its transcript, the working one attaches. Quit again without activating
   them: neither is stopped (a chip never opened is never stopped).
8. Codex (phase 1b as built): new session from ⌘N on the host; no row
   yet, the chip reads "New Codex session". With Settings' Codex extra
   arguments set to `--no-daemon`: after the first prompt the row appears
   within seconds (process tree). Without it (Codex's shared app server
   writes the transcript): after the first prompt the tab asks "Is this
   the session? “<prompt>”, started at <time> in <folder>." with Yes,
   that's it and Not this one; Yes: the row appears; Not this one: that
   candidate never comes back for this tab. `tmux -L temple ls` shows the
   handle name unchanged. Quit before adoption with the agent working: it
   is detached; relaunch: the "New Codex session" chip under the host
   project; activate: attached, then adopted or asked. (Quit with an idle
   pending tab that was typed into stops it and keeps the question for the
   next launch; one never typed into is let go.) Close an idle pending tab
   after typing: it stays with "Codex ended before Temple learned its
   session id…", the question, Start a new session and Discard (hover
   Discard: its help tag). Detach a working pending tab: Sessions on
   <host> lists it with Open. Start two Codex sessions in one folder at
   once: neither is adopted by heuristic; each asks; answer one; the other
   no longer offers that candidate.
8b. Unknown liveness: with a Claude tab open, `rm` the tmux socket on the
   host; drop Wi-Fi; the tab says Temple can't tell; reconnect; Open:
   attach fails, the tab offers Resume anyway with the stop instruction;
   `kill -USR1` the server by hand on the host; Open: attached. Then kill
   the tmux server on the host; Open: `can't find session` is impossible
   now (no server), so the tab stays Unknown; choose Resume anyway: a new
   `--resume` under a new handle; the old row remains and Stop on it
   reports uncertainty.
9. `jetson-mentes`: steps 2, 4, 6; timeouts read right on the slower box.
10. Remove the host with a row open: header says not set up; no `-O exit`;
    re-add: works without a new fingerprint prompt. Finally remove every
    host and delete `remote-state.sqlite`: every local session and tab is
    intact.

---

## 12. Phases

Each phase lands on main (direct commits, local `codex review` first),
reviewed by gpt-6.1-sol with gpt-6-astra alongside where the shape changes,
dark behind `temple.feature.remoteHosts` until phase 3 (history: the owner
removed the flag in round 2; remote is invisible until a host is enabled).

**Phase 0: transport, environment and the connection manager.**
`RemoteExec`, `SSHExec`, `SSHConnection.arguments(for:)`, the host record,
the config parser, the quoting function, environment resolution, the Hosts
connection manager with the Test connection sheet (checks by execution,
including the exact tmux chain), the registry rebuilt from enabled hosts.
Flag-off tests for both entry points. You get: enable or enter a host, test
it answering ssh yourself, read "Connected as mentes@…, Claude Code 2.1.283,
Codex 0.52.0, tmux 3.4" or the honest failure.

**Phase 1a: the durable slice, Claude only.** The id is known at spawn, so
this phase exercises the whole launch, attach, exit, close, quit and
persistence machinery with no identity step: `remote-state.sqlite` with
`runs` and `remote_project_state`, the `KeepAlive` protocol with the tmux
implementation (create and attach as separate commands, the socket-path
pin), `RemoteHostLauncher` (wrapper, pane command), `RemoteLaunchMarker`
with final collection and record recovery by persisted path, the liveness
contract (socket-missing as unknown), Resume anyway, close/Detach/Stop
with the one-command attached-checked kill and its acknowledgement as end
evidence, left-running records and the Sessions on <host> sheet,
`drainAll(graceful:detach:stops:)` inside the existing drain and engine
barrier, the quit prompt,
`applyLaunchDirectory`,
restoration with the host taken from the row, Codex rows that already have
an id (resume of an imported or earlier session works here too; only *new*
Codex launches wait for 1b). Its own sol review and Linux acceptance on both
boxes. You get: create, work in, detach from, stop, quit around and reopen
Claude sessions on a host.

**Phase 1b: Codex identity.** `declined_candidates`, the process-tree
verification, suggestions the user confirms, uniqueness and reconciliation,
pending chips and their restore from `runs`, Start a new session, the Codex
rows in the manual plan. Its own sol review and Linux acceptance on both
boxes (the real `codex` under the npm launcher, per box). You get: new Codex
sessions on a host, identified or asked about, never guessed.

Phase 1 as a whole also lands `RemoteSessionSource` with `adopt`,
`directoryEvidence`, `proveAbsent`, a `locate` that lists nothing, `read`
throwing `.transport`; the folder sheet, ⌘N and launcher rows; the CLI
`close` semantics; libghostty `clipboard-write` for remote tabs; the find-bar
note. Script execution tests and Linux acceptance green on both boxes before
this phase is called done. You get: create, work in, detach from, stop, quit
around and reopen Claude and Codex sessions on a host, pending Codex
launches included, with natural scrolling.

**Phase 2: enrichment.** Real `locate` and `read` with framing and shared
inputs, the breaker, `LocalShellExec`, `RemoteSourceContractTests`, the
per-host actor, `ModuleBoundaryTests`. You get: a reopened or imported
remote row that lacked a title, folder or date fills from its transcript.

**Phase 3: ship.** Flag on by default (history: prepared on the local
branch `remote-flag-on`; superseded by the owner's round 2, which removed
the flag: remote is invisible until a host is enabled), ADR-036 (this document cut to
decisions, including the ADR-010 amendment and "Removing remote"),
FEATURES.md (Sidebar, Session lifecycle, Settings, Shortcuts, Security), a
note in AGENTS.md that remote shipped with no core schema change and
`v13-project-host` stays reserved, release notes saying remote agents keep
running when Temple quits and how to stop them. No partial release before
this.

**After v1:** shpool as the second keep-alive experiment if scrollback feel
is the complaint; sidebar live marks from `tmux ls`; ⌘F routed to tmux's
search; a remote `catalog` per host, opt-in; `temple sessions new --host`;
rename-host; agent-native backgrounds when both CLIs have them.

---

## Review changes (gpt-6-astra, round 1 → revision 2)

| # | finding | what changed |
|---|---|---|
| 1 | v13 lacked process exclusion | Revision 2: no migration. Revision 4 (owner): additive `open_tabs.host`, older-build window accepted and documented (section 8). |
| 2 | backfill lost hosts for flagged-dev tabs | Backfill from `session_state` by id; remote tabs created before v13 restore from the launch row (section 8). |
| 3 | tmux command did not launch the agent | Revision 4: one command queue, agent as `new-session`'s shell-command, executed tests (section 4). |
| 4 | Codex adoption could miss; no window; no arbitration | Revision 4: lazy identity, two methods, uniqueness, bounded schedule (section 3). |
| 5 | reattachment depended on a rename | Handle names the session; no rename exists; pending launches persisted and restorable (section 3). |
| 6 | first-use authentication circular; key cases conflated | Test connection sheet; split copy (section 2). Confirmed resolved. |
| 7 | probe and launch environments differed | One policy, PATH to probe, client and `-e` (section 2). Confirmed resolved. |
| 8 | folder evidence and delivery bent ADR-029 | Revision 4: evidence only from a created pane; canonical dir; atomic records; acknowledged deletion; final collection (sections 4, 5). |
| 9 | close and quit lacked a policy | Exit table by `has-session`, Detach/Stop/Cancel, `drainAll(graceful:detach:)`, CLI `--force` detaches (section 5). |
| 10 | ControlMaster ownership underspecified | Revision 4: keyed by state dir and parameters, never killed by Temple, positive staleness only (section 2). |
| 11 | polling before reopen was reliable | No polling; honest description of startup locate plus breaker (section 6). |
| 12 | collision overstated; sequence; flag-off and Linux tests | Stated; phases reordered; both entry points; Linux acceptance (sections 8, 11, 12). Confirmed resolved. |

## Revision 3: Hosts as a connection manager (owner feedback)

Config aliases read-only plus hosts added in Temple through a form; per-host
`-o` options rather than a generated config file (`-F` drops the system
config and adds an ordering trap); Test connection as a terminal sheet, then
checks with each tool's own output; changed host key with no retry; host
record in `UserDefaults`, name fixed once saved; `ssh -G` tests and form
validation; phase 0 and manual step 1 updated. All carried into revision 4.

## Revision 4: astra round 2 and three owner directives

| source | finding or directive | what changed |
|---|---|---|
| astra P1 §3 | configuration could vanish before `new-session` | One client invocation, one command queue: configure then `new-session`, no empty-server gap; tested as "first launch after the last session exited" (section 4). (Revision 5 dropped `-A`: creation and attachment are separate commands.) |
| astra P1 §3/§6 | 3.2 fails `allow-passthrough`; Check did not exercise the launch | Floor 3.2 with `set -gq allow-passthrough` (explicitly optional, reported); the test executes the exact launch chain with `-e` on a throwaway socket, stderr preserved (sections 4, 7). |
| astra P1 §3 | `ok` preceded the pane's own directory; attach could report `ok` | The pane command does the `cd`, the timestamp, `pwd -P`, the pid record and the `exec`; attach runs no pane command and yields no record; no `has-session` pre-check (section 4). |
| astra P1 §3/§7 | pending launches had no reopening route; `PersistedTab.sessionID` non-optional | Launches are the tracked unit in `remote-state.sqlite`; a pending Codex launch is a tab or a chip restored from its launch row, reopenable by handle, never a fabricated row; `open_tabs` holds only tabs with an id (sections 3, 8). |
| astra P1 §3 | `/proc` adoption not a complete protocol | Pid and start time recorded by the pane itself (no tree walk, pid reuse defeated), writable-fd check, header equals filename, inconclusive on anything unclear, fallback after exit, `UNIQUE(host, session_id)` (**superseded** by astra's implementation note 1: uniqueness is on claims) so a lone candidate is never claimed twice, serial adoption per host (section 3). |
| astra P1 §3/§7 | canonical dir updated the row only | `applyLaunchDirectory` updates row, tab, project bookkeeping, launch row and the next save in one operation; grouping derives from `session_state` (section 5). |
| astra P1 §7 | whole-array ledger; adoption without mapping; remote masks outside transactions | Per-row SQLite in the remote store; id written there before the join with uniqueness; startup reconciliation; `remote_project_state` written by the same archive/restore/undo operations; failing pre-spawn writes refuse the open; read failures refuse rather than mint (sections 3, 8). |
| astra P1 §4 | `has-session` had no negative-proof contract | Three-valued contract by exit code and stderr pattern, stderr kept, bound to launch generation, rechecked against user close and quit; only a positive absence closes or marks Ended (section 5). |
| astra P2 §2 | Remove killed a shared master; fallback dir collided; `-O check` unlinked live sockets | No `-O exit` anywhere; socket key includes state dir and parameters; removal only on `ECONNREFUSED` (section 2). |
| astra P2 §5 | enrichment scheduling misdescribed; 64 KiB claim | Honest description of the engine's startup locate and backoff, a circuit breaker in the source, `complete` always empty with its consequence stated, shared inputs fetched whole (section 6). |
| astra P2 §6/§10 | registration depended on Check | Enabled hosts are registered regardless; the registry is rebuilt on list change; tests are diagnostics (section 7). |
| owner | additive `host` on `open_tabs`/`project_state`, v13, accepted window | **Superseded** by revision 6 (no core schema change). `open_tabs.host` additive with backfill and per-path positions; `project_state` left alone because remote project state is remote-only data (next row); the window accepted and documented (section 8). |
| owner | remote-only data in remote-owned storage; "Removing remote" | `remote-state.sqlite` (launches, remote project state), `UserDefaults` hosts, `<state dir>/ssh/`; nothing remote-specific in `session_state`; section 9 lists exactly what deletion removes and what rows a user keeps. |
| owner | keep-alive on merit, not only tmux | Section 4's evaluation: tmux hidden chosen; shpool the runner-up behind a `KeepAlive` protocol; dtach/abduco rejected on reattach; helper rejected for an experiment. |
| owner | scrolling and ⌘F under hidden tmux | `mouse on`, 50k history, wheel-to-copy-mode with `-e`, `Any` cancels, drag copies via OSC 52, ⇧-drag native, ⌘F stays libghostty's over what the tab received, with the find-bar note (section 4). |

## Revision 5: astra round 3

| source | finding | what changed |
|---|---|---|
| blocker §3 | uniqueness mistaken for ownership; two pending runs or an unrelated `codex` can match one rollout | (The descendant walk is **superseded** by phase 1b round 2: only the pane's own process is adopted.) No automatic heuristic adoption. Automatic only on launch-specific evidence: the pane's own process tree (descendants walked with start-time ordering, because Codex's npm launcher spawns the native child) holding the rollout open for writing, header equal to filename, tree fully readable; anything else inconclusive. Directory and time matches are suggestions the user confirms in the tab or chip; declined candidates are remembered; ambiguous runs stay pending and reopenable by handle (section 3; `adopt` / `suggest` in section 6; tests in section 11). |
| blocker §§3,5 | socket reachability became permission to restart; 3.2a's `error connecting … (No such file or directory)` missing | (The `SIGUSR1` repair here is **superseded** by revision 6: deferred, a missing socket is unknown.) Attach-only from Unknown and for every previously started handle; creation and attachment are different commands (`new-session` without `-A` on first Open, `attach-session` after); automatic `resume` only when absence is proven against the **pinned server** (socket path, server pid and start time recorded by the pane's `$TMUX`); the lost-socket case checks the pinned pid, repairs with `SIGUSR1` and retries, and is absence only when the pid is gone or reused; otherwise an explicit **Start a new run** whose copy says the original may still be running and how to stop it from the host (sections 3, 4, 5). |
| nit §§3-5,8 | run identity vs attachment generation; record recovery; `failed tmux` semantics | Run (durable handle) separated from attachment (per Open, what async results bind to); `record_path` persisted at spawn and recovered on the next Open before attaching; `failed tmux` is `creation unproven` → Unknown → attach-only; the state table rewritten with Creating / Attaching rows and these transitions, each a listed test (sections 3, 8, 11). |
| nit §§3,4,11 | executable and terminal boundaries: npm wrapper, `TERM=xterm-ghostty`, tilde only in the outer wrapper | Process-tree walk (above); local `TERM=xterm-256color` for the ssh process, `tmux-256color` inside, an attached-client test in the sheet's own surface; tilde expansion moved into the pane script and tested through the complete pane command; acceptance on the installed CLIs at `~/.local/bin` on both boxes as they are (24.04/x86_64/tmux 3.4 and 22.04/aarch64/tmux 3.2a) with the result per box recorded (sections 4, 11). |
| nit §8 | cross-store archive repair asserted without a mechanism | Stated plainly: no remote sweep; recovery of a mask out of step with its rows is another user Restore or Undo, which rewrites the mask from the rows; tested with a simulated crash (sections 8, 11). |
| nit §§8,9,12 | removal left detached agents and fallback sockets unaccounted; isolation claim stale; phase-1 restoration untested before v13 | "Removing remote" gains the hosts sheet (list runs per host, Stop all or Keep (**superseded**: as built, Stop or Keep per session), and the manual tmux commands for later) and the fallback socket dir, with masters never terminated; the hosts setting goes through `TempleState.settingsDefaults` so a demo follows `TEMPLE_DEFAULTS_SUITE`; phase-1 restoration with the host taken from the `session_state` row is tested on the v12 schema before the v13 migration exists (sections 8, 9, 11, 12). |

## Approval (astra, round 4) and implementation notes

Approved 2026-10-16. Three corrections to apply during implementation:

1. `UNIQUE(host, session_id)` contradicts multiple runs per session (resume after an ended run; an explicit new run while the original is Unknown). Allow several run records per established session; enforce competing adoption claims separately. Test both transitions with old records retained.
2. Server pinning in the sample script: `${TMUX##*,*,}` extracts the session index, not the server pid; the attach branch must use `-S <pinned socket>`, not `-L temple`. Parse `$TMUX` correctly and `/proc/<pid>/stat` without assuming the process name has no spaces. Test record generation through socket recovery.
3. Client diagnostics must not overwrite pane evidence: the wrapper's `failed tmux` goes to a separate record from the pane's `ok`. Test creation succeeding with a nonzero client exit, delayed collection, and recovery on reopen.

## Revision 6: fable final read (approved with must-fixes)

| # | must-fix | what changed |
|---|---|---|
| 1 | drop `v13 open_tabs.host` unless a concrete case needs it | No case survives: a restored tab's host is its `session_state` row's host (ids are globally unique; the ADR-029 interim rule becomes the rule), and a pending Codex tab restores from `runs`. v13 removed; the core schema does not change at all; the accepted older-build window and the AGENTS.md rule change are gone; "Removing remote" and the data section updated; the per-path position numbering kept for the shared primary key (sections 3, 8, 9, 11, 12). |
| 2 | socket-repair path optional, deferred | "no server running" and tmux 3.2a's socket-missing error are **unknown** in v1: attach-only plus the explicit button, nothing closed, nothing created. The `SIGUSR1` repair (server pid and start time pin, retry, auto-resume) is kept in the design as deferred until acceptance shows the case occurs; acceptance logs the message per tmux version as that evidence. The socket-path pin for `-S` stays (sections 3, 5, 11, manual step 8b). |
| 3 | copy: "run" is internal | User-facing buttons are **Resume anyway** (id known) and **Start a new session** (pending Codex), each keeping the sentence that the original may still be running and how to stop it from the host; "run" appears nowhere on screen (sections 3, 5, 11). |
| 4 | split phase 1 | **1a Claude only** (id at spawn, no identity step; the whole launch, attach, exit, close, quit and persistence machinery, plus resume of Codex rows that already have an id) and **1b Codex identity** (process tree, suggestions, uniqueness, pending chips, Start a new session), each with its own sol review and Linux acceptance on both boxes (section 12). |

Astra's three implementation notes above are kept as written and apply
unchanged: several run records per session (the `UNIQUE(host, session_id)`
constraint becomes a uniqueness check on *competing claims* for an id, not
on rows), correct `$TMUX` parsing and `-S <pinned socket>` in the attach
branch, and the wrapper's `failed tmux` recorded apart from the pane's `ok`.

## Revision 7: cleaning up remote tmux sessions (owner question)

| # | owner's point | what changed |
|---|---|---|
| 1 | close an idle tab, host reachable | Close means stop, as locally (ADR-010): kill-session on the pinned socket, confirmed by the exit check, `ended_at`; reopening later resumes from the transcript. Working: Detach/Stop/Cancel unchanged (section 5; state table rows Running and Detached). |
| 2 | close when the host is unreachable | **Superseded** by revision 9 (no deferred stops; left running instead). `stop_requested_at` on the run row; the tab goes with a notice; carried out at the next contact. (Revision 7 judged idleness from 120 s of silence; revision 8 replaces that: the request records the tab's last observed gate, silence never confirms, and the sweep stops only an idle-when-last-seen session that nobody has attached to since.) New **Stop requested** row in the state table (sections 3, 5, 8). |
| 3 | quit | (The requests here are **superseded** by revision 9: unacknowledged stops are left running.) `drainAll(graceful:detach:stops:)`: working remote agents detach; idle ones on reachable hosts are stopped in parallel inside the existing bounded drain, request written first and cleared on acknowledgement; unreachable ones keep the request. Quit is never delayed by a host. Prompt copy: "Sessions working on <host> keep running; Temple will reconnect to them." (section 5; the policy for deferred stops is corrected in revision 8). |
| 4 | orphans | **Superseded** by phase 1a note 1 (the owner's decision: Temple never discovers or stops a session it did not start; no "Not in Temple" rows). On each contact, sessions on Temple's private server with no run row are listed in the Remote sessions sheet (now a standing part of the Hosts card) as "Not in Temple" with Stop / Keep, never stopped automatically; the user's own tmux server is never queried (sections 5, 9). |
| 5 | disconnect without close | Nothing changes on the host; the tab stays "Disconnected" and reconnects; closing that tab is a Close as in 1 or 2 (section 5). |
| | tests and acceptance | Lifecycle tests for every branch above and the contact sweep; manual steps 4, 4b, 5, 5b, 7, 7b rewritten (sections 11). |

## Revision 8: astra's delta review of revision 7

| # | finding | what changed |
|---|---|---|
| 1 | 120 s of silence is not idle evidence; `session_activity` is not all output | (Superseded by revision 9: deferred stops removed.) Silence never confirms. Close while connected decides by the tab's own activity gate, as a local tab does. A deferred stop records `stop_last_gate` (idle or working as Temple last observed it) and a token; at contact the sweep stops only when the last observed gate was idle, no client is attached at command time, no attach happened since Temple last saw the session (`session_last_attached` vs `last_seen_remote_epoch`, remote-to-remote), and the token is still current. Recent host activity vetoes and keeps; a working last gate is never auto-stopped and is listed with a notice. Copy updated (sections 3, 5). |
| 2 | clearing the flag cannot cancel an issued kill; reattachment never gated stopping | (Superseded by revision 9: no lock, no deferred kill.) Per-run lock in `remote-state.sqlite` (`run_locks`, atomic across processes, stale-owner reclaim): Open/Keep revoke the request under the lock before attaching; a dispatch re-reads the token under the lock and holds it until acknowledged or timed out; an Open that meets a dispatch waits and then resumes or attaches by its outcome. The kill is one remote command that re-checks `session_attached` at command time. Observed reattachment (attached now, or attached since last seen) revokes the request (sections 5, 8). |
| 3 | stopping the last session reads "no server running" (Unknown) and breaks Stop → Ended → resume | An acknowledged targeted `kill-session` (exit 0) is its own end evidence (`end_evidence: killed`); only a lost acknowledgement keeps uncertainty. Tests and manual step 5c for the last session and for one of several (sections 3, 5, 11). |
| 4 | stop completion vs the quit contract; stale `drainAll` signature | Quit keeps today's sequence: `prepareForQuit`, the 3 s surface drain (now `drainAll(graceful:detach:stops:)`, with stop *operations*, requests written before dispatch, outstanding query clients cancelled at the deadline), then the existing engine barrier (`stopListening`, `shutDown(timeout: 2 s)`, commit 4dc203a) with the remote store flushed inside it. Durable stop completions are written whenever they arrive before the barrier closes; only tab-side callbacks are discarded. Tests: hung query, late acknowledgement, no tabs, asynchronous completion; phase 1a's signature updated (sections 5, 11, 12). |

## Revision 9: deferred stops removed (escalation after two clustered rounds)

| # | decision | what changed |
|---|---|---|
| 1 | no automatic deferred stops | `stop_requested_at`, `stop_token`, `stop_last_gate`, `last_seen_remote_epoch`, `run_locks`, the contact sweep and every contact-time kill are gone. A stop Temple cannot carry out and confirm when the user acts leaves the session running, recorded as `left_running_at` and a reason on the run row; "Sessions on <host>" lists it with the notice ("Left running: <host> didn't answer when you closed it.") and a Stop button; one notice at close says the same; a sidebar line at the next contact says how many are left running. Temple never kills anything without a live user action (sections 1, 3, 5, 8, 9). |
| 2 | close while connected, one non-yielding kill | Local parity unchanged: the tab's gate decides; idle → stop now, working → Detach/Stop/Cancel. The kill is one `if-shell -F` sequence in one query client that checks `#{session_attached}` equals the number of clients Temple itself has attached (1 from the tab, 0 elsewhere) and kills in the same queue, else prints `temple-not-killed`. Acknowledged exit 0 = Ended (`killed`); not acknowledged or not killed → left running with the reason, no fencing: a later Open attaches if it survived or resumes if positively absent (sections 3, 5). |
| 3 | quit | Idle remote tabs on hosts with a live master get the same one-command stop inside the existing 3 s drain; anything not acknowledged by the deadline, and every host without a master, is left running (`quit deadline` / `host did not answer`) and listed next launch; working tabs detach; copy unchanged (section 5). |
| 4 | remaining nits | Running and Detached rows and the Stop paragraph defer to acknowledged-kill evidence, not to an exit check; the durable-completion exception is stated once in the quit section; the remote store flush shares the engine barrier's 2 s deadline and never extends it. The activity-baseline nit disappeared with 1 (sections 3, 5). |

## Approval of revision 9 (astra) and two more implementation notes

Approved 2026-10-16. For phase 1a:

4. Attachment count is not client identity: with `<n> = 1` another client can replace Temple's before the command runs. Detach Temple's own client first and require zero attached clients in the same server-side condition (or validate the initiating client's identity there). Test replacement of the original client before execution.
5. One decoded kill outcome everywhere: query success without `temple-not-killed` = killed; the marker = refused (another client attached); failure or timeout = unconfirmed (left running). Never "exit 0" alone (the false branch also exits 0). Say "never retried automatically", not "at once or not at all": a cancelled query may already have taken effect.

## Fable approval of revisions 7 to 9, and one must-fix

Approved 2026-10-16 (fable final read of the lifecycle changes). Must-fix for phase 1a:

6. **Keep clears the flag.** In "Sessions on <host>", Keep on a left-running session clears `left_running_at`/`left_running_reason` (it becomes an ordinary Detached session), so the state table's Left running row exits by Open, Stop **or Keep**. The sidebar line "N sessions left running on <host>" shows once per flag (dismissed or acted on, it does not return on the next contact), so a session the user chose to keep never nags.

Adopt astra's note 4 (detach Temple's own client, require zero attached) before 1a lands. Not in v1: growing the "Not in Temple" rows (**superseded**: phase 1a note 1 removed those rows altogether); a "still running" nudge for sessions detached while working (the v1.1 lever if acceptance shows they get forgotten).

## Phase 0 as built (implementation notes)

Recorded after two sol review rounds on phase 0 (astra agreed the
altitude decision in the second):

1. **The Test connection's terminal runs the user's ssh and nothing
   else.** An earlier build ran a local wrapper and an attached-check
   helper in the sheet's terminal; three findings in a row landed in that
   wrapper (supervision, signals, storage failures), so it was deleted
   rather than patched. The terminal's process is `/usr/bin/env ssh
   <arguments> -- <name> true`. Its exit status is never used: libghostty
   launches through `/usr/bin/login`, whose parent exits 0 whatever ssh
   did. When the process ends, by any status and in any way, Temple runs
   `ssh -O check` on its own ControlPath for that alias (local, no remote
   command, never `-O exit`): a master up means the connect worked, and
   the checks run as `BatchMode` queries over it. No master runs nothing
   and reconnects nothing: "Couldn't connect. See ssh's message above." in
   the sheet, "Couldn't connect. Test the connection to see ssh's
   message." in the Hosts list. ssh's stderr is on the terminal, not in
   Temple, so the unknown-key and changed-key copy apply to queries (phase
   1), and a changed key gets the generic copy in the sheet with Test
   again. A master left from an earlier test (it persists 10 minutes)
   counts as a master. Linux acceptance proves the evidence on both boxes:
   no master before the connect, one after, the checks riding it.
   - **The probe and the checks stay on the master.** `-O check` and every
     Test query carry `ControlMaster=no`, `ControlPersist=no`,
     `BatchMode=yes`, `ConnectTimeout=1` and `ProxyCommand=/usr/bin/false`
     on the command line, ahead of any of the host's own options (ssh
     keeps the first value it is given, so a Temple-added `ProxyJump`
     after them is ignored, and they win over any config): an inherited
     `ControlMaster yes` or `ask` cannot make ssh skip the socket, and a
     failed mux handshake has no transport to fall back to (the config's
     `ProxyJump` is displaced too). Tested with the real ssh against a
     local TCP listener standing in for the host: it never sees a
     connection, and sees one with the old probe.
   - **A master is not a connection.** `-O check` proves a local process.
     The first query over the master (the environment) must run on the
     host; if it doesn't, the test reads "Couldn't confirm the connection:
     <ssh's first line>." and is never "Connected". Until it has, the
     sheet reads "Checking the connection…".
   - **Closing the sheet cancels everything it started**, the `ssh -G`
     resolution included; a test closed during resolution prepares no
     socket storage and starts no terminal.
   - **The socket follows where ssh resolves the host.** The test runs
     `ssh -G` first; hostname, user, port, proxyjump and proxycommand join
     the socket key, so an alias retargeted in `~/.ssh/config` gets a new
     socket and never rides the old destination's master, and "Connected
     as …" names the connection the checks ran over.
2. **The attached-client check moves to phase 1a's acceptance**: a
   terminal opening a client under tmux, `TERM=xterm-256color` outside and
   `tmux-256color` in the pane (`tput colors`, `tput cup`), are validated
   there, on both boxes, with the tab's own launch. Phase 0 already ran
   that check on both boxes before the wrapper was removed: the attached
   client exited 0 on `masterblaster-mentes` (tmux 3.4) and on
   `jetson-mentes` (tmux 3.2a).
3. **The socket path limit is 86 bytes, not 90**: ssh binds the master at
   `<ControlPath>.<16 random characters>` and `sun_path` holds 104 bytes
   with its NUL. A fallback still too long goes under
   `/tmp/temple-ssh-<uid>/`. The socket directory is created or checked
   without following a symlink, must be this user's, and is made 0700;
   anything else fails the test before a terminal starts.
4. **Hosts, users and jump hosts pass a strict grammar** (ASCII host
   names, IPv4, IPv6; `[A-Za-z0-9._-]` users; `[user@]host[:port]` hops),
   because ssh substitutes them into a `ProxyCommand`'s shell text. A
   non-ASCII name is refused with "Use the host's ASCII name. For an
   international name, add it to ~/.ssh/config or enter its xn-- form.";
   Temple does no IDNA conversion of its own. Every check for shell syntax
   works on Unicode scalars or bytes, not Characters.

## Phase 1a as built (implementation notes)

Recorded after the first sol and astra review of phase 1a. Decisions 1 to
5 are the owner's constraints as astra applied them.

1. **Unowned sessions** (decision 1). Temple never discovers or stops a
   session it did not start. "Sessions on <host>" is built from tracked
   runs only; absence is established only by a check against each run's
   own pinned socket, never from a `-L temple` listing or a guessed
   socket. Manual step 7b is gone.
2. **Unused new Claude sessions** (decision 2). A run records whether its
   conversation is confirmed (`runs.conversation`, migration
   `r2-conversation`): a new Claude run starts unconfirmed; a resume is
   confirmed. Typed input is not evidence (Return at an ssh prompt or
   Claude's trust screen proves nothing; round 2): a session whose last run
   ended unconfirmed is checked on the host when it is reopened, by one
   bounded query for `<root>/projects/*/<id>.jsonl` under exactly the
   config root its agent was started with (round 3): the login
   environment's `CLAUDE_CONFIG_DIR` comes from the same bounded query as
   the PATH (framed so newlines and relative values survive), the launch
   hands it to the pane explicitly, set or unset, through `new-session -e
   TEMPLE_CFG` / `TEMPLE_CFG_VALUE` (round 4; `-e` values are not
   format-expanded, measured on 3.2a, 3.4 and 3.7, and an older server's
   environment never decides it). Without a resolved value the launch
   passes its own environment's, explicitly; a pane told nothing valid
   records `failed<TAB>cfg` and starts no agent, which the tab shows as a
   launch failure. The pane records the root it has, hex-encoded and
   decoded strictly (malformed or invalid UTF-8 is no evidence; an encoded
   empty value is a value), which the run row keeps (`r3-config`). The
   check uses the root of the session's latest relevant run (not
   dismissed, not a creation that failed before it ran); a run that left
   no evidence makes it Unknown, never an older run's root. A relative
   root is made absolute against the folder that run was in, and a
   resume after a present answer starts against exactly that root, not
   the login environment's current one; any other resume uses the latest
   run's root when known. Present: confirmed, and resumed. Absent only
   when that root was checked to the end; an unknown root, an ancestor
   that can't be searched, or a store that can't be read whole is Unknown. Absent: the
   tab offers **Start a new session**
   (a fresh agent under the same id) and **Discard** (its runs dismissed;
   its row let go, or archived when the user named, pinned or colored it).
   Unknown: **Resume** too, with copy saying Temple couldn't check. No row
   is deleted automatically.
3. **An agent that fails at once** (decision 3). No `remain-on-exit`. The
   pane pipes what it shows (its first 64 KiB, `pipe-pane`, started from
   inside the pane before the `exec`) to `<record>.out`; the tail comes
   back with the records, and a tab whose agent ended within the early
   window shows "<agent> exited immediately on <host>." with those lines
   and the argv. The agent keeps its terminal for stdout and stderr, the
   pane pid stays the agent's, and liveness is unchanged. Measured on tmux
   3.2a, 3.4 and 3.7: `pipe-pane`'s command is format-expanded, runs in the
   server's directory and does not get the session's `-e` environment, so
   the path is passed inline, shell-quoted, with `#` doubled.
4. **Socket repair** (decision 4) stays deferred; a missing socket is
   Unknown.
5. **jetson-mentes** (decision 5): `claude` there is not logged in (it stops
   at onboarding), so the conversation and `--resume` check is
   **incomplete, not passed**, on Ubuntu 22.04 / tmux 3.2a. Required before
   the flag flips. Everything else in the 1a acceptance passes there.
6. **Record location.** Records live in `~/.temple/launch/<marker>`, the
   locator the run row persists (the same for every connection; a
   `$TMPDIR`-based path differed between connections). Before every record
   operation the directory is checked: a real directory, this user's, mode
   0700, `~/.temple` not a link and not group- or world-writable;
   otherwise no record is written and a fetch reports it unsafe. Records
   are written beside, with `set -C` (no link followed), then moved.
7. **`new-session -c /`.** `-c` is format-expanded by tmux, so no user path
   goes there; the pane enters the folder itself.
8. **Exact diagnostics.** Only `can't find session: <name>` for the name
   asked about proves absence, in the liveness check and in the stop.
   Measured on 3.2a, 3.4 and 3.7: `if-shell -t =<name>:` on a missing
   session does not fail (it prints `temple-not-killed` with status 0), so
   the stop runs `has-session` first in the same command queue.
9. **Trailing newlines.** `pwd -P` is captured with a sentinel in the pane
   and the folder check, so a folder whose name ends in a newline keeps it.
10. **One PATH policy.** One resolver is shared by the environment query
    and the launch. All its attempts share one 5 s budget, enforced only
    by the watchdog below, never by `timeout` (GNU `timeout` moves its
    command into a process group of its own, and on masterblaster a hung
    login shell's children escaped the watchdog that way; the first box
    run of this check passed vacuously, its resolver script mangled by a
    missing newline, and now also asserts the hang ran); the resolver runs in a process group of
    its own (`setsid` on Linux, where dash has no job control without a
    tty; the shell's job control where `setsid` is missing), and at the
    budget the whole group is sent TERM, then KILL, and its leader reaped
    (`kill -SIG -<pgid>`, the spelling dash and bash both take). Where
    neither containment exists it spawns nothing and falls back. So the
    interactive launch is bounded too, and nothing is left behind (tested
    here and on both boxes with a shell that ignores TERM and leaves a
    child); the query's own deadline bounds
    it from this side. Its state is explicit: unresolved (the launch asks
    the login shell itself, with the same resolver), resolved, or fallback
    (resolution ran and found none: ssh's default environment for checks
    and launch alike), and it is cached only for the connection it was
    resolved over (an answer for an alias's old target never lands on the
    new one).
11. **The alias is resolved again** on every explicit open and contact; a
    changed resolution is a new connection and its PATH is resolved again.
12. **Ownership.** Every open, record poll, exit check, stop and the writes
    that follow them are owned by `RemoteOperations`. An idle close gives
    up the tab, not its stop; a host removed or edited is retired first
    (its launcher queries nothing more, its operations are cancelled, a
    stop so cancelled is recorded left running, its pending opens and
    results are invalidated and the launcher's identity is checked before
    any spawn, its connected clients are detached); the quit plans from
    each tab's run and gate (an idle agent whose client had already ended
    is stopped too), cancels what only looks, lets stops run inside its
    window, expires the rest with `quit deadline`, and the engine barrier
    waits for every owned write within its own 2 s.
13. **Durability.** Store work runs off the main actor. A write that fails
    is reported (`.storage`, a notice), never as success, and nothing is
    acknowledged on the host after a failed write. A stop answer that
    arrived is written even after its waiter was cancelled. The ordinary
    find-or-reserve is one immediate transaction across processes; Resume
    anyway and Start a new session insert explicitly. Persisted creation
    evidence is replayed into the row and tab on reopen.
14. **Copy.** "Temple couldn't check these sessions", "No Temple sessions
    to show", and "another terminal is attached" (not "someone else").
15. **One gate for late completions** (round 2, after two rounds of
    findings in the same place). Every asynchronous completion that
    touches a tab, a row, a sheet or the saved tab set is listed in
    `RemoteCompletion` and passes `RemoteEffectGate.admit` right before its
    effect, after its last await: not quitting, not cancelled, the host's
    launcher still the one the work began with, and for a tab still open
    with the same open token, handle and attachment (and no newer run
    attachment), for a sheet still the one on screen. Durable writes of
    outcomes happen regardless. Every query that can write an outcome (the
    sheet's checks and the folder check included) is owned by
    `RemoteOperations`, and a query checks for retirement before each
    follow-up query. A test walks the list after close, quit and
    retirement.
16. **No pin, no absence.** A run with no server on record is asked on
    `-L temple` only after its record is recovered, and nothing that
    server says proves it gone: Unknown in the probe, the exit check and
    the stop.
17. **Discard is durable work** (round 3): the runs' dismissal and the
    row's disposition (let go, or archived when the user made the row
    theirs) finish together in one owned operation, for the membership
    (incarnation) Discard was chosen for; quit, retirement or a closed
    window change nothing of it. Only its failure notice is gated. The
    disposition is one database transaction under `(id, host,
    incarnation)` (round 4, `TempleDB.discardRemoteSession`): the DELETE
    and the archive both carry the predicate, so a membership replaced
    through any connection, whatever the window's cache last saw, is left
    alone (tested by replacing the row through a second connection), and
    a write that fails is said.
18. **Run evidence is mandatory at the gate** for the completions that
    apply it (record polls, the final collection, the failed-folder header,
    the exit verdict, diagnostics): each reads the run's persisted
    attachment after its last await, so another Temple instance attaching
    meanwhile suppresses it. The settle timer passes the gate too for tabs
    on hosts; the mechanisms outside the gate (title persistence, the
    launcher's cache, the Test connection's callbacks, the local launch
    channel) and why are listed in `RemoteCompletion`'s documentation. The
    walk proves coverage of that enum, not completeness against the source.
19. **Startup-evidence deadline.** A remote open that shows no sign of life
    (no record, no title from tmux) in 20 s says "Still connecting to
    <host>…" with Cancel; Cancel ends the client, the exit check decides
    what is known, and nothing is created in its place.
20. **Diagnostics take only the output file.** The pane's and the client's
    records are acknowledged only after their evidence is written; a
    storage failure is shown, never swallowed.
21. **The acceptance stall, explained: macOS ssh's mux at 8 KiB.** In
    round 2, two of about eight box runs reached no `ok` record; the
    "client still running" then was `script`'s pid, not ssh's. With the
    ssh child and its `-v -E` trace captured (round 3), jetson failed three
    runs in a row, each the same way: `auto-mux: Trying existing master`,
    then `mm_send_fd: sendmsg(2): Message too long` and
    `mux_client_request_session: send fds failed`; ssh exit 255, nothing
    on the host. A mux client writes its session request to the master's
    socket and then passes its stdio with `sendmsg`; on macOS the sender
    loses send space for each byte the master has not read yet, so a
    request ending just below a multiple of the 8 KiB socket buffer cannot
    pass its descriptors. Measured against a jetson master with plain
    `ssh -t` and `ssh -T`: commands of 8,060 to 8,100 bytes failed 2 or 3
    times in 3, 16,250 to 16,290 bytes 1 or 2 in 3, every size between and
    around passed. Round 3's create command (the resolver now inside the
    wrapper) was about 8,000 bytes plus the host's PATH; jetson's PATH is
    about 46 bytes longer than masterblaster's, which put its launch in
    the band, and round 2's slightly shorter command sat at its edge.
    Round 3 padded commands out of the band; round 4 replaced that, since
    the request also carries `TERM` and whatever the user's ssh forwards
    (`SendEnv`, `SetEnv`), which can move an unchanged command into the
    band, and the band's place is measured, not a contract. The launch is
    now staged (note 22) and every interactive command is short: 437 bytes
    on both boxes, at most `LaunchStage.maximumCommandBytes` (1 KiB, which
    a test asserts for every command Temple builds), so the forwarded
    environment would need about 7 KiB of its own to reach the first band.
    The acceptance asserts the sizes and still sends raw band-sized
    commands to each master, for information: 2 of 3 were refused on each
    box in round 4. In the product this failure is not a stall: ssh exits
    255 at once with those two lines on the tab. The startup-evidence
    deadline (note 19) stays for a client that really does wait.
22. **The launch is staged; the tab's command is short** (round 4). The
    launch script, with every variable-length value in it (PATH, the
    config root, the folder, the agent's argv, the record's locator, the
    socket), is written to `~/.temple/launch/<marker>.s-c<nonce>` (a
    creation; `.s-a<nonce>` for an attach) by a bounded, non-interactive
    query over Temple's master, its bytes on stdin: noclobber and mode
    0600 beside, its length checked, then linked into place, so a partial
    file is never read. The tab's ssh runs `sh -c '<executor>' temple-launch
    <name> <wait>`: it waits up to 30 s for the file, then (round 5)
    checks the private chain as the writer does (`~/.temple` a real
    directory of this account's, not group- or world-writable; `launch` a
    real directory of this account's, exactly 0700), takes the file by an
    atomic rename to a fresh name inside that directory (nobody but the
    account can put anything there, so what is checked is what is read),
    checks what it took (a regular file, not a symlink, this account's,
    exactly 0600), reads it, deletes it, and runs it. The fresh name is
    `.run-<stage>-<pid>`, checked absent first, so the rename never lands
    inside an existing directory (round 6). Anything else, or a file that
    never comes, is said in the tab (status 125) and nothing runs; what
    was taken is removed whole (a file, a link without its target, a
    directory), and a `.run-*` left by an executor killed midway goes with
    the 24-hour sweep; each unsafe case is tested against the executor itself, and the
    acceptance checks a 0644 file is refused on both boxes. A `mkdir` of
    the directory that loses a race with another Temple operation (EEXIST)
    is accepted after the same checks on what the winner made (this was
    the intermittent failure of the cross-process reservation test: two
    cold opens staged at once, the loser's staging was refused, and the
    test's `async let` cancelled the other open, which then read as a
    refusal; the test now awaits both answers whole, and a cancellation
    during staging stays a cancellation).
    What nothing read is removed when the creation's record is
    acknowledged, when the run's end is proven (exit check or stop), and
    by the 24-hour sweep. **First contact:** when no master answers at
    the open, the tab is spawned first, and its own interactive ssh
    authenticates (the person may be asked) and becomes the master
    (`ControlMaster=auto`, `ControlPersist`); Temple stages once `ssh -O
    check` answers, never through the terminal. A staging write refused
    before the spawn refuses the open (a creation is recorded failed); a
    refusal after the spawn ends the tab's client and the tab says why. A
    creation whose launch never left this Mac (its tab ended or closed
    first) is recorded failed, not unproven, and a stop of it asks
    nothing of the host: nothing can be running there. Tested on both
    boxes: the first launch of each run is a first contact.
    A pending launch keeps the exact connection planned for its tab and is
    written over that connection's master only (`.overMaster`): never a
    direct connection, never a newer connection another open re-resolved
    meanwhile. "Failed, nothing ran" is claimed (stop reads Absent, the
    exit says why) only once that write has committed, in one statement
    guarded on the run still being an unstarted first attachment; a run
    another open attached to meanwhile is left as it is, and a write that
    fails is a storage error with the proof kept for the next try, never a
    claim.
23. **Every command line is a short fixed bootstrap** (round 5). Queries
    too: the command line carries only `sh -c '<bootstrap>' temple <end>`
    (the same bytes for every query); the program (`set --` with the
    arguments, the resolved PATH, the script), an end line and then the
    query's own input travel on stdin. The bootstrap reads the program a
    line at a time (`read` takes no more than the line from a pipe) and
    runs it only if the end line arrived, so a program cut short runs
    nothing; what follows stays on stdin for the script (the staging
    payload). A test builds every real query script over both query
    transports with a 48 KB PATH, 40 KB arguments and 100 KB of input, and
    every interactive command, and asserts each command line is within
    1 KiB. The stdin writer is the run's own nonblocking write source,
    cancelled with the readers when the run is answered (an exit, a
    deadline, a cancellation): a 4 MiB upload to a process whose child
    holds stdin without reading leaves no descriptor or worker behind.
    Round 6: the markers that frame a query's output are printed by `sh`
    in the bootstrap, not by the login shell (csh's and tcsh's `>&2`
    writes a file named `2`); the whole invocation is tested under csh
    and tcsh. The end line is one that appears nowhere in the encoded
    program, so no argument, PATH or script line can end it early. Every
    session Temple asks for (queries, over the master or not, and tabs)
    forces `StdinNull=no`, `ForkAfterAuthentication=no`,
    `SessionType=default` and `RemoteCommand=none`, so a config that sets
    `-n`, `-f`, `-N`/`-s` or a remote command cannot eat a query's
    program or a tab's keys; asserted in the argv, resolved with `ssh -G`
    against a fixture config, and run on both boxes with a throwaway `-F`
    config that sets `StdinNull yes`. The helpers without a remote command
    (`-O check`, `-G`) force `ForkAfterAuthentication=no` too (round 7):
    ssh refuses that setting without a command before doing anything. The
    end line's collision check splits the program on the LF byte, as
    `read` does (a CRLF is one Swift Character).

## Phase 1b as built (implementation notes)

Codex identity, built after the on-screen check of phase 1a. Decisions 1
to 5 are the owner's, binding.

1. **The suggested lookup is not discovery** (decision 1). It runs only
   for a pending run Temple started, asks the user and never adopts. It
   reads only rollouts under that run's Codex home touched since its
   `ok`, whose first line names the run's folder, and offers only those
   whose header id is also their file name's id, whose `cwd` is the run's
   canonical folder (`pwd -P`, as the pane recorded it) and whose header
   timestamp lies in [`ok` epoch, end] on the host's clock (an Ended run's
   end is its end as this Mac saw it, moved by the clocks' offset measured
   in the same query, plus 30 s). A rollout declined for the run, or whose
   id another run on the host holds, is never offered. Nothing is listed
   for import and nothing unrelated to a pending Temple run is shown.
2. **Hosts without `/proc` are suggest-only** (decision 2). The automatic
   check answers inconclusive for good (`lasting`: no `/proc`, or a pane
   that recorded no start time) and the suggestions take over at once.
   There is no non-`/proc` walk. The check's proc root is a property of
   `RemoteSessions` (`procRoot`), which the acceptance points at a
   directory that does not exist to stand for such a host.
3. **`declined_candidates` is remote-store only** (decision 3), in
   migration `r4-codex-identity`, which also adds to `runs`: the Codex home
   the pane recorded (`codex_home_state`, `codex_home_dir`), `claim`
   (`verified` or `confirmed`), `joined_at` and `tab_closed_at`. Core is
   untouched.
4. **The remote branches left `OpenSessionsModel` first** (decision 4), as
   a behaviour-preserving commit with the full suite green (6ade29a):
   `RemoteTabController` owns the operations, the gate, the notice and
   Discard handlers and every remote tab action; the model kept its tab
   list, the activity heuristics, `applyLaunchDirectory` and the saved tab
   set, and calls into the controller from its open, exit, close, title,
   activation and quit seams (1965 lines became 1291 and 721).
5. **Copy** (decision 5): "No sessions started from Temple."; the
   left-running notice is the Sessions sheet's line for the same reason
   plus where to stop it, from one function; Resume anyway (and Start a
   new session for a pending Codex session Temple can't reach) confirm in
   a sheet with a short title, one sentence, and the `tmux -L temple
   kill-session` command apart and selectable; Discard's help tag says
   whether it removes the row or archives it (named, pinned, colored,
   imported or with a transcript); no em-dash in any of it.

What the boxes showed, which shaped the build:

6. **Codex's shared app server writes the rollouts by default.** codex
   0.158 and 0.163 (the standalone release at `~/.local/bin/codex` on both
   boxes; no npm launcher is installed on either) hand each interactive
   session to `codex app-server --managed-daemon`, which holds every
   rollout it writes open (`O_RDWR|O_APPEND`) and serves every TUI of the
   account. On masterblaster that server runs from before (ppid 1), so the
   pane's tree holds no rollout and the check reads "no session file is
   open right now". On jetson the first TUI started it as its own child,
   inside the tree, where it could have held another TUI's rollout (the
   tree walk here is **superseded** by round 2 ruling 1: only the pane's own
   process counts, so any other writer is inconclusive): a
   process whose argv names `app-server` holding a rollout makes the walk
   inconclusive (`lasting`, "a shared Codex app server writes this
   session's transcript"), never a claim. With `codex --no-daemon` the
   TUI writes its own rollout and holds it open from the first prompt
   while idle, at depth 0 (the pane pid), and the walk adopts it at the
   first check on both boxes. Temple passes no flag of its own to Codex
   (AGENTS.md: no opinion on how a CLI runs); `--no-daemon` is the user's
   to add in Settings' extra arguments, and without it every new Codex
   session on these boxes is identified by the question.
7. **The rollout appears with the first prompt**, and an app server's
   rollout records the prompt only as a user message item behind Codex's
   injected blocks (no `user_message` event): the question names it
   through `CodexFormat.firstTypedPrompt`, which skips items that begin
   with `<`. The local catalog's titles are unchanged.
8. **The walk** (**superseded** in part by round 2 ruling 1: descendants
   are no longer candidates; the pane's own process is the only writer that
   counts) reads every `/proc/<pid>/stat` with the shell's `read`
   (no process per entry) past the last `)`, walks descendants of the
   pane pid whose start time is no earlier than their parent's, to a
   depth of 4, verifies the pane pid's start time and tmux's
   `#{pane_pid}`, collects descriptors linking to `<home>/sessions/
   **/rollout-*.jsonl` whose `fdinfo` access mode is write or read-write,
   and re-reads each process's start time after its descriptors (a
   process gone or reused mid-walk is inconclusive). A stat that exists
   but can't be read, an unreadable descriptor table, a pane whose start
   time changed, tmux naming another pane, none or more than one rollout:
   inconclusive. The found file is the run's only when its header's id is
   its file name's id, its `cwd` is the run's folder and it is not a
   subagent's thread.
9. **The Codex home** is resolved by the same login query as the PATH and
   `CLAUDE_CONFIG_DIR` (`printenv CODEX_HOME` in the frame), handed to the
   pane explicitly (`-e TEMPLE_CDX`/`TEMPLE_CDX_VALUE`, set or unset; told
   nothing, the pane records `failed<TAB>cdx` and starts no agent) and
   recorded hex-encoded in `ok`. The check and the lookup canonicalize it
   on the host (`pwd -P`; relative values against the pane's folder, as
   Codex does). An empty `CODEX_HOME` is not guessed at: lasting
   inconclusive and no suggestions. A Codex resume starts against the home
   of the session's latest run.
10. **Claims.** A claim is written in one immediate transaction that
    refuses an id any other run on the host holds, and a partial unique
    index (`runs_claim`, `(host, session_id) WHERE claim IS NOT NULL`)
    makes two claims of one id impossible; runs of one session that are
    its resumes stay allowed (astra's implementation note 1). The core
    join follows the claim; it is durable work like the claim (only the
    quit defers it); a refusal (`hostConflict`, `agentConflict`) releases
    the claim and the tab shows core's reason; a join is marked
    (`joined_at`), and the next launch joins every claim that was not
    (reconciliation step one). A session whose runs all ended resumes on
    its next Open as before (step two). A claimed run's conversation is
    confirmed.
11. **The schedule** (2, 5, 15, 60 s after `ok`, then each minute while
    attached) is one owned operation per open (`RemoteOperations` kind
    `identity`, cancelled with the open, the host and the quit); a check
    also runs on activation (not twice in 5 s) and at the exit. One host's
    checks are serial (`RemoteSessions.serially`). The question is shown
    once the check can't answer: for good, when the agent ended, or once
    something was typed (the rollout exists only from the first prompt).
12. **Pending tabs.** A new Codex tab on a host opens a pending run
    (`openPending`, no id on the agent's argv; the run written before the
    spawn) and reopens it by handle, attach-only while it runs. Closing it
    while idle checks its identity once more (its agent still runs), then
    stops it: identified, the tab closes; unidentified with something
    typed, it stays as "Codex ended before Temple learned its session id.
    Its transcript is still on <host>." with the question, Start a new
    session and Discard; with nothing typed, Temple stops tracking it.
    Detach keeps it running, closes its tab (`tab_closed_at`) and lists it
    under Sessions on <host>, which gains Open for a pending session. A
    quit never stops a pending run (it could not be resumed without its
    id): it detaches. (**Superseded** by round 1 ruling 5: pending runs
    follow the quit policy of any run.) Pending runs not discarded, never failed and whose
    tab was not closed restore at launch as chips from the runs alone.
    Discard of a pending session dismisses its run; no row is ever made
    from a handle.
13. **The gate** has eight new completions (`pendingOpenResult`,
    `identityResult`, `suggestionsLoaded`, `confirmResult`,
    `pendingStopOutcome`, `pendingRestore`, `pendingDiscardNotice`,
    `identityNotice`), each in the walk. `identityResult` is walked
    without the close disruption: closing a pending tab checks its
    identity once more on purpose, so that check's own answer is
    admitted (tested on its own).

Also folded in from the on-screen check of 1a: an acknowledged stop and a
proven absence remove the run's pane output (`.out`, kept in memory for
the diagnostics header), which the pane now creates under `umask 077`;
Return in the folder sheet starts the session (the window's key catcher
took it for the sidebar while no tab was active: a sheet now owns every
key); a host's project heading leads with the globe and keeps the host
apart from the name (the globe and the second line are **superseded** by UX
round 2: `@host` on the heading's own line, section 7); every Test connection row has Show output.

## Phase 1b round 1 (sol and astra review; Fable's decisions; the coordinator's rulings)

1. **Ownership, not descendance.** (The launcher exception here is
   **superseded** by round 2 ruling 1.) A rollout is adopted only when the
   pane's own process holds it, or, when the pane is a launcher shim (an
   interpreter whose arguments name a script `codex` or `codex.js`, as
   Codex's npm package installs), its direct child that is the launched
   CLI: an executable whose name begins with `codex`, given exactly the
   arguments the pane was given after the script (`/proc/<pid>/exe` and
   `cmdline`). Any other writer (another child, every deeper descendant,
   a nested codex the agent ran, Codex's shared app server) proves nothing
   about the run: when only such writers hold a rollout the check is
   lastingly inconclusive ("the session file is held by a process Temple
   didn't start") and the question takes over. Note 6's app-server rule is
   now a case of this one. Every read in the walk that fails (a link, an
   `fdinfo`, a `cmdline`, an `exe`) is a retry, never skipped; flags must
   be octal and their access mode exactly 1 or 2. Acceptance checks the
   rule on each box's real `/proc` with processes it starts (a real nested
   codex can't be arranged from outside the agent).
2. **Temple passes no `--no-daemon`** (Fable 1). The question and the
   ended header say: "With --no-daemon in Codex's arguments (Settings),
   Temple identifies the session itself." No button writes Settings (the
   arguments field is global and would change local Codex too).
3. **The suggestions** take paths as `find -exec` arguments and send them
   in hex; an unreadable file, a folder that can't be searched or an
   answer not framed whole (each frame's length and end marker, then
   `done` with nothing after it) is unavailable, never a partial list.
   Every candidate is listed by its first line and filtered for
   eligibility before the newest twenty are read for their prompts. A
   store that can't say what was declined or held makes the question
   unavailable. A yes reruns the eligibility check and claims only a
   candidate that still passes; the claim refuses a declined file in its
   own transaction. The home keeps a trailing newline (`pwd -P` with a
   sentinel).
4. **Joins by outcome.** Only a join core wrote is marked (`joined_at`); a
   refusal releases the claim with core's reason; a failed write leaves the
   claim unjoined for the next check and the next launch, and the schedule
   keeps checking until the tab is the session.
5. **Quit** (ruling 3): pending runs follow phase 1a (working detached,
   idle stopped). Stopped, a run typed into keeps its ended record for the
   question after relaunch; one never typed into is let go. A failed stop
   is left running and never retried.
6. **An ended yes is at rest** (ruling 4): confirming an ended session
   records who it was and leaves its tab at rest ("This Codex session
   ended on <host>. Resume it to continue the conversation." with
   Resume); nothing starts until the user asks.
   Superseded by the remote UX round 1 (below): the tab closes instead,
   as a local tab does when its agent exits; still nothing starts until
   the user opens the row (the row selection that round added was
   removed in the simplification round).
7. **Input evidence is kept** (ruling 5, persisted): `r5-input` adds
   `runs.input_seen_at`, written the first time a pending tab is typed
   into, so a restored chip still asks and a close keeps it.
8. **Hand-over.** A tab that becomes its session marks its run handed over
   to `open_tabs` (`tab_closed_at`); a claimed run that never was (the
   claim landed after the quit froze the tab set) is restored at launch as
   that session's chip, then handed over.
9. **Owned writes.** Every pending run's own write (its tab closed or
   handed over, its run dismissed, its input kept, a refused claim
   released) is owned and a failure is said once (`pendingWriteNotice`,
   in the walk). A pending open answered "identified elsewhere" joins and
   opens as that session instead of staying opening.
10. **Test connection**: a CLI that prints nothing still has Show output
    (the command and its exit status).

Not done here, by decision: the local catalog's titles for app-server
rollouts (Fable 6, its own commit before the next release); Codex's shared
history and index lines and jetson's initialised `~/.codex` stay (Fable 4);
the dark-mode tmux contrast check is for the hands-on pass (Fable 7).

## Phase 1b round 2 (coordinator's rulings)

1. **Only the pane's own process is adopted.** Round 1's launcher
   exception (a direct child of an interpreter whose arguments named
   `codex` or `codex.js`, given the same arguments) drew a blocker in two
   rounds in a row, so the mechanism changed instead of the evidence: the
   writer must be the process the launch `exec`ed. A codex installed behind
   Codex's npm launcher (where the native binary is the launcher's child)
   is identified by the question, like the default app-server mode; with
   the standalone install both boxes have, `--no-daemon` is adopted at
   depth 0. The argument comparison is gone.
2. **Restored chips are never stopped at quit.** Only a run this launch
   attached to and saw idle is stopped; a chip restored and never opened
   (one detached while working, or left running by a stop that failed)
   keeps running.
3. **Restore follows reconciliation.** At launch the unjoined claims are
   joined first; a claimed run comes back as that session's chip only when
   core holds it (joined now or before), and otherwise by its handle as a
   pending chip (a refusal released it; a failed write left it claimed,
   joined again when it is opened). A run is handed over (`tab_closed_at`)
   only once the tab set is acknowledged as written
   (`TabPersistence.saveAcknowledged`; local saves behave as before).
4. **Input evidence.** `r5-input` marks runs from before it with the epoch:
   unknown, kept as typed into. A pending tab's input is committed only
   once written; a failed write is tried three times, then said, and the
   next Return tries again.
5. **Prompts.** A prompt query that fails, a file it couldn't read, or a
   head cut short before any prompt is unknown ("its first prompt couldn't
   be read"), never "no prompt".
6. **Frames.** A length is checked against the bytes left by subtraction,
   so a length near `Int.max` is refused, not an overflow.
7. **Core refusals are remembered.** A run whose id core refused is not
   claimed again on schedule, and that id is not offered; Try again (in
   the tab) or the conflicting row leaving lets it be claimed once more. A
   failed core write keeps retrying.

## Phase 1b round 3

1. **Outstanding hand-overs.** A tab that becomes its session while the
   tab set can't be written keeps its run as the fallback that restores
   it; when that tab is closed or detached, the fallback is retired then
   (`tab_closed_at`), so a closed tab never comes back from its run.
2. **Remembered refusals keep their reason.** Core's refusal is kept by the
   run's handle with core's words, and said again, with Try again, whenever
   the run reopens this launch (a reconnect, a detach then Open). After a
   relaunch the first check finds the id again and core's refusal brings
   the note back.
3. **Heads keep their bytes.** A suggestion's head is captured with a
   sentinel, so a head ending in a newline at the 256 KiB cap reads as cut
   short (prompt unknown), not as a whole file with no prompt.
4. **`r5-input` was rewritten before landing** (round 2 made runs from
   before it unknown). It never left this machine: unpushed, and behind
   the flag that is off everywhere remote shipped, so no store that applied
   the first version exists outside dev and acceptance stores (none remain;
   the acceptance and test stores are temp trees removed with their runs).
   No repair migration (the coordinator's ruling).
5. The ProxyCommand test, which runs the local ssh, moved into
   `SSHConnectionTests` with the other ssh-invoking tests.

## Phase 1b round 4: the hand-over, lifted

Round 3's hand-over (retire the run's own restoration when its tab closes)
looked its host's launcher up at the close, so a host removed meanwhile
lost the write; and it forgot the obligation before the write committed.
Two rounds in the same place, so the mechanism moved up a level:

- **The obligation holds the store.** When a tab becomes its session (or
  the launch restores a claimed run as that session's chip), the
  controller records a hand-over by the run's handle, holding a
  `RemoteRunLedger`: `remote-state.sqlite` itself, written directly by
  run (`tab_closed_at`). Nothing of the host's registry entry or launcher
  is used after that.
- **It ends in one way:** the write commits. It is attempted when the tab
  set is acknowledged as written, or when the tab is gone, whichever comes
  first; tried three times; kept on failure and tried again at every later
  tab close, at the quit (whose frozen tab set is written then), and at
  the next launch (where the run, still restorable, comes back and owes it
  again); a failure is said once (`pendingWriteNotice`, suppressed only for
  a host no longer set up).
- **Every path that ends a tab's hand-over obligation** goes through it:
  close, detach, discard (the tab is removed), a host disabled, edited or
  removed (the obligation does not need the host), quit, relaunch restore.
- The retargeted-alias test, which resolves with the real `ssh -G`, moved
  into `SSHConnectionTests` with the other ssh-invoking tests.

## Phase 1b round 5

- **A hand-over never saves.** It waits on the acknowledged saves the
  model makes anyway (`persist()` keeps whether each was written, the one
  save it always made): it is finished once a save written after it was
  owed, or its tab's removal, says so. Settling makes no save, so neither
  a local tab's close nor the quit gains one, and the quit adds nothing
  outside its 3 s drain and 2 s barrier (the write itself runs off the
  main actor as an owned operation, bounded by that barrier).
- **The notice's ticket is taken before the write**, so a host edited
  while the write was held (its launcher replaced) refuses it.
- **A failure is logged first** (`remote` category, at notice), so a notice
  the gate suppresses still leaves a diagnostic.


## Phase 1b final copy (Fable's final read)

Approved for push with these wording changes, which override the strings
quoted earlier in these notes:

- The question with no prompt reads "Is this the session? No prompt yet,
  started at <time> in <folder>." and, when the prompt couldn't be read,
  "First prompt unreadable" in the same place.
- "Codex ended before Temple learned its session ID. Its transcript is
  still on <host>." (ID, as in the Copy session ID menus).
- Resume anyway: "Temple can't reach this session on <host> and can't
  tell whether it is still running. If it is, it keeps running."
- Start a new session: "Temple can't tell whether Codex is still running
  on <host>. If it is, it keeps running, and a new session starts beside
  it."
- The hint reads "With --no-daemon in Codex's arguments (Settings), Temple
  identifies the session on its own." and is hidden while the tab shows a
  remembered refusal, where it doesn't apply.

Before any release that turns remote on: local catalog titles for Codex
app-server rollouts (they lose the first prompt the same way; reuse
`CodexFormat.firstTypedPrompt`), and the dark-mode contrast comparison of a
remote tab against a local one.

## Phase 2 as built (implementation notes)

Enrichment: a reopened or imported remote row that lacks a title, folder or
date fills from its own transcript, through the engine like any host's
(`SessionEngine` reads, `FactPersister` writes NULL-only under `(id, host,
incarnation)`). The v1 answers stand: no catalog, no change stream,
`complete` always empty, `directoryEvidence` unknown, `proveAbsent`
unproven, `adopt` inconclusive. A remote row is never `confirmedAbsent`,
dimmed or auto-archived for a missing transcript.

0. **Local Codex titles first** (its own commit, Fable's decision). The
   local catalog read the first prompt only from `user_message` events,
   which Codex's shared app server never writes, so those rollouts listed
   as "(no prompt)". The wider read now uses `CodexFormat.firstTypedPrompt`,
   which also skips the `# AGENTS.md instructions for <folder>` block Codex
   injects as a user message item (measured on codex 0.163: 51 such items
   on masterblaster; before this, the remote question would have offered
   that block as the "prompt" in a folder with an AGENTS.md). Facts version
   3, so kept catalog summaries are read again.
1. **The source is built on `RemoteSessions`** (`RemoteSessionSource(sessions:)`
   in `RemoteHost.swift`), through a small provider seam
   (`RemoteTranscriptProvider`): the query exec (the same connection, PATH
   policy and `.query` purpose as 1a/1b's queries: it rides Temple's master
   when one is up, otherwise connects on its own with `BatchMode`) and, per
   requested id and agent, where to look.
2. **Roots, the 1a/1b way.** A session with runs is looked for under the
   root its latest relevant run's agent had (not dismissed, not a creation
   that failed before it ran), as that run's pane recorded it
   (`effectiveRoot` / `effectiveHome`), and only there: a run that left no
   evidence makes the root unknown, never an older run's or the login
   environment's. A session with no run (imported, or from before the
   store) is looked for under the login environment's `CLAUDE_CONFIG_DIR` /
   `CODEX_HOME`, from the same bounded query as the PATH. Empty, relative
   with no folder to resolve against, or unread: unknown, not searched. A
   store that exists but can't be read makes every root unknown. The host
   resolves and canonicalizes each root (`pwd -P` with a sentinel, so a
   trailing newline survives).
3. **`locate`** is one exec for the whole batch. Arguments are groups of
   `agent state value base ids`, then `--` and the hint paths. Per group,
   one `find` narrowed to the requested names (Claude `-mindepth 2
   -maxdepth 2 \( -name <id>.jsonl -o … \)`, Codex `rollout-*-<id>.jsonl`
   and `rollout-*-<id>_*.jsonl` for reverts), its records NUL-terminated
   (`size TAB mtime TAB inode TAB path`, GNU `-printf`, or `stat -f` under
   BSD), followed by `S<find's status>`, the whole of it hex-encoded on one
   line. The store folder is followed when it is a link (`find -H`, as the
   local store resolves its root); files inside it are stat'ed as they are,
   exactly as a read stats them. Codex names match in any case (`-iname`),
   as `CodexFormat.name` reads them. A root of `/` joins as `/projects`,
   the same spelling on both sides. A `find` that failed lists nothing for its group (no partial
   listing is used). Nothing is listed for an id Temple has no row for
   (`RemoteSourceTests` asserts the answer never names a session nobody
   asked for). A hint (the row's recorded path) is stat'ed in the same exec and is
   a candidate only inside its root's store, as the local source's
   `acceptsTranscript`. Roles come from `TranscriptCandidates.assign`.
   Coverage moves on the first listing after a transport failure.
4. **`read`** is one exec: the opening stat, the first window (64 KiB),
   when facts are wanted the tail (the last `min(64 KiB, size - 64 KiB)`
   bytes, as the local store reads it), for Codex the session's own lines
   of `history.jsonl` and `session_index.jsonl` (`grep -F` on the id, from
   the rollout's own canonical home), the closing stat, then `done`. Bytes
   go through a private temp file (`umask 077`, removed on exit), so each
   frame's length is exactly what follows; the parser is strict (lengths
   checked by subtraction, `\nend\n` after each body, nothing after
   `done`). Identity is decided exactly as `StoreIO.identity` decides it,
   on the head: a Codex header line longer than 64 KiB is unreadable; a
   Claude identity undecided in the first window and a file that goes on
   is read again with the scan's full 1 MiB cap (one more exec), as is a
   Codex `needsWiderHead` (one more exec, counted as the wider read).
   Opening and closing stats that differ are retried three times, then
   `.changedDuringRead`. Missing is `.missing` only when the parent folder
   can be searched; otherwise unreadable.
5. **Bytes are bytes.** `RemoteOutput` carries stdout's raw bytes
   (`data`), unframed from the marker at the byte level, and the per-stream
   cap is 8 MiB (a read is at most a 1 MiB head, a 64 KiB tail and the
   session's shared lines).
6. **One actor per host** (`RemoteTranscriptAccess`): two execs at a time;
   locates arriving within 250 ms of the first are answered by one exec
   (each caller gets its own ids; a caller that is cancelled is answered at
   once, and a batch nobody waits for any more is cancelled, its exec
   killed); the breaker trips after three
   consecutive transport failures (an exec that threw, didn't reach the
   host, exited non-zero, or answered with something that isn't an
   answer; the provider failing counts too) and then answers
   `.transport("<host> unreachable since <time>; next try at <time>")`
   without spawning anything for ten minutes. An explicit open
   (`refresh`) gets through once; a failure there keeps it open, a success
   closes it. Every transport failure also drops the cached PATH and roots
   (`RemoteSessions.transportFailed`), so the next query resolves them
   again. A quit (`shutDown`) cancels the exec in flight, whose ssh process
   is killed, and returns only once each batch's own task has finished. A
   cancelled lookup or read is never charged to the breaker, whatever error
   the cancellation surfaced as (a killed `ssh -G` reads as a refusal).
7. **Late completions.** Enrichment touches no tab, sheet or tab set: its
   facts reach rows only through `EngineSet` and `FactPersister`. A host
   removed or edited takes its engine with it, and a read answered after
   that touches nothing (`RemoteGateWalkTests.testEnrichmentOfARetiredHostTouchesNoRow`);
   `RemoteCompletion`'s list of mechanisms outside the gate says so.
8. **Flag off**: no registry entry, no source, no engine for a host;
   nothing changes. A host with no rows has no members, so its engine
   locates nothing and spawns nothing at startup (the existing
   "registration and startup run nothing" test holds with the real
   source).

Deviations from section 6, with reasons:

- `session_index.jsonl` travels as the lines that contain the session's
  id, not whole: the facts for one id are the same (both shared readers key
  by id) and the transfer stays proportional to the session. Substring
  filtering is an optimisation, not a guarantee that no unrelated line
  crosses the wire (a line that merely mentions the id does).
- No shared revision: `sharedRevision` is empty and a read's is nil. Each
  read takes the shared lines in the same exec as the rollout, so its
  titles are fresh when read; v1 enrichment is one-shot and NULL-only, with
  no change stream to announce a newer revision.
- Hints are honoured (inside the root's store), as the local source does;
  section 6 lists only the `find`.
- `directoryEvidence` stays unknown (as built since phase 0) rather than
  `test -d`: History and the folder sweep ask it per project, and a spawn
  per question is not worth `.exists`, which no remote decision uses.
- `adopt` stays inconclusive: identity on a host is `RemoteSessions`'
  (phase 1b).
- The source does not conform to `HostSourceDiagnostics` (it monitors
  nothing); its counters are `RemoteSessionSource.counters`.
- The engine is unchanged, so every unarchived remote row with a
  transcript costs one identity read at startup (or open), not only rows
  that want a field; with two execs at a time and 64 KiB each.

What the boxes showed (`LinuxAcceptanceTests.testPhase2EnrichmentOnEachHost`):

- masterblaster-mentes (Ubuntu 24.04, GNU find): a `claude -p
  --session-id` transcript and a `codex exec` rollout in a temp folder;
  their rows (no title, folder or date) filled in 0.8 s from one locate
  exec and two reads: title "Reply with the single word ok", folder the
  canonical temp folder, date, transcript path. A row with no transcript
  stayed `incomplete`.
- jetson-mentes (Ubuntu 22.04): the Codex row filled the same way (1.2 s).
  claude there is not logged in: `claude -p` exited 1 with "Not logged in ·
  Please run /login" but still wrote a transcript, and that row filled from
  it. Enrichment of a transcript a working Claude wrote stays incomplete
  on jetson until its claude is logged in.
- An unreachable host (127.0.0.1 port 1, refused): three locates failed in
  0.3 s each with ssh's line; the fourth locate and a read answered
  "unreachable-mentes unreachable since 1:48 PM; next try at 1:58 PM"
  with no process spawned; an explicit open spawned again (ssh -G, the
  environment query, the locate).
- Cleanup: the temp folders, Claude's project folders for them and the
  rollouts the test made were removed; Codex's history and index lines and
  the boxes' app servers were left alone; no `temple-read.*` temp file was
  left behind.

### Phase 2 round 1 (sol and astra review)

Astra's decisions on the open questions, adopted: the startup cost (one
identity read per remote row with a transcript) is accepted for v1 and
the engine stays generic; jetson's authenticated Claude conversation stays
an explicit acceptance gap; separate source counters are fine for v1
(`HostSourceDiagnostics` with `isMonitoring = false` later, if wanted);
locale short times stay, with a date when the time is on another day.

1. **An environment that couldn't be read is a transport failure.**
   `queryExec` keeps going without a PATH when the environment query
   doesn't reach the host; enrichment no longer does.
   `RemoteSessions.transcriptContext` throws ssh's line when the query for
   this connection didn't reach the host, so a lookup is charged once on
   the breaker and retried, instead of finding nothing under roots that
   only looked unknown. A root that is unknown because the host said so
   (a variable it couldn't print, set empty, relative with no folder)
   stays unknown, not a failure. Tested failure then recovery.
2. **Links are refused, not followed.** A transcript that is a link (or
   anything but a regular file) is `.unreadable` in the listing (each
   record now carries its type: GNU `%y`, `test -L`/`-f` under BSD), as a
   hint, and in a read. A link's own stat (what the local source's
   `lstat` reports too) says nothing about the file a read takes, its size
   or its growth, so the signature could never move with the content; and
   no agent writes its transcript as a link. The store folder itself is
   still followed (`find -H`). Checked on both boxes.
3. **Admission after the permit.** Work that waited for one of the two
   permits checks the breaker and its own cancellation again before asking
   for a context or spawning, so nothing queued spawns once the breaker
   trips meanwhile.
4. **Hints are contained.** A hint is looked at only when it is a normal
   absolute path (no empty, `.` or `..` component; every path the source
   lists is one) and in the agent's shape inside the store, as the local
   stores' `acceptsTranscript` decides: Claude `<store>/<folder>/<id>.jsonl`,
   Codex a `rollout-*.jsonl` below `sessions`. Listed files pass the same
   check.
5. **Malformed is not a failed find.** A listing whose records or status
   aren't well formed is a transport failure of the lookup (charged, never
   clearing the breaker); a well-formed one whose `find` reported a status
   other than 0 lists nothing for its group and is a successful answer. A
   record whose path is not UTF-8 is well formed and passed over.
6. **A response budget, on the host.** A read prints at most
   `RemoteTranscripts.responseBudget` (6 MiB) of bodies: the script adds
   each part's size before printing it, and a session whose head, tail and
   shared lines would pass it ends with `unreadable` (that session's,
   never the host's breaker); nothing past the budget crosses the wire.
   Checked on both boxes with 320 KB of a session's history lines against
   a 128 KiB budget.
7. **Each coalesced caller gets its own answer**, built from its own
   requests (agents, hints) out of the shared listing.
8. **The breaker's times carry the date** when they fall on another day.

### Phase 2 round 2

1. **Paths are judged on bytes.** The normal-path check, the store
   containment and the agent's shape (hints and listed files, both
   agents), a Codex home from a path's shape, and whether a root is
   absolute all work on UTF-8 bytes, as the host's kernel reads a path:
   Characters let `/../\u{0301}outside/` (a combining mark joined to the
   slash) hide a real `..`, and treat precomposed and decomposed spellings,
   which the host keeps apart, as one.
2. A well-framed answer whose `find` failed is a transport that worked: it
   lists nothing, charges nothing, and resets the breaker's count like any
   answer (the test now says so and asserts it).

### Phase 2 round 3: one byte-exact path type

The second round on how remote paths compare, so the fix moved to the
type: `RemotePath` wraps a path's UTF-8 bytes and is equal, hashed and
ordered by them alone (Swift's `String` is equal under canonical
equivalence, so a precomposed and a decomposed spelling, two folders on a
Linux host, were one key). Every remote root (`RemoteTranscriptRoot`'s
value and base, so two such roots are two groups and both are searched),
listed path, hint and its stat, store prefix, Codex home and the
path-to-home cache in `TempleRemoteHost` is one; so are the Codex
identity's folder comparison (`verify`, `eligible`), its seen and declined
rollout sets (`RemoteStateStore.declined` returns `Set<RemotePath>`) and
the suggestion heads. A `String` is made from one only for display, a
script argument (its bytes are the path's) or a locator handed to the
engine. Tested together in one batch and in the cache, locally (an exec
that answers from its arguments, since APFS folds the two spellings) and
on both boxes (ext4 keeps two folders; one batch finds each session under
its own, and each Codex read titles from its own home's history).

What remains outside this module: core's `TranscriptLocator` equality and
`TranscriptCandidates.assign`'s de-duplication compare `String`s. Within
one session's own store two files whose paths differ only in
normalization (two Claude project folders spelled both ways, holding the
same id) would be offered as one candidate; identity verification still
decides which file is the session's, and nothing of another session can
reach the row. A byte-exact locator is a core change, for a decision of
its own.

### Phase 2 round 4, and Fable's final read

- **Suggestions are identified by their path's bytes** (8ae23d3).
  `CodexSuggestion.id` is a `RemotePath`, and `RemoteSuggestion.id` the
  rollout path's UTF-8; both types' `==` compare path, session id and
  folder by bytes. The tab's `confirming` marker is that byte id, and
  confirm's recheck in `RemoteSessions` matches by it. Two rollouts whose
  folders differ only in normalization are two suggestions: declining one
  leaves the other and declines only its bytes.
- **Approved for push** (Fable, final read) with one wording change: a
  read over the budget says "this session is larger than Temple reads (at
  its <part>): <n> bytes in all, limit <budget>" (the total so far, not the
  part's own size; Opus's review).
- **To decide in phase 3, not leave to a later round:** core's
  `TranscriptLocator` equality and `TranscriptCandidates.assign` still
  compare `String`s. Rounds 2 to 4 all landed on path comparison; the
  remote module is byte-exact at the type, and core is the cluster's last
  member. Either make the locator byte-exact, or record that core stays
  `String` because local stores are on APFS, which folds the spellings.

## Phase 1b hands-on fixes (computer-use findings)

- **B1, the title.** tmux titles every new pane with the host's name, and
  the chain's `set-titles-string '#T'` handed it to the tab and, through
  the title handler, to the row ("MasterBlaster"). The chain's title is now
  the pane's title only once it is no longer the host's name (`host` or
  `host_short`), measured on 3.2a, 3.4 and 3.7c; the terminal gets an
  empty title until the agent sets one. A pending Codex tab reads "New
  Codex session" until then; Codex then titles itself with its folder's
  name (and a spinner while it works), which is the agent's own title, as
  it is locally.
  - **The empty title became this Mac's home** (re-check): libghostty
    treats an empty title as a reset and titles the terminal with its pwd
    instead (`termio/stream_handler.zig` `windowTitle`), and the pwd starts
    as the child's working directory (`termio/Exec.zig`), which for a tab
    on a host is this Mac's home: "/Users/sriram" reached the tab and the
    row. The same reset gives a local tab its folder path when its agent
    clears its title, or reports a pwd (OSC 7) before any title. The view
    now tracks the terminal's pwd (the launch directory, then
    `GHOSTTY_ACTION_PWD`) and reports a title whose UTF-8 bytes are exactly
    the pwd's as a stand-in (`didUpdateStandInTitle`): the model treats it
    as a title change for every activity, settle and early-close input,
    exactly as before, and only the tab's and row's title ignore it. An
    empty title is ignored for the tab and the row but still counts as
    tmux drawing (the startup-evidence deadline), as the host-name title
    counted before. A row that already took such a title
    keeps it until the agent retitles itself (generated titles overwrite;
    transcript fills are NULL-only and never replace it) or the user
    renames it; only dev and acceptance stores ran a build with the
    regression, so no repair is shipped. **Superseded for local tabs** by
    the owner's round 2: only a tab on a host ignores a stand-in title; on
    this Mac it is shown and kept, as in v0.5.2 (it is the tab's own folder).
- **B2, working at close.** A spawn (a launch, a reopen, an attach) boots
  into running and only the 15 s settle timer took it back, so ⌘W soon
  after a reopen asked Detach or Stop. Measured on masterblaster: Codex
  animates a spinner in its title while it works and stops when it is
  done, in both modes (an app-server turn that errors included); it rings
  no bell and its own state report (OSC 7501) does not pass tmux. A close
  (⌘W, the CLI's `close`) now takes a running tab as at rest before the
  timer only on positive evidence that its agent has done nothing this
  spawn: nothing typed since it spawned, no title that brought it back from
  rest, and its title quiet for the quiet window, after a spawn that
  started the agent (a launch or a resume: an agent booting, resuming or at
  a trust screen; Claude at its trust screen was the same path). A
  reattach to a remote run already running is no such evidence (the
  agent's state carries over from before the detach, perhaps mid tool
  call): it keeps the timer, then the working prompt. Anything after a Return keeps the old behaviour (the
  timer, then the working prompt): a quiet or unrelated title then is no
  evidence (a long tool call holds its title, a tool can set its own), so
  ⌘W within 15 s of an answer still asks, the safe failure. A misread at
  close is never harmless: a local close hangs up and reaps the agent, a
  remote one stops its session (`.stopIfRunning`); only the quit gate
  detaches a working agent on a host. The CLI decides without touching the
  tab and applies "at rest" only once its request is committed. Same rule
  for local and remote tabs (round 1 of the hands-on review: Sol, Fable).
  **Superseded for local tabs** by the owner's round 2: the rule is a tab
  on a host's only; a local tab keeps the settle timer's reading, as in
  v0.5.2.
  - **Follow-up, not changed here:** the quit gate keeps the timer's
    reading, and that timer ignores an unanswered Return (pre-existing):
    15 s after a Return with a quiet title it settles to idle, so a long
    tool call that holds its title is stopped at quit as idle rather than
    detached. Making the timer honour an unanswered Return trades that for
    an agent that never retitles (`CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1`,
    or a CLI with no titles) reading as working forever, prompting at every
    close and detaching at every quit until a bell.
  - **Every way a user action becomes bytes to the pty** (hands-on review
    round 4: enumerated once from libghostty's `Surface.zig`, every
    `queueIo` that writes, rather than one gesture at a time). An early
    rest needs none of them since the spawn; each is recorded at the
    Temple-side hook named, as `surfaceDidReceiveInput`
    (`OpenSessionsModel.inputSinceSpawn`).

    | Path (libghostty) | Bytes | Temple-side hook |
    |---|---|---|
    | `keyCallback`, `endKeySequence`: every key, keypad Enter, Esc, IME text committed inside a key press | key encoding | `GhosttySurfaceView.keyDown` (every press, before the surface) |
    | Keybind actions `text:`, `csi:`, `esc:`, `cursor_key` (`performBindingAction`) | the bound bytes | `keyDown` (they are reached only by a key; Temple's own binding actions are search, which writes nothing) |
    | `write_screen_file:paste` | a file path | `keyDown` (keybind only) |
    | `completeClipboardPaste`: ⌘V `paste_from_clipboard`, middle-click (captured or not), `paste_from_selection`, an unsafe paste confirmed | the clipboard | `GhosttySurfaceView.deliverClipboard`, the one place every clipboard read is handed over (`onReadClipboard`, `onConfirmReadClipboard`) |
    | `completeClipboardReadOSC52`: the program's own clipboard read | the clipboard | `deliverClipboard` too (counted although the program asked: over-counting only costs the shortcut) |
    | `ghostty_surface_text`: IME commit outside a key press, a drop's text | the text | `GhosttySurfaceView.insertText` (outside a key press) |
    | `mouseReport` from `mouseButtonCallback`, `cursorPosCallback` (drag), `scrollCallback`, while the program captures the mouse | mouse reports | `mouseDown`/`Up`, `right…`, `other…`, `…Dragged`, `scrollWheel` when `ghostty_surface_mouse_captured` (under tmux `mouse on`: always) |
    | `cursorPosCallback` motion reports (mode 1003, no button) | mouse reports | not recorded: no button, nothing chosen; tmux asks for button events only |
    | `scrollCallback` alternate scroll (alternate screen, no capture) | cursor Up/Down | not recorded (accepted, round 4): only Up/Down, and libghostty does not say when it applies |
    | `maybePromptClick` (a click at a prompt that declared OSC 133): cursor arrows, or with `click_events` an SGR mouse report | cursor Left/Right, or a mouse report | not recorded: tmux does not pass prompt clicks on, so a tab on a host never gets one (neither agent declares them either, measured). Closed with `cursor-click-to-move = false` until the owner's round 2, which reverted it: it was app-wide, and local tabs keep libghostty's behaviour |
    | `flagsChanged`, `keyUp`: Kitty keyboard modifier and release reports, when the program enabled them | key reports | not recorded: a modifier or a release submits nothing; the press that does is recorded in `keyDown` |
    | `clear_screen` keybind: an FF to the program when it is at a prompt | `\x0c` | `keyDown` (keybind only) |
    | `focusCallback` (mode 1004), `colorSchemeCallback` (mode 2031), the title report (CSI 21 t), and termio's answers to queries (DA, DSR, OSC 10/11) | reports | not input: the terminal's own state or answers to the program's queries, no content from the user |
    | `resize` | none (a window size, SIGWINCH) | not input |
- **T1, T2**: Fable's spec (the host on a second line under the name; the
  `--no-daemon` hint in secondary, the flag monospaced).
- **T3, colours.** Under Temple's own chain, tmux 3.4 asks the outer
  terminal for its colours on attach and answers a pane's OSC 10/11 with
  exactly them (measured with a dark terminal), so Codex picks its palette
  from Temple's background at startup, as locally; a Codex started while
  Temple was light keeps its light bands after a switch to dark, locally
  too. tmux 3.2a (jetson) neither asks nor answers (colour reports came in
  3.3), and no option changes that: Codex there gets no answer and uses
  its default palette. Acceptance: `testTerminalColoursAndTitleUnderTemplesChainOnEachHost`.

## Phase 3: the core locator decision

Phase 2's rounds 2 to 4 all landed on how paths compare, and Fable asked
phase 3 to settle core's part explicitly. **Decision: core's
`TranscriptLocator` and `TranscriptCandidates.assign` keep comparing
`String`s.** The remote module stays byte-exact at the type (`RemotePath`);
nothing in core changes but a doc comment on `TranscriptLocator` that
points here and to ADR-036.

Why not byte-exact, on the local side:

- **APFS folds the two spellings.** Measured on this Mac's APFS volume:
  after `mkdir café` (precomposed), `mkdir cafe\u{301}` (decomposed) fails
  with EEXIST, and both spellings open the one folder. A local store cannot
  hold two files that differ only in normalization.
- **Locally the same file reaches core from several producers**: the
  directory enumeration, FSEvents paths (routed to members through the
  engine's `byLocator` index), the row's recorded `transcript_path` used as
  a hint, and the catalog cache's keys. Under `String` equality two
  spellings of one file are one key. Byte equality would make them two
  whenever two producers spelled a path differently, so an event could miss
  its member or one file become two candidates, and every producer would
  need a normalization step to fold what APFS already folds. That is new
  risk on the path every user takes, for no local gain. No migration would
  be needed (the database and caches store strings either way), which is
  why this is a judgment of risk, not of cost.

What `String` equality can and cannot do on a host that keeps the two
spellings apart (ext4 does):

- **Where a collision can come from.** One `assign` call sees one session,
  one agent and one store, whose prefix is byte-identical (one root per id
  and agent; two roots that differ in normalization are two groups, phase
  2 round 3). Below the store neither agent writes anything but ASCII:
  Claude Code names a project folder with `replace(/[^a-zA-Z0-9]/g,"-")`
  (found in the 2.1.302 binary), so `é` in either spelling becomes ASCII,
  and the two differ (`-` against `e-`); Codex writes
  `sessions/YYYY/MM/DD/rollout-<timestamp>-<id>.jsonl`. A collision needs a
  folder inside the store that some other tool or person made, with a
  non-ASCII name, holding the session's file in both spellings.
- **What happens then.** The two are one candidate: the first in byte
  order (the listing is sorted by `RemotePath`), with its own stat (the
  remote source keys stats by bytes), and its read is sent its own bytes (a
  `String` keeps its scalars, and SQLite returns a recorded path as it was
  written). Identity verification reads the id inside the file. If the
  kept file is not the session's, the row stays unfilled (`mismatch` or
  `incomplete`); nothing of the other file, or of another session, reaches
  the row. A remote row is never `confirmedAbsent`, dimmed or
  auto-archived, so a missed candidate can cost a fill and nothing else.
- **The engine's locator index** merges two such locators across members;
  it only routes change events, and a remote source has no change stream.

Pinned by `RemoteSourceTests.testTwoSpellingsOfOneSessionsFileInOneStoreAreOneCandidateReadByItsOwnBytes`.
Revisit if an agent starts writing non-ASCII names below its store, or if
remote gains a change stream.

## Remote UX round 1 (Fable's UX-flow and visual reviews)

Owner constraints unchanged (ADR-036): closing stops, Temple never stops
anything later, nothing is discovered, the feature stays removable. What
changed, by finding:

- **No ended-identified state** (UX 3). "Yes, that's it" for a Codex
  session that ended before Temple learned its id records the claim (and
  the core join) as before, then closes the tab exactly as a local exit
  does. (It also selected the now-identified row; superseded by the
  simplification round, below.) The tab never becomes the
  session's tab, so no save of the tab set holds it; the run's own
  restoration is retired once the pending tab is gone (fix round). The `endedIdentified` phase, its banner and its
  Resume are gone; opening the row resumes, nothing resumes on its own.
- **Ended before identified: one band** (UX 2, visual 2). The fact and the
  question are one sentence, question first: "Codex ended on <host> before
  Temple learned which session this was. Is it “<first prompt>” (<time>)?"
  (no candidate: the first sentence alone), one candidate at a time, Not
  this one bringing the next; the identity note and the `--no-daemon` hint
  stay as its captions (the hint's place waits on the owner). The pane is
  never blank: tmux's exit leaves the client's screen as it was before tmux
  drew, so where the terminal was the tab says so in one line. (This
  round showed the last 40 lines of what the pane printed there instead,
  fetched as `.endedOutput`; superseded by the simplification round,
  below, with the reason.)
- **Banner answers sit by their sentence** (visual 5). Every remote band
  puts its answers right after the sentence as small bordered buttons
  (Reconnect, Resume, Resume anyway, Start a new session, Sessions on
  <host>, Yes and No, Try again); the trailing edge holds only dismiss-type
  actions (Discard, Cancel), as links in the app's bold-neutral style
  (`.neutralLink`, as History's Refresh and Settings' Show output; never the
  system blue, fix round), as are Sessions on <host>'s Open, Stop and Keep.
  Icons: a question mark for a
  session whose state or identity is unknown, the bolt for a dropped
  connection, the triangle for a stop that failed.
- **The working prompt explains itself** (UX 4). The remote "still working"
  alert gains local's message line: "Detach leaves it running; Stop ends
  it." (shortened in the fix round: the title names the host, and the
  longer line orphaned "it."). Buttons unchanged.
- **The selection follows the active tab** (visual 7). The sidebar's
  highlight was set only when the newly active tab had an id, so a pending
  Codex tab left the previous tab's row selected, and one identified while
  active never moved it. It now follows the active session tab's id as it
  changes (nil: no row selected), resolved when the activation is emitted;
  a utility tab leaves it.
- **The heading comes at once** (UX 5). Until a session on a host reports
  its folder (the `ok` record; a pending Codex session has no row at all
  until identified), the sidebar shows its project heading from the tab's
  folder, the one typed in the sheet, with the session's row under it when
  it has one. A display hint in `AppModel.displayProjects` only: nothing is
  written to the row, `session_state`, the remote store or the project
  order, and hints are left out of `orderedVisibleProjectKeys`, so neither
  a drag nor a Move can persist one. The reported folder still wins: the
  tab moves to it, the row records it, and the hint goes.
- **Copy and the Sessions sheet** (UX 7, UX 8 in part, visual 8). The
  folder sheet's field reads "Folder" (its title names the host). Sessions
  on <host> says "In a tab" (was "Open in Temple", which read as a button;
  simplification round) / "Running" / "Unknown" (nothing local
  says attached), in a capsule apart from Stop and Keep; the tmux name
  `temple-<handle>` moved from a line to the title's tooltip. A host
  project heading's context menu has "Sessions on <host>…". Folding the
  manual stop command into the sheet's header (UX 9) is later.
- **Hosts card and Test connection** (visuals 1 and 6). The Test
  connection terminal applies the app's appearance when it is made (the
  terminal runtime's theme is rebuilt only by an apply, and with no tab
  open nothing had applied it: white in a dark sheet) and again when the
  sheet's colour scheme changes; it is 160 pt tall. An enabled host's links
  read "Test connection" and "Sessions…" (the row names the host) in one
  trailing group, its status line is an 11 pt secondary caption (tertiary
  until the Add host sheet's visual review: too faint in dark; orange and
  red still mark a proven fault). The config switches keep the app's
  neutral tint (a `.tint(.accentColor)` tried in round 1 resolved to that
  same neutral inside `RootView` and was removed in the fix round) and are
  small rather than mini, whose knob read heavy in dark. (The switches are
  **superseded** by UX round 2: the card lists only hosts in use, and an
  alias is turned on from Add host…, section 7, now a sheet.)
- **One error colour, one field** (visual 3). The folder sheet's field is
  the Add host form's (plain, on the control fill, no heavy ring), and its
  "No folder …" and unreachable lines use the form's red.
- **History fits "name @host"** (visual 4). The wide tier of the meta
  column is 240 pt (was 180).


### Fix round (sol's review, the on-screen check, Fable's visual re-check)

Superseded: the first, second and sixth bullets below (the ended output,
its retention on the host, its cap rule) and the fourth (the row selection
after a yes) were removed in the simplification round that follows.

- **The ended output is the run's** (sol 3). The host hands a pane's
  output over once, so the fetch is kept by run (host and handle) in
  `RemoteTabController`, apart from any tab's ticket: a reopen while it is
  in flight waits on the same fetch, an empty later answer never replaces
  a good one, and only the presentation passes `.endedOutput`. The copy
  goes when no tab holds the run, or when Start a new session moves the
  tab to a new one. A fetch in flight is the run's over one launcher: a
  reopen after the host was removed or edited starts its own, never
  waiting on the retired host's cancelled one (sol round 2).
- **The output outlives the stop** (the on-screen check). The stop that
  proves a run's end removed its `.out` and threw away what it held, so
  closing an ended-unidentified Codex tab always showed the fallback line.
  A new Codex session that was typed into and never identified now keeps
  its output on the host (0600) until its question takes it, the run is
  dismissed or its tab is closed; only a run that comes back with that
  question keeps it (not dismissed, tab not closed, as `pendingRuns`), and
  every other run still leaves nothing behind.
- **A yes for an ended session saves no tab of it** (sol 1). It used to
  make the tab the session's (saved, active) and then close it, so a
  failed second save left a tab the next launch resumed. The pending tab
  now closes as it is and its run's restoration (`tab_closed_at`) is owed
  until the tab is gone, then written with the hand-over's retries; one
  that keeps failing is written at a later close, the quit or the next
  launch, and at worst comes back as an inert chip, never an active one.
- **The row selection after a yes is a gated completion** (sol 2). Set at
  once, then again a run-loop turn later over the active-tab follower's
  write of the neighbour the close activated. That second write is
  `.endedRowSelection`: it passes the gate (nothing after the quit or the
  host's retirement), and it replaces only the follower's own write, so a
  row selected meanwhile stays selected, even the neighbour's own row
  selected again (sol round 2: ownership by `selectionRevision`, which
  every selection but the follower's bumps, not by comparing values).
- **"Open in Temple" (now "In a tab") is this Temple's** (sol 4). It came from tmux's
  attachment count, which counts a terminal or another Temple too. It now
  means this Temple has a connected tab of the run
  (`RemoteTabController.hasLiveTab`); any other attachment reads Running.
- **Only a complete capture is shown as the last lines** (Fable's visual
  re-check). The pane's capture keeps its first 64 KiB
  (`LaunchRecords.outputCap`), so a long session's "last lines" were
  mid-session text under a label that said otherwise. The host now prints
  a capture's end only when the capture never reached the cap; a capped
  one is removed and treated as no output, and the band shows its
  fallback line alone. The real fix, keeping the tail rather than the head,
  is deferred: `pipe-pane` would have to run a bounded rotating writer (two
  segments of at most 32 KiB renamed in turn, read back in order), every
  reader of `.out` (the take, the end-proof discard, the collect) would
  read the segments, and it needs a reader of the pipe that never reads
  past its chunk (BSD `head -c` reads through stdio and can drop bytes at
  a boundary), proven against real tmux on macOS and Linux.

### Simplification round (Fable's altitude call after three review rounds)

Three review rounds (sol r1 to r3) found new problems in the same three
places each time, and the count was not dropping: the ended band's output
fetch (`RemoteTabController`), the host's retention of a run's `.out` for
its question (`RemoteSessions`), and the row selection after a yes for an
ended session (`AppModel`). Fable judged the mechanisms, not the next
patch, and two were removed rather than fixed again.

- **The preserved output is gone** (superseded: the fetch, its run-keyed
  cache and coalescing, `.endedOutput`, `outputChecked`, the 64 KiB cap
  rule, and on the host the keep-for-question retention and the removals
  in Close and Discard). Reason: three review rounds of races were spent
  keeping output nobody could read. The `pipe-pane` stream of an
  alt-screen TUI has no lines to keep, only cursor moves, so what reached
  the band was a run-on paragraph of spinner frames, status fragments and
  repeated JSON (Fable's visual round 3). Where the terminal was, the band's
  tab now says, at once and with nothing fetched, "Codex's last screen on
  <host> isn't kept after it ends." (12 pt, secondary, top-leading in the
  band's text column: 36 pt leading, 22 pt trailing, where the captions sit
  too): a fact, not a failure, since there is nothing to try
  again. A run's `.out` is handled for every run as it was before: an
  acknowledged stop or a proven absence removes it, kept in memory only
  for phase 1a's early-exit diagnostics, which are unchanged.
- **The row selection after a yes is gone** (superseded:
  `selectRowHandler`, `.endedRowSelection`, `selectionRevision`, the
  follower's write flag). Reason: the highlight means "the active tab's
  session" since the follower (visual 7). A yes that closes its tab leaves
  no session for it to follow, so selecting the identified row gave the
  highlight a second meaning, and each fix was a fight with the follower.
  The tab closes and the selection follows the tab that becomes active, as
  after a local exit; the identified row sits at the top of its project,
  under the heading the folder hint already showed.
- **The row's title until its own arrives.** The yes knows the candidate's
  first prompt, so `AppModel.titleHints` holds it by session id and
  `displayTitle` shows it while the row has no name and no title fact, so
  the sidebar never flashes "New Codex session". Display only, never
  written; dropped once the fill writes the title. It is seeded only as
  the tab's part of `.identityResult` (nothing after the tab's close, the
  quit or the host's retirement), and only when the claim answers with the
  candidate's own id, compared by bytes (sol round 4). The ended tab's terminal
  title (for example "Reply ok | temple-ux3") is no longer pushed as the
  session's generated title, since the fill titles the row.
- **The ended band fits a narrow window.** `ViewThatFits` on the band row:
  the sentence and its answers on one line when they fit, else the
  sentence at the band's width and the answers on a leading row beneath
  it, Discard at that row's trailing edge (no `fixedSize` or
  `layoutPriority`, per the split view's inset rule). Host names in the
  tab's bands carry non-breaking hyphens (U+2011, `RemoteCopy.displayHost`,
  display only), so "masterblaster-mentes" wraps whole.
- **"In a tab"** replaces "Open in Temple" in Sessions on <host>'s capsule:
  a state, not an imperative. The `--no-daemon` hint was already set in
  monospace (an attributed run), so its dashes are SF Mono's hyphens and
  were left.

Later, not now:

- **A rendered last screen.** If the ended band should show what the pane
  showed, capture the rendered screen, not the stream: either
  `remain-on-exit on` with a `pane-died` hook that runs
  `capture-pane -p -S -40` into the run's marker directory, fetched once,
  or a replay through the Test connection's read-only terminal. Pick then.
- Stripping glyphs and suffixes from terminal-derived titles (a heuristic
  one TUI change behind; the title hint already covers ended rows), and
  the look of an ended row over the launcher.
- Hiding the Hosts card's `--no-daemon` note until a host is enabled, and
  listing only the `~/.ssh/config` hosts that answer (owner round 2 visual
  review: later, not now).

## Owner decisions, round 2 (no flag, local unchanged, auto-link, quit)

The owner decided four things after the UX round; each is built as below,
and the sections above say so where they changed.

1. **No feature flag.** `temple.feature.remoteHosts` is gone (a stored value
   is ignored). Remote is invisible until a host is enabled: with none the
   registry holds this Mac only, no ssh config is read until Settings' Hosts
   card is shown, nothing is spawned, the remote project store is not even
   attached (it is once a host is enabled, or when its file is already
   there), and no remote UI appears but that card, the one way to add a
   host. Remote UI appears for an enabled host only (a host project's
   Sessions menu item included). `check-remote-off.sh` became
   `check-remote-code.sh`: the `.app` carries the remote code and the host
   list has no default. The `remote-flag-on` branch is superseded.
2. **Local behaviour is v0.5.2's.** Every change since v0.5.2 that reached
   this Mac's tabs was audited (`git diff v0.5.2..HEAD -- Sources`). Scoped
   to remote: the early rest rule at ⌘W and the CLI's close; stand-in title
   suppression; History's 240 pt meta column (only while a host's project is
   listed); the key catcher's yielding to sheets (remote's own sheets, each
   marked while up, not every sheet window). Reverted: `cursor-click-to-move
   = false`; the quit drain's early end with local agents in it (they get
   the whole window again); an empty tooltip on local project headings and
   the find bar's wrapper. Kept, as fixes the owner accepted: Codex
   app-server rollouts titled from the first typed prompt (91bddc4, with
   `factsVersion` 3), and the sidebar selection following a tab that gets
   its session while active (d5a8616). Inert for local and kept: the input
   and stand-in hooks in the terminal view (reported, but read only for
   remote tabs), `clipboard-write = allow` (libghostty's default, pinned),
   the acknowledged tab save, the registry box, the engine set's add and
   remove, and the quit prompt's host line (absent with no remote tab).
3. **A lone Codex candidate gets Temple's own yes** (Fable's UX item 1):
   section 3's "As built (owner, round 2)" note. The `--no-daemon` hint
   left the bands for the Hosts card's notes.
4. **Quit stops nothing on a host** (section 5's Quit, as built): every
   client detached, every run left running and restored as a tab.
   Docs: jetson's Claude login is optional coverage, not a gate; the
   additive-schema rule stays, kept by the owner.

### Round 2 visual review (Fable and Opus on the screenshots)

- The linked band's Discard sits right after its sentence as a small
  bordered button, as the question's answers do.
- A candidate's start reads relative to the tab's open ("started 4 s after
  this tab opened", whole minutes past one; the start, on the host's
  clock, is moved by the offset the lookup measured (Sol round 6); the
  clock time when the open or the offset is unknown, the start was well
  before it, or an hour after), so candidates
  whose prompts read the same are told apart; candidates are listed in
  start order.
- The remote close alert reads "<agent> is running on <host>." (it shows
  while a reattached agent can't yet be told idle), with "Detach leaves it
  running; Stop ends it." The local alert is unchanged.
- The Hosts card's note reads "With --no-daemon in Codex's arguments above,
  Temple identifies each new Codex session on a host by itself."
- ⌘N's "Folder on <host>…" glyph takes the width of "Choose folder…"'s, so
  both labels start at one x; the rows were already one height each (46 pt),
  and "Choose folder…", this Mac's row, is unchanged.

### Round 2 fixes (the computer-use pass and Sol's review)

**Superseded** (all but the first and last bullets): the undo design these
fixed, Not this session with its per-run identity state machine, epochs,
deferred save-acknowledged unlink, `r6-auto-link` provenance and
`asked_at`, was removed before it was pushed. Sol's round 2 found five more
problems in the same mechanism (a row-ownership proof for the undo's delete,
provenance lost on reconnect, an aborted link's release racing identity
results, a deferred unlink fencing the wrong ticket, `asked_at` backfill):
two clustered rounds, so the mechanism changed instead of another patch.
Fable's decision: an automatic link is a yes Temple gives through
`confirm`'s exact path, plus a display-only note, and a wrong one is
corrected with Discard (section 3). Each race class existed only because
the undo deleted a row, re-showed a button, released a claim concurrently
or deferred its write; none of that exists now. Kept: the couldn't-tell
line (for the last declined candidate) and the retired host fix.

- **Never a bare tab.** Not this session on the only candidate left the tab
  with nothing (the host's lookups leave a declined candidate out). A run
  that was asked about now says "Temple couldn't tell which Codex session
  this is." whenever no candidate is left. The tab's title is Codex's own
  terminal title throughout, as for any pending tab.
- **One identity state machine per run** (`RemoteTabController.RunIdentity`,
  replacing three loose sets): pending → linking → linked → unlinking →
  pending, with an `epoch` that every Not this session moves. A check,
  open, close or yes captures the epoch when it begins, and `adopted`
  ignores an answer from an older epoch; while linking or unlinking no
  check runs and only the automatic claim's own answer is taken up.
- **A link is made only where it can be undone.** The automatic claim
  (`autoConfirm`, `RemoteSessions.confirm(automatic:)`) is checked again
  when it answers: if the tab ended, closed or reconnected meanwhile, or
  the app is quitting, the claim is released and the question decides.
- **Not this session waits for the saved tab set.** Nothing is released
  until a save without the session is acknowledged; it is retried
  (`unlinkSaveRetries`), said once if it keeps failing, and finished at the
  next acknowledged save. An unlink still owed at quit is lost with the
  memory, and the restored tab keeps its link line.
- **Kept with the run** (`r6-auto-link`, additive): `asked_at` (the store
  refuses an automatic claim once the user was asked, across relaunches;
  set when candidates are shown, one is declined, or a link is undone) and
  `auto_link` (the claim's candidate and the core row its join made). A
  session tab attached to that run after a relaunch gets its line and Not
  this session back (`restoreAutoLink`).
- **A row somebody opened stays.** `releaseLinkedSession` also needs
  `last_opened_at` empty, or no later than the restored tab's own open
  (`openedThrough`).
- **A retired host leaves nothing on screen.** Its notice and any sheet
  asked for it go with it, and Sessions on <host> or the folder sheet open
  only for an enabled host.


## Cold-read round (wording, behaviour and visual design)

**Why.** The owner found the Hosts card's `Test connection  Sessions…  Turn
off` unreadable after every design review had passed it. A cold read of
every remote string, by a reviewer with no context, and a task walk found
43 mismatches between what a label made people expect and what it did
(docs/copy-review.md now makes that procedure a rule). Fable decided each
fix and a second cold read refined them; the decisions, the string index
and the second read are kept outside the repo with the round's working
files. The coordinator's rulings: no local label or behaviour changes (so
the local "New Claude session" row stays; Fable's proposal to rename it was
not built), closing a waiting host tab still stops its agent, a quit still
leaves every agent on a host running, and there is no flag.

**Words, as built.** One name per thing, never shortened for a row's
rhythm: the sheet is "Running sessions on <host>" everywhere (the Hosts
card, a project heading's menu, a failed stop's band and the sidebar
notice, each with "…"), adding by hand is "Add host by address", Detach is
the user closing a tab and leaving the agent running (P4, P6, X1, File),
Disconnect is the connection ending (B2, B3, F13). Running = alive on the
host; working = busy with a task, and only a working agent is asked about
("Claude Code is working on <host>."). Prose names the products ("Found
Claude Code 2.1.283, Codex 0.48.0, tmux 3.4."); a command's name appears
only as what was looked for ("No codex command on PATH."). Every status
line ends "Not checked whether Claude Code and Codex are signed in." (Temple
never asks). Every line that says something may still be running is
orange. The copy lives in `RemoteCopy` and `HostTestSummary`; the unit test
is `RemoteCodexIdentityTests.testTheCopyIsOneSourceAndHasNoEmDash`.

**Behaviour, as built.**

1. *Detach* (`RemoteTabController.detach`): on a tab on a host, the row's
   menu and the tab's menu read "Detach from <host> (keeps running)"
   directly above "Close tab (stops the agent if it is waiting for
   input)", and File has Detach above Close Tab (no shortcut). The tab's ×
   says what closing does there. The row menu's Close tab on a host goes
   through the close prompt, as ⌘W does.
2. *Remove* (`AppModel.requestRemoveHost`): both kinds of host read
   Remove. The host is asked for Temple's tracked sessions first; any
   running (in a tab here or not) shows the alert ("2 sessions are still
   running on <host>." / the singular), with "Remove, leave them running"
   (default: retiring the host detaches its tabs), "Stop them and remove"
   (each stopped through `stopTracked`, no per-session question; a failure
   keeps the host and is said under its row) and Cancel. None running, or
   no answer: removed at once. Two new gated completions:
   `.removalCheck`, `.removalStopOutcome`.
3. *Discard* has one meaning, a session that is not running here (B4, B5,
   B12), and never stops anything. Its link says which: "Remove from
   Temple", or "Archive session" when the row is named, pinned, colored or
   has a transcript. A stop is "Stop on <host>" in the row's menu.
4. *Not this one on a link Temple made on its own* (`unlink`): one
   remote-store write (`RemoteStateStore.unlink`) releases the claim,
   declines the candidate and clears `tab_closed_at` (a hand-over already
   written is undone, so the run restores by its handle again); the
   hand-over still owed is dropped. The row the link created is archived as
   a person's archive (History restores it; the reason "declined link" is
   the remote store's declined candidate and a log line, not a new core
   `archive_reason`, so core's archive semantics are unchanged). The tab
   becomes pending again and loads the question without that candidate;
   none left, it says Temple couldn't tell, with Try again. The agent keeps
   running and its client stays attached.
5. *Dismiss* (S11) is only on a row with a left-running note and clears
   the flag; "Kept" is gone.
6. *The folder sheet's Test connection* opens the host's own Test
   connection sheet over the folder sheet (`RemoteFolderSheetModel.
   testConnection`); closing it returns with the typed path, and a test
   that passed checks the folder again (`testClosed`). "Start without
   checking" replaces "Start anyway".
7. *Open ~/.ssh/config* replaces Edit on a config row (A12's action).
8. *Open / Show tab* on every Running sessions row: Open opens the session
   as its sidebar row does (an unidentified Codex run opens by handle);
   Show tab focuses its tab; both close the sheet.
9. *The launch notice*: the quit's plan flags each connected tab's run
   `detached at quit` (a `RemoteLeftRunningReason`, stored in the existing
   `left_running_reason` column, so no migration; it never shows as an S7
   line). The launch contact splits its count (`contactLeftRunning` now
   answers `(closed, quit)`), and the notice says "3 sessions from before
   you quit are running on <host>." once; Running sessions… or × marks it
   seen, and attaching clears a run's flag as before.
10. *One tmux rule* (`HostTestSummary.provesTmuxUnusable`, missing or older
    than 3.2): such a host leaves the launcher and ⌘N, is greyed in the `+`
    menu (its availability already said so), and the folder sheet says the
    host's line and won't start. A refusal (`tmux 3.4 couldn't start a
    session`) is said, not the rule.
11. *Stopping a working agent asks* (S12, `workingTab`): from Running
    sessions and from "Stop on <host>". "<Agent> is working on <host>. Stop
    it?", "Its tab closes." when a tab is open. An agent waiting for input,
    or with no tab here, stops at once.
12. A row whose agent still runs on its host can't be archived: "Stop it on
    <host> to archive" (`AppModel.archiveBlocker`), as "Close tab to
    archive" already did.

**Visual, as built.** One chrome (`RemoteSheetChrome.swift`): 20pt padding,
520 wide (Test connection stays 680), a leading VStack 12pt apart, a 15pt
title, the 96pt leading label column for the host form, the Add host sheet
and the folder sheet, Settings' field chrome (`templeFieldChrome`, now also
what `SettingsView.textField` uses, unchanged there), hints 11 secondary,
problems in Settings' triangle-and-red shape, lists under a field as plain
full-row buttons washed on hover (never the link colour), links
`.neutralLink`. The Hosts card's links sit on their own line under the
name, wrapping (`WrappingRow`) rather than cutting a label: "Running
sessions on masterblaster-mentes…" does not fit beside a name in Settings'
column. No measuring view (`ViewThatFits`, `fixedSize`) was added under
the detail pane.

**Not built, with reasons.** The `.link` buttons in the launch-failure
header, `LauncherView` and `HistoryTabView` are local surfaces (AGENTS.md:
remote must not change a local tab's looks), so they keep the system link
style. The local "New Claude session" label, and the untitled-session title
Running sessions shares with the sidebar, stay as they are. The `+` menu's
"Codex — <reason>" separator is the shared local format and keeps its dash.
"No `codex` command on PATH." is plain text ("No codex command on PATH."):
a status line is one string, also used as a greyed menu item. H5's long
sentence is an orange line under the row, not the caption slot. The
`--no-daemon` hint's mechanism clause was checked against Codex's own
`--help` ("Run without the shared background server, even if it is already
running") and reads "Codex then runs each session in its own process
instead of a shared background server".

**Tests.** `RemoteColdReadTests` (Remove and both choices, a failed stop
keeping the host, the row actions, Detach, the working-agent question, the
archive blocker, Open / Show tab / Dismiss, a failed sheet stop, the folder
sheet's test, the tmux rule, the launch notice and which runs the quit
flags); `RemoteCodexIdentityTests` (Not this one, with candidates left and
none, and its failed write); `RemoteAppTests.testNotThisOneArchivesTheLinkedRowReversibly`;
`CodexIdentityTests.testUnlinkReleasesTheClaimDeclinesAndRestoresTheRun`;
the gate walk's two new completions. Computer-use passes check tasks, not
labels (docs/copy-review.md).

### Cold-read round: review fixes

Sol's code review (seven should-fixes), Fable's visual review (items 1 to
4; item 5, shortening "Close tab (stops the agent if it is waiting for
input)", was overruled by the coordinator per docs/copy-review.md) and a
cold read of the real screens, as built:

- *Not this one commits first.* `unlink` writes the store first; only a
  committed write drops the owed hand-over, archives the row and (through
  the new gated completion `.unlinkResult`) makes the tab unidentified. A
  failed write changes nothing, is said once, and the button can be used
  again (`RemoteTabState.unlinking` holds it while the write is out).
- *The undo is a hand-back, the hand-over's reverse* (Sol round 2; the
  second finding in this path, so the mechanism, not a patch). The unlink
  write releases the claim but keeps the run's own restoration off
  (`tab_closed_at`, set if not already) and records `hand_back_from` (the
  session id a saved tab set may still hold; remote store migration
  `r6-hand-back`). A `HandBack` obligation holds the run store like a
  hand-over: it is finished (`finishHandBack`: restoration back on) only by
  an acknowledged save after the tab became the run's, dropped
  (`dropHandBack`) when the tab went first (a close or detach stands),
  retried, and settled at the quit; the UI gate decides only what the tab
  shows. At the next launch `restorePending` turns a saved tab still holding
  the session into the run's tab (or brings the run back by its handle when
  none does) and owes the hand-back again; an open of such a saved tab (the
  restored active one opens at once) does the same before it would ever
  open the rejected session. Relaunch tests: the quit before the write
  commits, a failed tab save, and a detach before the commit.
- *A late hand-over can't undo it.* `RemoteStateStore.markTabClosed` marks
  the run only while it still holds the session id the hand-over was owed
  for, in the statement itself (`RemoteRunLedger.markTabClosed(_:sessionID:)`).
- *Never a bare tab.* After Not this one the tab says Temple couldn't tell
  until a lookup brings candidates (`unlinkFallback`); a failed lookup and
  Try again keep it. Try again never re-offers a candidate declined in this
  tab (`declinedHere`), even before the host's record is written. The line
  now reads "…; it gets a sidebar row once Temple can tell."
- *Remove* counts a session with a connected tab here as running, whatever
  the host's probe said, and adds one the listing lacks
  (`runningForRemoval`); Stop them and remove stops it too.
- *The launch notice* is built from handles the host proved present
  (`contactLeftRunningByCause`: an unknown probe counts for neither cause),
  minus any open in a live tab here when the answer arrives.
- *Open on a rowless session* opens a Codex run through the pending path
  (which rejoins an identified run whose core join failed) and any other by
  its session id; with no folder on record the row says what to do and the
  sheet stays open.
- *The folder sheet's post-test check is advice*: it shows where the path
  resolved; only Start starts.
- *A just-reattached tab's close prompt* says "<Agent> may still be working
  on <host>." ("Temple reattached to it a moment ago and can't tell yet.")
  until input, a wake or the settle timer's first reading
  (`OpenSessionsModel.unsettledReattach`, `workingIsUncertain`).
- *A removed host's open tabs* say so at once, in place of their other
  headers, with Open Settings at Hosts (`AppModel.removedRemoteHosts`; an
  edit keeps the name and is not a removal).
- *Visual*: remote hints and problems wrap (the Name hint was cut); Add
  host hides its "Add host by address…" link while the default button reads
  the same; the folder sheet's title is "New <Agent> session" with the host
  in mono after it; every `--flag` in the Hosts notes is code.
