//
//  StripControllerTests.swift -- v2 strip keys, paste, plain paste, drop-in, drag-out export, geometry.
//  Fake pasteboard + fake event poster; temp dirs only.
//

import XCTest
import AppKit
import Carbon
@testable import ShakeBoard

@MainActor
final class StripControllerTests: XCTestCase {
    private var tmp: URL!
    private var pb: FakePasteboard!
    private var oldPB: PasteboardAccess!

    final class Poster: EventPoster {
        var allowed = true
        var posted: [pid_t] = []
        func canPost() -> Bool { allowed }
        func postPaste(to pid: pid_t) { posted.append(pid) }
    }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardStripCtl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        pb = FakePasteboard()
        oldPB = ClipboardWriter.pasteboard
        ClipboardWriter.pasteboard = pb
    }
    override func tearDownWithError() throws {
        ClipboardWriter.pasteboard = oldPB
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStrip() -> (StripController, Poster) {
        let store = ClipStore(baseDir: tmp); store.load()
        let pins = ClipPins(baseDir: tmp); pins.load()
        let state = StripState(shelf: ShelfModel(baseDir: tmp), store: store, pins: pins)
        let c = StripController(state: state)
        let poster = Poster()
        c.poster = poster
        c.frontmostPID = { 4242 }
        c.pasteDelay = 0
        return (c, poster)
    }
    @discardableResult
    private func ingest(_ store: ClipStore, _ items: [[RawRep]]) -> Clip {
        let exp = expectation(description: "ingest")
        var out: Clip?
        store.ingest(CapturedClipboard(snapshot: RawSnapshot(changeCount: 1, allTypes: [], items: items),
                                       sourceBundleID: nil, sourceAppName: nil, capturedAt: Date())) { c, _ in
            out = c; exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        store.flush()
        return out!
    }
    private func key(_ code: Int, _ chars: String, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: UInt16(code))!
    }
    private func spin(_ s: TimeInterval = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    // MARK: stacks from the strip

    private func waitFor(_ cond: () -> Bool, _ msg: String) {
        let end = Date().addingTimeInterval(5)
        while !cond() && Date() < end { spin(0.02) }
        XCTAssertTrue(cond(), msg)
    }

    func testSplitIntoStack_makesANewStackOfDerivedPiecesInOrder() {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        let stacks = PasteStack(store: store, baseDir: tmp)
        strip.stacks = stacks
        let src = ingest(store, [[textRep("celadon\ntenmoku\n\nshino")]])
        strip.splitIntoStack(src.id, mode: nil)
        waitFor({ stacks.stacks.count == 1 }, "a new stack appears")
        let st = stacks.stacks[0]
        XCTAssertEqual(stacks.entries(of: st.id).map { store.fullText(for: $0.clip) }, ["celadon", "tenmoku", "shino"])
        XCTAssertTrue(st.clipIDs.allSatisfy { store.clip($0)?.derivedFrom == src.id }, "each piece is derived from the source")
        XCTAssertNotNil(store.clip(src.id), "the original is unchanged")
        XCTAssertFalse(stacks.isOn, "a split stack waits for Ready to paste")
    }

    func testSplitIntoStack_forcedModeAndNothingToSplit() {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        let stacks = PasteStack(store: store, baseDir: tmp)
        strip.stacks = stacks
        let one = ingest(store, [[textRep("just one thing")]])
        strip.splitIntoStack(one.id, mode: nil)
        spin()
        XCTAssertTrue(stacks.stacks.isEmpty)
        XCTAssertNotNil(strip.state.notice)
        let csv = ingest(store, [[textRep("a, b, c")]])
        strip.splitIntoStack(csv.id, mode: .commas)
        waitFor({ stacks.stacks.first?.slots.count == 3 }, "forced By Comma")
    }

    func testSplitIntoStack_clearHistoryMidSplitRollsBack() {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        let stacks = PasteStack(store: store, baseDir: tmp)
        strip.stacks = stacks
        let src = ingest(store, [[textRep((1...20).map { "piece \($0)" }.joined(separator: "\n"))]])
        strip.splitIntoStack(src.id, mode: nil)
        store.clearAll()                              // before the first piece lands
        spin(0.5)
        XCTAssertTrue(stacks.stacks.isEmpty, "no stack from a cancelled split")
        XCTAssertFalse(store.clips.contains { $0.derivedFrom == src.id }, "and no stray pieces")
    }

    func testAddToStack_newOrExisting() {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        let stacks = PasteStack(store: store, baseDir: tmp)
        strip.stacks = stacks
        let a = ingest(store, [[textRep("A")]])
        strip.addToStack(a.id, stack: nil)
        XCTAssertEqual(stacks.stacks.count, 1)
        strip.addToStack(a.id, stack: stacks.stacks[0].id)
        XCTAssertEqual(stacks.stacks[0].slots.count, 2)
        XCTAssertTrue(stacks.showsLane)
    }

    func testArmFromStrip_dismissesASummonedStrip() {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        let stacks = PasteStack(store: store, baseDir: tmp)
        stacks.pasteboard = { [unowned self] in self.pb }
        strip.stacks = stacks
        let a = ingest(store, [[textRep("A")]])
        let id = stacks.newStack(clips: [a.id])
        var dismissed = 0
        strip.dismiss = { dismissed += 1 }
        strip.state.summoned = true
        strip.armFromStrip(id)
        XCTAssertEqual(stacks.readyID, id)
        XCTAssertEqual(dismissed, 1, "the strip gets out of the way so Cmd-V reaches the target app")
        stacks.disarm()
    }

    func testReturn_writesCardDismissesAndPastesIntoFrontApp() {
        let (strip, poster) = makeStrip()
        let store = strip.state.store
        ingest(store, [[textRep("older")]])
        ingest(store, [[textRep("newest")]])
        var dismissed = 0
        strip.dismiss = { dismissed += 1 }
        strip.state.resetCursor()
        XCTAssertTrue(strip.handleKey(key(kVK_Return, "\r")))
        spin()
        XCTAssertEqual(dismissed, 1, "the strip gets out of the way first")
        XCTAssertEqual(pb.items, [[textRep("newest")]], "the newest copy is the default card")
        XCTAssertEqual(poster.posted, [4242])
    }

    func testGoHome_selectsNewestCopyAndRequestsHomeScroll() {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        ingest(store, [[textRep("older")]])
        ingest(store, [[textRep("newest")]])
        let newest = store.clips.first { $0.preview.contains("newest") }!.id
        strip.state.cursor = nil
        let before = strip.state.scrollHome
        strip.state.goHome()
        XCTAssertEqual(strip.state.cursor, .clip(newest), "every open selects the newest copy")
        XCTAssertEqual(strip.state.homeTarget, .clip(newest), "and scrolls it to the left edge")
        XCTAssertEqual(strip.state.scrollHome, before + 1)
        XCTAssertTrue(strip.state.homing, "the cursor's own scroll stands down while homing")
        let exp = expectation(description: "homing safety clears")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        XCTAssertFalse(strip.state.homing, "homing never sticks when the card list isn't there to finish it")
    }

    func testShiftReturn_pastesPlainText() {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        ingest(store, [[RawRep(type: ClipTypes.rtf, data: Data("{\\rtf1 bold}".utf8)), textRep("bold")]])
        strip.state.resetCursor()
        XCTAssertTrue(strip.handleKey(key(kVK_Return, "\r", .shift)))
        spin()
        XCTAssertEqual(pb.items, [[textRep("bold")]], "no RTF on a plain paste")
    }

    func testPlainOnly_keepsTextAndTurnsLinksIntoText_nilForImages() {
        let url = RawRep(type: ClipTypes.url, data: Data("https://e.com".utf8))
        XCTAssertEqual(ClipPaster.plainOnly([[url]]), [[RawRep(type: ClipTypes.plainText, data: Data("https://e.com".utf8))]])
        XCTAssertEqual(ClipPaster.plainOnly([[RawRep(type: ClipTypes.html, data: Data("<b>x</b>".utf8)), textRep("x")]]), [[textRep("x")]])
        XCTAssertNil(ClipPaster.plainOnly([[RawRep(type: ClipTypes.png, data: Data([1]))]]))
    }

    func testDigits_followVisibleOrder_pinnedFirst_andOnlyWithEmptySearch() {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        let a = ingest(store, [[textRep("aaa")]])
        ingest(store, [[textRep("bbb")]])
        strip.state.pins.pin(a.id)          // pinned -> card 1
        XCTAssertTrue(strip.handleKey(key(kVK_ANSI_1, "1")))
        spin()
        XCTAssertEqual(pb.items, [[textRep("aaa")]])
        strip.state.query = "b"
        XCTAssertFalse(strip.handleKey(key(kVK_ANSI_2, "2")), "with a search, digits type")
        XCTAssertTrue(strip.handleKey(key(kVK_ANSI_1, "1", .command)), "Command-digit always pastes")
        spin()
        XCTAssertEqual(pb.items, [[textRep("bbb")]], "card 1 of the filtered strip")
    }

    func testTargetChanged_reopensWithNotice_neverPastesElsewhere() {
        let (strip, poster) = makeStrip()
        ingest(strip.state.store, [[textRep("x")]])
        var pid: pid_t = 4242
        strip.frontmostPID = { pid }
        var notice: String?
        strip.reopen = { notice = $0 }
        strip.dismiss = { pid = 7 }        // the user switched apps as the strip closed
        strip.state.resetCursor()
        strip.activate(strip.state.cursor!, plain: false, copyOnly: false)
        spin()
        XCTAssertTrue(poster.posted.isEmpty)
        XCTAssertEqual(notice, "Copied -- press \u{2318}V where you want it.")
    }

    func testCommandC_copiesOnly_stripStays() {
        let (strip, poster) = makeStrip()
        ingest(strip.state.store, [[textRep("copy me")]])
        var dismissed = 0
        strip.dismiss = { dismissed += 1 }
        strip.state.resetCursor()
        XCTAssertTrue(strip.handleKey(key(kVK_ANSI_C, "c", .command)))
        XCTAssertEqual(pb.items, [[textRep("copy me")]])
        XCTAssertEqual(dismissed, 0)
        XCTAssertTrue(poster.posted.isEmpty)
        XCTAssertEqual(strip.state.notice, "Copied")
    }

    func testEscapeLadder_previewThenSearchThenFilterThenDismiss() {
        let (strip, _) = makeStrip()
        var dismissed = 0, gaveBack = 0
        strip.dismiss = { dismissed += 1 }
        strip.giveKeyBack = { gaveBack += 1 }
        strip.state.summoned = true
        strip.state.query = "x"; strip.state.filter = .code
        XCTAssertTrue(strip.handleKey(key(kVK_Escape, "\u{1b}")))
        XCTAssertEqual(strip.state.query, "")
        XCTAssertTrue(strip.handleKey(key(kVK_Escape, "\u{1b}")))
        XCTAssertEqual(strip.state.filter, .all)
        XCTAssertEqual(dismissed, 0)
        XCTAssertTrue(strip.handleKey(key(kVK_Escape, "\u{1b}")))
        XCTAssertEqual(dismissed, 1, "a summoned strip closes")
        strip.state.summoned = false
        XCTAssertTrue(strip.handleKey(key(kVK_Escape, "\u{1b}")))
        XCTAssertEqual(gaveBack, 1, "a revealed strip just gives the keyboard back")
    }

    func testPinKeyAndDelete() {
        let (strip, _) = makeStrip()
        let c = ingest(strip.state.store, [[textRep("pin me")]])
        strip.state.resetCursor()
        XCTAssertTrue(strip.handleKey(key(kVK_ANSI_P, "p", .command)))
        XCTAssertTrue(strip.state.pins.isPinned(c.id))
        XCTAssertTrue(strip.handleKey(key(kVK_Delete, "\u{7f}", .command)))
        XCTAssertFalse(strip.state.pins.isPinned(c.id), "deleting unpins first")
        XCTAssertNil(strip.state.store.clip(c.id), "...so the delete isn't refused")
    }

    func testDroppedText_becomesPinnedClip() {
        let (strip, _) = makeStrip()
        let exp = expectation(description: "drop")
        strip.ingestDropped([[textRep("parked text")]]) { ok in XCTAssertTrue(ok); exp.fulfill() }
        wait(for: [exp], timeout: 5)
        let clip = strip.state.store.clips.first
        XCTAssertEqual(clip?.preview, "parked text")
        XCTAssertEqual(strip.state.pins.ids, clip.map { [$0.id] })
        XCTAssertEqual(strip.state.sections.pinned.map(\.id), clip.map { [$0.id] })
    }

    func testDropView_readsTextTypesFromADragPasteboard() {
        let p = NSPasteboard(name: NSPasteboard.Name("ShakeBoardTest-\(UUID().uuidString)"))
        defer { p.releaseGlobally() }
        p.clearContents()
        p.setString("hello", forType: .string)
        p.setString("<b>hello</b>", forType: .html)
        let items = DropView.textItems(p)
        XCTAssertEqual(items?.count, 1)
        XCTAssertEqual(Set(items?.first?.map(\.type) ?? []), [ClipTypes.plainText, ClipTypes.html])
    }

    func testExport_textAsTypedFile_imageAsPNG_ownerOnly_andClearRemoves() throws {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        let code = ingest(store, [[textRep("def f(x):\n    return x\n")]])
        strip.state.loadHeadsNow()
        let kind = strip.state.kind(of: code)
        XCTAssertEqual(kind, .code("Python"))
        let urls = StripExport.files(for: code, kind: kind, store: store)
        XCTAssertEqual(urls.first?.pathExtension, "py")
        XCTAssertEqual(try String(contentsOf: urls[0], encoding: .utf8), "def f(x):\n    return x\n")
        let perms = (try FileManager.default.attributesOfItem(atPath: urls[0].path))[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertTrue(urls[0].path.hasPrefix(StripExport.root.path), "never inside ShakeBoard's data dir")

        let img = ingest(store, [[RawRep(type: ClipTypes.png, data: imageData(4, 4, type: .png))]])
        let pngs = StripExport.files(for: img, kind: .image, store: store)
        XCTAssertEqual(pngs.map(\.lastPathComponent), ["Image.png"])

        StripExport.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: StripExport.root.path))
    }

    func testHeads_keepNewlinesAndFindLinkTitles() {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        let t = ingest(store, [[textRep("line one\nline two")]])
        let l = ingest(store, [[RawRep(type: ClipTypes.url, data: Data("https://example.com/a".utf8)),
                                RawRep(type: ClipTypes.html, data: Data("<a href=\"https://example.com/a\">Spring Sale</a>".utf8))]])
        strip.state.loadHeadsNow()
        XCTAssertEqual(strip.state.heads[t.id]?.text, "line one\nline two")
        XCTAssertEqual(strip.state.heads[t.id]?.lines, 2)
        XCTAssertEqual(strip.state.heads[l.id]?.linkTitle, "Spring Sale")
        XCTAssertEqual(strip.state.kind(of: l), .link)
        // Clearing history forgets the cached text.
        store.clearAll()
        strip.state.reconcile()
        XCTAssertTrue(strip.state.heads.isEmpty)
    }

    func testClearHistory_keepsPinnedClips() {
        let store = ClipStore(baseDir: tmp); store.load()
        let pins = ClipPins(baseDir: tmp); pins.load()
        store.pinned = { pins.set }
        let keep = ingest(store, [[textRep("keep")]])
        ingest(store, [[textRep("drop")]])
        pins.pin(keep.id)
        store.clearAll()
        pins.prune(keeping: Set(store.clips.map(\.id)))
        XCTAssertEqual(store.clips.map(\.id), [keep.id])
        XCTAssertEqual(pins.ids, [keep.id])
    }

    func testStripFrame_spansTheVisibleFrameAtTheBottom() {
        let vf = NSRect(x: 0, y: 70, width: 1512, height: 870)
        let f = Layout.stripFrame(in: vf)
        XCTAssertEqual(f.minX, 8); XCTAssertEqual(f.maxX, 1504)
        XCTAssertEqual(f.minY, 78)
        XCTAssertEqual(f.height, 174)
        let second = Layout.stripFrame(in: NSRect(x: 1512, y: 0, width: 1920, height: 1050))
        XCTAssertEqual(second.minX, 1520, "on the screen it's shown on, not the main one")
        XCTAssertEqual(second.width, 1904)
    }

    // MARK: Codex review round 1

    func testPinThatCantBeSaved_isTakenBackAndReported() throws {
        let (strip, _) = makeStrip()
        let c = ingest(strip.state.store, [[textRep("x")]])
        // A directory where the pins file should be: every write fails.
        try FileManager.default.removeItem(at: strip.state.pins.url)
        try FileManager.default.createDirectory(at: strip.state.pins.url, withIntermediateDirectories: true)
        strip.state.cursor = .clip(c.id)
        XCTAssertTrue(strip.handleKey(key(kVK_ANSI_P, "p", .command)))
        XCTAssertFalse(strip.state.pins.isPinned(c.id), "never looks protected when it isn't on disk")
        XCTAssertTrue(strip.state.pins.lastSaveFailed)
        XCTAssertEqual(strip.state.notice, "Couldn't save the pin -- check disk space.")
    }

    func testUnpin_appliesRetentionRightAway() {
        var now = Date()
        let store = ClipStore(baseDir: tmp, clock: { now })
        store.load()
        let pins = ClipPins(baseDir: tmp); pins.load()
        store.pinned = { pins.set }
        pins.onUnpinned = { store.prune() }
        let old = ingest(store, [[textRep("old pinned")]])
        pins.pin(old.id)
        now = now.addingTimeInterval(30 * 24 * 3600)
        store.prune()
        XCTAssertNotNil(store.clip(old.id), "pinned: kept past 7 days")
        pins.unpin(old.id)
        XCTAssertNil(store.clip(old.id), "unpinned: aged out immediately, not at the next launch")
    }

    func testPendingClipPreview_followsACursorMoveBeforeItLands() {
        let (strip, _) = makeStrip()
        let fake = FakePresenter()
        let root = tmp.appendingPathComponent("ql"), data = tmp.appendingPathComponent("data")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ql = QuickLookController(presenter: fake, makeTemp: { PreviewTempDir(root: root, dataDir: data) })
        strip.quickLook = ql
        ingest(strip.state.store, [[textRep("second")]])
        ingest(strip.state.store, [[textRep("first")]])
        strip.state.resetCursor()
        XCTAssertTrue(strip.handleKey(key(kVK_Space, " ")))      // materializing "first"...
        XCTAssertTrue(strip.previewShowing, "a pending preview counts as open")
        XCTAssertTrue(strip.handleKey(key(kVK_RightArrow, "")))  // ...moved before it landed
        let deadline = Date().addingTimeInterval(5)
        func shown() -> String? { ql.session?.current.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }
        while shown() == nil && Date() < deadline { spin(0.02) }
        spin(0.2)
        XCTAssertEqual(shown(), "second", "the old request never lands over the new cursor")
        XCTAssertEqual(fake.shown.count, 1)
    }

    func testThumbCache_purgedWhenClipsGo() {
        let (strip, _) = makeStrip()
        let img = ingest(strip.state.store, [[RawRep(type: ClipTypes.png, data: imageData(4, 4, type: .png))]])
        let url = strip.state.store.imageURL(for: img)
        func load() -> NSImage? {
            let exp = expectation(description: "thumb")
            var out: NSImage?
            Task { out = await ClipThumbCache.load(url, edge: 20); exp.fulfill() }
            wait(for: [exp], timeout: 5)
            return out
        }
        XCTAssertNotNil(load())
        strip.state.forgetHeads()                                // what Clear History calls
        try? FileManager.default.removeItem(at: url!)
        XCTAssertNil(load(), "no decoded copy survives the clear")
    }

    // MARK: Codex review round 2

    func testExport_multiItemCopies_keepEveryItem() {
        let (strip, _) = makeStrip()
        let store = strip.state.store
        let text = ingest(store, [[textRep("one")], [textRep("two")]])
        let urls = StripExport.files(for: text, kind: .text, store: store)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(try? String(contentsOf: urls[0], encoding: .utf8), "one\ntwo", "joined, not cut to the first")
        let imgs = ingest(store, [[RawRep(type: ClipTypes.png, data: imageData(3, 3, type: .png))],
                                  [RawRep(type: ClipTypes.png, data: imageData(5, 5, type: .png))]])
        XCTAssertEqual(StripExport.files(for: imgs, kind: .image, store: store).count, 2)
        XCTAssertTrue(StripView.isMulti(imgs), "multi-image cards drag through the all-items handle")
        XCTAssertFalse(StripView.isMulti(text))
        let links = ingest(store, [[RawRep(type: ClipTypes.url, data: Data("https://a.com".utf8))],
                                   [RawRep(type: ClipTypes.url, data: Data("https://b.com".utf8))]])
        let lf = StripExport.files(for: links, kind: .link, store: store)
        XCTAssertEqual(try? String(contentsOf: lf[0], encoding: .utf8), "https://a.com\nhttps://b.com")
        let provider = strip.dragProvider(for: links)
        XCTAssertTrue(provider.canLoadObject(ofClass: NSURL.self), "several links drag as one file, not just the first URL")
        XCTAssertEqual(provider.suggestedName, lf[0].lastPathComponent)
        StripExport.clear()
    }
}
