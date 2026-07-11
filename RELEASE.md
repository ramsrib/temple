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

1. **Build** — `Scripts/build-app.sh`: `xcodegen` → `xcodebuild` Release →
   bundles the Ghostty runtime resources → signs with Developer ID (hardened
   runtime) → `dist/Temple.app`.
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

## Version numbers

`VERSION` (e.g. `v0.1.0`) drives the git tag, the artifact names, and the app's
`MARKETING_VERSION`. Tag names use the `v` prefix; the bundle version drops it.
