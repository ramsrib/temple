# Releasing Temple

Releases are Developer ID–signed, notarized by Apple, and published to
[GitHub Releases](https://github.com/ramsrib/temple/releases) as a stapled
`.dmg` and `.zip` (Apple Silicon).

```sh
make release VERSION=v0.1.0
```

That single command builds, signs, notarizes, staples, packages, tags, and
publishes. Everything below is the setup it depends on — done once.

## One-time setup

**Tools**

```sh
brew install xcodegen create-dmg   # project generation + styled dmg
./Scripts/build-ghostty.sh         # the embedded terminal engine (10–30 min)
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
   release with both artifacts and generated notes.

> `notarytool` accepts only `.zip`/`.dmg`/`.pkg` uploads, while `stapler` can
> only write a ticket to the `.app`/`.dmg` — which is why submit and staple are
> separate steps in the script.

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

## Version numbers

`VERSION` (e.g. `v0.1.0`) drives the git tag, the artifact names, and the app's
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
released:   v0.1.1 v0.1.0          # tags
published:  v0.1.1 v0.1.0          # GitHub releases
on brew:    0.1.1                  # what users actually get
installed:  0.1.1                  # your /Applications
unreleased: 3 commits since v0.1.1
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

So the next release after `v0.1.1` is `v0.1.2`, `v0.2.0`, or `v1.0.0`, and the
script will tell you so if you type anything else.
