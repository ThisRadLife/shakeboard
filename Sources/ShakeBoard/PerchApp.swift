//
//  PerchApp.swift
//  ShakeBoard -- the full-width bottom strip (shelf files + everything you copied, Strip.swift), shake/hotkey
//  summon, drag-in/out, auto-hide, PERSISTENCE (survives quit/reboot), recordable shake gesture +
//  sensitivity, launch-at-login, clear-all / remove-individual.
//
//  Shake rules: summon on shake WHILE dragging something, OR (when not dragging) if the shelf
//  already has items -- never on an idle shake over an empty shelf.
//

import SwiftUI
import AppKit
import Carbon            // HIToolbox (hotkey) + AE (shakeboard:// URL handling)
import ServiceManagement
import Combine
import ApplicationServices   // AXIsProcessTrusted -- accessibility gate for the global mouse monitor
import ImageIO               // HEIC decode + JPEG re-encode for Claude-friendly drag-out
import UniformTypeIdentifiers
import QuickLookThumbnailing   // real chip previews (images/PDFs) instead of generic file-type icons

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

// MARK: - Named constants (P3-2/P3-3: no bare magic numbers, one home for the fork-sensitive identifiers)

// Identity strings that a fork MUST keep in sync across BOTH targets. This enum is the app-side source
// of truth; ShakeBoardShare (a separate module -- a unit-test bundle can't depend on an app extension, so the
// two can't share a symbol without a third file we deliberately don't add) mirrors `scheme` locally and
// its Info.plist mirrors `shareBundleID`. FORK INVARIANT: rename here -> also rename ShakeBoardShare's local
// `shakeboardScheme`, both bundleIds in Project.swift, and CFBundleURLSchemes. (P3-3)
enum PerchID {
    static let scheme = "shakeboard"                        // shakeboard://add?dir=<handoff>
    static let appBundleID = "com.thisradlife.shakeboard"
    static let shareBundleID = "com.thisradlife.shakeboard.share"
}

// On-disk roots. SHAKEBOARD_DATA_DIR (preferred) or PERCH_DATA_DIR (compatibility) relocates EVERYTHING
// ShakeBoard writes -- shelf.json, Shelf/, Clips/ --
// so a dev/branch build can be run without touching (or schema-migrating) the real store. Also moves the
// preferences into a separate defaults suite so dev runs can't clobber the real app's settings.
enum PerchPaths {
    static let overrideDir: URL? = {
        let env = ProcessInfo.processInfo.environment
        guard let raw = [env["SHAKEBOARD_DATA_DIR"], env["PERCH_DATA_DIR"]]
            .compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }()
    private static var resolvedBase: URL?
    static var applicationSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
    static func resolveBase(_ url: URL?) { resolvedBase = url }
    static var base: URL {
        if let overrideDir { return overrideDir }
        if let resolvedBase { return resolvedBase }
        return applicationSupportRoot.appendingPathComponent("ShakeBoard", isDirectory: true)
    }
    static let defaults: UserDefaults = {
        if overrideDir != nil, let d = UserDefaults(suiteName: "com.thisradlife.shakeboard.devdata") { return d }
        return .standard
    }()
}

// Panel geometry. The strip spans the screen's visibleFrame (above the Dock), less a small inset.
enum Layout {
    static let stripHeight: CGFloat = 174
    static let stripSideInset: CGFloat = 8              // gap to the screen's left/right edges
    static let panelBottomInset: CGFloat = 8           // gap above the Dock / screen bottom
    static let dropDownTopInset: CGFloat = 8           // gap below the menu bar for the stack bar

    // Full width of the visible frame, bottom-anchored.
    static func stripFrame(in vf: NSRect) -> NSRect {
        NSRect(x: (vf.minX + stripSideInset).rounded(), y: (vf.minY + panelBottomInset).rounded(),
               width: max(vf.width - 2 * stripSideInset, 200).rounded(), height: min(stripHeight, vf.height))
    }
}

// Reveal/hide timing (seconds).
enum Timing {
    static let fade = 0.18                             // reveal/hide alpha fade (P2-2)
    static let autoHideAfterReveal = 3.0              // shelf summoned but untouched
    static let autoHideAfterExit = 1.1               // cursor left the panel
    static let autoHideAfterDrop = 1.4               // a drop just landed
    static let staleHandoffAge: TimeInterval = 24 * 3600   // sweep handoff/promise dirs older than this
}

// Size / count caps.
enum Limits {
    static let maxHandoffFiles = 100                  // bounded ingest enumeration
    static let maxIngestFileBytes = 4 * 1024 * 1024 * 1024   // 4 GiB -- skip a single absurd handoff file (P1-11)
    static let optimizerCacheEntries = 64             // bound the drag-out temp-JPEG cache (P3-4)
    static let thumbnailCacheEntries = 128            // bound the chip preview cache; chips are small
}

// MARK: - Model + persistence (security bookmarks -> shelf.json)

struct ShelfItem: Identifiable {
    let id: UUID
    let url: URL
    let bookmark: Data
    var missing: Bool = false
    // True ONLY when ShakeBoard made the copy that backs this item (shared-content ingest + promise copies);
    // false for Finder-bookmarked originals. Gates deleteOwnedCopy so a user's original is never removed. (P1-8)
    var ownedCopy: Bool = false
}

@MainActor
final class ShelfModel: ObservableObject {
    @Published var items: [ShelfItem] = []
    @Published var hovering = false
    @Published var selected: Set<UUID> = []
    // Chip under the pointer -- Space previews it (QuickLook.swift). Not persisted.
    @Published var hoveredID: UUID? = nil
    private var selectionAnchor: UUID?
    @Published var reduceOnDrag: Bool {
        didSet { defaults.set(reduceOnDrag, forKey: "reduceOnDrag") }
    }

    // Set (in memory only) when the last save() failed even after one retry -- surfaced as a single
    // status-menu line so a silent write failure (disk full, permissions) can't lose the shelf unseen.
    // NOT a badge/notification subsystem. Cleared on the next successful save(). (P1-6)
    @Published private(set) var lastSaveFailed = false

    // Base directory for shelf.json + the owned-copy Shelf/ folder. Defaults to Application Support/ShakeBoard;
    // tests inject a temp dir so the on-disk store is fully isolated. (P1-2)
    private let baseDir: URL
    private let defaults: UserDefaults
    init(baseDir: URL? = nil, defaults: UserDefaults = PerchPaths.defaults) {
        self.baseDir = baseDir ?? PerchPaths.base
        self.defaults = defaults
        reduceOnDrag = defaults.bool(forKey: "reduceOnDrag")
    }

    // The on-disk format is a public contract, so it carries a `version`. Old (pre-versioned) files were a
    // bare `[Stored]` array; load() migrates them forward. `name`/`ownedCopy` are optional so those old
    // files still decode -- a missing ownedCopy means "not ShakeBoard's copy" (never auto-deletable). (P1-9)
    private struct Stored: Codable { let id: UUID; let bookmark: Data; var name: String?; var ownedCopy: Bool? }
    private struct ShelfFile: Codable { var version: Int; var items: [Stored] }
    private static let currentVersion = 1

    private var storeURL: URL {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        return baseDir.appendingPathComponent("shelf.json")
    }

    // Add URLs to the shelf. `owned` is true when ShakeBoard made the copy (shared/promise ingest). Dedup by
    // resolved path: a duplicate add moves the existing chip to the front (visible feedback) instead of
    // silently no-op'ing or double-shelving; new items append. (P1-3)
    // Returns how many of `urls` are on the shelf afterwards (new or already present) -- callers that made
    // a file for the shelf use it to roll that file back when the add didn't land (bookmark failure).
    //
    // `transactional`: all-or-nothing on disk. If shelf.json can't be saved, the NEW items are taken back
    // out of memory and 0 is returned so the caller can delete the file it made (copied-image ingest).
    // Off by default: drop/handoff ingest has already consumed its source, so it keeps the in-memory item
    // and the lastSaveFailed menu line rather than losing the user's only copy.
    @discardableResult
    func add(_ urls: [URL], owned: Bool = false, transactional: Bool = false) -> Int {
        let before = items
        var changed = false
        var landed = 0
        for url in urls {
            let key = Self.pathKey(url)
            if let idx = items.firstIndex(where: { Self.pathKey($0.url) == key }) {
                if idx != 0 { let existing = items.remove(at: idx); items.insert(existing, at: 0) }
                changed = true; landed += 1
                continue
            }
            guard let bm = try? url.bookmarkData() else { continue }
            items.append(ShelfItem(id: UUID(), url: url, bookmark: bm, ownedCopy: owned))
            changed = true; landed += 1
        }
        if changed {
            let ok = save()
            if !ok && transactional { items = before; return 0 }
        }
        return landed
    }
    var ownedCount: Int { items.filter(\.ownedCopy).count }
    private static func pathKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
    func remove(_ item: ShelfItem) {
        deleteOwnedCopy(item)
        ShelfThumbnails.invalidate(item.url)   // don't let a later file at this path show a stale preview
        items.removeAll { $0.id == item.id }; selected.remove(item.id); save()
    }
    func clear() {
        for item in items { deleteOwnedCopy(item); ShelfThumbnails.invalidate(item.url) }
        items.removeAll(); selected.removeAll(); save()
    }

    private var shelfCopyDir: URL {
        baseDir.appendingPathComponent("Shelf", isDirectory: true)
    }
    // Delete the file backing an item ONLY when ShakeBoard owns the copy (the persisted ownedCopy bit) AND it
    // lives inside ShakeBoard/Shelf. Both gates must hold -- the bit stops us deleting a Finder-bookmarked
    // original even if a bookmark happened to resolve inside Shelf, and the path check stops us following
    // a mislabeled item out of the store. Stops removed/cleared shared content from lingering. (C7/P1-8)
    private func deleteOwnedCopy(_ item: ShelfItem) {
        guard item.ownedCopy else { return }
        let base = shelfCopyDir.resolvingSymlinksInPath().path
        let path = item.url.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return }
        try? FileManager.default.removeItem(at: item.url)
    }

    func toggleSelect(_ item: ShelfItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
        selectionAnchor = item.id
    }
    // Finder-style click: a plain click ALWAYS selects exactly this chip (it never deselects -- that would
    // silently turn the next drag into "drag everything"); Command-click is the only toggle; Shift-click
    // selects the range from the last clicked chip; a click on empty shelf space clears (selectOnly(nil)).
    // Missing chips are never selected.
    func click(_ item: ShelfItem, command: Bool, shift: Bool) {
        guard !item.missing else { return }
        if command { toggleSelect(item); return }
        if shift, let anchor = selectionAnchor,
           let a = items.firstIndex(where: { $0.id == anchor }), let b = items.firstIndex(where: { $0.id == item.id }) {
            selected = Set(items[min(a, b)...max(a, b)].filter { !$0.missing }.map(\.id))
            return
        }
        selected = [item.id]
        selectionAnchor = item.id
    }
    func selectOnly(_ id: UUID?) {
        selected = id.map { [$0] } ?? []
        selectionAnchor = id
    }
    // Drag payload: the selected items, or ALL items when nothing is selected -- each resolved to a
    // real, Claude-friendly file URL (HEIC->JPEG, optional downscale). Computed at drag start.
    func dragURLs() -> [URL] {
        let chosen = selected.isEmpty ? items : items.filter { selected.contains($0.id) }
        return chosen.compactMap { dragURL(for: $0) }
    }
    func dragURL(for item: ShelfItem) -> URL? {
        guard !item.missing else { return nil }
        var stale = false
        // `missing` is only computed at load(); a file deleted/moved mid-session still looks live.
        // If the bookmark can't resolve or the file is gone NOW, skip it -- never hand out a dead URL.
        guard let original = try? URL(resolvingBookmarkData: item.bookmark, options: [],
                                      relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        // Security-scoped bookmark model (P1-10, DECISION: keep the calls).
        // ShakeBoard is NON-sandboxed and creates PLAIN bookmarks (`url.bookmarkData()`, no `.withSecurityScope`),
        // so start/stopAccessingSecurityScopedResource is a harmless no-op today -- `didAccess` comes back
        // false and the `defer` does nothing. We deliberately KEEP the correctly-paired calls rather than
        // strip "dead" ceremony: the moment ShakeBoard ships a sandboxed / App-Group build (the deferred signing
        // milestone) it will resolve `.withSecurityScope` bookmarks, at which point these calls become
        // load-bearing and their absence would be a latent file-access bug. Keeping them now costs nothing
        // and avoids that churn. This is the ONE security-scoped seam in the app.
        let didAccess = original.startAccessingSecurityScopedResource()
        defer { if didAccess { original.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: original.path) else { return nil }
        return DragImageOptimizer.optimized(original, reduce: reduceOnDrag) ?? original
    }

    @discardableResult
    private func save() -> Bool {
        let dtos = items.map { Stored(id: $0.id, bookmark: $0.bookmark, name: $0.url.lastPathComponent,
                                      ownedCopy: $0.ownedCopy) }
        let file = ShelfFile(version: Self.currentVersion, items: dtos)
        guard let data = try? JSONEncoder().encode(file) else { lastSaveFailed = true; return false }
        // Retry once -- a transient write failure (a momentary lock, the dir briefly gone) usually clears
        // immediately. If it still fails, record ONE in-memory flag rather than dying silently. (P1-6)
        let url = storeURL
        do {
            try data.write(to: url, options: .atomic)
            lastSaveFailed = false
            return true
        } catch {
            do {
                try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                lastSaveFailed = false
                return true
            } catch {
                NSLog("ShakeBoard: shelf save failed twice: \(error)")
                lastSaveFailed = true
                return false
            }
        }
    }
    func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }   // no file yet == first run
        let dtos: [Stored]
        var migrated = false
        if let file = try? JSONDecoder().decode(ShelfFile.self, from: data) {
            guard file.version <= Self.currentVersion else {
                // Written by a NEWER ShakeBoard -- the format may carry fields we'd silently drop on the next
                // save(). Quarantine and start empty rather than crash or corrupt a future file. (P1-9)
                quarantine(reason: "unknown future schema version \(file.version)")
                return
            }
            dtos = file.items
        } else if let legacy = try? JSONDecoder().decode([Stored].self, from: data) {
            dtos = legacy; migrated = true   // pre-versioned (v0) file -- rewrite in the new envelope below
        } else {
            // Corrupt/truncated shelf.json: back it up rather than starting empty -- the next save()
            // would otherwise overwrite the (possibly recoverable) file and make the loss permanent. (F8)
            quarantine(reason: "failed to decode")
            return
        }
        var needsSave = migrated
        items = dtos.map { dto in
            var stale = false
            if let url = try? URL(resolvingBookmarkData: dto.bookmark, options: [],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let missing = !FileManager.default.fileExists(atPath: url.path)
                var bookmark = dto.bookmark
                if stale, !missing, let fresh = try? url.bookmarkData() {   // refresh a stale bookmark (F9)
                    bookmark = fresh; needsSave = true
                }
                return ShelfItem(id: dto.id, url: url, bookmark: bookmark, missing: missing,
                                 ownedCopy: dto.ownedCopy ?? false)
            }
            // Bookmark won't resolve (e.g. an unmounted volume). KEEP the item, greyed out -- never drop
            // it, or the next save() erases it permanently. Retain the bookmark so it returns on remount;
            // show its last-known name. (F2)
            let name = dto.name ?? "(unavailable)"
            return ShelfItem(id: dto.id, url: URL(fileURLWithPath: name), bookmark: dto.bookmark,
                             missing: true, ownedCopy: dto.ownedCopy ?? false)
        }
        if needsSave { save() }
    }
    // Move a shelf.json we won't/can't read to shelf.json.corrupt so a later save() can't overwrite the
    // (possibly recoverable) file. Used for both corrupt JSON and unknown-future schema versions. (F8/P1-9)
    private func quarantine(reason: String) {
        let backup = storeURL.deletingLastPathComponent().appendingPathComponent("shelf.json.corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: storeURL, to: backup)
        NSLog("ShakeBoard: shelf.json quarantined (\(reason)); backed up to shelf.json.corrupt")
    }
}

// MARK: - Chip thumbnails (real previews instead of generic file-type icons)

// QuickLook renders an actual preview for images/PDFs/video and falls back to the file's icon for
// types it can't draw, so this covers every shelf item without type-sniffing. Generation is async, so
// a chip paints the Workspace icon immediately and swaps in the preview when it arrives -- the shelf
// must never block on disk I/O while you're mid-drag. Cache is bounded FIFO, same shape as the
// drag-out encode cache (P3-4), and keyed by path+size so the larger previews you get after resizing
// the panel don't collide with the small ones.
@MainActor
enum ShelfThumbnails {
    private static var cache: [String: NSImage] = [:]
    private static var order: [String] = []
    private static var inFlight: Set<String> = []

    // The panel resizes continuously, but QuickLook must NOT be asked for a new render on every pixel --
    // that regenerates the whole row mid-drag and makes the chips shimmer. Requests snap to a few size
    // classes and the resulting image is scaled to the in-between sizes, so a full resize costs at most
    // a handful of renders.
    private static let renderSteps: [CGFloat] = [48, 72, 112, 160, 224]
    static func renderEdge(for edge: CGFloat) -> CGFloat {
        renderSteps.first { $0 >= edge * (NSScreen.main?.backingScaleFactor ?? 2) / 2 } ?? 224
    }

    private static func key(_ url: URL, _ edge: CGFloat) -> String { "\(Int(edge)):\(url.path)" }

    static func cached(_ url: URL, edge: CGFloat) -> NSImage? { cache[key(url, edge)] }

    /// Kick off generation if we don't already have (or aren't already fetching) this preview.
    ///
    /// Three tiers, best content first. QuickLook alone is not enough: asking it for `.thumbnail`
    /// fails outright on files it will only represent as an icon, and asking for `.all` succeeds but
    /// hands back a generic document badge. Neither shows you the picture. So when QuickLook declines
    /// to render a real preview we decode the file ourselves before settling for an icon -- a `.webp`
    /// on this machine is actually JPEG bytes, which ImageIO reads happily even though QuickLook
    /// returns QLThumbnailErrorDomain 0 for it.
    static func load(_ url: URL, edge: CGFloat, scale: CGFloat, then: @escaping (NSImage) -> Void) {
        let k = key(url, edge)
        if let hit = cache[k] { then(hit); return }
        guard !inFlight.contains(k) else { return }   // coalesce: chips re-render often
        inFlight.insert(k)

        func finish(_ image: NSImage?) {
            inFlight.remove(k)
            guard let image else { return }           // nothing worked -- chip keeps the Workspace icon
            store(k, image)
            then(image)
        }

        // 1) QuickLook's real preview: right answer for PDFs, video, documents and most images.
        quickLook(url, edge: edge, scale: scale, types: .thumbnail) { rendered in
            if let rendered { finish(rendered); return }
            // 2) Decode it ourselves -- covers every format the system has an image decoder for.
            DispatchQueue.global(qos: .userInitiated).async {
                let decoded = decodeThumbnail(url, edge: edge, scale: scale)
                Task { @MainActor in
                    if let decoded { finish(decoded); return }
                    // 3) Whatever QuickLook does have, usually the document icon. Genuinely not an
                    //    image (archive, binary), so a badge is the honest thing to show.
                    quickLook(url, edge: edge, scale: scale, types: .all) { finish($0) }
                }
            }
        }
    }

    private static func quickLook(_ url: URL, edge: CGFloat, scale: CGFloat,
                                  types: QLThumbnailGenerator.Request.RepresentationTypes,
                                  then: @escaping (NSImage?) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: edge, height: edge),
                                                   scale: max(1, scale),
                                                   representationTypes: types)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            Task { @MainActor in then(rep?.nsImage) }
        }
    }

    /// ImageIO thumbnail. `nonisolated` and pure so it can run off the main thread -- decoding a large
    /// photo is real work and must not block the shelf mid-drag.
    nonisolated private static func decodeThumbnail(_ url: URL, edge: CGFloat, scale: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let pixels = max(1, Int(edge * max(1, scale)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // bake in EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Size in POINTS, so a 2x render doesn't draw double-size in the chip.
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / max(1, scale),
                                                 height: CGFloat(cg.height) / max(1, scale)))
    }

    private static func store(_ k: String, _ image: NSImage) {
        order.removeAll { $0 == k }
        cache[k] = image
        order.append(k)
        while order.count > Limits.thumbnailCacheEntries, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// Drop every cached size for a path -- used when an item leaves the shelf.
    static func invalidate(_ url: URL) {
        let suffix = ":\(url.path)"
        for k in order where k.hasSuffix(suffix) { cache.removeValue(forKey: k) }
        order.removeAll { $0.hasSuffix(suffix) }
    }
}

// A chip's image well: Workspace icon first, real preview swapped in once QuickLook returns.
struct ChipThumbnail: View {
    let url: URL
    let edge: CGFloat
    let missing: Bool
    @State private var preview: NSImage?

    var body: some View {
        Image(nsImage: preview ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: preview == nil ? .fit : .fill)
            .frame(width: edge, height: edge)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(missing ? 0.4 : 1)
            // Keyed on the SNAPPED size, not the live one, so a drag re-runs this only when it crosses a
            // size class -- the displayed frame still tracks the panel smoothly in between.
            .task(id: "\(url.path):\(Int(ShelfThumbnails.renderEdge(for: edge)))") {
                guard !missing else { return }          // don't spin up QuickLook for a dead path
                let render = ShelfThumbnails.renderEdge(for: edge)
                if let hit = ShelfThumbnails.cached(url, edge: render) { preview = hit; return }
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                ShelfThumbnails.load(url, edge: render, scale: scale) { preview = $0 }
            }
    }
}

// MARK: - Drag-out image optimizer (Claude-friendly: HEIC->JPEG, optional downscale)

enum DragImageOptimizer {
    static let claudeMaxEdge = 1568          // Claude's recommended long edge; downscale target when "reduce" is on
    static let fullResCap = 8192             // long-edge cap when NOT reducing (covers 48MP photos; bounds worst case)
    static let maxSourcePixels = 200_000_000 // reject decompression bombs before decode (200MP; allows even 200MP phone modes, rejects gigapixel bombs)
    static let syncMaxPixels = 24_000_000    // ~24MP: optimize inline only up to here; drag start runs on the
                                             // main thread, so a bigger decode+re-encode would visibly stall it (P1-5)

    // Is an image of this declared size small enough to decode + re-encode INLINE on the drag thread?
    // Above the cap we hand back the original untouched so beginning a drag never blocks. This REPLACES
    // background pre-warming (a pre-warm races cold-launch clearTemp()). Pure + injected-size, so testable. (P1-5)
    static func canOptimizeSynchronously(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let (product, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && product <= syncMaxPixels
    }

    // (source path | mtime | reduce) -> already-encoded temp URL. Drags run on the main thread only, so
    // the cache is @MainActor-isolated (no lock needed). Lets repeat drags reuse one encode instead of
    // re-decoding + duplicating. (F3/F10/P2-3)
    @MainActor private static var cache: [String: URL] = [:]
    // Insertion order for the cache, so it can be bounded FIFO instead of growing all session. (P3-4)
    @MainActor private static var cacheOrder: [String] = []

    static var tempDir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardDrag", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    @MainActor static func clearTemp() { cache.removeAll(); cacheOrder.removeAll(); try? FileManager.default.removeItem(at: tempDir) }

    // Record an encode in the cache and evict the oldest entry (deleting its temp file) once the cache
    // exceeds its cap -- otherwise a long session accumulates temp JPEGs until the next launch-clear. (P3-4)
    @MainActor private static func cache(_ key: String, _ url: URL) {
        cacheOrder.removeAll { $0 == key }
        cache[key] = url
        cacheOrder.append(key)
        while cacheOrder.count > Limits.optimizerCacheEntries {
            let old = cacheOrder.removeFirst()
            if let stale = cache.removeValue(forKey: old) { try? FileManager.default.removeItem(at: stale) }
        }
    }

    // A Claude-ready temp URL for an image, or nil to drag the original untouched (non-images, or
    // already-friendly formats when not reducing). HEIC is ALWAYS re-encoded -- Claude can't read it.
    @MainActor static func optimized(_ src: URL, reduce: Bool) -> URL? {
        guard let type = try? src.resourceValues(forKeys: [.contentTypeKey]).contentType,
              type.conforms(to: .image) else { return nil }
        let friendly = [UTType.jpeg, .png, .gif, .webP].contains { type.conforms(to: $0) }
        if friendly && !reduce { return nil }                    // JPEG/PNG/... at full size: nothing to do
        // Reuse a prior encode of the same source+mtime+reduce -- avoids re-decoding on repeat drags and
        // stops duplicate temp JPEGs from accumulating within a session. (F3/F10)
        let mtime = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let cacheKey = "\(src.path)|\(mtime)|\(reduce)"
        if let cached = cache[cacheKey], FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard let source = CGImageSourceCreateWithURL(src as CFURL, nil) else { return nil }
        // Decompression-bomb guard: check the DECLARED dimensions before decoding and bail on absurd
        // images -- decode cost tracks SOURCE pixels, so a gigapixel image would hang/OOM this
        // non-sandboxed process. Bailing drags the original untouched.
        // If the declared dimensions can't be read, BAIL (drag the original untouched) rather than
        // decoding blind -- a header that omits dimensions must not slip past the bomb guard. (F11)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let (product, overflow) = w.multipliedReportingOverflow(by: h)
        if w <= 0 || h <= 0 || overflow || product > maxSourcePixels { return nil }
        // Bounded-synchronous cap: past ~24MP the inline decode+re-encode would stall drag start, so drag
        // the ORIGINAL untouched instead of blocking. (HEIC over the cap therefore drags as HEIC -- an
        // accepted trade: a responsive drag beats a converted-but-janky one. Small HEIC still converts.) (P1-5)
        if !canOptimizeSynchronously(width: w, height: h) { return nil }
        // Thumbnail API bakes in EXIF orientation and downscales in one pass.
        let maxPixel = reduce ? claudeMaxEdge : fullResCap
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        let dest = uniqueURL(base: src.deletingPathExtension().lastPathComponent, ext: "jpg")
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(out, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(out) else {
            try? FileManager.default.removeItem(at: dest)   // don't leave a half-written file squatting the name
            return nil
        }
        cache(cacheKey, dest)
        return dest
    }
    private static func uniqueURL(base: String, ext: String) -> URL {
        let fm = FileManager.default
        var url = tempDir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fm.fileExists(atPath: url.path) { url = tempDir.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 }
        return url
    }
}

// MARK: - Shake detector (back-and-forth scrub); thresholds are calibratable

final class ShakeDetector {
    var onShake: (() -> Void)?
    var minTravel: CGFloat = 60
    var neededReversals = 3
    var windowSec: TimeInterval = 0.6

    private var accum: CGFloat = 0
    private var committedDir = 0
    private var reversalTimes: [TimeInterval] = []
    private var lastTime: TimeInterval = 0
    var currentReversalCount: Int { reversalTimes.count }

    func feed(deltaX: CGFloat, time: TimeInterval) {
        if time - lastTime > 0.35 { reset() }
        lastTime = time
        accum += deltaX
        guard abs(accum) >= minTravel else { return }
        let dir = accum > 0 ? 1 : -1
        if committedDir != 0 && dir != committedDir {
            reversalTimes.append(time)
            reversalTimes = reversalTimes.filter { time - $0 <= windowSec }
            if reversalTimes.count >= neededReversals { reset(); onShake?(); return }
        }
        committedDir = dir
        accum = 0
    }
    func reset() { accum = 0; committedDir = 0; reversalTimes.removeAll() }
}

// MARK: - Global hotkey (Carbon)

@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let myID: UInt32
    // 'PRCH' as an OSType -- the four-char signature that tags THIS app's hotkey registration so the
    // Carbon event carries an id we own. (P3-1)
    private static let signature = OSType(0x50524348)
    // Keyed by hotkey id because the C event callback can't capture Swift context. Touched only on the
    // main thread (Carbon fires on the main run loop), so it's @MainActor-isolated. (P2-3)
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var counter: UInt32 = 0
    // Carbon event handlers currently installed by GlobalHotKey (tests assert a failed registration leaks none).
    private(set) static var installedHandlerCount = 0

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        GlobalHotKey.counter += 1
        myID = GlobalHotKey.counter
        GlobalHotKey.handlers[myID] = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                if let eventRef {
                    var hkID = EventHotKeyID()
                    GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID), nil,
                                      MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                    // Carbon delivers on the main run loop, so touching the main-actor registry here is safe.
                    MainActor.assumeIsolated { GlobalHotKey.handlers[hkID.id]?() }
                }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        guard installStatus == noErr else { GlobalHotKey.handlers[myID] = nil; return nil }
        GlobalHotKey.installedHandlerCount += 1
        let hkID = EventHotKeyID(signature: GlobalHotKey.signature, id: myID)
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hkID,
                                            GetApplicationEventTarget(), 0, &hotKeyRef)
        guard regStatus == noErr else {
            // The combo is taken. Remove the handler we just installed -- otherwise every failed attempt
            // (e.g. each Cmd-Space while another app owns Cmd-C) leaks one more app-level Carbon handler.
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            GlobalHotKey.installedHandlerCount -= 1
            GlobalHotKey.handlers[myID] = nil
            return nil
        }
    }
    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        let removed = handlerRef != nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        if removed { Task { @MainActor in GlobalHotKey.installedHandlerCount -= 1 } }
        // The registry is @MainActor-isolated; deinit is nonisolated, so hop to the main actor to drop
        // our entry. (In practice the sole GlobalHotKey lives for the whole app, so this rarely runs.)
        let id = myID
        Task { @MainActor in GlobalHotKey.handlers[id] = nil }
    }
}

// MARK: - Drag destination

final class DropView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    // Ephemeral files (materialized file promises): the caller must COPY these into the durable store
    // and shelve the copy -- bookmarking the temp URL loses them on the next tmp purge/reboot. (F1)
    var onDropCopying: (([URL]) -> Void)?
    // Text / web links (no files): the pasteboard items, allow-listed text types only.
    var onDropText: (([[RawRep]]) -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }   // chips must drag files, not the window
    private let promiseQueue = OperationQueue()
    // Plain pointer exit (not a drag): the shelf hands the keyboard back (QuickLook focus rule).
    var onPointerExit: (() -> Void)?
    private var pointerArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a); pointerArea = a
    }
    override func mouseExited(with event: NSEvent) { onPointerExit?() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { unregisterDraggedTypes(); return }
        // Accept BOTH direct file URLs and file PROMISES (sandboxed apps / editors like
        // Codex/VS Code/Mail hand files over as promises, not direct paths).
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        // ...and text: a dragged selection or web link becomes a pinned clip on the strip.
        types += [.string, .rtf, .html, .URL]
        registerForDraggedTypes(types)
    }
    // A drag that started in ShakeBoard itself (a card or file pulled off the strip and let go over it) is not a
    // drop: it would shelve a temporary export or re-add what's already there.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource == nil else { return [] }
        onEnter?(); return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource == nil ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { onExit?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { sender.draggingSource == nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onExit?()
        let pb = sender.draggingPasteboard
        // 1) Direct file URLs (Finder + most apps).
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDrop?(urls)
            return true
        }
        // 2) File promises -- materialize them into a temp dir, then shelve the real files.
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self],
                                          options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty {
            // Fresh per-batch dir so concurrent/repeat drops can't collide on a filename (F12).
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShakeBoardPromise-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: dest, options: [:],
                                              operationQueue: promiseQueue) { [weak self] url, error in
                    if let error { NSLog("ShakeBoard: promise receive failed: \(error)"); return }   // (F12)
                    // Copy into the durable store -- never bookmark this temp URL (F1).
                    DispatchQueue.main.async { self?.onDropCopying?([url]) }
                }
            }
            return true
        }
        // 3) Text / web links.
        if let items = Self.textItems(pb), !items.isEmpty {
            onDropText?(items)
            return true
        }
        NSLog("ShakeBoard: unhandled drag types: \(pb.types ?? [])")
        return false
    }
}

extension DropView {
    // The dragged text in the clipboard store's shape: per item, the allow-listed text reps (richest
    // first, like ClipTypes.allowed), size-capped like a copy.
    static func textItems(_ pb: NSPasteboard) -> [[RawRep]]? {
        let types = [ClipTypes.url, ClipTypes.rtf, ClipTypes.html, ClipTypes.plainText]
        let items: [[RawRep]] = (pb.pasteboardItems ?? []).prefix(ClipLimits.maxItemsPerClip).map { item in
            types.compactMap { t in
                guard let d = item.data(forType: NSPasteboard.PasteboardType(t)), !d.isEmpty,
                      d.count <= (t == ClipTypes.rtf || t == ClipTypes.html ? ClipLimits.maxRichTextBytes : ClipLimits.maxTextBytes)
                else { return nil }
                return RawRep(type: t, data: d)
            }
        }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }
}

// The shelf panel can become KEY (never main, never activating) so Space / arrows / Esc can reach it for
// Quick Look. It only becomes key when clicked (explicit intent) and hands the keyboard back when the
// pointer leaves it -- hovering alone never takes typing away from the app you're in.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func retentionReleaseHandler(isDegraded: @escaping () -> Bool,
                                        prune: @escaping () -> Void) -> () -> Void {
        { if !isDegraded() { prune() } }
    }

    private let injectedDefaults: UserDefaults?
    private var defaults: UserDefaults { injectedDefaults ?? PerchPaths.defaults }
    private var panel: NSPanel?
    private var motionMonitor: Any?
    private var globalMotionEvents = 0
    private var localCalibrationEvents = 0
    private var shakeLogTimer: Timer?
    private var hideWork: DispatchWorkItem?
    private var pendingReveal = false   // set if a share arrives before the panel is built
    private let shake = ShakeDetector()
    private lazy var model = ShelfModel(defaults: defaults)
    lazy var themeStore = ThemeStore(prefs: PerchPrefs(defaults: defaults))
    private var themeBag: AnyCancellable?

    // Clipboard history (ClipboardMonitor/ClipStore). Capture starts only after model.load().
    lazy var clipStore = ClipStore()
    private(set) lazy var ocrService = OCRService(store: clipStore, shelf: model)
    private var clipMonitor: ClipboardMonitor?
    // Pinboards are the source of truth. ClipPins is the compatibility view of the stable default board.
    lazy var pinboards = PinboardStore()
    private(set) lazy var clipPins = ClipPins(store: pinboards)
    private(set) lazy var stripState: StripState = {
        let st = StripState(shelf: model, store: clipStore, pins: clipPins, ocr: ocrService)
        // Copied images already land on the shelf as files -- don't show them twice.
        st.hideImageClips = { [weak self] in self?.addImagesToShelf ?? false }
        return st
    }()
    private(set) lazy var strip: StripController = StripController(state: stripState)
    private var resignObserver: Any?
    private var becameKeyObserver: Any?
    private(set) lazy var pasteStack = PasteStack(store: clipStore, baseDir: PerchPaths.base)
    private var stackBar: StackBarController?
    private let stackKeys = StackKeyWatcher()
    private var lastImageReveal = Date.distantPast
    private var hotKeys: PerchHotKeys?
    private var shelfKeyMonitor: Any?
    private var shelfKeyLease: KeyLease?
    // One Quick Look preview for the whole app (QuickLook.swift); `owner` says which panel drives it.
    lazy var quickLook: QuickLookController = {
        let presenter = QuickLookPanelPresenter()
        let c = QuickLookController(presenter: presenter)
        presenter.onCloseClicked = { [weak c] in c?.close() }
        c.onOwnerClosed = { [weak self] owner in self?.previewClosed(owner) }
        return c
    }()
    var addImagesToShelf: Bool {
        get { defaults.object(forKey: "addImagesToShelf") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "addImagesToShelf") }
    }

    // Count of items the most-recent add couldn't fully land (copy/disk-full failures + oversized skips).
    // Surfaced as ONE disabled menu line, reset when the next add is attempted. No alert/badge/focus theft. (P1-6)
    private var lastAddFailureCount = 0
    private func noteAddFailures(_ n: Int) {
        lastAddFailureCount = n
        refreshSettings(full: false)
    }

    // shake calibration
    private var calibReversals = 0
    private var calibSwing: CGFloat = 0
    private var variance: Double { PerchPrefs(defaults: defaults).shakeVariance }
    private lazy var calibrationSession = CalibrationSession(
        addLocalMonitor: { [weak self] handler in
            NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
                self?.localCalibrationEvents += 1
                return handler(event)
            }
        },
        removeMonitor: { NSEvent.removeMonitor($0) },
        schedule: { delay, callback in
            let work = DispatchWorkItem(block: callback)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        },
        beginTracking: { [weak self] in self?.settingsWindow.beginCalibrationMouseTracking() },
        endTracking: { [weak self] in self?.settingsWindow.endCalibrationMouseTracking() },
        onProgress: { [weak self] swings in self?.settings.calibration = .recording(swings: swings) },
        onFinish: { [weak self] reversals, swing in self?.completeCalibration(reversals: reversals, swing: swing) }
    )

    // MCP bridge (AIBridge.swift / AIAccess.swift): off until the user turns it on in Settings > Privacy & AI.
    private(set) lazy var aiBridge = AIBridgeService()
    let aiConsent = AIConsentPanel()

    // Settings window (Settings.swift): opened from the strip's gear, Command-comma in the strip, and by
    // relaunching ShakeBoard (Spotlight / Finder / Dock) -- there is no menu-bar icon.
    private(set) lazy var settings = SettingsModel(defaults: defaults)
    private(set) lazy var settingsWindow: SettingsWindowController = {
        let c = SettingsWindowController(model: settings, themes: themeStore)
        c.willShow = { [weak self] in
            guard let self else { return }
            if self.stripState.summoned { self.dismissStrip() }   // Settings takes the keyboard; the strip goes
        }
        c.refresh = { [weak self] in self?.refreshSettings(full: true) }
        return c
    }()
    private var loginItemError: String?
    private var launchFinished = false
    private var launchedForHandoff = false
    private var alertTimer: Timer?
    private var migrationOutcome = PerchMigration.Outcome(data: .notNeeded, migratedPreferences: false)

    override init() {
        injectedDefaults = nil
        super.init()
    }

    init(defaults: UserDefaults) {
        injectedDefaults = defaults
        super.init()
    }

    // When the app is hosting the XCTest bundle we only need the classes loaded, not the running UI --
    // skip all launch-time setup so unit tests don't spin up a panel, Settings window, global monitor, or
    // accessibility prompt (and don't touch the real shelf.json). (P1-2)
    static var isRunningUnitTests: Bool { NSClassFromString("XCTestCase") != nil }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        // This must be the first launch action. Every data-backed service above is lazy so nothing resolves
        // PerchPaths.base or reads a preference before the old app has been migrated (or selected in place).
        // Dev runs use their injected folder/defaults suite and skip the migration completely.
        if PerchPaths.overrideDir == nil {
            let support = PerchPaths.applicationSupportRoot
            let migration = PerchMigration(
                paths: .init(
                    legacyData: support.appendingPathComponent("Perch", isDirectory: true),
                    shakeBoardData: support.appendingPathComponent("ShakeBoard", isDirectory: true),
                    breadcrumb: support.appendingPathComponent("Perch-moved-to-ShakeBoard.txt")
                ),
                preferences: .live(newDefaults: defaults),
                resolveDataDirectory: { PerchPaths.resolveBase($0) }
            )
            migrationOutcome = migration.run()
        }
        calibReversals = defaults.integer(forKey: "calibReversals")
        calibSwing = CGFloat(defaults.double(forKey: "calibSwing"))
        var prefs = PerchPrefs(defaults: defaults)
        prefs.seedPasswordsIgnoredAppIfNeeded()
        // Load the shelf BEFORE registering the shakeboard:// handler. A cold-launch handoff URL is
        // delivered between will- and didFinishLaunching; ingesting into an unloaded model would
        // save() over shelf.json with only the new item and WIPE the existing shelf.
        model.load()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        healLoginItem()
        promptForAccessibilityIfNeeded()   // shake dies silently without it (esp. after an OS upgrade)
        DragImageOptimizer.clearTemp()      // discard stale drag-out JPEGs from a previous run
        StripExport.clear()                 // and text/image files exported by a previous run's drags
        sweepStaleHandoffs()                // purge handoff/promise dirs orphaned by a crash or rejected share
        PreviewTempDir.sweep()              // Quick Look temp files left by a dead process
        applyCalibration()
        setupPanel()   // no launch reveal: greetAtLaunch() decides (a login launch stays fully quiet)

        // Keep the shelf on-screen across display/resolution/Space changes -- the category's #1 "shelf
        // won't appear" cause is a panel stranded off-screen after an undock or resolution change. (P1-4)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenGeometryChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screenGeometryChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        startClipboard()
        setupHotKeys()   // after startClipboard: the stack shortcut drives the paste stack
        wireSettings()
        greetAtLaunch()
        shake.onShake = { [weak self] in
            guard let self, PerchPrefs(defaults: self.defaults).shakeToShow else { return }
            self.handleShake(dragging: NSEvent.pressedMouseButtons & 1 != 0)
        }
        motionMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            guard let self else { return }
            self.globalMotionEvents += 1
            self.calibrationSession.record(deltaX: event.deltaX)
            // shake: while dragging (always), or when not dragging only if the shelf has items
            if event.type == .leftMouseDragged {
                self.shake.feed(deltaX: event.deltaX, time: event.timestamp)
            } else if !self.model.items.isEmpty || (self.shelfShown && self.shakeToggle.canCloseByShake) {
                // A shake-opened strip can be shaken closed even when the shelf has no files.
                self.shake.feed(deltaX: event.deltaX, time: event.timestamp)
            }
            // A summoned strip stays until Esc / paste / a click elsewhere -- no pointer auto-hide.
            if let panel = self.panel, panel.isVisible, !self.stripState.summoned {
                if panel.frame.contains(NSEvent.mouseLocation) { self.cancelHide() }
                else if self.hideWork == nil { self.scheduleHide(after: Timing.autoHideAfterExit) }
            }
        }
    }

    // MARK: panel
    func setupPanel() {   // internal (not private) so tests can build a real panel
        let frame = stripFrame()
        let panel = ShelfPanel(contentRect: frame, styleMask: [.nonactivatingPanel, .borderless],
                               backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false   // a click on a card makes it key (nonactivating) for Space
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = Self.stripSpaces
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false

        let drop = DropView(frame: NSRect(origin: .zero, size: frame.size))
        drop.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: ThemedHostingRoot(themes: themeStore) {
            StripView(
                state: stripState, stack: pasteStack, controller: strip,
                onGear: { [weak self] in self?.openSettings() },
                onStack: { [weak self] in self?.pasteStack.railTapped() }
            )
        })
        hosting.frame = drop.bounds
        hosting.autoresizingMask = [.width, .height]
        drop.addSubview(hosting)
        ThemeAppearance.apply(themeStore.current, to: panel)
        themeBag = themeStore.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                ThemeAppearance.apply(self.themeStore.current, to: self.panel)
            }
        }
        drop.onEnter = { [weak self] in self?.model.hovering = true; self?.cancelHide() }
        drop.onExit = { [weak self] in
            guard let self else { return }
            self.model.hovering = false
            if !self.stripState.summoned { self.scheduleHide(after: Timing.autoHideAfterExit) }
        }
        drop.onDrop = { [weak self] urls in
            self?.model.add(urls)
            if self?.stripState.summoned == false { self?.scheduleHide(after: Timing.autoHideAfterDrop) }
        }
        drop.onDropCopying = { [weak self] urls in
            guard let self else { return }
            let stored = self.copyIntoShelfStore(urls)   // durable copies, not the volatile temp (F1)
            self.noteAddFailures(urls.count - stored.count)   // disk-full/copy failures -> one-line notice (P1-6)
            if !stored.isEmpty { self.model.add(stored, owned: true) }   // ShakeBoard owns these copies (P1-8)
            if !self.stripState.summoned { self.scheduleHide(after: Timing.autoHideAfterDrop) }
        }
        // Text / web links dropped on the strip become pinned clips.
        drop.onDropText = { [weak self] items in
            guard let self else { return }
            self.strip.ingestDropped(items)
            if !self.stripState.summoned { self.scheduleHide(after: Timing.autoHideAfterDrop) }
        }
        drop.onPointerExit = { [weak self] in
            guard let self else { return }
            self.model.hoveredID = nil
            self.stripState.hovered = nil
            if !self.strip.previewShowing && !self.stripState.summoned { self.relinquishShelfKey() }
        }
        panel.contentView = drop
        installShelfKeyMonitor()
        let lease = KeyLease(window: panel)
        lease.isHeld = { [weak self] in
            guard let self else { return false }
            let previewOpen = self.quickLook.isShowing(for: .shelf) || self.quickLook.isPending(for: .shelf)
            return previewOpen || self.stripState.summoned || self.stripState.editing != nil
        }
        shelfKeyLease = lease
        // Whenever the strip takes the keyboard (summoned, or a click on a card), typing goes to search.
        becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stripState.focusSearch += 1 }
        }
        // A summoned strip goes away when you click somewhere else (it loses key), like a popover.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.stripState.summoned, !self.stripDismissing else { return }
                self.dismissStrip()
            }
        }

        strip.quickLook = quickLook
        strip.stacks = pasteStack
        strip.dismiss = { [weak self] in self?.dismissStrip() }
        strip.reopen = { [weak self] notice in self?.summonStrip(notice: notice) }
        strip.giveKeyBack = { [weak self] in self?.relinquishShelfKey() }
        strip.holdOpen = { [weak self] in self?.holdStripOpen() }
        strip.showMenu = { [weak self] menu in self?.popUpInStrip(menu) }
        strip.openSettings = { [weak self] in self?.openSettings() }
        strip.quit = { [weak self] in self?.quit() }

        self.panel = panel
        if pendingReveal { pendingReveal = false; reveal() }   // a cold-launch share was waiting
    }
    static let stripSpaces: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

    // The screen the user is on: under the pointer, else main.
    private func activeScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func stripFrame(on screen: NSScreen? = nil) -> NSRect {
        guard let vf = (screen ?? activeScreen())?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: 800, height: Layout.stripHeight)
        }
        return Layout.stripFrame(in: vf)
    }
    // Full width of the screen you're on, every time it appears (displays come and go; the Dock moves).
    private func positionStrip() {
        guard let panel else { return }
        let f = stripFrame()
        if panel.frame != f { panel.setFrame(f, display: true) }
    }

    // Display/Space geometry changed: re-apply collectionBehavior (dropped by some display reconfigs) and
    // re-fit the strip to a live screen so it can't be stranded off-screen. (P1-4)
    @objc private func screenGeometryChanged() {
        guard let panel else { return }
        panel.collectionBehavior = Self.stripSpaces
        let screen = NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? activeScreen()
        let f = stripFrame(on: screen)
        if panel.frame != f { panel.setFrame(f, display: true) }
    }

    // Gear / Command-comma / relaunch: the Settings window.
    @objc func openSettings() { settingsWindow.show() }

    // MARK: visibility + auto-hide
    // Bumped on every show/hide so a hide-fade completion that lands AFTER a new reveal can tell it was
    // superseded and skip its orderOut -- otherwise a quick hide->show race would order the panel back
    // out mid-reveal. (P2-2)
    private var visibilityToken = 0
    // The shelf's INTENDED visibility, updated synchronously on every show/hide. panel.isVisible stays true
    // for the whole hide fade, so toggles must read this instead.
    private(set) var shelfShown = false {
        // The strip's Stack lane replaces the top stack bar while the strip is up (PasteStack.swift). The
        // bar comes back only once the hide fade has really ordered the strip out (hidePanel), so the two
        // never show at once; a reveal that supersedes the fade keeps it suppressed.
        didSet { if shelfShown { stackBar?.suppressed = true } }
    }

    // Command-Space: summon the strip when it's hidden (or only revealed passively), hide it when summoned.
    @objc private func toggleShelf() {
        guard panel != nil else { return }
        if shelfShown && stripState.summoned { dismissStrip() } else { summonStrip() }
    }

    // Shake: reveal the strip, or close it again if a shake opened it (ShakeToggle in SmoothScroll.swift).
    private var shakeToggle = ShakeToggle()
    private func handleShake(dragging: Bool) {
        let inUse = stripState.summoned || stripState.editing != nil || strip.previewShowing
        switch shakeToggle.shake(at: ProcessInfo.processInfo.systemUptime, shown: shelfShown && panel != nil,
                                 dragging: dragging, inUse: inUse) {
        case .reveal: reveal(byShake: true)
        case .close: dismissStrip()
        case .ignore: break
        }
    }

    // Passive reveal (shake, a copied image, a share): shown but NOT key, auto-hides.
    private func reveal(byShake: Bool = false) {
        guard panel != nil else { pendingReveal = true; return }
        if !byShake && !shelfShown { shakeToggle.reset() }   // a copy/share opened it, not a shake
        if stripState.summoned { return }            // already up and in use
        // Opening, or something new arrived (a copied image, a share): show the newest copy at the left edge.
        // A shake on an already-shown strip leaves where you scrolled alone.
        if !shelfShown || !byShake { stripState.goHome() }
        positionStrip()
        showPanel()
        scheduleHide(after: Timing.autoHideAfterReveal)
    }

    // Summon (Command-Space): shown AND key -- the caret is in the search field, Return pastes into the
    // app you were in. The panel is nonactivating, so that app stays frontmost the whole time.
    func summonStrip(notice: String? = nil) {
        guard let panel else { pendingReveal = true; return }
        shakeToggle.reset()   // Command-Space owns it now: a shake won't close it
        cancelHide()
        strip.target = strip.frontmostPID()
        stripState.query = ""
        stripState.board = nil
        stripState.filter = .all
        stripState.picks.clear()
        stripState.notice = notice
        stripState.summoned = true
        stripState.goHome()          // newest copy selected and at the left edge
        if !shelfShown || !panel.isVisible { positionStrip() }
        showPanel()
        panel.makeKey()
        stripState.focusSearch += 1
        shelfKeyLease?.touch()
    }

    // Edit (Cmd-E / the card menu): keep the strip up and key without resetting search, filter or cursor --
    // a strip that was only revealed (shake, copy) becomes summoned so it can't auto-hide mid-edit.
    private func holdStripOpen() {
        guard let panel else { return }
        cancelHide()
        if !stripState.summoned {
            strip.target = strip.frontmostPID()
            stripState.summoned = true
        }
        if !shelfShown || !panel.isVisible { positionStrip(); showPanel() }
        panel.makeKey()
        shelfKeyLease?.touch()
    }

    // Cmd-T: the Transform menu, at the pointer when it's over the strip, else at the strip's top left.
    private func popUpInStrip(_ menu: NSMenu) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let at = panel.frame.contains(mouse) ? mouse : NSPoint(x: panel.frame.minX + 60, y: panel.frame.maxY - 30)
        menu.popUp(positioning: nil, at: at, in: nil)
    }

    // Esc / paste / click elsewhere: close any preview, give the keyboard back, hide.
    private var stripDismissing = false
    func dismissStrip() {
        guard panel != nil else { return }
        stripDismissing = true
        defer { stripDismissing = false }
        if strip.previewShowing { quickLook.close() }
        stripState.summoned = false
        stripState.notice = nil
        relinquishShelfKey()
        cancelHide()
        hidePanel()
    }
    // Fade the panel in without ever activating it -- orderFrontRegardless keeps focus with the app the
    // user is working in; only the alpha animates. (P2-2)
    private func showPanel() {
        guard let panel else { return }
        shelfShown = true
        visibilityToken += 1
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Timing.fade
            panel.animator().alphaValue = 1
        }
    }
    // Fade out, then orderOut and restore alpha for the next reveal. The token guard drops the orderOut if
    // a reveal happened during the fade. (P2-2)
    private func hidePanel() {
        guard let panel, panel.isVisible else { return }
        guard !quickLook.isActive(for: .shelf) else { return }   // keep the strip while its preview is up (or landing)
        shelfShown = false
        shakeToggle.reset()
        stripState.summoned = false
        visibilityToken += 1
        let token = visibilityToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Timing.fade
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Animation completions fire on the main thread, so it's safe to assert main-actor isolation
            // here to reach visibilityToken/panel. (P2-2/P2-3)
            MainActor.assumeIsolated {
                guard let self, self.visibilityToken == token else { return }   // superseded by a reveal
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.stackBar?.suppressed = false
            }
        })
    }
    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hidePanel(); self?.hideWork = nil }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func cancelHide() { hideWork?.cancel(); hideWork = nil }

    // MARK: shake calibration
    // Settings > Shelf & Shake > Calibrate: record 2.5 s of the user's shake, with a live swing count.
    private func calibrateShake() {
        calibrationSession.start()
    }
    private func completeCalibration(reversals: Int, swing: CGFloat) {
        guard reversals >= 2, swing > 10 else { settings.calibration = .failed; return }
        calibReversals = reversals; calibSwing = swing
        defaults.set(reversals, forKey: "calibReversals")
        defaults.set(Double(swing), forKey: "calibSwing")
        applyCalibration()
        settings.calibration = .done(swings: reversals)
    }
    private func cancelCalibration() {
        guard calibrationSession.isRecording else { return }
        calibrationSession.cancel()
        settings.calibration = .idle
    }
    static func analyzeCalibrationSamples(_ samples: [CGFloat]) -> (reversals: Int, swing: CGFloat) {
        CalibrationSession.analyze(samples)
    }
    private func applyCalibration() {
        guard calibReversals >= 2 else { return }   // use defaults until calibrated
        shake.neededReversals = max(2, Int((Double(calibReversals) * (1 - variance)).rounded()))
        shake.minTravel = max(25, calibSwing * CGFloat(1 - variance))
    }

    // MARK: shakeboard:// share-extension handoff
    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        handleShakeBoardURL(url)
    }
    private func handleShakeBoardURL(_ url: URL) {
        guard url.scheme == PerchID.scheme, url.host == "add",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "dir" })?.value,
              let dir = Self.validatedHandoffDir(raw, container: Self.handoffContainer) else {
            NSLog("ShakeBoard: rejected shakeboard:// URL")
            return
        }
        // A validated share that cold-launched ShakeBoard: no greeting (it would steal focus from the sharing app).
        if !launchFinished { launchedForHandoff = true }
        ingestHandoff(at: dir)
    }

    // The ShakeBoardShare extension's own sandbox temp container -- the ONLY place a legitimate handoff folder
    // can live. Factored out so validatedHandoffDir + the launch sweep share one definition.
    static var handoffContainer: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(PerchID.shareBundleID)/Data/tmp", isDirectory: true)
    }

    // The shakeboard:// scheme is world-invocable (any app or even a webpage link can call it), so
    // `dir` is UNTRUSTED. Accept ONLY a directory named ShakeBoardHandoff-<uuid> sitting directly inside
    // the ShakeBoardShare extension's own sandbox temp container. Anything else is refused WITHOUT
    // touching the filesystem -- this is what stops shakeboard://add?dir=/Users/you/Documents from being
    // copied out and deleted. `container` is injected so tests can exercise every rejection branch. (P1-2)
    static func validatedHandoffDir(_ raw: String, container: URL) -> URL? {
        guard !raw.isEmpty else { return nil }
        let candidate = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL
        let name = candidate.lastPathComponent
        guard name.hasPrefix("ShakeBoardHandoff-"),
              UUID(uuidString: String(name.dropFirst("ShakeBoardHandoff-".count))) != nil else { return nil }
        let base = container.resolvingSymlinksInPath().standardizedFileURL
        // Must sit DIRECTLY under the extension container tmp (no traversal, no nesting).
        guard candidate.deletingLastPathComponent().path == base.path else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return candidate
    }

    // Copy the validated handoff's regular files into ShakeBoard's own store, shelve them, pop the shelf
    // up, then delete the (validated) handoff folder. Symlinks and sub-directories are skipped --
    // never followed -- so a staged symlink can't exfiltrate or escalate. ShakeBoard owns these copies
    // (shared content has no stable "original" the way a Finder drag does).
    // Absurd-size guard lives in Limits.maxIngestFileBytes (4 GiB): skip any single handoff file larger
    // than that (treated as an add failure, per P1-6). Generous enough to never bother a real share (big
    // videos included); it only bounds a hostile or runaway file from filling the disk. Disk-full during a
    // copy is caught below as a failure too. (P1-11/P3-2)
    private func ingestHandoff(at dir: URL) {
        let fm = FileManager.default
        // TOCTOU mitigation (P1-11): re-validate the folder AT ingest time, not just when the URL arrived.
        // validatedHandoffDir re-resolves symlinks and re-checks it's a real directory sitting directly in
        // the extension container, so a dir swapped for a symlink/other path after the first check is caught
        // here. Residual: a rename between this re-check and the enumerator open is a sub-millisecond window
        // against the extension's OWN sandbox container (only ShakeBoardShare writes there) -- accepted under the
        // local threat model; see SECURITY.md.
        guard let dir = Self.validatedHandoffDir(dir.path, container: Self.handoffContainer) else {
            NSLog("ShakeBoard: handoff re-validation failed at ingest"); return
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        // Bounded, top-level enumeration -- stop after the cap instead of materializing + sorting a whole
        // (possibly huge, hostile) directory. Symlinks and sub-directories are never followed. (C6)
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return }
        var candidates: [URL] = []
        var skipped = 0
        while candidates.count < Limits.maxHandoffFiles, let f = en.nextObject() as? URL {
            let vals = try? f.resourceValues(forKeys: Set(keys))
            guard vals?.isSymbolicLink != true, vals?.isRegularFile == true else { continue }
            if let size = vals?.fileSize, size > Limits.maxIngestFileBytes {
                skipped += 1
                NSLog("ShakeBoard: skipping oversized handoff file \(f.lastPathComponent) (\(size) bytes)"); continue
            }
            candidates.append(f)
        }
        // Did a regular file remain beyond the 100-file cap? If so we must NOT delete the whole handoff --
        // that would destroy shared files we never copied (the extension already told the user they landed).
        // Leave the overflow in place; the launch sweep reclaims it after 24h. (P1-7)
        var truncated = false
        while let f = en.nextObject() as? URL {
            let vals = try? f.resourceValues(forKeys: Set(keys))
            if vals?.isSymbolicLink != true, vals?.isRegularFile == true { truncated = true; break }
        }
        if truncated { NSLog("ShakeBoard: handoff exceeded 100 files; copied 100, left the rest for the sweep") }
        candidates.sort { $0.lastPathComponent < $1.lastPathComponent }

        let store = shelfStoreURL()
        var added: [URL] = []
        var failures = 0
        for f in candidates {
            let dest = uniqueStoreURL(in: store, name: f.lastPathComponent)
            do {
                try fm.copyItem(at: f, to: dest)   // disk-full surfaces here as a throw -> counted failure (P1-11)
                added.append(dest)
                try? fm.removeItem(at: f)   // drop the source only AFTER a successful copy
            } catch {
                failures += 1                // keep the source -- it may be the only copy
                NSLog("ShakeBoard: ingest copy failed: \(error)")
            }
        }
        // Tear down the handoff ONLY when every candidate committed AND nothing overflowed the cap -- so no
        // shared file is ever deleted without being copied. On failure or overflow, leave the folder; the
        // launch sweep is the backstop for anything left behind. (C5/F6/P1-7)
        if failures == 0 && !truncated { try? fm.removeItem(at: dir) }
        // One-line, no-alert notice of anything that didn't land (copy/disk-full failures + oversized skips). (P1-6)
        noteAddFailures(failures + skipped)
        guard !added.isEmpty else { return }
        model.add(added, owned: true)   // ShakeBoard owns these copies (P1-8)
        reveal()
    }
    private func shelfStoreURL() -> URL {
        let base = PerchPaths.base.appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // Remove handoff/promise scratch dirs left behind by a crash, a rejected share, or an ingest failure
    // (older than a day so an in-flight share is never touched). Backstop for the orphan paths. (F6/C8)
    private func sweepStaleHandoffs() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Timing.staleHandoffAge)
        let locations: [(URL, String)] = [
            (Self.handoffContainer, "ShakeBoardHandoff-"),
            (fm.temporaryDirectory, "ShakeBoardPromise-"),
        ]
        for (base, prefix) in locations {
            guard let entries = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for e in entries where e.lastPathComponent.hasPrefix(prefix) {
                let mod = (try? e.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let mod, mod < cutoff { try? fm.removeItem(at: e) }
            }
        }
    }

    // Copy materialized file promises into ShakeBoard's durable store and return the store URLs (the volatile
    // temp source is removed). Mirrors ingestHandoff for shared content -- these have no stable original
    // to bookmark, so ShakeBoard owns the copy. (F1)
    private func copyIntoShelfStore(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        let store = shelfStoreURL()
        var out: [URL] = []
        for src in urls {
            let dest = uniqueStoreURL(in: store, name: src.lastPathComponent)
            do {
                try fm.copyItem(at: src, to: dest)
                out.append(dest)
                try? fm.removeItem(at: src)   // just this file; siblings may still be copying (swept at launch)
            } catch { NSLog("ShakeBoard: promise copy-in failed: \(error)") }
        }
        return out
    }
    private func uniqueStoreURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: dest.path) else { return dest }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = dir.appendingPathComponent(candidate)
            n += 1
        } while fm.fileExists(atPath: dest.path)
        return dest
    }

    // MARK: clipboard capture -> history (+ copied images -> shelf)

    // Global shortcuts (HotKeys.swift): Command-Space shows/hides the strip; the optional, user-recorded
    // stack shortcut (unset by default) toggles the paste stack. Failures are listed in Settings > Shortcuts
    // (a Command-Space failure also opens Settings at launch -- without it there's no way in).
    private func setupHotKeys() {
        let keys = PerchHotKeys(defaults: defaults,
                                onToggleStrip: { [weak self] in self?.toggleShelf() },
                                onToggleStack: { [weak self] in self?.pasteStack.toggle() })
        keys.start()
        for f in keys.failures { NSLog("ShakeBoard: hotkey registration failed: \(f)") }
        hotKeys = keys
    }
    // MARK: Quick Look on the shelf

    private func installShelfKeyMonitor() {
        guard shelfKeyMonitor == nil else { return }
        shelfKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let panel = self.panel, e.window === panel else { return e }
            return MainActor.assumeIsolated {
                self.shelfKeyLease?.touch()
                return self.strip.handleKey(e) ? nil : e
            }
        }
    }

    // The preview ending ends the keyboard interaction: give the keyboard back right away, even if the
    // pointer is still over the panel (otherwise typing would be swallowed until the pointer moves).
    func previewClosed(_ owner: PreviewOwner) {   // internal for tests
        if owner == .stack { stackBar?.releaseKey() }
        guard owner == .shelf, let panel else { return }
        guard !stripState.summoned else { return }   // a summoned strip keeps the keyboard (search, Return)
        relinquishShelfKey()
        if !panel.frame.contains(NSEvent.mouseLocation) { scheduleHide(after: Timing.autoHideAfterExit) }
    }

    // Give the keyboard back to the app you were in (see relinquishKey in QuickLook.swift).
    var shelfPanelForTesting: NSPanel? { panel }
    private func relinquishShelfKey() {
        guard let panel else { return }
        relinquishKey(panel)
    }

    // Called from didFinishLaunching, i.e. strictly AFTER model.load() in willFinishLaunching -- a capture
    // that reached the shelf before load() could otherwise save() over a non-empty shelf.json.
    private func startClipboard() {
        // Pinboards first: retention runs inside load(), and every board membership must survive launch.
        clipPins.load()
        let stack = pasteStack
        stack.load()       // stacks.json: their clips are protected from retention, like pins
        let boards = pinboards
        clipStore.pinned = { [weak self, weak stack, weak boards] in
            var ids = (stack?.pinnedIDs ?? []).union(boards?.allClipIDs ?? [])
            if boards?.retentionUnknown == true {
                ids.formUnion(self?.clipStore.clips.map(\.id) ?? [])
            }
            return ids
        }
        // The user's retention (Settings > Clipboard) applies from the first load.
        let prefs = PerchPrefs(defaults: defaults)
        clipStore.maxCount = prefs.historyMaxCount
        clipStore.maxAge = prefs.historyMaxAge
        // Before any clip leaves (including retention inside load()), make inherited "hidden from AI" durable.
        clipStore.willDrop = { [weak self] in
            guard let self else { return }
            AIVisibility.persistInheritedHides(store: self.clipStore)
        }
        clipStore.load()
        ocrService.startBackfill()
        if !clipStore.isDegraded {
            pinboards.prune(keeping: Set(clipStore.clips.map(\.id)))
            stack.prune(keeping: Set(clipStore.clips.map(\.id)))
        }
        pinboards.onRetentionReleased = Self.retentionReleaseHandler(
            isDegraded: { [weak self] in self?.clipStore.isDegraded ?? true },
            prune: { [weak self] in self?.clipStore.prune() }
        )
        let monitor = ClipboardMonitor(pasteboard: ClipboardWriter.pasteboard)
        monitor.isEnabled = !prefs.capturePaused
        monitor.extraIgnored = { [weak self] in
            guard let self else { return [] }
            return Set(PerchPrefs(defaults: self.defaults).ignoredApps)
        }
        ClipboardWriter.monitor = monitor
        monitor.onCapture = { [weak self] captured in
            // The stack collecting when the copy was SEEN gets it, even if collecting moves while it's saved.
            let target = self?.pasteStack.collectingID
            self?.clipStore.ingest(captured) { clip, isNew in
                if ClipboardMonitor.debug { NSLog("ShakeBoard clips: ingest -> \(clip.map { "\($0.kind) new=\(isNew)" } ?? "rejected")") }
                guard let self, let clip else { return }
                self.didCapture(clip, isNew: isNew, capturedChangeCount: captured.snapshot.changeCount, target: target)
            }
        }
        monitor.start()
        clipMonitor = monitor

        // Paste stack: pins its queued clips against history eviction (wired above, with the user's pins),
        // gets every capture, ends itself (restoring the clipboard if still ShakeBoard's) before history is cleared.
        clipboardDidCapture = { [weak stack] clip, count, target in stack?.didCapture(clip, capturedChangeCount: count, into: target) }
        stack.onPinsReleased = { [weak self] in self?.clipStore.prune() }
        clipboardWillClear = { [weak stack] in stack?.stop() }   // stacks keep their clips (like pins)
        stackKeys.start(stack)
        let bar = StackBarController(stack: stack, themes: themeStore)
        stackBar = bar
        bar.suppressed = shelfShown
        bar.quickLook = quickLook
        bar.store = clipStore
        startAIBridge()
        // Dev-only (needs PERCH_DATA_DIR too, so it can never fire in the real install): open the UI at
        // launch for headless screenshots, since synthetic hotkeys are blocked for scripts.
        if PerchPaths.overrideDir != nil, let show = ProcessInfo.processInfo.environment["PERCH_DEBUG_SHOW"] {
            if let id = ProcessInfo.processInfo.environment["PERCH_DEBUG_THEME"] {
                themeStore.select(id, persist: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self else { return }
                // Dev-only OCR seed: PERCH_DEBUG_SHOW=ocr plus PERCH_OCR_SEED=/path/to/image.png.
                if show.contains("ocr"),
                   let path = ProcessInfo.processInfo.environment["PERCH_OCR_SEED"],
                   let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    let snap = RawSnapshot(changeCount: -1, allTypes: [ClipTypes.png],
                                           items: [[RawRep(type: ClipTypes.png, data: data)]])
                    let cap = CapturedClipboard(snapshot: snap, sourceBundleID: PerchID.appBundleID,
                                                sourceAppName: "ShakeBoard OCR Seed", capturedAt: Date())
                    self.clipStore.ingest(cap) { clip, isNew in
                        guard let clip else { NSLog("ShakeBoard OCR seed: image rejected"); return }
                        if isNew { self.ocrService.enqueue(clip, priority: true) }
                        self.ocrService.whenIdle {
                            NSLog("ShakeBoard OCR seed: \(self.ocrService.text(for: clip)?.count ?? 0) chars")
                        }
                    }
                }
                if show.contains("pinboards") {
                    self.seedDebugPinboards(show)
                    return
                }
                // Dev-only: `stacks` seeds sample stacks from the newest clips WITHOUT touching the clipboard
                // (Ready is only marked, never armed): "Vendor info" Ready at #2, "Stack 2" Collecting, one archived.
                if show.contains("stacks") {
                    let samples = ["https://example.com/invoice/4821", "Invoice 4821 -- 12 mugs, 4 platters",
                                   "Net 30", "Edgecomb, ME", "(207) 555-0142", "orders@example.com",
                                   "123 Main St, Edgecomb, ME 04556", "Acme Ceramics LLC",
                                   "Glaze: celadon\nGlaze: tenmoku\nGlaze: shino\nGlaze: ash"]
                    @MainActor func seed(_ i: Int) {
                        guard i < samples.count else { self.seedDebugStacks(show); return }
                        let snap = RawSnapshot(changeCount: -1, allTypes: [ClipTypes.plainText],
                                               items: [[RawRep(type: ClipTypes.plainText, data: Data(samples[i].utf8))]])
                        self.clipStore.ingest(CapturedClipboard(snapshot: snap, sourceBundleID: "com.apple.Safari",
                                                                sourceAppName: "Safari", capturedAt: Date())) { _, _ in seed(i + 1) }
                    }
                    seed(0)
                } else if show.contains("stack") { self.pasteStack.start() }
                // Dev-only: queue the 4 newest clips into the collecting stack (no clipboard write).
                if show.contains("stackfill") {
                    for clip in self.clipStore.clips.prefix(4).reversed() {
                        self.pasteStack.didCapture(clip, capturedChangeCount: -1)
                    }
                }
                // Dev-only: render the bar under the menu bar to <PERCH_DATA_DIR>/bar-snapshot.png.
                if show.contains("barsnapshot"), let dir = PerchPaths.overrideDir {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.stackBar?.snapshot(to: dir.appendingPathComponent("bar-snapshot.png")) }
                }
                if show.contains("bigshelf"), let dir = PerchPaths.overrideDir {   // a crowded shelf (~90 files)
                    let seedDir = dir.appendingPathComponent("seed-files")
                    try? FileManager.default.createDirectory(at: seedDir, withIntermediateDirectories: true)
                    let urls = (1...40).map { i -> URL in
                        let u = seedDir.appendingPathComponent(String(format: "shelf-file-%02d.txt", i))
                        try? Data("file \(i)".utf8).write(to: u)
                        return u
                    }
                    if self.model.items.isEmpty { _ = self.model.add(urls) }
                }
                if show.contains("wheeltest") {   // seed enough cards to overflow any screen, then glide
                    @MainActor func seed(_ i: Int) {
                        guard i < 40 else {
                            self.summonStrip()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                if let panel = self.panel { SmoothWheel.shared.debugSelfTest(in: panel) }
                            }
                            return
                        }
                        let snap = RawSnapshot(changeCount: -1, allTypes: [ClipTypes.plainText],
                                               items: [[RawRep(type: ClipTypes.plainText, data: Data("Sample copy \(i)".utf8))]])
                        self.clipStore.ingest(CapturedClipboard(snapshot: snap, sourceBundleID: "com.apple.Safari",
                                                                sourceAppName: "Safari", capturedAt: Date())) { _, _ in seed(i + 1) }
                    }
                    seed(0)
                }
                if show.contains("consent") {   // the AI consent panel, for screenshots
                    self.aiConsent.ask(name: "Claude Code", detail: "com.anthropic.claude-code, signed by team Q6L2SF6YDW",
                                       reported: "claude-code") { _ in }
                    if show.contains("snapshot"), let dir = PerchPaths.overrideDir {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.aiConsent.snapshot(to: dir.appendingPathComponent("consent-snapshot.png"))
                        }
                    }
                }
                if show.contains("settings") {
                    if show.contains("privacy") { self.settings.section = .privacy }
                    self.settingsWindow.show()
                    if show.contains("snapshot"), let dir = PerchPaths.overrideDir {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.settingsWindow.snapshotSections(to: dir) }
                    }
                    return
                }
                if show.contains("history") || show.contains("strip") { self.summonStrip() }
                else if show.contains("shelf") { self.reveal() }
                // Dev-only: open the editor on the newest code card (else text card) for screenshots.
                if show.contains("edit") {
                    let clips = self.clipStore.clips.filter { self.strip.canEdit($0.id) }
                    let pick = clips.first { self.stripState.kind(of: $0).isCode } ?? clips.first
                    if let pick { self.strip.beginEdit(pick.id) }
                }
                // Dev-only: write the strip's own rendering to PERCH_DATA_DIR (scripts
                // can't screen-record; a window can always render itself).
                // Dev-only: `picks` Command-click-picks three copies out of order (3rd, 1st, 5th newest) for screenshots.
                if show.contains("picks") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let r = self.stripState.sections.recent.map(\.id)
                        guard r.count >= 5 else { return }
                        self.stripState.clickClip(r[2], command: false, shift: false)
                        self.stripState.clickClip(r[0], command: true, shift: false)
                        self.stripState.clickClip(r[4], command: true, shift: false)
                    }
                }
                if show.contains("snapshot"), let dir = PerchPaths.overrideDir {
                    // `first`: select the first card (the strip already opens at its start; this moves the
                    // selection highlight too).
                    if show.contains("first") { self.stripState.cursor = self.stripState.sections.order.first }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        guard let v = self.panel?.contentView,
                              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                        v.cacheDisplay(in: v.bounds, to: rep)
                        let name = show.contains("stripsnapshot")
                            ? "strip-snapshot-\(self.themeStore.current.id).png" : "strip-snapshot.png"
                        try? rep.representation(using: .png, properties: [:])?
                            .write(to: dir.appendingPathComponent(name))
                        NSLog("ShakeBoard debug: strip snapshot \(Int(v.bounds.width))x\(Int(v.bounds.height)) written")
                    }
                }
                if show.contains("preview") {   // real QLPreviewView panel; logs whether ShakeBoard got activated
                    let file = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertNoteIcon.icns")
                    let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                    self.quickLook.open(owner: .stack) { _ in [file] }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let after = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                        NSLog("ShakeBoard preview probe: front before=\(before) after=\(after) shakeboardActive=\(NSApp.isActive) keyWindow=\(String(describing: NSApp.keyWindow))")
                    }
                }
            }
        }
    }

    // Dev-only (PERCH_DEBUG_SHOW=stacks): sample stacks over the newest clips -- Ready is only MARKED, never armed,
    // so the clipboard is never written. "Vendor info" Ready at #2, "Stack 2" Collecting, one archived.
    private func seedDebugStacks(_ show: String) {
        let ids = clipStore.clips.prefix(9).map(\.id)
        let s = pasteStack
        let a = s.newStack(name: "Vendor info", clips: Array(ids.dropFirst(1).prefix(5).reversed()))
        let b = s.newStack(name: "Stack 2", clips: [ids[0]])
        _ = s.newStack(name: "Stack 3")
        let c = s.newStack(name: "Invoice 4821", clips: Array(ids.suffix(3)))
        s.archive(c)
        s.collect(into: b)
        if !show.contains("collectonly") { s.debugMarkReady(a, cursor: 1) }
        s.selectedID = show.contains("selectb") || show.contains("collectonly") ? b : a
        if show.contains("strip") { summonStrip() }
        if show.contains("stacksfilter") { stripState.filter = .stacks }   // after summon (it resets the filter)
    }

    // Dev-only (PERCH_DEBUG_SHOW=pinboards): local sample clips and memberships. It never reads or writes the
    // pasteboard, and the PERCH_DATA_DIR gate above keeps it away from real ShakeBoard data.
    private func seedDebugPinboards(_ show: String) {
        let samples = [
            "Edgecomb gallery address (sample)", "Portland gallery address (sample)",
            "Portsmouth gallery address (sample)", "Gallery directions link (sample)",
            "{% for product in collection.products %}", "{{ product.title | escape }}",
            "{% if product.available %}In stock{% endif %}", "Thanks for your order -- sample reply",
        ]
        var ids: [UUID] = []
        @MainActor func seed(_ index: Int) {
            guard index < samples.count else {
                guard ids.count == samples.count, let pinned = self.pinboards.defaultBoardID else {
                    NSLog("ShakeBoard debug: pinboard seed stopped because one or more sample copies could not be stored")
                    return
                }
                _ = self.pinboards.add([ids[7]], to: pinned)
                let gallery = self.pinboards.create(name: "Gallery addresses", color: .green,
                                                    clipIDs: Array(ids.prefix(4)))
                _ = self.pinboards.create(name: "Shopify snippets", color: .purple,
                                          clipIDs: Array(ids.dropFirst(4).prefix(3)))
                self.summonStrip()
                if let gallery { self.stripState.toggleBoard(gallery) }
                guard show.contains("snapshot"), let dir = PerchPaths.overrideDir else { return }
                // Generous delays: the summon animation and SwiftUI's async re-render must settle before each capture.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.snapshotStrip(to: dir.appendingPathComponent("strip-pinboards.png"))
                    self.stripState.board = nil
                    self.stripState.resetCursor()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.snapshotStrip(to: dir.appendingPathComponent("strip-pinboards-all.png"))
                    }
                }
                return
            }
            let snapshot = RawSnapshot(changeCount: -1, allTypes: [ClipTypes.plainText],
                                       items: [[RawRep(type: ClipTypes.plainText, data: Data(samples[index].utf8))]])
            let capture = CapturedClipboard(snapshot: snapshot, sourceBundleID: "com.apple.Safari",
                                            sourceAppName: "Safari", capturedAt: Date())
            clipStore.ingest(capture) { clip, _ in
                if let clip { ids.append(clip.id) }
                seed(index + 1)
            }
        }
        seed(0)
    }

    private func snapshotStrip(to url: URL) {
        guard let view = panel?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        NSLog("ShakeBoard debug: strip snapshot \(Int(view.bounds.width))x\(Int(view.bounds.height)) written to \(url.lastPathComponent)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningUnitTests else { return }
        cancelCalibration()
        shakeLogTimer?.invalidate(); shakeLogTimer = nil
        if let motionMonitor { NSEvent.removeMonitor(motionMonitor) }
        motionMonitor = nil
        themeStore.flushPendingSave()   // a color edit made <300 ms before Command-Q
        quickLook.close()       // deletes any preview temp files
        StripExport.clear()     // drag-out copies of clip text/images
        pasteStack.stop()       // restore the user's clipboard if the stack still owns it
        _ = ocrService.flushShelfCacheWrites(timeout: 1) // cache cleanup never waits behind Vision
        clipStore.flush()       // finish queued index/payload writes
        aiBridge.stop()         // removes the socket
        aiBridge.audit.flush()
    }

    // MARK: AI bridge (MCP)

    private func startAIBridge() {
        let b = aiBridge
        b.setConsent = { [weak self] key, label, allow in self?.settings.setAIConsent(key, allow, label: label) }
        b.askConsent = { [weak self] reported, invoker, done in
            self?.aiConsent.ask(name: invoker.name, detail: invoker.label, reported: reported, done: done)
        }
        b.snapshot = { [weak self] in self?.aiSnapshot() ?? AISnapshot(records: [], hiddenCount: 0, shelfNames: [], redactContacts: true) }
        b.onAudit = { [weak self] in
            guard let self, self.settingsWindow.isOpen else { return }
            self.refreshSettings(full: true)
        }
        b.start()
    }

    // What AI tools may see, built on main; text is read lazily off main from each clip's sidecar.
    private func aiSnapshot() -> AISnapshot {
        let p = PerchPrefs(defaults: defaults)
        AIVisibility.persistInheritedHides(store: clipStore)
        let hiddenApps = AIVisibility.hiddenApps(p)
        let hiddenClips = AIHiddenClips.shared.ids
        let byID = Dictionary(clipStore.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var records: [AIRecord] = []
        var hidden = 0
        for c in clipStore.clips {
            if AIVisibility.isHidden(c, byID: byID, hiddenApps: hiddenApps, hiddenClips: hiddenClips) { hidden += 1; continue }
            let textRep = c.reps.first { $0.type == ClipTypes.plainText }
            let ocrURL = clipStore.payloadDir(c.id).appendingPathComponent("ocr.txt")
            let useOCR = p.recognizeTextInImages && c.kind == .image && FileManager.default.fileExists(atPath: ocrURL.path)
            let textURL = useOCR ? ocrURL : textRep.map { clipStore.payloadDir(c.id).appendingPathComponent($0.file) }
            let textBytes = useOCR
                ? ((try? ocrURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                : (c.kind == .image ? 0 : (textRep?.bytes ?? c.preview.utf8.count))
            records.append(AIRecord(id: c.id, kind: c.kind, createdAt: c.createdAt, lastUsedAt: c.lastUsedAt,
                                    sourceApp: c.sourceAppName, pixelWidth: c.pixelWidth, pixelHeight: c.pixelHeight,
                                    preview: c.preview,
                                    boards: pinboards.boards(containing: c.id).map(\.name),
                                    textBytes: textBytes,
                                    loadText: { limit in textURL.flatMap { AIRecord.read($0, limit: limit) } }))
        }
        return AISnapshot(records: records, hiddenCount: hidden,
                          shelfNames: p.aiIncludeShelfNames ? model.items.map { $0.url.lastPathComponent } : [],
                          redactContacts: p.aiRedactContacts)
    }

    private func didCapture(_ clip: Clip, isNew: Bool, capturedChangeCount: Int, target: UUID?) {
        if isNew, clip.kind == .image { ocrService.enqueue(clip, priority: true) }
        if clip.kind == .image, addImagesToShelf { ingestOwnedImage(from: clip) }
        clipboardDidCapture?(clip, capturedChangeCount, target)
    }
    // Hook for the paste stacks: the clip, the pasteboard changeCount it was read at, and the stack that was
    // collecting when the copy was seen.
    var clipboardDidCapture: ((Clip, Int, UUID?) -> Void)?

    // Copy a clipboard image into Shelf/ (never point the shelf at a Clips/ sidecar: history retention would
    // delete it) and shelve it as an owned copy. Dedupes against images already on the shelf by content, rolls
    // the file back if the add doesn't land, and reveals the shelf at most once per burst of copies.
    @discardableResult
    func ingestOwnedImage(from clip: Clip) -> Bool {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var landedAny = false
        for (i, src) in clipStore.imageURLs(for: clip).enumerated() {   // multi-image copies shelve each image
            guard let data = try? Data(contentsOf: src) else { continue }
            if let existing = ownedShelfItem(matching: data) {
                model.add([existing.url], owned: true)   // already there: bump it to the front, don't duplicate
                ocrService.reuseOCR(from: clip, imageIndex: i, for: existing)
                landedAny = true
                continue
            }
            let suffix = i == 0 ? "" : " (\(i + 1))"
            let dest = uniqueStoreURL(in: shelfStoreURL(), name: "Image \(fmt.string(from: clip.createdAt))\(suffix).png")
            do { try data.write(to: dest, options: .atomic) } catch {
                noteAddFailures(1); NSLog("ShakeBoard: copied-image write failed: \(error)"); continue
            }
            // Transactional: a bookmark OR shelf.json save failure rolls back both the item and the file.
            guard model.add([dest], owned: true, transactional: true) == 1 else {
                try? FileManager.default.removeItem(at: dest)
                noteAddFailures(1)
                continue
            }
            if let added = model.items.first(where: { $0.url.standardizedFileURL == dest.standardizedFileURL }) {
                ocrService.reuseOCR(from: clip, imageIndex: i, for: added)
            }
            landedAny = true
        }
        if landedAny {
            let show = PerchPrefs(defaults: defaults).showOnImageCopy
            if Self.shouldRevealForImage(showOnImageCopy: show, lastReveal: lastImageReveal, now: Date()) { reveal() }
            if show { lastImageReveal = Date() }
        }
        return landedAny
    }
    // The ONLY capture-time reveal (copied images and copied screenshots both arrive here): respects the
    // "Show ShakeBoard when an image is copied" pref and shows at most once per 2 s burst.
    nonisolated static func shouldRevealForImage(showOnImageCopy: Bool, lastReveal: Date, now: Date) -> Bool {
        showOnImageCopy && now.timeIntervalSince(lastReveal) > 2
    }
    private func ownedShelfItem(matching data: Data) -> ShelfItem? {
        for item in model.items where item.ownedCopy && !item.missing && item.url.pathExtension.lowercased() == "png" {
            let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard size == data.count, let other = try? Data(contentsOf: item.url) else { continue }
            if other == data { return item }
        }
        return nil
    }

    private func clearClipboardHistory() {
        quickLook.closeClipPreviews()   // preview temp files hold clip text too -- gone before the clear
        StripExport.clear()             // so do drag-out exports
        clipboardWillClear?()
        stripState.forgetHeads()
        clipStore.clearAll()            // keeps every clip referenced by a pinboard or stack
        if !clipStore.isDegraded {
            pinboards.prune(keeping: Set(clipStore.clips.map(\.id)))
            pasteStack.prune(keeping: Set(clipStore.clips.map(\.id)))
            AIHiddenClips.shared.prune(keeping: Set(clipStore.clips.map(\.id)))
        }
    }
    // The paste stack ends itself (restoring the clipboard) before history is wiped.
    var clipboardWillClear: (() -> Void)?

    private func clearShelf() { model.clear() }
    // Command-Q in the strip and Quit in Settings: the same clean terminate (applicationWillTerminate tidies up).
    private func quit() { NSApp.terminate(nil) }

    // MARK: reachability (no menu-bar icon -- Reachability.swift)

    // Relaunching ShakeBoard while it runs (Spotlight, Finder, the Dock): Settings, plus a glimpse of the strip so
    // you can see where it lives. The strip is only revealed (not summoned): Settings takes the keyboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !Self.isRunningUnitTests else { return false }
        settingsWindow.show()
        reveal()
        return false
    }

    // A cold launch you started yourself shows Settings once; a login-item launch stays silent; a failed
    // Command-Space opens Settings on Shortcuts even at login (it's the only other way in).
    private func greetAtLaunch() {
        let debugShow = PerchPaths.overrideDir != nil && ProcessInfo.processInfo.environment["PERCH_DEBUG_SHOW"] != nil
        defer { launchFinished = true }
        let login = LaunchGreeting.isLoginLaunch(appleEventSaysLoginItem: LaunchGreeting.appleEventSaysLoginItem(),
                                                 loginItemEnabled: SMAppService.mainApp.status == .enabled,
                                                 sessionStart: LaunchGreeting.consoleLoginTime(), now: Date())
        guard let section = LaunchGreeting.section(loginLaunch: login, handoffLaunch: launchedForHandoff,
                                                   debugShow: debugShow,
                                                   stripShortcutFailed: hotKeys?.stripFailed ?? false,
                                                   renameMigrationThisLaunch: migrationOutcome.changedThisLaunch) else { return }
        settingsWindow.show(section: section)
        // A forced login-item welcome needs Settings, not a second transient strip. Ordinary cold launches
        // retain their existing glimpse of the strip.
        if section == .general && !login { reveal() }
    }
    private func setLaunchAtLogin(_ on: Bool) {
        // A dev run (PERCH_DATA_DIR) must never point the real login item at a branch build.
        guard PerchPaths.overrideDir == nil else { loginItemError = "not available in a dev run"; return }
        do {
            if !on {
                try SMAppService.mainApp.unregister()
                defaults.set(false, forKey: "wantsLoginItem")
            } else {
                try SMAppService.mainApp.register()
                defaults.set(true, forKey: "wantsLoginItem")
                defaults.set(currentBuildStamp(), forKey: "loginItemBuildStamp")
            }
            loginItemError = nil
        } catch {
            NSLog("ShakeBoard: launch-at-login toggle failed: \(error)")
            loginItemError = error.localizedDescription
        }
        refreshSettings(full: true)
    }

    // MARK: Settings wiring
    private func wireSettings() {
        var a = SettingsModel.Actions()
        a.prefsChanged = { [weak self] in self?.applyPrefs() }
        a.setLaunchAtLogin = { [weak self] on in self?.setLaunchAtLogin(on) }
        a.launchAtLoginEnabled = { SMAppService.mainApp.status == .enabled }
        a.accessibilityTrusted = { AXIsProcessTrusted() }
        a.pasteboardAccessStatus = { PasteboardAccessStatus.current() }
        a.openAccessibility = { [weak self] in self?.openAccessibilitySettings() }
        a.stackShortcut = { [weak self] in self?.hotKeys?.stackShortcut }
        a.setStackShortcut = { [weak self] combo in
            guard let self, let keys = self.hotKeys else { return false }
            let ok = keys.setStackShortcut(combo)
            self.refreshSettings(full: false)
            return ok
        }
        a.stackShortcutFailed = { [weak self] in self?.hotKeys?.stackFailed ?? false }
        a.stripShortcutFailed = { [weak self] in self?.hotKeys?.stripFailed ?? false }
        a.suspendStackShortcut = { [weak self] on in self?.hotKeys?.suspendStackShortcut(on) }
        a.calibrate = { [weak self] in self?.calibrateShake() }
        a.cancelCalibration = { [weak self] in self?.cancelCalibration() }
        a.clearHistory = { [weak self] in self?.clearClipboardHistory(); self?.refreshSettings(full: true) }
        a.clearShelf = { [weak self] in self?.clearShelf(); self?.refreshSettings(full: true) }
        a.counts = { [weak self] in
            guard let self else { return (0, 0, 0, 0) }
            return (self.clipStore.clips.count, self.clipPins.ids.count, self.model.items.count, self.model.ownedCount)
        }
        a.quit = { NSApp.terminate(nil) }
        a.aiAuditEntries = { [weak self] in self?.aiBridge.audit.load(limit: 200) ?? [] }
        a.clearAIAudit = { [weak self] in self?.aiBridge.audit.clear() }
        a.aiHelperPath = {
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("shakeboard-mcp").path ?? ""
        }
        a.connectAI = { t, done in
            // A dev run must never register a branch build in the user's real Claude / Codex config.
            guard PerchPaths.overrideDir == nil else { done("Not available in a dev run."); return }
            let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("shakeboard-mcp").path ?? ""
            t.run(helper: helper, completion: done)
        }
        a.isDevRun = { PerchPaths.overrideDir != nil }
        settings.actions = a
        applyPrefs()
        // Keep the gear's warning dot current (Accessibility can be granted or revoked any time; save
        // failures flip on their own). Cheap: no disk, no IPC on this path.
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSettings(full: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        alertTimer = t
        refreshSettings(full: false)
    }

    // Apply every pref Settings can change (also at launch).
    private func applyPrefs() {
        let p = PerchPrefs(defaults: defaults)
        AIVisibility.persistInheritedHides(store: clipStore)   // a newly hidden app hides its copies' edits too
        applyCalibration()
        clipMonitor?.isEnabled = !p.capturePaused
        ocrService.preferencesChanged()
        if model.reduceOnDrag != p.reduceOnDrag { model.reduceOnDrag = p.reduceOnDrag }
        updateShakeLogging(enabled: p.debugShakeLog)
        if clipStore.maxCount != p.historyMaxCount || clipStore.maxAge != p.historyMaxAge {
            clipStore.maxCount = p.historyMaxCount
            clipStore.maxAge = p.historyMaxAge
            clipStore.prune()
        }
        stripState.objectWillChange.send()   // images-to-shelf changes which cards Recent shows
        refreshSettings(full: settingsWindow.isOpen)
    }

    private func updateShakeLogging(enabled: Bool) {
        guard enabled else {
            shakeLogTimer?.invalidate(); shakeLogTimer = nil
            globalMotionEvents = 0; localCalibrationEvents = 0
            return
        }
        guard shakeLogTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSLog("ShakeBoard shake: global=\(self.globalMotionEvents) local=\(self.localCalibrationEvents) "
                      + "reversals=\(self.shake.currentReversalCount) trusted=\(AXIsProcessTrusted())")
                self.globalMotionEvents = 0
                self.localCalibrationEvents = 0
            }
        }
        RunLoop.main.add(t, forMode: .common)
        shakeLogTimer = t
    }

    private func alertInputs() -> SettingsAlerts.Inputs {
        var i = SettingsAlerts.Inputs()
        i.accessibilityTrusted = AXIsProcessTrusted()
        i.shelfSaveFailed = model.lastSaveFailed
        i.addFailures = lastAddFailureCount
        i.hotKeyFailures = hotKeys?.failures ?? []
        i.historyClearFailed = clipStore.clearFailed
        i.historyDegraded = clipStore.isDegraded
        i.historySaveFailed = clipStore.lastSaveFailed
        i.pinsSaveFailed = clipPins.lastSaveFailed
        i.pinboardsSetAside = pinboards.setAsideFileName
        i.pinboardsReadOnly = pinboards.readOnly
        i.stacksSaveFailed = pasteStack.lastSaveFailed
        i.capturePaused = PerchPrefs(defaults: defaults).capturePaused
        i.migrationFailure = migrationOutcome.legacyFailure
        i.migrationLegacyLeftBehind = migrationOutcome.legacyDataLeftBehind
        i.loginItemError = loginItemError
        let p = PerchPrefs(defaults: defaults)
        if p.aiAccessEnabled, let e = aiBridge.startError { i.aiBridgeError = e }
        return i
    }
    func refreshSettings(full: Bool) {
        settings.refresh(alertInputs: alertInputs(), full: full)
        let dot = settings.needsAttention
        if stripState.gearAlert != dot { stripState.gearAlert = dot }
    }

    // MARK: accessibility (the global mouse monitor that powers the shake needs it)
    // After a macOS major upgrade -- and for ad-hoc-signed builds whose code identity isn't stable --
    // the Accessibility (TCC) grant is commonly dropped, which silently kills the shake. Prompt on
    // launch and expose a one-click fix in the menu so it never fails silently again.
    private func promptForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        // kAXTrustedCheckOptionPrompt -- the literal key sidesteps the Unmanaged<CFString> import dance.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }
    @objc private func openAccessibilitySettings() {
        SystemSettingsLink.open(.accessibility)
    }

    // Self-heal launch-at-login across ad-hoc REBUILDS only. An ad-hoc rebuild changes the app's
    // code signature, orphaning the prior Background Task Management registration so it silently
    // stops launching at boot. Re-register only when the app binary actually changed since we last
    // registered -- so a user who turned the login item off in System Settings (no rebuild) is left
    // alone, instead of us re-adding it on every launch. (Moot once signed with a stable Team ID.)
    private func healLoginItem() {
        // A dev run (PERCH_DATA_DIR set) must never (re-)register the login item -- that would point the
        // user's real launch-at-login at a throwaway branch build.
        guard PerchPaths.overrideDir == nil else { return }
        // The copied wantsLoginItem intent and the new binary stamp make this register ShakeBoard's entry.
        // The old com.dadequate.perch login item belongs to another bundle and cannot be removed from here;
        // it becomes stale when the old app is deleted.
        let d = defaults
        // Seed intent for users who enabled it before this self-heal existed.
        if d.object(forKey: "wantsLoginItem") == nil {
            d.set(SMAppService.mainApp.status == .enabled, forKey: "wantsLoginItem")
        }
        guard d.bool(forKey: "wantsLoginItem") else { return }
        let stamp = currentBuildStamp()
        guard stamp != d.string(forKey: "loginItemBuildStamp") else { return }
        do {
            try SMAppService.mainApp.register()
            d.set(stamp, forKey: "loginItemBuildStamp")
        } catch {
            NSLog("ShakeBoard: login-item self-heal failed: \(error)")
            loginItemError = "couldn't re-register after an update (\(error.localizedDescription))"
        }
    }
    // Include the bundle identity as well as the executable mtime. A copied Perch preference can contain the
    // same timestamp, but must still re-register because ShakeBoard is a different SMAppService identity.
    private func currentBuildStamp() -> String {
        guard let exe = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
              let mod = attrs[.modificationDate] as? Date else { return "unknown" }
        return "\(PerchID.appBundleID):\(mod.timeIntervalSince1970)"
    }
}

// MARK: - Multi-file drag-out source (AppKit -- SwiftUI .onDrag can't vend multiple files at once)

struct DragOutHandle: NSViewRepresentable {
    var urls: () -> [URL]
    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ v: DragSourceView, context: Context) { v.urls = urls }
}
final class DragSourceView: NSView, NSDraggingSource {
    var urls: () -> [URL] = { [] }
    override func mouseDown(with event: NSEvent) {}   // consume so mouseDragged is delivered
    override func mouseDragged(with event: NSEvent) {
        let files = urls()
        guard !files.isEmpty else { return }
        let items: [NSDraggingItem] = files.map { url in
            let it = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            it.setDraggingFrame(NSRect(x: 0, y: 0, width: 40, height: 40), contents: icon)
            return it
        }
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
