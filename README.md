# Temple

**Where agents answer the call.**

Temple is a native macOS session manager for Claude Code and Codex. It finds
every session you have ever run, groups them by project, and lets you search
them. Click one and it resumes in a real terminal, right where you left off.

- **Every session in one place.** Temple reads the session files the agents
  already write, so nothing is lost. Sessions you start elsewhere show up
  within a second.
- **Real terminals.** Each session runs in an embedded
  [Ghostty](https://ghostty.org) terminal. You type straight into your agent,
  the same as in any terminal.
- **Tabs per project.** The tab strip shows the project you are working in.
  Switching projects leaves the other agents running.
- **Clear activity states.** Green means the agent is working. Gray means it is
  waiting for you. Orange means it needs your attention. Closing a busy agent
  asks first.
- **Keyboard first.** ⌘K jumps to any session, ⌘T starts a new one, ⌘B toggles
  the sidebar, ⌘/ lists the rest.
- **Quiet and local.** Light and dark themes, no Electron, no accounts, no
  cloud. Your sessions never leave your machine.

Temple does not edit your files, run git, or change session contents. The
agents' own files stay the source of truth.

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
