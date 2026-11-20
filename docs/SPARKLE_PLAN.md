# Sparkle 2 Plan

This is the plan for the next pull request. The public release preparation does not add update behavior.

## Dependency and app configuration

- Add Sparkle 2 through Swift Package Manager and pin an exact reviewed version in `Project.swift`.
- Generate an EdDSA key pair with Sparkle's `generate_keys` tool.
- Keep the private EdDSA key offline. Do not store it in GitHub Actions, repository secrets, source control, or the
  app bundle.
- Add `SUPublicEDKey` and `SUFeedURL` to the app's Info.plist configuration. Host `appcast.xml` on GitHub Pages over
  HTTPS.
- Disable system profiling so update requests do not include device or OS profile fields beyond what HTTP requires.

## User experience

- On first launch, ask whether the user wants automatic update checks. Do not enable them before opt-in.
- Add **Check for Updates** under Settings > General for a user-initiated check.
- Keep update errors actionable without making the app unreachable or interrupting clipboard work.

## Privacy promise

The Sparkle appcast check will be ShakeBoard's only network call. Document the appcast URL, opt-in behavior, and data sent
in `docs/PRIVACY.md`. Future sync remains separate, optional, and end-to-end encrypted.

## Release integration

- Run Sparkle's `sign_update` locally against the final notarized DMG, or add a separate protected manual signing
  step that receives the offline signature. The EdDSA private key must never enter the normal CI release job.
- Add the EdDSA signature and file length to `appcast.xml` with the release notes and minimum macOS version.
- Publish the appcast update only after the GitHub draft release is reviewed and published.
- Extend `.github/workflows/release.yml` to preserve the notarized DMG as the single signed artifact, prepare appcast
  metadata, and upload the reviewed `appcast.xml` to GitHub Pages without exposing the EdDSA private key.
