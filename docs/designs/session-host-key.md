# A session is its id on a host

Status: accepted by the owner 2026-11-15 ("session id is unique only on the
same machine, not across machines"). ADR-041.

## The problem

Since ADR-036, `session_state` keys a session by its id alone and records the
host as an attribute (remote-ssh.md section 8): "a join or adoption for an id
already present on another host or as another agent is refused and shown".
That holds only while a transcript lives on one machine. It does not when a
person copies one: on 2026-11-15 the owner rsynced a Claude session from
mac-personal to mac-mini-personal, `claude --resume <id>` worked on the Mini,
and Temple refused to open it there: "Temple here already has this session,
on this Mac" (`OpenByIDSheet`, `.elsewhere`), because the id already had a
row on this Mac. Archiving the local row did not help (the row stays), and
nothing in Temple moves a row to another host.

A session id is unique on one machine. Two machines holding the same
transcript hold two sessions from then on: each can be resumed, and each
continues on its own.

## The decision

**A session is `(id, host)`.** Everywhere Temple stores, looks up, compares
or announces a session, it names both. `SessionKey` (already in TempleCore)
is that identity; `MembershipRef` adds the incarnation as before.

- The same id on two hosts is two rows, two members of two engines, two
  sidebar rows in two projects (projects are already `ProjectKey(host,
  path)`), and two History rows on two pages. Neither knows about the other.
- Marks (name, colour, pin, archive) are per row. A copy opened by id on
  the Mini starts with none; an import from that host's own Temple still
  carries its name and colour (ADR-039). Carrying marks between copies is
  not part of this change.
- The agent conflict stays, per host: one id on one host is one session,
  and a second agent's claim on it is refused (`agentConflict`).
- A local tab and a remote tab of the same id can be open at once; they
  are different tabs of different sessions.

## Schema: `v14-session-host-key`

`v13-project-host` stays reserved and unused. One migration, in one
transaction under the migration lock:

1. `session_state` is rebuilt with `PRIMARY KEY (id, host)`: same columns,
   same defaults, rows copied, the `session_state_incarnation` trigger
   recreated (incarnations are kept).
2. `open_tabs` is rebuilt with a `host` column (`NOT NULL DEFAULT ''`),
   `PRIMARY KEY (host, project_path, position)` and
   `UNIQUE (host, project_path, session_id)`. Each saved tab's host is
   backfilled from its row (`SELECT host FROM session_state WHERE id =
   session_id`, unique at that point); a tab with no row keeps `''`.
   Today a saved tab takes its host from its row; with two rows per id the
   tab has to say which.
3. `process_registry` gets a `host` column (additive), so closing a tab
   unregisters that tab's session only.

**Older builds.** Every build since GRDB's `hasBeenSuperseded` guard refuses
a database with a migration it does not know and says "Update Temple to
continue". So a dev build opening the real database locks out the installed
app until it updates, as any migration does. Builds before ADR-029 have no
guard and fail on the new key; they are months old and not supported. The
"schema changes stay additive" rule in AGENTS.md is amended by the owner
for this change.

**Another Temple's database (ADR-039).** `PeerTemple` reads a fixed column
projection of `session_state` (`host = ''` rows) and `open_tabs.session_id`;
both survive the rebuild, so this build reads older and newer peers, and
older builds read this one. A peer's saved tab is still matched by id alone
(it only says "In a tab on <host>"), which is accepted: the projection has
to work on files without the new column, and choosing a query by schema
would add a second, unwatched `sqlite3` run to a script whose watchdog and
lock handling were reviewed in depth (ADR-039).

**Old writers.** The newer-schema guard is checked when a Temple opens the
file, so an older Temple already running when a new one migrates would go
on writing by id alone. v14 is in `TempleDB.soleAccessMigrations`: it runs
only when no other Temple process has the file open (`FileHolders`, by
device and inode); otherwise nothing is written and the launch says which
process to quit.

**Two aliases, one machine.** A host is its configured name, so two
aliases for one machine are two namespaces: the same transcript reached
through both is two sessions. Accepted.

## Code

- **TempleDB.** Every per-session read and write takes the host:
  `sessionState(_:host:)`, the setters (pin, archive, name, colour),
  `updateState` (no `.local` default), `join` (`ON CONFLICT(id, host)`;
  `hostConflict` is removed), every `open_tabs` guard
  (`... WHERE session_id = ? AND host = ?`), `OpenTabRecord.host`,
  the process registry. Observers deliver `SessionKey`; the lists
  `autoArchive`, `restoreTempleArchives` and `discardNeverStarted` return
  `[SessionKey]`.
- **Engines** are per host and keep their `String` member keys. The relay
  passes on only its own host's joins and leaves.
- **App.** `Session.id` becomes `SessionKey` (so SwiftUI identities and
  every dictionary built from it are host-aware), with `Session.sessionID`
  for the bare id. `EngineSet`'s merged maps, the presented rows, title
  hints, the overlay store, History's projection, the archive policy and
  tab lookups (`openTab(for: SessionKey)`) all key by `SessionKey`. A tab
  already has `host` and `sessionID`.
- **Open by ID.** The `.elsewhere` state and its "Open it" button go. The
  check looks for a member on the chosen host only; a member on another
  host is irrelevant.
- **History.** A row on a host's page whose id is a member on another host
  is no longer a conflict row: it is that host's session, importable.
- **`temple` (the command line).** `sessions get|open|close` and `history
  get` act on this Mac's session unless `--host NAME` names another machine
  (owner's call: no `--host` always means this Mac). Control protocol 2:
  requests may carry `host`, and every session says its host. `templectl
  --watch` gives its local engine's verdicts to this Mac's rows only.
- **Notifications** carry the host with the id; one posted by an older
  build opens only when exactly one host has the id.
- **Engine merge and facts.** The merged snapshot is `SessionsSnapshot`,
  keyed by session; the fact committer keys pending and applied writes by
  session, so one host's snapshot never revokes another's.
- **Remote state** (`remote-state.sqlite`) is already keyed by
  `(host, session_id)`; unchanged.

## Not changed

Transcript formats, the engines' per-host state machines, the remote
run model, the auto-archive and discard predicates (only their keys), and
what any surface looks like for a session that exists on one host.

## Tests

- Migration: a v12 fixture with local and remote rows and saved tabs
  migrates with every column and incarnation kept and each tab's host
  backfilled; a second row with the same id on another host can then be
  joined; the trigger still stamps incarnations.
- Every DB write touches only its `(id, host)` row when the id is on two
  hosts (pin, archive, name, colour, title, touch, fill, leave, discard,
  auto-archive, restore, open-tab guards).
- Open by ID on host B for an id that is a member on host A opens on B.
- Two tabs, same id, two hosts: both open, both restore after relaunch,
  closing one leaves the other.
- History on host B lists the copied session as importable.
