//
//  ClipPaste.swift
//  ShakeBoard -- pasting a card into the app you were in, plus small shared views (app icons, image thumbs).
//
//  ShakeBoard writes the item to the pasteboard (tagged, through ClipboardWriter), the strip closes and hands
//  the keyboard back, ShakeBoard re-checks the target is still frontmost, then posts Cmd-V to that process. If
//  ShakeBoard can't post events (no Accessibility), the item stays on the clipboard and the strip says so
//  instead of pretending it pasted. (The v1 top history drop-down that lived here is retired: the bottom
//  strip shows history now.)
//

import SwiftUI
import AppKit
import Carbon   // kVK_ key codes
import ImageIO

// MARK: - Paste (injectable event posting)

protocol EventPoster {
    func canPost() -> Bool
    func postPaste(to pid: pid_t)
}

struct SystemEventPoster: EventPoster {
    func canPost() -> Bool { CGPreflightPostEventAccess() }
    func postPaste(to pid: pid_t) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)   // physical V; non-QWERTY layouts are a known limit (see STATUS)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.postToPid(pid); up.postToPid(pid)
    }
}

enum PasteOutcome: Equatable { case pasted, copiedOnly, noPermission, targetChanged, payloadMissing, clipboardBusy }

@MainActor
struct ClipPaster {
    let store: ClipStore
    let poster: EventPoster
    var frontmostPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    // Put the clip on the pasteboard (tagged), then -- unless copyOnly -- paste into `target`.
    // `plain`: text only (no RTF/HTML), for Shift-Return.
    func paste(_ clip: Clip, into target: pid_t?, copyOnly: Bool, plain: Bool = false) -> PasteOutcome {
        guard let items = store.payload(for: clip) else { return .payloadMissing }
        let out = plain ? (Self.plainOnly(items) ?? items) : items
        return pasteItems(out, into: target, copyOnly: copyOnly) { store.markUsed(clip.id) }
    }

    // `onWritten` runs only once the clipboard really holds the items.
    func pasteItems(_ items: [[RawRep]], into target: pid_t?, copyOnly: Bool,
                    onWritten: () -> Void = { }) -> PasteOutcome {
        // Refused = an external copy is still settling and wasn't recorded yet. The clipboard does NOT hold
        // this item, so never mark it used and never post Cmd-V (that would paste the wrong content).
        guard ClipboardWriter.write(items) != nil else { return .clipboardBusy }
        onWritten()
        if copyOnly { return .copiedOnly }
        guard poster.canPost() else { return .noPermission }
        guard let target, frontmostPID() == target else { return .targetChanged }
        poster.postPaste(to: target)
        return .pasted
    }

    // Plain-text version of a text/link payload: one item per original item, plain text only (a link's
    // URL becomes its text). nil when there's no text to keep (images, files) -- callers paste as-is.
    nonisolated static func plainOnly(_ items: [[RawRep]]) -> [[RawRep]]? {
        let out: [[RawRep]] = items.compactMap { reps in
            if let t = reps.first(where: { $0.type == ClipTypes.plainText }) { return [t] }
            if let u = reps.first(where: { $0.type == ClipTypes.url }) { return [RawRep(type: ClipTypes.plainText, data: u.data)] }
            return nil
        }
        return out.isEmpty ? nil : out
    }
}

@MainActor
enum ClipThumbCache {
    private static var cache: [String: NSImage] = [:]
    // Bumped by removeAll(): a decode that was already running when the cache was purged must not put its
    // image back afterwards.
    private static var generation = 0
    // Decoded clipboard images must not outlive their clips (Clear History, eviction, delete).
    static func removeAll() { cache.removeAll(); generation += 1 }
    static func load(_ url: URL?, edge: CGFloat) async -> NSImage? {
        guard let url else { return nil }
        let px = Int(edge * (NSScreen.main?.backingScaleFactor ?? 2))   // card-sized, at the screen's scale
        let key = "\(px):\(url.path)"
        if let hit = cache[key] { return hit }
        let gen = generation
        let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: px,
                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
        guard gen == generation else { return nil }      // purged while decoding: drop it
        if let img { if cache.count > 80 { cache.removeAll() }; cache[key] = img }
        return img
    }
}

struct AppIcon: View {
    let bundleID: String?
    var body: some View {
        if let img = Self.icon(bundleID) {
            Image(nsImage: img).resizable()
        } else {
            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.3))
        }
    }
    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor static func icon(_ id: String?) -> NSImage? {
        guard let id else { return nil }
        if let hit = cache[id] { return hit }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache[id] = img
        return img
    }
}

