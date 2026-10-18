# Working on Temple

## Running the app — use `make demo`, never a bare launch

Temple reads the **real** Claude/Codex session stores and writes to the **real** app
preferences. A dev build launched casually is not a sandbox: it shows Sri's actual
projects, and a bundled build's settings writes land in the same `UserDefaults`
domain his installed Temple uses.

```
make demo        # fake session store in /private/tmp/temple-demo — no real projects
make demo-clean  # remove it
Scripts/demo-app.sh  # the bundled equivalent's app: a renamed copy of dist/Temple.app
```

Use `make demo` for anything visual: screenshots, UI verification, driving the app.

Four traps, each hit for real:

- **`open dist/Temple.app` may not launch what you built.** LaunchServices resolves
  the bundle id and will happily activate the copy in `/Applications` instead — you
  screenshot the old UI and conclude your change didn't work. Launch a binary
  directly, and for a demo never `dist/Temple.app` itself (its frames land in
  his preferences, see below): `make demo`, or the copy `Scripts/demo-app.sh`
  makes, launched by the isolated recipe in
  [docs/UI-SCENARIOS.md](docs/UI-SCENARIOS.md#fresh-fixture-and-launch). To confirm
  which build is on screen: `strings <binary> | grep '<a string you just added>'`.

- **Sri's own Temple is usually already running from `/Applications`.** Check
  `ps aux | grep Temple.app` before assuming a Temple window is yours, and target
  your instance by pid, not by name:
  `tell application "System Events" to tell (first process whose unix id is <pid>) …`
  Never kill the `/Applications` one — he has live agent sessions in it.

- **`make install` / `make stage` break `screencapture` for any shell running inside
  Temple — including this one.** Both run `tccutil reset ScreenCapture` for Temple's
  bundle id (see the Makefile for why). A Claude Code or Codex session hosted in a
  Temple tab is, to TCC, Temple: every `screencapture` after that fails with
  "could not create image" until Sri re-grants Screen Recording in System Settings
  and relaunches Temple. Take the screenshots you need *before* installing, or
  tell him a re-grant is coming. **The way around it** — also for a shell whose
  terminal was never granted Screen Recording — is the app's own snapshot hook:
  launch with `TEMPLE_SNAPSHOT_DIR=<dir>` and send `kill -USR1 <pid>`; the app
  renders its window in-process to `<dir>/snapshot-NN.png` (`WindowSnapshot.swift`).
  The same gate installs two gesture hooks for frame-by-frame checks of an
  animation nothing outside the process can trigger without input injection:
  `kill -USR2 <pid>` toggles the sidebar (⌘B), `kill -INFO <pid>` folds/unfolds
  the first project. Fire USR1 in a 50ms loop right after either to get frames.
  `TEMPLE_SNAPSHOT_PRESENT=palette|history|archived` opens that panel two seconds
  after launch, for snapshots of rows no key chord can be posted to reach.
  **Keep the window at least partly uncovered while snapshotting:** a fully
  covered window counts as occluded, its terminals are told they are hidden
  (`GhosttySurfaceView.syncRendererState`), and they stop updating — the shot
  shows terminal content from the moment the window was covered.
  `TEMPLE_SNAPSHOT_APPEARANCE=dark|light` forces the appearance for that process
  without touching the persisted theme setting — **check both**: a fill that
  reads fine in light mode was a shade off the selection wash in dark.
  Drive the UI with AppleScript (`tell application "System Events" to tell
  process "TempleDemo" …`: the *bundled* demo copy below, not the bare
  SwiftPM binary, which has no windows System Events can see). The shot is a real
  pixel capture of the window's screen rect: sidebar, terminal, panels and
  context menus all appear as on screen; other apps' windows do not. For clicks,
  right-clicks, drags and key chords that AppleScript can't post, compile
  `Scripts/uiclick.swift` (usage in its header).

- **A demo's settings follow `TEMPLE_DEFAULTS_SUITE`; AppKit's autosaves follow
  the app's identity.** `TEMPLE_CLAUDE_ROOT` / `TEMPLE_CODEX_ROOT` /
  `TEMPLE_STATE_DIR` redirect the stores and the state (database, catalog cache,
  `ghostty.conf`), and `TEMPLE_DEFAULTS_SUITE` redirects Temple's settings:
  `TempleState.settingsDefaults` is the one place Temple gets its `UserDefaults`,
  and `make demo` sets `com.sriramb.temple.demo.settings`. AppKit's own writes
  (the window frame, the split view's widths, the open panel's folder, saved
  window state) can only use the app's own domain and bundle id. For the
  SwiftPM binary that is the `temple-app` domain (an unbundled executable's
  domain is its name; measured), never his. For `dist/Temple.app` it **is** his
  (`com.sriramb.temple`), whatever variables you set. So a bundled demo runs the
  copy `Scripts/demo-app.sh` makes (bundle id `com.sriramb.temple.demo`,
  executable `TempleDemo`), never `dist/Temple.app` itself, and anything new
  that reads or writes a setting goes through `TempleState.settingsDefaults`.

## Two entry points: the shipped app is not the binary `make demo` runs

`make demo` and `swift run temple-app` build the SwiftPM executable (the
product named `temple` is the command line, ADR-034), whose `@main` is
`Sources/Temple/TempleApp.swift`. The `.app` — `make app`, `make install`, the
Homebrew release — is built by xcodebuild from `project.yml`, whose `@main` is
**`App/TempleApp.swift`**. They are two files with the same `init()` shape and
neither includes the other. Anything done at launch (a store path, a flag, a
resource lookup) must be done in **both**, or it works in every demo and every
test and is silently absent from what users run. Shipped for real: the usage
meter's log file was enabled in the SwiftPM entry point only; the released app
never wrote it, and the first report of the meter failing came with no file to
hand over — the exact case the file existed for. The demo cannot catch this,
because the demo runs the other binary; check with
`strings dist/Temple.app/Contents/MacOS/Temple | grep '<a string only the .app path would carry>'`,
remembering that Swift keeps strings of 15 bytes or fewer inline, where
`strings` cannot see them.

The two binaries can also differ in the **SDK they record** (`LC_BUILD_VERSION`),
and macOS picks AppKit/SwiftUI behaviour by that, not by the source. Since
Xcode 27, `swift build` (the Swift Build engine) linked the SwiftPM binary as
built against SDK 14.0, its deployment target. The demo then ran with macOS 14
compatibility behaviour: the sidebar drew 52pt below where it took clicks,
under an empty band, while the .app was fine. It looked like a bundling
difference and was taken for one. `Package.swift` hands the real
SDK to the link (`linkAgainstBuildSDK`), and `make build` runs
`Scripts/check-sdk-linkage.sh`. If the demo and the .app disagree on how
something looks or where it takes clicks, check
`otool -l <binary> | grep -A4 LC_BUILD_VERSION` before you compare anything else.

## A probe that fails once is not a verdict — macOS evaluates fresh binaries on first exec

`AgentToolchain` decides which `claude`/`codex` Temple launches by running each
candidate's `--version`. Seen 2026-09-26: Temple 0.3.0's first launch probed
claude 2.1.283 one second after install, got a launch error (the likely cause,
from the system log's timestamps, is macOS evaluating the freshly downloaded
binary — Gatekeeper scan, provenance — on its first exec by a freshly
installed app; the probe threw the error away, so it is not established),
chose the 2025 npm relic behind it on the PATH, and — detection ran once and
never again — every new session for the next ten hours launched a CLI that
rejects `--session-id`. Opening Settings happened to re-detect and "fixed" it. So: a verdict that came
from a probe that failed to run, or timed out, is retried on a short schedule
(`ToolchainModel.retryDelays`), the launch error is kept in the verdict rather
than flattened to "can't be launched", and every verdict is logged at notice
(`com.sriramb.temple.app`, category `launch`). Don't add a probe path that
records a failure without a reason, and don't cache a detection result past
the retry schedule without a way back.

## The split view's titlebar inset is fragile — the detail pane can break the sidebar

`NavigationSplitView` gives the sidebar an automatic titlebar inset. Certain layout
modifiers **in the detail pane** make SwiftUI rewrap the split view, and the sidebar
silently loses that inset: its rows then scroll up under the title bar and collide
with the traffic lights. The sidebar code is not involved and nothing errors — you
only find it by scrolling the sidebar and looking.

Known triggers, each found by bisection after it shipped a bug:

- **`.fixedSize(horizontal: false, vertical: true)`** — the idiomatic way to let a
  `Text` wrap inside an `HStack`. Broke the sidebar from the launcher's warning
  banner. Wrap text with `.frame(maxWidth: .infinity, alignment: .leading)` instead.
- **`.allowsHitTesting`** — broke it from the overlay panels; an environment value
  (`\.overlayActive`) is used instead. See the comment in `RootView`.

Rule of thumb: if a change to the **detail** pane makes the **sidebar** look wrong,
you have found another one. Before adding a layout modifier that forces measurement
(`fixedSize`, `layoutPriority`, intrinsic-size tricks) to anything under
`MainContentView`, scroll the sidebar and check the traffic lights. The real fix is to
stop depending on the implicit inset — until someone does that, this list will grow.

## Title-bar double-click has one owner, and it is not AppKit

AppKit zooms on a title-bar double-click only where the window's private
*drag region* allows (`-[NSWindow _shouldZoomInDragRegionAtLocation:]`), and
that region is a cache rebuilt lazily from the view tree. In Temple it left
out the whole sidebar with no tab open, and the detail side right after
History opened; which half worked depended on what had last been laid out.
`TitleBandDoubleClick` (a per-window mouse-down monitor) performs the system
action on empty band and swallows that click so AppKit cannot act twice.
It acts only when the gesture's first click was on empty band too: a first
click can dismiss a panel's backdrop and leave empty band under the second.
Don't add a per-page zoom shim, and don't "fix" a dead spot by changing what
the band hit-tests to: mark a new band control `TitleBandControl` instead.
`TEMPLE_DEBUG_TITLEBAR=1` logs every band double-click (category
`titlebar`): what it hit, AppKit's own verdict, and what was done.

## Quitting: ask before the window goes, and never reply early

Temple is single-window, so **closing the window quits** — the red button routes
through `windowShouldClose` → `applicationShouldTerminate` → drain. Four traps
here, each one shipped as a bug first.

- **Ask in `windowShouldClose`, not in `applicationShouldTerminate`.** AppKit only
  reaches the terminate delegate *after* the window is closed, so a confirmation
  there has nothing to cancel back to: v0.1.13 put the "an agent is still working"
  prompt up over a destroyed window, and SwiftUI — its `WindowGroup` now empty —
  tore the scene down and exited regardless of `.terminateCancel`. Cancel killed
  the agent it offered to protect.
- **Don't answer that prompt by starting a termination.** Calling `NSApp.terminate`
  from inside `windowShouldClose` (even deferred a run-loop turn) re-enters: SwiftUI
  re-delivers `windowShouldClose` during its scene teardown, so one click produced
  two prompts and the second quit despite Cancel. Decide synchronously in the
  callback and return the answer; record the approval so the termination it starts
  doesn't ask again. That approval must be scoped to the closing window and expire
  — a global "already said yes" gets banked by a close that never terminated.
- **`reply(toApplicationShouldTerminate:)` must come *after* `.terminateLater` is
  returned.** `SessionRuntimeController.drainAll` used to invoke its completion
  synchronously when nothing was running, which replied first; AppKit then waited
  forever for a reply that had already come. Symptom: **the app cannot be quit at
  all** — window open, close button and `⌘Q` both inert, no error anywhere.
  Reachable whenever a tab's agent had already exited.
- **Every quit with a model drains, tabs or not, and the reply waits for the
  engines.** A quit with no tabs used to return `.terminateNow` and leave the
  engines, their FSEvents streams and proofs running into `exit()`.
  `drainForQuit` now stops listening to engine snapshots in the same call as
  the drain's end, then replies only once every engine and its source has
  stopped (`HostEngine.shutDown`), or after `engineShutdownTimeout` (2 s,
  logged): a stuck host must never make Temple unquittable. The race is two
  unstructured tasks, not a task group, which would wait for a stuck child.

Deciding in `windowShouldClose` means displacing SwiftUI's own window delegate, so
`WindowCloseInterceptor` answers that one selector and forwards everything else via
`responds(to:)` + `forwardingTarget(for:)`. Like the titlebar band claim, it
**self-heals rather than latches**: reinstalled on `didBecomeMain`/`didBecomeKey`,
swept once at launch for a window that beat the observers, dropped on `willClose`.
Anything gated on a window being *visible* is wrong here — `isVisible` and
`canBecomeMain` are both false for a minimized or `⌘H`-hidden window, which is
still a window the user can come back to.

## Settings: shipped default → detected → user override

Three layers, and **only the third is ever persisted**:

| layer | lives in | example |
|---|---|---|
| shipped default | code (`?? 13`) | font size 13, SF Mono |
| detected | memory, recomputed each launch (`ToolchainModel`) | which `claude` actually runs |
| user override | `UserDefaults` | the Command field in Settings |

Absence at any layer means "defer to the layer below" — an empty `claudePath` is
not missing data to be backfilled, it is the user saying *you pick*.

**Never write a computed value into a settings key.** v0.1 did: it seeded
`claudePath` with its own auto-detected guess, and `persist()` rewrote every key on
any change, so the first drag of the font-size slider laundered that guess into the
same bytes a deliberate override lives in. After that, nothing could tell Temple's
guess from the user's decision — so the guess could never be safely revisited, and
the only way out was a migration that tries to divine intent from old data. We do
not do blind migrations. Keep the layers separate and there is nothing to migrate:
each setting writes only its own key (`write(_:_:)`), and detection is never saved.

A user override **wins outright** — including a broken one. Temple launches what
they chose and reports that it's broken; it never silently substitutes its own pick.

**Adding a field to a persisted `Codable` needs an explicit decoder.** A stored-property
default does *not* make synthesized `Decodable` tolerant of a missing key — it still
requires the key and throws `keyNotFound`. Every `load()` here turns a throw into an
empty result, so the field that was meant to default quietly erases the whole record
set the first time older data is read. Write `init(from:)` with `decodeIfPresent`, and
pin it with a fixture of the *old* JSON.

## Agent binaries are detected, never guessed

`LoginShellEnvironment` asks the user's **login + interactive** shell for its PATH
(`-lic` — a login-only shell skips `.zshrc`, where much of a real PATH is assembled),
and `AgentToolchain` then *runs* each `claude`/`codex` it finds and picks the first
that works. Don't reintroduce a hardcoded list of install directories: a machine with
a stale `claude` shadowing a current one will silently launch the stale one, and the
user's own shell won't reproduce it. Whatever we reject, we explain in Settings.

**Temple has no opinion on how an agent CLI is built or what it runs on.** It is not
our job to know about Node, npm, version managers, or anyone's runtime — chasing that
is a bottomless pit and none of it is Temple's problem. The only question we can
answer honestly is *"does this binary run?"*, so we run it and report whatever it says
back. Two consequences, both load-bearing:

- Never diagnose *why* a CLI is broken, and never special-case a runtime. Surface the
  CLI's own error output and let the user act on it.
- Never assume a CLI validates anything. Measured: `codex --bogus-flag --version`
  exits 2 and names the flag, while `claude --bogus-flag --version` exits 0 and prints
  its version. So the pre-flight argument check can **prove a failure but never a
  success** — there is no "arguments OK" tick, and there must not be one. What
  pre-flight can't catch, the launch-failure header in `MainContentView` does.

## The row is the session — never build a surface from a transcript

Since ADR-029 every surface renders `session_state` rows (`Session`, grouped by
`ProjectKey(host, directory)`). Transcripts only fill a row's missing facts and
verify identity. Rules that each prevent a bug that shipped or nearly did
during that refactor:

- **Parsers never invent.** A fact the file does not state is nil.
  Placeholders and Claude's lossy directory decode are display hints on
  `TranscriptSummary`; storing one makes a guess permanent, because fills only
  write NULL columns.
- **Fills are NULL-only; the tab's directory wins.** Only a launch that
  *reports* entering its folder records it (`tab`-sourced, replacing any prior
  value): `HostLauncher.prepare` returns the command, the agent's own argv for
  the failure header, and a `LaunchResultChannel`; the folder is written on
  its `.directoryEstablished`, after the spawn started — never from a
  preflight check, an exit code or `start()` returning. The local launcher
  runs the agent behind `/usr/bin/env /bin/sh -c 'cd -- "$1" || …; exec "$@"'`
  with positional arguments and a per-launch marker armed before the spawn;
  a launcher failure (`.failed`) keeps the tab with its reason however long
  the process lived. A host whose launcher returns no channel never records
  a folder from a tab. Copying a row into a restored chip writes nothing.
- **Destructive-ish actions take their proof at decision time, through the
  host seam.** Archiving a row because its transcript is gone asks the
  owning host's `proveAbsent` right before the write (ADR-030); long-lived
  engine state — a published `.confirmedAbsent`, a cached completeness — is a
  hint and is never load-bearing for such an action.
- **The engine never writes the database.** `SessionEngine` reads rows and
  publishes authorized facts; only `FactPersister`, called from the app (or
  writable templectl), writes them, under the `(id, host, incarnation)`
  predicate. Don't add a DB write to the engine or a source: the incarnation
  check in the write is what makes a leave-and-rejoin race harmless, and it
  only works if every engine-originated write goes through it.
- **Absence needs evidence.** Only a completed enumeration is `absent`;
  `mismatch`, `unreadable`, a failed scan, a cancelled scan or a missing
  catalog entry never are. A remote transport failure must not be either.
- **Local transcript I/O is the `TempleLocalHost` module.** Its stores are
  internal; `LocalSessionSource` is the public type. `TempleUI` imports it in
  exactly one file, `Sources/TempleUI/Hosts/LocalHost.swift`, and templectl
  imports it; `ModuleBoundaryTests` asserts that import list, and that
  `TempleCore/Formats` touches no filesystem API (no `FileManager`,
  `FileHandle`, `contentsOf`, `open`). Neither can stop a new direct read of a
  transcript path with Foundation from TempleUI or TempleCore — that remains
  a review rule: route it through `HostSessionSource`.
- **Hosts build their own commands.** Launch from an `AgentLaunchSpec` through
  the row's host's `HostLauncher`; never build a command with this Mac's
  toolchain and hand it to another host. Directory checks go to the owning
  host too, and "unknown" must not be treated as "missing".
- **Temple archives only what it can prove is gone, and only reversibly.**
  The sweep acts on `.confirmedAbsent` (a completed enumeration) or the owning
  host's `.missing` folder evidence alone, never on a failed, partial or
  cancelled scan, `.unreadable`, `.mismatch`, `.incomplete`,
  `.awaitingCreation` or `.unknown` (a missing store root, Claude's or
  Codex's, and a folder whose volume is not mounted are failures, not
  absences), and only for the membership the verdict names. Every automatic
  archive records its reason, is rechecked in its own SQL, and is undone by
  the notice's Undo or a Restore, which keep the row until activity after
  the restore. Don't add an automatic archive path
  without a reason column and a person's way back, don't put it on the
  window's undo stack, and don't make the engine watch archived rows.
- **Schema changes stay additive.** Builds before ADR-029 have no
  newer-schema guard, so a dropped or retyped column breaks the installed
  app running beside a dev build on the same file. `generated_title` is
  still dual-written for them. (This rule used to end "until remote ships";
  remote shipped without touching the core schema, and the owner keeps the
  rule.)

## User-facing words get a cold read, not just a design review

Any change that adds or rewords a label, button, link, menu item, sheet
title, banner, notice or empty state runs the cold-read procedure in
[docs/copy-review.md](docs/copy-review.md) before it is pushed: the strings,
with where they appear and nothing about what they do, go to a reviewer that
has never seen the design (Opus or Fable, never the copy's author), who says
what each one does and walks a few plain tasks. Design reviews with full
context missed "Sessions…" and "Turn off" on the Hosts card because the
reviewers already knew what they did, the prompts asked about looks, and
each round shortened labels for layout. Never shorten a label at the cost
of its meaning; change the layout instead. Screenshot and computer-use
checks never assert exact strings.

## Sessions on hosts (ADR-036): where remote lives

Remote shipped with **no core schema change**: core migrations still end at
`v12-archive-provenance`, and `v13-project-host` stays reserved and unused
(a restored tab's host is its row's host). Everything remote-only is
deletable without touching core rows; keep it that way
([docs/designs/remote-ssh.md](docs/designs/remote-ssh.md) section 9,
"Removing remote").

- **One module, one import.** Remote code is the `TempleRemoteHost` module;
  `TempleUI` imports it only in `Sources/TempleUI/Hosts/RemoteHost.swift`
  (`ModuleBoundaryTests` asserts it). The remote tab logic is
  `RemoteTabController`; `OpenSessionsModel` keeps thin seams into it, so
  don't grow remote branches back into the model. Remote-only lifecycle
  metadata (runs, handles, pins, claims, left-running flags, a host's
  project masks) lives in `remote-state.sqlite` (its own migrator) and the
  host list in the `temple.settings.remoteHosts` key, never in
  `session_state`, `open_tabs` or `project_state`. A session on a host is
  still an ordinary row and its tab an ordinary saved tab. Temple never
  archives or unarchives a row on its own, and never undoes a link it made:
  a person's open (the activation sink, ADR-017) brings a row back, and a wrong automatic link is closed as any tab is; a claim, a join,
  a verified identity and a reconcile leave every archive as it is. A saved
  tab whose row is archived restores as an inert chip, local and remote alike.
- **Two entry points.** The host list (`temple.settings.remoteHosts`) and
  the registry are built by `AppStartup`/`AppModel`, which both
  `TempleApp.swift` files share; anything remote added at launch goes
  there, not into one `@main`. Before a release, run
  `Scripts/check-remote-code.sh` on the built `.app`: it proves the shipped
  binary carries the remote code and that nothing gives the host list a
  default.
- **No host enabled means nothing happens, and local is unchanged.** There
  is no flag. With no host enabled the registry holds this Mac only, no ssh
  config is read until Settings' Hosts card is shown, nothing is spawned,
  no remote store file is created, and no remote UI appears (no ⌘N or
  launcher host rows, no shortcuts note, no sidebar notices): the Hosts
  card is the one exception, since it is how a host is added
  (`RemoteHostsTests`). Remote UI appears for an enabled host only. A
  remote change must not alter a local tab's behaviour or looks: scope it
  to remote tabs and projects (`tab.remote`, `host.isLocal`), and test the
  local case against what it did before.
- **Never on a real host from a casual run.** Tests use `LocalShellExec` or
  stubs (`SSHConnectionTests` runs the local `ssh` against fixtures and a
  local listener only). The Linux acceptance tests are the only ones that
  reach a host, opted into with `TEMPLE_REMOTE_ACCEPTANCE=<alias>`, and only
  `masterblaster-mentes` / `jetson-mentes`.
