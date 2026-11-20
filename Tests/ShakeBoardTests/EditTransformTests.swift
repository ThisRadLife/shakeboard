//
//  EditTransformTests.swift -- v2 PR 2: Cmd-E edit and transforms always make a NEW clip (derivedFrom set,
//  original untouched); edit-mode keys go to the text view; clips.json stays readable both ways.
//  Temp dirs + fake pasteboard only.
//

import XCTest
import AppKit
import Carbon
@testable import ShakeBoard

@MainActor
final class EditTransformTests: XCTestCase {
    private var tmp: URL!
    private var pb: FakePasteboard!
    private var oldPB: PasteboardAccess!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardEdit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        pb = FakePasteboard()
        oldPB = ClipboardWriter.pasteboard
        ClipboardWriter.pasteboard = pb
    }
    override func tearDownWithError() throws {
        ClipboardWriter.pasteboard = oldPB
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStrip() -> StripController {
        let store = ClipStore(baseDir: tmp); store.load()
        let pins = ClipPins(baseDir: tmp); pins.load()
        let state = StripState(shelf: ShelfModel(baseDir: tmp), store: store, pins: pins)
        let c = StripController(state: state)
        c.frontmostPID = { 4242 }
        c.pasteDelay = 0
        return c
    }
    @discardableResult
    private func ingest(_ store: ClipStore, _ items: [[RawRep]]) -> Clip {
        let exp = expectation(description: "ingest")
        var out: Clip?
        store.ingest(CapturedClipboard(snapshot: RawSnapshot(changeCount: 1, allTypes: [], items: items),
                                       sourceBundleID: "com.example.src", sourceAppName: "Src", capturedAt: Date())) { c, _ in
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
    // Wait until the store's newest clip is not `old` (ingest commits asynchronously).
    private func waitForNewClip(_ store: ClipStore, count: Int) {
        let deadline = Date().addingTimeInterval(5)
        while store.clips.count < count, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        store.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func testTransform_makesNewClipAndLeavesOriginal() {
        let strip = makeStrip()
        let store = strip.state.store
        let orig = ingest(store, [[textRep("  hello  ")]])
        strip.state.query = "hel"
        strip.runTransform(.uppercase, on: orig.id)
        waitForNewClip(store, count: 2)
        XCTAssertEqual(store.clips.count, 2)
        let made = store.clips[0]
        XCTAssertEqual(store.fullText(for: made), "  HELLO  ")
        XCTAssertEqual(made.derivedFrom, orig.id)
        XCTAssertEqual(made.sourceBundleID, PerchID.appBundleID)
        XCTAssertEqual(store.fullText(for: store.clip(orig.id)!), "  hello  ", "the original is never changed")
        XCTAssertEqual(strip.state.cursor, .clip(made.id), "the result is selected")
        XCTAssertEqual(strip.state.query, "", "search cleared so the result is visible")
        XCTAssertNotNil(strip.state.notice)
    }

    func testTransform_plainTextDropsRichReps() {
        let strip = makeStrip()
        let store = strip.state.store
        let orig = ingest(store, [[RawRep(type: ClipTypes.rtf, data: Data("{\\rtf1 bold}".utf8)), textRep("bold")]])
        XCTAssertTrue(strip.transforms(for: orig.id).contains(.plainText))
        strip.runTransform(.plainText, on: orig.id)
        waitForNewClip(store, count: 2)
        XCTAssertEqual(store.clips[0].reps.map(\.type), [ClipTypes.plainText])
        XCTAssertEqual(store.clips.count, 2)
    }

    func testTransform_unavailableSaysSoAndSavesNothing() {
        let strip = makeStrip()
        let store = strip.state.store
        let orig = ingest(store, [[textRep("ALREADY")]])
        strip.runTransform(.uppercase, on: orig.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(store.clips.count, 1)
        XCTAssertNotNil(strip.state.notice)
    }

    func testTransforms_offeredOnlyForOneItemText() {
        let strip = makeStrip()
        let store = strip.state.store
        let multi = ingest(store, [[textRep("a")], [textRep("b")]])
        let img = ingest(store, [[RawRep(type: ClipTypes.png, data: imageData(2, 2, type: .png))]])
        XCTAssertEqual(strip.transforms(for: multi.id), [])
        XCTAssertFalse(strip.canEdit(multi.id))
        XCTAssertEqual(strip.transforms(for: img.id), [])
        XCTAssertFalse(strip.canEdit(img.id))
    }

    func testTransform_readsFullTextBeyondTheHead() {
        let strip = makeStrip()
        let store = strip.state.store
        let long = String(repeating: "word ", count: 1000) + "END   "      // > ClipHead.limit characters
        let orig = ingest(store, [[textRep(long)]])
        strip.state.loadHeadsNow()
        strip.runTransform(.trim, on: orig.id)
        waitForNewClip(store, count: 2)
        let out = store.fullText(for: store.clips[0])
        XCTAssertEqual(out?.hasSuffix("word END"), true, "the whole text, not the 3000-char head")
        XCTAssertEqual(out?.count, long.count - 3)
    }

    // MARK: edit

    func testCmdE_opensEditor_saveMakesNewClip_originalUntouched() {
        let strip = makeStrip()
        let store = strip.state.store
        let orig = ingest(store, [[textRep("draft one")]])
        var held = 0
        strip.holdOpen = { held += 1 }
        strip.state.resetCursor()
        XCTAssertTrue(strip.handleKey(key(kVK_ANSI_E, "e", .command)))
        XCTAssertEqual(held, 1, "the strip stays up and key while editing")
        XCTAssertEqual(strip.state.editing?.text, "draft one")
        strip.state.editing?.text = "draft two"
        XCTAssertTrue(strip.handleKey(key(kVK_Return, "\r", .command)))
        waitForNewClip(store, count: 2)
        XCTAssertNil(strip.state.editing)
        XCTAssertEqual(store.fullText(for: store.clips[0]), "draft two")
        XCTAssertEqual(store.clips[0].derivedFrom, orig.id)
        XCTAssertEqual(store.fullText(for: store.clip(orig.id)!), "draft one")
    }

    func testEditKeys_goToTheTextView() {
        let strip = makeStrip()
        let store = strip.state.store
        let orig = ingest(store, [[textRep("x")]])
        strip.beginEdit(orig.id)
        // Keys the strip normally owns must type while editing.
        XCTAssertFalse(strip.handleKey(key(kVK_Space, " ")))
        XCTAssertFalse(strip.handleKey(key(kVK_Return, "\r")))
        XCTAssertFalse(strip.handleKey(key(kVK_ANSI_1, "1")))
        XCTAssertFalse(strip.handleKey(key(kVK_LeftArrow, "")))
        XCTAssertFalse(strip.handleKey(key(kVK_ANSI_P, "p", .command)), "Cmd-P doesn't pin mid-edit")
        XCTAssertTrue(pb.items.isEmpty, "nothing pasted or copied")
        XCTAssertTrue(strip.handleKey(key(kVK_Escape, "\u{1b}")))
        XCTAssertNil(strip.state.editing, "Esc cancels the edit")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(store.clips.count, 1, "cancel saves nothing")
    }

    func testSaveEdit_unchangedOrEmpty() {
        let strip = makeStrip()
        let store = strip.state.store
        let orig = ingest(store, [[textRep("same")]])
        strip.beginEdit(orig.id)
        strip.saveEdit()
        XCTAssertNil(strip.state.editing, "no changes just closes")
        strip.beginEdit(orig.id)
        strip.state.editing?.text = "   \n"
        strip.saveEdit()
        XCTAssertNotNil(strip.state.editing, "an empty draft is kept, not saved")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(store.clips.count, 1)
    }

    func testEdit_imageCardRefuses() {
        let strip = makeStrip()
        let img = ingest(strip.state.store, [[RawRep(type: ClipTypes.png, data: imageData(2, 2, type: .png))]])
        strip.beginEdit(img.id)
        XCTAssertNil(strip.state.editing)
        XCTAssertNotNil(strip.state.notice)
    }

    func testClearHistory_dropsDraft() {
        let strip = makeStrip()
        let orig = ingest(strip.state.store, [[textRep("secret-ish")]])
        strip.beginEdit(orig.id)
        strip.state.forgetHeads()
        XCTAssertNil(strip.state.editing)
    }

    func testTransformMenu_enablesOnlyOffered() {
        let strip = makeStrip()
        let orig = ingest(strip.state.store, [[textRep(#"{"b":1,"a":2}"#)]])
        strip.state.loadHeadsNow()          // until the head loads, the menu is optimistic
        let menu = strip.transformMenu(for: orig.id)
        let enabled = menu.items.filter(\.isEnabled).map(\.title)
        XCTAssertTrue(enabled.contains(ClipTransform.jsonPretty.title))
        XCTAssertFalse(enabled.contains(ClipTransform.jsonMinify.title))
        XCTAssertFalse(enabled.contains(ClipTransform.markdownLink.title))
    }

    func testTransform_resultAlreadyInHistoryIsStillANewClip() {
        let strip = makeStrip()
        let store = strip.state.store
        ingest(store, [[textRep("ABC")]])
        let orig = ingest(store, [[textRep("abc")]])
        strip.runTransform(.uppercase, on: orig.id)
        waitForNewClip(store, count: 3)
        XCTAssertEqual(store.clips.count, 3, "not deduped onto the existing ABC")
        XCTAssertEqual(store.clips[0].derivedFrom, orig.id)
    }

    func testRichHyperlink_transformsUseTheURL() {
        let strip = makeStrip()
        let store = strip.state.store
        let orig = ingest(store, [[textRep("OpenAI"),
                                   RawRep(type: ClipTypes.url, data: Data("https://openai.com/x?utm_source=a&id=1".utf8))]])
        strip.state.loadHeadsNow()
        let offered = strip.transforms(for: orig.id)
        XCTAssertTrue(offered.contains(.markdownLink) && offered.contains(.stripTracking))
        strip.runTransform(.markdownLink, on: orig.id)
        waitForNewClip(store, count: 2)
        XCTAssertEqual(store.fullText(for: store.clips[0]), "[OpenAI](https://openai.com/x?utm_source=a&id=1)")
    }

    func testEdit_refusesHugeText() {
        let strip = makeStrip()
        let big = ingest(strip.state.store, [[textRep(String(repeating: "x", count: StripController.maxEditBytes + 1))]])
        strip.beginEdit(big.id)
        XCTAssertNil(strip.state.editing)
        XCTAssertNotNil(strip.state.notice)
    }

    func testTwoTransformsInFlight_bothLand() {
        let strip = makeStrip()
        let store = strip.state.store
        let a = ingest(store, [[textRep("one")]])
        let b = ingest(store, [[textRep("two")]])
        strip.runTransform(.uppercase, on: a.id)
        strip.runTransform(.uppercase, on: b.id)
        waitForNewClip(store, count: 4)
        XCTAssertEqual(Set(store.clips.compactMap { store.fullText(for: $0) }), ["one", "two", "ONE", "TWO"])
    }

    func testTransform_sourceDeletedMeanwhile_savesNothing() {
        let strip = makeStrip()
        let store = strip.state.store
        let orig = ingest(store, [[textRep("delete me")]])
        strip.runTransform(.uppercase, on: orig.id)
        strip.remove(.clip(orig.id))          // before the detached read/transform comes back
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        store.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(store.clips.isEmpty, "deleted text must not come back as a transform result")
    }

    func testStoreRefusesDerivedWhoseSourceVanished_unlessEdit() {
        let store = ClipStore(baseDir: tmp); store.load()
        let gone = UUID()
        let snap = RawSnapshot(changeCount: -1, allTypes: [], items: [[textRep("x")]])
        let cap = CapturedClipboard(snapshot: snap, sourceBundleID: nil, sourceAppName: nil, capturedAt: Date())
        let e1 = expectation(description: "transform")
        store.ingest(cap, derivedFrom: gone, requireSource: true) { c, _ in XCTAssertNil(c); e1.fulfill() }
        wait(for: [e1], timeout: 5)
        let e2 = expectation(description: "edit")
        store.ingest(cap, derivedFrom: gone) { c, _ in
            XCTAssertNotNil(c); XCTAssertNil(c?.derivedFrom, "no dangling link"); e2.fulfill()
        }
        wait(for: [e2], timeout: 5)
        store.flush()
        XCTAssertEqual(store.clips.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tmp.appendingPathComponent("Clips").path)
            .filter { UUID(uuidString: $0) != nil }.count, 1, "the refused payload was deleted")
    }

    func testSaveEdit_twiceQuickly_savesOnce() {
        let strip = makeStrip()
        let store = strip.state.store
        let orig = ingest(store, [[textRep("v1")]])
        strip.beginEdit(orig.id)
        strip.state.editing?.text = "v2"
        XCTAssertTrue(strip.handleKey(key(kVK_Return, "\r", .command)))
        _ = strip.handleKey(key(kVK_ANSI_S, "s", .command))   // ignored: the first save is still in flight
        strip.saveEdit()
        waitForNewClip(store, count: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        store.flush()
        XCTAssertEqual(store.clips.count, 2, "one new clip, not three")
        XCTAssertFalse(strip.state.editSaving)
    }

    func testRichOnlyCopy_editAndTransformUseItsText() {
        let strip = makeStrip()
        let store = strip.state.store
        let rtf = "{\\rtf1\\ansi {\\b Hello} world}"
        let orig = ingest(store, [[RawRep(type: ClipTypes.rtf, data: Data(rtf.utf8))]])
        XCTAssertTrue(strip.canEdit(orig.id))
        strip.state.loadHeadsNow()
        let caps = ingest(store, [[RawRep(type: ClipTypes.rtf, data: Data("{\\rtf1 PREVIEW}".utf8))]])
        strip.state.loadHeadsNow()
        XCTAssertTrue(strip.transforms(for: caps.id).contains(.uppercase), "a preview isn't the whole rich text")
        strip.beginEdit(orig.id)
        XCTAssertEqual(strip.state.editing?.text, "Hello world")
        strip.cancelEdit()
        strip.runTransform(.plainText, on: orig.id)
        waitForNewClip(store, count: 3)
        XCTAssertEqual(store.fullText(for: store.clips[0]), "Hello world")
    }

    func testRichText_keepsWhitespace_andBeatsBlankPlainText() {
        let strip = makeStrip()
        let store = strip.state.store
        let rtf = "{\\rtf1\\ansi     indented\\par\n}"
        let orig = ingest(store, [[textRep("   "), RawRep(type: ClipTypes.rtf, data: Data(rtf.utf8))]])
        strip.beginEdit(orig.id)
        XCTAssertEqual(strip.state.editing?.text.hasPrefix("    indented"), true, "RTF text, leading spaces kept")
    }

    func testBlankPlainText_headIsIncomplete_menuOptimistic() {
        let strip = makeStrip()
        let store = strip.state.store
        let rtf = "{\\rtf1 ALL CAPS PREVIEW}"
        let c = ingest(store, [[textRep("  "), RawRep(type: ClipTypes.rtf, data: Data(rtf.utf8))]])
        strip.state.loadHeadsNow()
        XCTAssertEqual(strip.state.heads[c.id]?.complete, false)
        XCTAssertTrue(strip.transforms(for: c.id).contains(.uppercase))
    }

    func testTransformOfOldestAtLimit_keepsItsSource() {
        let strip = makeStrip()
        let store = strip.state.store
        store.maxCount = 3
        let oldest = ingest(store, [[textRep("oldest")]])
        ingest(store, [[textRep("b")]])
        ingest(store, [[textRep("c")]])
        strip.runTransform(.uppercase, on: oldest.id)
        waitForNewClip(store, count: 4)
        XCTAssertNotNil(store.clip(oldest.id), "the source survives the result's own commit")
        XCTAssertEqual(store.clips.first?.derivedFrom, oldest.id)
    }

    // MARK: clips.json compatibility

    // The Clip schema as every build before v2 PR 2 declared it (no derivedFrom).
    private struct LegacyClip: Codable {
        let id: UUID; var kind: ClipKind; let createdAt: Date; var lastUsedAt: Date
        var sourceBundleID: String?; var sourceAppName: String?; let contentHash: String; var preview: String
        var reps: [StoredRep]; var totalBytes: Int; var pixelWidth: Int?; var pixelHeight: Int?
    }
    private struct LegacyIndex: Codable { var version: Int; var clips: [LegacyClip] }

    func testDerivedFrom_roundTripsAndBothSchemasReadEachOther() throws {
        let strip = makeStrip()
        let store = strip.state.store
        let orig = ingest(store, [[textRep("abc")]])
        strip.runTransform(.uppercase, on: orig.id)
        waitForNewClip(store, count: 2)
        store.flush()
        let indexURL = tmp.appendingPathComponent("Clips/clips.json")
        let reloaded = ClipStore(baseDir: tmp); reloaded.load()
        XCTAssertEqual(reloaded.clips.first?.derivedFrom, orig.id)
        XCTAssertNil(reloaded.clip(orig.id)?.derivedFrom)

        // An older build reads the new index (unknown key ignored) and it is still version 1.
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let legacy = try dec.decode(LegacyIndex.self, from: Data(contentsOf: indexURL))
        XCTAssertEqual(legacy.version, 1)
        XCTAssertEqual(legacy.clips.count, 2)

        // ...and the new build reads what an older build writes back (no derivedFrom key at all).
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(legacy).write(to: indexURL)
        XCTAssertFalse(try String(contentsOf: indexURL, encoding: .utf8).contains("derivedFrom"))
        let back = ClipStore(baseDir: tmp); back.load()
        XCTAssertEqual(back.clips.count, 2)
        XCTAssertTrue(back.clips.allSatisfy { $0.derivedFrom == nil })
    }
}
