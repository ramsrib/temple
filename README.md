# Temple

**Where agents answer the call.**

Temple is a native macOS app that turns your CLI coding agents — **Claude Code**
and **Codex** — into something like a chat app. Every session you've ever run
becomes a resumable conversation, organized by project. Click one and a real
terminal opens, resumed exactly where you left off.

- **All your sessions, one place** — Temple reads the agents' own on-disk
  session stores and builds a live, searchable index. New sessions appear
  within a second, wherever they were started.
- **Real terminals, not transcripts** — each session runs in an embedded
  [Ghostty](https://ghostty.org) terminal (GPU-rendered, Metal). Type straight
  into your agent.
- **Per-project tabs in the title bar** — the tab strip shows the project
  you're working in; switching projects never kills the others.
- **Honest activity states** — green means the agent is actually working, gray
  means it's waiting for you, orange means it needs attention. Closing a busy
  agent asks first.
- **Keyboard-first** — ⌘K to jump to any session, ⌘T for a new one, ⌘B for the
  sidebar, ⌘/ to see everything else.
- **Native and quiet** — monochrome chrome, light/dark theme (the terminal
  follows), no Electron, no cloud, no accounts. Your sessions never leave your
  machine.

Temple never edits your files, never runs git, and never touches the session
contents — the CLIs' own files remain the source of truth.

## Install

```sh
brew install --cask ramsrib/tap/temple
```

Or grab the latest `Temple-vX.Y.Z-arm64.dmg` from
[Releases](https://github.com/ramsrib/temple/releases) and drag **Temple** to
Applications.

Builds are Developer ID–signed and notarized by Apple, so they open normally —
no Gatekeeper warnings, no right-click dance. Updates come through Homebrew:

```sh
brew upgrade --cask temple
```

**Requirements:** macOS 14+ on Apple Silicon, with
[Claude Code](https://claude.com/claude-code) and/or
[Codex](https://github.com/openai/codex) installed. Temple auto-detects both
(paths configurable in Settings).

## Build from source

```sh
./Scripts/build-ghostty.sh   # one-time: builds the embedded terminal engine
make install                 # signed Temple.app → /Applications
```

Needs Xcode 26+ and `brew install xcodegen`. Zig is self-provisioned at the
pinned version. Terminal-engine details in
[docs/BUILDING-GHOSTTY.md](docs/BUILDING-GHOSTTY.md); cutting a signed,
notarized release is in [RELEASE.md](RELEASE.md).

## Learn more

- **Features & roadmap:** [docs/FEATURES.md](docs/FEATURES.md)
- **Architecture decisions:** [docs/DECISIONS.md](docs/DECISIONS.md)
- **Session storage formats:** [docs/SESSION-FORMATS.md](docs/SESSION-FORMATS.md)
- **Cutting a release:** [RELEASE.md](RELEASE.md)

Debug logging, if you ever need it:
`log stream --predicate 'subsystem BEGINSWITH "com.sriramb.temple"' --level debug`

## License

[MIT](LICENSE)
