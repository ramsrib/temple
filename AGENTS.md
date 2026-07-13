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

- **`make demo` isolates the stores and state dir, but NOT `UserDefaults`.**
  `TEMPLE_CLAUDE_ROOT` / `TEMPLE_CODEX_ROOT` / `TEMPLE_STATE_DIR` are redirected;
  the settings domain is not. Anything that writes a setting — including a
  first-launch defaults migration — hits his real preferences. Say so before you
  run it.

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
