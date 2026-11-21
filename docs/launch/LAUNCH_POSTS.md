# Launch posts

Use these only after the shipped app, release, license, screenshots, and repository agree with the launch facts.

## Show HN

### Title

Show HN: ShakeBoard - local clipboard history and drag shelf for macOS

### Body

I built ShakeBoard because clipboard history and moving files around were two versions of the same problem: I needed a temporary place for things while I worked.

ShakeBoard is one full-width strip at the bottom of the Mac. It keeps text, highlighted code, links, images, copied files, and files you drag onto its shelf. Shake the mouse or press Command-Space to open it.

The part I use most is paste stacks. You can collect several copies, mark a stack Ready, and then Command-V pastes each item in order. There are also named pinboards, on-device OCR, Quick Look, editing and text transforms, and custom color themes.

Your data stays on your Mac. There is no account or telemetry. The only network call is the update check you opt into. Password managers are excluded. There is an optional local MCP bridge so Claude Code and Codex can search history. It is off by default, read-only, redacts known secret patterns, asks per client, and keeps a content-free request log. Redaction is not a guarantee, so the UI says that plainly.

ShakeBoard supports macOS 14 and later and is open source under Apache-2.0. I would especially value feedback on paste-stack ergonomics, the MCP security model, and building the app on Macs other than mine.

Source and download: https://github.com/ThisRadLife/shakeboard

## r/macapps

### Title

I made ShakeBoard: an open-source clipboard history, drag shelf, and paste-stack app

### Body

ShakeBoard lives in one strip across the bottom of your Mac. Shake the mouse or press Command-Space and it shows recent text, highlighted code, links, images, copied files, and files you parked on its drag shelf.

You can search history, keep reusable copies in named pinboards, preview with Space, edit or clean up text, and use on-device OCR to search words inside copied images.

Paste stacks are the main difference from a standard clipboard manager. Collect copies into a stack, mark it Ready, and each Command-V pastes the next item in order. You can keep one stack collecting while another is ready, select cards in click order, or split a list into a stack.

Your data stays on your Mac. The app has no account or telemetry, and it does not capture password managers. The only network call is the update check you opt into. An optional read-only MCP bridge for Claude Code and Codex is off by default and asks for consent per client.

It supports macOS 14+, is licensed under Apache-2.0, and the notarized DMG is on GitHub Releases. Built-in signed updates are opt-in, with manual checks in Settings > General. A Homebrew cask is Coming.

I would like to hear what feels clear, what feels busy, and which workflow you would test first.

https://github.com/ThisRadLife/shakeboard

## Product Hunt

### Tagline

Clipboard history and paste stacks for your Mac

### Description

ShakeBoard keeps clipboard history, a file drag shelf, paste stacks, and pinboards in one strip at the bottom of your Mac. It is open source, keeps your data on your Mac, and includes on-device OCR plus optional read-only MCP access for Claude Code and Codex.

### First comment

Hi Product Hunt. I made ShakeBoard because I kept losing the temporary things between apps: a copied address, three snippets that had to be pasted in order, or a file I was still dragging between windows.

ShakeBoard puts those things in one full-width strip at the bottom of the Mac. It handles text, highlighted code, links, images, and files. You can build paste stacks, organize reusable copies in pinboards, search text recognized on-device from images, preview with Quick Look, and edit or transform text.

Privacy shaped the app from the start. Your data stays on your Mac. ShakeBoard has no account or telemetry, and never captures password managers. The only network call is the update check you opt into. Its optional MCP bridge for Claude Code and Codex is off by default, read-only, redacts known secret patterns, asks for consent per client, and records requests without recording clipboard text or search terms. Pattern-based redaction can miss things, so the app does not present it as a guarantee.

ShakeBoard supports macOS 14 and later. The source is available under Apache-2.0, and the first release is a notarized DMG on GitHub. I would value thoughtful bug reports and feedback on the core workflows.
