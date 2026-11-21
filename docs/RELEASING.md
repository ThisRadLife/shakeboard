# Releasing ShakeBoard

Releases are built, Developer ID signed, notarized, stapled, and packaged by the protected tag-only GitHub Actions
workflow. The workflow creates a draft GitHub release; a maintainer reviews and publishes it.

The release and CI workflows pin Tuist 4.202.0. When updating it, bump Tuist together with Xcode and replace the
pinned SHA-256 with the new value from that Tuist release's `SHASUMS256.txt`.

Sparkle is pinned to 2.10.1's immutable Git revision in `Project.swift`; the separately downloaded signing-tool
archive is pinned by SHA-256. The Sparkle EdDSA private key is never a CI or GitHub secret: it lives in the release
maintainer's login Keychain and `scripts/publish-appcast.sh` uses it locally only after the draft release has been
reviewed and published.

## One-time GitHub setup

Configure a tag protection rule or repository ruleset for `v*` that allows only maintainers to create release tags.

Create an environment named `release` under the repository's Settings > Environments page.

- Add required reviewers so a release job cannot access secrets until a maintainer approves it.
- Add a deployment tag rule matching `v*`.
- Store all release secrets in this environment, not as unprotected repository or organization secrets.

Required secrets:

- `DEVELOPER_ID_P12_BASE64`: export the **Developer ID Application** certificate and its private key from Keychain
  Access as a password-protected `.p12`, then encode it with `base64 -i DeveloperID.p12 | pbcopy`.
- `DEVELOPER_ID_P12_PASSWORD`: the password chosen when exporting that `.p12`.
- `ASC_KEY_ID`: the App Store Connect API key ID.
- `ASC_ISSUER_ID`: the App Store Connect issuer ID shown on the Integrations page.
- `ASC_KEY_P8_BASE64`: create an App Store Connect API key with the **Developer** role, download its one-time `.p8`
  file, then encode it with `base64 -i AuthKey_KEYID.p8 | pbcopy`.

Keep the original `.p12` and `.p8` files in an approved secrets store. Never commit them or paste them into logs.

## One-time Sparkle key setup

Run this on Brad's release Mac. Download the same Sparkle archive used by the appcast publisher and verify the pinned
SHA-256 before running any tool from it:

```bash
mkdir -p /tmp/shakeboard-sparkle-key-setup
cd /tmp/shakeboard-sparkle-key-setup
gh release download 2.10.1 \
  -R sparkle-project/Sparkle \
  -p Sparkle-2.10.1.tar.xz
echo '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27  Sparkle-2.10.1.tar.xz' \
  | shasum -a 256 -c -
tar -xJf Sparkle-2.10.1.tar.xz
cd Sparkle-2.10.1
./bin/generate_keys
```

`generate_keys` stores the private EdDSA key in the login Keychain and prints the public key. Put only that public key
in the `SPARKLE_PUBLIC_ED_KEY` build setting in `Project.swift`. Never copy the private key into the repository,
GitHub Actions, or GitHub secrets.

Create one offline recovery copy:

```bash
./bin/generate_keys -x sparkle-private-key.txt
```

Move `sparkle-private-key.txt` immediately to an encrypted USB drive or password manager, verify the backup, and then
delete the plaintext file:

```bash
rm -f sparkle-private-key.txt
```

Do not commit that file, attach it to an issue or release, paste it into a command, or put it in an environment
variable. Losing both the Keychain key and its offline backup means existing installs cannot trust a replacement key
without a separate key-rotation release signed by the old key.

## One-time GitHub Pages setup

Create the `gh-pages` branch with an initial `appcast.xml`, then in repository Settings > Pages choose **Deploy from a
branch**, branch **gh-pages**, folder **/(root)**. Confirm that
`https://thisradlife.github.io/shakeboard/appcast.xml` is served over HTTPS before shipping the first Sparkle-enabled
release.

Brad still needs to decide whether the permanent feed host is `thisradlife.github.io/shakeboard` or a custom domain.
If `SUFeedURL` changes after a release ships, keep serving the old URL and ship one transition release from that old
feed whose app points at the new URL. Do not remove or redirect the old feed until that transition has propagated.

## Release flow

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Project.swift` before tagging. The release workflow
   fails if `MARKETING_VERSION` does not match the tag.
2. Move the relevant entries in `CHANGELOG.md` from **Unreleased** into a `X.Y.Z` release section.
3. Generate the project and run the full test suite described in [`CONTRIBUTING.md`](../CONTRIBUTING.md).
4. Commit the release metadata with a DCO sign-off.
5. Create an annotated tag: `git tag vX.Y.Z -m "ShakeBoard X.Y.Z"`.
6. Push the tag: `git push origin vX.Y.Z`.
7. Approve the protected `release` environment deployment when GitHub prompts for review.
8. Wait for the release workflow to sign and notarize the app and DMG and create a draft GitHub release.
9. Review the workflow log, draft notes, attached `ShakeBoard-X.Y.Z.dmg`, and `.sha256` file. Download the DMG and verify
   installation and first launch on a clean test Mac.
10. Publish the draft release.
11. On Brad's release Mac, publish the signed update entry from the repository root:

    ```bash
    scripts/publish-appcast.sh vX.Y.Z
    ```

    The script downloads the published DMG and `.sha256`, verifies the checksum, notarization staple, and Gatekeeper
    assessment, downloads and verifies Sparkle 2.10.1, and runs `sign_update`. `sign_update` reads the EdDSA private key
    directly from the login Keychain. The script reads both bundle versions from the app inside the mounted DMG,
    prepends the release to the RSS appcast while retaining older items, validates the XML, and prints the exact
    `gh-pages` diff. It commits and pushes only after a `y/N` confirmation. Use `--yes` only for an already reviewed
    unattended invocation.
12. Verify the public feed after GitHub Pages deploys:

    ```bash
    curl -fsSL https://thisradlife.github.io/shakeboard/appcast.xml | xmllint --noout -
    curl -fsSL https://thisradlife.github.io/shakeboard/appcast.xml | grep -F "ShakeBoard-X.Y.Z.dmg"
    ```

    Then use **Settings > General > Check for Updates...** from the previous public ShakeBoard version and confirm it
    offers `X.Y.Z`, downloads it, and verifies it without a signature error.
13. On a clean preferences domain, open Settings and confirm ShakeBoard's own one-time automatic-update question is
    visible only in Settings > General, automatic checks remain off before answering, **Not Now** records the choice
    without enabling checks, and **Turn On** enables them. Confirm Sparkle does not show its own permission window.
14. Update the Homebrew tap cask with the published version and the SHA-256 value from the release asset, then test
    installation from the tap.

To generate and inspect an appcast locally without committing or pushing, run:

```bash
scripts/publish-appcast.sh --dry-run vX.Y.Z
```

The dry run writes `/tmp/ShakeBoard-appcast-X.Y.Z.xml`. It still downloads, verifies, mounts, and signs the published
DMG, so it requires the maintainer's Keychain key; it never touches `main` or `master`.

## Local fallback

Use this only when GitHub Actions is unavailable. The same Developer ID Application certificate must be installed in
the local keychain. First create a local notarytool profile without putting credentials in shell history:

```bash
xcrun notarytool store-credentials "shakeboard-notary" \
  --key /secure/path/AuthKey_KEYID.p8 \
  --key-id KEYID \
  --issuer ISSUER_ID
```

Then generate, build, verify, notarize, and package. Replace `X.Y.Z` with the version being released:

```bash
set -euo pipefail
tuist generate --no-open
xcodebuild \
  -workspace ShakeBoard.xcworkspace \
  -scheme ShakeBoard \
  -configuration Release \
  -derivedDataPath /tmp/shakeboard-release \
  build

APP_PATH=/tmp/shakeboard-release/Build/Products/Release/ShakeBoard.app
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" /tmp/ShakeBoard-notarization.zip
xcrun notarytool submit /tmp/ShakeBoard-notarization.zip --keychain-profile "shakeboard-notary" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

DMG_ROOT="$(mktemp -d /tmp/shakeboard-dmg.XXXXXX)"
ditto "$APP_PATH" "$DMG_ROOT/ShakeBoard.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname ShakeBoard -srcfolder "$DMG_ROOT" -ov -format UDZO "ShakeBoard-X.Y.Z.dmg"
codesign --force --timestamp --sign "Developer ID Application" "ShakeBoard-X.Y.Z.dmg"
xcrun notarytool submit "ShakeBoard-X.Y.Z.dmg" --keychain-profile "shakeboard-notary" --wait
xcrun stapler staple "ShakeBoard-X.Y.Z.dmg"
xcrun stapler validate "ShakeBoard-X.Y.Z.dmg"
shasum -a 256 "ShakeBoard-X.Y.Z.dmg" > "ShakeBoard-X.Y.Z.dmg.sha256"
```

Create a draft GitHub release only after the local artifacts pass those checks.

Until the real public key has been generated, a local non-shipping Release build can set
`SHAKEBOARD_ALLOW_UNSET_SPARKLE_KEY=1` to bypass the Release guard. Sparkle remains dormant and makes no network request
when the built key is empty or `UNSET_SPARKLE_PUBLIC_ED_KEY`. Never distribute a build made with this override. Debug
builds do not need it.

Automatic checks must remain off until the user answers ShakeBoard's one-time question in Settings > General. Do not
set `SUEnableAutomaticChecks` in the app's Info.plist: `UpdateController` suppresses Sparkle's permission window and
the `updateChoiceMade` preference records whether ShakeBoard's own question has been answered.

## Security notes

- Release secrets are scoped to the protected `release` environment and never reach fork pull requests.
- The release workflow must remain tag-only. Never add `pull_request` or `pull_request_target` to it.
- Do not place signing or notarization material in artifacts, caches, generated projects, logs, or release assets.
- Do not add the Sparkle EdDSA private key to CI. CI uploads only the notarized DMG and its SHA-256 file; appcast
  signing and publication happen locally after the GitHub release is public.
- Review any change to `.github/workflows/release.yml` under CODEOWNERS before tagging a release.
