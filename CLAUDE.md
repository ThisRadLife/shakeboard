# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ShakeBoard is a local macOS **drag-shelf** (a homegrown Yoink replacement): a floating agent app (no Dock or menu-bar icon)
that parks files mid-drag so you can drag them back out later. Local only, no networking (the MCP helper talks to the app over a local Unix socket). Three
targets (app, Share Extension, `shakeboard-mcp` helper) plus a unit-test target. One full-width **strip** at the bottom of the screen holds shelf files,
pinned and recent copies (and the stack lane while it's open); the stack bar under the
menu bar only shows while the strip is hidden. See `README.md` for the user-facing feature list and
`docs/PERCH_PRD.md` for the full design rationale (including why several approaches were rejected).

## Build & run

The Xcode project is **Tuist-generated** — `ShakeBoard.xcodeproj` / `ShakeBoard.xcworkspace` are gitignored.
Regenerate them from `Project.swift` before building:

```bash
tuist generate                                   # regenerate the workspace from Project.swift
xcodebuild -workspace ShakeBoard.xcworkspace -scheme ShakeBoard -configuration Release \
  -derivedDataPath /tmp/shakeboard-build build        # build OUTSIDE iCloud (see gotcha below)
cp -R /tmp/shakeboard-build/Build/Products/Release/ShakeBoard.app /Applications/
open /Applications/ShakeBoard.app
```

Requires macOS 14+, Xcode 26+, Tuist 4.x. Swift 5 language mode (`SWIFT_VERSION = 5.0`), deployment
target macOS 14. **Release** builds of `ShakeBoard` and `ShakeBoardShare` sign with the maintainer's
**Developer ID Application** team + hardened runtime; **Debug** and the `ShakeBoardTests` bundle sign ad-hoc (`-`), so a
clone without the certificate can build and test. The identity is pinned per target and configuration
in `Project.swift` because Tuist's per-target default (`-`) otherwise wins and a plain Release
`xcodebuild` silently signs ad-hoc. Release also disables Xcode's base-entitlement injection so
`get-task-allow` cannot enter notarized binaries; Debug keeps the injected debugging entitlement.
CI builds with `CODE_SIGNING_ALLOWED=NO`.

- **Never build into a DerivedData path inside iCloud Drive.** `codesign`
  chokes on iCloud's extended attributes — always use `/tmp` or another non-iCloud path.
- **Any change to `Project.swift` requires re-running `tuist generate`** before it takes effect.
- **Tests:** `xcodebuild test -workspace ShakeBoard.xcworkspace -scheme ShakeBoardTests -derivedDataPath /tmp/...`
  (the `ShakeBoardTests` scheme, not `ShakeBoard`). Unit tests inject the pasteboard, clock, filesystem and event
  poster -- they must never touch the real general pasteboard or `Application Support/ShakeBoard`. Focus,
  Spaces, Secure Input, privacy prompts and real paste stay in the manual matrix.
- **`SHAKEBOARD_DATA_DIR=<dir>`** relocates shelf.json, `Shelf/` and `Clips/` (and moves prefs to a separate
  defaults suite, and disables the login-item self-heal). Always set it when running a branch build --
  `ShelfModel.load()` migrates `shelf.json` forward and can strand an older installed build.
  `PERCH_DATA_DIR` remains supported for compatibility; `SHAKEBOARD_DATA_DIR` wins when both are set.
  With it set, `PERCH_DEBUG_CLIPS=1` logs every capture decision and `PERCH_DEBUG_SHOW=strip,stack,shelf,edit,settings,pinboards,snapshot`
  opens that UI ~6 s after launch (`stackfill` also queues the 4 newest clips into the collecting stack; `stacks` seeds sample clips and stacks --
  one Ready (marked only, the clipboard is never written), one Collecting, one archived -- add `collectonly`, `stacksfilter`, and
  `barsnapshot` to write the bar to `bar-snapshot.png`) (scripts can't send the hotkeys -- macOS blocks synthetic keystrokes);
  `pinboards` seeds eight local sample copies and three boards, opens Gallery addresses, and with `snapshot` writes
  `strip-pinboards.png` plus the All view `strip-pinboards-all.png`;
  `PERCH_DEBUG_SHOW=preview` opens the real Quick Look panel and logs whether ShakeBoard got activated.
- The app is `LSUIElement` (agent: no Dock icon, and no menu-bar icon since v2 PR 5 -- see Reachability below).
  After install, first run needs
  **Accessibility** permission granted (powers the global mouse monitor / shake) — an ad-hoc rebuild
  changes the signature and can require re-granting it. Clipboard reads rely on the macOS 26+
pasteboard-access setting being "Always Allow" for ShakeBoard.

## Architecture

### Naming

The product, targets, bundle identifiers, paths, helper, socket, URL scheme, and user-facing strings use ShakeBoard.
Internal Swift type names such as `PerchApp`, `PerchPrefs`, `PerchPaths`, `PerchID`, `PerchTheme`, `PerchHotKeys`,
`PerchGlass`, and `PerchGlassRole` intentionally remain to avoid unrelated churn during the app rename.

Three targets defined in `Project.swift` (the third, `ShakeBoardMCP`, is the MCP helper -- see "MCP bridge" below):

1. **`ShakeBoard`** (`Sources/ShakeBoard/PerchApp.swift`) — the main app. **Non-sandboxed by design** (no
   entitlements file): it needs a global `NSEvent` mouse monitor and must read the extension's
   handoff folder. `PerchApp.swift` holds the shelf: the SwiftUI `App`, `AppDelegate`, model, drag
   view, shake detector. Clipboard features live beside it: `ClipboardMonitor.swift`
   (capture + filtering + the one tagged pasteboard writer), `ClipStore.swift` (history persistence),
   `Strip.swift` / `StripModel.swift` (the strip + its stack lane), `Settings.swift` (the Settings window), `ClipPaste.swift` (paste into the
   target app), `Transforms.swift` (edit/transform), `HotKeys.swift` (global shortcuts),
   `PasteStack.swift` (multiple paste stacks: collect / ready / archive + the stack bar), `Stacks.swift` (stack model,
   `stacks.json`, the Split into Stack splitter),
   `GlassStyle.swift` (Liquid Glass on macOS 26+, material fallback), and the MCP bridge (`AIBridge.swift`,
   `AIAccess.swift`, `AIRedactor.swift`, shared `Sources/Shared/MCPCore.swift`).
2. **`ShakeBoardShare`** (`Sources/ShakeBoardShare/ShareViewController.swift`) — a macOS Share Extension.
   **Always sandboxed** (Apple forbids opting out); entitlements grant only user-selected-file read.

### The Share Extension handoff (the non-obvious cross-target flow)

Content currently moves between the targets through a custom URL scheme, **not** an App Group:

1. `ShareViewController` normalizes each shared item (file / image / web link / selected text) into
   a real file inside `ShakeBoardHandoff-<uuid>/` in its **own sandbox temp container**.
2. It calls `shakeboard://add?dir=<that folder>` via `NSWorkspace.open`.
3. `AppDelegate.handleURLEvent` receives it (registered as an Apple Event `kAEGetURL` handler, since
   an `LSUIElement` agent gets URLs this way).
4. ShakeBoard **validates** the dir, copies the regular files onto the shelf, then deletes the handoff.

**Security matters here.** `shakeboard://` is world-invocable — any app or web link can call it, so `dir`
is untrusted. `validatedHandoffDir` accepts **only** a `ShakeBoardHandoff-<uuid>` folder sitting directly
inside the extension's sandbox container (`~/Library/Containers/com.thisradlife.shakeboard.share/Data/tmp`),
and `ingestHandoff` skips symlinks and subdirectories. This is what stops
`shakeboard://add?dir=/Users/you/Documents` from copying out and deleting arbitrary paths. **Preserve
these checks** when touching the handoff code — they were hardened in an adversarial review
(commit `e07171e`).

> A future migration can move the handoff folder to a shared App Group
> (`group.com.thisradlife.shakeboard`) while leaving the rest of the flow unchanged.

### Two on-disk locations (don't conflate them)

- `~/Library/Application Support/ShakeBoard/shelf.json` — the persisted shelf: file **bookmarks** (not
  paths) so Finder-dragged originals survive moves/reboot. Missing files grey out
  rather than vanish.
- `~/Library/Application Support/ShakeBoard/Shelf/` — **copies** ShakeBoard owns, made when ingesting shared
  content (which has no stable "original" to bookmark). Finder drag-ins are bookmarked, not copied;
  shared items are copied. **Copy-only always — originals never move.**

### Migration from Perch

The shipping rename performs one launch-time migration before any data store or preference is read. If only
`~/Library/Application Support/Perch` exists, it is moved to `ShakeBoard` with one atomic `rename(2)` after an
`lstat` real-directory/current-owner check. It is never copied or deleted: rename preserves the inodes followed by
plain Shelf bookmarks, plus OCR cache identity, permissions and Time Machine exclusions, without partial state or
double disk use. When both folders exist, marker files (`shelf.json`, `Clips/clips.json`, `pinboards.json`,
`stacks.json`, `clip-pins.json`) and non-dotfile entries directly inside `Clips/` or `Shelf/` determine whether each
folder has real data; symlinked marker files, empty directories, runtime-only `mcp/` contents and breadcrumbs do not.
If ShakeBoard is empty and Perch has real data, the old-app guard runs first, then the empty folder is set aside with
the same atomic no-replace rename as `ShakeBoard.empty-<unix timestamp>` (adding `-2`, `-3`, etc. on collision) before
the normal verified Perch move. A set-aside or move failure uses Perch in place for that launch, shows a General-
settings failure, and retries next launch. If both folders have real data, ShakeBoard wins without merging or touching
either folder and a General alert names the leftover Perch path; there is no alert-dismissal state, so the row and gear
dot return each launch while both populated folders remain. If neither exists this is a fresh install. Preferences are
copied once from the exact `com.dadequate.perch` CFPreferences domain without overwriting new-domain values or
changing the old domain. A move or preference migration shows the one-time rename welcome and permission re-grant
links; unit tests and `SHAKEBOARD_DATA_DIR` / `PERCH_DATA_DIR` dev runs skip migration.

### Cold-launch ordering constraint (easy to break)

`model.load()` runs in `applicationWillFinishLaunching`, **before** the `shakeboard://` handler is
registered. A cold-launch handoff URL is delivered between will- and didFinishLaunching; ingesting
into an unloaded model would `save()` over `shelf.json` with only the new item and **wipe the
existing shelf**. Keep the load before the handler registration.

### Drag-in accepts file promises, not just URLs

`DropView.performDragOperation` handles two pasteboard shapes: direct `.fileURL` (Finder, most apps)
**and** `NSFilePromiseReceiver` promises (sandboxed editors like VS Code / Codex / Mail hand files
over as promises). Dropping either works; promises are materialized into a temp dir first. A passive
drag-pasteboard sniff was tried and proven unreliable on macOS 27 — drag-in goes through the AppKit
`NSDraggingDestination`, not a global sniff.

### Other pieces in `PerchApp.swift`

- **`ShakeDetector`** — counts back-and-forth reversals in the global mouse stream. `CalibrationSession` owns the timed calibration monitor and samples. Calibratable
  (record your own shake → stored in `UserDefaults`); Tight/Medium/Loose adjust a `variance`
  tolerance. Rule: fires while dragging, or (not dragging) only if the shelf has items — never on an
  idle empty shelf. Calibration temporarily adds a local mouse monitor and enables mouse-moved events
  on Settings, but local events are samples only and never enter shake detection. The opt-in
  `debugShakeLog` preference logs global/local event and current reversal counts once per second.
- **`GlobalHotKey`** — Carbon `RegisterEventHotKey`. Handlers are keyed by id in a static dict because
  the C callback can't capture Swift context. Releasing the object unregisters it.
- **`PerchHotKeys`** (`HotKeys.swift`) — the only global shortcuts: **Command-Space** shows/hides the
  strip; an optional user-recorded **stack shortcut** (prefs key `stackShortcut`, unset by default)
  stops all collecting and pasting, or else starts collecting into the selected stack. The Stacks button in the strip always works. **Never register Command-C /
  Command-V (or other plain Command editing keys) globally** -- a Carbon hotkey swallows the keystroke
  system-wide, breaking copy/paste and the paste stack's Cmd-V watcher; `HotKeyCombo.isAllowedForStack`
  enforces this for the recorded shortcut. Registration failures are listed in Settings > Shortcuts. While
  Settings records a new stack shortcut, `suspendStackShortcut(true)` unregisters the current one so it can be
  re-typed.
  Cmd-Space assumes Spotlight has been moved off Command-Space.
- **`healLoginItem`** — re-registers the `SMAppService` login item only when the binary's mod-time
  fingerprint changed (an ad-hoc rebuild orphans the prior registration). It deliberately leaves a
  user who turned the login item off alone. Moot once stably signed.
- The shelf is a non-activating, borderless, floating `NSPanel` that never calls
  `NSApp.activate` — it must never steal focus from the app you're working in. It *can* become key
  (`ShelfPanel`) but only when clicked, and hands the keyboard back when the pointer leaves
  (`relinquishKey` = `resignKey()`, order-out/in only as a fallback), when its preview closes, or 4 s
  after the click with no handled key (`KeyLease`). Hovering never takes typing away from the app you're in.

### Paste stacks (`PasteStack.swift`, `Stacks.swift`)

- Several named stacks in `stacks.json` (active + archived, 0600, unreadable file set aside, never overwritten). Each
  stack is Idle, **Collecting** (captures append; the clipboard is untouched, so Cmd-V is normal) or **Ready** (ShakeBoard
  writes the next item; the global Cmd-V keyUp advances). At most one of each, on different stacks: arming a stack
  ends collecting on it, collecting into the Ready stack disarms it. Neither state is persisted -- every launch is Idle.
- Ready keeps the single stack's safety rules: act only while the clipboard's changeCount is ShakeBoard's own write (else
  pause), one pending advance bound to the armed session and the item's token, restore the pre-arm clipboard only if
  ShakeBoard still owns it. A copy collected while another stack is Ready puts the Ready item straight back; a copy that
  isn't collected is left alone (the Ready stack pauses on the next Cmd-V).
- The last paste ARCHIVES the stack (items kept, `pastedCount`); the strip's Stacks filter shows active + archived
  stacks, Paste Again re-arms from the top. Archive capped at 30.
- Every clip any stack references (active or archived) is in `ClipStore.pinned`: safe from retention and Clear
  History, like a pin. Load stacks BEFORE `clipStore.load()` (retention runs inside it), prune after.
- Split into Stack makes each piece a derived clip (`derivedFrom` the source, inherits hidden-from-AI) and a new stack.

### Text in images (`TextRecognition.swift`)

On-device Vision OCR runs serially on a utility queue after image clips are committed and lazily backfills newest first.
Clip results live as owner-only `Clips/<uuid>/ocr.txt` sidecars (an empty file means OCR ran and found nothing); shelf
image results live in owner-only `shelf-ocr.json`, keyed by item id plus file size and modification time. Shelf originals
are only read through their resolved security-scoped bookmarks and are never modified. The Clipboard setting is on by
default; turning it off drops queued work, clears recognized text from memory, and deletes all clip `ocr.txt` sidecars
plus `shelf-ocr.json`.
Shelf bookmark resolution/stat runs off main and feeds the same metadata to validation and recognition. Cache writes use
a separate revision-coalesced serial queue (never the Vision queue), removals rewrite immediately, and quit performs a
bounded flush. Copied images linked to owned shelf files reuse the clip's per-image OCR result instead of running Vision
twice. Search uses an off-main, lowercased OCR index capped at 64 KB per item; MCP `shakeboard_search` returns only a bounded
match snippet for image OCR, while `shakeboard_get` remains the full-OCR endpoint. Single-pinboard search uses the same
clip OCR index as the All view.
All Copy/Paste Text actions create normal derived text clips and use the existing tagged writer and paste path.
- Multi-select: `StripState.picks` (`ClipPicks`, StripModel.swift) is an ORDERED list of clip ids -- click order is the
  send order. Command-click toggles (the first one seeds the current cursor copy as #1, like Finder), Shift-click
  appends the visible run left to right. Clips only (stacks never hold shelf files). A card's menu acts on all picks
  when it's one of them, else on just that card. `PasteStack.send(_:to:)` appends in order, stops at the first copy
  that doesn't fit, and offers Undo (removes exactly those slots; a stack it created is removed again). Picks clear
  on summon, plain click, arrows, Escape, any query/filter change (only visible cards are ever sent) and after a
  send; picks no longer on screen (deleted, or pushed past Recent's cap) drop out via `reconcile`. Undo is refused once the stack is Ready (its order is in use).
  Click modifiers come from `StripClickFlags` (mouse-DOWN flags via a local monitor), not the live state at tap.

### Pinboards (`Pinboards.swift`)

- `PinboardStore` owns ordered named/color boards in `pinboards.json` (versioned, atomic, 0600). Every mutation is
  transactional: a failed write restores the prior in-memory value and sets `lastSaveFailed`. An unreadable/future
  file is moved to `pinboards.json.unreadable-<timestamp>` before ShakeBoard starts over; if it cannot be moved, the store
  is read-only and the damaged file is never overwritten.
- On the first load without `pinboards.json`, the old ordered `clip-pins.json` ids migrate into a yellow board named
  Pinned. The old file stays untouched. `isDefaultPinned` is persisted identity, not a name/position convention, so
  that board can be renamed, recolored and moved but not deleted. `ClipPins` remains as a compatibility facade for
  Pin/Unpin and the All-view Pinned section; the legacy file is no longer live state.
- Load pinboards and stacks **before** `clipStore.load()` because retention runs during that call. `clipStore.pinned`
  is the union of every board and every active/archived/undo-held stack. Prune stale board ids only when ClipStore is
  not degraded. Removing membership or deleting a board re-runs retention immediately; deleting a board never deletes
  a copy directly.
- Board chips follow the kind filters. Board and kind filters are mutually exclusive; board view is one searchable,
  persisted-order section. Internal clip-ref drops add/reorder without replacing the external file/text drag payload.
  Option-1 through Option-9 adds the selected copy to that board; bare and Command digits keep their paste behavior.
- MCP records include `boards: [name]` only after the clip has passed the existing hidden-app/hidden-clip ancestry
  gate. Board names are redacted at serve time like other returned strings; hidden clips reveal no membership.

### Smooth wheel + shake-to-close (`SmoothScroll.swift`)

- Scroll views opt in with `.smoothWheel(.horizontal/.vertical)` on their content (an `NSViewRepresentable` anchor that
  registers its `enclosingScrollView` -- SwiftUI's `HostingScrollView`). One local `.scrollWheel` monitor takes only
  NON-precise ticks (classic wheel), moves a clamped target (`EasedScroll`) and eases the clip view toward it on the
  view's `displayLink` (tau 40 ms, no overshoot). Precise/momentum scrolling (trackpad, Magic Mouse) is never touched.
  A tick over a view with nothing to scroll falls through to the next registered ancestor. If anything else moves the
  view mid-glide (keyboard `scrollTo`), the glide yields. Reduce motion jumps instead. Programmatic scrolls use
  `Motion.scroll`. Dev: `PERCH_DEBUG_SHOW=wheeltest` seeds 40 clips, summons the strip and logs a synthetic glide
  (`PERCH_DEBUG_SCROLL=1` logs registrations).
- `ShakeToggle`: a shake-opened strip closes on the next shake, with a 1 s cooldown each way. It never closes while
  you're dragging (that's the reveal gesture), while summoned/editing/previewing, or when Command-Space or a copy
  reveal opened it. While a shake-opened strip is up, plain mouse shakes are fed to the detector even with an empty shelf.

### Settings window (`Settings.swift`)

- Opened from the strip's gear, Command-comma in the strip, and by relaunching ShakeBoard (see Reachability). A plain AppKit
  `NSWindow` hosting SwiftUI -- **not** the SwiftUI `Settings` scene / `openSettings` (unreliable from an agent
  app). ShakeBoard switches to `.regular` (Dock icon, a minimal main menu for Edit/Cmd-W/Cmd-Q, real activation) only
  while the window is open, and back to `.accessory` on close, re-activating the app you were in. Opening it
  dismisses a summoned strip first; the strip's own no-focus-steal rules are unchanged.
- `PerchPrefs` wraps the prefs suite (keys `addImagesToShelf`, `shakeVariance` kept from earlier builds; new:
  `shakeToShow`, `capturePaused`, `historyMaxCount`, `historyMaxDays`, `ignoredApps`, `reduceOnDrag`, `debugShakeLog`)
  and sanitizes every value.
  A missing `ignoredApps` defaults to Apple Passwords (`com.apple.Passwords`); the one-time
  `ignoredAppsPasswordsSeeded` migration adds it to an existing list without re-adding it after a user removes it.
  `AppDelegate.applyPrefs()` pushes changes into the monitor, store retention and shake.
- `SettingsAlerts` turns every failure that used to be a status-menu line (Accessibility off, shelf / history /
  pins save failures, Clear History failure, degraded history, add failures, hotkey failures, login-item errors)
  into a row in its section; any failure lights the orange dot on the strip's gear (`StripState.gearAlert`),
  refreshed by a cheap 2 s tick. A user-chosen pause is shown but isn't a warning.
- Dev: `PERCH_DEBUG_SHOW=settings` opens it; add `snapshot` to write `settings-<section>.png` per section into
  `SHAKEBOARD_DATA_DIR`.
- Settings links directly to Accessibility, Login Items, Keyboard Shortcuts and pasteboard privacy. Shelf & Shake
  owns the `reduceOnDrag` toggle and confirmed Clear Shelf action; the strip's Shelf header keeps only the compact
  drag-out handle and offers confirmed clearing from its context menu.

### Themes (`Themes.swift`)

- `ThemeStore` owns the built-in and custom `PerchTheme` values and persists selection/data under the
  `themeSelected` and `customThemes` preference keys. It sanitizes custom IDs, names, colors, duplicates, and the
  20-theme limit on both read and write; corrupt data is ignored without being overwritten.
- System is the unchanged dynamic accent/red + glass rendering path. Every other theme is an opaque panel/card
  surface with its own light or dark appearance. The shared store is injected into the strip, stack bar/lane, and
  Settings so edits apply live.
- The edit surface is fully opaque in every theme (including the System theme's native text-background color), so
  content in windows behind the translucent strip cannot show through below the last edited line. Card previews
  keep their translucent System-theme treatment.
- Dev runs still require `SHAKEBOARD_DATA_DIR`: `PERCH_DEBUG_THEME=<id>` selects a launch theme without touching normal
  preferences, and `PERCH_DEBUG_SHOW=stripsnapshot` writes `strip-snapshot-<themeid>.png` after showing the strip.

### App icon

- `Sources/ShakeBoard/AppIcon.icon` is the macOS 26+ layered Icon Composer source. The matching
  `Sources/ShakeBoard/Assets.xcassets/AppIcon.appiconset` remains the macOS 14/15 fallback; both use the `AppIcon` name.

### Reachability -- no menu-bar icon (`Reachability.swift`)

- There is no `NSStatusItem`. Ways in: Command-Space (strip); the strip's gear and **Command-comma** (Settings);
  **Command-Q** in the strip (quit -- the strip's key monitor only sees events aimed at its own panel, so it's never
  global; Cmd-Q is ignored while editing, Cmd-comma isn't).
- `applicationShouldHandleReopen` (relaunch from Spotlight / Finder / Dock while running) opens Settings and
  reveals (not summons) the strip.
- There is no launch-time strip reveal. At launch, `LaunchGreeting` decides: a cold launch you started shows Settings once (General); a login-item launch
  (`keyAELaunchedAsLogInItem`, or within 3 min of the console login in utmpx -- SMAppService doesn't always set the
  flag, and only when launch-at-login is on) stays silent; a validated Share-Extension cold launch stays silent
  (no focus theft); a failed Command-Space opens Settings on Shortcuts even at login (no other way in). Dev runs
  with `PERCH_DEBUG_SHOW` stay silent. **Never remove all of these at once** -- an agent app with no icon and no
  working hotkey is unreachable short of Activity Monitor.
- Every open (Command-Space, shake, a copied image, relaunch) calls `StripState.goHome()`: the newest copy is selected
  and scrolled to the strip's LEFT edge (a shelf can hold ~90 files before Recent). Pinned and Shelf are a
  scroll to the left. A shake on an already-shown strip doesn't re-home. Dev: `PERCH_DEBUG_SHOW=bigshelf` seeds 40 shelf files.

### MCP bridge (`Sources/Shared/MCPCore.swift`, `AIBridge.swift`, `AIAccess.swift`, `AIRedactor.swift`)

- **`shakeboard-mcp`** (target `ShakeBoardMCP`, `Sources/ShakeBoardMCP/main.swift`) is a stdio MCP server embedded at
  `ShakeBoard.app/Contents/MacOS/shakeboard-mcp` by the ShakeBoard target's "Embed shakeboard-mcp" script phase (signed by its own target
  with the same identity + hardened runtime). It is a **dumb pipe**: hand-rolled JSON-RPC 2.0 (`MCPServer`: initialize
  + version negotiation, ping, tools/list, tools/call; no SDK) that forwards each tool call to the running app over
  `<data>/mcp/shakeboard.sock`. It must never read ShakeBoard's data folder itself. Before sending, it verifies the listener
  (`CodeIdentity.verifyPeer`): same uid, the ShakeBoard.app bundle it lives in, same Team ID -- so a process that replaces
  the socket can't feed it fake "clipboard" content.
- **App side.** `AIBridgeServer`: dir 0700 (must be a real dir owned by us, never a symlink), socket 0600, a stale
  socket is removed only if it is a socket. Each connection: same uid, and the peer's audit-token `SecCode` must be
  THIS bundle's `shakeboard-mcp` signed by our team (refusals audited as `peer_refused`). Hygiene only -- any same-user
  process can run the real helper -- so the real gates are in `AIBridgeService` / `AIGate`, in this order: master
  switch (`aiAccessEnabled`, **off by default**) -> consent -> 30 calls/min (charged only to an allowed app). **Consent
  is keyed by the verified launcher of the helper** (`AIInvoker`: its parent's code signature `team:<TEAM>:<id>`, else
  `path:<exe>`; only the system shells at `/bin/*` / `/usr/bin/env` are skipped, up to 5), never by the self-reported
  MCP `clientInfo.name`. The panel headline and the audit log use the verified name; the reported name shows as
  "not verified". First call from a new launcher shows `AIConsentPanel` (non-activating, no default button; at most 3
  open) and is refused as pending. An unidentifiable launcher is refused. **Threat model:** this guards *which AI tool
  the user approved*; it is not a wall against malicious code running as the user (that can read `Clips/` directly),
  and an interpreter (node, python) is one identity for every script it runs.
- **What's served.** `AIToolEngine` runs on a snapshot taken on main: hidden = password managers + `aiHiddenApps` +
  `AIHiddenClips`, followed through the whole `derivedFrom` chain (and an edit/transform of a hidden copy is marked
  hidden at creation, and `AIVisibility.persistInheritedHides` -- run from `ClipStore.willDrop` (before retention,
  Clear History or delete can remove a clip, including retention inside `load()`), on prefs changes, Hide, and each AI
  call -- gives every descendant its own mark, so evicting an ancestor can't un-hide it). Text is read off main with a bounded `FileHandle` read
  (`AIRecord.read`), cut to a raw byte budget (+8 KB margin) BEFORE redaction, redacted by `AIRedactor` at serve time; search runs over redacted text only; each
  call has a 24 MB / 3 s budget (`partial: true` when hit). Every payload carries `untrusted_content: true`. Shelf file
  NAMES are only searchable with `aiIncludeShelfNames` (off by default); stats never report hidden counts.
- **Redaction rules must stay linear**: every quantifier that can start anywhere in a run is bounded (an unbounded
  `[class]+@` hung the suite on 256 KB of `a`). `testHostileInputStaysLinear` guards it.
- **Audit** (`<data>/mcp/audit.jsonl`, 0600, trimmed at 1000 lines): time, client, tool, outcome, counts. Never text,
  queries or clip ids.
- Secret fixtures in tests are assembled from fragments at runtime -- never commit a contiguous real-looking token.
- Settings > Privacy & AI: master switch, contacts + shelf-names toggles, Connect (runs `claude mcp add ...` /
  `codex mcp add ...` in a login shell; disabled in a dev run so a branch build is never registered), allowed apps
  (revoke / forget), hidden apps, request log. Dev: `PERCH_DEBUG_SHOW=consent,snapshot` writes `consent-snapshot.png`;
  Settings snapshots render 1250 pt tall. With `SHAKEBOARD_DATA_DIR` (or legacy `PERCH_DATA_DIR`), keep the socket path
  under 104 bytes (short `/tmp` dir).

### Quick Look (`QuickLook.swift`)

Space previews like Finder: shelf (selected or hovered chip; Left/Right move, multi-select = list),
strip (selected card), stack bar (hovered card, else the next).
- **Not `QLPreviewPanel`.** Probed on macOS 27.3 from an `.accessory` app: it doesn't activate ShakeBoard, but
  it's a normal-level, activating-style panel that never becomes key in an inactive app (so its own keys
  can't work, and the next click elsewhere buries it). ShakeBoard hosts a `QLPreviewView` in its own
  `PreviewPanel`: nonactivating, `canBecomeKey == false`, floating. The ShakeBoard panel the user is in keeps
  the keyboard and drives it. Trade-off: no native QL toolbar (Open With / Share / full screen).
- **Temp files** (clip previews only; shelf files preview in place) go to
  `$TMPDIR/ShakeBoardPreview-<pid>-<uuid>/` -- `PreviewTempDir` refuses any path inside ShakeBoard's data dir, so
  never `Shelf/` or `Clips/`. Deleted on close/retarget; the launch sweep removes dirs of dead processes.
- Shelf click is Finder-style now: a plain click always selects exactly that chip, Command-click toggles,
  Shift-click ranges, a click on empty shelf space clears. Drag-out drags the selection (or everything
  when nothing is selected), as before.
- Clip previews are hard links to the Clips/ sidecars (no copy), materialized off main; Clear History
  and quit close them and delete the temp dir first.
