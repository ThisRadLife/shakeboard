//
//  ClipboardTests.swift
//  Clipboard capture, normalization and history persistence. Uses a fake pasteboard and a temp base dir:
//  nothing here touches NSPasteboard.general or ~/Library/Application Support/ShakeBoard.
//

import XCTest
import AppKit
@testable import ShakeBoard

final class FakePasteboard: PasteboardAccess {
    var changeCount = 0
    var items: [[RawRep]] = []
    var extraTypes: Set<String> = []
    var bumpOnRead = false          // simulate a copy landing mid-read
    var bumpEveryRead = false       // pasteboard never settles while we read
    private(set) var writes = 0

    var types: Set<String> { Set(items.flatMap { $0.map(\.type) }).union(extraTypes) }

    func set(_ items: [[RawRep]], extra: Set<String> = []) {
        self.items = items; extraTypes = extra; changeCount += 1
    }
    func readSnapshot(allowed: [String], maxItems: Int, maxRepBytes: Int) -> RawSnapshot {
        let count = changeCount
        let snap = RawSnapshot(changeCount: count, allTypes: types,
                               items: items.prefix(maxItems).map { reps in
                                   allowed.compactMap { t in reps.first { $0.type == t && $0.data.count <= maxRepBytes } }
                               }.filter { !$0.isEmpty })
        if bumpOnRead { changeCount += 1; bumpOnRead = false }
        if bumpEveryRead { changeCount += 1 }
        return snap
    }
    func readAll(maxItems: Int, maxRepBytes: Int, maxTotalBytes: Int) -> [[RawRep]] {
        var total = 0
        return items.prefix(maxItems).enumerated().map { idx, reps in
            var out = reps.filter { r in
                guard r.data.count <= maxRepBytes, total + r.data.count <= maxTotalBytes else { return false }
                total += r.data.count; return true
            }
            // extra (marker) types ride on the first item, like the real pasteboard
            if idx == 0 { out += extraTypes.sorted().map { RawRep(type: $0, data: Data()) } }
            return out
        }.filter { !$0.isEmpty }
    }
    @discardableResult func write(_ items: [[RawRep]]) -> Int {
        writes += 1
        self.items = items
        extraTypes = [ClipTypes.shakeboardMarker]
        changeCount += 1
        return changeCount
    }
}

func textRep(_ s: String) -> RawRep { RawRep(type: ClipTypes.plainText, data: Data(s.utf8)) }

// A real tiny image encoded as `type` (png/tiff) so ImageIO paths run for real.
func imageData(_ w: Int, _ h: Int, type: UTType) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return type == .png ? rep.representation(using: .png, properties: [:])! : rep.tiffRepresentation!
}
import UniformTypeIdentifiers

@MainActor
final class ClipboardTests: XCTestCase {
    private var tmp: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardClipTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func makeStore() -> ClipStore {
        let s = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        s.load()
        return s
    }
    private func cap(_ items: [[RawRep]], at date: Date? = nil, app: String? = "com.apple.Safari") -> CapturedClipboard {
        CapturedClipboard(snapshot: RawSnapshot(changeCount: 1, allTypes: Set(items.flatMap { $0.map(\.type) }), items: items),
                          sourceBundleID: app, sourceAppName: "Safari", capturedAt: date ?? now)
    }
    @discardableResult
    private func ingest(_ store: ClipStore, _ c: CapturedClipboard, derivedFrom: UUID? = nil) -> (Clip?, Bool) {
        let exp = expectation(description: "ingest")
        var result: (Clip?, Bool) = (nil, false)
        store.ingest(c, derivedFrom: derivedFrom) { clip, isNew in result = (clip, isNew); exp.fulfill() }
        wait(for: [exp], timeout: 5)
        store.flush()
        return result
    }

    // MARK: filter

    func testFilter_skipsMarkersAppsAndSecureInput() {
        XCTAssertEqual(ClipFilter.skipReason(types: [ClipTypes.shakeboardMarker], bundleID: nil, secureInput: false), .shakeboardWrite)
        XCTAssertEqual(ClipFilter.skipReason(types: ["org.nspasteboard.ConcealedType", ClipTypes.plainText],
                                             bundleID: nil, secureInput: false), .secretMarker)
        XCTAssertEqual(ClipFilter.skipReason(types: [ClipTypes.plainText], bundleID: "com.1password.1password",
                                             secureInput: false), .ignoredApp)
        XCTAssertEqual(ClipFilter.skipReason(types: [ClipTypes.plainText], bundleID: nil, secureInput: true), .secureInput)
        XCTAssertNil(ClipFilter.skipReason(types: [ClipTypes.plainText], bundleID: "com.apple.Safari", secureInput: false))
    }

    func testWriter_usesShakeBoardSelfMarker() {
        let native = NSPasteboard(name: NSPasteboard.Name("ShakeBoardMarkerTest-\(UUID().uuidString)"))
        native.clearContents()
        let pb = SystemPasteboard(native)
        _ = pb.write([[textRep("ShakeBoard wrote this")]])
        XCTAssertTrue(pb.types.contains("com.thisradlife.shakeboard.self"))
    }

    func testFilter_skipsLegacyPerchSelfMarker() {
        XCTAssertEqual(
            ClipFilter.skipReason(types: ["com.dadequate.perch.self"], bundleID: nil, secureInput: false),
            .shakeboardWrite
        )
    }

    // MARK: monitor

    func testMonitor_capturesOnlyOnChange() {
        let pb = FakePasteboard()
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { ("com.apple.Safari", "Safari") })
        var got: [CapturedClipboard] = []
        m.onCapture = { got.append($0) }
        m.tick()
        XCTAssertTrue(got.isEmpty, "no change since launch -> nothing")
        pb.set([[textRep("hello")]])
        m.tick(); m.tick()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.sourceBundleID, "com.apple.Safari")
    }

    func testMonitor_skipsOwnWritesAndSecrets() {
        let pb = FakePasteboard()
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { (nil, nil) })
        var got = 0
        m.onCapture = { _ in got += 1 }
        pb.write([[textRep("shakeboard wrote this")]])
        m.tick()
        XCTAssertEqual(m.lastSkip, .shakeboardWrite)
        pb.set([[textRep("hunter2")]], extra: ["org.nspasteboard.ConcealedType"])
        m.tick()
        XCTAssertEqual(m.lastSkip, .secretMarker)
        XCTAssertEqual(got, 0)
    }

    func testMonitor_pausesDuringSecureInput() {
        let pb = FakePasteboard()
        var secure = true
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { secure }, frontmost: { (nil, nil) })
        var got = 0
        m.onCapture = { _ in got += 1 }
        pb.set([[textRep("typed in a password box")]])
        m.tick()
        XCTAssertEqual(m.lastSkip, .secureInput)
        secure = false
        pb.set([[textRep("normal")]])
        m.tick()
        XCTAssertEqual(got, 1)
    }

    func testMonitor_discardsSnapshotWhenCountMovesMidRead_thenRereads() {
        let pb = FakePasteboard()
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { (nil, nil) })
        var got: [CapturedClipboard] = []
        m.onCapture = { got.append($0) }
        pb.set([[textRep("first")]])
        pb.bumpOnRead = true
        m.tick()
        XCTAssertEqual(m.lastSkip, .unstable)
        XCTAssertTrue(got.isEmpty)
        m.tick()   // next tick reads the settled pasteboard
        XCTAssertEqual(got.count, 1)
    }

    func testWriter_marksSeenSoMonitorIgnoresIt() {
        let pb = FakePasteboard()
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { (nil, nil) })
        let oldPB = ClipboardWriter.pasteboard
        ClipboardWriter.pasteboard = pb; ClipboardWriter.monitor = m
        defer { ClipboardWriter.pasteboard = oldPB; ClipboardWriter.monitor = nil }
        var got = 0
        m.onCapture = { _ in got += 1 }
        ClipboardWriter.writeString("/tmp/x")
        m.tick()
        XCTAssertEqual(got, 0)
        XCTAssertTrue(pb.types.contains(ClipTypes.shakeboardMarker))
    }

    // MARK: normalizer

    func testNormalize_textAndURLKinds() {
        XCTAssertEqual(ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [], items: [[textRep("a note")]]))?.kind, .text)
        XCTAssertEqual(ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [],
                                                            items: [[textRep("https://example.com/a")]]))?.kind, .url)
        XCTAssertNil(ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [], items: [[textRep("   \n ")]])))
    }

    func testNormalize_filesBeatTIFFPreview() {
        let url = RawRep(type: ClipTypes.fileURL, data: Data("file:///Users/x/Report.pdf".utf8))
        let tiff = RawRep(type: ClipTypes.tiff, data: imageData(4, 4, type: .tiff))
        let n = ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [], items: [[url, textRep("Report.pdf"), tiff]]))
        XCTAssertEqual(n?.kind, .files)
        XCTAssertEqual(n?.preview, "Report.pdf")
        XCTAssertFalse(n!.items.flatMap { $0 }.contains { $0.type == ClipTypes.tiff })
    }

    func testNormalize_textWithRenderedImageStaysText() {
        let tiff = RawRep(type: ClipTypes.tiff, data: imageData(4, 4, type: .tiff))
        let n = ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [], items: [[textRep("words"), tiff]]))
        XCTAssertEqual(n?.kind, .text)
        XCTAssertEqual(n?.items.first?.map(\.type), [ClipTypes.plainText])
    }

    func testNormalize_tiffConvertedToPNG_andPixelCapRejects() {
        let tiff = RawRep(type: ClipTypes.tiff, data: imageData(8, 6, type: .tiff))
        let n = ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [], items: [[tiff]]))
        XCTAssertEqual(n?.kind, .image)
        XCTAssertEqual(n?.items.first?.first?.type, ClipTypes.png)
        XCTAssertEqual(n?.pixelWidth, 8); XCTAssertEqual(n?.pixelHeight, 6)
        let old = ClipLimits.maxImagePixels
        ClipLimits.maxImagePixels = 10
        defer { ClipLimits.maxImagePixels = old }
        XCTAssertNil(ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [], items: [[tiff]])))
    }

    func testNormalize_oversizeTextRejected() {
        let big = String(repeating: "x", count: ClipLimits.maxTextBytes + 1)
        XCTAssertNil(ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [], items: [[textRep(big)]])))
    }

    // MARK: store

    func testStore_roundTripsOrderedMultiItemMultiType() {
        let store = makeStore()
        let rtf = RawRep(type: ClipTypes.rtf, data: Data("{\\rtf1 a}".utf8))
        let (clip, isNew) = ingest(store, cap([[rtf, textRep("a")], [textRep("b")]]))
        XCTAssertTrue(isNew)
        let payload = store.payload(for: clip!)
        XCTAssertEqual(payload?.count, 2)
        XCTAssertEqual(payload?[0].map(\.type), [ClipTypes.rtf, ClipTypes.plainText])
        XCTAssertEqual(payload?[1].first?.data, Data("b".utf8))
        // Survives a reload.
        let again = makeStore()
        XCTAssertEqual(again.clips.map(\.id), [clip!.id])
        XCTAssertEqual(again.fullText(for: again.clips[0]), "a")
    }

    func testStore_dedupeKeepsCreatedAtAndBumpsLastUsed() {
        let store = makeStore()
        let (first, _) = ingest(store, cap([[textRep("same")]]))
        ingest(store, cap([[textRep("other")]]))
        let later = now.addingTimeInterval(60)
        let (again, isNew) = ingest(store, cap([[textRep("same")]], at: later))
        XCTAssertFalse(isNew)
        XCTAssertEqual(again?.id, first?.id)
        XCTAssertEqual(again?.createdAt, first?.createdAt)
        XCTAssertEqual(again?.lastUsedAt, later)
        XCTAssertEqual(store.clips.first?.id, first?.id)
        XCTAssertEqual(store.clips.count, 2)
    }

    func testStore_evictsByCountAgeAndBytes_butNotPinned() {
        let store = makeStore()
        store.maxCount = 2
        let (a, _) = ingest(store, cap([[textRep("a")]]))
        store.pinned = { [a!.id] }
        ingest(store, cap([[textRep("b")]]))
        ingest(store, cap([[textRep("c")]]))
        XCTAssertTrue(store.clips.contains { $0.id == a!.id }, "pinned survives count eviction")
        XCTAssertEqual(store.clips.count, 3)   // a (pinned) + the 2 newest
        store.pinned = { [] }
        store.maxCount = 200
        now = now.addingTimeInterval(8 * 24 * 3600)
        ingest(store, cap([[textRep("fresh")]]))
        XCTAssertEqual(store.clips.map(\.preview), ["fresh"], "older than 7 days evicted")
        store.maxBytes = 6
        ingest(store, cap([[textRep("12345")]]))
        XCTAssertEqual(store.clips.map(\.preview), ["12345"], "byte cap evicts the oldest")
        store.flush()
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: store.dir.path))?.filter { !$0.hasSuffix(".json") } ?? []
        XCTAssertEqual(Set(dirs), Set(store.clips.map { $0.id.uuidString }), "evicted payloads are physically gone")
    }

    func testStore_clearAllDeletesPayloadsButNotShelf() throws {
        let shelfFile = tmp.appendingPathComponent("Shelf/keep.png")
        try FileManager.default.createDirectory(at: shelfFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: shelfFile)
        let store = makeStore()
        let (c, _) = ingest(store, cap([[textRep("secret-ish")]]))
        store.clearAll()
        store.flush()
        XCTAssertTrue(store.clips.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.payloadDir(c!.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shelfFile.path))
        XCTAssertTrue(makeStore().clips.isEmpty)
    }

    func testStore_reconcilesOrphansAndMissingPayloads() throws {
        let store = makeStore()
        let (keep, _) = ingest(store, cap([[textRep("keep")]]))
        let (lose, _) = ingest(store, cap([[textRep("lose")]]))
        store.flush()
        // Crash shapes: an orphan payload dir, a half-written staging dir, and an index entry whose payload vanished.
        let orphan = store.dir.appendingPathComponent(UUID().uuidString)
        let staging = store.dir.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: store.payloadDir(lose!.id))
        let reloaded = makeStore()
        reloaded.flush()
        XCTAssertEqual(reloaded.clips.map(\.id), [keep!.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testStoreLoadKeepsIndexedClipWhenPayloadDirectoryAlsoContainsOCRSidecar() throws {
        let first = makeStore()
        let (clip, _) = ingest(first, cap([[RawRep(type: ClipTypes.png, data: imageData(3, 3, type: .png))]]))
        let saved = try XCTUnwrap(clip)
        try Data("recognized words".utf8).write(to: first.payloadDir(saved.id).appendingPathComponent("ocr.txt"))
        first.flush()

        let reloaded = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        reloaded.load()
        XCTAssertEqual(reloaded.clips.map(\.id), [saved.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.payloadDir(saved.id).appendingPathComponent("ocr.txt").path))
    }

    // (4) An unreadable / future index sets the whole Clips dir aside -- payloads are NOT reconciled away.
    func testStore_corruptOrFutureIndex_quarantinesWithoutDeletingPayloads() throws {
        for bad in [#"{"version":99,"clips":[]}"#, "{ not json"] {
            let store = makeStore()
            let (c, _) = ingest(store, cap([[textRep("precious \(bad.count)")]]))
            store.flush()
            try Data(bad.utf8).write(to: store.dir.appendingPathComponent("clips.json"))
            let reloaded = makeStore()
            reloaded.flush()
            XCTAssertTrue(reloaded.clips.isEmpty)
            let q = try reloaded.quarantinedDirs()
            XCTAssertFalse(q.isEmpty)
            let kept = q.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(c!.id.uuidString).path) }
            XCTAssertTrue(kept, "the quarantined copy still has the payload")
            // Clear History removes quarantined history too (it holds the same text).
            reloaded.clearAll(); reloaded.flush()
            XCTAssertTrue(try reloaded.quarantinedDirs().isEmpty)
        }
    }

    // (5) An ingest in flight when history is cleared must not come back.
    func testStore_clearDuringIngest_doesNotResurrect() {
        let store = makeStore()
        let exp = expectation(description: "ingest")
        var result: Clip? = Clip?.none
        var called = false
        store.ingest(cap([[textRep("copied just before Clear")]])) { c, _ in result = c; called = true; exp.fulfill() }
        store.clearAll()                                    // runs before the async ingest commits
        wait(for: [exp], timeout: 5)
        store.flush()
        XCTAssertTrue(called)
        XCTAssertNil(result)
        XCTAssertTrue(store.clips.isEmpty)
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: store.dir.path)) ?? []).filter { !$0.hasSuffix(".json") }
        XCTAssertTrue(dirs.isEmpty, "its staged payload was deleted: \(dirs)")
    }

    // (6) Hostile dimensions are rejected without trapping.
    func testPixelCap_overflowRejected() {
        XCTAssertFalse(ClipNormalizer.withinPixelCap((Int.max, 2)))
        XCTAssertFalse(ClipNormalizer.withinPixelCap((1 << 40, 1 << 40)))
        XCTAssertTrue(ClipNormalizer.withinPixelCap((100, 100)))
    }

    // (7) Framed hash: shifting bytes between a type and its neighbour's data changes the hash.
    func testHash_isFramed() {
        let a = [[RawRep(type: ClipTypes.rtf, data: Data("xpublic.html".utf8)), RawRep(type: "", data: Data("y".utf8))]]
        let b = [[RawRep(type: ClipTypes.rtf, data: Data("x".utf8)), RawRep(type: "public.html", data: Data("y".utf8))]]
        XCTAssertNotEqual(ClipNormalizer.contentHash(.text, a), ClipNormalizer.contentHash(.text, b))
        let c = [[textRep("ab")], [textRep("c")]]
        let d = [[textRep("a")], [textRep("bc")]]
        XCTAssertNotEqual(ClipNormalizer.contentHash(.text, c), ClipNormalizer.contentHash(.text, d))
    }

    // (8) Rich-only copies are accepted with a derived preview; multi-image copies keep every image.
    func testNormalize_richOnlyAndMultiImage() {
        let rtfData = try! NSAttributedString(string: "Bold claim").data(
            from: NSRange(location: 0, length: 10), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtf = ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [], items: [[RawRep(type: ClipTypes.rtf, data: rtfData)]]))
        XCTAssertEqual(rtf?.kind, .text); XCTAssertEqual(rtf?.preview, "Bold claim")
        let html = ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [],
            items: [[RawRep(type: ClipTypes.html, data: Data("<p>Hi &amp; <b>bye</b></p>".utf8))]]))
        XCTAssertEqual(html?.preview, "Hi &  bye")
        let url = ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [],
            items: [[RawRep(type: ClipTypes.url, data: Data("https://example.com/x".utf8))]]))
        XCTAssertEqual(url?.kind, .url)
        let two = ClipNormalizer.normalize(RawSnapshot(changeCount: 1, allTypes: [], items: [
            [RawRep(type: ClipTypes.png, data: imageData(3, 3, type: .png))],
            [RawRep(type: ClipTypes.tiff, data: imageData(4, 4, type: .tiff))]]))
        XCTAssertEqual(two?.kind, .image)
        XCTAssertEqual(two?.items.count, 2)
        XCTAssertEqual(two?.preview, "2 images")
    }

    // (14) Owner-only permissions, and Clips/ is excluded from backups.
    func testStore_permissionsAndBackupExclusion() throws {
        let store = makeStore()
        let (c, _) = ingest(store, cap([[textRep("private")]]))
        let fm = FileManager.default
        let dirPerm = (try fm.attributesOfItem(atPath: store.dir.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(dirPerm, 0o700)
        let file = store.payloadDir(c!.id).appendingPathComponent(c!.reps[0].file)
        XCTAssertEqual((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try fm.attributesOfItem(atPath: store.payloadDir(c!.id).path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try store.dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    // (12) A transactional add rolls the item back when shelf.json can't be saved.
    func testShelfAdd_transactionalRollsBackOnSaveFailure() throws {
        let base = tmp.appendingPathComponent("blocked")
        try Data("not a dir".utf8).write(to: base)          // baseDir is a FILE -> every save fails
        let model = ShelfModel(baseDir: base)
        let real = tmp.appendingPathComponent("img.png")
        try Data("png".utf8).write(to: real)
        XCTAssertEqual(model.add([real], owned: true, transactional: true), 0)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.add([real], owned: true), 1, "non-transactional keeps the item (drop/handoff path)")
        XCTAssertTrue(model.lastSaveFailed)
    }

    func testStore_imageClipExposesPNG() {
        let store = makeStore()
        let (c, _) = ingest(store, cap([[RawRep(type: ClipTypes.png, data: imageData(5, 5, type: .png))]]))
        XCTAssertEqual(c?.kind, .image)
        XCTAssertNotNil(store.imageURL(for: c!))
    }

    // MARK: shelf add result (image ingest rolls its file back when this says 0)

    func testShelfAdd_reportsLandedCount() throws {
        let model = ShelfModel(baseDir: tmp)
        let real = tmp.appendingPathComponent("Shelf/img.png")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: real)
        XCTAssertEqual(model.add([real], owned: true), 1)
        XCTAssertEqual(model.add([real], owned: true), 1, "already present still counts as landed")
        XCTAssertEqual(model.ownedCount, 1)
        let ghost = tmp.appendingPathComponent("does-not-exist.png")
        XCTAssertEqual(model.add([ghost], owned: true), 0, "unbookmarkable file is reported, so the caller can roll back")
    }

    final class FakePoster: EventPoster {
        var allowed = true
        var posted: [pid_t] = []
        func canPost() -> Bool { allowed }
        func postPaste(to pid: pid_t) { posted.append(pid) }
    }

    func testPaster_writesTaggedPayloadAndPastesIntoTarget() {
        let pb = FakePasteboard()
        let oldPB = ClipboardWriter.pasteboard
        ClipboardWriter.pasteboard = pb
        defer { ClipboardWriter.pasteboard = oldPB }
        let store = makeStore()
        let (c, _) = ingest(store, cap([[textRep("paste me")]]))
        let poster = FakePoster()
        var paster = ClipPaster(store: store, poster: poster)
        paster.frontmostPID = { 42 }
        XCTAssertEqual(paster.paste(c!, into: 42, copyOnly: false), .pasted)
        XCTAssertEqual(poster.posted, [42])
        XCTAssertEqual(pb.items.first?.first?.data, Data("paste me".utf8))
        XCTAssertTrue(pb.types.contains(ClipTypes.shakeboardMarker))
        XCTAssertEqual(paster.paste(c!, into: 7, copyOnly: false), .targetChanged, "never paste into a different app")
        XCTAssertEqual(paster.paste(c!, into: 42, copyOnly: true), .copiedOnly)
        poster.allowed = false
        XCTAssertEqual(paster.paste(c!, into: 42, copyOnly: false), .noPermission)
        XCTAssertEqual(poster.posted, [42])
    }

    // MARK: verify-pass regressions

    // An unstable read is retried synchronously before a ShakeBoard write, and the copy is recorded.
    func testWriter_retriesUnstableReadThenWrites() {
        let pb = FakePasteboard()
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { (nil, nil) })
        let oldPB = ClipboardWriter.pasteboard
        ClipboardWriter.pasteboard = pb; ClipboardWriter.monitor = m
        defer { ClipboardWriter.pasteboard = oldPB; ClipboardWriter.monitor = nil }
        var got = 0
        m.onCapture = { _ in got += 1 }
        pb.set([[textRep("external copy")]])
        pb.bumpOnRead = true                                 // first read is unstable
        XCTAssertNotNil(ClipboardWriter.writeString("shakeboard"))
        XCTAssertEqual(got, 1, "the external copy was recorded before the write")
    }

    // If the pending copy can't be recorded, the write is refused and the clipboard is left alone.
    func testWriter_refusesWhileCopyCannotBeRecorded() {
        let pb = FakePasteboard()
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { (nil, nil) })
        let oldPB = ClipboardWriter.pasteboard
        ClipboardWriter.pasteboard = pb; ClipboardWriter.monitor = m
        defer { ClipboardWriter.pasteboard = oldPB; ClipboardWriter.monitor = nil }
        pb.set([[textRep("still landing")]])
        pb.bumpEveryRead = true
        XCTAssertNil(ClipboardWriter.writeString("shakeboard"))
        XCTAssertEqual(pb.writes, 0)
        XCTAssertEqual(pb.items.first?.first?.data, Data("still landing".utf8))
        pb.bumpEveryRead = false
        XCTAssertTrue(m.hasUnseenChange, "the retry is NOT suppressed -- the next tick still records it")
    }

    // A failed quarantine move leaves the store degraded (not "empty and clean"): capture is refused, the
    // damaged files stay, and Clear History physically empties every entry under Clips/.
    func testStore_quarantineMoveFailure_degradesAndClearEmptiesEverything() throws {
        let store = makeStore()
        let (c, _) = ingest(store, cap([[textRep("sensitive")]]))
        store.flush()
        let stray = store.dir.appendingPathComponent(UUID().uuidString)   // an unindexed payload dir
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("{ corrupt".utf8).write(to: store.dir.appendingPathComponent("clips.json"))
        // Make the base dir read-only so moving Clips/ aside fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tmp.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path) }
        let reloaded = makeStore()
        XCTAssertTrue(reloaded.isDegraded)
        XCTAssertTrue(reloaded.clips.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.payloadDir(c!.id).path), "nothing deleted")
        let (refused, _) = ingest(reloaded, cap([[textRep("new copy")]]))
        XCTAssertNil(refused, "capture refused while degraded")
        XCTAssertEqual(try String(contentsOf: reloaded.dir.appendingPathComponent("clips.json"), encoding: .utf8),
                       "{ corrupt", "damaged index not overwritten")
        reloaded.clearAll()
        reloaded.flush()
        let left = try FileManager.default.contentsOfDirectory(atPath: reloaded.dir.path)
        XCTAssertEqual(left, ["clips.json"], "every payload, stray or indexed, is gone")
        XCTAssertFalse(reloaded.isDegraded)
        XCTAssertNotNil(ingest(reloaded, cap([[textRep("after clear")]])).0, "capture works again")
    }

    // A refused write (external copy still settling) must not paste, mark used, or report success.
    func testPaster_refusedWrite_doesNotPaste() {
        let pb = FakePasteboard()
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { (nil, nil) })
        let oldPB = ClipboardWriter.pasteboard
        ClipboardWriter.pasteboard = pb; ClipboardWriter.monitor = m
        defer { ClipboardWriter.pasteboard = oldPB; ClipboardWriter.monitor = nil }
        let store = makeStore()
        let (c, _) = ingest(store, cap([[textRep("from history")]]))
        let (other, _) = ingest(store, cap([[textRep("newer item")]], at: now.addingTimeInterval(5)))
        XCTAssertEqual(store.clips.first?.id, other?.id)
        pb.set([[textRep("external copy settling")]])
        pb.bumpEveryRead = true
        let poster = FakePoster()
        var paster = ClipPaster(store: store, poster: poster)
        paster.frontmostPID = { 42 }
        XCTAssertEqual(paster.paste(c!, into: 42, copyOnly: false), .clipboardBusy)
        XCTAssertTrue(poster.posted.isEmpty, "no Cmd-V posted")
        XCTAssertEqual(store.clips.first?.id, other?.id, "not marked used")
        XCTAssertEqual(pb.items.first?.first?.data, Data("external copy settling".utf8))
        pb.bumpEveryRead = false
    }

    // A Clear that can't delete everything stays degraded, flags clearFailed, and writes no fresh index.
    func testStore_clearWithFailedDeletion_staysDegraded() throws {
        let store = makeStore()
        let (c, _) = ingest(store, cap([[textRep("hard to delete")]]))
        store.flush()
        let payload = store.payloadDir(c!.id)
        // Read-only payload dir: its files can't be unlinked, so the dir can't be removed.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: payload.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payload.path) }
        XCTAssertFalse(store.clearAll())
        store.flush()
        XCTAssertTrue(store.clearFailed)
        XCTAssertTrue(store.isDegraded)
        // clips.json is never deleted; it is replaced by an index that no longer owns the leftovers.
        let idx = try Data(contentsOf: store.dir.appendingPathComponent("clips.json"))
        XCTAssertTrue(String(data: idx, encoding: .utf8)!.contains("\"clips\":[]"), "cleared items are not owned any more")
        XCTAssertNil(ingest(store, cap([[textRep("new")]])).0, "capture refused while degraded")
        // Once the blocker is gone, Clear succeeds and the store recovers.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payload.path)
        XCTAssertTrue(store.clearAll())
        store.flush()
        XCTAssertFalse(store.clearFailed)
        XCTAssertFalse(store.isDegraded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.dir.path), ["clips.json"])
    }

    // A failed Clear stays failed across a restart: the leftovers on disk drive degraded mode at launch,
    // and the cleared items do NOT come back.
    func testStore_restartAfterPartialClear_staysDegradedWithoutResurrection() throws {
        let store = makeStore()
        let (stuck, _) = ingest(store, cap([[textRep("stuck")]]))
        ingest(store, cap([[textRep("gone")]], at: now.addingTimeInterval(1)))
        store.flush()
        let payload = store.payloadDir(stuck!.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: payload.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payload.path) }
        XCTAssertFalse(store.clearAll())

        let restarted = makeStore()                          // "relaunch"
        restarted.flush()
        XCTAssertTrue(restarted.isDegraded, "degraded comes back from the leftovers on disk")
        XCTAssertTrue(restarted.clearFailed)
        XCTAssertTrue(restarted.clips.isEmpty, "cleared items are not resurrected")
        XCTAssertNil(ingest(restarted, cap([[textRep("new")]])).0, "capture stays off")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payload.path)
        let fixed = makeStore()                              // blocker gone: launch reconcile finishes the job
        fixed.flush()
        XCTAssertFalse(fixed.isDegraded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertNotNil(ingest(fixed, cap([[textRep("works again")]])).0)
    }

    // If Clips/ can't be listed, nothing can be verified: Clear fails and launch comes up degraded.
    func testStore_unlistableClipsDir_isNotTreatedAsClean() throws {
        let store = makeStore()
        ingest(store, cap([[textRep("hidden")]]))
        store.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: store.dir.path)  // no read
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.dir.path) }
        XCTAssertFalse(store.clearAll(), "enumeration failure is a failed clear")
        XCTAssertTrue(store.clearFailed)
        let restarted = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        // load() would chmod Clips back to 0700 in prepareDir; keep it unreadable for this check.
        XCTAssertFalse(ClipStore.removeUnowned(in: restarted.dir, keeping: []))
    }

    func testStore_pendingClearWithUnavailableIndexFailsClosedUntilRetry() throws {
        let store = makeStore()
        let (pinned, _) = ingest(store, cap([[textRep("keep for stack")]]))
        let (cleared, _) = ingest(store, cap([[textRep("clear after retry")]], at: now.addingTimeInterval(1)))
        store.flush()
        let index = store.dir.appendingPathComponent("clips.json")
        let marker = store.dir.appendingPathComponent("clear-pending")
        let oldIndex = try Data(contentsOf: index)
        try Data("pending".utf8).write(to: marker, options: .atomic)

        var failClipsListing = true
        let fm = FileManager.default
        let clipsDir = store.dir
        let operations = ClipStore.FileOperations(
            contentsOfDirectory: { url in
                if failClipsListing, url == clipsDir { throw CocoaError(.fileReadNoPermission) }
                return try fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            },
            removeItem: { try fm.removeItem(at: $0) },
            writeAtomically: { try $0.write(to: $1, options: .atomic) })
        let recovering = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now }, fileOperations: operations)
        recovering.pinned = { [pinned!.id] }

        recovering.load()

        XCTAssertTrue(recovering.isDegraded)
        XCTAssertTrue(recovering.clearFailed)
        XCTAssertTrue(recovering.clips.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "the retry marker must remain")
        XCTAssertEqual(try Data(contentsOf: index), oldIndex, "an unavailable old index must not be replaced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovering.payloadDir(pinned!.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovering.payloadDir(cleared!.id).path))

        failClipsListing = false
        recovering.load()
        recovering.flush()

        XCTAssertFalse(recovering.isDegraded)
        XCTAssertEqual(recovering.clips.map(\.id), [pinned!.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovering.payloadDir(pinned!.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovering.payloadDir(cleared!.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStore_pendingClearPersistsInheritedAIHideBeforeDroppingParent() throws {
        let suite = "shakeboard.tests.pending-clear-hide.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hidden = AIHiddenClips(defaults: defaults)
        let prefs = PerchPrefs(defaults: defaults)
        let store = makeStore()
        let (parent, _) = ingest(store, cap([[textRep("hidden parent")]]))
        let (child, _) = ingest(
            store,
            cap([[textRep("pinned child")]], at: now.addingTimeInterval(1)),
            derivedFrom: parent!.id)
        store.flush()
        hidden.hide(parent!.id)
        XCTAssertFalse(hidden.isHidden(child!.id), "the child should initially be hidden only through its parent")
        store.pinned = { [child!.id] }
        let marker = store.dir.appendingPathComponent("clear-pending")
        try Data("pending".utf8).write(to: marker, options: .atomic)

        let recovering = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        recovering.pinned = { [child!.id] }
        recovering.willDrop = {
            AIVisibility.persistInheritedHides(store: recovering, hidden: hidden, prefs: prefs)
        }
        recovering.load()
        recovering.flush()

        XCTAssertNil(recovering.clip(parent!.id))
        let kept = try XCTUnwrap(recovering.clip(child!.id))
        hidden.prune(keeping: Set(recovering.clips.map(\.id)))
        let byID = Dictionary(recovering.clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertTrue(AIVisibility.isHidden(
            kept, byID: byID, hiddenApps: AIVisibility.hiddenApps(prefs), hiddenClips: hidden.ids))
    }

    func testStore_pendingClearWithMissingIndexFinishesAndAllowsCapture() throws {
        let clipsDir = tmp.appendingPathComponent("Clips", isDirectory: true)
        let stray = clipsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: stray.appendingPathComponent("0-0.bin"))
        let marker = clipsDir.appendingPathComponent("clear-pending")
        try Data("pending".utf8).write(to: marker, options: .atomic)

        let recovering = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        recovering.load()
        recovering.flush()

        XCTAssertFalse(recovering.isDegraded)
        XCTAssertFalse(recovering.clearBlockedByUnavailableIndex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertNotNil(ingest(recovering, cap([[textRep("capture after recovery")]])).0)
    }

    func testStore_pendingClearWithSymlinkIndexFinishesWithoutTouchingTarget() throws {
        let clipsDir = tmp.appendingPathComponent("Clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        let target = tmp.appendingPathComponent("symlink-target")
        let targetData = Data("untouched".utf8)
        try targetData.write(to: target)
        let index = clipsDir.appendingPathComponent("clips.json")
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: target)
        let stray = clipsDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("stray".utf8).write(to: stray.appendingPathComponent("0-0.bin"))
        let marker = clipsDir.appendingPathComponent("clear-pending")
        try Data("pending".utf8).write(to: marker, options: .atomic)

        let recovering = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        recovering.load()

        XCTAssertFalse(recovering.isDegraded)
        XCTAssertFalse(recovering.clearBlockedByUnavailableIndex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        let values = try index.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        XCTAssertEqual(values.isRegularFile, true)
        XCTAssertNotEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try Data(contentsOf: target), targetData)
    }

    func testStore_listingFailureDoesNotQuarantineOrRewriteHistory() throws {
        let store = makeStore()
        let (first, _) = ingest(store, cap([[textRep("first")]]))
        let (second, _) = ingest(store, cap([[textRep("second")]], at: now.addingTimeInterval(1)))
        store.flush()
        let index = store.dir.appendingPathComponent("clips.json")
        let oldIndex = try Data(contentsOf: index)

        var failClipsListing = true
        let fm = FileManager.default
        let clipsDir = store.dir
        let operations = ClipStore.FileOperations(
            contentsOfDirectory: { url in
                if failClipsListing, url == clipsDir { throw CocoaError(.fileReadNoPermission) }
                return try fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            },
            removeItem: { try fm.removeItem(at: $0) },
            writeAtomically: { try $0.write(to: $1, options: .atomic) })
        let reloaded = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now }, fileOperations: operations)

        reloaded.load()

        XCTAssertTrue(reloaded.isDegraded)
        XCTAssertTrue(reloaded.clips.isEmpty)
        XCTAssertEqual(try Data(contentsOf: index), oldIndex)
        XCTAssertTrue(try reloaded.quarantinedDirs().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.payloadDir(first!.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.payloadDir(second!.id).path))

        failClipsListing = false
        reloaded.load()

        XCTAssertFalse(reloaded.isDegraded)
        XCTAssertEqual(reloaded.clips.map(\.id), [second!.id, first!.id])
    }

    func testStore_listingFailureClearFailsClosedAndPinnedClipSurvivesRestart() throws {
        let store = makeStore()
        let (pinned, _) = ingest(store, cap([[textRep("keep for stack")]]))
        store.flush()
        let index = store.dir.appendingPathComponent("clips.json")
        let payload = store.payloadDir(pinned!.id).appendingPathComponent(pinned!.reps[0].file)
        let oldIndex = try Data(contentsOf: index)
        let oldPayload = try Data(contentsOf: payload)

        var failClipsListing = true
        let fm = FileManager.default
        let clipsDir = store.dir
        let operations = ClipStore.FileOperations(
            contentsOfDirectory: { url in
                if failClipsListing, url == clipsDir { throw CocoaError(.fileReadNoPermission) }
                return try fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            },
            removeItem: { try fm.removeItem(at: $0) },
            writeAtomically: { try $0.write(to: $1, options: .atomic) })
        let degraded = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now }, fileOperations: operations)
        degraded.pinned = { [pinned!.id] }
        degraded.load()

        XCTAssertTrue(degraded.isDegraded)
        XCTAssertFalse(degraded.clearAll())
        XCTAssertTrue(degraded.isDegraded)
        XCTAssertTrue(degraded.clearFailed)
        XCTAssertEqual(try Data(contentsOf: index), oldIndex)
        XCTAssertEqual(try Data(contentsOf: payload), oldPayload)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: degraded.dir.appendingPathComponent("clear-pending").path))

        failClipsListing = false
        let restarted = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now }, fileOperations: operations)
        restarted.pinned = { [pinned!.id] }
        restarted.load()

        XCTAssertFalse(restarted.isDegraded)
        XCTAssertEqual(restarted.clips.map(\.id), [pinned!.id])
        XCTAssertEqual(try Data(contentsOf: payload), oldPayload)
    }

    func testStore_failedDeletionAndIndexReplacementDoesNotResurrectAfterRestart() throws {
        var failDeletion = false
        var failIndexWrite = false
        var blockedPayloadName: String?
        let fm = FileManager.default
        let operations = ClipStore.FileOperations(
            contentsOfDirectory: { url in
                try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            },
            removeItem: { url in
                if failDeletion, url.lastPathComponent == blockedPayloadName {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try fm.removeItem(at: url)
            },
            writeAtomically: { data, url in
                if failIndexWrite, url.lastPathComponent == "clips.json" {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
            })
        let store = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now }, fileOperations: operations)
        store.load()
        let (pinned, _) = ingest(store, cap([[textRep("keep for stack")]]))
        let (cleared, _) = ingest(store, cap([[textRep("must stay cleared")]], at: now.addingTimeInterval(1)))
        store.pinned = { [pinned!.id] }
        blockedPayloadName = cleared!.id.uuidString
        failDeletion = true
        failIndexWrite = true

        XCTAssertFalse(store.clearAll())
        let marker = store.dir.appendingPathComponent("clear-pending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        let restarted = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        restarted.pinned = { [pinned!.id] }
        restarted.load()
        restarted.flush()
        XCTAssertEqual(restarted.clips.map(\.id), [pinned!.id])
        XCTAssertNil(restarted.clip(cleared!.id), "the old index must not resurrect an attempted clear")
        XCTAssertTrue(FileManager.default.fileExists(atPath: restarted.payloadDir(pinned!.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStore_quarantineListingFailureLeavesPendingClearForRestart() {
        var failQuarantineListing = false
        let fm = FileManager.default
        let base = tmp!
        let operations = ClipStore.FileOperations(
            contentsOfDirectory: { url in
                if failQuarantineListing, url == base { throw CocoaError(.fileReadNoPermission) }
                return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            },
            removeItem: { try fm.removeItem(at: $0) },
            writeAtomically: { try $0.write(to: $1, options: .atomic) })
        let store = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now }, fileOperations: operations)
        store.load()
        let (cleared, _) = ingest(store, cap([[textRep("history")]]))
        failQuarantineListing = true

        XCTAssertFalse(store.clearAll())
        XCTAssertTrue(store.clearFailed)
        XCTAssertTrue(store.isDegraded)
        let marker = store.dir.appendingPathComponent("clear-pending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        let restarted = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        restarted.load()
        restarted.flush()

        XCTAssertFalse(restarted.isDegraded)
        XCTAssertNil(restarted.clip(cleared!.id), "the old index must not resurrect the cleared clip")
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.payloadDir(cleared!.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStore_markerWriteFailureLeavesHistoryUntouched() throws {
        let fm = FileManager.default
        let operations = ClipStore.FileOperations(
            contentsOfDirectory: {
                try fm.contentsOfDirectory(
                    at: $0, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            },
            removeItem: { try fm.removeItem(at: $0) },
            writeAtomically: { data, url in
                if url.lastPathComponent == "clear-pending" { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
        let store = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now }, fileOperations: operations)
        store.load()
        let (clip, _) = ingest(store, cap([[textRep("must remain")]]))
        let index = store.dir.appendingPathComponent("clips.json")
        let oldIndex = try Data(contentsOf: index)

        XCTAssertFalse(store.clearAll())

        XCTAssertEqual(store.clips.map(\.id), [clip!.id])
        XCTAssertEqual(try Data(contentsOf: index), oldIndex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.payloadDir(clip!.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.dir.appendingPathComponent("clear-pending").path))
    }

    func testRemoveUnownedDeletesDirectoryNamedClipsJSON() throws {
        let clipsDir = tmp.appendingPathComponent("Clips", isDirectory: true)
        let fakeIndex = clipsDir.appendingPathComponent("clips.json", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeIndex, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: fakeIndex.appendingPathComponent("inside"))

        XCTAssertTrue(ClipStore.removeUnowned(in: clipsDir, keeping: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeIndex.path))
    }

    func testStore_directoryNamedClipsJSONIsQuarantinedAsDamaged() throws {
        let clipsDir = tmp.appendingPathComponent("Clips", isDirectory: true)
        let fakeIndex = clipsDir.appendingPathComponent("clips.json", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeIndex, withIntermediateDirectories: true)
        try Data("history".utf8).write(to: fakeIndex.appendingPathComponent("inside"))

        let store = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        store.load()

        XCTAssertTrue(store.clips.isEmpty)
        XCTAssertFalse(store.isDegraded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fakeIndex.path))
        XCTAssertTrue(try store.quarantinedDirs().contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("clips.json/inside").path)
        })
    }
}
