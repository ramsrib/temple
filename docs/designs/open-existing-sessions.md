# Opening existing sessions on a host: design

Status: locked (revision 4), after gpt-6-astra's rounds 1 to 3 (each "approve with
must-fixes"; round 3 confirmed round 2's fixes) and Fable's final read
("lock in with changes"), plus the owner's decisions on names, the menu and
where Open by id lives. The changes are
listed at the end. Builds on remote (ADR-036, [remote-ssh.md](./remote-ssh.md));
changes nothing about how a session runs on a host once its tab is open. No
core schema change.

## The problem

On this Mac, History is the door to every session: one Temple never saw can be
imported or opened (resumed), and it joins (ADR-028, ADR-023). On a host there
is no door. A host can only start new sessions (⌘N, the launcher, a project's
`+`); a session that already exists there and is not a row here cannot be
reached from Temple at all. remote-ssh.md section 1 put "discovery or import of
remote sessions Temple did not start or open" out of v1 on purpose.

The case that motivates this: two Macs, each running Temple, each connected to
the other as a host. Work started in Temple on Mac B is continued from Mac A
today by hand: ssh to B, tmux, `claude --resume <id>`. Temple already does
exactly that for its own remote rows; what is missing is a way to reach B's
sessions.

## What this adds

1. **Temple on a host, in History.** History's header gets a menu choosing
   whose sessions the page shows: **This Mac** (today's page, the default)
   or a connected host by its name. Choosing a host reads
   that host's Temple database, if it has one, and lists its sessions beside
   this Temple's own rows for that host. Open resumes one on that host in a
   tab here; Import brings it in, with its name and colour, without running
   it. No session file is listed or read to build the list.
2. **Open a session by id.** A sheet, shaped like the new-session-on-a-host
   sheet: host and session id (agent and folder appear only when Temple
   can't find them out). Temple checks that this one session exists there,
   then opens it, or says why not. It is
   the way in for a host without Temple, for a session the list does not
   show, and for This Mac.

Both end in the same place: the session joins as a row on that host
(`opened` or `imported`, ADR-023) and resumes through the host's own
launcher, the remote machinery that already exists.

Out: listing a host's session files (a remote `catalog` over `find`); a Temple
whose state is not in the default place; writing anything to the other
Temple; mirroring its sidebar; a persistent cache of what it said.

## 1. History: whose sessions

### The menu

```
History    [ This Mac ▾ ]   All · In Temple · Archived · Not in Temple
             This Mac
             ─────────
             mac-b
             masterblaster   no Temple      (muted, once it has said so)
```

- Shown only when at least one host is enabled (remote's "no host, nothing
  changes" rule, AGENTS.md). Every enabled host is listed; none is contacted
  to decide whether to list it. Not persisted. A host that has answered
  "no Temple" during this run keeps its place but shows a muted "no Temple"
  beside its name, so the host that matters stands out (memory only).
- **This Mac** is exactly today's History: this Mac's session files plus
  every row this Temple has, remote ones included. It contacts no host.
- **A host by name** reads that host's Temple, when chosen and on Refresh (⌘R).
  Never at launch, never on a schedule, never a host that is not chosen.
- Navigation that targets a project (`showOnly(project:)`, the archived
  project entry points) goes to This Mac.
- **The bridge.** A session started in Mac B's own Temple is not on This
  Mac's page, and nothing else would say where to look. On This Mac, when a
  host is enabled and a search finds nothing (or only a few rows), one quiet
  line under the results: "Not here? Look on mac-b" (one link per enabled
  host not marked "no Temple"). It switches the page; it contacts nothing
  until clicked.

### A host's page

- The sessions this Temple already has on that host are always listed,
  whatever the read does. The host's Temple snapshot (section 2) adds its
  sessions. The header line says what is shown: "Sessions on mac-b · from
  its Temple, read 3 min ago". That one phrasing is used everywhere the read
  is dated.
- Rows are keyed as History keys them, `HistoryKey(host, agent, id)`, and
  classified by the existing member / outside / conflict rules. A peer row
  that is already a member here (same host and agent) shows as that member,
  with this Temple's title, folder and decisions. An id that is a member on
  another host or as another agent is a conflict row with its reason and no
  actions.
- The scopes keep their meaning relative to this Mac, and on a host's page
  are labelled so they cannot be read as the other Temple's: **All · On this
  Mac · Archived · Only on mac-b** ("In Temple" beside a header naming
  mac-b's Temple read as the opposite). Labels go through the cold read.
- A peer row shows: last activity (the peer's `last_active_at`), agent badge,
  the peer's displayed title (`custom_name`, else `title`, else the agent's
  placeholder: the same chain as `Session.displayTitle`), its colour,
  project, and two marks: "Archived on <host>" (a tag after the title: the
  session's archive, or its project's from the peer's `project_state`) and
  **"In a tab on <host>"**, in the row's status column, where it is seen
  before Open. Its tooltip says what it is: a saved tab in that Temple, not
  proof the agent is running. Neither gates anything: a session may run in
  two places, as `claude --resume` allows. Opening a row with that mark
  says so once, in the tab's launch header: "mac-b's Temple also has a tab
  for this session."
- **Open** resumes it in a tab here, running on the host (section 4).
  **Import** (⌘I, the selection bar) joins it with its name and colour
  (section 3), with today's confirmation and Undo.
- A member that cannot resume yet (imported, its folder not filled in) can
  still be opened from its peer row: the peer's folder is the launch hint
  (section 4). The member's presentation is unchanged.

### Failures

A line above the rows, never an empty page in place of one, never hiding
this Temple's rows:

- no database at the default path: "No Temple on <host>." with **Open a
  session by id…** (and the menu marks the host, above)
- no `sqlite3` on the host: "Temple can't read sessions on <host>: sqlite3
  isn't there." with Open a session by id…
- host unreachable: the transport's own first line, with Test connection
- database busy or unreadable: "Temple on <host> couldn't be read: <line>."
  A hot journal (the other Temple crashed mid-write) says so: "Temple on
  <host> needs to be opened once before its sessions can be read."
- a database whose shape this build cannot read: "Temple on <host> keeps
  its sessions in a form this version can't read. Updating Temple on both
  Macs usually fixes this." with Open a session by id…
- a result over the budget: "Temple on <host> has more sessions than can be
  read at once." with Open a session by id… Nothing is truncated silently.
- rows skipped as unusable (no agent or folder, an agent this build does not
  know, a malformed field) are counted in the header line, not listed.
  Measured on the owner's database: 297 unarchived rows, 1 without a folder;
  184 archived, 182 without.

The last good snapshot stays on the page while the tab lives, dated (the
header line's "read 3 min ago"), and a failed Refresh does not replace it.

### Peer rows are their own origin

Peer rows enter History's projection as a third origin beside catalog rows
and members (`HistoryProjectionInput.peer`), not as synthetic
`TranscriptSummary` values. They carry no transcript evidence: they never
feed `CatalogCoverage`, completion, `transcriptMissing`, noise or any
absence. `RemoteSessionSource.capabilities` and `catalog` are unchanged.

### Lifetimes and races

- The chosen page is projection input: changing it bumps the generation,
  cancels recorded commands and reconciles the selection (History's
  existing rule).
- A snapshot is bound to the host **configuration** that produced it (the
  host record's address, user, port, identity and jump host, plus the
  registry's add/remove generation). When that configuration changes, or
  the host is removed, or removed and re-added under the same name, the
  snapshot and every pending action captured from it (a queued Open or
  Import, an open confirmation, a Redo) are dropped; the page shows the
  host's rows and a Refresh. An Undo already earned is not: undoing an
  import touches only this Mac's database (section 3's receipt), so it
  survives the host being edited or removed. A Redo after such a change is
  refused.
- Reads carry a read id as History's catalog reads do, alongside the remote
  gate's ticket (`RemoteEffectGate`, bound to the tab's lifetime). Only the
  latest read for the current configuration installs; two Refreshes that
  finish out of order install the newer.
- Open, Import, Import's confirmation and its Redo recheck the row's live
  classification when they run (it may have become a member, or a
  conflict). `join` stays the transactional authority.

### A limit, stated

Sessions the other Temple runs on a third host (Mac B's sessions on
masterblaster) are rows with a host on B and are skipped (section 2). They
are reachable by id on that host. Not a bug; not in this version.

## 2. Reading another Temple's database

One exec over the host's existing ControlMaster (`RemoteExec`), one script.

- Path: `$HOME/Library/Application Support/Temple/temple.sqlite`
  (`TempleState.defaultDirectory`). Absent: "no Temple".
- `sqlite3` on the host's PATH, else `/usr/bin/sqlite3`. Absent: its own
  answer, not "no Temple".
- One read-only connection, URI `file:<path>?mode=ro`, `.timeout 1000` (how
  long to wait for the lock). Never read-write, never `immutable=1`, never a
  copy of the live file.
- **The host bounds the transaction, not ssh.** Temple's database uses a
  rollback journal (`DatabaseQueue`), so while the read holds its shared
  lock the other Temple's next write waits on its 5 s busy timeout. The
  script runs `sqlite3` as a child with a host-side watchdog that kills it
  after 2 s (a shell `sleep`/`kill` pair; macOS has no `timeout`), and the
  operating system releases the lock with the process. The ssh deadline
  (10 s) is for transport only; `SSHExec` killing its local client proves
  nothing about the host's child. A watchdog kill is "busy", not a failure
  of the host.
- **One snapshot, materialized before output.** The schema check and the
  three queries (sessions, saved tabs, project archives) run in one read
  transaction, writing to a private temporary file (`umask 077`, removed on
  exit, as the other remote scripts do). The transaction ends, then the
  file is measured against the budget and only then sent. A slow or stalled
  connection never holds the peer's lock.
- **Schema contract.** One fixed projection, valid for v10 and later:
  - `grdb_migrations` includes `v10-session-core` (every column read
    exists from v10: `generated_title` is not read, `color` is v4,
    `project_state` v7, the rest v1, v9 and v10). Unknown, newer
    migrations and extra columns are accepted: core schema changes are
    additive by rule (AGENTS.md). This differs on purpose from
    `TempleDB(readOnlyPath:)`, which refuses a newer schema; it is not
    reused.
  - Missing required structure (a migration, table or column the projection
    names) is "a form this version can't read", never "too old".
- **Rows selected:** `session_state` with `host = ''` (the peer's own
  sessions; ones it runs elsewhere, this Mac included, are skipped):
  `id, agent, directory, transcript_path, custom_name, title, color,
  archived, last_active_at, last_opened_at`; `open_tabs.session_id`;
  `project_state(path, archived)`.
- **Wire format, one record per row.** Every field is emitted as SQL
  `hex(...)`, and NULL as `-` (`CASE WHEN x IS NULL THEN '-' ELSE hex(x)
  END`), so a NULL and an empty string stay apart: the displayed-title
  chain and Undo's exact comparison both depend on it. Splitting keeps
  empty fields. Fields are separated by a tab, records by
  a newline (`sqlite3 -separator`), so no byte in a title can break framing.
  Each record is decoded on its own in Swift: a field that is not valid
  UTF-8, an unknown agent, a missing folder or a wrong field count skips
  that row and counts it; its neighbours survive. A broken envelope (the
  status line, the section markers, `done`) is a transport failure, a
  different thing from a bad row.
- **Budget**, counted on the bytes sent: the existing 6 MiB response budget.
  Hex doubles each field, so that is about 7,500 sessions at 400 raw bytes.
  Over it: "more sessions than can be read at once", never a truncation.
  Dates are GRDB's text form, UTC.
- Lives in `TempleRemoteHost` (`PeerTemple.swift`): the script, the parser,
  `PeerSnapshot`, `PeerSession`. `TempleUI` reaches it only through
  `Sources/TempleUI/Hosts/RemoteHost.swift` (`ModuleBoundaryTests`).
  Nothing is stored.

## 3. Import from another Temple

Import brings the session in as the other Mac shows it:

- Written: `id`, `host` (the chosen host), `agent`, `joined_via`
  (`imported`), a locator from the peer's `transcript_path` when it has one
  (a hint the engine verifies), and **the peer's name (`custom_name`) and
  colour (`color`)** when it has them. A session never renamed there gets
  its title here the way any joined session does, from its own transcript.
- Not written: `title` (a fact this Temple reads from the transcript, and
  NULL-only, so a copied one would block the real one), `pinned` and
  `archived` (where it sits in this sidebar is decided here), `directory`
  (recorded only by a launch that enters it, or from the transcript).
- **Marks only on a new membership, in the same write.** The name and
  colour are written in the transaction that inserts the row, and only
  when that transaction inserted it. A session that is already a member
  (joined meanwhile from another window or connection, or earlier) keeps
  its own marks, deliberate empty ones included. `join` gains the carried
  marks as an input and returns whether it inserted, the incarnation, and
  the marks it actually wrote; that return is the import's **receipt**.
  Undo is registered only for a receipt that says inserted.
- **Undo Import keeps working.** Today Undo removes an imported row only
  while nobody has touched it, which it checks partly by `custom_name IS
  NULL AND color IS NULL` (`TempleDB.leave`). An import that brings a name
  and colour would fail that check at once. So `leave` takes the name and
  colour the receipt says were written and checks `custom_name IS ? AND
  color IS ?` instead; every other condition of `leave` stays (opened,
  pinned, archived, retitled, kept, a saved tab). Undo still works until
  someone renames or recolours the session here, and then leaves it alone,
  as today. The receipt `(id, host, agent, incarnation, name, colour)`
  rides in the undo step, in memory; nothing new is stored. Redo is a new
  import with a fresh receipt.
- Open on a peer row (section 4) joins as `opened` and carries the name
  and colour by the same rule (only into a row it inserts). There is no
  undo for an open.
- Import triggers the engine's ordinary membership enrichment, which
  locates and reads that one session's transcript on the host, as for any
  remote member. The list reads none; the import does, as every join does.

## 4. The resume handoff

`openSession(TranscriptSummary)` delegates to an existing member, which
cannot resume without a recorded folder, and a summary does not carry a
folder the person chose. Both doors hand an explicit value to
`OpenSessionsModel`:

```swift
struct ResumeRequest {
    let host: HostID
    let agent: Agent
    let id: String
    let locator: TranscriptLocator?   // a hint, verified by the engine
    let title: String                 // the tab's label until the row has one
    let launchDirectory: String       // where this launch starts
    let carried: CarriedMarks?        // name and colour from a peer row
}
```

- A live tab for the same host, agent and id is focused; nothing else
  matches. A restored, inert chip for it is resumed in place (as
  `openSession(Session)` does with `prepareResume`), not duplicated.
- A member with a recorded folder resumes in **its** folder. A member
  without one, or an outside session, launches in `launchDirectory`, a
  launch-only hint persisted only when the launch reports
  `.directoryEstablished`, as today.
- **Nothing launches until the join has succeeded.** The join goes through
  `openedHandler` and its `JoinResult`: `.joined` launches; `.refused` (a
  host or agent conflict) and `.failed` (a database error) launch nothing
  and say why. The existing launch paths check only for a conflict; this
  path checks for success, and the existing paths are fixed to do the same
  in the same change.

## 5. Open a session by id

### Where it is

(As built after the owner's testing; the entry points first designed here, the
launcher's and ⌘N's host rows, were removed.)

- **File ▸ Open Session by ID…**, where the owner looks first. Host: This Mac.
- **History's page**, for This Mac and for each host, and the lines that
  leave a host's page without a list: **Open Session by ID…**, with that
  page's machine chosen.
- **⌘K, by pasting a whole id**: a session Temple has opens; any other opens
  the sheet on This Mac with the id filled in.

Not in the launcher, ⌘N, the sidebar or a project's `+` menu.
Every label here runs the cold read in [copy-review.md](../copy-review.md)
before it is pushed (AGENTS.md).

### The sheet

**Session ID** first, with the hint "Any Claude Code or Codex session. Temple
finds which agent it is and the folder it ran in." Below it **Host** (This Mac
by default, or the page's host), shown only when a host is connected, or
while a host chosen in it has since been removed so This Mac can be chosen
again. One machine is asked at a time; nothing looks on every host at once.
The agent and the folder are found, not asked:

- **Agent** appears only when the lookup finds this id in both Claude's and
  Codex's stores (two sessions, one id): a Claude | Codex choice, then Open.
- **Folder** appears only when the session's transcript records none, with
  the host's recent folders (as the folder sheet). Otherwise the
  transcript's folder is used: Claude resumes a session only from its own
  project folder, so asking would only invite a mismatch.

**Open** runs the check, then hands off:

1. **Already here.** A member with this id on this host that can resume (a
   live tab, or a recorded folder): open it (section 4), no lookup. A
   member on another host: "This session is already in Temple on
   <other host>." with **Open on <other host>**, which opens that member.
   A member that cannot resume yet goes on to step 2 for its folder.
2. **Look it up**, one request for this id on the host's source, answered
   **per agent**:
   - `found(locator, folder?)` only after `read(expecting:)` confirms the
     file is this session (a file name is not identity), keeping the
     engine's candidate order and fallback; the same read returns the
     folder the transcript records;
   - `notFound`: that agent's store roots were present and listed to the
     end with no match;
   - `cannotTell(reason)`: a root missing or unreadable, a listing that
     failed, a file unreadable or changing, an identity mismatch.
   The whole request can instead fail as `transport(line)`.
   Outcome: one agent `found` (whatever the other store said): that
   session, go on. Both `found`: the agent choice appears. Neither found and
   both `notFound`: "No session 3f2a1c… on <host>." Otherwise (`cannotTell`
   on either): what could not be checked, never "no session". `transport`:
   "Temple couldn't reach <host>: <line>." with Test connection.
   This is a new primitive on the source (remote and local), built from the
   locate script's per-root status; the engine's absence rules and remote
   `complete` do not change.
3. **Folder.** The transcript's folder; if it records none, the folder
   field appears and is required. The folder is checked on the host
   (`checkFolder`, as the folder sheet).
4. **Open.** The captured host, id, agent and folder are compared with the
   sheet's fields; an edit since the check means checking again. Then a
   `ResumeRequest` with the verified locator.

The checks run under the remote gate like the folder sheet's: a dismissed
sheet cancels them, and an answer for a sheet or a host configuration that
has gone launches nothing.

## 6. Tests

- `PeerTemple` script under `LocalShellExec`: no file; no `sqlite3`; v9
  (unreadable form); v10; v12; an additive newer schema (an unknown
  migration and an extra column); a required column missing; an unknown
  agent; a row with no folder; a non-UTF-8 title among good rows (the good
  rows survive and the count says one skipped); titles with tabs, newlines
  and quotes; a row on another host; an archived project; a hot journal; a
  lock held past the timeout; a deliberately slow query killed by the
  watchdog, with a concurrent writer that then completes; a client
  cancelled mid-read, after which the writer completes; a result over the
  budget; `custom_name` and `title` differing (the displayed title is
  `custom_name`); NULL and empty strings kept apart through decoding.
- History: the menu absent with no host; This Mac identical to today
  (existing tests); project navigation landing on This Mac; a host page
  merging peer rows and members by `HistoryKey`; a member showing this
  Temple's title; a conflict row; every failure line with members still
  listed; the last good snapshot kept on a failed Refresh; no read for a
  host not chosen (an exec counter); switching pages with Return and Import
  queued; a host edited, removed, or removed and re-added after a snapshot
  installed (snapshot and captured actions dropped); two Refreshes finishing
  out of order; a stale import confirmation and a Redo after the row became
  a member; Import, then the host removed, then Undo (works); Undo, host
  replaced, Redo (refused); the scope labels on a host's page; the bridge
  line on This Mac (shown only for an empty or thin search with a host
  enabled, contacting nothing); a host marked "no Temple" after it said so.
- Import: only the listed columns written; marks written only when the
  join inserted (a concurrent join first: no marks, no Undo); an existing
  member with different marks keeps them; Undo after an import that
  brought a name and colour; Undo refused after a rename here; NULL and
  empty marks compared exactly; Import,
  enrichment failing, then Open from the peer row (launches in the peer's
  folder).
- Handoff: a member's folder wins; an outside session records its folder
  only on `.directoryEstablished`; a join that is refused or fails launches
  nothing (and the same for the existing launch paths); an inert chip
  resumed in place.
- Open by id: every branch and the precedence of section 5 with stub
  sources and launchers; a missing root is `cannotTell`, never `notFound`; a
  name match whose identity read fails is not `found`; chosen agent found
  while the other store is unreadable; both found (the agent choice
  appears); a transcript with no folder (the folder field appears); a
  member on another host (Open on it); an edit during the check; ⌘K
  offering the entry only for a whole id; a row with "In a tab on <host>"
  saying so once in the launch header.
- Linux acceptance is unaffected (no Temple there: the no-Temple line). One
  manual acceptance between two Macs before release, since no Mac has been
  an acceptance host for remote.

## Changes

From revision 1 (astra round 1): peer rows are a third History origin; a
`ResumeRequest` handoff; a lookup that says "not found" only after a
complete, verified search; classification by `HistoryKey` with conflicts,
rechecked at action time; reads gated on the host and the page; one
materialized snapshot; an explicit schema contract; failures never hide
members; marks worded as what they are; missing `sqlite3`, an unreadable
form and an oversized result are their own answers.

From revision 2:
- Owner: Import brings the peer's name and colour, and Undo Import compares
  against what the import wrote. The menu is **This Mac** / each host by name (owner: "This Temple" read
  as confusing); This Mac contacts no host, and the earlier "This Mac"
  narrowing to host "" is dropped. A host's page says whose list it is in
  its header line ("Sessions in Temple on mac-b · read 3 min ago"). Open by id lives in ⌘K (paste an id), ⌘N and the launcher's host
  rows, History's header and the no-Temple line; the sheet has a host
  field.
- Astra round 2: snapshots and captured actions bound to the host
  configuration, plus read ids (1); an incomplete member opens through the
  peer's folder, and Open by id short-circuits only for a member that can
  resume (2); a host-side watchdog under the writer's busy timeout (3);
  lookup answered per agent with a stated precedence (4); launch only after
  a successful join, fixed in the existing paths too (5); per-record,
  hex-field wire format (6); one fixed v10 projection, "can't read" instead
  of "too old" (7); the displayed title is `custom_name`, else `title` (8).

From revision 3:
- Astra round 3: carried marks written only into a row the join inserts,
  in the same transaction, with a receipt; Undo survives a host edit or
  removal, Redo does not; NULL encoded as `-`, apart from an empty string.
- Fable: a bridge line on This Mac ("Not here? Look on mac-b"); scope
  labels on a host's page relative to this Mac (All · On this Mac ·
  Archived · Only on mac-b); one dated phrasing ("Sessions on mac-b · from
  its Temple, read 3 min ago"); Open by id's answers lead somewhere (Open
  on <other host>; both agents found offers the choice) instead of
  stopping; the sheet asks only for host and id, agent and folder appear
  when the lookup cannot answer them (owner confirmed); Open by
  id dropped from This Mac's History header and added to every line that
  leaves a host's page without a list; hosts that said "no Temple" are
  muted in the menu; "In a tab on <host>" in the status column and said
  once in the launch header; the incompatible-database line suggests
  updating; the third-host limit stated.

From owner testing (after the build):
- Open by id's entry points are File ▸ **Open Session by ID…** and the same
  link on History's page for This Mac and each host (plus `⌘K` paste); the
  launcher and `⌘N` rows are removed. **Host** defaults to This Mac, a
  host's page presets that host, and the field is hidden with no host
  connected. Searching every host at once was proposed and rejected: one
  machine is asked at a time. The sheet's hint says it opens any Claude Code
  or Codex session and finds the agent and folder itself.
