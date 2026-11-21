# Sparkle 2 Implementation

Status: implemented with Sparkle 2.10.1. The app integration, release checks, local appcast publisher, privacy
documentation, and Homebrew metadata are in place. A real public EdDSA key and a published `gh-pages` feed are still
release-operator setup; the EdDSA private key remains in the maintainer's login Keychain and never enters CI or GitHub
secrets.

## Dependency and app configuration

- Sparkle 2.10.1 is pinned to its immutable Git revision through Swift Package Manager in `Project.swift`.
- Generate the EdDSA key pair once with Sparkle's `generate_keys` tool as documented in `RELEASING.md`.
- Keep the private EdDSA key offline. Do not store it in GitHub Actions, repository secrets, source control, or the
  app bundle.
- `SUPublicEDKey` and `SUFeedURL` are set through the app's build settings. The feed URL is
  `https://thisradlife.github.io/shakeboard/appcast.xml` until Brad selects a custom domain.
- `SUEnableSystemProfiling` is false. Release CI rejects an unset public key or enabled profiling.
- Local non-shipping Release builds may explicitly set `SHAKEBOARD_ALLOW_UNSET_SPARKLE_KEY=1`; Sparkle stays dormant
  in those builds. Debug builds do not need the override.

## User experience

- Automatic checks are off by default. ShakeBoard asks once at the top of Settings > General; Sparkle's separate
  permission window is suppressed so it cannot be missed behind another app.
- Settings > General includes **Automatically check for updates** and **Check for Updates...**.
- Scheduled checks only show Sparkle when immediate focus is appropriate. Otherwise an informational update row and
  the strip gear's orange dot wait for the user to choose **Install...**.

## Privacy promise

The Sparkle appcast check is ShakeBoard's only network call. `docs/PRIVACY.md` documents the appcast host, GitHub
release download, opt-in behavior, signature verification, and the standard HTTP request data. Future networking may
not be added without updating that policy.

## Release integration

- CI builds, signs, notarizes, and staples the DMG, checks every nested Mach-O and signed bundle, then creates a draft
  release containing the DMG and its SHA-256 file. CI does not contain the Sparkle private key and does not sign or
  publish an appcast.
- After a maintainer reviews and publishes the GitHub release, `scripts/publish-appcast.sh vX.Y.Z` verifies the DMG,
  invokes Sparkle's pinned `sign_update` using the login-Keychain key, prepends the release to `appcast.xml`, prints the
  diff, and publishes only to `gh-pages` after confirmation.
