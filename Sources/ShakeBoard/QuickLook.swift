//
//  QuickLook.swift
//  ShakeBoard -- Space = Quick Look for the strip (files and clip cards) and the paste-stack bar.
//
//  Why not QLPreviewPanel: probed on macOS 27.3 from an .accessory app (2026-11-11). The shared panel
//  does NOT activate the app or change the frontmost app -- but it is a normal-level (0), activating-style
//  panel that never becomes key in an inactive app, so its own Space/arrow/Esc handling can't work and the
//  next click in another app buries it. Instead ShakeBoard hosts a QLPreviewView in its OWN panel:
//  nonactivating, never key (canBecomeKey false), floating level. Keys are handled by the ShakeBoard panel the
//  user is already in (strip / stack bar), which drives the preview. Trade-off: no native QL
//  toolbar (Open With / Share / full screen) -- the header shows the name and "n of m".
//
//  Temp files (clip previews) live in <TMPDIR>/ShakeBoardPreview-<pid>-<uuid>/ -- never in Shelf/ or Clips/ --
//  are deleted when the preview closes, and leftovers from a dead process are swept at launch.
//

import AppKit
import SwiftUI
import Quartz

// MARK: - Giving the keyboard back

// Drop key status so typing goes back to the app the user is in. resignKey() is enough for a nonactivating
// panel: probed 2026-11-12 (macOS 27.3, .accessory app) -- after makeKey the panel is key and NSApp.isActive
// reads true while the frontmost app never changes; after resignKey() the panel is not key, NSApp.keyWindow
// is nil, NSApp.isActive is false, the panel stays visible and didResignKey fires. The order-out/order-in
// fallback only runs if a panel somehow stays key.
@MainActor
func relinquishKey(_ window: NSWindow) {
    guard window.isKeyWindow else { return }
    window.resignKey()
    if window.isKeyWindow { window.orderOut(nil); window.orderFrontRegardless() }
}

// A panel that took the keyboard because the user clicked it gets it only for a short lease: if no key it
// handles arrives within `idle` seconds (and no preview is open), the keyboard goes back automatically, so a
// click that isn't followed by Space never leaves typing swallowed while the pointer rests on the panel.
@MainActor
final class KeyLease {
    private weak var window: NSWindow?
    let idle: TimeInterval
    var isHeld: () -> Bool = { false }      // e.g. a preview from this panel is open
    private var work: DispatchWorkItem?
    private var observer: Any?

    init(window: NSWindow, idle: TimeInterval = 4) {
        self.window = window
        self.idle = idle
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                          object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.touch() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    // Call whenever the panel handles a key; restarts the lease.
    func touch() {
        work?.cancel()
        scheduleExpiry()
    }
    private func scheduleExpiry() {
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isKeyWindow else { return }
                self.work = nil
                if self.isHeld() { self.scheduleExpiry() } else { relinquishKey(window) }
            }
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + idle, execute: w)
    }
    func release() {
        work?.cancel(); work = nil
        if let window { relinquishKey(window) }
    }
}

// MARK: - Temp files for clip previews

final class PreviewTempDir: @unchecked Sendable {   // immutable url; FileManager calls are thread-safe
    static let prefix = "ShakeBoardPreview-"
    let url: URL
    private let fm = FileManager.default

    // `root` is injectable for tests; production uses the per-user temp dir. Refuses to live inside ShakeBoard's
    // data dir (Shelf/ and Clips/ are owned data; previews are throwaway).
    init?(root: URL = FileManager.default.temporaryDirectory, dataDir: URL = PerchPaths.base) {
        let dir = root.appendingPathComponent("\(Self.prefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        let data = dataDir.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard !(dir.resolvingSymlinksInPath().standardizedFileURL.path + "/").hasPrefix(data) else { return nil }
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        url = dir
    }

    // A free path for `name` inside the dir (nothing written).
    func reserve(name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        var dest = url.appendingPathComponent(safe)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
            dest = url.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
        }
        return dest
    }

    func write(_ data: Data, name: String) -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        var dest = url.appendingPathComponent(safe)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
            dest = url.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"); n += 1
        }
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return nil }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        return dest
    }

    func remove() { try? fm.removeItem(at: url) }

    // Launch sweep: delete preview dirs whose owning process is gone (never a live ShakeBoard's, e.g. a dev run).
    static func sweep(root: URL = FileManager.default.temporaryDirectory, isAlive: (pid_t) -> Bool = { kill($0, 0) == 0 }) {
        let fm = FileManager.default
        for e in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where e.lastPathComponent.hasPrefix(prefix) {
            let rest = e.lastPathComponent.dropFirst(prefix.count)
            let pid = rest.split(separator: "-").first.flatMap { pid_t($0) }
            if let pid, pid != getpid(), isAlive(pid) { continue }
            try? fm.removeItem(at: e)
        }
    }
}

// MARK: - Clip -> previewable files

// What to show for a clip, decided on the main actor WITHOUT disk IO; materialize() does the IO off main.
struct PreviewSource: Equatable {
    enum Kind: Equatable {
        case sidecar(URL)          // an existing Clips/ sidecar, exposed under `name` (hard link, not a copy)
        case fileURLRep(URL)       // a sidecar holding a file URL; preview that file in place if it exists
    }
    let kind: Kind
    let name: String
}

enum ClipPreviewResolver {
    // Images: their PNG sidecars; text: the richest of RTF / HTML / plain text; files: the files themselves.
    @MainActor
    static func plan(for clip: Clip, store: ClipStore) -> [PreviewSource] {
        let dir = store.payloadDir(clip.id)
        switch clip.kind {
        case .image:
            return clip.reps.filter { $0.type == ClipTypes.png }.enumerated().map { i, r in
                PreviewSource(kind: .sidecar(dir.appendingPathComponent(r.file)),
                              name: i == 0 ? "Image.png" : "Image \(i + 1).png")
            }
        case .files:
            return clip.reps.filter { $0.type == ClipTypes.fileURL }.map {
                PreviewSource(kind: .fileURLRep(dir.appendingPathComponent($0.file)), name: "")
            }
        case .text, .url:
            let title = String(clip.preview.prefix(40)).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ":", with: "-")
            let base = title.isEmpty ? "Clip" : title
            for (type, ext) in [(ClipTypes.rtf, "rtf"), (ClipTypes.html, "html"), (ClipTypes.plainText, "txt"), (ClipTypes.url, "txt")] {
                if let r = clip.reps.first(where: { $0.item == 0 && $0.type == type }) {
                    return [PreviewSource(kind: .sidecar(dir.appendingPathComponent(r.file)), name: "\(base).\(ext)")]
                }
            }
            return []
        }
    }

    // Disk IO; call OFF the main actor. A hard link gives QL the right extension without copying the data
    // (same inode, same 0600 perms); copy only if linking fails (e.g. another volume).
    static func materialize(_ plan: [PreviewSource], into temp: PreviewTempDir) -> [URL] {
        let fm = FileManager.default
        return plan.compactMap { src in
            switch src.kind {
            case .sidecar(let sidecar):
                guard let dest = temp.reserve(name: src.name) else { return nil }
                if (try? fm.linkItem(at: sidecar, to: dest)) != nil { return dest }
                if (try? fm.copyItem(at: sidecar, to: dest)) != nil {
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                    return dest
                }
                return nil
            case .fileURLRep(let sidecar):
                guard let d = try? Data(contentsOf: sidecar), let s = String(data: d, encoding: .utf8),
                      let u = URL(string: s), u.isFileURL, fm.fileExists(atPath: u.path) else { return nil }
                return u
            }
        }
    }

    // Convenience for tests / synchronous callers.
    @MainActor
    static func urls(for clip: Clip, store: ClipStore, temp: PreviewTempDir) -> [URL] {
        materialize(plan(for: clip, store: store), into: temp)
    }
}

// MARK: - Shelf target resolution (pure)

enum ShelfPreviewTargets {
    // What Space previews on the shelf: every selected, present item (in shelf order) when more than one is
    // selected; otherwise the hovered item, else the single selected one. Missing items are skipped.
    // Returns the item ids and the index to start on (the hovered item if it is part of the list).
    static func resolve(items: [ShelfItem], selected: Set<UUID>, hovered: UUID?) -> (ids: [UUID], start: Int) {
        let present = items.filter { !$0.missing }
        let sel = present.filter { selected.contains($0.id) }
        if sel.count > 1 {
            let start = hovered.flatMap { h in sel.firstIndex { $0.id == h } } ?? 0
            return (sel.map(\.id), start)
        }
        if let h = hovered, present.contains(where: { $0.id == h }) { return ([h], 0) }
        if let s = sel.first { return ([s.id], 0) }
        return ([], 0)
    }

    // Left/Right on the shelf moves the (single) selection to the neighbouring present item.
    static func step(items: [ShelfItem], from current: UUID?, by delta: Int) -> UUID? {
        let present = items.filter { !$0.missing }
        guard !present.isEmpty else { return nil }
        guard let current, let i = present.firstIndex(where: { $0.id == current }) else {
            return delta >= 0 ? present.first?.id : present.last?.id
        }
        return present[min(max(i + delta, 0), present.count - 1)].id
    }
}

// MARK: - Preview session (pure state)

struct PreviewSession: Equatable {
    var urls: [URL]
    var index: Int
    var current: URL? { urls.indices.contains(index) ? urls[index] : nil }
    mutating func move(_ delta: Int) { index = min(max(index + delta, 0), max(urls.count - 1, 0)) }
}

// MARK: - Presenter

@MainActor
protocol PreviewPresenter: AnyObject {
    var isShowing: Bool { get }
    func show(_ session: PreviewSession)
    func update(_ session: PreviewSession)
    func close()
}

// .shelf = the bottom strip (file chips and clip cards alike); .stack = the paste-stack bar.
enum PreviewOwner: Equatable { case shelf, stack }

// Owns the session + the temp dir; the panels call open / move / retarget / close. Temp files die with the
// session. `owner` says which ShakeBoard panel is driving it (that panel keeps the keyboard).
@MainActor
final class QuickLookController {
    let presenter: PreviewPresenter
    private(set) var session: PreviewSession?
    private(set) var owner: PreviewOwner?
    // True while the session shows clip payloads (hard links to Clips/ sidecars), which Clear History and
    // quit must close first. Shelf files preview in place and aren't clip data.
    private(set) var isClipSession = false
    private var temp: PreviewTempDir?
    var onClose: () -> Void = { }
    private let makeTemp: () -> PreviewTempDir?
    private let materialize: ([PreviewSource], PreviewTempDir) -> [URL]

    init(presenter: PreviewPresenter, makeTemp: @escaping () -> PreviewTempDir? = { PreviewTempDir() },
         materialize: @escaping ([PreviewSource], PreviewTempDir) -> [URL] = ClipPreviewResolver.materialize) {
        self.presenter = presenter
        self.makeTemp = makeTemp
        self.materialize = materialize
    }

    var isShowing: Bool { session != nil }
    func isShowing(for o: PreviewOwner) -> Bool { session != nil && owner == o }
    var isPending: Bool { session == nil && temp != nil && owner != nil }
    func isPending(for o: PreviewOwner) -> Bool { isPending && owner == o }
    // Showing OR still materializing (a clip preview is planned on main and lands a moment later). Key
    // handling must treat a pending preview as open, or a cursor move could let the old one land.
    func isActive(for o: PreviewOwner) -> Bool { isShowing(for: o) || isPending(for: o) }

    // `build` gets a fresh temp dir and returns the files to show (writing clip previews into it).
    func open(owner o: PreviewOwner, start: Int = 0, _ build: (PreviewTempDir?) -> [URL]) {
        close(replacingWith: o)
        request += 1
        owner = o
        let t = makeTemp()
        let urls = build(t)
        guard !urls.isEmpty else { t?.remove(); owner = nil; return }
        temp = t
        let s = PreviewSession(urls: urls, index: min(max(start, 0), urls.count - 1))
        session = s
        presenter.show(s)
    }

    func move(_ delta: Int) {
        guard var s = session else { return }
        s.move(delta)
        session = s
        presenter.update(s)
    }

    // Replace what's shown (selection moved in the source panel) without closing the window.
    func retarget(_ build: (PreviewTempDir?) -> [URL]) {
        guard session != nil else { return }
        temp?.remove()
        let t = makeTemp()
        let urls = build(t)
        guard !urls.isEmpty else { t?.remove(); close(); return }
        temp = t
        isClipSession = false
        let s = PreviewSession(urls: urls, index: 0)
        session = s
        presenter.update(s)
    }

    func close() { close(replacingWith: nil) }

    // Opening a new preview for the SAME owner (the strip moving from a file to a clip card) is a switch,
    // not an ending: the owner isn't told its preview closed, so it keeps the keyboard.
    private func close(replacingWith next: PreviewOwner?) {
        guard session != nil || temp != nil else { return }
        request += 1                                  // drop any in-flight materialization
        presenter.close()
        temp?.remove(); temp = nil
        session = nil
        isClipSession = false
        let was = owner
        owner = nil
        onClose()
        if let was, was != next { onOwnerClosed?(was) }
    }
    var onOwnerClosed: ((PreviewOwner) -> Void)?

    // History / stack clips. Planned on main (no IO), materialized off main, shown back on main -- unless
    // something newer (another open, a retarget, a close) happened meanwhile.
    private var request = 0
    func openClips(_ clips: [Clip], start: Int = 0, store: ClipStore, owner o: PreviewOwner) {
        close(replacingWith: o)
        let plan = clips.flatMap { ClipPreviewResolver.plan(for: $0, store: store) }
        guard !plan.isEmpty, let t = makeTemp() else { return }
        request += 1
        let id = request
        owner = o
        temp = t
        isClipSession = true
        let materialize = self.materialize
        DispatchQueue.global(qos: .userInitiated).async {
            let urls = materialize(plan, t)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.request == id, self.temp === t else { t.remove(); return }
                    guard !urls.isEmpty else { self.close(); return }
                    let s = PreviewSession(urls: urls, index: min(max(start, 0), urls.count - 1))
                    self.session = s
                    self.presenter.show(s)
                }
            }
        }
    }
    func retargetClip(_ clip: Clip, store: ClipStore) {
        guard session != nil else { return }
        let plan = ClipPreviewResolver.plan(for: clip, store: store)
        guard !plan.isEmpty, let t = makeTemp() else { close(); return }
        request += 1
        let id = request
        let old = temp
        temp = t
        isClipSession = true
        let materialize = self.materialize
        DispatchQueue.global(qos: .userInitiated).async {
            old?.remove()
            let urls = materialize(plan, t)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.request == id, self.temp === t, self.session != nil else { t.remove(); return }
                    guard !urls.isEmpty else { self.close(); return }
                    let s = PreviewSession(urls: urls, index: 0)
                    self.session = s
                    self.presenter.update(s)
                }
            }
        }
    }

    // Clear History / quit: close any clip preview (strip card or stack) and delete its temp files now.
    func closeClipPreviews() {
        if isClipSession || owner == .stack { close() }
    }

    deinit { temp?.remove() }   // best effort; normal paths remove it in close()
}

// MARK: - The real presenter: QLPreviewView in a nonactivating, never-key floating panel

final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }    // keys stay with the ShakeBoard panel driving the preview
    override var canBecomeMain: Bool { false }
}

@MainActor
final class QuickLookPanelPresenter: PreviewPresenter {
    private var panel: PreviewPanel?
    private var qlView: QLPreviewView?
    private let header = NSTextField(labelWithString: "")
    var onCloseClicked: () -> Void = { }

    var isShowing: Bool { panel?.isVisible ?? false }

    func show(_ s: PreviewSession) {
        let p = panel ?? makePanel()
        position(p)
        update(s)
        p.orderFrontRegardless()                 // never makeKey / activate
    }

    func update(_ s: PreviewSession) {
        guard let url = s.current else { return }
        qlView?.previewItem = url as NSURL
        header.stringValue = s.urls.count > 1 ? "\(url.lastPathComponent)    \(s.index + 1) of \(s.urls.count)"
                                              : url.lastPathComponent
    }

    func close() {
        qlView?.previewItem = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> PreviewPanel {
        let size = NSSize(width: 720, height: 540)
        let p = PreviewPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.nonactivatingPanel, .borderless, .resizable], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let root = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        root.material = .hudWindow; root.blendingMode = .behindWindow; root.state = .active
        root.wantsLayer = true; root.layer?.cornerRadius = 18; root.layer?.masksToBounds = true
        root.autoresizingMask = [.width, .height]

        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingMiddle
        header.frame = NSRect(x: 16, y: size.height - 30, width: size.width - 70, height: 18)
        header.autoresizingMask = [.width, .minYMargin]
        root.addSubview(header)

        let close = NSButton(title: "", image: NSImage(systemSymbolName: "xmark.circle.fill",
                                                       accessibilityDescription: "Close preview")!,
                             target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.frame = NSRect(x: size.width - 36, y: size.height - 34, width: 24, height: 24)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        root.addSubview(close)

        let ql = QLPreviewView(frame: NSRect(x: 8, y: 8, width: size.width - 16, height: size.height - 44),
                               style: .normal)!
        ql.autoresizingMask = [.width, .height]
        ql.shouldCloseWithWindow = false
        root.addSubview(ql)
        qlView = ql

        p.contentView = root
        panel = p
        return p
    }

    @objc private func closeClicked() { onCloseClicked() }

    // Centered on the screen under the mouse, clear of the menu bar.
    private func position(_ p: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let w = min(p.frame.width, vf.width - 40), h = min(p.frame.height, vf.height - 140)
        p.setFrame(NSRect(x: (vf.midX - w / 2).rounded(), y: (vf.midY - h / 2 + 40).rounded(), width: w, height: h),
                   display: true)
    }
}
