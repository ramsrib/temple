# Releasing Temple

Releases are Developer ID–signed, notarized by Apple, and published to
[GitHub Releases](https://github.com/ramsrib/temple/releases) as a stapled
`.dmg` and `.zip` (Apple Silicon). They run on GitHub Actions
(`.github/workflows/release.yml`), so no Mac of yours needs the signing key:

1. **On a Mac:** run the tests (the workflow runs none), then
   `make release-notes VERSION=v0.x.y` to draft `docs/releases/v0.x.y.md`
   ([Release notes](#release-notes)). Read it, edit it, and commit and push
   it with the code. `make version` prints the last version.
2. **Release:**
   `gh workflow run release -R ramsrib/temple -f version=v0.x.y`, then
   `gh run watch -R ramsrib/temple`. With the engine cached it takes about 8
   minutes: 5.5 for the Xcode build, about 30 seconds for each of the two
   notarizations.
3. **Bump the Homebrew cask** with the dmg's sha256 from the run's summary
   ([Homebrew](#homebrew)).

On a machine signed in to more than one GitHub account, run `gh` with
`GH_TOKEN=$(gh auth token --user ramsrib)`. The workflow's modes and setup
are in [Releasing from GitHub](#releasing-from-github). `make release
VERSION=v0.x.y` on a Mac that holds the signing key (mac-personal) runs the
same `Scripts/release.sh` and is the fallback:
[Releasing from a Mac](#releasing-from-a-mac).

## Release notes

Every release publishes `docs/releases/<version>.md` as its notes, and a
release refuses to start without that file, committed on `main`. (From a
Mac, `NOTES=` points `make release` at another file.)
GitHub's generated notes list merged PRs; Temple lands on `main` without
them, so until v0.5.0 almost every release said only "Full Changelog" (they were
backfilled since).

`make release-notes VERSION=v0.x.y` (or, from a Mac, `make release` with no notes yet) has a
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

## Releasing from GitHub

`.github/workflows/release.yml` runs `Scripts/release.sh`
([What a release does](#what-a-release-does)) on GitHub-hosted Macs. It has
three modes:

```sh
gh workflow run release                                   # build only, ad-hoc signed: no secret used
gh workflow run release -f version=v0.x.y -f verify=true  # sign, notarize, package; nothing tagged or published
gh workflow run release -f version=v0.x.y                 # release (add -f draft=true for a draft)
```

`gh run watch` follows the run. Every run that gets as far as packaging keeps
what it built (the app's zip, and for a signed run the dmg) for 14 days:
`gh run download <run-id>`. A release's summary prints the published dmg's
sha256 for the Homebrew cask; a verify's dmg is a separate build, so its hash
is for inspection only.

**Run a verify first** after setting or renewing the secrets, bumping
`XCODE_BUILD`, or changing the workflow or `Scripts/release.sh`: a verify
with the next unused version signs, notarizes and packages exactly as a
release would, needs no notes, tags nothing, and leaves that version free.
The first one (v0.8.0, 2026-11-02) produced an app Gatekeeper accepts as
*Notarized Developer ID* and a stapled dmg.

The workflow refuses a release without committed notes, and refuses any
signed run from a branch other than `main` or without the secrets below. It
runs no tests: it builds, signs, and runs the two binary checks, nothing more.

**A run that fails partway is finished by running it again**, with the same
version from the same commit. A release creates its GitHub release as a draft
with both files first, pushes the tag second, and publishes the draft last, so
no failure leaves a public tag without its release. The next run of that
version finds what the last one left and carries on: it rebuilds, replaces an
unpublished draft, keeps a tag already at that commit, and publishes. Don't
publish a draft by hand, or start a Mac release, while a run of the same
version is going: the run could replace the draft just as it is published.
The same
goes for a release run as a draft (`-f draft=true`): run it again without
`draft` to publish it, or publish it as built with
`gh release edit v0.x.y --draft=false`.

A version is refused only once it is published, or when GitHub's tag for it
names another commit than the one being built. The workflow builds `main`, so
once `main` has moved on after a failed run it cannot finish that version.
Then either:

- from a Mac with the signing key, check out the tagged commit and run the
  release there: `git checkout v0.x.y && make release VERSION=v0.x.y`. The
  version check does not apply to a version that was already started, so a
  newer release shipped meanwhile does not block it; or
- finish it by hand from the failed run's files (`gh run download <run-id>`).
  `gh release view v0.x.y` says what exists: with no release, run
  `gh release create v0.x.y <zip> <dmg> --title "Temple v0.x.y" --notes-file docs/releases/v0.x.y.md --generate-notes`;
  with a draft, `gh release upload v0.x.y <zip> <dmg> --clobber` then
  `gh release edit v0.x.y --draft=false`. A run cancelled before it kept its
  files leaves only the Mac route; or
- cut the next version.

- **Xcode is pinned by build number** (`XCODE_BUILD` in the workflow), on
  the `xcode-27` runner. The Xcode decides the SDK the app records, and macOS
  picks AppKit/SwiftUI behaviour by it, so the job fails rather than build
  with another one. v0.7.0 was built with 27A9275 (Xcode 27.1, SDK 27.0).
  Bump it only after testing a build from the new one.
- **The Ghostty engine is built in a job of its own, on `macos-15`**: zig
  0.15 cannot link against any macOS 26+ SDK (they list only arm64e;
  [docs/BUILDING-GHOSTTY.md](docs/BUILDING-GHOSTTY.md), gotcha 1), and that
  image still carries Xcode 16.4's macOS 15 SDK beside Xcode 26.3. The job's
  build steps are skipped when the engine is cached; the cache key is its
  stamp (ADR-026), a digest of `Scripts/build-ghostty.sh`, the slice, and the
  Xcode and SDK builds. GitHub drops a cache that has not been used for 7
  days (sooner under storage pressure), so a release more than a week after
  the last run builds it again, about 6 minutes. The engine lives only in
  the cache: a Mac still builds its own.
- **Secrets** (Settings → Secrets and variables → Actions):

  | Secret | Value |
  |---|---|
  | `TEMPLE_DEVELOPER_ID_P12` | the Developer ID Application certificate and its private key, exported from Keychain Access as `.p12`, base64-encoded |
  | `TEMPLE_DEVELOPER_ID_P12_PASSWORD` | the password chosen at export |
  | `NOTARY_KEY_P8` | the contents of the App Store Connect `AuthKey_<KEYID>.p8` |
  | `NOTARY_KEY_ID` | its Key ID |
  | `NOTARY_ISSUER` | its Issuer ID |

  Set them from the Mac that holds them, for example
  `base64 -i developer-id.p12 | gh secret set TEMPLE_DEVELOPER_ID_P12 -R ramsrib/temple`
  and `gh secret set NOTARY_KEY_P8 -R ramsrib/temple < AuthKey_<KEYID>.p8`.
  The Developer ID certificate expires on 2027-02-01, with the intermediate
  that issued it: after renewing it, export the new one and set
  `TEMPLE_DEVELOPER_ID_P12` and its password again, or signing fails.

The tag is pushed as `github-actions[bot]`, and the release is created by the
repository's own token, so which `gh` account starts the run does not matter
to what is published.

## What a release does

`Scripts/release.sh`, from the workflow or `make release`:


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
5. **Publish** — creates the GitHub release as a draft with both artifacts
   and `docs/releases/<version>.md` as its notes, then tags `<version>` and
   pushes the tag, then publishes the draft (unless `DRAFT=1`). A run that
   fails partway is finished by running it again (see Releasing from GitHub).

Between steps 1 and 2 the release runs two checks on the built app and stops
on either: `Scripts/check-remote-code.sh` proves the shipped binary carries
the code for sessions on hosts and that nothing gives the host list a
default, so a fresh install shows no remote UI, and
`Scripts/check-sdk-linkage.sh` proves each binary records the SDK it was
built with (AGENTS.md, "Two entry points").

> `notarytool` accepts only `.zip`/`.dmg`/`.pkg` uploads, while `stapler` can
> only write a ticket to the `.app`/`.dmg` — which is why submit and staple are
> separate steps in the script.

## Releasing from a Mac

`make release VERSION=v0.x.y` does what the workflow does, from the Mac it
runs on. The first run drafts the notes and stops, like `make release-notes`;
run it again once they are committed.

### One-time setup

**Tools**

```sh
brew install xcodegen create-dmg   # project generation + styled dmg
./Scripts/build-ghostty.sh         # the embedded terminal engine (10–30 min)
                                   # re-run when its pins or Patches/ghostty change;
                                   # the release refuses a stale one (ADR-026)
```

Xcode 26+ and the GitHub CLI (`gh`, authenticated) are also required.
Building the engine from scratch also needs a macOS 15 SDK, which no current
Xcode or Command Line Tools carries; see
[docs/BUILDING-GHOSTTY.md](docs/BUILDING-GHOSTTY.md), gotcha 1.

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

### Releasing over SSH

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
simply be run again. A release from GitHub has a keychain of its own,
unlocked for the job, and a desktop session for Finder. And `gh` publishes as whichever account is active: from
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
(`Casks/temple.rb`). After publishing a release, bump it. A release from
GitHub has no local dmg: take the sha256 from the run's summary, or download
the published dmg first (`gh release download <version> -p '*.dmg' -D dist`).

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

**Tags record the versions that are taken; published GitHub releases record
what shipped.** The two differ only while a release is a draft or a run failed
after pushing its tag, until that version is run again (see Releasing from
GitHub). `make version`'s `released:` line lists tags, so it counts such a
version; `published:` lists releases. To see
where things stand:

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

Because `VERSION` is typed by hand, every release checks it before it does
anything, and each check is a mistake that cannot be undone once published:

| Refused | Why |
|---|---|
| `0.1.2` (no `v`), `v0.1` | Must be `vX.Y.Z` — a malformed tag breaks the cask's `livecheck` and the artifact URLs. |
| A version that is already published, or tagged at another commit | Releases are immutable. Re-publishing under a version someone already downloaded gives two different builds the same name. (A version that is tagged at this commit, or only has a draft, is a run that did not finish: running it again finishes it.) |
| A version that skips one (`v0.1.3` after `v0.1.1`) | A gap in the tags is indistinguishable from a release whose artifacts went missing. To skip one deliberately (e.g. leaving `v0.2.0` for a feature still landing), release from a Mac with `FORCE_VERSION=1`; the workflow has no such override. |
| A dirty working tree | The tag would name code that exists only on your machine. |
| Commits not pushed to `origin/main` | Same: the tag would point at code nobody else can fetch. |

So the release after `v0.x.y` is `v0.x.y+1`, `v0.x+1.0`, or `v1.0.0`, and the
script will tell you so if you type anything else.
