# Releasing Temple

Releases are Developer ID–signed, notarized by Apple, and published to
[GitHub Releases](https://github.com/ramsrib/temple/releases) as a stapled
`.dmg` and `.zip` (Apple Silicon).

```sh
make release VERSION=v0.x.y   # `make version` prints the last tag
```

The first run drafts `docs/releases/v0.x.y.md` and stops. Read it, edit it,
commit it, and run the same command again.

That single command builds, signs, notarizes, staples, packages, tags, and
publishes. Everything below is the setup it depends on — done once.

## Release notes

Every release publishes `docs/releases/<version>.md` as its notes, and
`make release` refuses to start without that file (`NOTES=` points elsewhere).
GitHub's generated notes list merged PRs; Temple lands on `main` without
them, so until v0.5.0 almost every release said only "Full Changelog" (they were
backfilled since).

`make release-notes VERSION=v0.x.y` (or a release with no notes yet) has a
headless Claude agent draft them by these rules, via `claude-run` from Sri's
dotfiles, and report whether the version fits what is new. It is a draft:
nothing ships until you have read and committed it. By hand or by agent,
write them from `git log <last-tag>..HEAD`, for the person deciding whether
to upgrade. First, list what is in this release **for the first time**: a
version number chosen from "the CLI is new" when the log also held an
unreleased engine rewrite shipped as patch v0.4.1, withdrawn and reissued as
v0.5.0.

- `## What's new`: bullets of what a user sees, a bold one-line claim and a
  plain sentence or two. Fold many commits into one bullet; leave out tests,
  docs and refactors unless they change what a user gets.
- `## Upgrading`, only when the release migrates data, changes a default, or
  asks the user to do something.
- `## Known issue`, only for one you know of.
- No em-dashes (the release refuses them): the notes go out as Sri.

The "Full Changelog" link is appended by GitHub; don't write it.

## One-time setup

**Tools**

```sh
brew install xcodegen create-dmg   # project generation + styled dmg
./Scripts/build-ghostty.sh         # the embedded terminal engine (10–30 min)
                                   # re-run when its pins or Patches/ghostty change;
                                   # the release refuses a stale one (ADR-026)
```

Xcode 26+ and the GitHub CLI (`gh`, authenticated) are also required.

**Signing.** A *Developer ID Application* certificate must be in the login
keychain; `Scripts/build-app.sh` finds it automatically (falling back to Apple
Development, then ad-hoc). Verify with:

```sh
security find-identity -v -p codesigning
```

**Notarization.** Create an [App Store Connect API
key](https://appstoreconnect.apple.com/access/integrations/api) (*Users and
Access → Integrations → Keys*) with **Developer** access, download the `.p8`,
and note the **Key ID** and the **Issuer ID** shown above the key table. Then
store a notarytool keychain profile:

```sh
xcrun notarytool store-credentials temple-notary \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> \
  --issuer <ISSUER-UUID>
```

Finally copy `.env.example` to `.env` (gitignored) so the release script picks
the profile up automatically:

```sh
cp .env.example .env   # then fill in NOTARY_PROFILE + key details
```

Without a `.env` the release still builds and signs — it just skips
notarization, and downloaders have to approve the app in System Settings.

## What `make release` does

0. **Preflight** — refuses the release rather than publish something you cannot
   take back. See [Version numbers](#version-numbers).
1. **Build** — `Scripts/build-app.sh`: `xcodegen` → `xcodebuild` Release →
   bundles the Ghostty runtime resources → signs with Developer ID (hardened
   runtime) → `dist/Temple.app`. The built app's version must match the tag, or
   the release stops before anything is notarized or published.
2. **Notarize the app** — zips it, submits to Apple, waits for `Accepted`,
   **staples the ticket to the `.app`**, and asserts `spctl --assess` reports
   *Notarized Developer ID*. A rejection fails the release.
3. **Package** — `Temple-<version>-<arch>.zip` (ditto) and a styled
   drag-to-Applications `Temple-<version>-<arch>.dmg` (create-dmg).
4. **Notarize the dmg** — submits and staples it too, so the disk image itself
   opens clean.
5. **Publish** — tags `<version>`, pushes the tag, and creates the GitHub
   release with both artifacts and `docs/releases/<version>.md` as its notes.

Before releasing, build the app (`make app`) and run
`Scripts/check-remote-code.sh dist/Temple.app`: it proves the shipped binary
carries the code for sessions on hosts and that nothing gives the host list
a default, so a fresh install shows no remote UI (AGENTS.md, "Two entry
points").

> `notarytool` accepts only `.zip`/`.dmg`/`.pkg` uploads, while `stapler` can
> only write a ticket to the `.app`/`.dmg` — which is why submit and staple are
> separate steps in the script.

## Releasing over SSH

`make release` needs two things from the session it runs in, and an SSH
session gives you at most one of them (v0.6.1, cut from another Mac):

- **Signing.** `codesign` reaches the Developer ID key only in a session whose
  login keychain is unlocked. A fresh SSH session's is not, and signing fails
  with `errSecInternalComponent` after a full build. Unlock it in that session
  first (`security unlock-keychain ~/Library/Keychains/login.keychain-db`), or
  run inside something that was started from the GUI login.
- **The dmg.** `create-dmg` styles the window by scripting Finder, and macOS
  charges that to the *responsible* process. A tmux server reused from another
  job is charged to whatever started it (a `node` agent, once); with no grant
  the call waits on a prompt nobody sees and fails with `AppleEvent timed out
  (-1712)`. Probe before a 10-minute run:
  `osascript -e 'tell application "Finder" to get name of startup disk'`.

Both failures come before tagging, so a failed run publishes nothing and can
simply be run again. And `gh` publishes as whichever account is active: from
a machine signed in to more than one, run the release step with
`GH_TOKEN=$(gh auth token --user <owner>)`, or the release API answers 404.

## Verifying a published release

```sh
gh release download <version> -p '*.dmg' -D /tmp/check
xcrun stapler validate /tmp/check/Temple-<version>-arm64.dmg
hdiutil attach /tmp/check/Temple-<version>-arm64.dmg
spctl --assess -vv /Volumes/Temple/Temple.app   # → accepted, Notarized Developer ID
hdiutil detach /Volumes/Temple
```

## Homebrew

The cask lives in [ramsrib/homebrew-tap](https://github.com/ramsrib/homebrew-tap)
(`Casks/temple.rb`). After publishing a release, bump it:

```sh
shasum -a 256 dist/Temple-<version>-arm64.dmg      # new sha256
# edit ../homebrew-tap/Casks/temple.rb: version + sha256
cd ../homebrew-tap && brew style --fix Casks/temple.rb && git commit -am "temple: bump cask to <version>" && git push
```

Users then get it with `brew install --cask ramsrib/tap/temple` (or
`brew upgrade --cask temple`).

The first release that ships the `temple` command line (ADR-034) also adds
this to the cask, once, so Homebrew links it onto the PATH:

```ruby
binary "#{appdir}/Temple.app/Contents/Helpers/temple"
```

## Version numbers

Every version in this file is written `v0.x.y`, and it is always a placeholder:
run `make version` for the real numbers. (An earlier draft used a plausible
`v0.1.0` throughout, and a reader took the example for the current release.)

`VERSION` (`vX.Y.Z`) drives the git tag, the artifact names, and the app's
`MARKETING_VERSION`. Tag names use the `v` prefix; the bundle version drops it.
`App/Info.plist` takes `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`
from the build settings — never hardcode a version there, or About will report
the wrong one no matter what you release (v0.1.1 shipped saying `0.1.0` this
way). A local `make install` build takes its version from the last tag and its
build number from the commit count.

**Git tags are the record of what shipped.** To see where things stand:

```sh
make version
```

```
released:   v0.x.y v0.x.y-1        # tags
published:  v0.x.y v0.x.y-1        # GitHub releases
on brew:    0.x.y                  # what users actually get
installed:  0.x.y                  # your /Applications
unreleased: 3 commits since v0.x.y
```

Because `VERSION` is typed by hand, `make release` checks it before it does
anything, and each check is a mistake that cannot be undone once published:

| Refused | Why |
|---|---|
| `0.1.2` (no `v`), `v0.1` | Must be `vX.Y.Z` — a malformed tag breaks the cask's `livecheck` and the artifact URLs. |
| A version that already has a tag or release | Releases are immutable. Re-publishing under a version someone already downloaded gives two different builds the same name. |
| A version that skips one (`v0.1.3` after `v0.1.1`) | A gap in the tags is indistinguishable from a release whose artifacts went missing. Pass `FORCE_VERSION=1` to skip deliberately — e.g. leaving `v0.2.0` for a feature still landing. |
| A dirty working tree | The tag would name code that exists only on your machine. |
| Commits not pushed to `origin/main` | Same: the tag would point at code nobody else can fetch. |

So the release after `v0.x.y` is `v0.x.y+1`, `v0.x+1.0`, or `v1.0.0`, and the
script will tell you so if you type anything else.
