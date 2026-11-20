# Historical design doc from when the app was called Perch

# Perch -- Product Requirements Document

**A local macOS drag-shelf and alternative to Yoink.**
Version 0.1 (v1 scope) - 2026-06-24

> **Superseded (v2, 2026-11):** Perch no longer has a menu-bar icon (`NSStatusItem`). The status-menu items
> described below moved to the Settings window (gear in the strip / Command-comma / relaunch). See README.md and
> CLAUDE.md "Reachability" for current behavior; this document is the v1 design record.

---

## Summary

Perch is a menu-bar macOS app that gives you a floating "shelf" to park files and folders mid-drag. Start dragging any file anywhere on screen and the shelf slides in at the edge; drop files onto it to stash them; later, drag them back out into any app, Finder, an upload field, or a terminal (where dropping pastes the file's path). It is a non-activating floating panel that never steals focus, lives in the menu bar with no Dock icon, and the shelf survives quit and reboot. v1 is **local only** -- no cloud, no networking, no cross-device transfer. The build is grounded in the proven AppKit/SwiftUI mechanics from the open-source Dropp reference (read for the APIs, not copied -- Dropp carries no license).

**One honesty note up front:** Dropp's shelf is in-memory + cloud-backed -- it has **no local item persistence at all**. So Perch's most important survival feature (the on-disk shelf store) is **net-new code**, not a "strip the cloud bits" adaptation. Budget accordingly.

---

## Goals & Non-Goals

### Goals (v1)
- Replace Yoink's core daily loop: drag-start auto-reveal, stash files, drag back out.
- Floating shelf that never steals focus from the app you're working in.
- Persist the shelf across quit/restart/reboot.
- Menu-bar resident, no Dock icon, launch-at-login option.
- Drag-out works into any app, Finder, web upload fields, and terminals (path-paste).
- Signed and runnable locally on the maintainer's Mac. No App Store.

### Non-Goals (explicitly OUT of v1)
- Cross-device transfer / cloud / sync -- adopt **LocalSend** (free, open-source) separately; a "Send via LocalSend" hand-off is a **P1** add, not v1.
- Any networking, accounts, auth, or API.
- ~~Text / image / URL clips (P1).~~ **Superseded 2026-11-10:** clipboard history, copied images
  to the shelf, and sequential paste stacks are now implemented.
- Item stacking / grouping (P1). (The paste stack above is a clipboard queue, not shelf grouping.)
- Multi-monitor edge-trigger plumbing.
- Mac App Store distribution.

---

## Window / Panel Architecture

The shelf is a single **`NSPanel`**, not a standard window, configured to float and never take focus. Grounded in Dropp's `AppDelegate.applicationDidFinishLaunching` and `WindowLayout`:

```swift
let panel = NSPanel(
    contentRect: NSRect(origin: .zero, size: WindowLayout.targetSize),
    styleMask: [.nonactivatingPanel, .borderless],
    backing: .buffered,
    defer: false
)
panel.contentViewController = NSHostingController(rootView: rootView) // SwiftUI inside AppKit panel
panel.isFloatingPanel = true
panel.becomesKeyOnlyIfNeeded = true   // only becomes key when a control truly needs it
panel.hidesOnDeactivate = false       // stay visible when our app isn't active
panel.isReleasedWhenClosed = false
```

Never-steal-focus contract:
- **`.nonactivatingPanel`** style mask -- accepting a drag/click does not activate the app.
- **`becomesKeyOnlyIfNeeded = true`** + **`isFloatingPanel = true`**.
- We never call `NSApp.activate(ignoringOtherApps:)` on a normal reveal. (Dropp activates on some button taps; Perch v1 keeps reveals passive so focus stays in the foreground app -- that's the whole point.)
- **Remove BOTH activation-hide observers.** Dropp installs `didResignActiveNotification` (hide) AND `didBecomeActiveNotification` (hide, via `handleApplicationBecameActive`), plus `skipNextActivationUpdate` gymnastics around `showWindowSuppressingActivationUpdate`. For Perch's always-visible-while-working model we delete **both** observers and the suppression dance entirely; otherwise the panel flickers/hides when any control inside it becomes key. Visibility is governed only by drag-start reveal, click-outside, the empty-shelf rule, the hotkey, and the menu.

Level, behavior, geometry (from `WindowLayout.configure` / `applySizeAndPosition`):
- `window.level = .floating` -- sits above normal windows.
- Borderless + transparent: `titleVisibility = .hidden`, `isOpaque = false`, `backgroundColor = .clear`, standard window buttons hidden, content layer `cornerRadius = 10`, `masksToBounds = true`.
- Non-movable, non-resizable (`isMovable = false`, no `.resizable`).
- **Collection behavior across Spaces:** set `window.collectionBehavior = [.canJoinAllSpaces, .stationary]` so the shelf shows on every Space and isn't swept by Mission Control. (Dropp only *removes* `.fullScreenPrimary`/`.fullScreenAuxiliary`; we add the all-Spaces flags explicitly.) **Re-apply** collection behavior AND edge position inside the `didChangeScreenParametersNotification` handler so a Space switch or display change can't reset them.
- **Position:** right edge, vertically centered -- `x = visibleFrame.maxX - width`, `y = visibleFrame.midY - height/2`. Re-applied on screen-parameter change.
- Target size ~`160 x 400` (tunable).

Reveal/hide is animated alpha (`NSAnimationContext`, ~0.2s) via a `WindowVisibilityController` as Dropp does -- `orderFrontRegardless()` on show (does not activate the app), fade-then-`orderOut(nil)` on hide.

---

## Reveal Model (the Yoink feel)

Three independent triggers, all in `AppDelegate`:

### 1. Drag-start auto-reveal (primary)
A global mouse monitor sniffs the drag pasteboard the instant a file drag begins anywhere on screen. Grounded in Dropp's `FileDragStartObserver`:

```swift
NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
    self?.handleDragged()
}
NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
    self?.handleMouseUp()
}

private func handleDragged() {
    let pb = NSPasteboard(name: .drag)
    guard pb.changeCount != lastFiredChangeCount else { return } // fire once per drag
    lastFiredChangeCount = pb.changeCount
    let fileTypes: Set<NSPasteboard.PasteboardType> = [.fileURL, .URL]
    if !fileTypes.isDisjoint(with: Set(pb.types ?? [])) {
        onFileDragStart()   // -> visibilityController.setVisible(true)
    }
}
```
- The `.drag` pasteboard `changeCount` gate ensures one reveal per drag, not per move event.
- On `.leftMouseUp` after a drag, schedule a hide after a short grace delay (~300ms) **unless** the shelf is non-empty or the cursor is over it.
- **This monitor is the #1 permission/privacy risk -- see Permissions and Spike T1.**

### 2. Global hotkey (toggle)
> **Superseded (2026-11-12, v2 PR 3):** the shipped default is **Command-Space** (assuming Spotlight has
> been moved off it), plus an optional user-recorded stack shortcut, unset by default. See `HotKeys.swift`. The
> original Control-Option-Space design is kept below as history.

Carbon `RegisterEventHotKey` (works system-wide **without** Accessibility), as in Dropp's `registerGlobalHotKey`:
```swift
// Default chord: Control-Option-Space (locked)
let mods = UInt32(controlKey | optionKey)
RegisterEventHotKey(UInt32(kVK_Space), mods, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
```
- **Default is locked to Control-Option-Space** (not Dropp's bare F10, which collides with Mission Control / function-key behavior). Verify on the test Mac that it doesn't collide with Spotlight (Cmd-Space) or another launcher; the chord is config-changeable in P1.
- Note: only the drag-start **monitor** may need Accessibility/Input Monitoring -- the **hotkey** never does.
- Toggles visibility with `force: true`.

### 3. Menu-bar toggle
`NSStatusItem` menu item "Show/Hide Shelf" calls the same `visibilityController.setVisible(...)`.

Auto-hide helper:
- A global `[.leftMouseDown, .rightMouseDown, .otherMouseDown]` monitor hides the shelf when you click outside its frame (`!window.frame.contains(NSEvent.mouseLocation)`).
- Hide-on-resign-active is **disabled** (we want persistence while you work in other apps); auto-hide relies on click-outside + empty-shelf rules only.

---

## Drag-IN Mechanics

A custom `NSView` registered for file URLs, wrapped for SwiftUI. Grounded in Dropp's `DropView` / `DropContainer`:

```swift
final class DropView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window != nil ? registerForDraggedTypes([.fileURL]) : unregisterDraggedTypes()
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = s.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: opts) as? [URL], !urls.isEmpty
        else { return false }
        onDrop?(urls)   // -> Shelf.add(urls)
        return true
    }
}
```
- `registerForDraggedTypes([.fileURL])` accepts files and folders.
- `readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])` returns **multiple** URLs -> multi-drop supported.
- Wrapped in an `NSViewRepresentable` (`DropContainer`) so the SwiftUI shelf view lives inside the drop-accepting `NSView`.
- (SwiftUI `.onDrop(of: [.fileURL])` is an acceptable fallback if the AppKit path fights us.)

---

## Drag-OUT Mechanics (and free terminal path-paste)

Each shelf row is an `NSView` that is an `NSDraggingSource`. Grounded in Dropp's `DraggableContainerView` -- with one **deliberate divergence** below.

```swift
private func startDraggingSession(with event: NSEvent) {
    guard let fileURL = item.beginDragAccess() else { return }      // scoped access ON (if scoped)
    let draggingItem = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
    let preview = item.snapshotImage()  // static NSImage, NOT the live hosting view
    draggingItem.setDraggingFrame(bounds, contents: preview)
    let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
}

// LOCKED DIVERGENCE FROM DROPP: copy-only outside the app, never move.
func draggingSession(_ s: NSDraggingSession,
                     sourceOperationMaskFor ctx: NSDraggingContext) -> NSDragOperation {
    return .copy   // Dropp returns [.move,.copy] for ALL contexts -- we must NOT.
}

func draggingSession(_ s: NSDraggingSession, endedAt p: NSPoint, operation: NSDragOperation) {
    item.endDragAccess()    // scoped access OFF (if scoped)
    // v1: do NOT remove on drag-out, and do NOT implement onExternalMove. (Yoink-style persistence.)
}
```
- `NSDraggingItem(pasteboardWriter: fileURL as NSURL)` -- writing a **file URL** (`public.file-url`) to the drag pasteboard is what makes the drop universal.
- **Why terminals get path-paste for free:** the dragging item carries `public.file-url`. Finder/upload-fields consume it as a file; a **terminal** (Terminal.app, iTerm, VS Code terminal) interprets a dropped file URL by inserting its POSIX **path** as text. One `NSURL` writer satisfies all three targets -- no special-casing.
- **Copy-only is a locked requirement, and Dropp's reference code does the opposite.** Dropp returns `[.move, .copy]` for `withinApplication`, `outsideApplication`, and the default context (ContentView.swift:963-972) and calls `onExternalMove(item)` in `endedAt` to remove/transfer the item. Perch returns **only `.copy`** and implements **no** `onExternalMove`, so a drag into Finder can never move the original off disk.
- **Drag preview:** generate a static `NSImage` snapshot (Dropp's `snapshotImage()` via `cacheDisplay`/`bitmapImageRepForCachingDisplay`) and pass *that* to `setDraggingFrame` -- do **not** pass the live hosting `NSView` as `contents` (fragile, causes drag-image artifacts).
- Per-item **"Copy Path"**: `NSPasteboard.general` with `item.resolvedURL()?.path`.
- Double-click a row = open (`NSWorkspace.shared.open`); reveal action = `NSWorkspace.shared.activateFileViewerSelecting([url])`.

---

## Shelf Data Model & Persistence

**Reality check:** Dropp's `Shelf` is purely in-memory (`@Published items`), and its cross-launch survival comes **entirely from the cloud** (`refreshCloudInventoryOnLaunch`). There is **no `JSONEncoder`/`PropertyListEncoder`/`UserDefaults`/Application Support write of items anywhere** in the reference. Only the **per-item bookmark API** (`ShelfItem.init`, `resolvedURL`, `begin/endDragAccess`) is borrowed. **The entire on-disk store/reload pipeline below is original code** and is the single largest chunk of genuinely new work in v1.

### Model
```swift
@MainActor final class Shelf: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    func add(_ urls: [URL])        // dedup by RESOLVED PATH ONLY (see below)
    func remove(_ item: ShelfItem)
    func clear()
    // every mutation calls persist()
}

@MainActor final class ShelfItem: Identifiable, Hashable, Codable {
    let id: UUID
    private var bookmarkData: Data
    private var usesSecurityScope: Bool   // false in v1 (non-sandboxed)
    let addedDate: Date
    private var cachedDisplayName: String
    var displayName: String { resolvedURL()?.lastPathComponent ?? cachedDisplayName }
    func resolvedURL() -> URL?            // nil => missing/stale (greyed row, see below)
    func beginDragAccess() -> URL?        // startAccessingSecurityScopedResource() only if scoped
    func endDragAccess()
}
```

**Dedup -- by resolved path ONLY.** Dropp's `add` dedups by **filename OR** resolved path (Shelf.swift:31-33: `existingName == standardized.lastPathComponent`), so `~/a/report.pdf` and `~/b/report.pdf` collide and the second is silently swallowed. Perch dedups **only** by `url.standardizedFileURL` / resolved path -- drop the `lastPathComponent` branch. Folders dedup identically (a folder is just a directory URL).

### Persistence (NET-NEW pipeline)
- Make `ShelfItem` `Codable`: `id`, `bookmarkData` (base64), `usesSecurityScope`, `addedDate`, `cachedDisplayName`.
- On **every** add/remove/clear, encode `[ShelfItem]` with `JSONEncoder` and **atomic write** to `~/Library/Application Support/Perch/shelf.json` (`.atomic` option; create the dir if needed).
- On launch: decode the JSON, then a **resolve loop** rebuilds `items` by resolving each bookmark. Write this loop yourself -- nothing in Dropp does it.

**Bookmarks -- default to PLAIN, not security-scoped (non-sandboxed v1).**
`.withSecurityScope` is an **App Sandbox feature**; outside the sandbox it is effectively a no-op and on some OS versions `bookmarkData(options:[.withSecurityScope])` can throw or resolve oddly. So v1 defaults to plain bookmarks; security-scope is the opt-in path reserved for a future sandboxed build (the model already carries `usesSecurityScope` so adding it later is a flag flip, not a rewrite).

```swift
// store (v1 default = plain):
bookmarkData = try url.bookmarkData(options: [],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
usesSecurityScope = false
// restore:
var isStale = false
let url = try? URL(resolvingBookmarkData: bookmarkData,
                   options: usesSecurityScope ? [.withSecurityScope] : [],
                   relativeTo: nil, bookmarkDataIsStale: &isStale)
if let url, isStale { recreateBookmark(from: url) }   // file moved -> refresh
```
Keep Dropp's try/catch fallback shape, but **inverted**: plain is the default, scoped is the fallback/opt-in.

**Missing-file UX is P0 (greyed row), not a silent drop.** If `resolvedURL()` returns nil (parent folder moved, file deleted), **keep the row** and render it greyed/disabled with a "file moved or missing" label rather than vanishing it. Cheap (nil-guard the row), high daily-trust payoff. Interactive *re-locate* stays P1; the greyed state ships in v1.

---

## Permissions / Entitlements & Sandbox Stance

**Sandbox: NON-sandboxed for v1.** The global drag monitor + arbitrary file access push hard against the App Sandbox; staying non-sandboxed keeps v1 simple. (No App Store = no sandbox requirement.) This is also *why* persistence uses plain bookmarks.

**Entitlements / Info.plist:**
- `LSUIElement = true` (`Application is agent`) -- no Dock icon, menu-bar only.
- No App Sandbox entitlement in v1. If sandboxed later: add `com.apple.security.files.user-selected.read-write` + `com.apple.security.files.bookmarks.app-scope`, and flip items to `usesSecurityScope = true`.
- Hardened Runtime ON (needed for Developer ID notarization later, P1).

**>>> FIRST SPIKE -- the global-monitor permission risk <<<**
On modern macOS (14/15/26), a global `NSEvent.addGlobalMonitorForEvents([.leftMouseDragged])` monitor requires **Input Monitoring** (historically also **Accessibility**) approval, and macOS delivers **zero events, silently, with no prompt** if ungranted -- so the marquee auto-reveal can silently no-op. This is the make-or-break unknown.

**You cannot detect "monitor installed but never firing" from the monitor itself** (no callback, no error when ungranted). So the app must **preflight the TCC grant independently at startup**:
- For **Input Monitoring:** `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` / `CGPreflightListenEventAccess()`.
- For **Accessibility:** `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions`.

If not trusted, immediately surface a one-time "Enable in System Settings -> Privacy & Security -> Input Monitoring (or Accessibility)" prompt with an `x-apple.systempreferences:` deep link (pattern: Dropp's `promptForDiskAccessIfNeeded`) -- don't wait for a drag that will never report. **T1 must determine WHICH permission `[.leftMouseDragged]` actually needs on the test Mac**, because the preflight API differs per permission.

Full Disk Access is **not** required for v1's user-dragged files; we skip Dropp's FDA prompt unless a real need surfaces.

---

## Menu Bar & Launch-at-Login

- **Menu bar:** `NSStatusItem` with a template icon. Items: *Show/Hide Shelf*, *Clear Shelf*, *Launch at Login* (toggle), *About*, *Quit*. (Dropp uses an in-panel popover; Perch moves these to the status menu to keep the panel minimal.)
- **No Dock icon:** `LSUIElement`. App scene is `Settings { EmptyView() }` with `@NSApplicationDelegateAdaptor` driving everything from `AppDelegate` (Dropp's `DroppApp` shape).
- **Launch at login:** `SMAppService.mainApp.register()` / `.unregister()` (ServiceManagement, macOS 13+). Reflect current state via `SMAppService.mainApp.status`. (Not in Dropp -- standard macOS 13+ API.)

---

## Scope: P0 (v1) vs P1

### P0 -- v1 ships when all true
- Non-activating floating `NSPanel` shelf, right-edge, all-Spaces, never steals focus (both activation-hide observers removed).
- Drag-start global monitor auto-reveals the shelf (after T1 settles the permission path + preflight prompt).
- Global hotkey toggle (Control-Option-Space) + menu-bar toggle.
- Drag **in** files & folders (multi).
- Drag **out** to any app / Finder / upload field / terminal (path-paste), **copy-only** (original never moved); per-item Copy Path.
- Per-item remove, Clear All; **no auto-clear** on drag-out.
- Persistence across quit/reboot via the net-new `shelf.json` pipeline (plain bookmarks).
- **Greyed missing-file row** (no silent drop).
- Menu-bar app, no Dock icon, launch-at-login toggle.
- Dedup by resolved path only.
- Developer-signed, runs locally.

### P1 -- fast-follow
- "Send via LocalSend" hand-off action.
- Text / image / URL clips.
- Item stacking / grouping.
- Configurable hotkey & edge in a real Settings window.
- Interactive re-locate for missing files.
- Notarized Developer ID build.
- Optional sandboxed build (flip to security-scoped bookmarks).

---

## Implementation Plan

### File structure (~7-8 files -- no cloud/auth/keychain/API/Android)
```
Perch/
  PerchApp.swift          // @main App + @NSApplicationDelegateAdaptor; AppDelegate:
                          //   builds NSPanel, wires triggers, status item, persistence load/save
  ShelfPanel.swift        // NSPanel config + WindowVisibilityController (level, collectionBehavior,
                          //   edge position, alpha fade); re-apply on screen-param change
  DragStartObserver.swift // global .leftMouseDragged/.leftMouseUp + .drag pb sniff + TCC preflight
  Hotkey.swift            // Carbon RegisterEventHotKey (Ctrl-Opt-Space) toggle
  StatusItem.swift        // NSStatusItem menu (show/hide, clear, launch-at-login via SMAppService)
  Shelf.swift             // Shelf + Codable ShelfItem (plain bookmarks, resolve, begin/endDragAccess)
                          //   + NET-NEW shelf.json encode/decode/atomic-write/resolve-loop
  ShelfView.swift         // SwiftUI: empty state + rows (incl. greyed missing-file state);
                          //   DropContainer (drag-in); DraggableRow/NSDraggingSource (drag-out,
                          //   copy-only, static snapshot preview); Copy Path / Remove / Reveal
```
(Optionally split drag-in vs drag-out into `DragViews.swift` -> 8 files. No `AuthManager`, `DroppAPI`, `CloudLinkStore`, `KeychainStore`, or any networking.)

### Build & signing setup
- **Xcode project** (not Tuist for v1 -- simpler for an 8-file app). macOS app target, deployment target macOS 13+ (for `SMAppService`).
- SwiftUI + AppKit, no SPM dependencies.
- Info.plist: `LSUIElement = YES`; bundle id `com.dadequate.perch` (or chosen name).
- Signing: Apple Development / "Sign to Run Locally", Hardened Runtime ON, **App Sandbox OFF**. Notarization is P1.
- Repo: a standalone git repository.

---

## Tracer-Bullet Tickets (thin end-to-end slices)

**T1 -- SPIKE: global drag monitor + permission reality (do first).**
Throwaway menu-bar app that installs `addGlobalMonitorForEvents([.leftMouseDragged])`, sniffs `NSPasteboard(name: .drag)` for `.fileURL`/`.URL`, and logs "FILE DRAG STARTED". Also call the TCC **preflight** APIs (`IOHIDCheckAccess` for Input Monitoring, `AXIsProcessTrusted` for Accessibility) and log their results at startup.
*Accept:* On the test Mac, dragging a file in Finder logs the line. Document exactly which grant (none / Input Monitoring / Accessibility) was required, confirm the matching preflight API reports it correctly *before* a drag, and capture the System Settings deep-link prompt UX. Decision recorded in README.

**T2 -- Floating non-activating panel that never steals focus.**
Build the `NSPanel` (`.nonactivatingPanel`, `isFloatingPanel`, `level=.floating`, all-Spaces collectionBehavior, right-edge), shown at launch with a placeholder SwiftUI view containing a **button**. Remove both activation-hide observers.
*Accept:* Panel appears right-edge, stays on top, visible on every Space; clicking it (and clicking the inner button) does **not** deactivate the foreground app and does **not** make the panel hide/flicker.

**T3 -- Drag-in: stash files & folders.**
Wire `DropContainer` + `Shelf.add`. Rows show file icon + truncated name; dedup by resolved path; multi-drop; folders accepted.
*Accept:* Drag 3 files + 1 folder -> 4 rows; re-dropping a duplicate adds nothing; two different files with the same basename both appear (no filename collision).

**T4 -- Drag-out everywhere (copy-only) + Copy Path.**
`DraggableRow` as `NSDraggingSource` writing `fileURL as NSURL`, `sourceOperationMaskFor` returns `.copy` only, static-snapshot preview; per-row Copy Path.
*Accept:* Drag a stashed row into (a) a Finder folder -> file **copied** and the **original still exists at its source path**, (b) a browser upload field -> file attaches, (c) Terminal -> POSIX path appears as text. Copy Path puts the path on the clipboard.

**T5 -- Auto-reveal on drag-start (wire T1 into the real app).**
Connect `DragStartObserver` -> `WindowVisibilityController.setVisible(true)` with the `.drag` changeCount one-shot gate; hide ~300ms after mouse-up when the shelf is empty and un-hovered; never on drag-out. Show the preflight prompt if ungranted.
*Accept:* Starting a file drag anywhere fades the shelf in; releasing over empty space fades it out; releasing onto the shelf keeps it up with the new item; if the grant is missing, the Settings prompt appears instead of a silent no-op.

**T6 -- Persistence across quit/reboot (NET-NEW pipeline, plain bookmarks).**
Make `ShelfItem` Codable; atomic-write `[ShelfItem]` to `Application Support/Perch/shelf.json` on every mutation; launch-time decode + resolve loop with plain bookmarks; greyed row for nil-resolve.
*Accept:* Stash files, Quit, relaunch **and reboot** -> same rows return and still drag out correctly (verified with **plain** bookmarks, no security-scope). Move a stashed file's parent folder -> its row appears greyed, not gone.

**T7 -- Menu-bar shell: hotkey, status menu, launch-at-login, Clear All.**
`NSStatusItem` menu (Show/Hide, Clear Shelf, Launch at Login via `SMAppService`, Quit), Carbon hotkey (Ctrl-Opt-Space), `LSUIElement`.
*Accept:* No Dock icon; hotkey and menu both toggle the shelf; Ctrl-Opt-Space doesn't collide with Spotlight/Raycast; Launch-at-Login survives reboot (Perch auto-starts and restores the shelf); Clear Shelf empties it.

---

## API Feasibility Notes (verified against the Dropp reference)

Every core mechanic was checked file-by-file in the cloned source. Four are **sound as written**; three carry **deliberate divergences** that the reference proves are necessary.

**Sound, copy the pattern:**
- **Non-activating panel:** `NSPanel(styleMask:[.nonactivatingPanel,.borderless])` + `isFloatingPanel`/`becomesKeyOnlyIfNeeded`/`hidesOnDeactivate=false`/`level=.floating` -- `DroppApp.swift`. Receives drops without stealing focus.
- **Drag-out universality:** `NSDraggingItem(pasteboardWriter: fileURL as NSURL)` + `beginDraggingSession`; the `public.file-url` gives terminal path-paste for free -- `DraggableContainerView`, ContentView.swift.
- **Drag-in multi-URL:** `registerForDraggedTypes([.fileURL])` + `readObjects(forClasses:[NSURL.self], options:[.urlReadingFileURLsOnly:true])` -- `DropView.swift`.
- **Per-item bookmark API:** `url.bookmarkData` / `URL(resolvingBookmarkData:)` + `start/stopAccessingSecurityScopedResource()` -- `ShelfItem` in Shelf.swift.

**Deliberate divergences (reference is wrong for Perch -- confirmed in source):**
- **Persistence is NET-NEW.** Grep confirms Dropp has zero local item persistence -- the bookmark code persists individual bookmarks into cloud link mappings, not a local shelf store; cross-launch survival is `refreshCloudInventoryOnLaunch` only. The `shelf.json` encode/decode/atomic-write/resolve pipeline is original.
- **Drag-out mask:** Dropp returns `[.move, .copy]` for all contexts (ContentView.swift:966/968/970) and removes items via `onExternalMove` (line 981). Perch returns `.copy` only and implements no `onExternalMove`, per the locked never-move / no-auto-clear decisions.
- **Dedup:** Dropp dedups by `lastPathComponent` OR resolved path (Shelf.swift:32-33), silently swallowing distinct same-named files. Perch dedups by resolved path only.
- **Bookmark default:** Perch defaults to **plain** `bookmarkData(options: [])` (non-sandboxed v1); `.withSecurityScope` is a sandbox feature reserved for P1.
- **Activation observers:** Dropp installs both resign-active and become-active hide observers + `skipNextActivationUpdate` suppression; Perch removes all of it.
- **Drag preview:** use Dropp's `snapshotImage()` static `NSImage`, not a live hosting view, for `setDraggingFrame(contents:)`.

**The one genuine unknown is the TCC grant** the global mouse monitor needs on the test Mac -- Dropp ships the monitor but the repo doesn't prove the permission state. Hence **T1 is the first spike**, with an explicit preflight-API requirement since a silent monitor can't self-detect. Launch-at-login uses `SMAppService` (not in Dropp; standard macOS 13+). ~Half of Dropp (Firebase auth, cloud API client, keychain, Android) is irrelevant and dropped.
