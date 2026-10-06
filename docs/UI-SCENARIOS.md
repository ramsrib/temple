# Temple UI regression scenarios

## 1. Purpose and how to use this document

This is the living UI regression checklist for a person or a computer-use agent testing Temple. It covers Temple's own app UI only: window chrome, sidebar, chips, launcher, panels, History, archive/import UI, read-only Settings, menus, appearance, failure windows and responsiveness. It excludes terminal input/output, agent behavior, session internals and agent lifecycle. Existing isolated sessions may supply a chip, status dot or Temple launch-failure header for manual inspection, but their contents are not acceptance criteria. This is not a substitute for unit, host-contract or database tests. Run P0 scenarios on every UI change, the affected area's scenarios before merging, and the full applicable pass before a release. Repeat layout and focus checks on each supported macOS version available to the team.

Read the setup before acting. Run the untouched-fixture checks first, then reversible edits, then fixture variants, then separately authorized manual checks of session chrome and quitting UI. Each scenario states its own preconditions; never carry altered counts into a fresh-fixture assertion. Record SKIP with a reason when a fixture, permission, tool capability, or isolated environment is unavailable. A workaround is evidence of partial coverage, not a PASS for the original gesture. For a partially exercised scenario, use SKIP and list the substeps that passed or failed; any observed defect makes the scenario FAIL.

Priorities: P0 protects safety, core navigation, state, or a known regression; P1 covers ordinary workflows; P2 covers less common or extended conditions. Safety labels are conditional on Section 2:

- **Safe in demo:** no process launch or shared setting change; reversible demo database changes are allowed.
- **Needs care:** requires a fixture variant, precise process targeting, clipboard/Finder access, or geometry restoration.
- **Manual only:** requires a separately isolated macOS test account or test machine, pre-existing isolated session chrome, controlled UI error fixtures, or explicit quitting authorization. These scenarios do not authorize operating the owner's app.

Keep reports and screenshots outside the checkout, for example in a unique `/private/tmp/temple-ui-run.XXXXXX` directory. Append concise run results to the Result log at the end, preserving previous entries. Keep large evidence files externally and link them when available. Use this template:

```text
Date/time and timezone:
Build/version, commit, dirty-tree description, binary path and hash:
Runner (person or agent/tool/version), macOS version:
Demo PID, fixture seeded at, fixture variant, appearance:
Window size in points, detail-pane width, screenshot scale:
ID | PASS/FAIL/SKIP | action and actual result | screenshot/log | bug link
Bugs: severity, scenario ID, steps, expected, actual, reproducibility
Known-bug retests and new findings:
Final demo counts/state, processes left running, frame restoration status:
```

For a fresh run, never reuse the historical PID in a result entry. Use exact current copy in reports. Counts, IDs, dates and paths are dynamic where specified. Text quoted here avoids em-dashes; where the UI contains one, the sentence is described rather than quoted verbatim.

### Source and coverage rules

The source inventory is [FEATURES.md](FEATURES.md). Behavior and safety are grounded in [AGENTS.md](../AGENTS.md), [DECISIONS.md](DECISIONS.md), [demo-data.py](../Scripts/demo-data.py), the [Makefile](../Makefile), and `Sources/TempleUI` views, models and key routing. ADR-031 supersedes the separate archive-browser language in ADR-017/028. ADR-029 makes database rows the sessions; files enrich them. ADR-030 requires proof before automatic archive. ADR-032 caches catalog summaries, not membership or archive decisions.

The first computer-use pass, dated 2026-10-05, is evidence, not the specification. Its plan and report are currently at:

- `/private/tmp/claude-501/-Users-sriram-Projects-active-temple/d0a7aaa4-c32e-4581-bca2-00812a287547/scratchpad/cu-ui-test-prompt.md`
- `/private/tmp/claude-501/-Users-sriram-Projects-active-temple/d0a7aaa4-c32e-4581-bca2-00812a287547/scratchpad/cu-ui-report.md`

Those temporary files may disappear. The watch list below preserves their actionable findings. FEATURES roadmap items are not shipped acceptance criteria: do not fail for missing project pinning, delete/fork, lineage/attach, split panes, multi-window, third agents, proxy backends, cloud sync, Linux, auto-update or notarized DMG distribution. The current titlebar implementation has overflow cues, covered below, even though the roadmap still mentions overflow work. Temple remains a terminal host, without a chat composer, git operations or general-purpose shell tabs.

## 2. Safety and setup for automated runs

### Hard boundaries

1. Operate only a verified demo process. Never click, type into, move, resize, close, quit or signal the owner's Temple. Never select an app merely by the name Temple or its bundle identifier.
2. Never inspect the real `~/.claude`, `~/.codex`, or `~/Library/Application Support/Temple`. Never copy production data into a fixture. All fixture reads, edits and database backups must resolve beneath the declared temporary test directories.
3. Never start, resume or import a session unless the scenario explicitly allows that action and the current run authorization permits it. The 2026-10-05 Pass 2 authorization forbids all three, even where a future manual scenario describes them. Sidebar single-click opens a session, unlike History single-click, which selects. Return, double-click, Open, recent-project rows, creation menus and `⌘⇧T` can launch real CLIs. Restore buttons do not launch agents.
4. Never change Settings, including resets, clear buttons, font controls, agent defaults, command/argument fields or appearance. Opening Settings for read-only inspection is allowed here, although the first pass prohibited opening it. UserDefaults is shared. A first-launch migration can also write it; announce that limitation before launching.
5. Never change system settings, permissions, appearance, display, Dock, notifications or Keychain access. Do not approve a permission prompt to complete a check. Record SKIP if existing access is insufficient.
6. Never use `make install`, `make stage`, `make open`, `open dist/Temple.app`, bare `swift run`, or a bare app launch. Install/stage can reset Screen Recording permission and affect the owner's installation. LaunchServices can redirect `open` to `/Applications/Temple.app`.
7. Do not run `make demo-clean` in this workflow: it also removes matching paths in the real Claude store. Reset only a verified disposable `/private/tmp/temple-demo`, after its owning demo process has stopped and after checking that no other runner uses it.
8. If the screen is locked, stop and report without typing. Never quit either Temple in a browsing-only pass.
9. Do not run a real agent against seeded transcripts. They were never real agent sessions and cannot resume. Demo store variables redirect Temple's readers, not the CLIs' own output stores. Live tests require independently verified CLI storage isolation in a disposable macOS account or machine, using only test projects and data.

**Additional isolation limit:** demo variables do not isolate Claude usage authentication. The current usage reader can consult the macOS Keychain and fall back to the current user's Claude credentials file. Do not claim that `make demo` alone guarantees zero access to the owner's credentials or real stores. If the run requires that guarantee, run under a disposable macOS test account/machine with no owner credentials, or use a reviewed test build that disables that access. Do not invent an environment switch. Do not click usage refresh on the owner's account. Pass 1 created the document without launching an app. Pass 2 operated only the owner-prepared, already-running bundled demo.

### Fresh fixture and launch

Coordinate with other runners first: `demo-data.py` uses one fixed directory and reseeds transcripts with new UUIDs. `make demo` does not clear old state; rerunning it over an old state directory can accumulate old memberships and change counts. Preserve an intentional run or stop its demo and reset the disposable fixture before reseeding. Never reset while another demo is using it.

Use the Makefile's supported flow for SwiftPM: `make demo` builds, seeds 25 sessions, imports them using `templectl`, prunes three transcripts, and launches with all three isolation variables. Arm snapshots by supplying `TEMPLE_SNAPSHOT_DIR` and optionally `TEMPLE_SNAPSHOT_APPEARANCE` in its environment. Save frame preferences before invoking it. Record that this is the SwiftPM entry point, not the shipped bundle.

For bundled UI automation, use the exact equivalent fixture flow below and execute the binary directly. This is the bundled equivalent of `make demo`, not permission for a bare launch. Build with `make build` and `make app` only when the run authorizes building; coordinate with concurrent code work and record the binary actually used. The example assumes a fresh, verified demo directory, existing binaries, a Bash shell, and an isolated account when strict store-access isolation is required:

```bash
set -euo pipefail
cd /Users/sriram/Projects/active/temple
run_dir=$(mktemp -d /private/tmp/temple-ui-run.XXXXXX)
source Scripts/window-frame-prefs.sh
frame_prefs_save com.sriramb.temple "$run_dir/frame-prefs.plist"
# Stop here if saving failed. Do not launch without a usable snapshot.
export TEMPLE_CLAUDE_ROOT=/private/tmp/temple-demo/claude-store
export TEMPLE_CODEX_ROOT=/private/tmp/temple-demo/codex-store
export TEMPLE_STATE_DIR=/private/tmp/temple-demo/state
./Scripts/demo-data.py
.build/debug/templectl --import-all
./Scripts/demo-data.py --prune
export TEMPLE_SNAPSHOT_DIR="$run_dir/snapshots"
export TEMPLE_SNAPSHOT_APPEARANCE=light
# Optional: export TEMPLE_SNAPSHOT_PRESENT=palette (or history or archived)
# Start this as a harness-managed background job and retain its exact PID:
dist/Temple.app/Contents/MacOS/Temple
```

Execute setup sequentially and stop on any error. The final line runs in the foreground as written; a runner must use its supported background-job facility to retain control. Do not assume the PID of `make` is the app PID. Record app PID and executable path from the process list. Compare `ps -axo pid=,command=` with the launch record; the installed app normally runs from `/Applications`. Confirm the demo shows only `acme-api`, `storefront`, `notes-app`, `pipeline`, `dotfiles`, and, when visible, `legacy-tools`. Fake names alone are a second check, not proof of PID identity. Never reuse PID 17819 from the first pass.

For AppleScript target every operation inside:

```applescript
tell application "System Events"
    tell (first process whose unix id is DEMO_PID)
        -- Read or operate this process's window here.
    end tell
end tell
```

Replace `DEMO_PID` with the verified current number. Keep queries and actions in the PID-scoped block: returned accessibility references can resolve back through an ambiguous process name. Verify the demo is the key window before global key injection. The bare SwiftPM executable may not expose windows to System Events; use the bundled demo for those checks.

`App/TempleApp.swift` is the bundled entry point; `Sources/Temple/TempleApp.swift` is SwiftPM's. Startup changes require verification of both. Check the actual binary with a sufficiently long identifying string or hash, not the app icon. If rendering/hit-testing differs, compare `otool -l <binary>` and its `LC_BUILD_VERSION` SDK. `make build` runs `Scripts/check-sdk-linkage.sh`.

### Frame preferences, evidence and cleanup

[window-frame-prefs.sh](../Scripts/window-frame-prefs.sh) saves only `NSWindow Frame ` and `NSSplitView Subview Frames ` keys. Use its `frame_prefs_save` before the first launch and `frame_prefs_restore com.sriramb.temple "$run_dir/frame-prefs.plist"` only after the last test PID exits. Do not restore the entire defaults domain. The helper preserves types and removes frame keys introduced by the test. It cannot distinguish geometry the owner's running Temple changed during the run; coordinate to avoid that race. Saving frames does not protect settings from migrations or edits.

Default automation leaves the demo open unless lifecycle testing or cleanup was explicitly included. Report its PID, size and pending frame restoration. If cleanup is authorized, stop only the recorded demo PID, confirm it has exited, then restore frames. Never use `pkill Temple`, `killall Temple` or name-based quit. Preserve screenshots and the result log before deleting only verified disposable test data.

With `TEMPLE_SNAPSHOT_DIR` armed at launch:

```bash
kill -USR1 "$demo_pid"   # writes snapshot-01.png, then increasing numbers
kill -USR2 "$demo_pid"   # toggles sidebar through the app action
kill -INFO "$demo_pid"   # folds/unfolds the first project
```

Validate the PID again before signalling. Without the snapshot gate these signals are not safe test commands. Use a bounded frame-capture burst at about 50 ms around a toggle when inspecting animation, not an endless polling loop. Keep the demo at least partly uncovered: fully occluded terminals stop updating and snapshots can show stale contents. The hook captures this process's window and panels, not other apps. It does not justify changing Screen Recording settings when ordinary screenshots fail.

`TEMPLE_SNAPSHOT_APPEARANCE=light|dark` forces process appearance without writing the theme preference. Repeat the baseline in both. `TEMPLE_SNAPSHOT_PRESENT=palette|history|archived` presents that surface about two seconds after launch and requires the snapshot gate. History selection/import hooks exist for prepared fixtures, but do not enable them incidentally; never use `settings-keys`, which exercises editable fields, in this read-only workflow.

### Computer-use limitations and fallbacks

- Both passes' click tools lacked a modifier parameter. Click plus `Shift+Down` is a possible contiguous-selection fallback, but Pass 2 did not establish that it extended selection. Verify the selection bar before acting. `⌘A` on a filtered view reliably selected that view in Pass 2. Test literal `⌘`-click and discontiguous selection manually or with a tool that explicitly supports modifiers. Do not label the substitute as coverage of `⌘`-click.
- Edge, corner and splitter drags did not reliably resize. Prefer a PID-scoped accessibility size action or the demo's native Window > Zoom. Measure the resulting frame; a requested size is not evidence. Native tiling altered restore geometry in the first pass, so test ordinary zoom before tiling. Pass 2 used Window > Move & Resize > Top Left, then Return to Previous Size to return to 1000 by 700. Avoid Arrange/All commands that can affect other windows. Bind Computer Use to the verified bundle path, not the shared app name; obey that tool's own UI-action restrictions instead of switching to an unsupported injection API.
- Synthetic keys may not reach SwiftUI/AppKit key monitors, held-modifier switchers, or the intended field. Verify focus and visible effects after each gesture. Do not repeatedly send Return to diagnose an uncertain target.
- AppleScript and snapshot hooks cover many checks. `Scripts/uiclick.swift` documents an event-posting fallback for right-click, drag and chords; use only when input injection is allowed by the runner and the verified demo is foreground. Never work around tool restrictions or missing permissions.
- Wait for the palette field to visibly focus before ordinary search tests. Separately test immediate typing as PAL-004 so the workaround does not hide the race.
- Record window dimensions in points and screenshot scale. The first pass used 2x screenshots; 1802 pixels was approximately 901 points. History breakpoints use the detail pane, not full window width.

## 3. Fixture reference

Fresh seed, empty demo state, import before prune, then wait for launch's completed archive sweep:

| Project | Claude | Codex | Total | In Temple after sweep | Archived |
|---|---:|---:|---:|---:|---:|
| acme-api | 8 | 1 | 9 | 9 | 0 |
| storefront | 4 | 1 | 5 | 5 | 0 |
| notes-app | 3 | 0 | 3 | 3 | 0 |
| pipeline | 3 | 0 | 3 | 3 | 0 |
| dotfiles | 2 | 0 | 2 | 2 | 0 |
| legacy-tools | 3 | 0 | 3 | 0 | 3 |
| Total | 23 | 2 | 25 | 22 | 3 |

The fresh sidebar order is acme-api, storefront, notes-app, pipeline, dotfiles. The first project has six visible rows and **Show 3 more**. All other active projects fit the six-row cap. There are no open terminals or pinned rows. The fixture has only six projects, so **Show all projects** needs an extension with more than eight visible projects.

| Project | Exact seeded titles, in fixture order |
|---|---|
| acme-api (Claude) | the /orders endpoint returns 500 when the cart is empty, can you trace it?; add pagination to the customers list, cursor based; write integration tests for the webhook retry logic; why is the staging deploy 4x slower than prod?; bump the sdk and fix whatever breaks; can you review the rate limiter before I open the PR; split the monolith config into per-env files; the idempotency key check is racy under load |
| acme-api (Codex) | audit the auth middleware for timing leaks |
| storefront (Claude) | checkout button does nothing on mobile safari; migrate the product grid to the new design tokens; lighthouse score dropped to 61, find the regression; add optimistic updates to the cart |
| storefront (Codex) | convert the legacy sass to css modules |
| notes-app | offline sync conflicts are duplicating notes; swiftui list scroll jank on large documents; add full text search over the local db |
| pipeline | the nightly job silently drops rows, help me find where; parallelize the backfill, it takes 6 hours; set up alerting for the ingestion lag |
| dotfiles | clean up my zsh startup, it takes 400ms; script to sync my brew packages across machines |
| legacy-tools | port the release script from bash to python; why does the nightly build only fail on tuesdays; document the old deploy runbook before we retire it |

The legacy-tools sessions are respectively 9, 20 and 45 days old. `--prune` deletes only their transcripts after membership import, mimicking retention cleanup. `pruned.txt` records their paths; `<path>.kept` preserves a copy. Their project folder still exists, so expect **No transcript**, not **No folder**. Copying a kept file back does not restore membership visibility. UUIDs and calendar headers change with seed time and timezone; do not hardcode the first pass's dates or 18:08 timestamps.

Expected settled header: **25 sessions · 22 in Temple · 3 archived**. All has 25 rows, In Temple 22, Archived 3, Not in Temple 0. Agent filter counts are Claude Code (23), Codex (2). All + `deploy` finds two rows, the staging deploy and archived runbook. The palette finds only staging deploy because it excludes archives. Any agent + acme-api yields nine; Codex + acme-api yields one. Codex usage has five-hour 23% and weekly 41%, so its headline is **41%**. Claude subscription data is not faked and is not a deterministic fixture expectation.

Fixture variants must be described in the run log with titles, IDs, membership, timestamps and paths. Create them only in temporary stores while appropriate readers are stopped, using the fixture's formats and the current `templectl` interface. Never silently change this base fixture to make a test pass. Useful variants: outside sessions added after import, more than eight projects, more than sixteen sessions in one project, noise/subagents, missing folder, unreadable or mismatched transcripts, large catalog, and real test sessions in an isolated account. SKIP dependent scenarios if the variant is absent.

## 4. Scenarios

### 4.1 Launch and startup

#### STA-001: Fresh launch and membership baseline
- **Priority:** P0. **Safety:** Needs care, launch and shared frame preferences.
- **Preconditions:** Section 2 complete; fresh base fixture; recorded binary and PID.
- **Steps:** Launch the demo. Verify fake names and the launcher. Wait for the archive sweep to finish; open History with `⌘Y` and select All.
- **Expected:** One main window, five sidebar projects, no terminal spawned, 25 total / 22 in Temple / 3 archived. Rows render without waiting for every transcript to parse.
- **Notes:** ADR-029/030. A transient pre-sweep count is not a failure; persistent extra rows usually mean reused state and invalidate the baseline.

#### STA-002: Bundled and SwiftPM startup parity
- **Priority:** P0. **Safety:** Needs care, separate runs and frame restoration.
- **Preconditions:** Both binaries built from the recorded revision; fresh fixture per run.
- **Steps:** Run STA-001 with each entry point. Capture the same launcher and History state. Compare SDK linkage if positions or hit targets differ.
- **Expected:** Same store isolation, startup behavior, counts, snapshot overrides and aligned controls. The bundle uses its Ghostty resources and opens a real native window.
- **Notes:** Never infer shipped behavior solely from `make demo`. Short Swift strings may not appear in `strings` output.

#### STA-003: Startup failure windows
- **Priority:** P1. **Safety:** Needs care, disposable state copies only; quitting belongs to QUI-004.
- **Preconditions:** Bundled demo; a SQLite backup of demo state with an unknown migration, and another state directory containing a directory named `temple.sqlite`. See `Scripts/check-startup-windows.sh` for construction, not permission to run its quit steps blindly.
- **Steps:** Launch separately with each temporary state path and the fake store roots. Inspect the window and menus; copy error details for the broken case if allowed.
- **Expected:** Newer schema shows **Update Temple to continue**, version and bundle path, and Quit. Broken database shows **Temple couldn't open its data**, raw path/error, Copy Details, Quit, and Reveal in Finder when a path is available. No ordinary session UI, silent empty fallback or New Window command. Failure content is 560 by 340 points, with native chrome additional.
- **Notes:** Do not damage the base fixture or production database to reach these states.

#### STA-004: Detection warnings and retry presentation
- **Priority:** P1. **Safety:** Manual only, controlled toolchain fixture required; no shared Settings edits.
- **Preconditions:** Isolated account with a prepared PATH containing a failing or initially unavailable test CLI followed by a working candidate.
- **Steps:** Launch; inspect launcher warning and its Settings link. Follow it read-only; observe scheduled retries and eventual recovery.
- **Expected:** Raw failure reason remains available; **Checking…**, retry countdown and **Check again** describe progress. The warning links to the relevant agent. Detection can recover within its retry schedule; no permanent first-failure verdict or fabricated runtime diagnosis.
- **Notes:** Do not edit the owner's PATH or command overrides. A preflight may prove failure, never an “arguments OK” result.

### 4.2 Window and title bar

#### WIN-001: Launcher double-click and drag
- **Priority:** P0. **Safety:** Needs care, geometry is shared through preferences.
- **Preconditions:** Launcher, normal approximately 1000 by 700 point window, existing system double-click behavior known without changing it.
- **Steps:** Record frame. Double-click blank right-pane title strip; capture immediately and after about two seconds. Double-click again. Drag that blank strip to move the demo.
- **Expected:** With Maximize/default behavior, zoom persists and the second double-click restores prior geometry. No bounce. Minimize or None follows the existing system preference instead. Drag moves the window; controls do not become drag handles.
- **Notes:** First pass passed launcher zoom. Blank sidebar header was inert; do not treat it as the same target.

#### WIN-002: History and session-state zoom reversal
- **Priority:** P0. **Safety:** Needs care for History; Manual only for live session state.
- **Preconditions:** Normal-size demo with History open; pre-existing isolated session chip for the session-chrome variant.
- **Steps:** Repeat WIN-001 in History, then in the session-chrome variant. Test before native tiling, then separately after tiling if available. Avoid chip and button hit targets.
- **Expected:** Both halves of the zoom toggle work, with stable geometry after two seconds. Double-clicking a session chip invokes rename instead of zoom.
- **Notes:** Fixed and retested in Pass 2 on ce90dbd, 2026-10-05: History zoom and second-double-click restore worked before and after Top Left tiling. Session-chip variant remains manual. Keep this regression check.

#### WIN-003: Minimum window, split width and traffic lights
- **Priority:** P0. **Safety:** Needs care, PID-scoped resize only.
- **Preconditions:** Base demo; frame preferences saved.
- **Steps:** Request a size below minimum, then approximately 900, 1000 and 1400 points wide. Resize sidebar toward its 240 and 360 point bounds. Scroll it fully with launcher, History and Settings visible in turn.
- **Expected:** Main content minimum is 900 by 600 points; measured outer frame may include chrome. Sidebar ideal width is 280. Traffic lights, search/toggle, project headers and left margins stay intact. No rows scroll across the titlebar or into an empty 52-point hit-test band.
- **Notes:** First pass reached approximately 901 points, not a proven exact minimum. Record actual dimensions.

#### WIN-004: Sidebar collapse and titlebar reflow
- **Priority:** P0. **Safety:** Safe in demo, reversible UI state.
- **Preconditions:** History open and sidebar visible.
- **Steps:** Press `⌘B`, then use the visible toggle to restore. Repeat with the palette dismissed and launcher active; capture animation if possible. Hover a permitted drag near the collapsed edge without dropping it.
- **Expected:** Search and toggle slide beside traffic lights; detail expands; chips begin after the controls, with no overlap, capsule jump or ghost gap. Sidebar does not spring open merely because a drag hovers its edge.
- **Notes:** Snapshot USR2 exercises the same toggle but does not prove the keyboard binding.

#### WIN-005: History responsive tiers
- **Priority:** P0. **Safety:** Needs care, measured geometry required.
- **Preconditions:** Archived scope with three rows; sidebar shown.
- **Steps:** Obtain detail-pane widths at/above 1000, between 692 and 999, below 692, and below 600 points where possible. Type and clear `deploy`; inspect rightmost actions and scroll to the bottom in each tier.
- **Expected:** Wide: one toolbar row. Compact: search above scopes plus separate agent/project menus. Narrow: one Filter menu. Below 600: project/branch column hides. Restore/Import stays visible; titles truncate; nothing widens the pane or pushes the sidebar left.
- **Notes:** Full window width is not pane width. The approximately 900-point whole-window overflow regression must be checked even when the exact breakpoint cannot be reached.

### 4.3 Sidebar and index

#### SID-001: Groups, badges and expansion
- **Priority:** P1. **Safety:** Safe in demo, use disclosures only.
- **Preconditions:** Fresh active sidebar, no pins or manual order.
- **Steps:** Inspect five uppercase group labels, hairline rules, Claude/Codex badges and acme-api's six rows. Click **Show 3 more**, then **Show fewer**. Fold/unfold acme-api and scroll to dotfiles.
- **Expected:** Nine acme-api rows appear when expanded; folding stays within its group's box. Both dotfiles rows are reachable above notice/footer. Header hover reveals a project `+` without starting anything.
- **Notes:** Rows are approximately 32 points high; no scrollbar is expected in this rail.

#### SID-002: Project and session caps
- **Priority:** P2. **Safety:** Needs care, extended fake fixture.
- **Preconditions:** At least nine active projects and a project with more than sixteen members.
- **Steps:** Count initial projects/rows. Use **Show all projects** and **Show N more** repeatedly, then fold back.
- **Expected:** Initial cap is eight projects and six sessions per project; each Show more reveals ten additional sessions or the remainder. N accurately names remaining hidden rows.
- **Notes:** Base fixture cannot cover the project cap or multiple expansion batches.

#### SID-003: Browse highlight versus opening
- **Priority:** P0. **Safety:** Safe in demo for arrow keys only; opening is TAB-001.
- **Preconditions:** Launcher; no text field or panel owns focus.
- **Steps:** Move highlight with Up/Down. Observe tab strip and process-free launcher. Do not click a row or press Return.
- **Expected:** Highlight moves without opening a tab. Closed browsable rows/badges are quieter than live rows; hover changes presentation without launching.
- **Notes:** A sidebar single-click opens, so it is not a safe selection workaround.

#### SID-004: Sidebar search and hidden-rail focus
- **Priority:** P0. **Safety:** Safe in demo, no result activation.
- **Preconditions:** Sidebar visible; base members.
- **Steps:** Click magnifier, type `deploy`, inspect results, press Esc. Repeat with × and with an empty field losing focus. Hide the rail with a query retained; click the surviving magnifier and type after focus is visible.
- **Expected:** Only the active staging-deploy member matches. Search unfolds below the band; Esc/× clears and closes it; empty blur folds it. Hidden-rail magnifier reveals the rail and focuses search instead of discarding the query. `⌘F` does not open sidebar search.
- **Notes:** Recheck titlebar inset after every transition.

#### SID-005: Rename and pin
- **Priority:** P1. **Safety:** Safe in demo, reversible database-only edits.
- **Preconditions:** Closed orders session; note original title.
- **Steps:** Right-click the closed orders row > Rename session. In the Rename session sheet, replace the selected Name with `UI regression orders`; use Save or Return. Search the custom and original titles in palette and History. Pin, inspect PINNED, then Unpin. Reopen Rename session, empty Name and Save to restore the automatic title. Separately use Cancel or Esc and verify no change.
- **Expected:** Custom title propagates to History and palette searches; original prompt still matches there. Pinned section appears and disappears appropriately. Empty name restores automatic title; Esc preserves the previous title.
- **Notes:** UI-2026-10-05-01 fixed and retested in Pass 3: `endpoint` found the renamed orders row in palette and History. Pass 3 cleanup was interrupted by a screen lock; see its final-state record before another run. Do not choose Open. SID-010 covers safe color edits; TAB-004 covers chips.

#### SID-006: Session and project context menus
- **Priority:** P1. **Safety:** Needs care, clipboard/Finder change foreground context.
- **Preconditions:** Base demo; verified existing fixture transcript/folder.
- **Steps:** Right-click a closed row and inspect Open, Rename session, Pin/Unpin, Archive session, Copy resume command, Copy session ID, Reveal session file in Finder, Show in History and the color-circle row. Live rows may offer Focus/Close. Inspect project Reveal in Finder, Copy path, Show in History and Archive project. In a separately scoped clipboard/Finder check, copy fixture values without executing them and reveal only verified fake paths.
- **Expected:** Copies identify the correct agent/session/project. Finder selects only fixture files. Menu availability reflects tab state; a project with tabs offers disabled **Close tabs to archive**. No filesystem or git mutation is performed by browsing.
- **Notes:** Reverify demo focus after Finder. Live Focus/Close are separate scenarios.

#### SID-007: Project drag ordering
- **Priority:** P1. **Safety:** Needs care, real drag support and demo-state persistence.
- **Preconditions:** Five active projects; no agent launch.
- **Steps:** Drag dotfiles header above acme-api's header, then below storefront's body. Fold a target and drop in its lower header half. Inspect launcher order; relaunch only under approved demo lifecycle setup.
- **Expected:** Insertion line, header-shaped preview and dimmed source group agree with the drop. Header means above, body/lower collapsed half means below. Order persists; launcher heading becomes **Projects** and follows its first five. An unplaced new fake project appears above the placed block.
- **Notes:** ADR-017. Do not treat failed synthetic drags as successful ordering. A missed drop must not paste a path into a terminal.

#### SID-008: Membership, noise and live index updates
- **Priority:** P1. **Safety:** Needs care, extended fake stores only.
- **Preconditions:** Add an outside session after initial import, noise fixtures and subagent transcripts; include a member fixture with missing facts.
- **Steps:** Observe sidebar, palette, launcher and `⌘N` picker without activating results. Open History. In controlled fixture steps, complete a partially written member transcript and append activity to another member.
- **Expected:** Outside session appears only in History until imported/opened. Noise and both agents' subagents stay excluded. Missing member facts can fill after retry; recorded titles/directories do not get replaced by guessed or later transcript facts. Existing row order stays frozen during the run; genuinely new members prepend.
- **Notes:** ADR-029. UI evidence cannot prove host/incarnation SQL guards; retain automated contract coverage.

#### SID-009: Restored missing-record presentation
- **Priority:** P0. **Safety:** Safe in demo, Restore button only.
- **Preconditions:** Fresh Archived legacy-tools rows.
- **Steps:** Restore one through History's Restore button; inspect its new sidebar group and tooltip. Search for it without opening it. Refresh History and switch away/back.
- **Expected:** Row survives without a transcript, stays browsable and dimmed as appropriate, and explains the missing file. No fabricated title or deletion. Restore restores the record, not its transcript, and no terminal starts.
- **Notes:** First pass tooltip: **Transcript missing: the session file is no longer on disk**. ADR-029/030.

#### SID-010: Closed-session color and reset
- **Priority:** P1. **Safety:** Safe in demo, reversible metadata only; never choose Open.
- **Preconditions:** Closed orders row; record its original color and pin state.
- **Steps:** Right-click the row. Choose blue from the horizontal color circles. Inspect its leading sidebar capsule; pin it and compare PINNED, then search its title in the palette without activating it. Unpin and reset to the original color, normally the first uncolored circle.
- **Expected:** Blue capsule appears on both sidebar copies and the palette result has a blue wash. Menu offers an uncolored option and seven colors. Reset removes the custom color. No session opens.
- **Notes:** Pass 2 color circles lacked useful AX labels. Use the current screenshot to target the swatch, then verify the visible color. Chip colors remain TAB-004.

### 4.4 Automatic archive and notice

#### AUT-001: Proof-based initial sweep and notice layout
- **Priority:** P0. **Safety:** Safe in demo, initial automatic database change.
- **Preconditions:** Fresh pruned fixture, no user archive/restore yet.
- **Steps:** Inspect notice at full and narrow sidebar widths; scroll to the bottom. Hide/show sidebar and leave it idle briefly.
- **Expected:** **3 sessions archived: no transcript on disk**, × above View and Undo. Message/actions do not overlap. Notice sits below the list and above footer, persists across sidebar hiding, and never covers the final rows.
- **Notes:** No No folder row belongs in the base fixture. Automatic archive is not placed on the window undo stack.

#### AUT-002: View bounded batch
- **Priority:** P0. **Safety:** Safe in demo, browsing only.
- **Preconditions:** Fresh notice visible.
- **Steps:** Click **View**. Inspect tab, scope, chip, count and titles. Clear the chip using ×; repeat from a fresh run and change scope.
- **Expected:** Notice closes; History opens Archived with **Archived just now · 3**, **Showing 3 of 25**, three legacy-tools rows and Restore actions. Chip matches only that batch. × or any scope pick clears it.
- **Notes:** First pass passed. Esc ladder and bridges must clear the chip correctly too.

#### AUT-003: Notice Undo and keep protection
- **Priority:** P0. **Safety:** Safe in demo, reversible demo state.
- **Preconditions:** Fresh notice, not consumed by View.
- **Steps:** Click its **Undo**. Inspect sidebar and All/Archived counts. Reactivate demo and refresh History. If a later sweep can be observed, check the same rows again.
- **Expected:** Notice disappears; all three records return, yielding 25 in Temple / 0 archived. They remain kept despite absent transcripts. No process or file is created. The next sweep does not undo the user's choice.
- **Notes:** New activity after the keep, then another idle week, is required to make them eligible again. Do not wait a week in UI automation; use fixture/contract tests for that guard.

#### AUT-004: Dismiss without restore
- **Priority:** P1. **Safety:** Safe in demo, notice-only state.
- **Preconditions:** Fresh notice.
- **Steps:** Click ×. Open Archived from the launcher; toggle sidebar and revisit History.
- **Expected:** Notice stays dismissed this run; three rows remain archived; counts stay 22/3. Dismissal neither restores nor deletes anything.
- **Notes:** A later launch is a separate notice lifecycle, not proof of this run's dismissal.

#### AUT-005: Returned transcript does not unarchive
- **Priority:** P1. **Safety:** Needs care, fixture-only file restoration.
- **Preconditions:** One pruned legacy row remains archived; its exact path verified in `pruned.txt`.
- **Steps:** Copy its `.kept` file back to that fixture path. Refresh History; inspect Archived and sidebar. Click Restore explicitly.
- **Expected:** File return alone leaves it archived; completed catalog refresh can remove No transcript. Explicit Restore returns only that row and starts no agent.
- **Notes:** ADR-017/030/031. Do not use Return here once the transcript exists; it may resume.

#### AUT-006: Guards, missing folders and uncertain evidence
- **Priority:** P0. **Safety:** Needs care, prepared fake variants; some guards need a manual isolated live run.
- **Preconditions:** Old missing-transcript rows separately pinned, recently active, kept, open or lazily restored; a missing-folder row with transcript; unreadable/mismatched rows; unavailable store variant.
- **Steps:** Launch each variant and inspect counts, tags and notice. In a combined proven-missing fixture inspect mixed-reason notice. Repeat with incomplete or failed listing evidence.
- **Expected:** Pinned/recent/kept/open/restored members do not auto-archive. Proven old missing folder may archive with **No folder** and notice reason **folder gone**. Mixed batches say **transcript or folder gone**. Both reasons on one row prefer transcript. Unknown folder, missing store root, unreadable/mismatched file or incomplete read is not proof and does not archive.
- **Notes:** Do not unplug disks or change permissions on real paths. UI checks supplement decision-time proof and membership-race tests; they cannot establish those invariants alone.

### 4.5 Launcher and creation surfaces

#### HOM-001: Home content and safe routes
- **Priority:** P1. **Safety:** Safe in demo, avoid creation/recent-project rows.
- **Preconditions:** Base demo.
- **Steps:** Press `⌘⇧H`. Inspect Temple masthead, tagline, Get started and Recent projects. Use Command palette, Session history, Archived sessions, Keyboard shortcuts and read-only Settings, returning home each time.
- **Expected:** **Where agents answer the call.** appears. All named routes work; Archived sessions is always present, even when empty. First five projects match sidebar order; relative activity appears on hover. Home does not close existing utility tabs.
- **Notes:** A recent-project click creates a new session, not a safe browsing action. Switch project row appears only with more than one open project.

#### HOM-002: Creation menus and project picker, cancel path
- **Priority:** P1. **Safety:** Needs care, stop before any start or folder confirmation.
- **Preconditions:** Base demo and verified keyboard target.
- **Steps:** Open a project-header `+`, inspect agent choices, dismiss. Open `⌘N` and `⌘⇧N` picker, inspect projects and Choose folder, then Esc. Open `⌘O` folder chooser and Cancel.
- **Expected:** New session heading, agent marks and default-first order; `⌘T` only where it applies to active project. Known unlaunchable agents are disabled with a reason. Picker has no outside or archived projects. Folder command is available away from the sidebar toggle.
- **Notes:** Never press Return on a picker project or confirm the chooser in the baseline pass. No successful-arguments tick is expected.

#### HOM-003: New sessions from every entry point
- **Priority:** P1. **Safety:** Manual only, explicitly permits creation in an isolated live fixture.
- **Preconditions:** Isolated account, verified test CLI storage, known default agent and disposable folders.
- **Steps:** Create using launcher agent row, New session in folder, recent project, project `+`, tab `+`, `⌘T`, `⌘N`, `⌘⇧N` and `⌘O` across separate controlled attempts. Cancel one chooser before selecting; test no prior project and a last-used project.
- **Expected:** Each authorized entry point creates one Temple chip in the intended project with the selected agent badge. Unknown project selection asks for a folder; cancellation creates no chip. Existing default-agent choice is respected. Do not inspect terminal contents, CLI arguments, rollout adoption or agent responses.
- **Notes:** Never run in the seeded demo or change Settings to prepare a default. This manual scenario covers only Temple selection and chip presentation; session behavior is outside scope.

#### HOM-004: Panel to folder chooser, keyboard and Cancel
- **Priority:** P0. **Safety:** Needs care, chooser inspection only; never choose a folder or confirm Open.
- **Preconditions:** Verified demo with a recorded History query. No real paths need inspection.
- **Steps:** Open Shortcuts with `⌘/`, type a harmless marker and verify History is unchanged. Press `⌘O`. Verify the panel disappears and the native Open chooser appears. Click its Search field, type a unique nonmatching test string, then Cancel. Append a marker to History without clicking its search field. Repeat from palette and project picker when time allows, always cancelling the chooser.
- **Expected:** Shortcuts swallows ordinary typing. The chooser accepts text, offers Cancel and the instruction **Choose a project folder to start a session in**. No old panel remains above it. Cancel returns to the prior page/query and typing remains usable; no session chip is created.
- **Notes:** Pass 3 verified the Shortcuts route and post-Cancel typing. Palette/picker variants remain untested. Native chooser may display its remembered directory; do not browse or open it. Panel Search and chooser Search are different fields.

### 4.6 Tabs and project navigation

#### TAB-001: Open, focus and project context
- **Priority:** P0. **Safety:** Manual only, explicitly permits resume of real isolated test sessions.
- **Preconditions:** Two resumable test sessions in one project, one in another.
- **Steps:** Open via sidebar click, Return after arrow selection, and double-click in separate attempts. Reopen an already open row; switch projects.
- **Expected:** Exactly one chip per session. Reopening focuses the existing chip. Sidebar highlight follows active session; strip shows the active project's chips. Switching projects retains other projects' chip state without duplication.
- **Notes:** Never substitute the fake seed transcripts for resumable sessions.

#### TAB-002: Utility tab singleton, close and reorder
- **Priority:** P1. **Safety:** Safe in demo, History and read-only Settings only.
- **Preconditions:** No terminal tabs.
- **Steps:** Open History and Settings repeatedly via menu/shortcuts. Drag their chips to reorder where supported. Close the active utility chip with × and `⌘W`, separately; reopen.
- **Expected:** One chip per utility; no separate Settings window or duplicate History. Close removes only that tab and starts no process. Utilities remain available across project context when test projects exist.
- **Notes:** Do not use `⌘W` on a failure window or click the red window button here.

#### TAB-003: Tab drag order and overflow
- **Priority:** P1. **Safety:** Manual only, isolated live or prepared inert chips; activation may resume.
- **Preconditions:** Enough tabs in two projects to overflow the strip at narrow width.
- **Steps:** Reorder within one project. Scroll strip and use left/right overflow cues; select a clipped tab by `⌘1` through `⌘9`; add/close an edge tab; switch projects and back; expand/collapse sidebar.
- **Expected:** Order changes only within its project. Selected/new chip becomes visible; cue click reveals the nearest hidden chip. No oscillating gutters, permanent blank tail or overlap with traffic lights. Project-specific scroll position restores coherently. Open-tab order survives relaunch.
- **Notes:** Current TitlebarTabStrip implements overflow cues; record actual behavior if a concurrent revision differs.

#### TAB-004: Chip rename, color and context menu
- **Priority:** P1. **Safety:** Manual only to provide a real session chip; metadata edits themselves stay in demo state.
- **Preconditions:** Isolated test tab with known original title.
- **Steps:** Double-click chip, rename and Return; repeat and Esc; clear name and commit. Choose each available color from context menu. Inspect sidebar, palette, tab switcher and History; close/reopen tab and relaunch later.
- **Expected:** Seven fixed color marks, consistent chip fill/hairline, drag preview, sidebar capsule and row washes. Name/color persist by session identity. Empty rename returns automatic title. Menu copies resume command/ID and Close targets this tab.
- **Notes:** A chip double-click must not zoom the window. Renaming must not route Return into History or the agent.

#### TAB-005: Busy close, cancel and idle close
- **Priority:** P0. **Safety:** Manual only, explicitly permits ending isolated test processes.
- **Preconditions:** Running, idle and attention-state test tabs.
- **Steps:** Close running tab using ×, menu and `⌘W` in separate trials. Esc the prompt once; confirm with Return once. Close idle/attention and inert chips separately.
- **Expected:** A running-status chip asks **Close “<title>”?**, offers Cancel/Close and explains interruption. Esc preserves the chip; Return removes it after confirmation. Idle, attention, exited, inert and Settings chips close without a prompt. Do not inspect process shutdown or terminal contents.
- **Notes:** The fixture supplies status states without testing how an agent reaches them. QUI covers app-wide quitting UI.

#### TAB-006: Reopen user-closed tab
- **Priority:** P0. **Safety:** Manual only, explicitly permits resume through `⌘⇧T`.
- **Preconditions:** Two isolated session chips closed by the user; an independently prepared automatically closed-chip variant if available.
- **Steps:** Press `⌘⇧T` repeatedly and inspect File > Reopen Closed Tab. Include a tab closed from another project.
- **Expected:** Most recent user close reopens first; correct project activates. Automatically closed chips do not enter this stack. No duplicate active chip is created. Inspect only Temple navigation and labels.
- **Notes:** This shortcut launches agents; never run it casually in a fixture with unknown saved tab history.

#### TAB-007: Lazy restoration and last-active exception
- **Priority:** P0. **Safety:** Manual only, explicit quit/relaunch and resume.
- **Preconditions:** Multiple isolated test sessions across projects.
- **Steps:** With explicit quit/relaunch authorization, quit from a selected isolated session chip and relaunch the same test state. Inspect restored chip order and selected project. Repeat after quitting from home via `⌘⇧H`; do not type in or inspect terminal contents.
- **Expected:** Last-active project and tab order restore. The formerly selected chip is selected; other chips appear as restored placeholders until activated. Quitting from home returns to home. Missing directory facts produce a Temple explanation rather than an invented directory.
- **Notes:** A restored chip itself does not record a successful directory entry; ADR-029.

#### TAB-008: Project switcher and cycling
- **Priority:** P1. **Safety:** Manual only, may activate/resume isolated sessions.
- **Preconditions:** Three open test projects with known last-used sessions.
- **Steps:** Use folder project control; inspect names, containing folders, counts and dots. Hold `⌘`, tap P repeatedly, then release; reverse with available switcher controls and cancel once with Esc. Try `⌘⇧[` and `⌘⇧]`.
- **Expected:** `⌘P` walks MRU projects, marks current, and one tap returns to previous project; release lands on its last-used session. Bracket shortcuts cycle without HUD. Folder chooser cancels safely. Control is a folder, not a new-session plus.
- **Notes:** Tools that cannot hold modifiers must report the hold/release branch SKIP.

#### TAB-009: MRU tab switcher
- **Priority:** P1. **Safety:** Manual only, may activate/resume isolated sessions.
- **Preconditions:** Three visited test tabs spanning projects; known visit order.
- **Steps:** Hold Control and tap Tab; walk further and reverse with Shift while held. Release to land. Try fresh `⌃⇧⇥`, then `⌃⇥`, and one bounce from home. Cancel a walk with Esc.
- **Expected:** MRU order spans projects, current marker and activity dots are accurate. Fresh forward or reverse tap returns to previous tab; Shift reverses only mid-walk. Cross-project landing switches strip. Cancel preserves original selection.
- **Notes:** Verify key-up delivery with synthetic tools.

### 4.7 Command palette

#### PAL-001: Empty palette and ranked title search
- **Priority:** P1. **Safety:** Safe in demo, no activation.
- **Preconditions:** Base fixture, no open terminals.
- **Steps:** Open `⌘K`, wait for focus, inspect empty state, type `deploy`, then use × and Esc. Repeat with custom-name and original-prompt queries after SID-005.
- **Expected:** Empty state explains there are no open sessions and invites typing. `deploy` lists staging deploy only, with acme-api. Archived runbook is excluded. Both displayed and original titles match; × clears, Esc dismisses.
- **Notes:** The palette has a trailing Search history action for a nonempty query even with active results. The empty-state sentence invites typing to search all. Original-title matching after rename was fixed and verified in Pass 3, UI-2026-10-05-01.

#### PAL-002: Trailing Search history bridge with and without matches
- **Priority:** P0. **Safety:** Safe in demo, explicitly permits Return on the no-match bridge only.
- **Preconditions:** Fresh fixture: `deploy` has one active palette match and two History matches; `retire it` has only the archived runbook.
- **Steps:** Type `deploy` in the palette. Verify the staging result and trailing **Search history for “deploy”** row. Click that bridge, not the session. Verify two History rows. Repeat with `retire it`; verify the sole **Search history for “retire it”** row before pressing Return. Never press Return while an active session result is selected.
- **Expected:** The bridge is present for a nonempty query even when active matches exist. It dismisses the palette and opens History All with the same query, clearing a just-archived chip. Deploy yields two base rows; retire it yields the archived runbook. No session chip is opened.
- **Notes:** Inspect the target before Return; a session result is a different, unsafe action.

#### PAL-003: Result activation, ordering and focus return
- **Priority:** P1. **Safety:** Manual only, explicitly permits opening isolated real session results.
- **Preconditions:** Open and closed matching test sessions across projects.
- **Steps:** Open empty palette, inspect open-chip recency, type a query, select with arrows and Return. Reopen and Esc; verify the original Temple chip remains selected without typing into its terminal.
- **Expected:** Empty query shows open sessions by recent activity; typed results weight open sessions first. Return opens/focuses the intended chip, switches project and dismisses the panel. Esc preserves the original chip selection.
- **Notes:** No duplicate tabs or accidental input to an underlying terminal.

#### PAL-004: Immediate typing focus race
- **Priority:** P0. **Safety:** Safe in demo, History underneath, no terminals.
- **Preconditions:** History search focused with a recorded query.
- **Steps:** Invoke `⌘K` and immediately type `deploy` once. Capture both fields. Dismiss, reset and repeat after visibly waiting for palette focus.
- **Expected:** Typing belongs to the palette; History query remains byte-for-byte unchanged. In the initial focus handoff, at most the first character may be dropped under the current acceptance rule, but none may reach the underlying page. Once focus is established, all typed characters must arrive. Record dropped characters explicitly.
- **Notes:** Retested in Pass 3: immediate `endpoint` arrived wholly in the palette with the underlying History query unchanged; later immediate palette typing also remained isolated. The first-pass split-query bug remains fixed. PAL-006 checks dismissal focus; HIS-018 separately tests opening History itself.

#### PAL-005: Overlay exclusivity and underlying hover
- **Priority:** P1. **Safety:** Safe in demo, dismiss pickers without selection.
- **Preconditions:** Launcher or History, no terminal activation.
- **Steps:** Alternate `⌘K`, `⌘/`, and project switcher if available; use `⌘Y`/`⌘⇧Y` to leave overlays. Move pointer over underlying rows, then Esc.
- **Expected:** Only one panel at a time. History commands put panels away; `⌘Y` over History's palette only dismisses it. Underlying hover/action state does not leak through. Esc dismisses from any field.
- **Notes:** Sidebar traffic-light inset must remain intact after overlays.

#### PAL-006: Panel switching and return to the prior History caret
- **Priority:** P0. **Safety:** Safe in demo, do not activate a session or picker result.
- **Preconditions:** History search focused with a known query and caret at its end; no session tabs.
- **Steps:** Press `⌘K`, type `endpoint` immediately and inspect both fields. Esc, then append a marker without clicking History. Repeat `⌘K`, type, Esc, then append again. Open `⌘K`, switch directly to `⌘N`, type `acme` into the picker without Return, then Esc and append another marker to History.
- **Expected:** Exactly one panel at a time. Palette/picker text never reaches History. Each dismissal returns to History's prior caret at the end, and the marker appends instead of replacing the query. No permanent inability to type. A focus-transition character drop is recorded under PAL-004, never excused as leakage.
- **Notes:** Passed in Pass 3. Use actual typing, not setValue, to prove routing. `⌘A` in History can select view rows rather than replace its search text; use its clear control when resetting the query.

### 4.8 History

#### HIS-001: Singleton and toggle semantics
- **Priority:** P0. **Safety:** Safe in demo, utility navigation only.
- **Preconditions:** Launcher, optionally Settings as previous tab.
- **Steps:** Press `⌘Y`, repeat, then return. Press `⌘⇧Y` to select Archived, repeat while already there. Open palette over History and press `⌘Y`.
- **Expected:** One History chip. Repeated shortcut on its active destination returns to previous tab/home and leaves chip open. Archived shortcut retains search/filters. Palette-over-History case only dismisses palette.
- **Notes:** First pass called Archived's toggle-away a low-severity bug; current FEATURES and ADR-031 explicitly specify it. Treat as an expectation correction, not an open defect.

#### HIS-002: Scope partition and header counts
- **Priority:** P0. **Safety:** Safe in demo, browsing only.
- **Preconditions:** Fresh settled 25/22/3 fixture, no filters/chip/query.
- **Steps:** Select All, In Temple, Archived, Not in Temple; count displayed rows and read header.
- **Expected:** 25, 22, 3 and 0 respectively; header remains **25 sessions · 22 in Temple · 3 archived**. Narrowed scopes show **Showing N of 25**. Not in Temple says **Everything on disk is in Temple.** and **Sessions from other terminals appear here the next time this page refreshes.**
- **Notes:** Archived is a separate partition, although its rows remain members of Temple's database.

#### HIS-003: Row facts, tags, dates and tooltips
- **Priority:** P1. **Safety:** Safe in demo, hover only.
- **Preconditions:** All, fresh fixture.
- **Steps:** Inspect recent and older day groups; scroll under sticky headers. Hover title, gate mark, condition tag and Restore. Inspect Codex and Claude rows.
- **Expected:** Time, agent, title, condition, activity when applicable, project/branch and one status column. Active members have gate mark with join provenance; archives are quieter with Restore and No transcript. Tooltips expose available last message/model/count/path without invented facts. Headers remain sticky and selected rows scroll clear of them.
- **Notes:** Claude fixtures have branch main; not every Codex row has a branch. Dates are relative to seed, not fixed to the first report.

#### HIS-004: Search field coverage and empty result
- **Priority:** P1. **Safety:** Safe in demo, never Return on a resumable match.
- **Preconditions:** All, no other filters.
- **Steps:** Use `⌘F`; search `deploy`, `acme-api`, `main`, a displayed ID prefix, and fixture last-message text where present. Search an impossible phrase, use Clear search, then ×. Include renamed and original titles from SID-005.
- **Expected:** Deploy has two base rows; search composes over title/original, project, branch, last message and ID prefix. No-match text names the query and active filters. Clear search and × reset text without closing the tab.
- **Notes:** Field debounce must not let old results replace newer input.

#### HIS-005: Agent and project filters
- **Priority:** P1. **Safety:** Safe in demo, filtering only.
- **Preconditions:** All, no query/chip.
- **Steps:** Inspect Any agent/Any project counts; select Codex, then acme-api. Reset agent; try the same via narrow Filter menu. Change scope once.
- **Expected:** Claude Code (23), Codex (2); Codex yields two, plus acme-api yields one; Any agent + acme-api yields nine. All six projects are offered. Filters compose and retain day groups; changes reset selection to first visible row.
- **Notes:** Popup counts describe all rows, not just current search. Test layout separately in WIN-005.

#### HIS-006: Arrow and day navigation
- **Priority:** P1. **Safety:** Safe in demo, no Return.
- **Preconditions:** All with History search focused.
- **Steps:** Use Up/Down, Shift+Up/Down, Option+Up/Down, Command+Up/Down and shifted variants. Hover an unselected row.
- **Expected:** Arrows move, Shift extends, Option jumps day and Command reaches ends. Selection scrolls into view below sticky headers. Hover does not move selection. Empty results handle keys harmlessly.
- **Notes:** Verify modifier delivery; do not substitute plain arrows for day/end coverage.

#### HIS-007: Mouse selection and select all
- **Priority:** P1. **Safety:** Safe in demo, single-click only.
- **Preconditions:** All; no sheet.
- **Steps:** Single-click a row; Shift-click another; Command-click a discontiguous row where supported. Filter to acme-api and press `⌘A`; use Deselect.
- **Expected:** Native single/range/toggle selection. `⌘A` selects nine currently visible matching rows, not all 25. Bar says **9 selected · all in Temple** and offers applicable actions. Deselect removes bulk selection.
- **Notes:** Click plus Shift+Down is the first-pass fallback, not proof of modifier-click support.

#### HIS-008: Escape ladder
- **Priority:** P0. **Safety:** Safe in demo, navigation only.
- **Preconditions:** Notice View has supplied chip; type a matching query and make a selection.
- **Steps:** Press Esc once at a time and capture after each press. Repeat with freshly typed text before debounce settles.
- **Expected:** First clears typed search, next clears Archived just now chip, next clears selection, next returns to previous tab/home. No layer is skipped because projected query lagged typing.
- **Notes:** Scope remains Archived when clearing chip; Esc is not a Restore command.

#### HIS-009: Single Restore and immediate keyboard undo/redo
- **Priority:** P0. **Safety:** Safe in demo, Restore does not launch.
- **Preconditions:** Fresh fixture. Search `deploy`, Esc, then Archived, recreating text-edit undo history.
- **Steps:** With History search focused, restore the release-script row and immediately press `⌘Z`, then `⌘⇧Z`; compare query and counts after each. Repeat after deliberately removing search focus, verifying the actual focused element before undo. Also keep a nonempty query such as `release` during a trial. If routing fails, test visible Undo separately. Verify typing still works afterward.
- **Expected:** Restore yields **1 session restored**, Undo hint, 23 in Temple / 2 archived. Intended archive undo returns to 22/3 with original automatic reason; redo returns to 23/2. Search text does not steal the advertised operation.
- **Notes:** Pass 3 verified focused-search Restore, undo and redo while `release` stayed unchanged. A second trial after Tab also undid Restore, but Tab may have selected search text rather than removing field focus, so the unfocused branch remains unproven. Typing afterward worked. Do not assume a Tab press establishes an unfocused state.

#### HIS-010: Bulk Restore and mixed selection bar
- **Priority:** P0. **Safety:** Safe in demo, explicit Restore buttons only.
- **Preconditions:** At least two legacy archived rows; record starting counts.
- **Steps:** In Archived use `⌘A` to select the three base rows. Verify **3 selected · all archived**, then click **Restore 3**, immediately undo and redo. Separately test two-row range selection and a mixed active/archive selection when modifier input is reliable; verify its bar before acting.
- **Expected:** Base bulk bar offers **Restore 3**, **Deselect**, Return restore and Esc deselect hints. Restore yields **3 sessions restored**, 25 in Temple / 0 archived and **Nothing archived**. Undo returns 22/3; redo returns 25/0. An N-row subset uses Restore N; mixed selection restores only archived rows and counts only those changed.
- **Notes:** Three-row ⌘A/Restore/undo/redo passed in Pass 2. Mixed and two-row range branches were skipped. Synthetic Shift+Down did not establish an extended selection, so do not assume it worked.

#### HIS-011: Return and double-click dispatch
- **Priority:** P0. **Safety:** Needs care for confirmed missing legacy rows; Manual only for resumable or outside rows, explicitly permits resume there.
- **Preconditions:** Confirmed No transcript legacy row; two archived selections; isolated resumable variants for other branches.
- **Steps:** Return on one nonresumable archived row, then Return on an all-archived multi-selection. For isolated variants, Return/double-click active, outside and resumable archived rows. Return on a mixed multi-selection.
- **Expected:** Nonresumable archive restores without opening. All-archived multi-selection restores all, never launches many agents. Single resumable row opens/focuses; outside joins as opened; archived restores on the way. Mixed/multiple non-all-archived selection opens nothing.
- **Notes:** Revalidate tags and availability before each baseline Return. A returned `.kept` file changes safety.

#### HIS-012: Archive selection and text-edit boundary
- **Priority:** P0. **Safety:** Safe in demo, closed member rows only.
- **Preconditions:** In Temple; select two closed acme-api rows, with empty search.
- **Steps:** Use **Archive 2**; undo. Repeat with `⌘⌫`. Then put text in focused History search and press `⌘⌫`. Test an ineligible mixed selection using an outside fixture if available.
- **Expected:** Eligible selection archives in one undoable action; counts and sidebar agree. With focused nonempty search, chord deletes text rather than archiving rows. Archive is unavailable/no-op when any selected row is ineligible, including open tabs or outside rows.
- **Notes:** Inspect Edit's undo label to distinguish text edits from archive actions.

#### HIS-013: Foreign-field and sheet keyboard ownership
- **Priority:** P0. **Safety:** Safe in demo for fields; Needs care for prepared import sheet, cancel only.
- **Preconditions:** History active; sidebar search open; later an import confirmation from IMP-001.
- **Steps:** Type into sidebar search and use `⌘A`, arrows and Esc. Repeat with a session rename field without opening it. While import sheet is shown, try `⌘K`, `⌘Y`, `⌘W`, then Esc.
- **Expected:** Foreign field owns editing keys; History does not select/archive/open beneath it. Rename Return commits only the rename. Sheet owns every key; shortcuts do not navigate behind it and Esc cancels.
- **Notes:** HistoryKeyFocus and attached-sheet routing are the source of truth. Settings editing is excluded.

#### HIS-014: Copy commands and context actions
- **Priority:** P1. **Safety:** Needs care, clipboard/Finder; never execute copied text.
- **Preconditions:** Base History with known fixture IDs.
- **Steps:** Select two rows and `⌘C`; inspect copied resume commands. Select text inside History search and `⌘C` again. Inspect row menus across active/archive/outside variants; use Show only acme-api.
- **Expected:** Row selection copies one command per row; selected field text takes precedence. Menu status/actions match row relationship. Archived menu includes Restore and, when applicable, Restore project. Show only filters the project; rename/pin/color remain sidebar actions.
- **Notes:** Reveal only an existing fake transcript, never resolve an unknown path.

#### HIS-015: Show in History and Show in sidebar bridges
- **Priority:** P0. **Safety:** Safe in demo, context-menu navigation only.
- **Preconditions:** Chip or filters active in History; sidebar acme-api available.
- **Steps:** Right-click acme-api header > Show in History. Repeat for orders session. Use its History context menu > Show in sidebar. Repeat with row folded past Show more and with a collapsed project.
- **Expected:** Project bridge opens All filtered to acme-api, clears chip, and yields nine base rows. Session bridge opens All with the full session ID as its search query and clears agent/project filters and chip. Show in sidebar reveals a hidden rail, highlights and scrolls an existing row; it does not automatically unfold hidden rows.
- **Notes:** Hidden-row highlight without forced expansion is documented behavior, not a failed reveal.

#### HIS-016: Snapshot refresh and tab-close reset
- **Priority:** P1. **Safety:** Needs care, outside fake fixture changes only.
- **Preconditions:** History open; add a new external fake session after snapshot.
- **Steps:** Observe without refresh, then click Refresh or `⌘R`. Set query/filters/selection, navigate away/back, then close History and reopen.
- **Expected:** Outside disk catalog is read on showing/refresh, not continuously watched. New outside row arrives on refresh. Switching away/back refreshes while preserving tab filters; closing resets query/filters/selection/notices. Reopening displays retained rows promptly while refreshing underneath. Updated age advances.
- **Notes:** ADR-028/031/032. Members may update independently; they are not evidence of whole-disk watching.

#### HIS-017: Empty states, failed stores and stale commands
- **Priority:** P0. **Safety:** Needs care, isolated fixture variants; avoid commands that launch.
- **Preconditions:** Empty stores variant, failed-read variant and large/slow fake projection variant.
- **Steps:** Inspect initial reading and settled empty states. Restore all archives using buttons, inspect empty Archived and chip-empty states. With a store failure, refresh while other store is healthy. Rapidly change query/filter and then select all; change query again before a queued action can apply.
- **Expected:** No premature No sessions yet during first read. Empty Archived says **Nothing archived**; empty batch says **None of the sessions archived just now are still archived** with Show all archived. Readable store and existing member rows remain; failed store reports its own error when emitted. Stale queued selection/action never applies to superseded results.
- **Notes:** Missing root is not proof of absence and may present empty rather than an error banner. Race-sensitive archive/import variants require controlled fixtures or model tests, not uncontrolled repeated Return.

#### HIS-018: Immediate typing after opening History
- **Priority:** P1. **Safety:** Safe in demo, query input only; never press Return on a row.
- **Preconditions:** Launcher with no session tabs; record whether History is already open as a utility chip.
- **Steps:** Press `⌘Y` and immediately type `deploy` without an intervening focus wait. Capture the resulting search text. Reset using Clear search. Repeat from home, then compare with a trial that waits for visible History search focus.
- **Expected:** Once History is shown its search owns typing. The full query should be captured; no characters may reach a different surface. Report any initial loss separately from the panel-isolation acceptance rule, which applies to PAL-004.
- **Notes:** UI-2026-10-05-03, low-severity observation in Pass 3: the first immediate trial produced `ploy`, dropping `de`. Repetition was interrupted by screen lock, so reproducibility and attribution remain unconfirmed. Later typing in the focused field worked.

### 4.9 Import flow

#### IMP-001: Import confirmation and Cancel
- **Priority:** P0. **Safety:** Needs care, explicitly permits requesting import of an outside fake row, then cancelling.
- **Preconditions:** Add a uniquely titled valid fixture transcript after base import; refresh History; it appears in Not in Temple and nowhere else.
- **Steps:** Click its Import, inspect sheet, Cancel. Repeat via context **Import into Temple…** and `⌘I`.
- **Expected:** Confirmation names title and destination, explains that nothing runs and session files do not change. Cancel preserves membership/counts and opens no tab.
- **Notes:** Do not use Return before checking whether focus is on a sheet or a row.

#### IMP-002: Confirm single and bulk import
- **Priority:** P0. **Safety:** Needs care, explicitly permits fake-row import, never Open.
- **Preconditions:** Outside fake rows, including one whose project is archived; record counts.
- **Steps:** Confirm one Import. Select outside plus existing rows; use **Import N…** and confirm. Inspect sidebar, History and feedback.
- **Expected:** Only outside rows join as imported, no process or transcript rewrite. Temporary **Imported** status appears; stay on History. Bar reports actual import count and Undo even when Not in Temple empties. Archived-project destination is explicitly History under Archived; it does not revive the project.
- **Notes:** Save fixture hashes before/after if proving files unchanged. Use only demo-owned inputs.

#### IMP-003: Undo untouched import
- **Priority:** P0. **Safety:** Needs care, fake memberships only.
- **Preconditions:** IMP-002 imports untouched rows; no rename/pin/color/open/archive since.
- **Steps:** Click notice Undo; separately repeat import and use Edit > Undo Import or `⌘Z` with verified focus. Refresh and inspect all surfaces.
- **Expected:** Untouched rows leave Temple immediately and return to Not in Temple while remaining on disk. Sidebar/palette drop them; no process starts. Report keyboard focus failure separately if present.
- **Notes:** ADR-028. Do not assume redo semantics not specified for import; record the offered Edit command rather than inventing one.

#### IMP-004: Undo import protects touched rows
- **Priority:** P1. **Safety:** Needs care for fake metadata; Manual only for opened/running variants.
- **Preconditions:** Fresh imports, one row per protection case.
- **Steps:** Rename, pin, color or manually archive separate imported rows; then undo the import. In isolated live variants, open then close one and leave another running. Include an automatically archived import and a subsequently restored one where fixture supports them.
- **Expected:** User-touched/opened/running rows stay in Temple; feedback identifies why each was kept. An untouched automatic archive alone does not prevent leaving, but a person's Restore does. Untouched rows still leave.
- **Notes:** Undo Import must not erase later intentional work. Archive/Restore undo and Import undo are distinct stacks/actions.

#### IMP-005: Import errors and partial success
- **Priority:** P1. **Safety:** Manual only, controlled temporary database fault fixture.
- **Preconditions:** Reviewed fault-injection setup affecting only disposable state, with multiple outside rows.
- **Steps:** Attempt bulk import with a prepared write failure; inspect alert, titles and remaining successful memberships. Dismiss with OK; refresh.
- **Expected:** Failure reports raw error and affected titles; committed successes remain imported. Sheet/alert retains keyboard ownership and no agent runs.
- **Notes:** Do not force this by corrupting a running base or production database. SKIP without a controlled fault fixture.

### 4.10 Archive and restore end to end

#### ARC-001: Manual session archive and undo
- **Priority:** P0. **Safety:** Safe in demo, closed member only.
- **Preconditions:** Fresh orders row; pin it first to test pin restoration.
- **Steps:** Context menu > Archive session. Inspect sidebar, palette and Archived. Use Edit > Undo Archive Session, then redo with `⌘⇧Z` after verifying focus.
- **Expected:** Session disappears from browse surfaces and Pinned, appears in Archived with Restore and no missing tag while its file exists. Archive clears its pin; Undo returns both visibility and pin. Files are neither deleted nor moved.
- **Notes:** Use `⌘⇧Y` with HIS-001's toggle semantics, not an assumption it always stays on History.

#### ARC-002: Project archive and full restore
- **Priority:** P0. **Safety:** Safe in demo, no open project tabs.
- **Preconditions:** Pin one storefront row; manually archive a different storefront row first.
- **Steps:** Archive storefront from header. Inspect launcher/picker/palette and History filter. Use the **storefront is archived** line's **Restore project**, then undo/redo with known focus.
- **Expected:** Project and its pins disappear from browse surfaces. Restore project restores project-hidden rows/pins, but leaves the separately user-archived row archived. Undo returns the exact previous mask and archive state.
- **Notes:** ADR-017/031. Project mask hides pins; it does not clear them like session archive does.

#### ARC-003: Restore one from archived project
- **Priority:** P0. **Safety:** Safe in demo, Restore button only.
- **Preconditions:** Entire storefront archived; record five rows and pin state.
- **Steps:** Restore just the checkout row. Inspect sidebar and remaining archives. Undo and redo, checking counts and Restore tooltips.
- **Expected:** Only one row returns; remaining four stay archived. Undo restores original project mask and provenance exactly. Feedback counts the rows actually restored, not every row whose internal archive representation changed.
- **Notes:** Do not expect a single Restore to revive the entire project. Use a fresh project-mask fixture for ARC-002 rather than assuming a converted mask still exists.

#### ARC-004: Archive refusal and prepared archived activity
- **Priority:** P1. **Safety:** Manual only, isolated open and externally resumed sessions.
- **Preconditions:** Test project with open/inert chip; separately prepared archived row whose fixture already reflects later activity.
- **Steps:** Inspect session/project archive actions with the chip present. Refresh History for the prepared archived-activity row. In a separately authorized isolated chip fixture, explicitly Open that row and inspect Temple navigation only.
- **Expected:** Open/restorable chips block archive. The prepared activity row remains archived after refresh. Explicit Temple Open restores only the chosen row and selects its chip.
- **Notes:** Generating external agent activity is outside this checklist. Use a prepared fixture; no external execution or session opening in the base demo.

### 4.11 Settings, read-only

#### SET-001: Settings structure and singleton
- **Priority:** P1. **Safety:** Safe in demo, read-only; never manipulate editable controls.
- **Preconditions:** Verified demo, no settings migration forced for testing.
- **Steps:** Open `⌘,`, launcher Settings and gear > Settings in separate trials. Scroll and inspect AGENTS, CLAUDE CODE, CODEX and APPEARANCE cards. Terminal font is inside APPEARANCE, not a separate Terminal card. Close only the Settings chip.
- **Expected:** One inline Settings tab with grouped cards. Font size/family, default agent, Command/Detected/Arguments, and System/Light/Dark controls are visible. No separate settings window or shared preference write is required by these steps.
- **Notes:** Existing values may be owner overrides; do not reset them to match defaults.

#### SET-002: Detection details and output, read-only
- **Priority:** P1. **Safety:** Needs care, opening Settings probes CLI versions; no command edits.
- **Preconditions:** Detected agents or a controlled failing-toolchain variant.
- **Steps:** Read chosen command/version, **Also found** entries, skipped-candidate reason, checked timestamp and any retry countdown. Open Show output when offered; close it.
- **Expected:** Command, Detected, Arguments, version and checked time are readable. Empty Command says **Leave empty to use the one Temple detects.** An override shows its run verdict and makes detection secondary, with **Not used while a command is set.** Failures retain actual CLI output without invented runtime advice.
- **Notes:** Do not click Check again merely to induce failures on the owner's machine. STA-004 covers controlled retries.

#### SET-003: Defaults and narrow layout inspection
- **Priority:** P1. **Safety:** Safe in demo for inspection; Needs care for resizing.
- **Preconditions:** Known recorded settings; narrow and wide demo windows.
- **Steps:** Inspect command placeholders, argument help, font and theme selections without focus/edit. Resize and scroll both page and sidebar; inspect warning wrapping.
- **Expected:** Empty arguments are supported; shipped argument documentation identifies `--dangerously-skip-permissions` for Claude and `--dangerously-bypass-approvals-and-sandbox` for Codex. Current overrides need not equal these. Cards wrap without clipping or removing sidebar titlebar inset.
- **Notes:** Existing font overrides may show a fallback message and **Use built in**. Do not click it. Pass 2 observed SF Mono unavailable with JetBrains Mono (built in) fallback. Live edits, resets and System-theme changes are excluded from this document; do not use system appearance changes for the appearance pass.

### 4.12 Session chrome and launch-failure header

#### TER-001: Retired, Terminal input and identity

Retired 2026-10-05. Outside the owner-defined Temple app UI scope. No executable steps; ID reserved permanently. Temple chip status is covered by TER-004 and launch-failure chrome by TER-006.

#### TER-002: Retired, Find in terminal

Retired 2026-10-05. Outside the owner-defined Temple app UI scope. No executable steps; ID reserved permanently. Temple chip status is covered by TER-004 and launch-failure chrome by TER-006.

#### TER-003: Retired, File and image drop

Retired 2026-10-05. Outside the owner-defined Temple app UI scope. No executable steps; ID reserved permanently. Temple chip status is covered by TER-004 and launch-failure chrome by TER-006.

#### TER-004: Temple status-dot presentation
- **Priority:** P1. **Safety:** Manual only, pre-existing isolated session chips required.
- **Preconditions:** A manual fixture already supplies chips with running, idle, attention and exited states. Do not generate signals or exercise agent behavior in this checklist.
- **Steps:** Inspect Temple-drawn status dots in tab strip, sidebar, project/tab switchers and History. Compare the same row across surfaces; focus an attention chip only in the isolated fixture.
- **Expected:** Running green, idle gray, attention orange/pulsing and exited red where shown. Only attention pulses. Labels and dots agree across Temple surfaces; focus targets the intended chip.
- **Notes:** Status heuristics and timers are outside scope. A dot is presentation, not evidence of agent completion or permission to quit.

#### TER-005: Retired, Notifications and activation

Retired 2026-10-05. Outside the owner-defined Temple app UI scope. No executable steps; ID reserved permanently. Temple chip status is covered by TER-004 and launch-failure chrome by TER-006.

#### TER-006: Temple launch-failure header and retained chip
- **Priority:** P0. **Safety:** Manual only, prepared isolated launch-failure fixture required.
- **Preconditions:** A prepared test tab already shows a launcher or early-exit failure. No launch of seeded sessions is allowed.
- **Steps:** Inspect the Temple failure header, command/error facts and retained chip. Resize, switch to a utility tab and back, and check title/status presentation. Do not inspect terminal output or send input.
- **Expected:** Temple retains readable failure chrome and the correct chip title/status. Error facts do not invent runtime causes. Header wraps without clipping or disturbing sidebar titlebar inset.
- **Notes:** Process exit, EOF, drain queues, agent lifecycle and terminal contents are outside scope. Startup database-failure windows are STA-003.

### 4.13 Subscription usage

#### USG-001: Deterministic Codex footer
- **Priority:** P1. **Safety:** Safe in an isolated demo, hover only; credential isolation caveat in Section 2 applies.
- **Preconditions:** Fresh seed with newest Codex rate-limit record.
- **Steps:** Inspect right-aligned footer and hover Codex meter; scroll sidebar to bottom.
- **Expected:** Codex headline **41%**, representing weekly constraint over five-hour 23%. Tooltip breaks down windows/reset information. Gear and meter stay on one footer line; content stops above it.
- **Notes:** Do not require a Claude percentage. Clicking the card triggers refresh, so it is not a read-only baseline action.

#### USG-002: Usage card and error presentation
- **Priority:** P2. **Safety:** Manual only, isolated test authentication/service responses; never grant Keychain permissions or inspect owner credentials.
- **Preconditions:** Reviewed test fixtures for success, absent login, refused sign-in, permission-needed, transient failures and 429.
- **Steps:** In the isolated UI fixture, open the usage card and inspect window bars, timestamps and prepared error variants. Inspect View > Refresh Usage without requesting real service activity.
- **Expected:** Cards show supplied figures and reset information legibly. Prepared refused-token state says **Sign-in rejected. Run claude auth login.**; repeated-failure state says **Couldn't refresh**. Last figures stay readable when supplied; footer remains numbers-or-nothing.
- **Notes:** Authentication, network refresh timing, backoff and service correctness are outside this UI document. Clicking the real card can refresh credentials, so skip without an isolated presentation fixture.

### 4.14 Menus and shortcut reference

#### KEY-001: Native menu parity and enabled states
- **Priority:** P1. **Safety:** Safe in demo, inspect unsafe actions without invoking.
- **Preconditions:** Launcher, History and read-only Settings available.
- **Steps:** Inspect Temple, File, Edit, View and Project menus in each state. Invoke only safe counterparts: Toggle Sidebar, palette, History, Archived, home and shortcuts. Compare with table below.
- **Expected:** File has session lifecycle commands rather than New Window. Edit labels Find in Terminal or Find in History appropriately; terminal-only find navigation is disabled without terminal. View owns History refresh and navigation; Project mirrors switcher/cycling. Same safe menu and keyboard actions yield same results.
- **Notes:** Refresh Usage, creation, reopen and quit remain gated by their scenarios.

#### KEY-002: Shortcuts overlay and focus restoration
- **Priority:** P1. **Safety:** Safe in demo, reference overlay only.
- **Preconditions:** Launcher or History.
- **Steps:** Open `⌘/` from History and launcher Keyboard shortcuts. Inspect top, bottom and all sections at approximately 901 by 653 and 1000 by 700, then a taller window. Attempt scrolling if content does not fit. Press Esc; reopen over a palette and verify panel exclusivity.
- **Expected:** Card remains within window bounds, with a visible Keyboard Shortcuts title and scrollable contents. Scroll to reach the final APP entries and back to the first row. Esc dismisses; mutually exclusive panels do not stack. Underlying page remains usable and sidebar inset stays intact.
- **Notes:** UI-2026-10-05-02 fix verified at 1000 by 700 in Pass 3: top was visible, scrolling reached the final Quit entry, and the underlying sidebar stayed below the titlebar. The original 901 by 653 reproduction size remains pending because the screen locked before resizing. Printed terminal shortcuts are app copy only; terminal behavior stays out of scope.

| Shortcut | Expected action/context | Scenario and baseline restriction |
|---|---|---|
| ⌘T | New default-agent session in current project | HOM-003, live isolated only |
| ⌘N / ⌘⇧N | Project picker, default/other agent | HOM-002 Cancel; HOM-003 launch |
| ⌘O | Open Project Folder chooser | HOM-002 Cancel; HOM-003 confirm |
| ⌘W | Close current tab, busy confirmation when running | TAB-002/005; failure window quits |
| ⌘⇧T | Resume last user-closed tab | TAB-006, live isolated only |
| ⌘⇧H | Home without closing tabs | HOM-001, TAB-007 |
| ⌘1 through ⌘9 | Positional tab in active project | TAB-003, activation may resume |
| ⌃⇥ / ⌃⇧⇥ | MRU tab switcher, release Control to land | TAB-009, isolated only |
| ⌘P | MRU project switcher, release Command to land | TAB-008, isolated only |
| ⌘⇧[ / ⌘⇧] | Previous/next project | TAB-008, activation may resume |
| ⌘F | Focus History search when History is active | HIS-004; terminal behavior excluded |
| ⌘K | Palette | PAL-001 through PAL-005 |
| ⌘Y | History; active History returns to previous tab | HIS-001 |
| ⌘⇧Y | History Archived, retaining filters; repeat goes back | HIS-001 |
| ⌘R | Refresh History; Check again on Settings | HIS-016; SET-002 inspect only |
| ⌘I | Request History import | IMP-001/002, explicit fake import only |
| ⌘A | Select History view rows unless foreign field owns key | HIS-007/013 |
| ⌘C | History resume commands, or selected search text | HIS-014 |
| ⌘⌫ | Archive eligible History selection; nonempty focused search edits text | HIS-012 |
| ↑ / ↓, ⇧↑ / ⇧↓ | Move/extend History selection; sidebar arrows only browse | HIS-006, SID-003 |
| ⌥↑ / ⌥↓, ⌘↑ / ⌘↓ | Jump History day/ends; Shift extends | HIS-006 |
| Return / double-click | Open History row; nonresumable archive restores; all-archive multi-selection restores | HIS-011, restricted |
| ⌘Z / ⌘⇧Z | Undo/redo current applicable action; text editor can own these | HIS-009/010, ARC; fixed focus regression |
| ⌘B | Toggle sidebar | WIN-004 |
| ⌘, | Singleton Settings tab | SET-001, read-only |
| ⌘/ | Shortcuts overlay | KEY-002 |
| Esc | Panel dismiss; busy Cancel; History search/chip/selection/back ladder | PAL-005, TAB-005, HIS-008 |
| ⌘Q / red window close | App quit, prompt if running | QUI-001 through QUI-004, never owner app |
| ⌘H | Native app Hide, not home | QUI-002, isolated only |

### 4.15 Appearance

#### APP-001: Light/dark surface parity
- **Priority:** P0. **Safety:** Needs care, separate environment-forced demo launches and frame restoration.
- **Preconditions:** Same known fixture state, `TEMPLE_SNAPSHOT_APPEARANCE=light` then `dark`.
- **Steps:** Capture launcher, sidebar, notice, palette, History All/Archived, bulk-selection/feedback bar and read-only Settings in both modes. Include hover/selection and a colored row when available.
- **Expected:** Text, dimmed rows, Restore, tags, highlights and dividers remain readable. Sticky day headers match page background. Selection/notice bars have discernible surfaces; no mismatched fill or clipping.
- **Notes:** First pass found unselected Restore visually subdued, a UX observation to track rather than a proven disabled control. Never change the stored theme or system appearance to run this.

#### APP-002: Failure-window and launch-header appearance
- **Priority:** P1. **Safety:** Needs care for startup failure windows; Manual only for a prepared isolated session failure header.
- **Preconditions:** STA-003 variants and TER-006 prepared header, each under forced light/dark.
- **Steps:** Capture Temple failure messages, buttons, launch-failure header and surrounding chip in each appearance. Exclude terminal contents.
- **Expected:** Failure window honors the process override without a normal app model. Temple header, chips and controls remain legible with coherent surfaces in both appearances.
- **Notes:** System theme follows macOS live by design; this pass observes the current system-resolved mode only, without changing system settings.

### 4.16 Quitting UI

#### QUI-001: No-running-agent quit
- **Priority:** P0. **Safety:** Manual only by default; may be automated only in an explicitly authorized PID-isolated cleanup run.
- **Preconditions:** Verified disposable demo PID; no live agents; snapshots saved and frame backup available.
- **Steps:** In separate launches, use red window close and `⌘Q`. Include a retained exited tab or a session whose process already ended. Observe process exit, then restore frames.
- **Expected:** Window close quits the single-window app without a stuck window or windowless app. Close and quit remain responsive in the prepared exited-chip state. Observe app disappearance only, not agent drain internals.
- **Notes:** Never run against owner's app. A tab close `⌘W` in the main window is not this scenario.

#### QUI-002: Busy quit cancellation keeps window and work
- **Priority:** P0. **Safety:** Manual only, isolated test process; interrupting owner's work is forbidden.
- **Preconditions:** At least one running test agent, with a known window and PID.
- **Steps:** Click red close, choose Cancel; repeat via `⌘Q`. Re-minimize/unminimize or hide/show only this isolated demo and repeat. Confirm no second prompt appears after Cancel.
- **Expected:** **An agent is still working.** (or plural count), Quit/Cancel and an interruption explanation appear before window destruction. Cancel keeps the window, scene and chips visible. Prompt behavior survives focus/hide/minimize transitions.
- **Notes:** No global banked approval may skip a later prompt; a cancelled or failed close must not authorize future termination.

#### QUI-003: Busy quit confirms once
- **Priority:** P0. **Safety:** Manual only, explicitly permits terminating all isolated test agents.
- **Preconditions:** Multiple disposable pre-existing session chips in different projects; exact demo PID and explicit quit authorization.
- **Steps:** Request quit from red close, confirm Quit and count prompts. In a separate authorized run use `⌘Q`. Inspect saved chip presentation on an authorized relaunch via TAB-007.
- **Expected:** Exactly one confirmation and the test app exits. Relaunch restores Temple chip presentation as specified by TAB-007. The owner's Temple remains untouched.
- **Notes:** Agent termination, reaping and orphan detection are outside this UI checklist; retain separate lifecycle tests. Never run in a browsing-only pass.

#### QUI-004: Failure-window exit paths
- **Priority:** P1. **Safety:** Needs care, explicitly authorized disposable failure-window run only.
- **Preconditions:** STA-003 failure variants with exact PID and frame backup.
- **Steps:** On separate launches use Quit button, red close, and Window > Close/`⌘W` when offered. Confirm target before each operation.
- **Expected:** Each path exits the failed demo process; no normal model or agents were created, no windowless menu-bar app remains. No New Window duplication route.
- **Notes:** `Scripts/check-startup-windows.sh` automates these branches but must be reviewed against run scope before invocation.

### 4.17 Performance and catalog cache smoke checks

#### PRF-001: Baseline History response
- **Priority:** P1. **Safety:** Safe in demo, browsing only.
- **Preconditions:** Base fixture; no background build competing unless recorded.
- **Steps:** Time `⌘Y` to first visible members, settled counts, query results and one bottom-to-top scroll. Repeat close/reopen and Refresh. Resize while reading if observable.
- **Expected:** Member rows appear promptly; window remains interactive, search and scrolling do not visibly stall. Record timings instead of inventing a universal millisecond threshold.
- **Notes:** A 25-row pass cannot prove 10,000-row performance. Compare same machine/build conditions.

#### PRF-002: Large-catalog responsiveness and warm reads
- **Priority:** P1. **Safety:** Needs care, generated temporary catalog only.
- **Preconditions:** Recorded synthetic 2,000 or 10,000-row fixture with realistic transcript sizes; no production data.
- **Steps:** Measure cold open, streamed progress, scrolling, rapid search/filter changes and warm Refresh. Close/reopen History, then relaunch under approved lifecycle scope and measure again.
- **Expected:** **Reading sessions on disk…** progress updates while existing rows remain usable; prepared rows appear immediately on reopen. Unchanged warm/relaunch reads improve through cache without stale counts or selection. No old-query snapshot replaces the current one.
- **Notes:** ADR-032's old 67 to 110 second 10k read is historical motivation, not an acceptance target. Use Instruments/model tests for main-thread and parse-count claims.

#### PRF-003: Cache correctness under change/failure
- **Priority:** P0. **Safety:** Needs care, fixture-only mutations and prepared failure variants.
- **Preconditions:** Warm outside-row catalog; known IDs and contents, plus member with recorded title.
- **Steps:** Using a prepared changed-catalog fixture, refresh History and inspect changed outside-row facts. Compare completed removal with a failed listing variant. Restore a member/archive state independently and reopen History.
- **Expected:** Changed outside facts refresh; shared Codex inputs are current; member title/membership/archive remain authoritative. Only completed coverage removes absent outside rows or establishes No transcript. Unreadable/mismatched candidate is not proof of absence. Cache fallback never breaks browsing or silently joins rows.
- **Notes:** ADR-029/032. This scenario checks visible catalog consistency only. Cache mutation, parse reuse, filesystem timestamp edge cases and corruption recovery belong to integration tests.

## 5. Regression watch list

Status is dated 2026-10-05. Preserve failed results even if a workaround lets the pass continue. Update status only with a linked fix and a fresh reproduction result.

| Watch item | Status/evidence | Required retest |
|---|---|---|
| Sidebar rows under traffic lights or 52-point visual/hit-target offset | Historical shipped regressions; detail-pane measurement/overlay modifiers and SDK linkage implicated | WIN-003/004, SID-001/004, SET-003, APP-001; scroll with every main surface |
| Titlebar zoom immediately bounces back | Historical bug; not reproduced on launcher or History maximize in first pass | WIN-001/002, immediate and delayed frame |
| History's second titlebar double-click fails to restore | Fixed and retested on ce90dbd, Pass 2, before and after tiling | WIN-002, ordinary sequence before tiling |
| History pushes sidebar left around 900-point window width | Historical overflow regression; first pass passed at approximately 901, exact minimum unproven | WIN-003/005, pane-width tiers and left margins |
| Notice obscures bottom rows or View fails to dismiss | First pass passed message layout, View and bottom reachability | AUT-001/002, SID-001 |
| Restore's advertised keyboard Undo edits old search text | Fixed in Pass 2; Pass 3 focused release-query undo/redo passed; unfocused field trial unproven | HIS-009/010, direct shortcut first, workaround separately |
| Palette immediate typing reaches underlying History field | Fixed in Pass 2 and retested in Pass 3; prior-field focus return also passed | PAL-004/006, immediate input, dismissal and panel switching |
| Archived shortcut toggles to launcher | First pass flagged low; resolved as expectation mismatch in current FEATURES/ADR-031, no code-fix claim | HIS-001, preserve chip and previous-tab semantics |
| Search history bridge absent for deploy | Fixed in Pass 2; Pass 3 verified trailing endpoint bridge alongside renamed match | PAL-002 with and without active matches |
| Restore looks disabled when unselected | UX observation, not a confirmed functional bug | APP-001 and HIS-009 in both appearances |
| Tool drag failure or missing modifier click mistaken for app failure | First pass limited coverage; exact minimum, literal Command-click and archive redo were unverified | WIN-003, SID-007, HIS-007; label substitutions |
| User archive/restore loses pins, reasons or project scope | High-impact state invariant | ARC-001/002/003, HIS-009/010 |
| File loss/read failure erases rows or falsely archives | Historical architectural failure mode, ADR-029/030/032 | SID-009, AUT-006, HIS-017, PRF-003 |
| Quitting closes window before Cancel, asks twice, or hangs with no processes | Historical shipped bugs from AGENTS.md | QUI-001/002/003, including hidden/minimized/exited states |
| First CLI probe failure permanently selects stale candidate | Historical shipped bug | STA-004, SET-002; reason and retries retained |
| Chip shows an incorrect title or stale status | Temple presentation regression guard; queue/drain tests stay outside this document | TAB-004, TER-004/006 |
| Bundled launch misses a SwiftPM-only fix or logging setup | Two independent entry points | STA-002 and bundled startup-failure checks |
| Tab strip shifts, clips active chip, or loses project scroll position | Current implementation regression guard | TAB-003 during close, reorder, resize and sidebar toggle |
| Renaming hides original-title search matches | Fixed and retested in Pass 3, UI-2026-10-05-01; run HEAD e2bda2e | SID-005, PAL-001, HIS-004; rename orders and search endpoint |
| Shortcuts overlay overflows and shifts content into titlebar | Fix verified at 1000 by 700 in Pass 3, UI-2026-10-05-02; original 901 by 653 retest pending | KEY-002 at 901 by 653; inspect both overlay ends and underlying rail |

| Panel dismissal loses the previous typing target | Pass 3 palette/picker return to History caret passed; chooser Cancel return passed | PAL-006, HOM-004 |
| Immediate History opening drops initial characters | Open observation, low, UI-2026-10-05-03; one trial, not yet reproduced | HIS-018, immediate versus settled focus |

## 6. How to evolve this document

Every user-visible change adds or updates its scenarios in the same commit as the change. Cover the entry point, resulting state, cancellation/undo path, keyboard focus, narrow layout and appearance where applicable. Add a synthetic fixture or explicitly document why a scenario remains manual or skipped. Never reach for production data to fill a coverage gap.

Keep IDs stable. Allocate the next unused number within the relevant prefix; never renumber or reuse retired IDs. To retire one, keep its heading and record the retirement date, reason and replacement ID, removing executable steps that would now be misleading. Split a growing scenario by retaining the original ID for its original behavior and allocating new IDs for additions.

Keep exact copy, counts, thresholds, shortcuts and safety labels synchronized with source changes. If FEATURES, an ADR and code disagree, record the discrepancy and resolve the intended behavior; do not silently promote one run's observation into the expected result. Later ADRs supersede earlier wording. Date known bugs, link their issues/fixes when available, and distinguish fixed-and-retested from merely not reproduced.

Before publishing an updated checklist, verify unique IDs, every scenario's priority/safety/preconditions/steps/expected/notes, coverage of the app-UI portion of the feature inventory, links and fixture arithmetic. Do not replace a skipped unsafe scenario with an unsafe workaround. Keep baseline setup usable without starting a CLI or changing settings.

### Active scenario inventory

| Area | Active scenarios |
|---|---:|
| 4.1 Launch and startup | 4 |
| 4.2 Window and title bar | 5 |
| 4.3 Sidebar and index | 10 |
| 4.4 Automatic archive and notice | 6 |
| 4.5 Launcher and creation surfaces | 4 |
| 4.6 Tabs and project navigation | 9 |
| 4.7 Command palette | 6 |
| 4.8 History | 18 |
| 4.9 Import flow | 5 |
| 4.10 Archive and restore end to end | 4 |
| 4.11 Settings, read-only | 3 |
| 4.12 Session chrome and launch-failure header | 2 |
| 4.13 Subscription usage | 2 |
| 4.14 Menus and shortcut reference | 2 |
| 4.15 Appearance | 2 |
| 4.16 Quitting UI | 4 |
| 4.17 Performance and catalog cache smoke checks | 3 |
| Total | 89 |

Retired IDs: TER-001, TER-002, TER-003, TER-005. Their reserved headings remain in Section 4.12.

### Changelog

- **2026-10-05:** Created from FEATURES.md, AGENTS.md, ADR-017/028/029/030/031/032, the demo fixture and launch scripts, current TempleUI implementation, and the first computer-use plan/report. Preserved open focus/zoom findings, corrected the Archived-toggle and palette-bridge expectations, and separated safe demo coverage from isolated live-agent tests. This initial scope was narrowed in Pass 2.
- **2026-10-05, Pass 2:** Exercised the owner-prepared ce90dbd demo with Computer Use. Restricted all scenarios to Temple app UI, retired TER-001/002/003/005, added SID-010, corrected rename-sheet, palette-bridge, Settings-card and selection instructions, marked today's fixes retested, and recorded two new regressions plus explicit coverage gaps. Active scenario count: 89 before, 86 after; four retired IDs retained.

- **2026-10-05, Pass 3:** Replaced the blocked entry with the partial hands-on run against demo PID 50265, HEAD `e2bda2e`. Verified original-title search, palette isolation/focus return, focused Restore undo and scrollable Shortcuts at 1000 by 700. Added PAL-006, HOM-004 and HIS-018. Recorded one immediate-History-input observation and the second screen lock that stopped testing and cleanup.

## 7. Result log

### 2026-10-05, Pass 2

- **Build:** `ce90dbd` (`git rev-parse --short HEAD`), owner-supplied bundled build from main. Binary: `/Users/sriram/Projects/active/temple/dist/Temple.app/Contents/MacOS/Temple`. No build, code edit or commit performed; another agent was working in the checkout. The commit identifies HEAD, not an independently verified binary hash.
- **Runner:** gpt-6-astra computer use, native Computer Use accessibility observations and screenshots. Screen was unlocked. Target bound by exact demo bundle path and checked against PID **93666**, never selected by the shared Temple name. Owner's `/Applications` instance was not operated.
- **Fixture:** Owner-prepared fresh fake demo, six named projects, settled 25 total / 22 in Temple / 3 archived. Legacy dates displayed Sep 26, Sep 15 and Aug 21 at 20:13 for this seed. No fixture files changed; no session started, resumed or imported.
- **Appearance/geometry:** Current dark rendering; Settings showed System, inspected only. Screenshots were 2x. Tested approximately 1000×700, 1470×923 zoomed and 901×653 Top Left tiled. Window > Move & Resize > Return to Previous Size returned the demo to 1000×700. No system preferences changed.
- **Evidence:** Live AX trees and screenshots are in the computer-use conversation. No standalone screenshot files or external issue links were created. UI text containing an em-dash is paraphrased to preserve this document's style rule.
- **Interpretation:** PASS means the scenario's executable coverage was completed. SKIP includes partial runs, with the successful subchecks stated; any observed defect is FAIL even if other branches were skipped. “Differs from doc” identifies corrected instructions or changed product behavior, not an additional outcome category.

**Scenario totals:** 8 PASS, 4 FAIL, 74 SKIP across 86 active scenarios. Four failures represent two unique bugs. Four retired scenarios have no executable coverage and are listed separately. These conservative totals do not count passing subchecks inside SKIP rows as complete passes.

| ID | Result | Actual result, difference or skip reason |
|---|---|---|
| STA-001 | SKIP | Already-running owner-prepared instance only. Observed launcher and settled 25/22/3 baseline; did not launch or time initial row arrival. |
| STA-002 | SKIP | No SwiftPM comparison or second launch authorized. |
| STA-003 | SKIP | No prepared failure window; no launch or database edits allowed. |
| STA-004 | SKIP | No controlled failing-toolchain fixture; no Settings changes. |
| WIN-001 | SKIP | Launcher blank-band double-click zoom and reverse passed, including stable later capture. Window-move drag not exercised. |
| WIN-002 | SKIP | History zoom/reverse passed at normal geometry and after Top Left tiling. No real-session chip variant permitted. Today's History fix is retested. |
| WIN-003 | SKIP | Layout observed at approximately 901×653, 1000×700 and 1470×923. Traffic lights and sidebar aligned outside Shortcuts. Exact minimum and sidebar bounds unproven; splitter drag did not resize. |
| WIN-004 | SKIP | ⌘B collapse/reopen passed on launcher; controls moved beside traffic lights and notice remained. Drag-hover and animation-frame branches not exercised. |
| WIN-005 | SKIP | Wide one-row, compact two-row and narrow merged-filter tiers observed; Restore stayed visible. Exact below-600 detail tier and every search/scroll combination untested. |
| SID-001 | PASS | Show 3 more revealed all nine acme-api rows; Show fewer and group fold/unfold worked. Both dotfiles rows reached above notice/footer. |
| SID-002 | SKIP | Base fixture has only five active projects and nine rows in its largest project. |
| SID-003 | SKIP | Arrow input did not open a chip, but moving highlight was not conclusively captured; no unsafe Return workaround used. |
| SID-004 | SKIP | Magnifier search deploy showed staging row; replacing with orders worked; Esc cleared/closed. Hidden-rail focus, × and empty-blur branches not exercised. |
| SID-005 | FAIL | Rename session sheet with Name, Cancel and Save; Return saved UI regression orders. PINNED, Unpin and empty-name reset worked. Original-title endpoint and cart is empty no longer matched after rename: UI-2026-10-05-01. Cancel branch untested. |
| SID-006 | SKIP | Closed-session and project menu labels inspected, including horizontal color swatches. Copy, Finder and live-tab menu branches deliberately not invoked. |
| SID-007 | SKIP | Project reordering and persistence not attempted; relaunch prohibited. |
| SID-008 | SKIP | No external/noise/partial-write fixture; only base fake rows available. |
| SID-009 | SKIP | Restored release-script row returned under legacy-tools with “Transcript missing: the session file is no longer on disk”. Search/refresh persistence branch not completed before undo. |
| SID-010 | PASS | Blue sidebar capsule appeared in project and PINNED copies, with matching palette wash. Unpin and uncolored swatch restored initial metadata; no session opened. |
| AUT-001 | SKIP | Exact notice “3 sessions archived: no transcript on disk”, View, Undo and × observed. Bottom rows accessible and notice survived sidebar hide/show. Sidebar-width variant untested. |
| AUT-002 | SKIP | View dismissed notice and opened Archived with “Archived just now · 3” and “Showing 3 of 25”; all legacy rows had No transcript and Restore. Esc cleared chip. Direct chip × and a fresh-run scope change untested. |
| AUT-003 | SKIP | Single initial notice was consumed by View. No reseed or relaunch allowed. |
| AUT-004 | SKIP | Single initial notice was consumed by View, so notice × was not exercised. |
| AUT-005 | SKIP | No fixture files changed in this pass. |
| AUT-006 | SKIP | Guard, missing-folder and uncertain-evidence fixture variants unavailable. |
| HOM-001 | SKIP | “Where agents answer the call.”, GET STARTED, RECENT PROJECTS and five fake project rows observed. Home, History and palette routes worked; not every launcher link was clicked. |
| HOM-002 | SKIP | Creation pickers and folder chooser not opened in this restricted pass. |
| HOM-003 | SKIP | Starting sessions prohibited; no isolated real-session fixture. |
| TAB-001 | SKIP | Opening/resuming sessions prohibited. |
| TAB-002 | SKIP | History/Settings singleton behavior and ⌘W close/reopen passed. Utility-chip drag and close × branch not exercised. |
| TAB-003 | SKIP | Requires real or restored session chips; activation/resume and quitting were prohibited. No such fixture supplied. |
| TAB-004 | SKIP | Requires real or restored session chips; activation/resume and quitting were prohibited. No such fixture supplied. |
| TAB-005 | SKIP | Requires real or restored session chips; activation/resume and quitting were prohibited. No such fixture supplied. |
| TAB-006 | SKIP | Requires real or restored session chips; activation/resume and quitting were prohibited. No such fixture supplied. |
| TAB-007 | SKIP | Requires real or restored session chips; activation/resume and quitting were prohibited. No such fixture supplied. |
| TAB-008 | SKIP | Requires real or restored session chips; activation/resume and quitting were prohibited. No such fixture supplied. |
| TAB-009 | SKIP | Requires real or restored session chips; activation/resume and quitting were prohibited. No such fixture supplied. |
| PAL-001 | FAIL | Empty palette invited typing; deploy showed only active staging session plus trailing bridge. Custom title matched, original endpoint query failed after rename: UI-2026-10-05-01. × reset branch untested. |
| PAL-002 | PASS | With deploy result present, clicked “Search history for “deploy”” and obtained two History rows. Sole retire it bridge activated with Return and showed archived runbook in All. No session opened. Differs from Pass 1 document, which omitted bridge when matches existed. |
| PAL-003 | SKIP | Session-result activation prohibited. |
| PAL-004 | PASS | Repeated immediate ⌘K then typing placed the complete query in palette; underlying History query stayed unchanged. Focused-input comparison also worked. First-pass race not reproduced. |
| PAL-005 | SKIP | ⌘Y over palette on History dismissed only the palette, leaving History visible. Full switcher/Shortcuts/hover matrix not completed; Shortcuts layout failure tracked under KEY-002. |
| HIS-001 | PASS | ⌘Y and ⌘⇧Y toggled active destinations to home while retaining History chip, then reopened. Archived retained filters. ⌘Y over History palette dismissed only the palette. |
| HIS-002 | PASS | All 25, In Temple 22, Archived 3, Not in Temple 0. Header stayed “25 sessions · 22 in Temple · 3 archived”. Empty outside copy: “Everything on disk is in Temple.” and “Sessions from other terminals appear here the next time this page refreshes.” |
| HIS-003 | SKIP | Agent marks, dates, main branch, No transcript and Restore observed; older legacy groups reached by scrolling. Full tooltip and sticky-header selection matrix untested. |
| HIS-004 | FAIL | deploy yielded two; impossible query showed “No sessions match” with query. Session-ID bridge yielded one. endpoint yielded zero after custom rename, one after clearing name: UI-2026-10-05-01. Branch/last-message/prefix and clear-control matrix incomplete. |
| HIS-005 | SKIP | Claude Code (23), Codex (2), six projects observed; Codex yielded 2, plus acme-api 1, reset agent 9. Narrow merged-menu selection and scope-retention branch untested. |
| HIS-006 | SKIP | Some plain arrows sent, but full selection/day/end/modifier matrix not verified. |
| HIS-007 | SKIP | Filtered acme-api ⌘A produced “9 selected · all in Temple” and Archive 9; Esc deselected. No supported Command-click; Shift+Down fallback did not establish a range. |
| HIS-008 | SKIP | Four-stage Esc ladder passed: query, chip, selection, then home. Scope stayed Archived. Pre-debounce rapid-input variant not separately timed. |
| HIS-009 | PASS | Release-script Restore: “1 session restored”, 23/2. Immediate ⌘Z: “Restore undone”, 22/3 and query unchanged; ⌘⇧Z: 23/2. Returned to 22/3 with undo. Fixed focus route retested after prior search edits. |
| HIS-010 | SKIP | Base ⌘A branch passed: “3 selected · all archived”, Restore 3, Deselect, Return/Esc hints; “3 sessions restored”, 25/0, “Nothing archived”. Immediate undo/redo passed; ended 22/3. Two-row and mixed branches not covered. |
| HIS-011 | SKIP | Return dispatch on session rows deliberately avoided; only confirmed palette History bridge received Return. |
| HIS-012 | SKIP | Archive 9 bar inspected but not activated. History bulk archive and ⌘⌫ text boundary not exercised; sidebar archive tested separately. |
| HIS-013 | SKIP | Sidebar search owned typing and ⌘A replacement; Esc closed it without History selection. Rename Return committed only metadata. No outside row existed for import-sheet key routing. |
| HIS-014 | SKIP | Archived context Restore, Restore project storefront and Show only storefront inspected; project filter action worked. Clipboard and outside-row variants not exercised. |
| HIS-015 | SKIP | Session Show in History produced full-ID query, All and one row, clearing project/agent filters. Project bridge invoked; separate stable capture and Show in sidebar hidden-row matrix incomplete. |
| HIS-016 | SKIP | Refresh/⌘R stayed responsive and showed Updated just now. Utility navigation preserved filter; ⌘W close/reopen reset to All/Any agent/Any project/empty query. No new external fixture row added. |
| HIS-017 | SKIP | All-archive restore showed “Nothing archived”. Restored project while filtered showed “No archived sessions in storefront” and “Show all archived”. Failed-store, first-read and stale-action variants unavailable. |
| IMP-001 | SKIP | Not in Temple was empty; no outside fixture added. Import confirmation was prohibited, so dependent import/undo/error flows were not run. |
| IMP-002 | SKIP | Not in Temple was empty; no outside fixture added. Import confirmation was prohibited, so dependent import/undo/error flows were not run. |
| IMP-003 | SKIP | Not in Temple was empty; no outside fixture added. Import confirmation was prohibited, so dependent import/undo/error flows were not run. |
| IMP-004 | SKIP | Not in Temple was empty; no outside fixture added. Import confirmation was prohibited, so dependent import/undo/error flows were not run. |
| IMP-005 | SKIP | Not in Temple was empty; no outside fixture added. Import confirmation was prohibited, so dependent import/undo/error flows were not run. |
| ARC-001 | SKIP | Pinned orders archive removed Pinned; undo restored pin; redo produced 21/4 and an archived row without No transcript; undo returned 22/3. Palette exclusion and Edit menu label not separately inspected. |
| ARC-002 | SKIP | Basic storefront mask/Restore project/undo/redo passed: 17/8 then 22/3, “storefront is archived”, “storefront restored”. Project tooltip promised every session not archived individually. Prior individual-archive/pin preservation branch not prepared. |
| ARC-003 | PASS | After storefront archive (17/8), checkout Restore alone yielded 18/7 and only checkout in sidebar. Undo returned 17/8; redo returned 18/7. Undid again before whole-project restoration. |
| ARC-004 | SKIP | No open/restored chips or external activity fixture; session activation forbidden. |
| SET-001 | SKIP | ⌘, twice opened one inline Settings chip. AGENTS, CLAUDE CODE, CODEX and APPEARANCE observed; font belongs in APPEARANCE. Scrolled and closed with ⌘W. Launcher/gear entry paths not both exercised. Differs from old separate Terminal-card expectation. |
| SET-002 | SKIP | Read Claude Code 2.1.290 and Codex 0.160.0, checked age, Check again, Command/Detected/Arguments. Empty command and override explanations matched revised expected copy. No failing candidate, retry countdown or Show output variant available. |
| SET-003 | SKIP | Read current System theme and font fallback, without edits, at narrow size. Cards wrapped normally and sidebar inset survived. Wide comparison and every warning variant not run. |
| TER-001 | SKIP | Retired in this pass: terminal/session internals are outside scope; ID remains reserved. |
| TER-002 | SKIP | Retired in this pass: terminal/session internals are outside scope; ID remains reserved. |
| TER-003 | SKIP | Retired in this pass: terminal/session internals are outside scope; ID remains reserved. |
| TER-004 | SKIP | No prepared real-session status chips; no session lifecycle stimulation permitted. |
| TER-005 | SKIP | Retired in this pass: terminal/session internals are outside scope; ID remains reserved. |
| TER-006 | SKIP | No prepared launch-failure header; starting sessions prohibited. |
| USG-001 | SKIP | Codex footer 41% and non-overlapping gear observed, including bottom scroll. Hover breakdown not captured; card not clicked because it can refresh credentials. |
| USG-002 | SKIP | No isolated presentation/authentication fixture; no usage refresh performed. |
| KEY-001 | SKIP | Window menu inspected and safe single-window tiling/restore used. Full Temple/File/Edit/View/Project state matrix not covered. |
| KEY-002 | FAIL | At approximately 901×653, ⌘/ clipped title/first item and bottom APP section, while underlying sidebar and History moved upward under traffic lights. Scroll did not reveal hidden content; Esc restored layout. UI-2026-10-05-02. |
| APP-001 | SKIP | Dark appearance visually inspected across launcher, sidebar, palette, History and Settings. No second light-mode launch permitted; System was current read-only setting. |
| APP-002 | SKIP | Failure fixtures unavailable; no light/dark relaunch allowed. |
| QUI-001 | SKIP | Owner explicitly prohibited quitting either app. No quit, red close or failure-window close invoked. |
| QUI-002 | SKIP | Owner explicitly prohibited quitting either app. No quit, red close or failure-window close invoked. |
| QUI-003 | SKIP | Owner explicitly prohibited quitting either app. No quit, red close or failure-window close invoked. |
| QUI-004 | SKIP | Owner explicitly prohibited quitting either app. No quit, red close or failure-window close invoked. |
| PRF-001 | SKIP | History open/reopen, search/filter, Refresh and bottom-to-top scroll responded within tool observations without visible stalls. No calibrated timings collected; 25-row qualitative smoke only. |
| PRF-002 | SKIP | No large synthetic catalog or relaunch authorization. |
| PRF-003 | SKIP | No catalog-change/failure fixture; file edits prohibited. |

#### Bugs found

| Bug | Severity/status | Reproduction | Expected | Observed |
|---|---|---|---|---|
| UI-2026-10-05-01 | Medium, open on ce90dbd | Right-click orders > Rename session; save `UI regression orders`. Open palette and search `endpoint` or `cart is empty`. Use its Search history bridge. Clear the custom name and repeat. | Both custom title and original prompt remain searchable, as documented in the feature inventory. | Custom title matches, but original-title query produces only the palette bridge and History **Showing 0 of 25**, **No sessions match “endpoint”**. Empty-name reset immediately restores the original title and its one History match. Reproduced in both surfaces; no session opened. |
| UI-2026-10-05-02 | Medium, open on ce90dbd | From History, use Window > Move & Resize > Top Left (about 901×653), then `⌘/`. Inspect overlay top/bottom and underlying sidebar. Scroll over the card, then Esc. | All shortcut content remains reachable and the underlying split view retains its titlebar inset. | Card title/first item and bottom APP section are clipped. Sidebar and History content shift upward under traffic lights. Scrolling does not reveal clipped content. Esc dismisses and restores the layout. Verified at the tiled size; not established at other heights. |

These are local report identifiers, not filed issue numbers. No code fix is claimed. The first bug could require an explicit product decision if original-title search is no longer intended; until then keep the documented acceptance criterion.

#### Fixed regressions rechecked

- Restore's immediate `⌘Z` and `⌘⇧Z` changed archive state after single and three-row Restore, without editing prior search text.
- Immediate typing after `⌘K` repeatedly landed completely in the palette.
- A trailing **Search history for “deploy”** action appeared alongside an active result and opened the full History search.
- Launcher and History blank titlebar double-click toggled zoom; History also reversed after Top Left tiling. Session-chip variants were not exercised.

#### Final state and remaining coverage

Demo PID **93666** remains open at approximately **1000×700**, on the launcher, with a retained History chip, sidebar visible and original metadata restored. History was last refreshed at 25 total / 22 in Temple / 3 archived, All, Any agent, Any project and empty query. No Settings or Shortcuts panel remains open. The auto-archive notice was consumed by View and is not recreated. The initial notice's Undo/× paths require another owner-prepared run.

No frame-preference backup or restoration was performed by this runner: the owner supplied an already-running instance, and restoration while it remains running would be premature. Current geometry was returned through the demo's native menu. The owner's real Temple was left untouched. Both apps remain running; no quit was attempted.

Major gaps are import UI without outside rows, light appearance, exact minimum/splitter limits, complete keyboard and menu matrices, session-chip variants, failure windows, quitting and large-catalog timings. Tool-limited modifier clicks and drags remain SKIP, not inferred product failures.

### 2026-10-05, Pass 3

- **Build:** `e2bda2e`, obtained with `git rev-parse --short HEAD` at the start of this run. The earlier blocked entry's `1709edb` is replaced. This records checkout HEAD, not an independently proven build hash for the already-running binary.
- **Runner:** gpt-6-astra computer use, native accessibility observations and screenshots.
- **Target:** PID **50265**, executable verified as `/Users/sriram/Projects/active/temple/dist/Temple.app/Contents/MacOS/Temple`. Bound Computer Use to that exact bundle path. Fake projects and 25/22/3 baseline verified. The owner's real Temple was never targeted.
- **Safety:** Screen was unlocked at the start. No session started, resumed or imported; no Settings or system preference changed; neither app quit. Only this document edited, no commits. No real session stores read.
- **Outcome:** Partial run, interrupted by a second screen lock during cleanup. The tool returned `cgWindowNotFound`; a read-only session-state check confirmed `CGSSessionScreenIsLocked=Yes`. All further UI actions stopped immediately. The window-access failure is not classified as an app bug.
- **Evidence:** AX trees and screenshots in this conversation, no standalone screenshot files. The demo was about 1000×700 (2000×1400 screenshots at 2x) in dark appearance. A temporary off-screen/right-edge crop and tool notices that the user changed the app complicated context-menu actions; fresh AX menu selection eventually opened Rename correctly. No product failure inferred from those transient tool events.
- **Results policy:** SKIP includes partial scenarios with their passing subchecks stated. A failed subcheck is FAIL. Fix verification can succeed for its exact subcheck even when the broader scenario is SKIP. No prior-pass result is counted as a new pass.

**Totals:** 2 PASS, 1 FAIL, 86 SKIP across 89 active scenarios. The single FAIL is a low-severity, single-observation input-loss finding awaiting reproduction. Four retired IDs remain excluded.

| ID | Result | Observation or reason |
|---|---|---|
| STA-001 | SKIP | Owner-prepared instance was already running. Verified fake projects and 25 total / 22 in Temple / 3 archived; no startup timing or launch performed. |
| STA-002 | SKIP | No second binary, startup-failure or toolchain fixture run; existing demo only, no relaunch. |
| STA-003 | SKIP | No second binary, startup-failure or toolchain fixture run; existing demo only, no relaunch. |
| STA-004 | SKIP | No second binary, startup-failure or toolchain fixture run; existing demo only, no relaunch. |
| WIN-001 | SKIP | No zoom/drag retest before screen lock; original 1000 by 700 geometry retained. |
| WIN-002 | SKIP | No zoom/tiling retest before screen lock; no session-chip variant allowed. |
| WIN-003 | SKIP | At 1000 by 700 the sidebar remained below the titlebar with History, palette, picker and Shortcuts. Minimum, split bounds, Settings and 901-point checks not reached. |
| WIN-004 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| WIN-005 | SKIP | 1000-point full-window History showed search above scopes/filters. Other responsive tiers and narrow Restore visibility not rechecked. |
| SID-001 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| SID-002 | SKIP | Required extended or failure fixture not supplied; no fixture files changed. |
| SID-003 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| SID-004 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| SID-005 | SKIP | Rename session sheet saved UI regression orders. Original endpoint matched that renamed row in palette and History; fix verified. Pin appeared and archive undo restored membership/pin. Cleanup Unpin was interrupted by screen lock; empty-name reset and Cancel not completed. |
| SID-006 | SKIP | Inspected Open, Rename session, Pin/Unpin, Archive session, copy/reveal/History items and color swatches. Menu activation intermittently failed through the tool, then worked using fresh AX item. No clipboard/Finder operations. |
| SID-007 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| SID-008 | SKIP | Required extended or failure fixture not supplied; no fixture files changed. |
| SID-009 | SKIP | Restore briefly returned legacy-tools under the sidebar while membership rose to 23/2. Full tooltip/refresh persistence check not completed before undo. |
| SID-010 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| AUT-001 | SKIP | Initial “3 sessions archived: no transcript on disk”, View, Undo and × visible above footer at 1000 by 700. Scrolling, narrow-width and collapse branches not rerun. |
| AUT-002 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| AUT-003 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| AUT-004 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| AUT-005 | SKIP | Required extended or failure fixture not supplied; no fixture files changed. |
| AUT-006 | SKIP | Required extended or failure fixture not supplied; no fixture files changed. |
| HOM-001 | SKIP | Initial launcher fake-project baseline observed; all safe launcher links not rerun. |
| HOM-002 | SKIP | ⌘K then ⌘N displayed “New Claude Code session in project…”; typing acme filtered picker and Esc returned to History. No result activated. Other-agent/header-plus branches not tested. |
| HOM-003 | SKIP | Starting a session prohibited by this run. |
| HOM-004 | SKIP | Shortcuts swallowed LEAK without changing History. ⌘O replaced it with native Open chooser; Search accepted temple-ui-no-folder, Open disabled, Cancel returned to History and afterchooser appended to query. Palette/picker chooser variants not reached. |
| TAB-001 | SKIP | Requires session chips, resume or quitting; prohibited or unavailable in this demo pass. |
| TAB-002 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| TAB-003 | SKIP | Requires session chips, resume or quitting; prohibited or unavailable in this demo pass. |
| TAB-004 | SKIP | Requires session chips, resume or quitting; prohibited or unavailable in this demo pass. |
| TAB-005 | SKIP | Requires session chips, resume or quitting; prohibited or unavailable in this demo pass. |
| TAB-006 | SKIP | Requires session chips, resume or quitting; prohibited or unavailable in this demo pass. |
| TAB-007 | SKIP | Requires session chips, resume or quitting; prohibited or unavailable in this demo pass. |
| TAB-008 | SKIP | Requires session chips, resume or quitting; prohibited or unavailable in this demo pass. |
| TAB-009 | SKIP | Requires session chips, resume or quitting; prohibited or unavailable in this demo pass. |
| PAL-001 | SKIP | Renamed UI regression orders matched original endpoint in palette, with trailing Search history action. Empty-state/custom-query/reset matrix not completed. |
| PAL-002 | SKIP | Clicked “Search history for “endpoint”” alongside an active renamed result. History opened All, endpoint, “Showing 1 of 25”, with UI regression orders. Deploy and sole-no-match Return variants not rerun. |
| PAL-003 | SKIP | Session-result activation prohibited. |
| PAL-004 | PASS | Immediate ⌘K then endpoint delivered the complete string to palette while underlying History stayed ploy. Later immediate deploy typing remained isolated; no split query or panel-induced typing lockout observed. |
| PAL-005 | SKIP | Palette replaced by ⌘N picker and Shortcuts dismissed by ⌘O. Full History-command, project-switcher and underlying-hover matrix not reached. |
| PAL-006 | PASS | Esc from typed palette appended XYZ to prior ploy query; repeated palette/type/Esc appended tail. ⌘K then ⌘N accepted acme in picker; Esc then back appended to History. Previous query and end caret preserved, with no extra session chip. |
| HIS-001 | SKIP | Opened History with ⌘Y; singleton toggle, Archived toggle and palette-over-History command matrix not rerun. |
| HIS-002 | SKIP | Header baseline 25/22/3 and Archived three rows observed. All four partitions not rechecked. |
| HIS-003 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-004 | SKIP | Original-title endpoint search found renamed orders, “Showing 1 of 25”. release matched the pruned release-script row in Archived. Full field/search/clear matrix not rerun. |
| HIS-005 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-006 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-007 | SKIP | ⌘A while editing History query did not replace query on subsequent typing, consistent with History view-selection routing. No complete selection-bar or modifier-click verification. |
| HIS-008 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-009 | SKIP | With focused search release, Restore yielded 23/2 and “1 session restored”; immediate ⌘Z returned 22/3 and “Restore undone”; redo 23/2, query unchanged. Repeated after Tab and undo worked, but Tab may have selected text rather than removed focus. Unfocused branch remains unverified. Later typing X worked; returned to 22/3. |
| HIS-010 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-011 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-012 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-013 | SKIP | Rename sheet accepted text and Return saved only metadata; no session launched. Sidebar foreign-field/import-sheet matrix not run. |
| HIS-014 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-015 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-016 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-017 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| HIS-018 | FAIL | First launcher ⌘Y followed immediately by typeText(deploy) produced History query ploy. No panel was open. One observation only; screen lock prevented controlled repetition and immediate-versus-waited comparison. UI-2026-10-05-03, low, attribution unconfirmed. |
| IMP-001 | SKIP | No outside-row fixture and import prohibited. No Import confirmation or session activation. |
| IMP-002 | SKIP | No outside-row fixture and import prohibited. No Import confirmation or session activation. |
| IMP-003 | SKIP | No outside-row fixture and import prohibited. No Import confirmation or session activation. |
| IMP-004 | SKIP | No outside-row fixture and import prohibited. No Import confirmation or session activation. |
| IMP-005 | SKIP | No outside-row fixture and import prohibited. No Import confirmation or session activation. |
| ARC-001 | SKIP | Archived pinned renamed orders, then undo/redo/undo. Redo showed 21/4 with Restore; final undo returned 22/3 and PINNED with UI regression orders. Palette exclusion and Edit label not checked; cleanup interrupted. |
| ARC-002 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| ARC-003 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| ARC-004 | SKIP | No isolated open-chip or archived-activity fixture; session activation prohibited. |
| SET-001 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| SET-002 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| SET-003 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| TER-004 | SKIP | No permitted session/status/failure-header fixture; no session launched. |
| TER-006 | SKIP | No permitted session/status/failure-header fixture; no session launched. |
| USG-001 | SKIP | Footer 41% observed; hover breakdown not tested and refresh not clicked. |
| USG-002 | SKIP | No isolated usage-error presentation fixture; no refresh or credential interaction. |
| KEY-001 | SKIP | Not reached before the second screen lock; no result inferred from earlier passes. |
| KEY-002 | SKIP | At 1000 by 700, Keyboard Shortcuts title and first commands fit; scrolling reached final APP/Quit entry. Sidebar and History stayed below titlebar. Typed LEAK did not reach History. Original 901 by 653 size and Esc/exclusivity matrix incomplete before lock. |
| APP-001 | SKIP | Current dark appearance observed for launcher, History and panels. No light-mode launch or Settings changes allowed. |
| APP-002 | SKIP | No failure-window/header fixture or appearance relaunch. |
| QUI-001 | SKIP | Owner prohibited quitting either app; no quit or red window close attempted. |
| QUI-002 | SKIP | Owner prohibited quitting either app; no quit or red window close attempted. |
| QUI-003 | SKIP | Owner prohibited quitting either app; no quit or red window close attempted. |
| QUI-004 | SKIP | Owner prohibited quitting either app; no quit or red window close attempted. |
| PRF-001 | SKIP | History/palette queries, original-title bridge and Restore results updated within observations without visible persistent stall. No calibrated timing, full scroll or refresh run. |
| PRF-002 | SKIP | Required extended or failure fixture not supplied; no fixture files changed. |
| PRF-003 | SKIP | Required extended or failure fixture not supplied; no fixture files changed. |

#### Full regression watch-list disposition

| Watch item | Pass 3 disposition |
|---|---|
| Sidebar/titlebar inset | Passed observed 1000×700 History and panel states; scroll/Settings/minimum variants skipped. |
| Immediate zoom bounce | SKIP, lock interrupted planned geometry checks. |
| History second double-click after tiling | SKIP, no zoom/tiling action performed. |
| History overflow near 900 points | SKIP, no 901-point resize reached. |
| Notice covers rows or View fails to dismiss | Notice fit initial 1000×700 view; scrolling and View skipped. |
| Restore undo edits prior search | Focused release-query Restore/undo/redo passed. Unfocused branch unproven. |
| Palette immediate typing leaks to History | Passed; full endpoint arrived in palette, History unchanged. |
| Archived shortcut toggles away | SKIP, established expectation unchanged. |
| Search history bridge missing with active matches | Passed endpoint variant with renamed active result. |
| Unselected Restore looks disabled | Control remained readable and worked; light appearance skipped. |
| Tool drag/modifier limitations | No new coverage; no failed synthetic gesture promoted to product defect. |
| Archive loses pins/reasons/project scope | Pinned session archive undo/redo returned expected counts and pin; project mask branch skipped. |
| Missing/read-failed files erase or archive rows | SKIP, no fixture variants or file edits. |
| Quit Cancel/double prompt/empty-process hang | SKIP, quitting prohibited. |
| First CLI probe failure sticks | SKIP, no controlled detection fixture. |
| Chip stale title/status | SKIP, no session-chip fixture. |
| Bundled versus SwiftPM parity | SKIP, bundled instance only. |
| Tab strip overflow/project scroll | SKIP, no session-chip fixture. |
| Renaming hides original-title search | Fixed and verified in both palette and History. |
| Shortcuts overflow/inset | Fix verified at 1000×700, including scroll to final entry; original 901×653 size pending. |
| Panel dismissal loses typing target | Palette and picker Esc, plus chooser Cancel, returned typing to History's prior query end. |
| Immediate History query loses characters | One failure: deploy became ploy; repetition pending. |

#### Findings and fix status

- **UI-2026-10-05-01: fixed and retested.** Rename orders to `UI regression orders`; palette query `endpoint` finds that renamed row. Clicking **Search history for “endpoint”** opens History All with **Showing 1 of 25** and the renamed title. No session opened.
- **UI-2026-10-05-02: fix verified at 1000×700, original smaller-size retest pending.** Shortcuts now has a visible title and scrollable body. Scroll reached APP and the final Quit entry without shifting History/sidebar beneath the traffic lights. Screen lock prevented the planned 901×653 repetition, so this is not a claim of complete small-window coverage.
- **UI-2026-10-05-03: low, open observation, attribution unconfirmed.** Repro observed once: from launcher press `⌘Y`, then immediately type `deploy` without a focus wait. History displayed `ploy`, dropping the first two characters. Expected full query. Later focused input worked, and no persistent inability to type was found. Repeat with controlled immediate and settled-focus trials before attributing this to the app rather than synthetic input timing. This is separate from the accepted initial-character drop for newly presented panels.
- **Panel/chooser focus:** `⌘K` immediate input never split into History. Palette Esc and palette-to-picker Esc returned to the prior query end. Shortcuts swallowed ordinary text. `⌘O` from Shortcuts removed the panel before opening the native chooser; its Search accepted text and Cancel returned typing to History. Palette/picker-to-chooser variants remain untested.
- **Restore focus:** Focused History search stayed `release` through Restore, Undo and Redo. A second trial after Tab also undid Restore and accepted later typing, but did not establish that History search had truly lost focus. No claim is made about foreign editable fields or the unfocused branch.

#### Final state and cleanup still required

Both apps were left running. Demo geometry was approximately **1000×700** throughout; no resize or frame-preference restoration was performed. The last confirmed demo membership was **25 total / 22 in Temple / 3 archived**, with History All searching `endpoint`. The original auto-archive notice remained visible. No session chips were created.

The orders row remains custom-named **UI regression orders**. It was pinned in the last confirmed AX state. An attempted **Unpin** returned `cgWindowNotFound` as the screen locked, so whether that action completed is unknown. The context menu may remain open. After unlocking, verify the current demo PID and fake names, dismiss any menu, inspect pin state and remove the temporary pin if present, then clear the custom Name through Rename session and Save. Clear History search if restoring the browsing baseline. Do not use Open or resume the row. No cleanup input was sent to the locked screen.

This run replaces the earlier blocked Pass 3 entry rather than adding a second Pass 3 heading. The outstanding smaller-window, full-watch-list and remaining safe-scenario checks require a further unlocked run; their SKIP results are preserved explicitly.
