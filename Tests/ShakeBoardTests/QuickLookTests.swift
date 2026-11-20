//
//  QuickLookTests.swift
//  Space = Quick Look: target resolution, selection, preview session, temp-file lifecycle, and the
//  strip / stack key handling -- with a fake presenter (no QLPreviewView, no windows shown).
//

import XCTest
import AppKit
import Carbon
@testable import ShakeBoard

@MainActor
final class FakePresenter: PreviewPresenter {
    var shown: [PreviewSession] = []
    var updates: [PreviewSession] = []
    var closes = 0
    var isShowing = false
    func show(_ s: PreviewSession) { shown.append(s); isShowing = true }
    func update(_ s: PreviewSession) { updates.append(s) }
    func close() { closes += 1; isShowing = false }
}

@MainActor
final class QuickLookTests: XCTestCase {
    private var tmp: URL!
    private var fake: FakePresenter!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardQLTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        fake = FakePresenter()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private var tempRoot: URL { tmp.appendingPathComponent("tmp") }
    private var dataDir: URL { tmp.appendingPathComponent("data") }
    private func makeController() -> QuickLookController {
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let root = tempRoot, data = dataDir
        return QuickLookController(presenter: fake, makeTemp: { PreviewTempDir(root: root, dataDir: data) })
    }
    // Clip previews materialize off main; wait for the session (or its absence) to settle.
    private func waitFor(_ cond: @escaping () -> Bool, _ what: String = "condition") {
        let deadline = Date().addingTimeInterval(5)
        while !cond() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(cond(), what)
    }
    private func previewDirs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: tempRoot.path)) ?? []).filter { $0.hasPrefix(PreviewTempDir.prefix) }
    }
    private func item(_ name: String, missing: Bool = false) -> ShelfItem {
        ShelfItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(name)"), bookmark: Data(), missing: missing)
    }

    // MARK: shelf targets + selection

    func testResolve_hoverWinsForSingle_multiSelectionIsAListStartingAtHover_missingSkipped() {
        let a = item("a"), b = item("b", missing: true), c = item("c"), d = item("d")
        let items = [a, b, c, d]
        XCTAssertEqual(ShelfPreviewTargets.resolve(items: items, selected: [a.id], hovered: c.id).ids, [c.id])
        XCTAssertEqual(ShelfPreviewTargets.resolve(items: items, selected: [a.id], hovered: nil).ids, [a.id])
        let multi = ShelfPreviewTargets.resolve(items: items, selected: [d.id, a.id, b.id], hovered: d.id)
        XCTAssertEqual(multi.ids, [a.id, d.id], "shelf order, missing skipped")
        XCTAssertEqual(multi.start, 1, "starts on the hovered item")
        XCTAssertTrue(ShelfPreviewTargets.resolve(items: items, selected: [], hovered: b.id).ids.isEmpty, "missing never previews")
    }

    func testStep_movesOverPresentItemsAndClamps() {
        let a = item("a"), b = item("b", missing: true), c = item("c")
        let items = [a, b, c]
        XCTAssertEqual(ShelfPreviewTargets.step(items: items, from: a.id, by: 1), c.id, "skips missing")
        XCTAssertEqual(ShelfPreviewTargets.step(items: items, from: c.id, by: 1), c.id, "clamps at the end")
        XCTAssertEqual(ShelfPreviewTargets.step(items: items, from: nil, by: -1), c.id)
    }

    func testShelfClick_finderStyle() throws {
        let model = ShelfModel(baseDir: dataDir)
        var urls: [URL] = []
        for n in ["1", "2", "3"] {
            let u = tmp.appendingPathComponent(n); try Data(n.utf8).write(to: u); urls.append(u)
        }
        model.add(urls)
        let (i1, i2, i3) = (model.items[0], model.items[1], model.items[2])
        model.click(i1, command: false, shift: false)
        XCTAssertEqual(model.selected, [i1.id])
        model.click(i3, command: false, shift: false)
        XCTAssertEqual(model.selected, [i3.id], "plain click replaces")
        model.click(i1, command: true, shift: false)
        XCTAssertEqual(model.selected, [i1.id, i3.id], "Command-click adds")
        model.click(i3, command: false, shift: true)
        XCTAssertEqual(model.selected, [i1.id, i2.id, i3.id], "Shift-click selects the range from the anchor")
        model.click(i2, command: false, shift: false); model.click(i2, command: false, shift: false)
        XCTAssertEqual(model.selected, [i2.id], "a plain click never deselects (a later drag stays scoped)")
        model.click(i2, command: true, shift: false)
        XCTAssertTrue(model.selected.isEmpty, "Command-click is the only toggle")
        model.click(i1, command: false, shift: false)
        model.selectOnly(nil)                                  // empty-space click
        XCTAssertTrue(model.selected.isEmpty)
        XCTAssertEqual(model.dragURLs().count, 3, "nothing selected = drag everything, as before")
    }

    // MARK: controller + temp lifecycle

    func testController_openMoveRetargetClose_cleansTemp() {
        let ql = makeController()
        var closedOwner: PreviewOwner?
        ql.onOwnerClosed = { closedOwner = $0 }
        ql.open(owner: .stack, start: 5) { t in
            [t!.write(Data("a".utf8), name: "a.txt")!, t!.write(Data("b".utf8), name: "b.txt")!]
        }
        XCTAssertEqual(fake.shown.count, 1)
        XCTAssertEqual(fake.shown[0].index, 1, "start clamped")
        XCTAssertTrue(ql.isShowing(for: .stack))
        XCTAssertFalse(ql.isShowing(for: .shelf))
        XCTAssertEqual(previewDirs().count, 1)
        ql.move(-5)
        XCTAssertEqual(ql.session?.index, 0)
        ql.retarget { t in [t!.write(Data("c".utf8), name: "c.txt")!] }
        XCTAssertEqual(previewDirs().count, 1, "old temp dir removed on retarget")
        XCTAssertEqual(fake.updates.last?.current?.lastPathComponent, "c.txt")
        ql.close()
        XCTAssertEqual(fake.closes, 1)
        XCTAssertTrue(previewDirs().isEmpty, "temp files deleted on close")
        XCTAssertEqual(closedOwner, .stack)
        XCTAssertFalse(ql.isShowing)
    }

    func testController_nothingToShow_showsNothingAndLeavesNoTemp() {
        let ql = makeController()
        ql.open(owner: .shelf) { _ in [] }
        XCTAssertTrue(fake.shown.isEmpty)
        XCTAssertFalse(ql.isShowing)
        XCTAssertTrue(previewDirs().isEmpty)
    }

    func testTempDir_neverInsideShakeBoardData_andSweepRemovesDeadOnly() throws {
        XCTAssertNil(PreviewTempDir(root: dataDir.appendingPathComponent("Clips"), dataDir: dataDir),
                     "previews can never land in Shelf/ or Clips/")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let dead = tempRoot.appendingPathComponent("\(PreviewTempDir.prefix)999999-\(UUID().uuidString)")
        let live = tempRoot.appendingPathComponent("\(PreviewTempDir.prefix)424242-\(UUID().uuidString)")
        let other = tempRoot.appendingPathComponent("SomethingElse")
        for d in [dead, live, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        PreviewTempDir.sweep(root: tempRoot, isAlive: { $0 == 424242 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a live ShakeBoard's previews are left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: clip resolution

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

    func testResolver_imageTextRichAndFiles() throws {
        let store = ClipStore(baseDir: dataDir); store.load()
        let temp = PreviewTempDir(root: tempRoot.deletingLastPathComponent(), dataDir: dataDir)!
        defer { temp.remove() }
        let img = ingest(store, [[RawRep(type: ClipTypes.png, data: imageData(4, 4, type: .png))]])
        let imgURLs = ClipPreviewResolver.urls(for: img, store: store, temp: temp)
        XCTAssertEqual(imgURLs.map(\.pathExtension), ["png"])
        XCTAssertTrue(imgURLs[0].path.hasPrefix(temp.url.path), "exposed in the preview temp dir, not Clips/")
        let sidecar = store.imageURL(for: img)!
        let ino = { (u: URL) in (try? FileManager.default.attributesOfItem(atPath: u.path)[.systemFileNumber] as? Int) ?? -1 }
        XCTAssertEqual(ino(imgURLs[0]), ino(sidecar), "hard link to the sidecar, not a copy")

        let rtf = RawRep(type: ClipTypes.rtf, data: Data("{\\rtf1 hi}".utf8))
        let rich = ingest(store, [[rtf, textRep("hi")]])
        XCTAssertEqual(ClipPreviewResolver.urls(for: rich, store: store, temp: temp).first?.pathExtension, "rtf",
                       "richest representation wins")
        let plain = ingest(store, [[textRep("just text")]])
        let txt = ClipPreviewResolver.urls(for: plain, store: store, temp: temp)
        XCTAssertEqual(txt.first?.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: txt[0], encoding: .utf8), "just text")

        let real = tmp.appendingPathComponent("Report.pdf"); try Data("pdf".utf8).write(to: real)
        let files = ingest(store, [[RawRep(type: ClipTypes.fileURL, data: Data(real.absoluteString.utf8))],
                                   [RawRep(type: ClipTypes.fileURL, data: Data("file:///nope/gone.pdf".utf8))]])
        XCTAssertEqual(ClipPreviewResolver.urls(for: files, store: store, temp: temp), [real],
                       "files preview in place; missing ones skipped")
    }

    // MARK: strip keys

    private func key(_ code: Int, _ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: UInt16(code))!
    }

    private func makeStrip(_ store: ClipStore, _ ql: QuickLookController) -> StripController {
        let pins = ClipPins(baseDir: dataDir); pins.load()
        let state = StripState(shelf: ShelfModel(baseDir: dataDir), store: store, pins: pins)
        let c = StripController(state: state)
        c.quickLook = ql
        return c
    }

    func testStrip_spacePreviewsOnlyWithEmptySearch_andFollowsCursor() {
        let store = ClipStore(baseDir: dataDir); store.load()
        _ = ingest(store, [[textRep("older")]])
        _ = ingest(store, [[textRep("newer")]])
        let ql = makeController()
        let strip = makeStrip(store, ql)
        strip.state.resetCursor()

        strip.state.query = "ne"
        XCTAssertFalse(strip.handleKey(key(kVK_Space, " ")), "with a search, Space types into the field")
        XCTAssertFalse(ql.isShowing)

        strip.state.query = ""
        strip.state.resetCursor()
        XCTAssertTrue(strip.handleKey(key(kVK_Space, " ")))
        waitFor({ ql.isShowing(for: .shelf) }, "preview shown")
        XCTAssertEqual(try String(contentsOf: ql.session!.current!, encoding: .utf8), "newer")
        XCTAssertTrue(strip.handleKey(key(kVK_RightArrow, "")))
        waitFor({ (try? String(contentsOf: ql.session!.current!, encoding: .utf8)) == "older" }, "preview follows")
        XCTAssertTrue(strip.handleKey(key(kVK_Escape, "")))
        XCTAssertFalse(ql.isShowing, "Esc closes the preview first")
        XCTAssertTrue(previewDirs().isEmpty)
    }

    // MARK: stack bar keys

    func testStackBar_spacePreviewsHoveredOrNext() {
        let store = ClipStore(baseDir: dataDir); store.load()
        let stack = PasteStack(store: store, baseDir: dataDir)
        let pb = FakePasteboard(); stack.pasteboard = { pb }; stack.isTrusted = { true }
        let oldPB = ClipboardWriter.pasteboard; ClipboardWriter.pasteboard = pb
        defer { ClipboardWriter.pasteboard = oldPB }
        stack.start()
        for t in ["first", "second"] {
            pb.set([[textRep(t)]]); let count = pb.changeCount
            stack.didCapture(ingest(store, [[textRep(t)]]), capturedChangeCount: count)
        }
        stack.arm(stack.collectingID!)
        let ql = makeController()
        let bar = StackBarController(stack: stack, themes: testThemes())
        bar.quickLook = ql; bar.store = store
        XCTAssertTrue(bar.handleKey(keyCode: kVK_Space))
        waitFor({ ql.isShowing(for: .stack) }, "preview shown")
        XCTAssertEqual(try String(contentsOf: ql.session!.current!, encoding: .utf8), "first", "no hover: the next card")
        XCTAssertTrue(bar.handleKey(keyCode: kVK_Space))
        XCTAssertFalse(ql.isShowing, "Space again closes")
        XCTAssertTrue(bar.handleKey(keyCode: kVK_Escape))
        XCTAssertFalse(bar.handleKey(keyCode: kVK_ANSI_A), "other keys are not swallowed")
    }

    // MARK: keyboard release (review HIGH 1)

    private func keyPanel() -> NSPanel {
        let p = ShelfPanel(contentRect: NSRect(x: -3000, y: -3000, width: 40, height: 40),
                           styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.becomesKeyOnlyIfNeeded = false
        p.orderFrontRegardless(); p.makeKey()
        return p
    }
    private func spin(_ seconds: TimeInterval) {
        let exp = expectation(description: "spin")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 5)
    }

    // Codex round 2: a stack preview still materializing is "open" -- Esc cancels it (never lets it land
    // later) instead of releasing the keyboard.
    func testStackBar_escapeCancelsAPendingPreview() {
        let store = ClipStore(baseDir: dataDir); store.load()
        let stack = PasteStack(store: store, baseDir: dataDir)
        let pb = FakePasteboard(); stack.pasteboard = { pb }; stack.isTrusted = { true }
        let oldPB = ClipboardWriter.pasteboard; ClipboardWriter.pasteboard = pb
        defer { ClipboardWriter.pasteboard = oldPB }
        stack.start()
        pb.set([[textRep("only")]]); let count = pb.changeCount
        stack.didCapture(ingest(store, [[textRep("only")]]), capturedChangeCount: count)
        stack.arm(stack.collectingID!)
        let ql = makeController()
        let bar = StackBarController(stack: stack, themes: testThemes())
        bar.quickLook = ql; bar.store = store
        XCTAssertTrue(bar.handleKey(keyCode: kVK_Space))         // pending
        XCTAssertTrue(ql.isActive(for: .stack))
        XCTAssertTrue(bar.handleKey(keyCode: kVK_Escape))        // before it lands
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(ql.isShowing, "the cancelled preview never appears")
        XCTAssertTrue(fake.shown.isEmpty)
        XCTAssertTrue(previewDirs().isEmpty)
        stack.stop()
    }

    func testStripToggleCancelsBlockedMaterializationAndDeletesTemp() {
        let store = ClipStore(baseDir: dataDir); store.load()
        let clip = ingest(store, [[textRep("pending")]])
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let root = tempRoot, data = dataDir
        let ql = QuickLookController(
            presenter: fake,
            makeTemp: { PreviewTempDir(root: root, dataDir: data) },
            materialize: { plan, temp in
                started.signal()
                _ = release.wait(timeout: .now() + 5)
                let urls = ClipPreviewResolver.materialize(plan, into: temp)
                finished.signal()
                return urls
            })
        let strip = makeStrip(store, ql)
        strip.state.cursor = .clip(clip.id)

        strip.togglePreview()
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(ql.isPending(for: .shelf))
        strip.togglePreview()
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        waitFor({ self.previewDirs().isEmpty }, "cancelled preview temp removed")

        XCTAssertFalse(ql.isPending(for: .shelf))
        XCTAssertFalse(ql.isShowing)
        XCTAssertTrue(fake.shown.isEmpty)
    }

    func testRelinquishKey_dropsKeyButStaysVisible() throws {
        let p = keyPanel()
        defer { p.orderOut(nil) }
        guard p.isKeyWindow else { throw XCTSkip("no key window possible in this session") }
        relinquishKey(p)
        XCTAssertFalse(p.isKeyWindow)
        XCTAssertTrue(p.isVisible, "the shelf is not hidden to give the keyboard back")
    }

    private func testThemes() -> ThemeStore {
        let suite = "shakeboard.tests.stackbar-theme.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ThemeStore(prefs: PerchPrefs(defaults: defaults))
    }

    func testKeyLease_releasesAfterIdle_unlessHeld() throws {
        let p = keyPanel()
        defer { p.orderOut(nil) }
        guard p.isKeyWindow else { throw XCTSkip("no key window possible in this session") }
        let lease = KeyLease(window: p, idle: 0.15)
        var held = true
        lease.isHeld = { held }
        lease.touch()
        spin(0.4)
        XCTAssertTrue(p.isKeyWindow, "kept while a preview is open")
        held = false
        spin(0.4)
        XCTAssertFalse(p.isKeyWindow, "a click with no follow-up gives the keyboard back")
        XCTAssertTrue(p.isVisible)
    }

    func testShelf_previewCloseReleasesKeyEvenWithPointerInside() throws {
        let suite = "shakeboard.tests.app-delegate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppDelegate(defaults: defaults)
        app.setupPanel()
        guard let p = app.shelfPanelForTesting else { return XCTFail("no panel") }
        defer { p.orderOut(nil) }
        p.orderFrontRegardless(); p.makeKey()
        guard p.isKeyWindow else { throw XCTSkip("no key window possible in this session") }
        app.previewClosed(.shelf)
        XCTAssertFalse(p.isKeyWindow)
    }

    // MARK: temp lifecycle (review HIGH 2 / MEDIUM 3)

    func testClipPreviews_closedForClearHistory_andTempDeleted() {
        let store = ClipStore(baseDir: dataDir); store.load()
        let c = ingest(store, [[textRep("secret-ish note")]])
        let ql = makeController()
        ql.openClips([c], store: store, owner: .shelf)
        waitFor({ ql.isShowing(for: .shelf) }, "shown")
        XCTAssertEqual(previewDirs().count, 1)
        ql.closeClipPreviews()                           // what Clear History / quit call first
        XCTAssertFalse(ql.isShowing)
        XCTAssertTrue(previewDirs().isEmpty, "no preview text survives Clear History")
    }

    func testClipPreview_closedBeforeMaterializeFinishes_showsNothingLeavesNothing() {
        let store = ClipStore(baseDir: dataDir); store.load()
        let c = ingest(store, [[textRep("late")]])
        let ql = makeController()
        ql.openClips([c], store: store, owner: .shelf)
        ql.close()                                       // before the background work lands
        waitFor({ self.previewDirs().isEmpty }, "temp removed")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(fake.shown.isEmpty, "a stale request never shows")
        XCTAssertFalse(ql.isShowing)
    }

    func testController_deinitRemovesTemp() {
        var ql: QuickLookController? = makeController()
        ql!.open(owner: .shelf) { t in [t!.write(Data("x".utf8), name: "x.txt")!] }
        XCTAssertEqual(previewDirs().count, 1)
        ql = nil
        XCTAssertTrue(previewDirs().isEmpty, "best-effort cleanup in deinit")
    }

    // MARK: strip cursor by card ID (v1 review MEDIUM 4, carried over)

    private func previewText(_ ql: QuickLookController) -> String? {
        ql.session?.current.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func testStrip_newClipAtFront_keepsCursorAndPreviewOnSameClip() {
        let store = ClipStore(baseDir: dataDir); store.load()
        _ = ingest(store, [[textRep("older")]])
        let watched = ingest(store, [[textRep("watched")]])
        let ql = makeController()
        let strip = makeStrip(store, ql)
        strip.state.resetCursor()
        XCTAssertEqual(strip.state.cursor, .clip(watched.id))
        strip.togglePreview()
        waitFor({ self.previewText(ql) == "watched" }, "previewing")
        _ = ingest(store, [[textRep("brand new copy")]])       // lands at the front
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(strip.state.cursor, .clip(watched.id), "cursor stays on the same clip")
        XCTAssertEqual(strip.state.sections.order.firstIndex(of: .clip(watched.id)), 1, "...now the second card")
        XCTAssertEqual(previewText(ql), "watched", "and the preview didn't jump")
    }

    func testStrip_typingSearchClosesPreview_neverRetargets() {
        let store = ClipStore(baseDir: dataDir); store.load()
        _ = ingest(store, [[textRep("alpha")]])
        _ = ingest(store, [[textRep("beta")]])
        let ql = makeController()
        let strip = makeStrip(store, ql)
        strip.state.resetCursor()
        strip.togglePreview()
        waitFor({ ql.isShowing(for: .shelf) }, "previewing")
        let shownBefore = fake.shown.count, updatesBefore = fake.updates.count
        strip.state.query = "al"
        strip.state.resetCursor()                               // what the search field's onChange does
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(ql.isShowing, "typing a search closes the preview")
        XCTAssertEqual(fake.updates.count, updatesBefore, "no retarget while searching")
        XCTAssertEqual(fake.shown.count, shownBefore)
    }

    func testStrip_cursorClipRemoved_reconcilesAndPreviewFollows() {
        let store = ClipStore(baseDir: dataDir); store.load()
        _ = ingest(store, [[textRep("stays")]])
        let goes = ingest(store, [[textRep("goes")]])
        let ql = makeController()
        let strip = makeStrip(store, ql)
        strip.state.resetCursor()
        XCTAssertEqual(strip.state.cursor, .clip(goes.id))
        strip.togglePreview()
        waitFor({ self.previewText(ql) == "goes" }, "previewing")
        store.remove(goes.id)
        waitFor({ self.previewText(ql) == "stays" }, "cursor reconciled and the preview followed")
    }

    // Switching the strip's preview from a file to a clip card is a switch, not an ending: the strip must
    // not be told its preview closed (that would hand the keyboard back mid-browse).
    func testStrip_switchingPreviewKindsDoesNotReportClose() throws {
        let store = ClipStore(baseDir: dataDir); store.load()
        _ = ingest(store, [[textRep("a clip")]])
        let ql = makeController()
        var closed: [PreviewOwner] = []
        ql.onOwnerClosed = { closed.append($0) }
        let f = tmp.appendingPathComponent("note.txt")
        try Data("file".utf8).write(to: f)
        ql.open(owner: .shelf) { _ in [f] }
        XCTAssertFalse(ql.isClipSession)
        ql.openClips(store.clips, store: store, owner: .shelf)
        waitFor({ self.previewText(ql) == "a clip" }, "now the clip")
        XCTAssertTrue(ql.isClipSession)
        XCTAssertEqual(closed, [], "same owner: no close reported")
        ql.closeClipPreviews()
        XCTAssertEqual(closed, [.shelf])
    }
}
