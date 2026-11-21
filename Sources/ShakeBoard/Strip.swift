//
//  Strip.swift
//  ShakeBoard v2 -- the unified bottom strip: shelf files and everything you copied, as cards, in one place.
//
//  StripState    view model: query / filter / cursor + the text heads read from Clips/ for the cards.
//  StripController  keys, paste, preview, drag-out export. Testable without a window (hooks for the panel).
//  StripView     the SwiftUI strip: left rail (Settings gear with warning dot, Stack) + top row (search, filters, hints) +
//                cards in three sections: Pinned, Shelf, Recent.
//
//  The panel itself (ShelfPanel, positioning, show/hide, focus rules) stays in AppDelegate: the strip never
//  activates ShakeBoard. Cmd-Space "summons" it -- shown AND key, search focused, so typing filters and Return
//  pastes into the app you were in; a shake/copy only "reveals" it (no key, auto-hides).
//

import SwiftUI
import AppKit
import Combine
import Carbon
import UniformTypeIdentifiers

// MARK: - Clip heads (the start of the real text, newlines kept)

struct ClipHead: Equatable {
    let text: String          // first `limit` characters of the plain text
    let lines: Int
    let chars: Int
    let linkTitle: String?
    let kind: CardKind
    // `text` is the clip's whole plain/URL text (not cut at `limit`, not the rich-only preview).
    var complete = false

    static let limit = 3000

    // Disk IO -- call off main.
    static func read(_ clip: Clip, dir: URL) -> ClipHead {
        func data(_ type: String, max: Int) -> Data? {
            guard let r = clip.reps.first(where: { $0.item == 0 && $0.type == type }),
                  let h = FileHandle(forReadingAtPath: dir.appendingPathComponent(r.file).path) else { return nil }
            defer { try? h.close() }
            return try? h.read(upToCount: max)
        }
        // A blank plain-text rep beside real rich text doesn't count: the card shows the rich preview then.
        func usable(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        var full = usable(data(ClipTypes.plainText, max: ClipLimits.maxTextBytes).flatMap { String(data: $0, encoding: .utf8) })
        if full == nil, clip.kind == .url { full = usable(data(ClipTypes.url, max: 64 * 1024).flatMap { String(data: $0, encoding: .utf8) }) }
        let text = full ?? clip.preview
        let head = String(text.prefix(limit))
        var title: String?
        if clip.kind == .url || ClipNormalizer.isSingleWebURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            title = data(ClipTypes.html, max: 256 * 1024).flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(LinkInfo.title(fromHTML:))
        }
        let lines = text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return ClipHead(text: head, lines: lines, chars: text.count, linkTitle: title,
                        kind: ClipClassifier.kind(of: clip, head: head),
                        complete: full != nil && text.count <= limit)
    }
}

// MARK: - State

// An open Edit (Cmd-E): the draft lives only in memory until saved as a NEW clip; the source is untouched.
struct EditSession: Equatable {
    let source: UUID
    let kind: CardKind
    let original: String
    var text: String
}

@MainActor
final class StripState: ObservableObject {
    let shelf: ShelfModel
    let store: ClipStore
    let pins: ClipPins
    let ocr: OCRService?

    // A new search or filter drops the picks: Send to Stack only ever sends cards you can see.
    @Published var query = "" { didSet { if query != oldValue { picks.clear(); onQueryChanged?() } } }
    @Published var filter: StripFilter = .all {
        didSet {
            guard filter != oldValue else { return }
            if filter != .all { board = nil }
            picks.clear(); onQueryChanged?()
        }
    }
    // A board is a view mode beside the kind filters. Its cards keep the board's persisted order.
    @Published var board: UUID? {
        didSet {
            guard board != oldValue else { return }
            if board != nil, filter != .all { filter = .all }
            picks.clear(); onQueryChanged?()
        }
    }
    // The keyboard cursor (Return / Space / 1-9 act on it). A card ID, not an index, so a new copy landing
    // at the front never moves it onto a different card.
    @Published var cursor: CardID? { didSet { if cursor != oldValue { onCursorChanged?() } } }
    @Published var hovered: CardID?
    // Copies picked with Command-click / Shift-click, in click order (the order Send to Stack uses).
    @Published var picks = ClipPicks()
    @Published var notice: String?
    @Published var summoned = false
    // Something in Settings needs attention (a failure or actionable notice, not a chosen pause): orange gear dot.
    @Published var gearAlert = false
    @Published var focusSearch = 0                   // bump to put the caret in the search field
    @Published var scrollHome = 0                    // bump on every open: scroll the newest copy to the left edge
    var homing = false                               // a home scroll is pending: the cursor's own scroll stands down
    @Published var editing: EditSession?             // Cmd-E draft (survives the strip hiding; Esc drops it)
    @Published var editSaving = false                // a save is in flight: repeats are ignored
    @Published var renamingBoardID: UUID?
    @Published var boardNameDraft = ""
    @Published private(set) var heads: [UUID: ClipHead] = [:]
    var hideImageClips: () -> Bool = { false }
    var onQueryChanged: (() -> Void)?
    var onCursorChanged: (() -> Void)?

    private var bags: [AnyCancellable] = []
    private var loading: Set<UUID> = []
    // Every reader in flight, so Clear History can cancel all of them (not just the latest).
    private var headTasks: [UUID: Task<Void, Never>] = [:]
    private var knownClips: Set<UUID> = []
    private var previewKinds: [UUID: CardKind] = [:]

    init(shelf: ShelfModel, store: ClipStore, pins: ClipPins, ocr: OCRService? = nil) {
        self.shelf = shelf
        self.store = store
        self.pins = pins
        self.ocr = ocr
        for pub in [shelf.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                    store.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                    pins.objectWillChange.map { _ in () }.eraseToAnyPublisher()] {
            bags.append(pub.sink { [weak self] in
                self?.objectWillChange.send()
                // objectWillChange fires BEFORE the change; reconcile once it has landed.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.reconcile() } }
            })
        }
        if let ocr { bags.append(ocr.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }) }
    }

    var sections: StripSections {
        if let board, let selected = pins.store.board(board) {
            return StripSections.buildBoard(clips: store.clips, ids: selected.clipIDs, query: query,
                                            kind: { [unowned self] in self.kind(of: $0) },
                                            text: { [unowned self] in self.heads[$0.id]?.text },
                                            ocr: { [unowned self] in self.ocr?.searchText(for: $0) })
        }
        return StripSections.build(clips: store.clips, pins: pins.ids, files: shelf.items, query: query, filter: filter,
                                   hideImageClips: hideImageClips(), kind: { [unowned self] in self.kind(of: $0) },
                                   text: { [unowned self] in self.heads[$0.id]?.text },
                                   ocr: { [unowned self] in self.ocr?.searchText(for: $0) },
                                   fileOCR: { [unowned self] in self.ocr?.searchText(for: $0) },
                                   isImageFile: Self.isImageFile)
    }

    func kind(of clip: Clip) -> CardKind {
        if let h = heads[clip.id] { return h.kind }
        if let k = previewKinds[clip.id] { return k }
        let k = ClipClassifier.kind(of: clip, head: nil)
        previewKinds[clip.id] = k
        return k
    }
    func clip(_ id: UUID) -> Clip? { store.clip(id) }
    func file(_ id: UUID) -> ShelfItem? { shelf.items.first { $0.id == id } }

    nonisolated static func isImageFile(_ item: ShelfItem) -> Bool {
        UTType(filenameExtension: item.url.pathExtension.lowercased())?.conforms(to: .image) ?? false
    }

    // Default cursor: the newest copy (what Paste-style strips select), else the first card.
    func resetCursor() {
        let s = sections
        cursor = board != nil ? s.order.first : (s.recent.first.map { .clip($0.id) } ?? s.order.first)
    }
    /// Every open (Command-Space, shake, a copied image, relaunch): select the newest copy and scroll it to the
    /// strip's left edge. A crowded shelf can hold ~90 files before Recent -- opening at the start
    /// buried the newest copy screens away.
    func goHome() {
        homing = true
        resetCursor()
        scrollHome += 1
        // Safety: if the card list isn't on screen to finish the home scroll, don't mute cursor scrolling forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.homing = false }
    }
    /// The card an open scrolls to: the newest copy, else the first card.
    var homeTarget: CardID? {
        let s = sections
        return board != nil ? s.order.first : (s.recent.first.map { .clip($0.id) } ?? s.order.first)
    }
    func selectFilter(_ selected: StripFilter) {
        board = nil
        filter = selected
        resetCursor()
    }
    func toggleBoard(_ id: UUID) {
        board = board == id ? nil : id
        if board != nil { filter = .all }
        resetCursor()
    }
    func reconcile() {
        if let board, pins.store.board(board) == nil { self.board = nil }
        // Forget text that's no longer in history (cleared, evicted, deleted): it may be sensitive.
        let live = Set(store.clips.map(\.id))
        if heads.keys.contains(where: { !live.contains($0) }) { heads = heads.filter { live.contains($0.key) } }
        // A clip went away: drop decoded thumbnails too (they reload from disk for the clips that remain).
        if !knownClips.isSubset(of: live) { ClipThumbCache.removeAll() }
        knownClips = live
        previewKinds = previewKinds.filter { live.contains($0.key) }
        // Picks follow what's on screen: a copy that left history OR scrolled past Recent's cap drops out.
        if !picks.isEmpty {
            let shown = Set(sections.order.compactMap { c -> UUID? in if case .clip(let i) = c { return i }; return nil })
            if picks.ids.contains(where: { !shown.contains($0) }) { picks.retain(shown) }
        }
        if let c = cursor, !sections.order.contains(c) {
            if summoned || cursor != nil { resetCursor() }
        }
        loadMissingHeads()
    }
    func step(_ delta: Int) {
        let order = sections.order
        guard !order.isEmpty else { cursor = nil; return }
        guard let c = cursor, let i = order.firstIndex(of: c) else { cursor = order.first; return }
        cursor = order[min(max(i + delta, 0), order.count - 1)]
    }
    // A click on a copy's card. Plain: select just it. Command: add / remove it from the picks (click order).
    // Shift: pick the run from the last click to here, in the strip's order.
    func clickClip(_ id: UUID, command: Bool, shift: Bool) {
        let seed: UUID? = { if case .clip(let c)? = cursor { return c }; return nil }()
        if command {
            picks.toggle(id, seed: seed)
        } else if shift {
            let visible = sections.order.compactMap { c -> UUID? in if case .clip(let i) = c { return i }; return nil }
            picks.extend(to: id, visible: visible, seed: seed)
        } else {
            picks.clear()
        }
        cursor = .clip(id)
        shelf.selectOnly(nil)
    }
    // What a card's menu acts on: the whole pick list when the card is in it, else just that card (Finder rule).
    func targets(for id: UUID) -> [UUID] {
        picks.count > 1 && picks.contains(id) ? picks.ids : [id]
    }

    func card(number n: Int) -> CardID? {
        let order = sections.order
        return order.indices.contains(n - 1) ? order[n - 1] : nil
    }

    // Read the start of every text clip's real text (newlines kept) off main, for card bodies, code
    // detection and search. Bounded: ClipHead.limit characters each.
    func loadMissingHeads() {
        let todo = store.clips.filter { ($0.kind == .text || $0.kind == .url) && heads[$0.id] == nil && !loading.contains($0.id) }
        guard !todo.isEmpty else { return }
        for c in todo { loading.insert(c.id) }
        let dirs = Dictionary(todo.map { ($0.id, store.payloadDir($0.id)) }, uniquingKeysWith: { a, _ in a })
        let gen = store.generation
        let taskID = UUID()
        headTasks[taskID] = Task.detached(priority: .userInitiated) {
            var out: [UUID: ClipHead] = [:]
            for c in todo {
                if Task.isCancelled { break }                           // Clear History: stop reading
                if let d = dirs[c.id] { out[c.id] = ClipHead.read(c, dir: d) }
            }
            let result = Task.isCancelled ? [:] : out
            await MainActor.run {
                self.headTasks[taskID] = nil
                for c in todo { self.loading.remove(c.id) }
                guard !Task.isCancelled, gen == self.store.generation else { return }   // history cleared meanwhile
                let live = Set(self.store.clips.map(\.id))
                for (id, h) in result where live.contains(id) { self.heads[id] = h }
            }
        }
    }
    func forgetHeads() {
        for t in headTasks.values { t.cancel() }
        headTasks = [:]
        heads = [:]; previewKinds = [:]; loading = []
        editing = nil                                    // Clear History: a draft can hold copied text too
        ClipThumbCache.removeAll()
    }

    // Test seam: load synchronously.
    func loadHeadsNow() {
        for c in store.clips where c.kind == .text || c.kind == .url {
            heads[c.id] = ClipHead.read(c, dir: store.payloadDir(c.id))
        }
    }
}

// MARK: - Drag-out export (text as a file, images as PNGs)

// Files handed to a drag live in <TMPDIR>/ShakeBoardDragOut-<pid>/<uuid>/, owner-only. Cleared at launch, on
// Clear History (they can hold copied text) and at quit.
enum StripExport {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardDragOut-\(getpid())", isDirectory: true)
    }
    static func clear() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("ShakeBoardDragOut-") {
            // Only ours and dead processes' -- never another live ShakeBoard's drag in flight.
            let pid = Int32(name.dropFirst("ShakeBoardDragOut-".count)) ?? 0
            if pid == getpid() || (pid > 0 && kill(pid, 0) != 0 && errno == ESRCH) || pid == 0 {
                try? fm.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
    }

    static func fileExtension(for kind: CardKind, rich: Bool) -> String {
        switch kind {
        case .code(let lang):
            return ["Swift": "swift", "Python": "py", "JSON": "json", "Shell": "sh", "JavaScript": "js",
                    "TypeScript": "ts", "HTML": "html", "CSS": "css", "SQL": "sql", "Go": "go", "Rust": "rs"][lang] ?? "txt"
        case .richText: return rich ? "rtf" : "txt"
        default: return "txt"
        }
    }
    static func baseName(_ preview: String) -> String {
        let words = preview.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(6).joined(separator: " ")
        let t = String(words.prefix(40)).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Clip" : t
    }

    // Disk IO on the caller's thread (drag start; payloads are capped at a few MB).
    @MainActor
    static func files(for clip: Clip, kind: CardKind, store: ClipStore) -> [URL] {
        let fm = FileManager.default
        let src = store.payloadDir(clip.id)
        switch clip.kind {
        case .files:
            return clip.reps.filter { $0.type == ClipTypes.fileURL }.compactMap { r in
                guard let d = try? Data(contentsOf: src.appendingPathComponent(r.file)),
                      let s = String(data: d, encoding: .utf8), let u = URL(string: s), u.isFileURL,
                      fm.fileExists(atPath: u.path) else { return nil }
                return u
            }
        case .image, .text, .url:
            let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])) != nil else { return [] }
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            var out: [URL] = []
            if clip.kind == .image {
                for (i, r) in clip.reps.filter({ $0.type == ClipTypes.png }).enumerated() {
                    let dest = dir.appendingPathComponent(i == 0 ? "Image.png" : "Image \(i + 1).png")
                    if (try? fm.copyItem(at: src.appendingPathComponent(r.file), to: dest)) != nil {
                        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                        out.append(dest)
                    }
                }
                return out
            }
            // One file for the whole copy. A multi-item text copy is joined (plain text, one item per
            // line) rather than silently cut to its first item; RTF is kept only for a single item.
            let rtf = clip.reps.first { $0.item == 0 && $0.type == ClipTypes.rtf }
            let rich = kind == .richText && rtf != nil && clip.itemCount == 1
            var data = Data()
            if rich, let rtf, let d = try? Data(contentsOf: src.appendingPathComponent(rtf.file)) {
                data = d
            } else {
                var parts: [Data] = []
                for i in 0..<clip.itemCount {
                    let r = clip.reps.first { $0.item == i && $0.type == ClipTypes.plainText }
                        ?? clip.reps.first { $0.item == i && $0.type == ClipTypes.url }
                    if let r, let d = try? Data(contentsOf: src.appendingPathComponent(r.file)) { parts.append(d) }
                }
                data = parts.joined(separator: Data("\n".utf8)).reduce(into: Data()) { $0.append($1) }
            }
            guard !data.isEmpty else { return [] }
            let dest = dir.appendingPathComponent("\(baseName(clip.preview)).\(fileExtension(for: kind, rich: rich))")
            guard (try? data.write(to: dest, options: .atomic)) != nil else { return [] }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            return [dest]
        }
    }
}

// MARK: - Click modifiers

// Command / Shift as they were when the mouse went DOWN (what Finder uses). SwiftUI's tap fires on mouse-up, and
// reading the live modifier state there turns a Command-click whose key came up a beat early into a plain click.
// A local monitor (ShakeBoard's own windows only, never global) records each mouse-down's flags.
@MainActor
enum StripClickFlags {
    private static var monitor: Any?
    private static var last: (flags: NSEvent.ModifierFlags, at: Date)?
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
            MainActor.assumeIsolated { last = (e.modifierFlags.intersection(.deviceIndependentFlagsMask), Date()) }
            return e
        }
    }
    static func current(now: Date = Date()) -> NSEvent.ModifierFlags {
        if let l = last, now.timeIntervalSince(l.at) < 2 { return l.flags }
        return NSEvent.modifierFlags
    }
}

// MARK: - Controller

@MainActor
final class StripController {
    let state: StripState
    var quickLook: QuickLookController?
    var poster: EventPoster = SystemEventPoster()
    // The app the paste goes to: whatever is frontmost (ShakeBoard never activates, so that's still the app you
    // were in), else the one recorded when the strip was summoned.
    var frontmostPID: () -> pid_t? = {
        let f = NSWorkspace.shared.frontmostApplication
        return f?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : f?.processIdentifier
    }
    var target: pid_t?
    var pasteDelay: TimeInterval = 0.05

    // Panel hooks (AppDelegate). dismiss = hide the strip and give the keyboard back.
    var dismiss: () -> Void = { }
    var reopen: (String) -> Void = { _ in }
    var giveKeyBack: () -> Void = { }
    var openFile: (ShelfItem) -> Void = { NSWorkspace.shared.open($0.url) }
    // Edit needs the keyboard until you save or cancel: keep the strip up and key (summoned).
    var holdOpen: () -> Void = { }
    // Cmd-T: pop the Transform menu for the selected card.
    var showMenu: (NSMenu) -> Void = { _ in }
    // No menu-bar icon (v2 PR 5): Command-comma and Command-Q work while the strip has the keyboard. The key
    // monitor only sees events aimed at the strip's own panel, so neither is ever global.
    var openSettings: () -> Void = { }
    var quit: () -> Void = { }
    var now: () -> Date = Date.init
    // Paste stacks (Add to Stack, Split into Stack, drops onto a stack).
    weak var stacks: PasteStack?

    init(state: StripState) {
        self.state = state
        StripClickFlags.install()
        state.onCursorChanged = { [weak self] in self?.cursorMoved() }
        state.onQueryChanged = { [weak self] in
            // Typing a search means Space types now; a preview of a card that may vanish goes away.
            guard let self, !self.state.query.isEmpty, self.previewShowing else { return }
            self.quickLook?.close()
        }
    }

    var previewShowing: Bool { quickLook?.isActive(for: .shelf) ?? false }

    // MARK: preview

    func togglePreview() {
        if previewShowing { quickLook?.close(); return }
        if state.cursor == nil { state.cursor = state.hovered ?? state.sections.order.first }
        guard let c = state.cursor else { return }
        preview(c)
    }

    private func preview(_ id: CardID) {
        guard let ql = quickLook else { return }
        switch id {
        case .clip(let cid):
            guard let clip = state.clip(cid) else { return }
            // Several copies picked, this one among them: preview them as a list in pick order, starting here.
            let picked = state.picks.count > 1 && state.picks.contains(cid) ? state.picks.ids.compactMap { state.clip($0) } : []
            if picked.count > 1 {
                ql.openClips(picked, start: picked.firstIndex { $0.id == cid } ?? 0, store: state.store, owner: .shelf)
                return
            }
            if ql.isShowing(for: .shelf), ql.isClipSession { ql.retargetClip(clip, store: state.store) }
            // Not landed yet (or a file preview): start over -- this cancels the pending request.
            else { ql.openClips([clip], store: state.store, owner: .shelf) }
        case .file(let fid):
            let shelf = state.shelf
            // A multi-selection that includes this file previews as a list starting here.
            let sel = shelf.items.filter { shelf.selected.contains($0.id) && !$0.missing }
            let list = (sel.count > 1 && sel.contains { $0.id == fid }) ? sel : shelf.items.filter { $0.id == fid && !$0.missing }
            guard !list.isEmpty else { return }
            let urls = list.map(\.url)
            let start = list.firstIndex { $0.id == fid } ?? 0
            ql.open(owner: .shelf, start: start) { _ in urls }
        }
    }

    // The preview follows the cursor -- under the same rule as Space: only while the search is empty.
    private func cursorMoved() {
        guard previewShowing, state.query.isEmpty else { return }
        if let c = state.cursor { preview(c) } else { quickLook?.close() }
    }

    // MARK: keys

    // Returns true if consumed. Keys the strip doesn't own fall through to the search field.
    func handleKey(_ e: NSEvent) -> Bool {
        let code = Int(e.keyCode)
        let cmd = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)
        let option = e.modifierFlags.contains(.option)
        if state.editing != nil { return handleEditKey(code: code, cmd: cmd, shift: shift) }
        if state.renamingBoardID != nil {
            if code == kVK_Escape { state.renamingBoardID = nil; return true }
            return false
        }
        // Renaming a stack: every key goes to its text field (Return commits there); Esc cancels.
        if stacks?.renamingID != nil {
            if code == kVK_Escape { stacks?.renamingID = nil; return true }
            return false
        }
        switch code {
        case kVK_Escape:
            if previewShowing { quickLook?.close() }
            else if !state.query.isEmpty { state.query = "" }
            else if state.board != nil { state.board = nil; state.resetCursor() }
            else if state.filter != .all { state.filter = .all }
            else if !state.picks.isEmpty { state.picks.clear() }
            else if !state.summoned && (state.cursor != nil || !state.shelf.selected.isEmpty) {
                state.cursor = nil; state.shelf.selectOnly(nil)
            }
            else if state.summoned { dismiss() }
            else { giveKeyBack() }
            return true
        case kVK_Space where state.query.isEmpty && !cmd:
            togglePreview(); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if state.cursor == nil { state.resetCursor() }
            if let c = state.cursor { activate(c, plain: shift, copyOnly: false) }
            return true
        case kVK_LeftArrow, kVK_RightArrow:
            let delta = code == kVK_RightArrow ? 1 : -1
            if previewShowing, !(quickLook?.isClipSession ?? true), (quickLook?.session?.urls.count ?? 0) > 1 {
                quickLook?.move(delta); return true
            }
            if state.cursor == nil { state.resetCursor() } else { state.step(delta) }
            state.picks.clear()
            if case .file(let id)? = state.cursor { state.shelf.selectOnly(id) } else { state.shelf.selectOnly(nil) }
            return true
        case kVK_ANSI_C where cmd && state.query.isEmpty:
            if let c = state.cursor { activate(c, plain: false, copyOnly: true) }
            return true
        case kVK_ANSI_P where cmd:
            if case .clip(let id)? = state.cursor { togglePin(id) }
            return true
        case kVK_ANSI_F where cmd:
            state.focusSearch += 1; return true
        case kVK_ANSI_E where cmd:
            if case .clip(let id)? = state.cursor { beginEdit(id) }
            return true
        case kVK_ANSI_T where cmd:
            if case .clip(let id)? = state.cursor { showMenu(transformMenu(for: id)) }
            return true
        case kVK_Delete where cmd, kVK_ForwardDelete where cmd:
            if let c = state.cursor { remove(c) }
            return true
        case kVK_ANSI_Comma where cmd:
            openSettings(); return true
        case kVK_ANSI_Q where cmd:
            quit(); return true
        default:
            break
        }
        // Option-1...9 adds the selected copy to that board. Command-Option keeps Command-digit paste behavior.
        if option, !cmd, let ch = e.charactersIgnoringModifiers, ch.count == 1, let n = Int(ch), (1...9).contains(n) {
            if case .clip(let id)? = state.cursor,
               let board = PinboardShortcut.boardID(for: n, in: state.pins.store.boards) {
                addToPinboard([id], board: board)
            }
            return true
        }
        // 1-9 pastes that card: bare digits while the search is empty, Command-digit always.
        if let ch = e.charactersIgnoringModifiers, ch.count == 1, let n = Int(ch), (1...9).contains(n),
           (state.query.isEmpty && !shift) || cmd {
            if let c = state.card(number: n) { activate(c, plain: false, copyOnly: false) }
            return true
        }
        return false
    }

    // While editing, the text view gets every key except Esc (cancel) and Cmd-Return / Cmd-S (save). The
    // standard editing commands are sent straight to the text view: ShakeBoard is never the active app, so the
    // main menu's Edit items can't be relied on to route them.
    private func handleEditKey(code: Int, cmd: Bool, shift: Bool) -> Bool {
        switch code {
        case kVK_Escape:
            cancelEdit(); return true
        case kVK_Return where cmd, kVK_ANSI_KeypadEnter where cmd, kVK_ANSI_S where cmd:
            saveEdit(); return true
        case kVK_ANSI_Comma where cmd:
            openSettings(); return true   // the draft survives the strip hiding (Cmd-Q is left out: typed work)
        default: break
        }
        guard cmd else { return false }
        let action: String?
        switch code {
        case kVK_ANSI_A: action = "selectAll:"
        case kVK_ANSI_C: action = "copy:"
        case kVK_ANSI_V: action = "paste:"
        case kVK_ANSI_X: action = "cut:"
        case kVK_ANSI_Z: action = shift ? "redo:" : "undo:"
        default: action = nil
        }
        guard let action else { return false }
        NSApp.sendAction(Selector(action), to: nil, from: nil)
        return true
    }

    // MARK: edit + transforms (always a NEW clip; the original copy is never changed)

    // The full text of a one-item text card plus what the transforms need. Disk IO -- off main for runs;
    // `head` (main-actor data) is read by the caller and passed in.
    nonisolated static func loadInput(_ clip: Clip, dir: URL, kind: CardKind, linkTitle: String?) -> TransformInput? {
        guard clip.kind == .text || clip.kind == .url else { return nil }
        func read(_ type: String) -> String? {
            guard let r = clip.reps.first(where: { $0.item == 0 && $0.type == type }),
                  let d = try? Data(contentsOf: dir.appendingPathComponent(r.file)) else { return nil }
            return String(data: d, encoding: .utf8)
        }
        func usable(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        let url = usable(read(ClipTypes.url))
        // RTF- or HTML-only copies (or a blank plain-text rep beside real rich text): the readable text.
        // RTF keeps its exact whitespace; HTML goes through the same tag-stripping as the card preview.
        func richText() -> String? {
            if let r = clip.reps.first(where: { $0.item == 0 && $0.type == ClipTypes.rtf }),
               let d = try? Data(contentsOf: dir.appendingPathComponent(r.file)),
               let a = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                               documentAttributes: nil),
               let t = usable(a.string) { return t }
            if let r = clip.reps.first(where: { $0.item == 0 && $0.type == ClipTypes.html }),
               let d = try? Data(contentsOf: dir.appendingPathComponent(r.file)),
               let html = String(data: d, encoding: .utf8) {
                return usable(HTMLText.plain(html))
            }
            return nil
        }
        guard let text = usable(read(ClipTypes.plainText)) ?? url ?? richText() else { return nil }
        let rich = clip.reps.contains { $0.type == ClipTypes.rtf || $0.type == ClipTypes.html }
        return TransformInput(text: text, kind: kind, hasRich: rich, linkTitle: linkTitle,
                              itemCount: clip.itemCount, url: url)
    }

    // What the menu shows, from memory only (the text head, or the preview until the head loads): the
    // context menu is built during SwiftUI body passes, so this must never touch the disk.
    func menuInput(for clip: Clip) -> TransformInput? {
        guard clip.kind == .text || clip.kind == .url else { return nil }
        let head = state.heads[clip.id]
        // Rich-only copies (or a blank plain-text rep) only have their collapsed 300-char preview in memory.
        let complete = head?.complete ?? false
        let rich = clip.reps.contains { $0.type == ClipTypes.rtf || $0.type == ClipTypes.html }
        let hasURLRep = clip.reps.contains { $0.type == ClipTypes.url }
        return TransformInput(text: head?.text ?? clip.preview, kind: state.kind(of: clip), hasRich: rich,
                              linkTitle: head?.linkTitle, itemCount: clip.itemCount,
                              // The URL rep isn't in memory; a URL-only copy's head IS the URL. Otherwise
                              // offer the link transforms optimistically and let the run decide.
                              url: hasURLRep && clip.kind == .url ? (head?.text ?? clip.preview) : nil,
                              complete: complete)
    }

    func canEdit(_ id: UUID) -> Bool {
        guard let clip = state.clip(id), clip.kind == .text || clip.kind == .url, clip.itemCount == 1 else { return false }
        return true
    }
    func transforms(for id: UUID) -> [ClipTransform] {
        guard let clip = state.clip(id), let input = menuInput(for: clip) else { return [] }
        var list = ClipTransform.available(for: input)
        // A rich hyperlink ("OpenAI" + its URL): the link transforms work on the URL rep, read at run time.
        if clip.kind == .url, input.kind == .link, ClipTransform.webURL(input.text) == nil {
            for t in [ClipTransform.stripTracking, .markdownLink] where !list.contains(t) { list.append(t) }
            list.sort { ClipTransform.allCases.firstIndex(of: $0)! < ClipTransform.allCases.firstIndex(of: $1)! }
        }
        return list
    }

    func beginEdit(_ id: UUID) {
        guard let clip = state.clip(id) else { return }
        guard canEdit(id), let input = Self.loadInput(clip, dir: state.store.payloadDir(clip.id), kind: state.kind(of: clip),
                                                     linkTitle: state.heads[clip.id]?.linkTitle),
              ClipTransform.isEditable(input) else {
            state.notice = clip.itemCount > 1 ? "Copies with several items can't be edited yet." : "Only text can be edited."
            return
        }
        guard input.text.utf8.count <= Self.maxEditBytes else {
            state.notice = "Too long to edit here -- over 256 KB. Drag it out and edit the file."; return
        }
        if previewShowing { quickLook?.close() }
        state.cursor = .clip(id)
        state.editing = EditSession(source: id, kind: input.kind, original: input.text, text: input.text)
        state.notice = nil
        holdOpen()
        state.focusSearch += 1          // routed to the editor while a draft is open
    }

    func cancelEdit() {
        state.editing = nil
        state.focusSearch += 1
    }

    func saveEdit() {
        guard let e = state.editing, !state.editSaving else { return }
        if e.text == e.original { state.notice = "No changes."; cancelEdit(); return }
        guard !e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.notice = "Nothing to save -- the text is empty."; return
        }
        state.editSaving = true
        saveDerived(e.text, from: e.source, what: "edited") { [weak self] ok in
            guard let self else { return }
            self.state.editSaving = false
            guard ok, self.state.editing == e else { return }
            self.state.editing = nil
            self.state.focusSearch += 1
        }
    }

    static let maxEditBytes = 256 * 1024

    // Reads the clip's full text and transforms it off main (a 1 MB JSON reformat must not stall the strip),
    // then saves the result as a new clip.
    func runTransform(_ t: ClipTransform, on id: UUID) {
        guard let clip = state.clip(id) else { state.notice = "That item's data is gone."; return }
        let dir = state.store.payloadDir(clip.id)
        let kind = state.kind(of: clip)
        let title = state.heads[clip.id]?.linkTitle
        let gen = state.store.generation
        state.notice = "\(t.title)\u{2026}"
        Task.detached(priority: .userInitiated) {
            let input = Self.loadInput(clip, dir: dir, kind: kind, linkTitle: title)
            let out = input.flatMap { t.apply($0) }
            let tooBig = out == nil && t == .jsonPretty && input.map {
                ClipTransform.isJSONContainer($0.text)
                    && JSONFormatter.pretty($0.text, maxBytes: ClipTransform.maxOutputBytes) == nil
            } == true
            await MainActor.run { [weak self] in
                guard let self else { return }
                // History cleared, or the source deleted, while it ran: save nothing (it would bring deleted
                // text back). Several transforms may be in flight; each stands alone.
                guard gen == self.state.store.generation else { return }
                guard self.state.clip(id) != nil else { self.state.notice = "The original was deleted -- nothing saved."; return }
                guard input != nil else { self.state.notice = "That item's data is gone."; return }
                guard let out else {
                    self.state.notice = tooBig ? "\(t.title): the result would be over 1 MB." : "\(t.title): nothing to change."
                    return
                }
                self.saveDerived(out, from: id, what: t.pastTense, requireSource: true)
            }
        }
    }

    // Save text as a new plain-text clip at the front of Recent, select it, and say so.
    func saveDerived(_ text: String, from source: UUID?, what: String, requireSource: Bool = false,
                     completion: @escaping (Bool) -> Void = { _ in }) {
        let data = Data(text.utf8)
        guard data.count <= ClipLimits.maxTextBytes else {
            state.notice = "Too long to save (over 1 MB)."; completion(false); return
        }
        let items = [[RawRep(type: ClipTypes.plainText, data: data)]]
        let snap = RawSnapshot(changeCount: -1, allTypes: [ClipTypes.plainText], items: items)
        let cap = CapturedClipboard(snapshot: snap, sourceBundleID: PerchID.appBundleID, sourceAppName: "ShakeBoard",
                                    capturedAt: now())
        // An edit / transform of a copy hidden from AI tools stays hidden (decided now, while the source exists).
        let inheritHidden = source.map { AIVisibility.isHidden($0, store: state.store) } ?? false
        state.store.ingest(cap, derivedFrom: source, requireSource: requireSource) { [weak self] clip, isNew in
            guard let self else { return }
            if let clip, isNew, inheritHidden { AIHiddenClips.shared.hide(clip.id) }
            guard let clip else {
                let gone = requireSource && source.map { self.state.clip($0) == nil } == true
                self.state.notice = gone ? "The original was deleted -- nothing saved."
                                         : "Couldn't save the new copy -- check disk space."
                completion(false); return
            }
            if !self.state.query.isEmpty { self.state.query = "" }
            if self.state.board != nil { self.state.board = nil }
            if self.state.filter != .all { self.state.filter = .all }
            self.state.cursor = .clip(clip.id)
            self.state.notice = isNew ? "New copy (\(what)) -- the original is unchanged."
                                      : "Already in history -- moved it to the front."
            completion(true)
        }
    }

    // The Transform menu for Cmd-T (the card's context menu builds the same list in SwiftUI).
    func transformMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu(title: "Transform")
        menu.autoenablesItems = false
        let offered = Set(transforms(for: id))
        for t in ClipTransform.allCases {
            let item = NSMenuItem(title: t.title, action: #selector(TransformMenuTarget.run(_:)), keyEquivalent: "")
            item.target = TransformMenuTarget.shared
            item.representedObject = TransformMenuTarget.Pick(controller: self, transform: t, clip: id)
            item.isEnabled = offered.contains(t)
            menu.addItem(item)
        }
        if offered.isEmpty {
            menu.insertItem(NSMenuItem(title: "Nothing to transform here", action: nil, keyEquivalent: ""), at: 0)
            menu.items[0].isEnabled = false
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    // MARK: actions

    // MARK: stacks

    // MARK: pinboards

    func nextBoardName() -> String {
        let used = Set(state.pins.store.boards.map(\.name))
        var n = state.pins.store.boards.count + 1
        while used.contains("Board \(n)") { n += 1 }
        return "Board \(n)"
    }

    @discardableResult
    func createPinboard(name: String? = nil, clips: [UUID] = [], select: Bool = false, rename: Bool = false) -> UUID? {
        let store = state.pins.store
        let color = BoardColor.allCases[store.boards.count % BoardColor.allCases.count]
        guard let id = store.create(name: name ?? nextBoardName(), color: color, clipIDs: clips) else {
            state.notice = "Couldn't save the pinboard -- check disk space."
            return nil
        }
        if select { state.toggleBoard(id) }
        if rename {
            state.boardNameDraft = store.board(id)?.name ?? ""
            state.renamingBoardID = id
            holdOpen()
        }
        if clips.count > 1 { state.picks.clear() }
        return id
    }

    func beginBoardRename(_ id: UUID) {
        guard let board = state.pins.store.board(id) else { return }
        state.boardNameDraft = board.name
        state.renamingBoardID = id
        holdOpen()
    }

    func commitBoardRename() {
        guard let id = state.renamingBoardID else { return }
        let draft = state.boardNameDraft
        state.renamingBoardID = nil
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if !state.pins.store.rename(id, to: draft) { state.notice = "Couldn't save the pinboard -- check disk space." }
    }

    func addToPinboard(_ clipIDs: [UUID], board id: UUID) {
        guard state.pins.store.add(clipIDs, to: id), let board = state.pins.store.board(id) else {
            state.notice = "Couldn't save the pinboard -- check disk space."
            return
        }
        if clipIDs.count > 1 { state.picks.clear() }
        state.notice = clipIDs.count > 1 ? "Added \(clipIDs.count) to \(board.name)" : "Added to \(board.name)"
    }

    func togglePinboard(_ clipIDs: [UUID], board id: UUID) {
        guard state.pins.store.toggle(clipIDs, in: id) else {
            state.notice = "Couldn't save the pinboard -- check disk space."
            return
        }
        if clipIDs.count > 1 { state.picks.clear() }
    }

    func deletePinboard(_ id: UUID) {
        guard state.pins.store.delete(id) else { return }
        if state.board == id { state.board = nil; state.resetCursor() }
    }

    // Arming from the strip: put the strip away (the bar under the menu bar takes over) and give the keyboard back,
    // so the very next Cmd-V reaches the app you're pasting into instead of ShakeBoard.
    func armFromStrip(_ id: UUID, restoring archived: Bool = false) {
        guard let stacks else { return }
        if archived { stacks.restore(id, arm: true) } else { stacks.arm(id) }
        guard stacks.readyID == id else { return }
        if state.summoned { dismiss() } else { giveKeyBack() }
    }

    // Add a card's copy to a stack (nil = a new stack, which is selected and shown).
    func addToStack(_ clipID: UUID, stack sid: UUID?) {
        guard let stacks else { return }
        let id = sid ?? stacks.newStack()
        stacks.laneOpen = true
        stacks.selectedID = id
        if stacks.add(clipID, to: id), let st = stacks.stack(id) {
            state.notice = "Added to \(st.name) (\(st.slots.count))"
        } else if let n = stacks.notice {
            state.notice = n
        }
    }

    // Send copies to a stack in the given order (the pick order; one card = Add to Stack). nil = a new stack, which
    // is selected and shown. Undo is offered in the stack lane.
    func sendToStack(_ clipIDs: [UUID], stack sid: UUID?) {
        guard let stacks else { return }
        if clipIDs.count == 1 { addToStack(clipIDs[0], stack: sid); return }
        let before = stacks.notice
        let r = stacks.send(clipIDs, to: sid)
        let why = stacks.notice != before ? stacks.notice : nil      // set by the stack when a copy didn't fit
        guard let r, let st = stacks.stack(r.stack) else {
            state.notice = why ?? "Those copies are gone."
            return
        }
        stacks.laneOpen = true
        stacks.selectedID = r.stack
        state.picks.clear()
        state.notice = r.added < clipIDs.count
            ? "Sent \(r.added) of \(clipIDs.count) to \(st.name) -- \(why ?? "it's full")"
            : "Sent \(r.added) to \(st.name) (\(st.slots.count))"
    }

    // Split a text card into pieces (lines / cells / list items) and make a NEW stack of them, in order, ready to
    // arm. Each piece is saved as its own derived clip (the original is unchanged) and inherits "hidden from AI".
    func splitIntoStack(_ clipID: UUID, mode: SplitMode?) {
        guard let stacks, let clip = state.clip(clipID), clip.kind == .text,
              let text = state.store.fullText(for: clip) else { state.notice = "That item's data is gone."; return }
        let pieces: [String]
        if let mode { pieces = StackSplitter.split(text, mode) }
        else if let auto = StackSplitter.autoSplit(text) { pieces = auto.pieces }
        else { pieces = [] }
        guard pieces.count >= 2 else { state.notice = "Nothing to split there."; return }
        let capped = Array(pieces.prefix(StackSplitter.maxPieces))
        let inheritHidden = AIVisibility.isHidden(clipID, store: state.store)
        let gen = state.store.generation
        var ids: [UUID] = []
        var created: [UUID] = []          // pieces that were NEW clips: removed again if the split doesn't finish
        func rollBack(_ message: String) {
            for id in created { state.store.remove(id) }
            state.notice = message
        }
        func next(_ i: Int) {
            guard gen == state.store.generation else { rollBack("History was cleared -- split cancelled."); return }
            guard i < capped.count else {
                let name = "Split: " + String(clip.preview.prefix(24))
                stacks.newStack(name: name, clips: ids)
                let more = pieces.count > capped.count ? " (first \(capped.count) of \(pieces.count))" : ""
                state.notice = "New stack with \(ids.count) pieces\(more) -- click Ready to paste"
                return
            }
            ingestText(capped[i], from: clipID) { c, isNew in
                guard gen == self.state.store.generation else { rollBack("History was cleared -- split cancelled."); return }
                guard let c else {
                    rollBack(self.state.clip(clipID) == nil ? "The original was deleted -- split cancelled."
                                                            : "Couldn't save the pieces -- check disk space.")
                    return
                }
                if isNew { created.append(c.id) }
                if inheritHidden { AIHiddenClips.shared.hide(c.id) }
                ids.append(c.id)
                next(i + 1)
            }
        }
        next(0)
    }

    // A derived plain-text clip, quietly (no cursor / filter change).
    private func ingestText(_ text: String, from source: UUID, completion: @escaping (Clip?, Bool) -> Void) {
        let data = Data(text.utf8)
        guard data.count <= ClipLimits.maxTextBytes else { completion(nil, false); return }
        let snap = RawSnapshot(changeCount: -1, allTypes: [ClipTypes.plainText],
                               items: [[RawRep(type: ClipTypes.plainText, data: data)]])
        let cap = CapturedClipboard(snapshot: snap, sourceBundleID: PerchID.appBundleID, sourceAppName: "ShakeBoard",
                                    capturedAt: now())
        state.store.ingest(cap, derivedFrom: source, requireSource: true) { clip, isNew in completion(clip, isNew) }
    }

    func togglePin(_ id: UUID) {
        if !state.pins.toggle(id) { state.notice = "Couldn't save the pin -- check disk space." }
    }

    func remove(_ id: CardID) {
        switch id {
        case .clip(let cid):
            guard state.pins.store.removeFromAll(cid) else {
                state.notice = "Couldn't update pinboards -- the copy wasn't deleted."
                return
            }
            state.store.remove(cid)
        case .file(let fid):
            if let item = state.file(fid) { state.shelf.remove(item) }
        }
    }

    // Pasteboard items for a card. Files paste as file URLs (Finder, Mail, chat apps take them).
    func items(for id: CardID, plain: Bool) -> (items: [[RawRep]], clip: Clip?)? {
        switch id {
        case .clip(let cid):
            guard let clip = state.clip(cid), let items = state.store.payload(for: clip) else { return nil }
            return (plain ? (ClipPaster.plainOnly(items) ?? items) : items, clip)
        case .file(let fid):
            guard let item = state.file(fid), let url = state.shelf.dragURL(for: item) else { return nil }
            return ([[RawRep(type: ClipTypes.fileURL, data: Data(url.absoluteString.utf8)),
                      RawRep(type: ClipTypes.plainText, data: Data(url.path.utf8))]], nil)
        }
    }

    // Return / double-click / 1-9: write the card to the clipboard, hide the strip, then paste into the app
    // you were in. copyOnly (Cmd-C, "Copy"): just the clipboard; the strip stays.
    func activate(_ id: CardID, plain: Bool, copyOnly: Bool) {
        let paster = ClipPaster(store: state.store, poster: poster, frontmostPID: frontmostPID)
        if copyOnly {
            guard let r = items(for: id, plain: plain) else { state.notice = "That item's data is gone."; return }
            let out = paster.pasteItems(r.items, into: nil, copyOnly: true) { if let clip = r.clip { self.state.store.markUsed(clip.id) } }
            state.notice = out == .clipboardBusy ? "Clipboard busy -- try again." : "Copied"
            return
        }
        let target = frontmostPID() ?? self.target
        dismiss()
        // Let the window server process the orderOut / key change before the synthetic Cmd-V lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let outcome: PasteOutcome
                if let r = self.items(for: id, plain: plain) {
                    outcome = paster.pasteItems(r.items, into: target, copyOnly: false) {
                        if let clip = r.clip { self.state.store.markUsed(clip.id) }
                    }
                } else {
                    outcome = .payloadMissing
                }
                switch outcome {
                case .noPermission: self.reopen("Copied -- ShakeBoard needs Accessibility to paste for you. Press \u{2318}V.")
                case .targetChanged: self.reopen("Copied -- press \u{2318}V where you want it.")
                case .payloadMissing: self.reopen("That item's data is gone.")
                case .clipboardBusy: self.reopen("Clipboard busy -- try again.")
                case .pasted, .copiedOnly: break
                }
            }
        }
    }

    // Drag a clip card out: text as a .txt/.md/.swift/... file (plus the text itself for text fields),
    // images as PNGs, links as the URL, copied files as themselves.
    func dragProvider(for clip: Clip) -> NSItemProvider {
        let p = exportProvider(for: clip)
        StackDrag.register(clip.id, on: p)   // so it can be dropped onto a stack in the lane
        return p
    }
    func internalDragProvider(for clip: Clip) -> NSItemProvider {
        let provider = NSItemProvider()
        StackDrag.register(clip.id, on: provider)
        return provider
    }
    private func exportProvider(for clip: Clip) -> NSItemProvider {
        let kind = state.kind(of: clip)
        let text = state.heads[clip.id]?.text ?? clip.preview
        // A single link drags as the URL itself; several links in one copy export as one text file (below).
        if kind == .link, clip.itemCount == 1,
           let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), u.host != nil {
            let p = NSItemProvider(object: u as NSURL)
            p.registerObject(u.absoluteString as NSString, visibility: .all)
            return p
        }
        guard let url = StripExport.files(for: clip, kind: kind, store: state.store).first else { return NSItemProvider() }
        let p = NSItemProvider(object: url as NSURL)
        p.suggestedName = url.lastPathComponent
        // The text itself too, for text fields -- every item, the same as the exported file.
        if clip.kind == .text || clip.kind == .url {
            let all = clip.itemCount == 1 ? state.store.fullText(for: clip)
                : (url.pathExtension == "rtf" ? nil : try? String(contentsOf: url, encoding: .utf8))
            if let all { p.registerObject(all as NSString, visibility: .all) }
        }
        return p
    }

    // Text (or a web link) dropped on the strip becomes a pinned clip -- dropping is deliberate parking.
    func ingestDropped(_ items: [[RawRep]], completion: @escaping (Bool) -> Void = { _ in }) {
        let snap = RawSnapshot(changeCount: -1, allTypes: Set(items.flatMap { $0.map(\.type) }), items: items)
        let cap = CapturedClipboard(snapshot: snap, sourceBundleID: nil, sourceAppName: "Dropped", capturedAt: Date())
        state.store.ingest(cap) { [weak self] clip, _ in
            guard let self, let clip else { completion(false); return }
            if !self.state.pins.pin(clip.id) { self.state.notice = "Couldn't save the pin -- check disk space." }
            self.state.cursor = .clip(clip.id)
            completion(true)
        }
    }
}

// NSMenu items need an @objc target.
@MainActor
final class TransformMenuTarget: NSObject {
    static let shared = TransformMenuTarget()
    final class Pick: NSObject {
        weak var controller: StripController?
        let transform: ClipTransform
        let clip: UUID
        init(controller: StripController, transform: ClipTransform, clip: UUID) {
            self.controller = controller; self.transform = transform; self.clip = clip
        }
    }
    @objc func run(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? Pick else { return }
        p.controller?.runTransform(p.transform, on: p.clip)
    }
}

// MARK: - View

struct StripView: View {
    @ObservedObject var state: StripState
    @ObservedObject var stack: PasteStack
    let controller: StripController
    var onGear: () -> Void = { }
    var onStack: () -> Void = { }
    @FocusState private var searchFocused: Bool
    @FocusState private var editorFocused: Bool
    @FocusState private var boardRenameFocused: Bool
    @State private var dropTargetBoard: UUID?
    @State private var boardEndDropTarget = false
    @State private var confirmClearShelf = false
    @EnvironmentObject private var themes: ThemeStore
    private var accent: Color { themes.current.isSystem ? .accentColor : themes.current.accent.color }
    private var collecting: Color { themes.current.isSystem ? .red : themes.current.collecting.color }
    private var text: Color { themes.current.isSystem ? .primary : themes.current.text.color }
    private var secondaryText: Color { themes.current.isSystem ? .secondary : themes.current.secondaryText }
    private var onAccent: Color {
        themes.current.isSystem ? Color(nsColor: .selectedControlTextColor) : themes.current.onAccent.color
    }
    private var onCollecting: Color {
        themes.current.isSystem ? Color(nsColor: .selectedControlTextColor) : themes.current.onCollecting.color
    }
    private var dropAccent: Color { themes.current.isSystem ? .blue : themes.current.accent.color }

    static let height: CGFloat = 174
    static let cardSize = CGSize(width: 156, height: 108)

    var body: some View {
        let sections = state.sections
        let order = sections.order
        HStack(alignment: .top, spacing: 8) {
            rail
            VStack(alignment: .leading, spacing: 6) {
                topRow
                HStack(alignment: .top, spacing: 14) {
                    // Paste stack on: its queue leads the strip (mockup frame 3) -- fixed, so "next" stays in
                    // view, and kept while editing (the top stack bar is hidden whenever the strip is up).
                    if stack.showsLane { StackLane(stack: stack, controller: controller) }
                    if state.editing != nil {
                        EditorInset(state: state, controller: controller, focused: $editorFocused)
                    } else if state.filter == .stacks && state.board == nil {
                        StacksGallery(stack: stack, controller: controller)
                    } else if sections.isEmpty {
                        emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        cards(sections, order: order)
                    }
                }
            }
        }
        .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .shakeboardGlass(cornerRadius: GlassMetrics.panelRadius)
        .overlay(RoundedRectangle(cornerRadius: GlassMetrics.panelRadius, style: .continuous)
            .strokeBorder(state.shelf.hovering ? dropAccent : Color.clear, lineWidth: 1.5))
        .foregroundStyle(text)
        .tint(themes.current.isSystem ? nil : accent)
        // One "take the caret" signal: the editor while a draft is open, else the search field.
        .onChange(of: state.focusSearch) { _, _ in
            if state.editing != nil { editorFocused = true } else { searchFocused = true }
        }
        .onAppear { state.loadMissingHeads() }
        .confirmationDialog("Clear the shelf?", isPresented: $confirmClearShelf) {
            Button("Clear Shelf", role: .destructive) { state.shelf.clear() }
        } message: {
            Text("Images ShakeBoard saved from the clipboard are deleted. Files you dragged in stay where they are.")
        }
    }

    // MARK: rail (gear on top, Stack at the bottom)

    private var rail: some View {
        VStack(spacing: 6) {
            Button(action: onGear) {
                Image(systemName: "gearshape").font(.system(size: 13))
                    .frame(width: 28, height: 26).contentShape(Rectangle())
                    .overlay(alignment: .topTrailing) {
                        if state.gearAlert {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
                                .offset(x: -3, y: 3)
                        }
                    }
            }
            .buttonStyle(.plain).foregroundStyle(secondaryText)
            .help(state.gearAlert ? "ShakeBoard settings -- something needs attention" : "ShakeBoard settings")
            .accessibilityLabel(state.gearAlert ? "Settings, needs attention" : "Settings")
            Spacer(minLength: 0)
            Button(action: onStack) {
                VStack(spacing: 1) {
                    Image(systemName: stack.isOn || stack.showsLane ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Stacks").font(.system(size: 7, weight: .semibold))
                }
                .padding(.top, 4)
                .padding(.bottom, 5)
                .frame(width: 30, height: 40)
                .foregroundStyle(onAccent)
                .background(RoundedRectangle(cornerRadius: 9).fill(accent))
                // "On" (lane shown) = a ring just OUTSIDE the button, so it never crosses the label.
                .overlay(RoundedRectangle(cornerRadius: 11.5).stroke(stack.showsLane ? accent : .clear, lineWidth: 1.5).padding(-2.5))
                .shadow(color: accent.opacity(0.45), radius: 5, y: 2)
                .overlay(alignment: .topTrailing) {
                    // Red = collecting (items gathered), blue = ready (items left to paste).
                    let n = stack.isReady ? stack.queue.count : (stack.collectingStack?.slots.count ?? 0)
                    if stack.isOn {
                        Text("\(n)").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(stack.isReady ? accent : onCollecting)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(stack.isReady ? Color.white : collecting)).offset(x: 5, y: -4)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(stack.showsLane ? "Hide the stacks (collecting and pasting carry on)"
                                  : "Paste stacks: collect several copies, then paste them in order with \u{2318}V")
            .accessibilityLabel(stack.showsLane ? "Hide stacks" : "Show stacks")
        }
        .padding(.bottom, 4)
        .frame(width: 40)
    }

    // MARK: top row (search, filters, hints) -- one slim 26 pt row

    private var topRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(secondaryText)
                TextField("Type to search", text: $state.query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($searchFocused)
                    .onChange(of: state.query) { _, _ in state.resetCursor() }
                    .disabled(state.editing != nil)
            }
            .padding(.horizontal, 9).frame(height: 24).frame(maxWidth: 380)
            .shakeboardGlassCapsule()
            ForEach(StripFilter.allCases) { f in
                Button { state.selectFilter(f) } label: {
                    Text(f.rawValue).font(.system(size: 10, weight: state.filter == f && state.board == nil ? .semibold : .regular))
                        .padding(.horizontal, 8).frame(height: 20)
                        .foregroundStyle(state.filter == f && state.board == nil ? accent : secondaryText)
                        .background(Capsule().fill(state.filter == f && state.board == nil ? accent.opacity(0.16) : text.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            Rectangle().fill(text.opacity(0.14)).frame(width: 1, height: 16).padding(.horizontal, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(state.pins.store.boards.enumerated()), id: \.element.id) { i, board in
                        boardChip(board, index: i)
                    }
                    Button {
                        _ = controller.createPinboard(select: true, rename: true)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                            .frame(width: 22, height: 20)
                            .background(Capsule().fill(text.opacity(0.06)))
                    }
                    .buttonStyle(.plain).foregroundStyle(secondaryText)
                    .help("New pinboard")
                }
            }
            .frame(maxWidth: 470)
            Spacer(minLength: 8)
            if let notice = state.notice {
                Label(notice, systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            } else if state.editing != nil {
                hint("\u{2318}\u{21A9} save as new"); hint("esc cancel")
            } else {
                hint("\u{21A9} paste"); hint("\u{21E7}\u{21A9} plain"); hint("space preview"); hint("esc")
            }
        }
        .frame(height: 26)
    }

    private func boardChip(_ board: Pinboard, index: Int) -> some View {
        let selected = state.board == board.id
        let targeted = dropTargetBoard == board.id
        return Group {
            if state.renamingBoardID == board.id {
                HStack(spacing: 5) {
                    Circle().fill(board.color.color).frame(width: 7, height: 7)
                    TextField("Name", text: $state.boardNameDraft)
                        .textFieldStyle(.plain).font(.system(size: 10, weight: .semibold))
                        .frame(width: 110).focused($boardRenameFocused)
                        .onSubmit { controller.commitBoardRename() }
                        .onExitCommand { state.renamingBoardID = nil }
                }
                .padding(.horizontal, 8).frame(height: 20)
                .background(Capsule().fill(text.opacity(0.10)))
                .onAppear { boardRenameFocused = true }
            } else {
                Button { state.toggleBoard(board.id) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(board.color.color).frame(width: 7, height: 7)
                        Text(board.name).font(.system(size: 10, weight: selected ? .semibold : .regular)).lineLimit(1)
                    }
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Capsule().fill(selected ? text.opacity(0.15) : text.opacity(0.055)))
                    .overlay(Capsule().stroke(targeted ? board.color.color : (selected ? text.opacity(0.42) : .clear),
                                              style: StrokeStyle(lineWidth: targeted ? 2 : 1,
                                                                 dash: targeted ? [3, 2] : [])))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rename\u{2026}") { controller.beginBoardRename(board.id) }
                    Menu("Change Color") {
                        ForEach(BoardColor.allCases) { color in
                            Button {
                                if !state.pins.store.setColor(board.id, to: color) {
                                    state.notice = "Couldn't save the pinboard -- check disk space."
                                }
                            } label: {
                                Label(color.title, systemImage: board.color == color ? "checkmark.circle.fill" : "circle.fill")
                            }
                        }
                    }
                    Divider()
                    Button("Move Left") { _ = state.pins.store.moveBoard(board.id, by: -1) }.disabled(index == 0)
                    Button("Move Right") { _ = state.pins.store.moveBoard(board.id, by: 1) }
                        .disabled(index == state.pins.store.boards.count - 1)
                    if !board.isDefaultPinned {
                        Divider()
                        Button("Delete Board", role: .destructive) { controller.deletePinboard(board.id) }
                    }
                }
                .onDrop(of: [StackDrag.type], isTargeted: Binding(
                    get: { dropTargetBoard == board.id },
                    set: { dropTargetBoard = $0 ? board.id : (dropTargetBoard == board.id ? nil : dropTargetBoard) }
                )) { providers in
                    StackDrag.load(providers) { id in controller.addToPinboard([id], board: board.id) }
                }
            }
        }
        .accessibilityLabel("Pinboard \(board.name), \(board.clipIDs.count) copies")
    }
    private func hint(_ s: String) -> some View {
        Text(s).font(.system(size: 9, weight: .medium)).foregroundStyle(secondaryText)
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(text.opacity(0.06)))
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: state.shelf.hovering ? "tray.and.arrow.down.fill" : "tray")
            .font(.system(size: 20)).foregroundStyle(state.shelf.hovering ? dropAccent : secondaryText)
            Text(state.shelf.hovering ? "Release to drop"
                 : (state.board != nil
                    ? (state.query.isEmpty ? "This pinboard is empty" : "No matches in this pinboard")
                    : (state.query.isEmpty && state.filter == .all ? "Copy something, or drag files or text here" : "No matches")))
                .font(.system(size: 12)).foregroundStyle(secondaryText)
        }
    }

    // MARK: cards

    private func cards(_ s: StripSections, order: [CardID]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    if let id = state.board, let board = state.pins.store.board(id), !s.board.isEmpty {
                        section("\(board.name) \u{00B7} \(board.clipIDs.count) \u{00B7} drag to reorder", symbol: "rectangle.3.group") {
                            ForEach(s.board) { clip in clipCard(clip, order: order) }
                            boardEndDropZone(board)
                        }
                    }
                    if !s.pinned.isEmpty {
                        section(state.pins.store.defaultBoard?.name ?? "Pinned", symbol: "pin.fill") {
                            ForEach(s.pinned) { clip in clipCard(clip, order: order) }
                        }
                    }
                    if !s.files.isEmpty {
                        section("Shelf", symbol: "tray.full", accessory: AnyView(shelfTools),
                                clearShelf: { confirmClearShelf = true }) {
                            ForEach(s.files) { item in fileCard(item, order: order) }
                        }
                    }
                    if !s.recent.isEmpty {
                        section("Recent", symbol: "clock") {
                            ForEach(s.recent) { clip in clipCard(clip, order: order) }
                        }
                    }
                }
                .padding(.horizontal, 2).padding(.bottom, 2)
                .smoothWheel(.horizontal)
            }
            // A click on empty strip space clears the selection, like Finder.
            .background(Color.clear.contentShape(Rectangle()).onTapGesture {
                state.cursor = nil; state.shelf.selectOnly(nil); state.picks.clear()
            })
            .onChange(of: state.cursor) { _, c in
                guard !state.homing else { return }   // an open is scrolling home; don't race it
                if let c { withAnimation(Motion.scroll) { proxy.scrollTo(c) } }
            }
            // Every open puts the newest copy (selected; Return pastes it) at the LEFT edge, so the latest thing
            // is the first thing you see; Pinned and Shelf are a scroll to the left. Deferred one turn so the
            // panel and the card list have laid out (scrollTo on an unlaid-out list silently does nothing).
            .onChange(of: state.scrollHome) { _, _ in
                DispatchQueue.main.async {
                    if let target = state.homeTarget { proxy.scrollTo(target, anchor: .leading) }
                    state.homing = false
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, symbol: String, accessory: AnyView? = nil,
                                        clearShelf: (() -> Void)? = nil,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sectionHeader(title, symbol: symbol, accessory: accessory, clearShelf: clearShelf)
            HStack(alignment: .top, spacing: 7) { content() }
        }
    }

    @ViewBuilder private func sectionHeader(_ title: String, symbol: String, accessory: AnyView?,
                                             clearShelf: (() -> Void)?) -> some View {
        let header = HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8))
            Text(title).font(.system(size: 9, weight: .semibold))
            if let accessory { accessory }
        }
        .foregroundStyle(secondaryText).frame(height: 12)
        if let clearShelf {
            header.contextMenu { Button("Clear Shelf...") { clearShelf() } }
        } else {
            header
        }
    }

    // Card drops target a card's position. This narrow trailing target is what makes the final slot reachable.
    private func boardEndDropZone(_ board: Pinboard) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(boardEndDropTarget ? board.color.color.opacity(0.8) : Color.clear)
            .frame(width: 12, height: Self.cardSize.height)
            .contentShape(Rectangle())
            .onDrop(of: [StackDrag.type], isTargeted: $boardEndDropTarget) { providers in
                StackDrag.load(providers) { dragged in
                    if !state.pins.store.moveClip(dragged, to: max(board.clipIDs.count - 1, 0), in: board.id) {
                        state.notice = "Couldn't reorder the pinboard -- check disk space."
                    }
                }
            }
            .help("Drop at the end of this pinboard")
    }

    // Drag everything (or the selection) out from the compact handle beside the Shelf label.
    private var shelfTools: some View {
        let shelf = state.shelf
        let count = shelf.selected.isEmpty ? shelf.items.count : shelf.selected.count
        return HStack(spacing: 3) {
            Image(systemName: "square.and.arrow.up.on.square").font(.system(size: 8))
            Text("\(count)").font(.system(size: 7, weight: .bold))
                .padding(.horizontal, 3).frame(minWidth: 12, minHeight: 10, maxHeight: 10)
                .background(Capsule().fill(dropAccent.opacity(0.16)))
        }
        .fixedSize()
        .foregroundStyle(dropAccent)
        .padding(.leading, 4).padding(.trailing, 3).frame(height: 12)
        .overlay(DragOutHandle(urls: { shelf.dragURLs() }))
        .help(shelf.selected.isEmpty ? "Drag ALL shelf files out (Claude, Finder, terminal...)" : "Drag the selected files out")
    }

    static func isMulti(_ clip: Clip) -> Bool {
        (clip.kind == .files || clip.kind == .image) && clip.itemCount > 1
    }

    private func number(_ id: CardID, _ order: [CardID]) -> Int? {
        guard let i = order.firstIndex(of: id), i < 9 else { return nil }
        return i + 1
    }

    private func clipCard(_ clip: Clip, order: [CardID]) -> some View {
        let id = CardID.clip(clip.id)
        let pinned = state.pins.isPinned(clip.id)
        let memberships = state.pins.store.boards(containing: clip.id)
        return ClipCard(clip: clip, kind: state.kind(of: clip), head: state.heads[clip.id], store: state.store,
                        dragAll: Self.isMulti(clip) ? { [state] in
                            StripExport.files(for: clip, kind: state.kind(of: clip), store: state.store) } : nil,
                        number: number(id, order), selected: state.cursor == id || state.picks.contains(clip.id), pinned: pinned,
                        hovered: state.hovered == id)
            .overlay(alignment: .topTrailing) {
                if let b = stack.badge(for: clip.id) {
                    Text(b.text).font(.system(size: 8, weight: .bold))
                        .foregroundStyle(b.ready ? onAccent : onCollecting)
                        .padding(.horizontal, 5).frame(height: 13)
                        .background(Capsule().fill(b.ready ? accent : collecting)).offset(x: -28, y: 5)   // left of the 1-9 number badge
                        .allowsHitTesting(false)
                        .accessibilityLabel((b.ready ? "Ready to paste, " : "Collected, ") + b.text)
                }
            }
            // Pick order (Command-click): the order Send to Stack uses.
            .overlay(alignment: .topLeading) {
                if state.picks.count > 1, let n = state.picks.position(of: clip.id) {
                    Text("\(n)").font(.system(size: 10, weight: .bold)).monospacedDigit().foregroundStyle(onAccent)
                        .frame(minWidth: 18, minHeight: 18).padding(.horizontal, n > 9 ? 3 : 0)
                        .background(Capsule().fill(accent))
                        .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
                        .offset(x: -2, y: -5)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Picked \(n) of \(state.picks.count)")
                }
            }
            .overlay(alignment: .topTrailing) {
                if !memberships.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(memberships.prefix(3)) { board in
                            Circle().fill(board.color.color).frame(width: 7, height: 7)
                                .overlay(Circle().stroke(Color.white.opacity(0.75), lineWidth: 0.6))
                        }
                        if memberships.count > 3 {
                            Text("+").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 4).frame(height: 13)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .offset(x: -76, y: 3)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if state.ocr?.text(for: clip) != nil { OCRBadge() }
            }
            .id(id)
            .onTapGesture(count: 2) { controller.activate(id, plain: false, copyOnly: false) }
            .onTapGesture {
                let mods = StripClickFlags.current()
                state.clickClip(clip.id, command: mods.contains(.command), shift: mods.contains(.shift))
            }
            .onHover { inside in
                if inside { state.hovered = id } else if state.hovered == id { state.hovered = nil }
            }
            // Several files / images in one copy: SwiftUI's onDrag carries one item, so those drag out
            // through the footer handle (all of them) instead of the card body (just one).
            .draggableIf(true) {
                Self.isMulti(clip) ? controller.internalDragProvider(for: clip) : controller.dragProvider(for: clip)
            }
            .onDrop(of: [StackDrag.type], isTargeted: nil) { providers in
                guard let board = state.board else { return false }
                return StackDrag.load(providers) { dragged in
                    if !state.pins.store.moveClip(dragged, before: clip.id, in: board) {
                        state.notice = "Couldn't reorder the pinboard -- check disk space."
                    }
                }
            }
            .contextMenu {
                Button("Paste") { controller.activate(id, plain: false, copyOnly: false) }
                if clip.kind == .text || clip.kind == .url {
                    Button("Paste as Plain Text") { controller.activate(id, plain: true, copyOnly: false) }
                }
                Button("Copy") { controller.activate(id, plain: false, copyOnly: true) }
                if clip.kind == .image { ocrClipMenu(clip) }
                Button("Quick Look") { state.cursor = id; controller.togglePreview() }
                Divider()
                Button("Edit\u{2026}") { controller.beginEdit(clip.id) }
                    .disabled(!controller.canEdit(clip.id))
                Menu("Transform") {
                    let offered = controller.transforms(for: clip.id)
                    ForEach(ClipTransform.allCases) { t in
                        Button(t.title) { controller.runTransform(t, on: clip.id) }
                            .disabled(!offered.contains(t))
                    }
                }
                .disabled(!controller.canEdit(clip.id))
                Divider()
                let count = state.targets(for: clip.id).count
                let targets = state.targets(for: clip.id)
                Menu(count > 1 ? "Add \(count) to Pinboard" : "Add to Pinboard") {
                    ForEach(state.pins.store.boards) { board in
                        let allPresent = targets.allSatisfy { board.clipIDs.contains($0) }
                        Button { controller.togglePinboard(state.targets(for: clip.id), board: board.id) } label: {
                            Label(board.name, systemImage: allPresent ? "checkmark.circle.fill" : "circle.fill")
                        }
                    }
                    Divider()
                    Button("New Pinboard\u{2026}") {
                        _ = controller.createPinboard(name: "New Pinboard", clips: state.targets(for: clip.id), rename: true)
                    }
                }
                Divider()
                // Targets are read again when an item is chosen: picks may have changed while the menu was open.
                Menu(count > 1 ? "Send \(count) to Stack" : "Add to Stack") {
                    Button("New Stack") { controller.sendToStack(state.targets(for: clip.id), stack: nil) }
                    if !stack.stacks.isEmpty { Divider() }
                    ForEach(stack.stacks) { st in
                        Button(st.name) { controller.sendToStack(state.targets(for: clip.id), stack: st.id) }
                    }
                }
                if clip.kind == .text, controller.canEdit(clip.id) {
                    let head = state.heads[clip.id]
                    let text = head?.text ?? clip.preview
                    if let label = (head?.complete == true) ? StackSplitter.menuLabel(text)
                        : (StackSplitter.detect(text) != nil ? "Split into Stack" : nil) {
                        Button(label) { controller.splitIntoStack(clip.id, mode: nil) }
                    }
                    Menu("Split into Stack As") {
                        ForEach(SplitMode.allCases) { m in
                            let n = StackSplitter.split(text, m).count
                            Button(head?.complete == true ? "\(m.menuTitle) (\(m.unit(n)))" : m.menuTitle) {
                                controller.splitIntoStack(clip.id, mode: m)
                            }
                            .disabled(head?.complete == true && n < 2)
                        }
                    }
                }
                Divider()
                Button(pinned ? "Unpin" : "Pin") { controller.togglePin(clip.id) }
                let ownHide = AIHiddenClips.shared.isHidden(clip.id)
                if !ownHide && AIVisibility.isHidden(clip.id, store: state.store) {
                    Button("Hidden from AI Tools (by its app or original)") {}.disabled(true)
                } else {
                    Button(ownHide ? "Show to AI Tools" : "Hide from AI Tools") {
                        AIHiddenClips.shared.toggle(clip.id)
                        // Edits / transforms already made from it are hidden too, durably.
                        if !ownHide { AIVisibility.persistInheritedHides(store: state.store) }
                    }
                }
                Button("Delete", role: .destructive) { controller.remove(id) }
            }
            .accessibilityValue(memberships.isEmpty ? "No pinboards" : "Pinboards: " + memberships.map(\.name).joined(separator: ", "))
            .help("Return pastes, Space previews, drag to pull out")
    }

    private func fileCard(_ item: ShelfItem, order: [CardID]) -> some View {
        let id = CardID.file(item.id)
        let shelf = state.shelf
        return FileCard(item: item, number: number(id, order),
                        selected: state.cursor == id || shelf.selected.contains(item.id),
                        hovered: state.hovered == id, isImage: StripState.isImageFile(item),
                        onRemove: { shelf.remove(item) })
            .id(id)
            .onTapGesture(count: 2) { if !item.missing { controller.openFile(item) } }
            .onTapGesture {
                let mods = StripClickFlags.current()
                if !mods.contains(.command) && !mods.contains(.shift) { state.picks.clear() }
                shelf.click(item, command: mods.contains(.command), shift: mods.contains(.shift))
                if !item.missing { state.cursor = id }
            }
            .onHover { inside in
                if inside { state.hovered = id; shelf.hoveredID = item.id }
                else {
                    if state.hovered == id { state.hovered = nil }
                    if shelf.hoveredID == item.id { shelf.hoveredID = nil }
                }
            }
            .contextMenu {
                if !item.missing {
                    Button("Paste") { controller.activate(id, plain: false, copyOnly: false) }
                    if StripState.isImageFile(item) { ocrFileMenu(item) }
                    Button("Open") { controller.openFile(item) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    // Through the one tagged writer, so the clipboard monitor doesn't log ShakeBoard's own write.
                    Button("Copy Path") { ClipboardWriter.writeString(item.url.path) }
                    Divider()
                }
                Button("Remove", role: .destructive) { shelf.remove(item) }
            }
            .overlay(alignment: .bottomLeading) {
                if state.ocr?.text(for: item) != nil { OCRBadge() }
            }
            .draggableIf(!item.missing) {
                guard let url = shelf.dragURL(for: item) else { return NSItemProvider() }
                return NSItemProvider(object: url as NSURL)
            }
            .help("Space previews, double-click opens, drag to pull out")
    }

    @ViewBuilder
    private func ocrClipMenu(_ clip: Clip) -> some View {
        if let ocr = state.ocr, ocr.isEnabled {
            Divider()
            switch ocr.status(for: clip) {
            case .complete:
                if let text = ocr.text(for: clip) {
                    Button("Copy Text") { controller.useRecognizedText(text, from: clip.id, paste: false) }
                    Button("Paste Text") { controller.useRecognizedText(text, from: clip.id, paste: true) }
                    Button("Split into Stack") { controller.splitRecognizedText(text, from: clip.id) }
                } else {
                    Button("No Text Found") {}.disabled(true)
                }
            case .failed:
                Button("Couldn't Read Text") {}.disabled(true)
            case .notStarted, .queued:
                Button("Recognizing Text…") {}.disabled(true)
            }
        }
    }

    @ViewBuilder
    private func ocrFileMenu(_ item: ShelfItem) -> some View {
        if let ocr = state.ocr, ocr.isEnabled {
            Divider()
            switch ocr.status(for: item) {
            case .complete:
                if let text = ocr.text(for: item) {
                    Button("Copy Text") { controller.useRecognizedText(text, from: nil, paste: false) }
                    Button("Paste Text") { controller.useRecognizedText(text, from: nil, paste: true) }
                    Button("Split into Stack") { controller.splitRecognizedText(text, from: nil) }
                } else {
                    Button("No Text Found") {}.disabled(true)
                }
            case .failed:
                Button("Couldn't Read Text") {}.disabled(true)
            case .notStarted, .queued:
                Button("Recognizing Text…") {}.disabled(true)
            }
        }
    }
}

// MARK: - Stack lane (mockup frames A/B: the stack list + the selected stack, leading the strip)

// A card dragged onto a stack carries its clip id under this in-process type (alongside the file / text it
// exports to other apps).
enum StackDrag {
    static let typeID = "com.thisradlife.shakeboard.clip-ref"
    static let type = UTType(importedAs: typeID)
    static func register(_ clipID: UUID, on p: NSItemProvider) {
        p.registerDataRepresentation(forTypeIdentifier: typeID, visibility: .ownProcess) { done in
            done(Data(clipID.uuidString.utf8), nil); return nil
        }
    }
    static func load(_ providers: [NSItemProvider], _ got: @escaping @MainActor (UUID) -> Void) -> Bool {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(typeID) }) else { return false }
        p.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
            guard let data, let s = String(data: data, encoding: .utf8), let id = UUID(uuidString: s) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { got(id) } }
        }
        return true
    }
}

struct StackLane: View {
    @ObservedObject var stack: PasteStack
    @EnvironmentObject private var themes: ThemeStore
    let controller: StripController
    static let listWidth: CGFloat = 150
    static let detailWidth: CGFloat = 236
    @State private var dropTarget: UUID?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool
    private var accent: Color { themes.current.isSystem ? .accentColor : themes.current.accent.color }
    private var collecting: Color { themes.current.isSystem ? .red : themes.current.collecting.color }
    private var onAccent: Color {
        themes.current.isSystem ? Color(nsColor: .selectedControlTextColor) : themes.current.onAccent.color
    }
    private var secondaryText: Color { themes.current.isSystem ? .secondary : themes.current.secondaryText }
    private var text: Color { themes.current.isSystem ? .primary : themes.current.text.color }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: Self.listWidth)
            Divider().opacity(0.5)
            detail.frame(width: Self.detailWidth)
        }
        .frame(height: StripView.cardSize.height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
        .padding(.top, 15)   // line up with the cards under their section labels
    }

    private var selected: ClipStack? { stack.selectedStack }
    private var tint: Color {
        guard let s = selected else { return accent }
        switch stack.mode(of: s.id) { case .collecting: return collecting; default: return accent }
    }

    // MARK: list

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 9))
                Text("Stacks").font(.system(size: 10, weight: .bold))
                Spacer(minLength: 2)
                Button { stack.collect(into: stack.newStack()) } label: {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("New stack -- starts collecting your next copies")
                .accessibilityLabel("New stack")
            }
            .foregroundStyle(secondaryText).frame(height: 16).padding(.horizontal, 6)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(stack.stacks.enumerated()), id: \.element.id) { i, st in stackRow(st, index: i) }
                }
                .smoothWheel(.vertical)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 3)
    }

    private func stackRow(_ st: ClipStack, index i: Int) -> some View {
        let mode = stack.mode(of: st.id)
        let isSel = selected?.id == st.id
        let color: Color = mode == .collecting ? collecting : accent
        return HStack(spacing: 5) {
            Button { mode == .ready ? stack.disarm() : stack.toggleCollecting(st.id) } label: {
                Group {
                    switch mode {
                    case .collecting: Circle().fill(collecting).frame(width: 9, height: 9)
                    case .ready: Image(systemName: "play.fill").font(.system(size: 8)).foregroundStyle(accent)
                    case .idle: Circle().strokeBorder(secondaryText, lineWidth: 1).frame(width: 9, height: 9)
                    }
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help(mode == .collecting ? "Stop collecting into \(st.name)"
                  : mode == .ready ? "Stop pasting \(st.name)" : "Collect your next copies into \(st.name)")
            if stack.renamingID == st.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .focused($renameFocused)
                    .onSubmit { stack.rename(st.id, to: draftName); stack.renamingID = nil }
                    .onExitCommand { stack.renamingID = nil }
                    .onAppear { draftName = st.name; renameFocused = true }
            } else {
                Text(st.name).font(.system(size: 11, weight: isSel ? .semibold : .regular)).lineLimit(1)
            }
            Spacer(minLength: 2)
            Text("\(st.slots.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(secondaryText)
                .padding(.horizontal, 5).frame(height: 14)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .padding(.horizontal, 5).frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSel ? color.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(dropTarget == st.id ? color : (isSel ? color.opacity(0.45) : .clear), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { stack.renamingID = st.id }
        .onTapGesture {
            stack.selectedID = st.id
            // Collecting follows the click: copies go to the stack you picked (never into the one pasting).
            if stack.isCollecting, stack.collectingID != st.id, mode != .ready { stack.collect(into: st.id) }
        }
        .onDrop(of: [StackDrag.type], isTargeted: Binding(get: { dropTarget == st.id },
                                                          set: { dropTarget = $0 ? st.id : (dropTarget == st.id ? nil : dropTarget) })) { providers in
            StackDrag.load(providers) { id in controller.addToStack(id, stack: st.id) }
        }
        .contextMenu {
            Button(mode == .collecting ? "Stop Collecting" : "Collect Here") { stack.toggleCollecting(st.id) }
            Button(mode == .ready ? "Stop Pasting" : "Ready to Paste") { if mode == .ready { stack.disarm() } else { controller.armFromStrip(st.id) } }
                .disabled(st.slots.isEmpty && mode != .ready)
            Divider()
            Button("Rename\u{2026}") { stack.renamingID = st.id }
            Button("Move Up") { stack.moveStack(st.id, by: -1) }.disabled(i == 0)
            Button("Move Down") { stack.moveStack(st.id, by: 1) }.disabled(i == stack.stacks.count - 1)
            Button("Archive") { stack.archive(st.id) }.disabled(st.slots.isEmpty)
            Divider()
            Button("Delete", role: .destructive) { stack.delete(st.id) }
        }
        .accessibilityLabel("\(st.name), \(st.slots.count) items" + (mode == .collecting ? ", collecting" : mode == .ready ? ", ready to paste" : ""))
    }

    // MARK: detail (the selected stack)

    @ViewBuilder private var detail: some View {
        if let st = selected {
            let mode = stack.mode(of: st.id)
            let entries = stack.entries(of: st.id)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(st.name).font(.system(size: 11, weight: .bold)).lineLimit(1)
                    stateChip(mode)
                    Spacer(minLength: 2)
                    switch mode {
                    case .ready:
                        Button { stack.disarm() } label: { chipButton("Stop", "stop.fill", filled: false) }
                            .buttonStyle(.plain).help("Stop pasting -- the stack keeps its items")
                    default:
                        Button { controller.armFromStrip(st.id) } label: { chipButton("Ready to paste", "play.fill", filled: true) }
                            .buttonStyle(.plain).disabled(st.slots.isEmpty)
                            .help("Each \u{2318}V pastes the next item, in order. After the last one the stack moves to Stacks.")
                    }
                }
                .frame(height: 18)
                if entries.isEmpty {
                    Text(mode == .collecting ? "Copy with \u{2318}C in any app -- each copy lands here. \u{2318}V still pastes as usual."
                         : "Empty. Click the circle to collect copies, or drag cards here.")
                        .font(.system(size: 10)).foregroundStyle(secondaryText)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(entries) { e in row(e, count: entries.count).id(e.token) }
                            }
                            .smoothWheel(.vertical)
                        }
                        .onAppear { if let n = entries.first(where: \.next) { proxy.scrollTo(n.token, anchor: .top) } }
                        .onChange(of: stack.cursor) { _, _ in
                            if let n = stack.entries(of: st.id).first(where: \.next) {
                                withAnimation(Motion.scroll) { proxy.scrollTo(n.token, anchor: .top) }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                footer(st, mode: mode, entries: entries)
            }
            .padding(.horizontal, 7).padding(.vertical, 6)
            .onDrop(of: [StackDrag.type], isTargeted: nil) { providers in
                StackDrag.load(providers) { id in controller.addToStack(id, stack: st.id) }
            }
        } else {
            VStack(spacing: 6) {
                Text("No stacks yet").font(.system(size: 11, weight: .semibold))
                Button { stack.collect(into: stack.newStack()) } label: { chipButton("New stack", "plus", filled: true) }
                    .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stateChip(_ mode: PasteStack.Mode) -> some View {
        Group {
            switch mode {
            case .collecting:
                Label("Collecting", systemImage: "circle.fill").foregroundStyle(collecting)
                    .background(Capsule().fill(collecting.opacity(0.14)).padding(.horizontal, -5))
            case .ready:
                Label("Ready", systemImage: "play.fill").foregroundStyle(accent)
                    .background(Capsule().fill(accent.opacity(0.14)).padding(.horizontal, -5))
            case .idle: EmptyView()
            }
        }
        .labelStyle(TightLabel())
        .font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5)
    }

    private func chipButton(_ title: String, _ symbol: String, filled: Bool) -> some View {
        Label(title, systemImage: symbol).labelStyle(TightLabel())
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 7).frame(height: 17)
            .background(Capsule().fill(filled ? accent : text.opacity(0.08)))
            .foregroundStyle(filled ? onAccent : text)
    }

    private func row(_ e: PasteStack.Entry, count: Int) -> some View {
        let clip = e.clip
        return HStack(spacing: 6) {
            Group {
                if e.pasted { Image(systemName: "checkmark").font(.system(size: 7, weight: .bold)) }
                else { Text("\(e.position + 1)").font(.system(size: 9, weight: .bold, design: .rounded)) }
            }
            .frame(width: 14, height: 14)
            .background(Circle().fill(e.next ? accent : text.opacity(0.1)))
            .foregroundStyle(e.next ? onAccent : secondaryText)
            Text(clip.kind == .image ? "Image" : clip.preview).font(.system(size: 10.5, weight: e.next ? .semibold : .regular))
                .lineLimit(1)
                .strikethrough(e.pasted, color: .secondary)
            Spacer(minLength: 0)
            if e.next { Text("next").font(.system(size: 8, weight: .bold)).foregroundStyle(accent) }
        }
        .padding(.leading, 3).padding(.trailing, 6).frame(height: 17)
        .background(RoundedRectangle(cornerRadius: 8).fill(e.next ? accent.opacity(0.22) : Color.clear))
        .opacity(e.pasted ? 0.45 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Move Up") { stack.move(token: e.token, by: -1) }.disabled(e.position == 0 || e.pasted)
            Button("Move Down") { stack.move(token: e.token, by: 1) }.disabled(e.position == count - 1 || e.pasted)
            Divider()
            Button("Remove from Stack") { stack.remove(token: e.token) }
        }
        .help(e.next ? "Next on \u{2318}V" : "Right-click to move or remove")
    }

    @ViewBuilder private func footer(_ st: ClipStack, mode: PasteStack.Mode, entries: [PasteStack.Entry]) -> some View {
        HStack(spacing: 5) {
            if let u = stack.undoOffer {
                Text(u.message).foregroundStyle(secondaryText).lineLimit(1)
                Spacer(minLength: 2)
                Button("Undo") { stack.performUndo() }.buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(accent)
            } else if mode == .ready && stack.isPaused {
                Text(stack.notice ?? "Paused").foregroundStyle(.orange).lineLimit(1)
                Spacer(minLength: 2)
                Button("Resume") { stack.resume() }.buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(accent)
            } else if let n = stack.notice {
                Text(n).foregroundStyle(.orange).lineLimit(1)
            } else if mode == .ready {
                Text("\u{2318}V pastes the next \u{00B7} \(entries.filter { !$0.pasted }.count) left").foregroundStyle(secondaryText).lineLimit(1)
            } else if mode == .collecting {
                Text("\u{2318}C adds here \u{00B7} \u{2318}V pastes as usual").foregroundStyle(secondaryText).lineLimit(1)
            } else if !entries.isEmpty {
                Text("Ready to paste, then \u{2318}V in order").foregroundStyle(secondaryText).lineLimit(1)
            }
        }
        .font(.system(size: 9)).frame(height: 13)
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.font(.system(size: 7)); configuration.title }
    }
}

// MARK: - Stacks filter (finished stacks are archived here; Paste Again re-arms one)

struct StacksGallery: View {
    @ObservedObject var stack: PasteStack
    @EnvironmentObject private var themes: ThemeStore
    let controller: StripController
    private var accent: Color { themes.current.isSystem ? .accentColor : themes.current.accent.color }
    private var collecting: Color { themes.current.isSystem ? .red : themes.current.collecting.color }
    private var onAccent: Color {
        themes.current.isSystem ? Color(nsColor: .selectedControlTextColor) : themes.current.onAccent.color
    }
    private var secondaryText: Color { themes.current.isSystem ? .secondary : themes.current.secondaryText }

    var body: some View {
        if stack.archived.isEmpty && stack.stacks.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 20)).foregroundStyle(secondaryText)
                Text("Stacks you finish pasting land here -- Paste Again re-arms one").font(.system(size: 12)).foregroundStyle(secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    if !stack.stacks.isEmpty {
                        section("Stacks", "square.stack.3d.up") { ForEach(stack.stacks) { card($0, archived: false) } }
                    }
                    if !stack.archived.isEmpty {
                        section("Finished", "archivebox") { ForEach(stack.archived) { card($0, archived: true) } }
                    }
                }
                .padding(.horizontal, 2).padding(.bottom, 2)
                .smoothWheel(.horizontal)
            }
        }
    }

    private func section<C: View>(_ title: String, _ symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 8))
                Text(title).font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(secondaryText).frame(height: 12)
            HStack(alignment: .top, spacing: 7) { content() }
        }
    }

    static func ago(_ d: Date) -> String {
        let a = Age.short(d)
        return a == "now" ? "just now" : a + " ago"
    }

    private func card(_ st: ClipStack, archived: Bool) -> some View {
        let entries = stack.entries(of: st.id)
        let mode = stack.mode(of: st.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: archived ? "checkmark.circle" : "square.stack.3d.up.fill").font(.system(size: 9))
                    .foregroundStyle(archived ? Color.green : (mode == .collecting ? collecting : accent))
                Text(st.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(st.slots.count)").font(.system(size: 9, weight: .semibold)).foregroundStyle(secondaryText)
            }
            ForEach(entries.prefix(2)) { e in
                HStack(spacing: 4) {
                    Text("\(e.position + 1)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(secondaryText)
                        .frame(width: 10)
                    Text(e.clip.kind == .image ? "Image" : e.clip.preview).font(.system(size: 10)).lineLimit(1)
                }
            }
            if entries.count > 2 {
                Text("+\(entries.count - 2) more").font(.system(size: 9)).foregroundStyle(secondaryText)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text((archived ? "pasted " : "made ") + Self.ago(archived ? (st.archivedAt ?? st.createdAt) : st.createdAt))
                    .font(.system(size: 9)).foregroundStyle(secondaryText).lineLimit(1)
                Spacer(minLength: 2)
                Button {
                    controller.armFromStrip(st.id, restoring: archived)
                } label: {
                    Label(archived ? "Paste again" : "Ready", systemImage: archived ? "arrow.counterclockwise" : "play.fill")
                        .labelStyle(TightLabel()).font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).frame(height: 16)
                        .background(Capsule().fill(accent)).foregroundStyle(onAccent)
                }
                .buttonStyle(.plain).disabled(st.slots.isEmpty || mode == .ready)
            }
        }
        .padding(8)
        .frame(width: StripView.cardSize.width + 24, height: StripView.cardSize.height, alignment: .topLeading)
        .modifier(PerchGlass(shape: RoundedRectangle(cornerRadius: GlassMetrics.cardRadius, style: .continuous),
                             tint: nil, role: .card))
        .contentShape(Rectangle())
        .onTapGesture { if !archived { stack.selectedID = st.id; stack.laneOpen = true } }
        .contextMenu {
            if archived {
                Button("Paste Again") { controller.armFromStrip(st.id, restoring: true) }
                Button("Move Back to Stacks") { stack.restore(st.id, arm: false) }
            } else {
                Button("Ready to Paste") { controller.armFromStrip(st.id) }.disabled(st.slots.isEmpty)
                Button("Show in Lane") { stack.selectedID = st.id; stack.laneOpen = true }
                Button("Archive") { stack.archive(st.id) }.disabled(st.slots.isEmpty)
            }
            Divider()
            Button("Delete", role: .destructive) { stack.delete(st.id) }
        }
        .help(archived ? "Finished stack -- Paste Again re-arms it from the first item" : "Click to show it in the stack lane")
    }
}

extension View {
    // Attach .onDrag ONLY when draggable -- an empty NSItemProvider still starts a payload-less
    // "ghost" drag, so for non-draggable items we omit the modifier entirely.
    @ViewBuilder func draggableIf(_ enabled: Bool, _ provider: @escaping () -> NSItemProvider) -> some View {
        if enabled { self.onDrag(provider) } else { self }
    }
}

// MARK: - Edit inset (replaces the cards while a draft is open)

private struct EditorInset: View {
    @ObservedObject var state: StripState
    let controller: StripController
    var focused: FocusState<Bool>.Binding
    @EnvironmentObject private var themes: ThemeStore
    private var accent: Color { themes.current.isSystem ? .accentColor : themes.current.accent.color }
    private var secondaryText: Color { themes.current.isSystem ? .secondary : themes.current.secondaryText }
    private var editorFill: Color {
        themes.current.isSystem ? Color(nsColor: .textBackgroundColor) : themes.current.card.color
    }

    var body: some View {
        let kind = state.editing?.kind ?? .text
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "pencil").font(.system(size: 9, weight: .semibold))
                Text("Editing \(kind.label.lowercased())").font(.system(size: 9, weight: .semibold))
                if case .code(let lang) = kind {
                    Text(lang).font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4).frame(height: 12)
                        .background(Capsule().fill(Color.purple.opacity(0.18)))
                }
                Text("Saving makes a new copy -- the original stays as it is.")
                    .font(.system(size: 9)).foregroundStyle(secondaryText)
                Spacer(minLength: 4)
                Button("Cancel") { controller.cancelEdit() }
                    .controlSize(.small)
                Button("Save as New") { controller.saveEdit() }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(state.editSaving || (state.editing.map { $0.text == $0.original } ?? true))
            }
            .frame(height: 18)
            TextEditor(text: Binding(get: { state.editing?.text ?? "" },
                                     set: { if state.editing != nil { state.editing?.text = $0 } }))
                .font(kind.isCode || kind == .link ? .system(size: 11, design: .monospaced) : .system(size: 12))
                .scrollContentBackground(.hidden)
                .background(editorFill)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(editorFill))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(accent.opacity(0.6), lineWidth: 1))
                .focused(focused)
                .accessibilityLabel("Edit text")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focused.wrappedValue = true }
    }
}

// MARK: - Cards

private struct CardChrome<Content: View, Footer: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    var badge: String? = nil
    let number: Int?
    let selected: Bool
    let hovered: Bool
    var pinned = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer
    @EnvironmentObject private var themes: ThemeStore
    private var cardColor: Color {
        themes.current.isSystem ? Color(nsColor: .textBackgroundColor).opacity(0.72) : themes.current.card.color
    }
    private var accent: Color { themes.current.isSystem ? .accentColor : themes.current.accent.color }
    private var rim: Color { themes.current.isSystem ? .primary : themes.current.text.color }
    private var secondaryText: Color { themes.current.isSystem ? Color.primary.opacity(0.55) : themes.current.secondaryText }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .semibold))
                if let badge {
                    Text(badge).font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 4).frame(height: 12)
                        .background(Capsule().fill(Color.white.opacity(0.28)))
                }
                Spacer(minLength: 2)
                if pinned { Image(systemName: "pin.fill").font(.system(size: 7)) }
                if let number {
                    Text("\(number)").font(.system(size: 8, weight: .bold, design: .rounded))
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(Color.white.opacity(0.3)))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 6).frame(height: 18)
            .background(tint.opacity(0.85))
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 6).padding(.top, 4)
                .clipped()
            footer()
                .font(.system(size: 8.5, weight: .medium)).foregroundStyle(secondaryText)
                .padding(.horizontal, 6).frame(height: 14)
        }
        .frame(width: StripView.cardSize.width, height: StripView.cardSize.height)
        .background(cardColor)
        .clipShape(RoundedRectangle(cornerRadius: GlassMetrics.cardRadius - 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GlassMetrics.cardRadius - 2, style: .continuous)
            .strokeBorder(selected ? accent : rim.opacity(hovered ? 0.25 : 0.1),
                          lineWidth: selected ? 2 : 0.5))
        .shadow(color: .black.opacity(selected ? 0.18 : 0.06), radius: selected ? 4 : 1, y: 1)
        .contentShape(Rectangle())
    }
}

enum CardThumbMetrics {
    // Thumbnail render size (points): the card's long edge plus a little headroom for the aspect-fill crop.
    // Rendered at the screen's backing scale, so it stays sharp on Retina without holding big bitmaps.
    static let renderEdge: CGFloat = 180
}

// Image and file cards: the picture IS the card. Edge to edge, one caption row over a soft scrim at the bottom
// (kind icon + name, then size / age), the 1-9 number as a corner chip. No separate header and footer rows.
struct MediaCardChrome<Media: View, Trailing: View>: View {
    let symbol: String
    let title: String
    let number: Int?
    let selected: Bool
    let hovered: Bool
    var pinned = false
    @ViewBuilder let media: () -> Media
    @ViewBuilder let trailing: () -> Trailing
    @EnvironmentObject private var themes: ThemeStore
    private var cardColor: Color {
        themes.current.isSystem ? Color(nsColor: .textBackgroundColor).opacity(0.72) : themes.current.card.color
    }
    private var accent: Color { themes.current.isSystem ? .accentColor : themes.current.accent.color }
    private var rim: Color { themes.current.isSystem ? .primary : themes.current.text.color }

    var body: some View {
        media()
            .frame(width: StripView.cardSize.width, height: StripView.cardSize.height)
            .clipped()
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
                    Text(title).font(.system(size: 9, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 3)
                    trailing().font(.system(size: 8.5, weight: .medium)).opacity(0.85).lineLimit(1).fixedSize()
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
                .padding(.horizontal, 6).frame(height: 18)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 32)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 3) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 7)).frame(width: 13, height: 13)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    if let number {
                        Text("\(number)").font(.system(size: 8, weight: .bold, design: .rounded))
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                }
                .foregroundStyle(.white)
                .padding(.top, 2.5).padding(.trailing, 6)
                .allowsHitTesting(false)
            }
            .frame(width: StripView.cardSize.width, height: StripView.cardSize.height)
            .background(cardColor)
            .clipShape(RoundedRectangle(cornerRadius: GlassMetrics.cardRadius - 2, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GlassMetrics.cardRadius - 2, style: .continuous)
                .strokeBorder(selected ? accent : rim.opacity(hovered ? 0.25 : 0.1),
                              lineWidth: selected ? 2 : 0.5))
            .shadow(color: .black.opacity(selected ? 0.18 : 0.06), radius: selected ? 4 : 1, y: 1)
            .contentShape(Rectangle())
    }
}

// A shelf file's picture: images fill the card (cropped), documents (PDF pages etc.) fit on a soft backdrop
// with room for the caption, anything QuickLook can't render shows its Finder icon.
struct CardThumbnail: View {
    let url: URL
    let fill: Bool
    let missing: Bool
    @State private var preview: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.05)
            if let preview, fill {
                Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else if let preview {
                Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
                    .padding(.top, 8).padding(.bottom, 22).padding(.horizontal, 10)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                    .aspectRatio(contentMode: .fit).frame(width: 52, height: 52)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: StripView.cardSize.width, height: StripView.cardSize.height)
        .clipped()
        .opacity(missing ? 0.4 : 1)
        .task(id: url.path) {
            guard !missing else { return }      // don't spin up QuickLook for a dead path
            let edge = CardThumbMetrics.renderEdge
            if let hit = ShelfThumbnails.cached(url, edge: edge) { preview = hit; return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            ShelfThumbnails.load(url, edge: edge, scale: scale) { preview = $0 }
        }
    }
}

struct ClipCard: View {
    let clip: Clip
    let kind: CardKind
    let head: ClipHead?
    let store: ClipStore
    var dragAll: (() -> [URL])? = nil
    let number: Int?
    let selected: Bool
    let pinned: Bool
    let hovered: Bool
    @EnvironmentObject private var themes: ThemeStore
    private var accent: Color { themes.current.isSystem ? .blue : themes.current.accent.color }

    private var tint: Color {
        switch kind {
        case .text: return .gray
        case .richText: return .orange
        case .code: return .purple
        case .link: return .blue
        case .image: return .green
        case .files: return .teal
        }
    }
    private var badge: String? {
        switch kind {
        case .code(let lang): return lang
        case .richText: return "Rich"
        default: return nil
        }
    }

    var body: some View {
        if kind == .image { imageBody } else { textBody }
    }

    // Copied images: the picture fills the card; one caption row carries kind, size and age.
    private var imageBody: some View {
        MediaCardChrome(symbol: kind.symbol, title: meta, number: number, selected: selected, hovered: hovered,
                        pinned: pinned) {
            ClipImage(url: store.imageURL(for: clip))
        } trailing: {
            if let dragAll {
                dragAllChip(dragAll)
            } else {
                HStack(spacing: 3) {
                    AppIcon(bundleID: clip.sourceBundleID).frame(width: 10, height: 10)
                    Text(Age.short(clip.lastUsedAt))
                }
            }
        }
    }

    private func dragAllChip(_ urls: @escaping () -> [URL]) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "square.and.arrow.up.on.square").font(.system(size: 8))
            Text("Drag \(clip.itemCount)").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 4).frame(height: 12)
        .background(Capsule().fill(Color.white.opacity(0.85)))
        .fixedSize()
        .overlay(DragOutHandle(urls: urls))
        .help("Drag all \(clip.itemCount) out")
    }

    private var textBody: some View {
        CardChrome(title: kind.label, symbol: kind.symbol, tint: tint, badge: badge, number: number,
                   selected: selected, hovered: hovered, pinned: pinned) {
            content
        } footer: {
            HStack(spacing: 3) {
                AppIcon(bundleID: clip.sourceBundleID).frame(width: 10, height: 10)
                Text(Age.short(clip.lastUsedAt))
                Spacer(minLength: 2)
                if let dragAll {
                    HStack(spacing: 2) {
                        Image(systemName: "square.and.arrow.up.on.square").font(.system(size: 8))
                        Text("Drag \(clip.itemCount)").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 4).frame(height: 12)
                    .background(Capsule().fill(accent.opacity(0.12)))
                    .fixedSize()
                    .overlay(DragOutHandle(urls: dragAll))
                    .help("Drag all \(clip.itemCount) out")
                } else {
                    Text(meta).lineLimit(1)
                }
            }
        }
    }

    private var text: String { head?.text ?? clip.preview }

    private var meta: String {
        switch kind {
        case .code: return "\(head?.lines ?? 1) line\((head?.lines ?? 1) == 1 ? "" : "s")"
        case .image:
            if let w = clip.pixelWidth, let h = clip.pixelHeight { return "\(w) x \(h)" }
            return "PNG"
        case .files: return clip.itemCount == 1 ? "1 file" : "\(clip.itemCount) files"
        case .richText: return "Rich text"
        case .link: return ""
        case .text: return "\(head?.chars ?? clip.preview.count) chars"
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .code(let lang):
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(7).joined(separator: "\n")
            Text(CodeHighlighter.attributed(lines, language: lang))
                .font(.system(size: 9.5, design: .monospaced)).lineLimit(6)
        case .link:
            let parts = LinkInfo.parts(text)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 10)).foregroundStyle(.blue)
                    Text(parts?.host ?? text).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                if let path = parts?.path, !path.isEmpty, path != "/" {
                    Text(path).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let title = head?.linkTitle {
                    Text(title).font(.system(size: 10)).lineLimit(2)
                }
            }
        case .image:
            ClipImage(url: store.imageURL(for: clip))   // drawn by imageBody; kept for exhaustiveness
        case .files:
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "doc.on.doc").font(.system(size: 18)).foregroundStyle(.teal)
                Text(clip.preview).font(.system(size: 10)).lineLimit(4)
            }
        case .text, .richText:
            Text(text).font(.system(size: 10.5)).lineLimit(5)
        }
    }
}

private struct ClipImage: View {
    let url: URL?
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            if let image {
                // Fill the card (crop the overflow) -- a letterboxed screenshot was too small to read.
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(.secondary)
            }
        }
        .frame(width: StripView.cardSize.width, height: StripView.cardSize.height)
        .clipped()
        .task(id: url?.path ?? "") { image = await ClipThumbCache.load(url, edge: CardThumbMetrics.renderEdge) }
    }
}

struct FileCard: View {
    let item: ShelfItem
    let number: Int?
    let selected: Bool
    let hovered: Bool
    let isImage: Bool
    let onRemove: () -> Void

    var body: some View {
        let name = item.url.lastPathComponent
        MediaCardChrome(symbol: isImage ? "photo" : "doc", title: name, number: number, selected: selected,
                        hovered: hovered) {
            CardThumbnail(url: item.url, fill: isImage, missing: item.missing)
                .accessibilityLabel(name)
                .accessibilityValue(item.missing ? "Missing" : "")
        } trailing: {
            Text(item.missing ? "Missing" : Self.size(item.url))
        }
        .opacity(item.missing ? 0.6 : 1)
        .overlay(alignment: .topLeading) {
            if hovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain).padding(4)
                .help("Remove from the shelf")
                .accessibilityLabel("Remove \(name)")
            }
        }
    }

    static func size(_ url: URL) -> String {
        guard let n = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

private struct OCRBadge: View {
    var body: some View {
        Image(systemName: "text.viewfinder")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(Circle().fill(Color.black.opacity(0.65)))
            .padding(5)
            .help("Text found -- right-click to copy it")
            .accessibilityLabel("Text found")
    }
}
