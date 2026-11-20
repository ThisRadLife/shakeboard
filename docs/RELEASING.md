# Releasing ShakeBoard

Releases are built, Developer ID signed, notarized, stapled, and packaged by the protected tag-only GitHub Actions
workflow. The workflow creates a draft GitHub release; a maintainer reviews and publishes it.

The release and CI workflows pin Tuist 4.202.0. When updating it, bump Tuist together with Xcode and replace the
pinned SHA-256 with the new value from that Tuist release's `SHASUMS256.txt`.

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

## Release checklist

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
11. Update the Homebrew tap cask with the published version and the SHA-256 value from the release asset, then test
    installation from the tap.

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

## Security notes

- Release secrets are scoped to the protected `release` environment and never reach fork pull requests.
- The release workflow must remain tag-only. Never add `pull_request` or `pull_request_target` to it.
- Do not place signing or notarization material in artifacts, caches, generated projects, logs, or release assets.
- Review any change to `.github/workflows/release.yml` under CODEOWNERS before tagging a release.
