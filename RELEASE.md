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
publishes. Everything below is the setup it depends on — done once. The same
release can also run on GitHub Actions, with no Mac of yours holding the
signing key: see [Releasing from GitHub](#releasing-from-github).

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

Between steps 1 and 2 the release runs two checks on the built app and stops
on either: `Scripts/check-remote-code.sh` proves the shipped binary carries
the code for sessions on hosts and that nothing gives the host list a
default, so a fresh install shows no remote UI, and
`Scripts/check-sdk-linkage.sh` proves each binary records the SDK it was
built with (AGENTS.md, "Two entry points").

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
simply be run again. A release from GitHub (next section) has a keychain of
its own, unlocked for the job. And `gh` publishes as whichever account is active: from
a machine signed in to more than one, run the release step with
`GH_TOKEN=$(gh auth token --user <owner>)`, or the release API answers 404.

## Releasing from GitHub

`.github/workflows/release.yml` runs the same `Scripts/release.sh` on
GitHub-hosted Macs, so no Mac of yours needs the signing key. It has three
modes:

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

**The first time**, after setting the secrets, run a verify with the next
unused version (`make version` prints the last). A verify needs no notes,
tags nothing, and leaves that version free for the real release.

Before a release, on a Mac:

- **Run the tests.** The workflow runs none: it builds, signs and checks the
  binary (the two checks between steps 1 and 2 above), nothing more.
- **Write the notes**: `make release-notes VERSION=v0.x.y`, read, commit,
  push. The workflow refuses a release without them, and refuses any signed
  run from a branch other than `main` or without the secrets below.

**A draft still uses up the version.** `release.sh` pushes the tag before it
creates the release, draft or not, and refuses a version whose tag exists.
Publish the draft rather than running the workflow again:
`gh release edit v0.x.y --draft=false`.

**If a release fails after tagging** (the release upload, a timeout, a
cancelled run), the tag is public and the version cannot be run again; do
not delete the tag. Finish the release by hand from what the run built:

1. Get the zip and dmg: `gh run download <run-id>`. A run cancelled or timed
   out before its last step may have kept none; then rebuild them on a Mac
   from the tagged commit (`git checkout v0.x.y`, then the steps in
   `Scripts/release.sh` up to packaging), or cut the next version instead.
2. `gh release view v0.x.y` says whether a release exists. `gh` creates one
   as a draft while it uploads, so a failure can leave one behind.
   - None: `gh release create v0.x.y Temple-v0.x.y-arm64.zip Temple-v0.x.y-arm64.dmg --title "Temple v0.x.y" --notes-file docs/releases/v0.x.y.md --generate-notes`,
     adding `--draft` if the run asked for a draft.
   - One exists: upload what it lacks with
     `gh release upload v0.x.y <file> --clobber`, then publish it with
     `gh release edit v0.x.y --draft=false` unless a draft was meant.

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
- **Not yet proven on a runner:** the signed path (keychain, notarization,
  stapling, the styled dmg, which scripts Finder). The build-only run has
  passed; run a `verify` before the first release from GitHub.
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
repository's own token, so the `gh` account question above does not arise.

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
what shipped.** The two differ only while a release is a draft or failed
after tagging (see Releasing from GitHub). `make version`'s `released:` line
lists tags, so it counts such a version; `published:` lists releases. To see
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
