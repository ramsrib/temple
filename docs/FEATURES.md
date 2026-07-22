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

- Projects and sessions are ordered by recency at launch, then frozen for that
  app run so activity cannot move a row under the pointer. Newly discovered
  entries prepend without reshuffling existing entries.
- The initial view shows up to eight projects and six sessions per project.
  **Show all projects** reveals the rest of the projects; within a project,
  **Show more** reveals ten further sessions at a time and reports how many
  remain, and **Show fewer** folds the list back.
- Filesystem watching, an index cache, and retries for files caught mid-write
  keep the index current without blocking launch.
- Agent badges distinguish Claude Code and Codex. Ambient and automation noise
  is hidden by the default noise filter.
- Sessions can be renamed, pinned, and color-marked. Pinned sessions appear in a
  dedicated section and custom names become their displayed and searchable
  titles. A color mark set on a session's tab shows in the sidebar as a slim
  leading capsule.
- A session-row context menu can open or focus the session, copy its resume
  command or ID, reveal its source file in Finder, rename it, pin or unpin it,
  and close its tab when open.
- The native sidebar can be shown or hidden. When hidden, the working surface
  expands to the window edge.

### Select versus open

Opening a session starts a real agent process, so browsing and opening are
separate actions. Arrow keys move the sidebar highlight without spawning
anything. Enter, double-click, or click opens the highlighted session; if it is
already open, Temple focuses its existing tab instead of creating a duplicate.
The sidebar highlight follows the active tab.

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
- A project Temple has never seen is opened by choosing its folder, from the
  switcher, from the sidebar's Projects header, or from the home page. That
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

The active libghostty terminal fills the main content area. Temple launches the
agent directly in the session's working directory and sends keyboard input to
the terminal; there is no bottom composer and no intervening shell.

- Files and images dropped onto a terminal are typed into it as shell-escaped
  paths, which is how an agent is handed a screenshot or a log. An image dragged
  from a browser or Preview carries no file, so Temple writes one and passes that.
- Each session chip shows its agent, title, activity dot, and close control.
  Double-clicking a chip renames the session in place: Enter commits, Esc
  cancels, and an emptied field reverts to the automatic title.
- A chip can carry one of seven fixed color marks (context menu → Color),
  Warp-style: the chip's fill and hairline take the tint, as does its drag
  preview and sidebar row. Marks are keyed to the session, so they survive
  closing the tab and relaunching Temple.
- The trailing `+` menu starts a new Claude or Codex session in the active
  project. `⌘T` takes the default-agent fast path.
- Tabs are drag-reorderable within their project. Temple persists each
  project's open-tab set and order.
- Open tabs restore lazily after relaunch as inert chips. No agent process starts
  until its chip is activated, and Temple restores the last-active project
  context.
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
- When a process exits on its own, Temple normally closes its tab. The session
  persists on disk and remains in the sidebar.
- Closing a tab asks for confirmation only while its agent is running. Return
  confirms; Esc cancels. Idle, attention, exited, inert, and Settings tabs close
  immediately.
- A non-user-initiated exit within roughly five seconds of launch keeps the tab
  visible with a red exited dot so the failure output can be read.
- Quitting Temple gracefully shuts down all live agent processes; Temple does
  not detach or orphan them.
- `Ctrl+D` passes through unchanged. If the agent exits on EOF, Temple handles it
  as an ordinary process exit.

New sessions are empty agent sessions, ready for terminal input. Temple can
start one from the launcher, a project-header `+` menu, the tab-bar `+` menu, or
`⌘T`. **Choose folder…** starts in a directory that is not yet indexed. Claude
sessions receive a Temple-generated session ID; Codex creates its own ID, which
Temple adopts when the new rollout file appears
([ADR-008](./DECISIONS.md#adr-008--session-identity-id--cli-id-asymmetric-minting)).

## Launcher / home page

`⌘N` shows the home page without closing existing tabs. Its masthead presents
Temple and the tagline “Where agents answer the call.”

The **Get Started** section provides New Claude session, New Codex session, New
session in folder…, Command palette, Keyboard shortcuts, and Settings. An agent
row uses the last-used project, or asks for a folder if none exists; the folder
row uses the default agent.

**Recent Projects** shows up to five noise-filtered projects in launch-frozen
order, with relative activity time on hover. Choosing one starts a brand-new
session there with the default agent; it does not reopen an existing session.
The home page is the general creation surface—there is no new-session modal or
prompt composer.

## Command palette, history & search

- Sidebar search filters session titles in place. It does not auto-focus at
  launch; `⌘F` reveals the sidebar when necessary and focuses the field.
- `⌘K` opens a top-anchored command palette. With an empty query it lists every
  session newest-activity-first, with the open sessions floated on top as a
  switcher block, a **Recent** divider between the blocks, and a relative
  timestamp on each row. Unlike the launch-frozen sidebar, this order is live.
- Typing searches all indexed sessions and weights open matches above closed
  ones. Search matches the *displayed* title — a rename or the agent's own
  title — as well as the original first-prompt title, whichever scores better.
  Choosing a result opens or focuses it and switches project context as needed.
- `⌘Y` opens the session history: every non-noise session, newest first,
  grouped under Today / Yesterday / date headers, each row carrying its agent,
  displayed title, last-message preview, project, and relative time. Typing
  switches to a flat ranked search; Enter or a click resumes the session.
- The palette and history fields include a `×` clear control. Esc dismisses
  either from anywhere. `⌘K`, `⌘Y`, `⌘P`, and `⌘/` are mutually exclusive —
  presenting one dismisses the others.

## Notifications & activity

Every open session has an activity dot in both its tab chip and sidebar row:

| Dot | Meaning |
|---|---|
| Green | The agent is running. |
| Gray | The tab is open and idle. |
| Orange | A background session needs attention. |
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

Agent arguments apply to both new and resumed sessions. Command paths are
auto-detected and overridable; argument fields are clearable to launch without
extra flags.

System theme follows macOS live. Light and Dark override it. The embedded
terminal follows the resolved appearance with Temple-owned Adwaita / Adwaita
Dark palettes and never reads or modifies the user's Ghostty configuration.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| **⌘T** | New empty session in the current project with the default agent. |
| **⌘W** | Close the current tab; asks first only when its agent is running. |
| **⌘⇧T** | Reopen the last closed tab (user-initiated closes only). |
| **⌘N** | Show the launcher/home page; existing tabs stay open. |
| **⌘1–9** | Switch to tab *N* in the active project. |
| **⌃⇥ / ⌃⇧⇥** | Next / previous tab. |
| **⌘⇧[ / ⌘⇧]** | Previous / next project; returns to the session last used there. |
| **⌘P** | Project switcher (hold ⌘, tap P to walk, release to land). |
| **⌘F** | Reveal the sidebar if needed and focus sidebar search. |
| **⌘K** | Command palette: recency-ordered sessions (open first) when empty; ranked search when typed. |
| **⌘Y** | Session history: every session, newest first, grouped by day. |
| **⌘/** | Open the Keyboard Shortcuts reference overlay. |
| **⌘B** | Toggle the sidebar. |
| **⌘,** | Open Settings as a tab. |
| **Esc** | Dismiss the palette, history, or shortcuts overlay from anywhere; cancel busy-close confirmation. |

## Platform & packaging

Temple is a native Swift/AppKit/SwiftUI macOS app with a Metal-backed embedded
libghostty surface. It ships as a Developer ID-signed `.app`; `make install`
provides the local installation path. The bundle identifier is
`com.sriramb.temple`.

The app adopts the login-shell `PATH` so GUI-launched sessions can find the
agent CLIs, raises its file-descriptor limit for large session stores, and uses a
Temple-owned terminal configuration. Its single main window uses a native
unified toolbar, standard macOS sidebar behavior, and System / Light / Dark
appearance.

## Roadmap / TODO

| Area | Planned work |
|---|---|
| Distribution | Notarized `.dmg` releases; auto-update; additional menu-bar and Dock integration. |
| Activity | Replace or strengthen the 15-second settle-timer heuristic; per-session and per-project mute; Do Not Disturb; Dock and sidebar badge counts. |
| Sidebar & discovery | Project pinning; agent, time-range, and active-only filters; richer project/agent/content search; configurable scan roots and excluded paths; rich metadata such as message count, model, and git branch in the sidebar. A flat recents view shipped as the `⌘Y` history and the `⌘K` recency list. |
| Session management | Archive and delete; duplicate/fork; grouping by git repository. Rename, pin/unpin, color marks, and context menus are already shipped. |
| Terminal & tabs | Split panes; scrollback search and copy mode; terminal cursor controls; tab-bar overflow handling. `⌘⇧T` reopen-closed-tab shipped. |
| Windowing | Multi-window support. |
| Agents | Third-agent adapters such as Gemini CLI and aider; surface agent-specific capabilities such as models and permission modes. |
| Platforms | Linux build with a GTK libghostty host. |
