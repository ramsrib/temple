# Working on Temple

## Running the app — use `make demo`, never a bare launch

Temple reads the **real** Claude/Codex session stores and writes to the **real** app
preferences. A dev build launched casually is not a sandbox: it shows Sri's actual
projects, and its settings writes land in the same `UserDefaults` domain his
installed Temple uses.

```
make demo        # fake session store in /private/tmp/temple-demo — no real projects
make demo-clean  # remove it
```

Use `make demo` for anything visual: screenshots, UI verification, driving the app.

Three traps, each hit for real:

- **`open dist/Temple.app` may not launch what you built.** LaunchServices resolves
  the bundle id and will happily activate the copy in `/Applications` instead — you
  screenshot the old UI and conclude your change didn't work. Launch the binary
  directly (`dist/Temple.app/Contents/MacOS/Temple`), or `make demo`. To confirm
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
  `TEMPLE_SNAPSHOT_PRESENT=palette|history|archive` opens that panel two seconds
  after launch, for snapshots of rows no key chord can be posted to reach.
  **Keep the window at least partly uncovered while snapshotting:** a fully
  covered window counts as occluded, its terminals are told they are hidden
  (`GhosttySurfaceView.syncRendererState`), and they stop updating — the shot
  shows terminal content from the moment the window was covered.
  `TEMPLE_SNAPSHOT_APPEARANCE=dark|light` forces the appearance for that process
  without touching the persisted theme setting — **check both**: a fill that
  reads fine in light mode was a shade off the selection wash in dark.
  Drive the UI with AppleScript (`tell application "System Events" to tell
  process "Temple" …` — the *bundled* `dist/Temple.app` binary, not the bare
  SwiftPM one, which has no windows System Events can see). The shot is a real
  pixel capture of the window's screen rect: sidebar, terminal, panels and
  context menus all appear as on screen; other apps' windows do not. For clicks,
  right-clicks, drags and key chords that AppleScript can't post, compile
  `Scripts/uiclick.swift` (usage in its header).

- **`make demo` isolates the stores and state dir, but NOT `UserDefaults`.**
  `TEMPLE_CLAUDE_ROOT` / `TEMPLE_CODEX_ROOT` / `TEMPLE_STATE_DIR` are redirected;
  the settings domain is not. Anything that writes a setting — including a
  first-launch defaults migration — hits his real preferences. Say so before you
  run it.

## Two entry points: the shipped app is not the binary `make demo` runs

`make demo` and `swift run` build the SwiftPM executable, whose `@main` is
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

## Quitting: ask before the window goes, and never reply early

Temple is single-window, so **closing the window quits** — the red button routes
through `windowShouldClose` → `applicationShouldTerminate` → drain. Three traps
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
- **Schema changes stay additive until remote ships.** Builds before ADR-029
  have no newer-schema guard, so a dropped or retyped column breaks the
  installed app running beside a dev build on the same file. `generated_title`
  is still dual-written for them.
