# ShakeBoard press kit

## Boilerplate

ShakeBoard is an open-source macOS app that keeps clipboard history, a file drag shelf, paste stacks, and pinboards in one full-width strip at the bottom of the screen. It handles text, highlighted code, links, images, and files; recognizes image text on-device; and includes an optional local MCP bridge for Claude Code and Codex. Your data stays on your Mac. ShakeBoard has no account or telemetry; its only network call is the update check you opt into. It is licensed under Apache-2.0 by Clay Money Inc. and supports macOS 14 and later.

## Fact sheet

| Field | Detail |
|---|---|
| Product | ShakeBoard |
| Category | macOS clipboard history and drag shelf |
| Developer and copyright | Clay Money Inc. |
| Source | https://github.com/ThisRadLife/shakeboard |
| License | Apache-2.0 |
| Platform | macOS 14 and later |
| Price | None; open source |
| Distribution | Notarized DMG on GitHub Releases |
| Data model | Data stays on your Mac; no account; no telemetry |
| Permission | Accessibility for shake detection and paste-stack advancement |
| Core workflows | Clipboard history, drag shelf, paste stacks, pinboards, on-device OCR, themes, Quick Look, editing, transforms, and optional local MCP access |
| AI access | Off by default; local; read-only; redacted on a best-effort basis; per-client consent-gated; rate-limited; content-free audit log |
| Updates | Built in; automatic checks are opt-in; "Check for Updates..." in Settings > General |
| Coming | Homebrew cask; encrypted backup and sync through a folder, network share, or iCloud Drive |
| Press contact | To be chosen before publication |

ShakeBoard opens as a full-width strip along the bottom of the screen. It can hold copied text, highlighted code, links, images, and files, plus files parked on a separate drag shelf. A mouse shake or Command-Space reveals the strip. Named pinboards keep reusable copies close. Paste stacks collect copies and paste them in order with Command-V.

OCR uses Apple Vision on the Mac. The optional MCP bridge works with Claude Code and Codex. It does not return image pixels or file contents. Redaction is pattern-based and cannot catch every secret.

## Approved asset list

Only package final assets captured from the current ShakeBoard build with synthetic data. Product copy comes from the repository-root `README.md`.

### Brand

- `docs/launch/brand/*` - app icon masters and the Icon Composer source bundle
- `docs/launch/social/social-preview-1280x640.png` - punk GitHub social preview
- `site/assets/og-image-1200x630.jpg` - punk website Open Graph and Twitter card
- `site/assets/favicon.ico` - browser favicon
- `site/assets/icons/icon-16.png` - 16 px web icon
- `site/assets/icons/icon-32.png` - 32 px web icon
- `site/assets/icons/icon-180.png` - Apple touch icon
- `site/assets/icons/icon-192.png` - 192 px web icon
- `site/assets/icons/icon-512.png` - 512 px web icon

### Screenshots

- `site/assets/screens/strip.png` - mixed clipboard history strip
- `site/assets/screens/lane.png` - paste stacks lane
- `site/assets/screens/picks.png` - ordered multi-select
- `site/assets/screens/pinboards.png` - named pinboard
- `site/assets/screens/ocr.png` - OCR search result
- `site/assets/screens/edit.png` - editing and transforms
- `site/assets/screens/theme-paper.png` - strip in the Paper theme
- `site/assets/screens/settings-about.png` - About settings
- `site/assets/screens/settings-appearance.png` - theme settings
- `site/assets/screens/settings-privacy.png` - privacy and AI settings
- `site/assets/screens/consent.png` - MCP consent panel

### Website art

- `site/assets/punk/collage-hero.jpg` - punk collage hero
- `site/assets/punk/sticker-sb.png` - ShakeBoard skateboard sticker
- `site/assets/punk/doodles/*.png` - feature doodles

The website art is hand-made-style screen-print/zine art generated with Codex image generation.

## Packaging notes

The press archive should contain PNG masters, concise captions, and alt text in `README.txt`. Do not include licensed font files or source design files. Publish a SHA-256 checksum beside the versioned ZIP. The final contact, release version, release date, signing identity, and canonical website URL remain owner decisions.
