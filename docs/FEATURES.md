# Temple — Product

What Temple is, what it does today, and what remains to build. Architectural
rationale lives in [DECISIONS.md](./DECISIONS.md); session-store details live in
[SESSION-FORMATS.md](./SESSION-FORMATS.md).

## What Temple is

> A session manager for your CLI coding agents. Every Claude Code or Codex
> session is a resumable piece of work, grouped by project and searchable. Open
> one and Temple resumes it in a real terminal tab. One home for everything you
> are working on across agents and repositories.

Temple has three primitives:

- **Agent** — Claude Code, Codex, or another CLI coding agent.
- **Project** — the working directory in which an agent runs.
- **Session** — one resumable agent run, titled from its first human prompt when
  no CLI summary is available.

Temple is a native macOS session manager. It reads the agents' own on-disk
session stores, presents them as a project-grouped index, and hosts each open
agent in an embedded libghostty terminal. The terminal remains the source of
truth; Temple supplies the index, navigation, lifecycle, and attention layer.

### Explicit non-goals

- Temple is not a general terminal emulator intended to replace Ghostty or
  iTerm. It hosts terminals for agent sessions.
- Temple is not a chat renderer. It does not turn terminal output into message
  bubbles or add a prompt composer.
- Temple is not a git or filesystem tool. It never runs git, creates branches or
  worktrees, or edits project files; those operations belong to the agent in its
  terminal ([ADR-012](./DECISIONS.md#adr-012--scope-boundary-agent-sessions-only--not-git-not-the-filesystem)).
- Temple has no cloud account, sync, or multi-machine service. It is local-first.
  A session on another machine runs over your own ssh, from this Mac to that
  host and nothing in between ([Sessions on a host](#sessions-on-a-host)).
- Windows is out of scope while libghostty supports macOS and Linux only
  ([ADR-004](./DECISIONS.md#adr-004--platforms-macos-first-linux-later-not-windows)).

## Sidebar & session index

The sidebar is the browse index; it is not the set of running processes. Temple
discovers Claude Code sessions under `~/.claude` and Codex sessions under
`~/.codex`, reads their true working directories, and groups them by project.
Session titles prefer the title an agent gives itself as the work moves on;
Temple records that title, because the CLIs write it nowhere on disk and it would
otherwise be lost when the session closes. A session with no such title yet falls
back to the first human prompt
([ADR-007](./DECISIONS.md#adr-007--session-index-is-built-from-the-clis-on-disk-stores),
[ADR-011](./DECISIONS.md#adr-011--title-source-first-human-prompt-cli-summaries-unreliable)).

Temple browses only **its own sessions**: every session it has started,
opened in a tab, or that you have pinned, renamed, colored or archived. A
project appears when it holds one. Sessions run anywhere else are on no
surface but one: not the sidebar, `⌘K`, the launcher, or the `⌘N` picker,
and Temple does not watch them while it runs (ADR-027). The
History tab (`⌘Y`) reads the whole disk when it is shown, lists them beside
Temple's own, and is the door in: Import brings one in without running it, and
opening one makes it a Temple session for good. Temple records how
each session joined (started here, opened, or imported), for features that
will need to know. On upgrade, the sidebar starts with the sessions Temple had
already pinned, renamed, colored, archived or seen retitle in a tab, plus the
open tabs; any other session returns the next time it is opened
([ADR-023](./DECISIONS.md#adr-023--temple-browses-its-own-sessions-by-default)).

- Projects and sessions are ordered by recency at launch, then frozen for that
  app run so activity cannot move a row under the pointer. Newly discovered
  entries prepend without reshuffling existing entries.
- Each project is a section: an uppercase, letter-spaced label trailed by a
  hairline rule — the launcher's own section language — led by a chevron that
  folds the group. A folded group hides its rows inside its own box; nothing
  crosses the header. The `+` that starts a session in that project appears on
  hover at the rule's end. Session rows sit under the label at 32pt: agent
  badge, title, and the activity dot when the session has an open tab. Open
  sessions read at full strength; the browsable history behind them steps
  back a tone, and its badges are faded until hovered.
- Projects reorder by drag: the header is the handle. A label set like the
  header follows the pointer and the whole group in hand dims. Dropping on another
  project's header lands above it; dropping anywhere in its body lands below it,
  and an insertion line shows where. A collapsed project has no body, so the
  lower half of its header means below it. The order persists. A manual order
  wins over recency; projects nobody has placed stay above the placed ones, so a
  new project still surfaces at the top rather than under the eight-project cap.
- The initial view shows up to eight projects and six sessions per project.
  A row set like a project header, **N MORE PROJECTS**, stands where the
  rest of the projects would be; clicking it reveals them in place, and
  **SHOW FEWER PROJECTS** at the end of the list folds them back. Within a
  project, **Show N more** names how many are folded away and reveals ten at
  a time, and **Show fewer** folds the list back.
- Filesystem watching, an index cache, and retries for files caught mid-write
  keep the index current without blocking launch.
- Agent badges distinguish Claude Code and Codex. Ambient and automation noise
  is hidden by the default noise filter. Subagent transcripts of either CLI are
  never listed: they belong to the session that spawned them
  ([ADR-024](./DECISIONS.md#adr-024--subagent-transcripts-are-not-sessions)).
- Sessions can be renamed, pinned, and color-marked. Pinned sessions appear in a
  dedicated section and custom names become their displayed and searchable
  titles. A color mark set on a session's tab shows in the sidebar as a slim
  leading capsule, and as a wash over the session's row in the `⌘K` palette,
  the `⌃⇥` tab switcher, and History.
- A session-row context menu can open or focus the session, copy its resume
  command or ID, reveal its source file in Finder, show it in History, rename
  it, pin or unpin it, archive it, and close its tab when open. A session with
  an open tab cannot be archived until the tab is closed. A project header's
  menu reveals the folder in Finder, copies its path, shows the project in
  History (every session of it, archived ones one segment away), and archives
  the project. Archiving from either menu is
  one click and one `⌘Z` (Edit ▸ Undo Archive Session / Project) to take back; undo
  also returns the pin the archive dropped.
- Archiving hides a session everywhere the index is browsed; archiving a project
  from its header context menu hides the project and every session in it.
  Archiving a session clears its pin; archiving a project only hides the pins
  inside it, and they return with the project. Nothing archived appears in the
  sidebar; History is the way back: its **Archived** scope (`⌘⇧Y`) lists every
  archived session, and Restore brings one back
  ([ADR-031](./DECISIONS.md#adr-031--archive-is-a-scope-of-history)).
- Temple archives a session nobody can resume any more: its transcript is
  gone (the CLI removed it, as Claude Code's retention cleanup does) or the
  folder it ran in no longer exists. Only on proof (a completed listing of the
  agent's store, or the folder's own host saying it is missing; a drive that is
  not plugged in proves nothing) and only for a session that is not pinned, has
  no tab open or restored, and has seen no activity for seven days. The foot of
  the sidebar says so once, in two rows below the list: "3 sessions
  archived: no transcript on disk" (or "folder gone", or "transcript or
  folder gone") with a dismiss, then **View** (History's Archived scope,
  narrowed by an "Archived just now" chip to exactly those sessions) and
  **Undo**; it stays until Undo, the dismiss or the end of the run.
  It is not on `⌘Z`: the user did not do it. A session brought back by Undo or
  Restore is not archived again until it has seen new activity.
- A session on another machine ([Sessions on a host](#sessions-on-a-host))
  belongs to the project of its folder on that host. That project's heading
  is one line, like a local one, with the host after the name:
  `› TEMPLE-DEMO  @masterblaster-mentes ───`, the host lowercase as it is
  spelled and quieter than the name, giving way before the name on a narrow sidebar;
  hover it for `host:/path`. A session's missing title, folder or date fills from its
  transcript on the host, looked up by its id when Temple starts and when you
  open it. Temple never dims, tags or archives a session on a host because
  its transcript seems to be gone: over ssh it cannot prove that, so only
  you archive one. History lists a host's sessions under In Temple and
  nothing more: Temple does not list a host's other sessions and cannot
  import them. A session Temple is tracking on a host adds **Stop on
  <host>** to its context menu.
- When sessions on a host were left running (see
  [Sessions on a host](#sessions-on-a-host)), the foot of the sidebar says so
  once when that host next answers, "2 sessions left running on <host>",
  with **Show** (Sessions on <host>) and a dismiss.
- The sidebar's actions live in the title bar, at the trailing edge of its
  section: search and the sidebar toggle — Temple's own button, in place of
  the system one, so the two behave as one group. When
  the sidebar is hidden they slide in beside the traffic lights and the
  working surface expands to the window edge; the tab strip measures where
  they end and starts after them. The macOS spring-loading that pops a
  collapsed sidebar open when a drag hovers its edge is turned off.
- The footer is one line: the subscription meters beside the settings gear,
  both on the right. It is the edge the list stops at.

### Select versus open

Opening a session starts a real agent process, so browsing and opening are
separate actions. Arrow keys move the sidebar highlight without spawning
anything. Enter, double-click, or click opens the highlighted session; if it is
already open, Temple focuses its existing tab instead of creating a duplicate.
The sidebar highlight follows the active tab, and that tab's session as it
changes: a new Codex session highlights no row until Temple learns its ID, then
its own; Settings and History leave the highlight where it was.

## Terminal tabs & the working surface

The sidebar and tab bar form a two-part navigation model:

- The sidebar contains discovered sessions, whether open or closed.
- A tab represents an open terminal. The horizontal tab bar shows only the
  active project's open terminals, plus the project-agnostic Settings tab.
- Opening a session in another project switches the tab-bar context without
  stopping that project's off-screen processes
  ([ADR-010](./DECISIONS.md#adr-010--temple-owns-the-agent-processes-graceful-lifecycle)).
- A project switcher names the project the tabs belong to and lists every project
  with sessions open, each with its containing folder, its session count, and a
  dot when an agent there is running or waiting. Choosing one returns to the
  session last used in it.
- A project Temple has never seen is opened by choosing its folder: `⌘O`
  (File → Open Project Folder…), the switcher, the `⌘N` picker, or the home
  page. Not from the title bar: a folder button there sat one slip from the
  sidebar toggle and was hit by mistake. The switcher's
  control is a folder, never the `+` that starts a session inside a project you
  already have.
- `⌘P` is the keyboard route between projects, shaped like the macOS app switcher
  rather than like `⌘K`: hold `⌘` and tap `P` to walk the projects you have work
  open in, most recently used first, and release `⌘` to land — so one tap returns
  you to the project you were just in. The project you are leaving is marked
  *current*. Landing on a project returns you to the session you last used there.
  `⌘⇧[` / `⌘⇧]` cycle without showing the switcher. Sessions get a search palette
  (`⌘K`); projects get a switcher, because you hold a handful of them in your head
  and search a hundred sessions.
- `⌃⇥` is the same gesture one level down: hold `⌃` and tap `⇥` to walk the open
  tabs **most recently visited first**, release `⌃` to land — so one tap bounces
  to the tab you were just on. A fresh tap of `⌃⇧⇥` is the same bounce (not a
  jump to the oldest tab), so alternating the two chords ping-pongs between two
  tabs; `⇧` steers direction only mid-walk, while `⌃` holds the switcher open.
  From the home page the bounce returns to the tab you left. The trail spans
  projects, and each row names the project it would take you to; landing
  elsewhere switches the strip. The tab you are leaving is marked *current*, and
  a dot flags tabs whose agent is running or waiting. `⌘1`–`⌘9` remain the
  positional route within the active project.

The active libghostty terminal fills the main content area. Temple launches the
agent directly in the session's working directory and sends keyboard input to
the terminal; there is no bottom composer and no intervening shell.

- `⌘F` opens a find bar over the terminal's top-right corner; libghostty
  matches and highlights in the scrollback and the bar counts them ("3/12"). Return
  / `⌘G` walks forward, ⇧Return / `⌘⇧G` back; Esc closes it and returns the
  keyboard to the terminal. The search stays with its tab across tab switches.
- Files and images dropped onto a terminal are typed into it as shell-escaped
  paths, which is how an agent is handed a screenshot or a log. An image dragged
  from a browser or Preview carries no file, so Temple writes one and passes that.
- Each session chip shows its agent, title, activity dot, and close control.
  Double-clicking a chip renames the session in place: Enter commits, Esc
  cancels, and an emptied field reverts to the automatic title.
- A chip can carry one of seven fixed color marks (context menu → Color),
  Warp-style: the chip's fill and hairline take the tint, as does its drag
  preview; the sidebar row carries it as a leading capsule and the palette,
  switcher and history rows as a wash. Marks are keyed to the session, so they
  survive closing the tab and relaunching Temple.
- The trailing `+` menu starts a new Claude or Codex session in the active
  project. `⌘T` takes the default-agent fast path.
- Tabs are drag-reorderable within their project. Temple persists each
  project's open-tab set and order.
- Open tabs restore lazily after relaunch as inert chips. No agent process starts
  until its chip is activated, and Temple restores the last-active project
  context. The one exception is the tab that was on screen when you quit: it is
  reactivated and its agent resumed, so relaunching puts you back where you were
  rather than on the launcher. Quit from the launcher (`⌘⇧H`) and you come back
  to the launcher.
- Closing the window quits Temple. The window is the app, so the red button runs
  the same graceful shutdown as `⌘Q` — every agent drained, the tab set saved —
  instead of leaving a windowless process with agents running out of sight. If an
  agent is mid-task, Temple asks before quitting.
- The Settings chip is a singleton, sits inline with session chips, and can be
  reordered like them.
- Tab context menus rename the session, set its color mark, copy the resume
  command or session ID, and close the tab.
- `⌘⇧T` reopens the most recently user-closed tab, browser-style, resuming its
  session. Tabs whose agent exited on its own are not restacked — reopening is
  an undo for closes you performed.

## Session lifecycle

A live session tab and its agent process have the same lifetime. A session tab
never hosts a bare shell: a new tab starts a fresh Claude or Codex process, and
an existing-session tab starts that agent's resume command. Lazy restored chips
have not started yet, retained launch-failure chips have already exited, and the
Settings tab is the one agent-less exception.

- Closing a live tab gracefully ends its process. Temple asks the CLI to exit,
  terminates and reaps it, and force-kills only after a bounded timeout.
- A spawned shell reports `TERM_PROGRAM=Temple` and `TERM_PROGRAM_VERSION`,
  not the terminal library underneath, so tools that ask which terminal they
  are in name the right app. The Ghostty resource variables and
  `TERM=xterm-ghostty` stay: shell integration and the terminfo depend on them.
- When a tab goes, its terminal surface is freed at a known point, the
  runtime's message queue is drained right after, and no new surface is
  created until that drain has finished — so, for a drain that runs to
  completion, a title queued by a closing terminal does not land on the tab
  spawned next
  ([ADR-021](./DECISIONS.md#adr-021--a-freed-surface-does-not-hand-its-messages-to-its-successor)).
- When a process exits on its own, Temple normally closes its tab. The session
  persists on disk and remains in the sidebar.
- Closing a tab asks for confirmation only while its agent is running. Return
  confirms; Esc cancels. Idle, attention, exited, inert, and Settings tabs close
  immediately. (A tab on a host has one more rule; see
  [Sessions on a host](#sessions-on-a-host).)
- A non-user-initiated exit within roughly five seconds of launch keeps the tab
  visible with a red exited dot so the failure output can be read.
- Quitting Temple gracefully shuts down all live agent processes on this Mac;
  Temple does not detach or orphan them. Agents on another machine are the
  exception: they all keep running ([Sessions on a host](#sessions-on-a-host)).
- `Ctrl+D` passes through unchanged. If the agent exits on EOF, Temple handles it
  as an ordinary process exit.

New sessions are empty agent sessions, ready for terminal input. Temple can
start one from the launcher, a project-header `+` menu, the tab-bar `+` menu, or
`⌘T`. Both `+` menus name only the choice they offer — the agent, under a **New
session** heading, each row carrying that agent's own mark. The default agent
leads and shows `⌘T` where that is true (the active project only). An agent
Temple has proof it cannot launch is disabled there and says which kind of
proof; there is no tick for one that looks fine. **Choose folder…** starts in a
directory that is not yet indexed. Claude
sessions receive a Temple-generated session ID; Codex creates its own ID, which
Temple adopts when the new rollout file appears
([ADR-008](./DECISIONS.md#adr-008--session-identity-id--cli-id-asymmetric-minting)).
A Codex session's title, until Codex or you give it one, is its first typed
prompt, including for sessions Codex's shared app server writes; the
instructions block Codex injects for a folder's `AGENTS.md` is never taken
for a prompt.

### Sessions on a host

Temple runs Claude Code and Codex on another machine you reach with ssh, in a
tab that works like a local one
([ADR-036](./DECISIONS.md#adr-036--sessions-on-another-machine-through-the-users-own-ssh)).
Hosts are set up in Settings ▸ Hosts. Until one is, nothing here appears
anywhere else in Temple: no host rows in `⌘N` or the launcher, no shortcuts
note, no sidebar notices; local tabs behave exactly as they would without
it. What follows appears for an enabled host only.

- **Starting one.** `⌘N` lists **Folder on <host>…** under **Choose
  folder…** for each host, the launcher has one row per host naming the
  agent it starts ("New Claude Code session on <host>…", the default
  agent), and a host project's `+` and `⌘T` start there (Codex on a host:
  the `+` menu or `⌘N`). The folder sheet takes a path on the host (`~/…`
  works), checks it there and shows where it resolved; under the field,
  "Recent folders on this host. Click one to start there." lists the host's
  earlier folders. When the host does not answer, it offers **Test
  connection** (the host's own test, over the folder sheet; closing it comes
  back with the path as typed, and a test that passed checks the folder
  again, as advice: nothing starts until **Start**) and **Start without
  checking**. A host whose last test proved tmux
  missing or older than 3.2 is left out of the launcher and `⌘N`, greyed in
  the `+` menu, and the folder sheet says why and won't start, all with the
  same line. The project's heading shows in the sidebar at once, from the
  folder you typed, and moves to the folder the session reports it entered;
  only that one is recorded.
- **It keeps running.** The agent runs inside a hidden tmux server of
  Temple's own on the host (`tmux -L temple`, tmux 3.2 or newer), so it
  survives a dropped connection, a sleeping Mac and a Temple quit while it
  works. A tab that loses its connection says "Disconnected from <host>.
  The session is still running there." with **Reconnect**, which attaches to
  the same agent.
- **Working and waiting.** An agent on a host is working while it is busy
  with a task and waiting otherwise; only a working one is ever asked about.
- **Closing a tab** means what it means locally: closing a tab whose agent
  is waiting for input stops it, at once, and opening the session later
  resumes it from its transcript. A working one asks "Claude Code is working
  on <host>." ("Detach leaves it running on <host>; Stop ends it.") with
  **Detach** (the default: it keeps working, and you can open it again),
  **Stop** and **Cancel**; a tab reattached a moment ago, before anything
  has said whether its agent works, asks "Claude Code may still be working
  on <host>." instead. The tab's ×, its menu, the sidebar row's menu and
  File say this where you act: on a tab on a host the menus read **Detach
  from <host> (keeps running)** directly above **Close tab (stops the agent
  if it is waiting for input)** (File: **Detach from <host> (keeps
  running)** above **Close Tab**), and the × says what closing does there.
  Detach closes the tab and leaves the agent running, working or waiting.
  On a host, a tab whose agent has just started (a new session or a resume)
  and has received nothing from you since counts as waiting once its title
  has been quiet for a few seconds, without waiting for the settle timer;
  any key, paste, or click it takes in since means the usual rule, so `⌘W`
  soon after an answer still asks. Tabs on this Mac keep the settle timer's
  reading.
- **Left running.** When the host does not answer as you close a tab, or
  another terminal is attached to the session, Temple leaves it running and
  says so once, in orange, naming the session ("“<title>” wasn't stopped:
  <host> didn't answer when you closed its tab. It may still be running.").
  It never stops anything later on its own. **Running sessions on <host>…**
  (in Settings ▸ Hosts, in a host project heading's context menu, on a tab
  whose stop failed, and on every such notice) lists every session Temple
  started on that host and still tracks, with its state (**Running in a
  tab** when a tab in this Temple is connected to it, **Running** when it
  runs without one, even if a terminal or another Temple is attached, or
  **Status unknown**; the tmux session's name is its tooltip). Each row has
  **Open** (a tab attached to it, as its sidebar row opens it; one with no
  row opens by its run, and one with no folder on record says what to do
  instead) or, when it
  is open in a tab here, **Show tab**, and **Stop** (its sidebar row stays,
  so you can resume it later); a row that was left running says why in
  orange and has **Dismiss**, which clears that note (it keeps running
  either way). Stopping a working agent, here or with a row's **Stop on
  <host>**, asks first ("Claude Code is working on <host>. Stop it?"); one
  waiting for input stops at once. A row whose agent still runs on its host
  can't be archived until it is stopped ("Stop it on <host> to archive").
  Temple never lists or stops a session it did not start, and never touches
  your own tmux sessions.
- **Quitting.** Temple stops no agent on a host when it quits, working or
  waiting: each tab's connection is detached and the agent keeps running
  there. When a host has a connected tab, the quit prompt says "An agent on
  this Mac is still working." about local working agents and adds
  "Sessions on <host> keep running; their tabs reconnect when you open them
  next launch." (with no host, it reads as it always did). After relaunch
  each comes back as a tab that attaches when opened; a host that answers
  says once, in the sidebar, how many sessions from before the quit it found
  still running there and not open in a tab, with **Running sessions on
  <host>…**; that or × marks them seen.
- **When Temple can't tell.** If Temple cannot tell whether a session is
  still running on its host, opening it only tries to attach. **Resume
  anyway…** starts it again from its transcript; the sheet says that the
  original, if it is running, keeps running, and gives the tmux command that
  stops it on the host. A session stopped before it had a conversation offers
  **Start a new session here**; one whose conversation Temple couldn't check
  offers **Try to resume** too. Either removes it with a link that says
  which: **Remove from Temple**, or **Archive session** when it is named,
  pinned, colored or has a transcript (restore it from History). Nothing is
  stopped by it.
- **Removing a host.** **Remove** (either kind of host) asks the host what
  Temple started there first. With sessions still running, it asks: "2
  sessions are still running on <host>." with **Remove, leave them
  running** (the default; Temple can't list or stop them until the host is
  added again), **Stop them and remove** (a stop that fails keeps the host
  and says why) and **Cancel**. With none, or no answer, the host is removed
  at once. `~/.ssh/config` is never changed. Editing a host added by address
  disconnects its open tabs (their agents keep running; Reconnect in each).
  A connected tab counts as running for that question even when the host's
  probe can't tell. A tab still open for a host just removed says so at
  once, with **Open Hosts in Settings**, and says what brings it back for
  the state it is in: a tab that was connected or connecting is left
  disconnected and gets Reconnect once the host is added again; a tab not
  yet opened opens once the host is back, when it is next shown; a tab already showing its own question
  (a stopped or ended session) only says to add the host again. A tab on a
  host Temple doesn't have says so too.
- **New Codex sessions.** Codex picks its own session ID, so a new Codex
  session on a host reads "New Codex session" until Temple learns the ID;
  it reopens and restores like any tab meanwhile. Temple identifies it on
  its own only when the Codex process it started holds the session's file
  open. By default Codex's shared app server writes that file, so Temple
  looks for sessions begun in the folder since the tab opened. When exactly one
  matches, you have typed into the tab, and Temple has not asked about it
  (nor have you declined a candidate for it, even before a relaunch), and
  no other new Codex session Temple started in that folder is still
  unidentified, Temple says yes on its own, exactly as you would, and the
  tab says so in one line: "Linked this tab to “<first prompt>”, the only
  Codex session started in this folder since the tab opened.", with **Not
  this one**, which undoes the link once its record is written (a write that
  fails changes nothing and says so): the row the link made is archived
  (restore it from History) and the tab is detached, its agent still
  running. A notice says "Unlinked. The agent keeps running on <host>. Its
  tab is under Running sessions on <host>; open it to pick the right
  session." with **Open**, which reopens it asking without that candidate. With two or more, or once it has asked, the tab
  says "Codex picks its own session id, so Temple can't tell which session
  this tab is." and asks: "Is this the session?" with the first prompt, the
  folder's full path and when it started (relative to the tab, "4 s after
  this tab opened", when that is known), earliest first, and **Yes, that's
  it** or **Not this one**; with nothing left to ask about, it says "No
  other Codex session has started in this folder since the tab opened."
  (the tab keeps working; it gets a sidebar row once Temple finds its
  session; when the one it found is another tab's, it says Temple couldn't
  tell), with **Try again**, which shows that it is checking and then "Checked again: still
  none." when it finds nothing new, and never offers a declined candidate
  again. With
  `--no-daemon` in Codex's arguments, Temple identifies the session on its
  own; the Hosts card says which, from the arguments.
  A Codex session that ended before Temple learned its ID asks in one
  sentence, "Codex ended on <host> before Temple learned which session this
  was. Is it “<first prompt>” (<time>)?", with **Yes, that's it**, **Not
  this one** and **Start a new session here** after it and **Remove from
  Temple** at the edge (in a narrow window the answers sit on a row under
  the sentence); where its terminal was, one line says "Codex's last screen
  on <host> isn't kept after it ends." Answering yes closes its tab, as a
  local exit does, and the selection follows the tab that becomes active.
  The session's row sits at the top of its project, titled with that first
  prompt until Codex's own title arrives; opening it resumes it.
- **Banners.** A tab's banner puts its answers (Reconnect, Resume anyway…,
  Start a new session here, Yes and No) right after its sentence as small
  buttons; only a dismiss-type link (Remove from Temple, Archive session,
  Cancel connecting) sits at the trailing edge.
- **Scrolling and find.** tmux keeps a session's history. The wheel scrolls
  the terminal's scrollback, and the first key you type returns to the
  prompt (the shortcuts panel says so, with the close and Detach rule). A drag selects and
  copies (to the Mac clipboard with tmux 3.3 or newer); `⇧`-drag selects in
  Temple's own terminal. `⌘F` searches what the tab has shown since it
  connected, and its bar says so.
- **What stays on this Mac.** The usage meter, Reveal in Finder and
  `temple sessions new`. The command line lists, opens and closes sessions on
  hosts; `temple sessions close` refuses one that is working, and `--force`
  detaches it rather than stopping it.

## Launcher / home page

`⌘⇧H` shows the home page without closing existing tabs. Its masthead presents
Temple and the tagline “Where agents answer the call.”

The **Get Started** section provides New Claude session, New Codex session, New
session in folder…, Command palette, Keyboard shortcuts, and Settings. An agent
row uses the last-used project, or asks for a folder if none exists; the folder
row uses the default agent.

**Recent Projects** shows the sidebar's first five projects — the same manual
order if one has been set (the heading then reads **Projects**), launch-frozen
recency otherwise — with relative activity time on hover. **Get started** also
carries **Archived sessions** (`⌘⇧Y`), History in its Archived scope: the
sidebar lists nothing archived, so this is a visible way back, and it is always
there. Choosing a project starts a brand-new
session there with the default agent; it does not reopen an existing session.
The home page is the general creation surface—there is no new-session modal or
prompt composer.

## Command palette, history & search

- Sidebar search filters session titles in place. The magnifier in the
  sidebar's title bar unfolds the field under the band and focuses it, revealing
  the sidebar first if it was hidden; the field folds away when it is empty and
  loses focus, on Esc, or from its ✕. It has no shortcut (`⌘F` is
  find-in-terminal).
- `⌘K` opens a top-anchored command palette. With an empty query it is a
  switcher over the **open** sessions only, most recent activity first (live
  recency, unlike the launch-frozen sidebar). `⌘K` jumps; `⌘Y` browses.
- Typing searches every Temple session and weights open matches above closed
  ones. Search matches the *displayed* title — a rename or the agent's own
  title — as well as the original first-prompt title, whichever scores better.
  Choosing a result opens or focuses it and switches project context as needed.
  Any typed query ends with one more row, **Search history for "…"** (the only
  row when nothing matches; `↓` past the last result reaches it), which opens
  the History tab already searching for it: archived sessions and ones from
  other terminals are never in `⌘K`, but they are in History.

### History tab (`⌘Y`)

A tab, not a panel: a singleton utility tab beside Settings, opened or focused
by `⌘Y` or View ▸ Session History. A command that names a place goes there:
pressed while History is the active tab, `⌘Y` stays on it (pressed while ⌘K
is open over History, it only puts the panel away). `⌃⇥`, or Esc once the
search and selection are clear, goes back to the tab you came from. It lists **every session
Temple or the disk knows about**, one status per row — Temple's (archived ones
included) and everyone else's — and is the one door through which the others
join and archived ones come back
([ADR-028](./DECISIONS.md#adr-028--history-is-a-tab-over-the-whole-disk-and-the-one-way-in),
[ADR-031](./DECISIONS.md#adr-031--archive-is-a-scope-of-history)).

- **A snapshot, read on demand.** The page reads both stores when it is shown
  (opening it, or switching back to it) and on Refresh (`⌘R`, View ▸ Refresh
  History). It is never watched. Temple's own rows, archived ones included,
  come from its database and are on the page before any file is read; disk
  rows stream in newest first under a "Reading sessions on disk… 1,240 of
  3,810" line. The header says what is in the box ("3,812 sessions · 164 in
  Temple · 173 archived") and when it was taken ("Updated 2 min ago · Refresh"). Temple's rows
  are its database rows (ADR-029), so their titles are the ones the sidebar
  shows; a transcript only fills what a row does not state. Closing the tab
  forgets its search, filters and selection but keeps the rows: reopening
  shows them at once and refreshes underneath. The list is prepared off the
  main thread, so a disk of ten thousand sessions streams in and searches
  without stalling the window. Noise (a folder that is gone, `/`, Codex
  exec/SDK runs) stays hidden. A store that cannot be read is named in a
  banner with its error as thrown, and the other store's sessions still show,
  as do the rows it showed before: only a store that was listed completely
  can say a session is gone. A read parses only transcripts that changed
  since Temple last read them, across relaunches too (ADR-032).
- **Rows.** One line per session, grouped under sticky Today / Yesterday /
  date headers: time, agent badge, displayed title, a condition tag, the
  activity dot when a tab is open, project and git branch, and a status
  column. The status column holds the row's relationship or its verb: Temple's
  rows in play read at full strength and end in the gate mark (its tooltip
  says how and when it joined); archived rows step back a tone and end in a
  quiet **Restore**, whose tooltip says who archived it and why ("You archived
  it on Oct 2.", "No transcript on disk carries this session, so Temple
  archived it…", "Its project raven is archived…"); outside rows step back
  and end in **Import**. Conditions are a tag after the title, for any of
  Temple's rows: **No transcript** or **No folder**. The last message, model,
  message count and file path are in the tooltip.
- **Search and filters** narrow the page in place and keep the day grouping:
  search matches the displayed and original titles, project, branch, the last
  message, and a session-id prefix. A segmented **All / In Temple / Archived
  / Not in Temple** control and agent and project popups (counts over every
  row) compose with it; "Showing 47 of 3,810" appears while anything narrows.
  The three narrow scopes partition All: In Temple is what the sidebar and
  `⌘K` show, Archived is in Temple and put away. The project popup on an
  archived project adds "raven is archived · **Restore project**". Any change
  clears the selection and puts it on the first row. Filters belong to the
  tab and reset when it closes; nothing is persisted. In a pane under
  1000 pt wide the search field takes a row of its own, with the scope and
  filters under it; under 692 pt the agent and project menus become one
  **Filter** menu, labelled with what is filtered. A row's Restore or Import
  column always shows; its project column narrows, then (under 600 pt)
  hides.
- **Selection** is the native vocabulary: click, `⌘`-click, `⇧`-click, arrows
  (`⇧` extends, `⌥` jumps a day, `⌘` to the ends), `⌘A` for everything in the
  current view. Hover is a separate fill and never moves the selection. On
  open the search field has focus and the first row is selected. While the
  search field has focus, every key that edits or selects its text is the
  field's (`⌘A` selects the typed text, `⇧` with an arrow selects text); a
  click on a row, or Tab, gives the list the keyboard, and then `⌘A`, `⌘C`,
  `⌘⌫` and `⇧`-arrows act on rows.
- **Return or a double-click opens** the selected session — an outside one
  joins as opened, like any resume, and an archived one is restored on the
  way. An archived row that cannot resume (no transcript, folder or agent) is
  restored instead, and opens nothing. With two or more selected, Return opens
  nothing (a tab is a process), but when every selected row is archived it
  restores them all.
- **Restore** brings back one session: one in an archived project comes back
  on its own, and the rest of the project stays archived. **Restore project**
  (the row's context menu, or the line under the toolbar) brings back the
  project with every session in it you have not archived yourself. A restore
  is one `⌘Z` (Edit ▸ Undo Restore Session / Sessions / Project), and undo puts
  each row back exactly as it was: a session Temple archived stays Temple's.
  The bar says "7 sessions restored · Undo".
- **The selection bar** appears with two or more rows: "7 selected · all
  archived" with **Restore 7**, "12 selected · 7 archived" with **Restore 7**,
  **Archive N** when every selected row can be archived (also `⌘⌫`), and
  **Import N…** for the rows outside Temple.
- **Import** — a row's Import, its context menu, `⌘I`, or the selection bar
  ("12 selected · 3 already in Temple · Import 9…") — asks first, naming each
  session by its displayed title and where it will appear (the sidebar, or
  History under Archived for a project that is archived), and saying nothing
  runs and no file on disk changes. Imported
  rows join as *imported*, appear in the sidebar at once, and read "Imported"
  for a moment; you stay on History, and the "9 sessions imported · Undo" line
  stays even when the import empties the view (Not in Temple). `⌘Z` (Edit ▸
  Undo Import, or Undo on the bar) takes the import back, row by row, only
  while a row is still untouched — a session renamed, pinned, colored,
  archived, retitled by its agent, or opened since (even if its tab has
  closed again) stays in Temple, and so does one running in a tab; the line
  says which reason kept which. An undone session leaves Temple's rows, and the
  sidebar, at once. A failed write is reported with its error and titles; the rest stay
  imported.
- **Context menu:** Open/Focus, Archive session, Import into Temple…, Copy
  resume command, Copy session ID, Reveal session file in Finder, Show in
  sidebar (Temple rows: lights the row and scrolls the rail to it, unless it is
  folded away in a collapsed project or past a Show more), Show only *project*.
  On an archived row: Open, Restore, Restore project *raven* (when its project
  is archived), then the copies and Show only *project*. Rename, pin and color
  stay in the sidebar.
- **Keys** while History is active: `⌘F` focuses its search (Edit ▸ Find in
  History), `⌘R` refreshes, `⌘C` copies the selection's resume commands, `⌘⌫`
  archives the selection (when the list has the keyboard), Esc
  clears the search, then the "Archived just now" chip, then the selection,
  then goes back to the previous tab.
  Esc and Return act on what is typed, even within the search's debounce.
  Arrows, Return and Esc drive the list from History's own search field too;
  `⌘A`, `⌘C`, `⌘⌫` and `⇧`-arrows are the list's only while no field has
  focus. In the sidebar search or a chip being renamed every key stays that
  field's. While the import sheet is up, every key
  goes to it.
- `⌘⇧Y` (View ▸ Archived Sessions, the launcher's Archived sessions) opens
  History in its Archived scope, leaving search and filters as they are;
  pressed on History already showing Archived, it stays, like `⌘Y`. Opening
  an archived session anywhere else unarchives it too; a session resumed
  outside Temple stays archived, because activity on disk is not a decision.
- A session Temple archived itself is tagged **No transcript** or **No folder**
  after its title, and its Restore says why. Restore brings it back like any
  other; a file that turns up again does not, and Temple does not watch an
  archived session's files at all.
- The palette and History fields include a `×` clear control. Esc dismisses
  any panel from anywhere. `⌘K`, `⌘P`, and `⌘/` are mutually exclusive —
  presenting one dismisses the others, and `⌘Y` and `⌘⇧Y` put them away too.

## Notifications & activity

Every open session has an activity dot in both its tab chip and sidebar row:

| Dot | Meaning |
|---|---|
| Green | The agent is running. |
| Gray | The tab is open and idle. |
| Orange, pulsing | A background session needs attention — the one dot that moves. |
| Red | The process exited during the retained launch-failure window. |

Temple derives these states from signals available through the terminal. A
Return submitted to the terminal marks the session running. A terminal bell or
desktop-notification escape (OSC 9 or OSC 777) marks the focused session idle or
a background session as needing attention. Without a stronger signal, roughly
15 seconds of quiet settles a running session to idle.

A background bell or OSC signal also produces a native macOS notification with
the project, session, and supplied message. Clicking the notification focuses
that session and switches project context.

## Settings

Settings opens as a singleton, card-grouped tab rather than a separate window.
Changes apply live where applicable.

- **Terminal:** font size and font family.
- **Agents:** default agent used by `⌘T`, folder launches, and recent-project
  launches.
- **Claude:** configurable Command and Arguments fields. The shipped default
  arguments are `--dangerously-skip-permissions`.
- **Codex:** configurable Command and Arguments fields. The shipped default
  arguments are `--dangerously-bypass-approvals-and-sandbox`.
- **Appearance:** System, Light, or Dark theme.

- **Hosts:** the machines you can start sessions on
  ([Sessions on a host](#sessions-on-a-host)). **Added hosts** lists every
  host Temple has, by name, wherever it came from: beside the name, the
  address for a host added by address, "from ~/.ssh/config" for one of the
  config's aliases (and, in orange under it, "No longer in ~/.ssh/config:
  ssh may not reach it by this name. Add it back to the file, or remove the
  host." when the config stopped naming it). Under the name, on a line of
  their own so no label is cut short: **Test connection**, **Running
  sessions on <host>…**, then **Open ~/.ssh/config** for a config alias or
  **Edit** for a host added by address, and **Remove** (its tag says
  `~/.ssh/config` is not changed), with the host's status line under them;
  with none, "No hosts yet." **Add host…** opens a small sheet with one
  **Host** field ("alias from ~/.ssh/config, or user@address"). Under it,
  "Click a host to add it at once." heads the config's aliases not added yet
  (`Host` entries, one level of `Include`; patterns and `Match` blocks are
  skipped), each beside the `user@hostname` its own `User` and `HostName`
  lines set ("no User or HostName set" when they set neither). Those that
  set a `User` or `IdentityFile` come first and bare names such as
  `github.com` last. Typing filters them; six show until **Show N more**.
  Clicking anywhere on a row adds it at once. Return adds what the field
  holds: an alias is added (matched exactly, else ignoring case when only
  one matches), and `user@address[:port]` or an address opens the form for
  an address filled in (the default button reads **Add**, or **Add host by
  address…** while the text reads as an address); text that is neither
  stays in the field with a note. Return while the config is still being
  read says "Reading ~/.ssh/config…" and waits for it. Under the list,
  "Not in ~/.ssh/config? **Add host by address…**" opens that form
  directly (a name, which Temple uses as the host's ssh name too and which
  can't be changed later, an address, and optionally a user, port, identity
  file and jump host, with **Copy as ssh config**), and **Open
  ~/.ssh/config** opens the file. With no alias to offer the sheet says
  why: "No hosts in ~/.ssh/config." or "Every host in ~/.ssh/config is
  already added." Test connection opens a small terminal, in the app's
  light or dark, where your own ssh connects and asks what it needs (a
  host key, a password, a second factor), then checks the login shell's
  PATH, Claude Code, Codex, whether tmux can start a session (by running the
  exact commands a launch sends) and whether the host ends your processes
  when you log out (`KillUserProcesses`), each with **Show output**. The
  status line says what it found ("Connected as <user@address>. Found
  Claude Code 2.1.283, Codex 0.48.0, tmux 3.4."), each problem in a
  sentence, and that it did not check whether Claude Code and Codex are
  signed in; until a test runs it says "Not tested since Temple started."
  (results are kept for this run only). A host that was never tested can
  still start sessions; only a test that ran and found a CLI unusable, or
  tmux missing or too old, rules it out. The card is always there, with no
  host yet too (it is how one is added); its notes say that the arguments
  above apply on hosts, and whether Codex's arguments include `--no-daemon`
  (which lets Temple tell new Codex sessions there apart without asking).
  `~/.ssh/config` is read when the card is shown and again when Add host…
  opens, never before. Opening the sheet runs nothing (not even `ssh -G`,
  which would run a config's `Match exec` commands).

Agent arguments apply to both new and resumed sessions, on hosts too
(`--dangerously-skip-permissions` included, as the Hosts card says). Command paths are
auto-detected and overridable; argument fields are clearable to launch without
extra flags.

Detection runs each candidate's `--version` and launches the first that
answers, in the PATH's own order. A verdict in which a failed probe decided
the winner — something ahead on the PATH skipped, or nothing running at all —
is retried a few times over the next couple of minutes rather than held for
the life of the process (the likely cause seen in the wild: macOS refusing the
first exec of a freshly downloaded binary while it evaluates it). Each
automatic resolution, with the reason anything was skipped, is logged at
notice level under `com.sriramb.temple.app`, category `launch`. Settings shows
the same reasons beside "Also found".

System theme follows macOS live. Light and Dark override it. The embedded
terminal follows the resolved appearance with Temple-owned Adwaita / Adwaita
Dark palettes and never reads or modifies the user's Ghostty configuration.

## Subscription usage

When a Claude Code or Codex subscription login is present, the sidebar footer
shows a compact usage readout — one headline percentage per agent (the most
constrained window: five-hour, weekly, or a per-model cap), a per-agent
breakdown in its tooltip, colored as it approaches the limit. Claude is a
live read of the OAuth usage endpoint using the CLI's own token (Keychain,
file fallback); Codex is the latest rate-limit snapshot from its rollout
logs, as fresh as the last Codex turn. Refreshes every five minutes, on app
activation, and on click — each path floored, and a 429 backs off for an
hour.

The endpoint is undocumented, so every reader treats any surprise as absence —
no login, no subscription, or a changed API means the meter simply doesn't
render, never an error.

The Claude figures are live only while Temple can read the Claude Code
sign-in and the sign-in is accepted. The Keychain is read in-process, and an
unattended poll never raises the macOS Keychain prompt: an item Temple has
not been allowed to read fails closed and the card says "Temple needs
permission to read the Claude Code sign-in. Refresh to allow." — the refresh
control is the one place the prompt may appear, and "Always Allow" there
makes every later poll silent. A token the endpoint refuses shows "Sign-in
rejected. Run claude auth login."; three polls that failed for any other
reason show "Couldn't refresh". All three keep the last figures and when they
were read, and none of them changes the footer: it shows numbers or nothing,
never a warning. What the meter did is written, one timestamped line per
lookup and per fetch, to `~/Library/Application Support/Temple/logs/usage.log`
(size-capped; never the token or the Keychain account) and to the unified log
(`com.sriramb.temple.core`, category `usage`) — including every skipped
poll and every dropped click, so "it does nothing when I click" is
explicable from the file. The file is the one to hand over when the meter
goes quiet. View → Refresh Usage runs the same interactive refresh as the
card's control, for a meter that has never shown a number and so has no
footer to click.

## Menu bar

The native menu bar mirrors Temple's commands instead of WindowGroup's
defaults: **File** carries the session lifecycle (New Session, New Session in
Project…, the other-agent variant, Reopen Closed Tab, Close Tab) in place of
New Window; **Edit** replaces the system Find submenu with Find in Terminal
(`⌘F`, retitled Find in History on the History tab), Find Next and Find
Previous, disabled when no terminal is showing; **View** owns Toggle Sidebar
at `⌘B` plus the palette, Session History, Refresh History (`⌘R`, on the
History tab), Archived Sessions, home, and shortcuts card; a **Project** menu mirrors the switcher and project
cycling; **Settings…** sits in the app menu. Menu items call the same actions
as the shortcuts below — the in-app key monitor remains the keyboard's source
of truth.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| **⌘T** | New empty session in the current project with the default agent. |
| **⌘W** | Close the current tab; asks first only when its agent is running. On a host, an idle agent is stopped and a working one asks Detach, Stop or Cancel. |
| **⌘⇧T** | Reopen the last closed tab (user-initiated closes only). |
| **⌘N** | New session in a project you pick (default agent); `⌘⇧N` uses the other agent. |
| **⌘⇧H** | Show the launcher/home page; existing tabs stay open. |
| **⌘1–9** | Switch to tab *N* in the active project. |
| **⌃⇥ / ⌃⇧⇥** | Tab switcher: last visited tab (hold ⌃ to walk the MRU list, ⇧ reverses mid-walk, release to land). |
| **⌘⇧[ / ⌘⇧]** | Previous / next project; returns to the session last used there. |
| **⌘Q** | Quit, draining every agent first; closing the window does the same. Asks first if an agent is mid-task. Agents on a host keep running. |
| **⌘P** | Project switcher (hold ⌘, tap P to walk, release to land). |
| **⌘F** | Find in the active terminal (bar over the top-right corner); on the History tab, its search. |
| **⌘G / ⌘⇧G** | Next / previous match while the find bar is open. |
| **⌘K** | Command palette: open sessions by recency when empty; ranked search over everything when typed. |
| **⌘Y** | History tab: every session on disk, by day. Opens or focuses it; pressed on it, stays. |
| **⌘R / ⌘I / ⌘A** | On the History tab: refresh the snapshot / import the selection / select every row in view (from the list; in the search field ⌘A selects its text). |
| **⌘⌫** | On the History tab: archive the selection, when every selected row can be (from the list; in the search field it deletes text). |
| **⌘⇧Y** | Archived sessions, in History: the History tab in its Archived scope; pressed there, stays. |
| **⌘/** | Open the Keyboard Shortcuts reference overlay. |
| **⌘B** | Toggle the sidebar. |
| **⌘,** | Open Settings as a tab. |
| **Esc** | Dismiss the palette or shortcuts overlay from anywhere; close the find bar from its field; cancel busy-close confirmation. On the History tab: clear the search, then the "Archived just now" chip, then the selection, then go back. |

Once a host is enabled, the shortcuts card adds: "In a session on a
host, scrolling up shows history; the first key you type returns to the
prompt."

## Command line

`temple` works with the open projects and sessions from any terminal, and
reads History for everything else ([ADR-034](./DECISIONS.md#adr-034--a-temple-command-line-for-the-sessions-you-have-open)).
It ships inside the app at `Temple.app/Contents/Helpers/temple`.

```
temple projects ls | get <dir>
temple sessions ls [--project DIR] [--cli NAME] | search <term> | get <id>
temple sessions new [dir] [--cli NAME] | open <id> | close <id> [--force]
temple history ls [--project DIR] [--cli NAME] | search <term> | get <id>
```

- **`projects` and `sessions` are what has a tab**, as the running app shows
  it: state (running, idle, attention, exited, or restored for a chip whose
  agent has not started), and `*` for the one on screen. They ask the app over
  a socket in the state directory, and say "Temple isn't running" when it is
  not.
- **`history` is the History tab's All scope**, read by the same code: every
  session on disk, Temple's or not, with its status (in-temple, archived,
  outside). It reads the stores and the database itself, so it works with
  Temple closed.
- **`sessions new` is the only command that starts a session**, in the given
  folder (default: the current one) with `--cli` or the default from Settings.
  A new Codex session is `pending`, with no id, until Codex writes its rollout.
- **`sessions open` is the app's Open**: it focuses the tab, or resumes the
  session in one. Any id History lists works; a session outside Temple joins as
  opened, an archived one is restored. One that cannot resume is refused with
  the reason.
- **`sessions close` is `⌘W`**: it refuses while the agent is working unless
  given `--force`.
- `new` and `open` start Temple when no Temple is running (only the app the
  command ships in) and bring it forward. A Temple that runs but does not
  answer, such as an older version, is reported rather than started twice.
- Every read verb takes `--json`. Exit status is 0 on success, 1 when the
  command failed or Temple refused, 2 for a usage error.

## Security

What Temple does, and never does, with the machines you reach over ssh
([ADR-036](./DECISIONS.md#adr-036--sessions-on-another-machine-through-the-users-own-ssh)).

- **No credentials.** Temple runs your own `ssh`, found on your login
  shell's PATH; keys, agents, passphrases, second factors and jump hosts are
  ssh's business. A host added in Temple is a name, an address and
  optionally a user, a port, an identity file's path and a jump host, passed
  to ssh as `-o` options. Temple never passes a password, `-i`,
  `StrictHostKeyChecking`, `UserKnownHostsFile` or `IdentitiesOnly`, never
  writes `~/.ssh/config` or `known_hosts`, and keeps nothing secret in its
  settings, databases or logs.
- **ssh asks only where you can see it**: in the Test connection sheet and in
  a session's tab. Every background question to a host is non-interactive and
  rides a connection one of those opened. When ssh says a host's key has
  changed, Temple says so and stops; it never changes `known_hosts`.
- **Only the hosts you chose.** Temple talks to a host only while it is in
  use in Settings, and only for something you did or for a session that
  names that host. Disabling or removing a host stops every query to it at
  once. Temple never ends an ssh connection it shares with you
  (`ssh -O exit`); a connection it opened ends on its own ten minutes after
  its last use.
- **What Temple leaves on a host**: `~/.temple/launch/` (private to your
  account, checked before every use) and its own tmux server's socket
  (`tmux -L temple`). Every command is a fixed script with its values passed
  as arguments, never spliced into shell text. Temple stops only sessions it
  started, only when you close or stop one, and never your own tmux server.
- **Arguments travel.** Settings' Claude and Codex arguments apply on hosts,
  so `--dangerously-skip-permissions` runs there as it does here.

## Platform & packaging

Temple is a native Swift/AppKit/SwiftUI macOS app with a Metal-backed embedded
libghostty surface. It ships as a Developer ID-signed `.app`; `make install`
provides the local installation path. The bundle identifier is
`com.sriramb.temple`.

The app adopts the login-shell `PATH` so GUI-launched sessions can find the
agent CLIs, raises its file-descriptor limit for large session stores, and uses a
Temple-owned terminal configuration. Its single main window uses a native
unified toolbar, a standard macOS split view with Temple's own sidebar toggle,
and System / Light / Dark appearance.

## Roadmap / TODO

| Area | Planned work |
|---|---|
| Distribution | Notarized `.dmg` releases; auto-update; additional menu-bar and Dock integration. |
| Activity | Replace or strengthen the 15-second settle-timer heuristic; per-session and per-project mute; Do Not Disturb; Dock and sidebar badge counts. |
| Sidebar & discovery | Project pinning; agent, time-range, and active-only filters; richer project/agent/content search; configurable scan roots and excluded paths; rich metadata such as message count, model, and git branch in the sidebar. A History tab over every session on disk shipped as `⌘Y`; a preview on Space is reserved there. |
| Session management | Delete; duplicate/fork; grouping by git repository. Archive, rename, pin/unpin, color marks, and context menus are already shipped. |
| Session lineage | Follow a Temple session that Claude continues under a new id (`←` / `/bg` writes `continued-in` into the old transcript) and hand its row and tab to the child; open live background sessions with `claude attach`; optionally show subagents under their parent. Each becomes Temple's through the same `join`, with lineage kept apart from how it joined (ADR-023); on-disk hooks in [SESSION-FORMATS](./SESSION-FORMATS.md). |
| Terminal & tabs | Split panes; copy mode; terminal cursor controls; tab-bar overflow handling. `⌘⇧T` reopen-closed-tab shipped. |
| Windowing | Multi-window support. |
| Agents | Third-agent adapters such as Gemini CLI and aider; surface agent-specific capabilities such as models and permission modes. |
| Proxied backends | Opt-in launch through a local [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) endpoint, so a session can run on a pooled or non-Anthropic backend (`claude --model gpt-5.6-sol`) without touching the direct-login path. Per-session and per-project, never a global default: Claude takes `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` in `TerminalCommand.env`, Codex ignores `OPENAI_BASE_URL` and needs `-c model_providers.…` flags instead. Endpoint URL is a settings key; the token is not, and belongs in the Keychain or an env lookup rather than `UserDefaults`. Model list comes from the endpoint's `/v1/models`, and a proxied session wants a visible mark in the tab and sidebar, because API-key auth makes Claude Code ignore the claude.ai login and disable its connectors. |
| Platforms | Linux build with a GTK libghostty host. |
