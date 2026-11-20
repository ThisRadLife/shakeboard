//
//  PasteStack.swift
//  ShakeBoard -- multiple paste stacks. Each stack is a named, ordered list of copies (Stacks.swift has the model and
//  stacks.json). At any moment at most ONE stack is Collecting and at most ONE (other) stack is Ready to paste:
//
//    Collecting   every captured copy is appended to that stack. The clipboard is left alone, so Cmd-V pastes
//                 normally -- collecting only gathers.
//    Ready        ShakeBoard puts the stack's next item on the clipboard; each Cmd-V pastes it and, a beat after the
//                 V keyUp, the next one is loaded. After the last item the stack is ARCHIVED (it leaves the
//                 active list and shows under the strip's Stacks filter, where Paste Again re-arms it) and the
//                 clipboard the user had before arming is restored (only if it's still ShakeBoard's).
//    Idle         neither. Every launch starts all stacks Idle.
//
//  Arming a stack stops collecting on that same stack (and collecting into the Ready stack disarms it), so one
//  stack can collect while a different one pastes. When a copy lands in the collecting stack while another is
//  Ready, the Ready stack's next item is put back on the clipboard right away -- the copy is safe in its stack.
//  A copy that isn't collected anywhere is left on the clipboard; the Ready stack then pauses (below).
//
//  Ownership (unchanged from the single stack): the Ready stack only acts on Cmd-V while the clipboard's
//  changeCount is the one it wrote. Anything else on the clipboard (an unpolled copy, a skipped password copy, a
//  history paste) PAUSES it instead of advancing; Resume (or a copy landing in the collecting stack) reloads it.
//  One pending advance at a time: a second Cmd-V inside the beat re-pastes the same item, never skips one.
//  Known limits: Edit-menu / right-click Paste doesn't advance; Secure Input hides the keystrokes; two copies
//  inside one 0.5 s poll merge into the later one.
//

import SwiftUI
import AppKit
import Combine
import Carbon
import ApplicationServices

@MainActor
final class PasteStack: ObservableObject {
    @Published private(set) var stacks: [ClipStack] = []          // active, in the user's order
    @Published private(set) var archived: [ClipStack] = []        // newest first
    @Published private(set) var collectingID: UUID?
    @Published private(set) var readyID: UUID?
    @Published var selectedID: UUID?                              // the stack the lane shows
    @Published var laneOpen = false                                // lane shown even while nothing is active
    @Published private(set) var cursor = 0                         // ready stack: index of the next item
    @Published private(set) var isPaused = false                   // clipboard isn't the ready stack's item
    @Published var notice: String?
    @Published private(set) var lastSaveFailed = false
    // "Stack 1 pasted 5 of 5" -- shown in the bar for a few seconds after a stack finishes.
    struct Finished: Equatable { let id: UUID; let name: String; let count: Int }
    @Published private(set) var finished: Finished?
    // One-step undo for deletes (no confirmation dialogs).
    struct UndoOffer { let id = UUID(); let message: String; let undo: () -> Void }
    @Published private(set) var undoOffer: UndoOffer?
    @Published var renamingID: UUID?

    static let maxItems = 50
    static let maxBytes = 200 * 1024 * 1024
    static let maxOriginalBytes = 50 * 1024 * 1024
    // Beat between the Cmd-V keyUp and loading the next item: long enough for slow / lazily-reading paste
    // targets (Electron, remote sessions) to have read the pasteboard.
    static let defaultAdvanceDelay: TimeInterval = 0.25
    static let bannerSeconds: TimeInterval = 8

    private let store: ClipStore
    let url: URL
    private var original: [[RawRep]] = []
    private var ownedChangeCount: Int?
    private var vArmed = false
    private(set) var advancePending = false
    // Identifies one armed period; a delayed advance scheduled in an earlier one is void.
    private(set) var session = UUID()
    var advanceDelay: TimeInterval = PasteStack.defaultAdvanceDelay
    var pasteboard: () -> PasteboardAccess = { ClipboardWriter.pasteboard }
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    var now: () -> Date = Date.init
    // Called when clips stop being referenced (stack deleted, item removed) so retention applies right away.
    var onPinsReleased: () -> Void = { }

    init(store: ClipStore, baseDir: URL) {
        self.store = store
        url = baseDir.appendingPathComponent("stacks.json")
    }

    // MARK: derived state

    var isCollecting: Bool { collectingID != nil }
    var isReady: Bool { readyID != nil }
    var isOn: Bool { isCollecting || isReady }               // anything going on (rail badge, bar)
    var showsLane: Bool { laneOpen }

    func stack(_ id: UUID?) -> ClipStack? { id.flatMap { i in stacks.first { $0.id == i } } }
    func archivedStack(_ id: UUID) -> ClipStack? { archived.first { $0.id == id } }
    private func index(_ id: UUID?) -> Int? { id.flatMap { i in stacks.firstIndex { $0.id == i } } }
    var readyStack: ClipStack? { stack(readyID) }
    var collectingStack: ClipStack? { stack(collectingID) }
    var selectedStack: ClipStack? { stack(selectedID) ?? stacks.first }

    enum Mode: Equatable { case idle, collecting, ready }
    func mode(of id: UUID) -> Mode { id == readyID ? .ready : id == collectingID ? .collecting : .idle }

    // Every clip any stack (active or archived) references -- protected from retention and Clear History.
    // A deleted stack's clips stay protected while its Undo is offered.
    var pinnedIDs: Set<UUID> { Set((stacks + archived).flatMap(\.clipIDs)).union(undoPinned) }
    private var undoPinned: Set<UUID> = []

    // Ready stack: what's left to paste, oldest first ([0] is "next on Cmd-V").
    var queue: [UUID] { readyStack.map { Array($0.clipIDs.dropFirst(cursor)) } ?? [] }

    struct Entry: Identifiable {
        let position: Int; let token: UUID; let clip: Clip; let pasted: Bool; let next: Bool
        var id: UUID { token }
    }
    // Rows for one stack, keyed by occurrence token (never the clip id or the index, which shift).
    func entries(of id: UUID?) -> [Entry] {
        guard let st = stack(id) ?? id.flatMap({ archivedStack($0) }) else { return [] }
        let ready = st.id == readyID
        return st.slots.enumerated().compactMap { i, slot in
            store.clip(slot.clip).map { Entry(position: i, token: slot.token, clip: $0,
                                               pasted: ready && i < cursor, next: ready && i == cursor) }
        }
    }
    // Ready stack, not yet pasted.
    var queuedEntries: [Entry] { entries(of: readyID).filter { !$0.pasted } }
    // Badge text for a clip that sits in the collecting or ready stack, e.g. "S1 #3".
    func badge(for clipID: UUID) -> (text: String, ready: Bool)? {
        for (sid, ready) in [(readyID, true), (collectingID, false)] {
            guard let i = index(sid) else { continue }
            let at = stacks[i].clipIDs.indices.filter { stacks[i].clipIDs[$0] == clipID && (!ready || $0 >= cursor) }
            if !at.isEmpty { return ("S\(i + 1) #" + at.map { String($0 + 1) }.joined(separator: ","), ready) }
        }
        return nil
    }
    func clipPreview(_ id: UUID) -> String? { store.clip(id).map { $0.kind == .image ? "Image" : $0.preview } }
    // The clipboard holds exactly what the ready stack last wrote.
    var ownsClipboard: Bool { ownedChangeCount != nil && pasteboard().changeCount == ownedChangeCount }

    // MARK: persistence

    // True when stacks.json exists but couldn't be read or set aside: nothing is ever written over it this run.
    @Published private(set) var readOnly = false

    func load() {
        var f = StackFile()
        switch StackFile.load(from: url) {
        case .loaded(let loaded): f = loaded; readOnly = false
        case .missing, .setAside: readOnly = false
        case .failed: readOnly = true; lastSaveFailed = true
        }
        stacks = f.active; archived = f.archived
        collectingID = nil; readyID = nil; cursor = 0
        if selectedID.map({ id in !stacks.contains { $0.id == id } }) ?? true { selectedID = stacks.first?.id }
    }

    // Drop occurrences of clips that no longer exist (history quarantined, clip deleted). Empty archived stacks go.
    func prune(keeping existing: Set<UUID>) {
        guard !store.isDegraded else { return }
        var changed = false
        func clean(_ list: inout [ClipStack]) {
            for i in list.indices {
                let kept = list[i].slots.filter { existing.contains($0.clip) }
                if kept != list[i].slots { list[i].slots = kept; changed = true }
            }
        }
        clean(&stacks); clean(&archived)
        let before = archived.count
        archived.removeAll { $0.slots.isEmpty }
        if archived.count != before { changed = true }
        if changed { save() }
    }

    // Every mutation rewrites the whole file, so a failed save is retried by the next change (and shown in Settings).
    @discardableResult
    private func save() -> Bool {
        guard !readOnly else { lastSaveFailed = true; return false }
        let ok = StackFile(active: stacks, archived: archived).save(to: url)
        lastSaveFailed = !ok
        return ok
    }

    // MARK: stacks

    func nextName() -> String {
        let used = Set((stacks + archived).map(\.name))
        var n = stacks.count + 1
        while used.contains("Stack \(n)") { n += 1 }
        return "Stack \(n)"
    }

    @discardableResult
    func newStack(name: String? = nil, clips: [UUID] = [], select: Bool = true) -> UUID {
        let st = ClipStack(name: name ?? nextName(), slots: clips.prefix(Self.maxItems).map { StackSlot(clip: $0) },
                           createdAt: now())
        stacks.append(st)
        if select { selectedID = st.id; laneOpen = true }
        save()
        return st.id
    }

    func rename(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let i = index(id) { stacks[i].name = String(t.prefix(60)) }
        else if let i = archived.firstIndex(where: { $0.id == id }) { archived[i].name = String(t.prefix(60)) }
        else { return }
        save()
    }

    func moveStack(_ id: UUID, by delta: Int) {
        guard let i = index(id) else { return }
        let j = i + delta
        guard stacks.indices.contains(j) else { return }
        stacks.swapAt(i, j)
        save()
    }

    // Delete an active or archived stack. Undoable for a few seconds.
    func delete(_ id: UUID) {
        if let i = index(id) {
            if id == readyID { disarm() }
            if id == collectingID { stopCollecting() }
            let st = stacks.remove(at: i)
            if selectedID == id { selectedID = stacks.first?.id }
            save()
            offerUndo("Deleted \u{201C}\(st.name)\u{201D}", pins: Set(st.clipIDs)) { [weak self] in
                guard let self else { return }
                self.stacks.insert(st, at: min(i, self.stacks.count)); self.selectedID = st.id; self.save()
            }
        } else if let i = archived.firstIndex(where: { $0.id == id }) {
            let st = archived.remove(at: i)
            save()
            offerUndo("Deleted \u{201C}\(st.name)\u{201D}", pins: Set(st.clipIDs)) { [weak self] in
                guard let self else { return }
                self.archived.insert(st, at: min(i, self.archived.count)); self.save()
            }
        }
        // Pins are released when the Undo offer ends (expires, is dismissed, or a newer one replaces it).
    }

    private func offerUndo(_ message: String, pins: Set<UUID>, _ undo: @escaping () -> Void) {
        // A newer offer supersedes the old one. Install the new pins BEFORE pruning for the old, or retention could
        // evict the clips of the stack that was just deleted.
        let released = !undoPinned.subtracting(pins).isEmpty
        let offer = UndoOffer(message: message, undo: undo)
        undoOffer = offer
        undoPinned = pins
        if released { onPinsReleased() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerSeconds) { [weak self] in
            MainActor.assumeIsolated { if self?.undoOffer?.id == offer.id { self?.endUndoOffer(releasing: true) } }
        }
    }
    private func endUndoOffer(releasing: Bool) {
        let had = !undoPinned.isEmpty
        undoOffer = nil
        undoPinned = []
        if releasing && had { onPinsReleased() }
    }
    func performUndo() {
        guard let u = undoOffer else { return }
        u.undo()                                   // the stack is back: its clips are pinned by it again
        endUndoOffer(releasing: false)
    }
    func dismissUndo() { endUndoOffer(releasing: true) }

    // Add a copy to a stack by hand (card menu, drag onto a stack, Split into Stack).
    @discardableResult
    func add(_ clipID: UUID, to id: UUID) -> Bool {
        guard let i = index(id), let clip = store.clip(clipID) else { return false }
        guard fits(clip, in: stacks[i]) else { return false }
        stacks[i].slots.append(StackSlot(clip: clipID))
        save()
        return true
    }

    // Send several copies to a stack in the given order (the strip's Command-click order). `id == nil` makes a new
    // stack. Stops at the first copy that doesn't fit (the stack's `notice` says why). Undoable: the copies sent
    // come back out (a stack this made is removed again). Returns the stack and how many went in, or nil.
    struct SendResult: Equatable { let stack: UUID; let added: Int; let created: Bool }
    @discardableResult
    func send(_ clipIDs: [UUID], to id: UUID?) -> SendResult? {
        let live = clipIDs.filter { store.clip($0) != nil }
        guard !live.isEmpty else { return nil }
        if let id, index(id) == nil { return nil }
        let created = id == nil
        let sid = id ?? newStack(select: true)
        var tokens: [UUID] = []
        for c in live {
            guard let i = index(sid), let clip = store.clip(c), fits(clip, in: stacks[i]) else { break }
            let slot = StackSlot(clip: c)
            stacks[i].slots.append(slot)
            tokens.append(slot.token)
        }
        if tokens.isEmpty && created {           // nothing fit (a single huge copy): don't leave an empty stack behind
            if let i = index(sid) { stacks.remove(at: i) }
            if selectedID == sid { selectedID = stacks.first?.id }
            save()
            return nil
        }
        save()
        guard let st = stack(sid), !tokens.isEmpty else { return nil }
        let n = tokens.count
        offerUndo("Sent \(n) to \u{201C}\(st.name)\u{201D}", pins: []) { [weak self] in
            guard let self else { return }
            // Once the stack is pasting (or done and archived) its order is in use: taking slots out from under the
            // Cmd-V cursor could finish it half-way. Undo then does nothing; the lane's Remove still works per item.
            guard let i = self.index(sid), sid != self.readyID else {
                self.notice = "Can't undo -- \u{201C}\(st.name)\u{201D} is already pasting"
                return
            }
            if created, self.stacks[i].slots.allSatisfy({ tokens.contains($0.token) }) {
                if sid == self.collectingID { self.stopCollecting() }
                self.stacks.remove(at: i)
                if self.selectedID == sid { self.selectedID = self.stacks.first?.id }
            } else {
                self.stacks[i].slots.removeAll { tokens.contains($0.token) }
            }
            self.save()
            self.onPinsReleased()
        }
        return SendResult(stack: sid, added: n, created: created)
    }

    private func fits(_ clip: Clip, in st: ClipStack) -> Bool {
        if st.slots.count >= Self.maxItems { notice = "\(st.name) is full (\(Self.maxItems))"; return false }
        let bytes = st.clipIDs.compactMap { store.clip($0) }.reduce(0) { $0 + $1.totalBytes }
        if bytes + clip.totalBytes > Self.maxBytes { notice = "\(st.name) is full (200 MB)"; return false }
        return true
    }

    // Remove one occurrence (rows hold its token, which stays right if the stack shifts meanwhile).
    func remove(token: UUID) {
        for i in stacks.indices {
            guard let j = stacks[i].slots.firstIndex(where: { $0.token == token }) else { continue }
            let isReady = stacks[i].id == readyID
            stacks[i].slots.remove(at: j)
            save()
            if isReady {
                if j < cursor { cursor -= 1 }
                if cursor >= stacks[i].slots.count { finish() }
                else if j == cursor && ownsClipboard { loadHead() }
            }
            onPinsReleased()
            return
        }
    }
    func remove(_ clipID: UUID) {
        guard let st = readyStack, let j = st.slots.indices.first(where: { $0 >= cursor && st.slots[$0].clip == clipID })
        else { return }
        remove(token: st.slots[j].token)
    }
    func remove(at i: Int) {           // position in the ready stack's remaining queue
        guard let st = readyStack, st.slots.indices.contains(cursor + i) else { return }
        remove(token: st.slots[cursor + i].token)
    }

    // Move an occurrence up / down within its stack. Never moves an item across the ready stack's cursor.
    func move(token: UUID, by delta: Int) {
        for i in stacks.indices {
            guard let j = stacks[i].slots.firstIndex(where: { $0.token == token }) else { continue }
            let k = j + delta
            guard stacks[i].slots.indices.contains(k) else { return }
            let isReady = stacks[i].id == readyID
            if isReady && (j < cursor || k < cursor) { return }
            stacks[i].slots.swapAt(j, k)
            save()
            if isReady && (j == cursor || k == cursor) && ownsClipboard { loadHead() }
            return
        }
    }

    // MARK: collecting

    func collect(into id: UUID) {
        guard index(id) != nil else { return }
        if id == readyID { disarm() }      // a stack is either collecting or pasting
        collectingID = id
        selectedID = id
        laneOpen = true
        finished = nil
        notice = nil
    }
    func stopCollecting() { collectingID = nil }
    func toggleCollecting(_ id: UUID) { collectingID == id ? stopCollecting() : collect(into: id) }

    // A capture finished ingesting. `capturedChangeCount` is the pasteboard changeCount it was read at; `target` is
    // the stack that was collecting when the copy was SEEN (ingest is async: collecting may have moved since).
    func didCapture(_ clip: Clip, capturedChangeCount: Int) {
        didCapture(clip, capturedChangeCount: capturedChangeCount, into: collectingID)
    }
    func didCapture(_ clip: Clip, capturedChangeCount: Int, into target: UUID?) {
        guard let ci = index(target) else { return }
        guard fits(clip, in: stacks[ci]) else { return }
        stacks[ci].slots.append(StackSlot(clip: clip.id))
        save()
        // The copy is safe in its stack: put the ready stack's next item back, but ONLY if the clipboard still
        // holds that copy (or our own item) -- never overwrite a newer copy ShakeBoard hasn't recorded yet.
        guard isReady else { return }
        let now = pasteboard().changeCount
        guard now == capturedChangeCount || now == ownedChangeCount else { return }
        loadHead()
    }

    // MARK: ready to paste

    @discardableResult
    func arm(_ id: UUID) -> Bool {
        guard let i = index(id) else { return false }
        guard !stacks[i].slots.isEmpty else { notice = "\(stacks[i].name) is empty -- copy something into it first"; return false }
        if isReady { disarm() }
        if collectingID == id { collectingID = nil }
        // Save EVERY readable type (incl. markers like Concealed) so restore is faithful.
        original = pasteboard().readAll(maxItems: ClipLimits.maxItemsPerClip, maxRepBytes: ClipLimits.maxRepBytes,
                                        maxTotalBytes: Self.maxOriginalBytes)
        readyID = id; selectedID = id; cursor = 0; laneOpen = true
        ownedChangeCount = nil; vArmed = false; advancePending = false; isPaused = false
        session = UUID(); finished = nil
        notice = isTrusted() ? nil : "Needs Accessibility to follow \u{2318}V"
        loadHead()
        return readyID == id
    }

    // Stop pasting: the stack keeps all its items and goes back to Idle.
    func disarm() {
        guard isReady else { return }
        restoreIfStillOurs()
        endReady()
    }

    private func endReady() {
        readyID = nil; cursor = 0
        ownedChangeCount = nil; vArmed = false; advancePending = false; isPaused = false
        original = []
        session = UUID()
        if notice?.hasPrefix("Needs Accessibility") == true || notice?.contains("paused") == true { notice = nil }
    }

    // The ready stack pasted its last item: archive it (Paste Again lives under the Stacks filter).
    private func finish() {
        guard let i = index(readyID) else { endReady(); return }
        restoreIfStillOurs()
        var st = stacks.remove(at: i)
        let pasted = min(cursor, st.slots.count)
        endReady()
        st.archivedAt = now(); st.pastedCount = pasted
        archived.insert(st, at: 0)
        var dropped = false
        while archived.count > StackFile.maxArchived { archived.removeLast(); dropped = true }
        if selectedID == st.id { selectedID = stacks.first?.id }
        save()
        let f = Finished(id: st.id, name: st.name, count: st.slots.count)
        finished = f
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bannerSeconds) { [weak self] in
            MainActor.assumeIsolated { if self?.finished == f { self?.finished = nil } }
        }
        if dropped { onPinsReleased() }
    }
    func dismissFinished() { finished = nil }

    // Archived -> active again. `arm`: and Ready to paste from the first item.
    func restore(_ id: UUID, arm armIt: Bool) {
        guard let i = archived.firstIndex(where: { $0.id == id }) else { return }
        var st = archived.remove(at: i)
        st.archivedAt = nil; st.pastedCount = nil
        stacks.append(st)
        selectedID = st.id
        save()
        if armIt { arm(st.id) }
    }
    // Archive an active stack by hand.
    func archive(_ id: UUID) {
        guard let i = index(id) else { return }
        if id == readyID { disarm() }
        if id == collectingID { stopCollecting() }
        var st = stacks.remove(at: i)
        st.archivedAt = now()
        archived.insert(st, at: 0)
        while archived.count > StackFile.maxArchived { archived.removeLast() }
        if selectedID == id { selectedID = stacks.first?.id }
        save()
        onPinsReleased()
    }

    // Put the next item back after a pause (bar / lane "Resume").
    func resume() {
        guard isReady, !queue.isEmpty else { return }
        loadHead()
    }

    // MARK: Stack button / stack shortcut / quit

    // The rail's Stack button: open the lane (creating and collecting into a first stack when there are none);
    // a second click hides it again (collecting / pasting carry on).
    func railTapped() {
        if laneOpen { laneOpen = false; return }   // collecting / pasting carry on; the rail badge shows it
        laneOpen = true
        if stacks.isEmpty { collect(into: newStack()) }
    }

    // The optional stack shortcut: stop everything if anything is going on, else collect into the selected stack
    // (a new one if there are none).
    func toggle() {
        if isOn { stop(); return }
        start()
    }
    func start() {
        let id = selectedStack?.id ?? newStack()
        collect(into: id)
        laneOpen = true
    }
    // End collecting and pasting (Clear History, quit). Stacks and their items stay.
    func stop() {
        stopCollecting()
        disarm()
    }

    // MARK: keys
    // Only arm when the clipboard really is the ready stack's item: a Cmd-V of anything else (a copy the poll
    // hasn't read yet, a skipped password copy, a history paste) must not consume the stack.
    func keyDown(keyCode: Int, command: Bool, isRepeat: Bool) {
        guard isReady, !queue.isEmpty, keyCode == kVK_ANSI_V, command, !isRepeat else { return }
        guard !advancePending else { return }
        guard ownsClipboard else { pause(); return }
        vArmed = true
    }
    func keyUp(keyCode: Int) {
        guard isReady, keyCode == kVK_ANSI_V, vArmed else { return }
        vArmed = false
        guard let st = readyStack, st.slots.indices.contains(cursor) else { return }
        advancePending = true
        // Bind the advance to THIS armed period and THIS item: disarming or removing it during the beat turns the
        // advance into a no-op instead of skipping some other, unpasted item.
        let boundSession = session, boundHead = st.slots[cursor].token
        if advanceDelay <= 0 { advance(session: boundSession, head: boundHead); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + advanceDelay) { [weak self] in
            MainActor.assumeIsolated { self?.advance(session: boundSession, head: boundHead) }
        }
    }

    // Move past the item that was just pasted; load the next or finish. Re-checks ownership: if the clipboard
    // changed during the beat, the paste may not have been ours -- keep the item.
    func advance(session expectedSession: UUID? = nil, head expectedHead: UUID? = nil) {
        if let expectedSession, expectedSession != session { return }
        advancePending = false
        guard let st = readyStack, st.slots.indices.contains(cursor) else { return }
        if let expectedHead, st.slots[cursor].token != expectedHead { return }
        guard ownsClipboard else { pause(); return }
        cursor += 1
        if cursor >= st.slots.count { finish() } else { loadHead() }
    }

    private func pause() {
        isPaused = true
        notice = "Clipboard changed -- stack paused"
    }

    private func loadHead() {
        while let st = readyStack, st.slots.indices.contains(cursor) {
            if let clip = store.clip(st.slots[cursor].clip), let items = store.payload(for: clip) {
                guard let count = ClipboardWriter.write(items) else {
                    pause()   // a copy is still landing; don't clobber it -- its capture will resume us
                    return
                }
                ownedChangeCount = count
                if isPaused { isPaused = false; notice = nil }
                return
            }
            cursor += 1   // payload vanished -- skip it rather than paste the wrong thing
        }
        finish()
    }

    // Restore only if the clipboard is still the stack's, and never replace it with "nothing".
    private func restoreIfStillOurs() {
        guard ownsClipboard, !original.isEmpty else { return }
        ClipboardWriter.write(original)
    }

    // Dev-only (PERCH_DEBUG_SHOW=stacks): mark a stack Ready WITHOUT touching the clipboard, for screenshots.
    func debugMarkReady(_ id: UUID, cursor c: Int) {
        guard index(id) != nil else { return }
        if collectingID == id { collectingID = nil }
        readyID = id; cursor = c; selectedID = id
    }
}

// MARK: - Global Cmd-V watcher (needs Accessibility, which ShakeBoard already requires for the shake)

@MainActor
final class StackKeyWatcher {
    private var monitor: Any?
    func start(_ stack: PasteStack) {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak stack] e in
            MainActor.assumeIsolated {
                guard let stack, stack.isReady else { return }
                if e.type == .keyDown {
                    stack.keyDown(keyCode: Int(e.keyCode), command: e.modifierFlags.contains(.command), isRepeat: e.isARepeat)
                } else {
                    stack.keyUp(keyCode: Int(e.keyCode))
                }
            }
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

// MARK: - Stack bar (its own glass panel under the menu bar)

struct StackBarView: View {
    @ObservedObject var stack: PasteStack
    @EnvironmentObject private var themes: ThemeStore
    let width: CGFloat
    var onHoverCard: (UUID?) -> Void = { _ in }
    var onPointerExit: () -> Void = { }
    // After any button: hand the keyboard straight back, so the next Cmd-V reaches the app you're pasting into.
    var onAction: () -> Void = { }
    private func act(_ f: @escaping () -> Void) -> () -> Void { { f(); onAction() } }
    private var accent: Color { themes.current.isSystem ? .accentColor : themes.current.accent.color }
    private var collecting: Color { themes.current.isSystem ? .red : themes.current.collecting.color }
    private var secondaryText: Color { themes.current.isSystem ? .secondary : themes.current.secondaryText }
    private var text: Color { themes.current.isSystem ? .primary : themes.current.text.color }
    private var card: Color { themes.current.isSystem ? Color(nsColor: .windowBackgroundColor) : themes.current.card.color }
    private var onAccent: Color {
        themes.current.isSystem ? Color(nsColor: .selectedControlTextColor) : themes.current.onAccent.color
    }

    static let cardWidth: CGFloat = 150
    static let spacing: CGFloat = 6
    static let chrome: CGFloat = 290      // leading label + resume + stop + padding
    static let collectingChip: CGFloat = 150
    static let height: CGFloat = 54       // Ready: numbered cards
    static let pillHeight: CGFloat = 38   // Collecting only / Finished: a slim pill

    enum Look: Equatable { case ready, collecting, finished, hidden }
    @MainActor static func look(_ s: PasteStack) -> Look {
        if s.isReady { return .ready }
        if s.isCollecting { return .collecting }
        if s.finished != nil { return .finished }
        return .hidden
    }
    static func height(for look: Look) -> CGFloat { look == .ready ? height : pillHeight }

    @MainActor static func idealWidth(_ s: PasteStack, screenWidth: CGFloat) -> CGFloat {
        let want: CGFloat
        switch look(s) {
        case .ready:
            let n = s.queue.count
            want = chrome + (s.isCollecting ? collectingChip : 0) + CGFloat(max(n, 1)) * (cardWidth + spacing)
        case .collecting: want = 620
        case .finished: want = 470
        case .hidden: want = 300
        }
        return min(want, screenWidth - 24)
    }
    private var visibleCount: Int {
        let room = width - Self.chrome - (stack.isCollecting ? Self.collectingChip : 0)
        return max(Int(room / (Self.cardWidth + Self.spacing)), 1)
    }

    var body: some View {
        Group {
            switch Self.look(stack) {
            case .ready: readyBar
            case .collecting: collectingPill
            case .finished: finishedPill
            case .hidden: Color.clear
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: Self.height(for: Self.look(stack)))
        .shakeboardGlass(cornerRadius: Self.look(stack) == .ready ? GlassMetrics.panelRadius : Self.pillHeight / 2)
        .foregroundStyle(themes.current.isSystem ? Color.primary : themes.current.text.color)
        .tint(themes.current.isSystem ? nil : themes.current.accent.color)
        .onHover { inside in if !inside { onHoverCard(nil); onPointerExit() } }
    }

    // MARK: collecting only (mockup C1)
    private var collectingPill: some View {
        let st = stack.collectingStack
        let last = st.flatMap { $0.clipIDs.last }.flatMap { stack.clipPreview($0) }
        return HStack(spacing: 8) {
            Circle().fill(collecting).frame(width: 9, height: 9)
            (Text("Collecting").fontWeight(.semibold) + Text(" into ").foregroundColor(secondaryText)
                + Text(st?.name ?? "").fontWeight(.semibold))
                .font(.system(size: 12)).lineLimit(1)
            Text("\(st?.slots.count ?? 0) item\(st?.slots.count == 1 ? "" : "s")").font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(text.opacity(0.08)))
            if let n = stack.notice {
                Text(n).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
            } else if let last {
                Text("+ " + last).font(.system(size: 10)).foregroundStyle(secondaryText).lineLimit(1)
            } else {
                Text("\u{2318}C adds here \u{00B7} \u{2318}V pastes as usual").font(.system(size: 10)).foregroundStyle(secondaryText)
            }
            Spacer(minLength: 4)
            if let id = st?.id {
                Button(action: act { stack.arm(id) }) {
                    Label("Ready to paste", systemImage: "play.fill").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(accent)).foregroundStyle(onAccent)
                }
                .buttonStyle(.plain).disabled(st?.slots.isEmpty ?? true)
                .help("Stop collecting and paste this stack in order with \u{2318}V")
            }
            Button(action: act { stack.stopCollecting() }) {
                Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(collecting)
                    .frame(width: 20, height: 20).background(Circle().strokeBorder(collecting.opacity(0.5)))
            }
            .buttonStyle(.plain).help("Stop collecting (the stack keeps what it has)")
            .accessibilityLabel("Stop collecting")
        }
    }

    // MARK: finished (mockup C5)
    private var finishedPill: some View {
        let f = stack.finished
        return HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").foregroundStyle(.green).font(.system(size: 13))
            (Text("\(f?.name ?? "Stack") pasted").fontWeight(.semibold) + Text(" \(f?.count ?? 0) of \(f?.count ?? 0)").foregroundColor(secondaryText))
                .font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            if let id = f?.id {
                Button(action: act { stack.restore(id, arm: true) }) {
                    Label("Paste again", systemImage: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(accent)).foregroundStyle(onAccent)
                }
                .buttonStyle(.plain)
            }
            Button(action: act { stack.dismissFinished() }) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 18, height: 18)
            }
            .buttonStyle(.plain).foregroundStyle(secondaryText).help("Dismiss -- the stack is under Stacks in the strip")
        }
    }

    // MARK: ready (mockup C2-C4)
    private var readyBar: some View {
        let entries = stack.queuedEntries
        let st = stack.readyStack
        return HStack(spacing: 8) {
            if let c = stack.collectingStack {
                HStack(spacing: 6) {
                    Circle().fill(collecting).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Collecting").font(.system(size: 10, weight: .semibold))
                        Text("\(c.name) \u{00B7} \(c.slots.count)").font(.system(size: 9)).lineLimit(1)
                    }
                    .foregroundStyle(collecting)
                }
                .padding(.horizontal, 8).frame(width: Self.collectingChip - 12, height: 38, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(collecting.opacity(0.1)))
            }
            VStack(alignment: .leading, spacing: 1) {
                Label { Text(st?.name ?? "Stack").foregroundStyle(.primary).lineLimit(1) } icon: {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(accent)
                }
                .font(.system(size: 11, weight: .semibold))
                Text(stack.isPaused ? (stack.notice ?? "Paused") : (stack.notice ?? "Ready \u{00B7} \(entries.count) left"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(stack.isPaused || stack.notice != nil ? Color.orange : accent).lineLimit(2)
            }
            .frame(width: 110, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.spacing) {
                    ForEach(entries) { e in card(e) }
                }
                .padding(.vertical, 2)
                .smoothWheel(.horizontal)
            }
            .overlay(alignment: .trailing) {
                if entries.count > visibleCount {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.clear, card.opacity(0.6)],
                                       startPoint: .leading, endPoint: .trailing).frame(width: 36)
                        Text("+\(entries.count - visibleCount)")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .shakeboardGlassCapsule()
                    }
                    .allowsHitTesting(false)
                }
            }
            if stack.isPaused {
                Button("Resume", action: act { stack.resume() })
                    .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3).shakeboardGlassCapsule(tint: accent.opacity(0.3))
            }
            Button(action: act { stack.disarm() }) {
                Label("Stop", systemImage: "stop.fill").font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3).shakeboardGlassCapsule()
            }
            .buttonStyle(.plain)
            .help("Stop pasting -- the stack keeps its items (restores your clipboard if ShakeBoard still owns it)")
        }
    }

    private func card(_ e: PasteStack.Entry) -> some View {
        let clip = e.clip
        let next = e.next
        return HStack(spacing: 6) {
            Text("\(e.position + 1)").font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 17, height: 17)
                .background(Circle().fill(next ? accent : text.opacity(0.1)))
                .foregroundStyle(next ? onAccent : secondaryText)
            VStack(alignment: .leading, spacing: 0) {
                Text(clip.kind == .image ? "Image" : clip.preview).font(.system(size: 11)).lineLimit(1)
                Text(next ? "next on \u{2318}V" : (clip.sourceAppName ?? ""))
                    .font(.system(size: 9, weight: next ? .semibold : .regular))
                    .foregroundStyle(next ? accent : secondaryText).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(width: Self.cardWidth, height: 38)
        .modifier(PerchGlass(shape: RoundedRectangle(cornerRadius: GlassMetrics.cardRadius, style: .continuous),
                             tint: next ? accent.opacity(0.28) : nil, role: .card))
        .opacity(next ? 1 : 0.85)
        .contextMenu { Button("Remove from Stack", action: act { stack.remove(token: e.token) }) }
        .onHover { inside in onHoverCard(inside ? clip.id : nil) }
        .help("Click the bar, then hover a card and press Space to preview it")
    }
}

// Key-capable (never main, never activating) so a hovered card can be previewed with Space. Like the shelf it
// only becomes key on a click, and gives the keyboard back when the pointer leaves.
final class StackBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StackBarController {
    private let stack: PasteStack
    private let themes: ThemeStore
    private var panel: NSPanel?
    var quickLook: QuickLookController?
    var store: ClipStore?
    private(set) var hoveredID: UUID?
    private var keyMonitor: Any?
    private var keyLease: KeyLease?
    private var hosting: NSHostingView<AnyView>?
    private var bag: AnyCancellable?
    private var themeBag: AnyCancellable?

    init(stack: PasteStack, themes: ThemeStore) {
        self.stack = stack
        self.themes = themes
        bag = stack.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        themeBag = themes.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
    }

    // True while the strip is on screen: the strip's own Stack lane shows the queue then, so the bar steps
    // aside instead of showing it twice. It comes back as soon as the strip hides.
    var suppressed = false {
        didSet { if suppressed != oldValue { refresh() } }
    }

    var isVisible: Bool { panel?.isVisible ?? false }
    var isPointerInside: Bool { panel.map { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) } ?? false }
    var occupiedHeight: CGFloat { isVisible ? (panel?.frame.height ?? StackBarView.height) + 6 : 0 }

    func refresh() {
        let look = StackBarView.look(stack)
        guard look != .hidden, !suppressed else {
            if quickLook?.isActive(for: .stack) == true { quickLook?.close() }
            panel?.orderOut(nil); return
        }
        let mouse = NSEvent.mouseLocation
        let screen = (panel?.screen) ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let w = StackBarView.idealWidth(stack, screenWidth: vf.width)
        let h = StackBarView.height(for: look)
        let p = panel ?? makePanel()
        let view = AnyView(ThemedHostingRoot(themes: themes) {
            StackBarView(stack: stack, width: w,
                         onHoverCard: { [weak self] id in self?.hoveredID = id },
                         onPointerExit: { [weak self] in self?.pointerLeft() },
                         onAction: { [weak self] in self?.releaseKey() })
        })
        if let hosting { hosting.rootView = view } else {
            let h = NSHostingView(rootView: view); hosting = h; p.contentView = h
        }
        p.setFrame(NSRect(x: (vf.midX - w / 2).rounded(), y: vf.maxY - Layout.dropDownTopInset - h,
                          width: w, height: h), display: true)
        ThemeAppearance.apply(themes.current, to: p)
        if !p.isVisible { p.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let p = StackBarPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = false       // a click makes it key (nonactivating) so Space reaches it
        panel = p
        let lease = KeyLease(window: p)
        lease.isHeld = { [weak self] in
            guard let ql = self?.quickLook else { return false }
            return ql.isShowing(for: .stack) || ql.isPending(for: .stack)
        }
        keyLease = lease
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            return MainActor.assumeIsolated { self.handleKey(keyCode: Int(e.keyCode)) ? nil : e }
        }
        return p
    }

    // Space previews the hovered card (else the next one); Esc closes the preview, then releases the keyboard.
    @discardableResult
    func handleKey(keyCode: Int) -> Bool {
        guard let ql = quickLook, let store else { return false }
        keyLease?.touch()
        switch keyCode {
        case kVK_Space:
            if ql.isActive(for: .stack) { ql.close(); return true }
            guard let id = hoveredID ?? stack.queue.first, let clip = store.clip(id) else { return true }
            ql.openClips([clip], store: store, owner: .stack)
            return true
        case kVK_Escape:
            if ql.isActive(for: .stack) { ql.close() } else { releaseKey() }
            return true
        default:
            return false
        }
    }

    // Dev-only: write the bar's own rendering (scripts can't screen-record).
    func snapshot(to url: URL) {
        guard let v = panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private func pointerLeft() {
        if quickLook?.isActive(for: .stack) != true { releaseKey() }
    }
    func releaseKey() {
        guard let panel else { return }
        relinquishKey(panel)
    }
}
