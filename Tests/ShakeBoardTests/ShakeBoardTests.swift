//
//  ShakeBoardTests.swift
//  Lean data-safety unit tests for ShakeBoard (Phase 1). No AppKit mocking, no UI tests -- these cover the
//  file-losing-bug surface: the filename sanitizer, shakeboard:// handoff validation, the owned-copy delete
//  boundary, shelf dedup, save/load round-trip, schema-version migration, corrupt-JSON quarantine, and
//  the missing-file-greys-not-dropped rule. Interaction behavior is covered by the manual matrix.
//

import XCTest
@testable import ShakeBoard
// ShareViewController.swift is compiled into this test target directly (a unit-test bundle can't depend
// on an app extension), so its internal sanitizer is reachable without an import.

// @MainActor: ShelfModel is now @MainActor-isolated (P2-3), so the tests that touch it must run on the
// main actor too. Annotating the class keeps every test method isolated; the pure sanitizer / shake /
// optimizer-cap helpers are nonisolated and remain callable from here.
@MainActor
final class ShakeBoardTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShakeBoardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // Make a real regular file so bookmarks resolve.
    private func makeFile(_ name: String, in dir: URL? = nil, contents: String = "x") throws -> URL {
        let base = dir ?? tmp!
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Filename sanitizer (ShakeBoardShare)

    func testSanitizer_replacesPathSeparators() {
        let out = ShareViewController.sanitizedFilename("a/b:c.txt", fallback: "f", defaultExt: "")
        XCTAssertFalse(out.contains("/"))
        XCTAssertFalse(out.contains(":"))
        XCTAssertEqual(out, "a-b-c.txt")
    }

    func testSanitizer_stripsControlAndBidiChars() {
        // Leading RTL override + a control char must not survive into a filename.
        let raw = "\u{202E}evil\u{0007}name.txt"
        let out = ShareViewController.sanitizedFilename(raw, fallback: "f", defaultExt: "")
        XCTAssertEqual(out, "evilname.txt")
        XCTAssertFalse(out.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) })
    }

    func testSanitizer_dotfileBecomesFallbackNotHidden() {
        // A name that is nothing but leading dots collapses to empty -> fallback, never a hidden file.
        let out = ShareViewController.sanitizedFilename("...", fallback: "clip", defaultExt: "txt")
        XCTAssertFalse(out.hasPrefix("."))
        XCTAssertEqual(out, "clip.txt")
    }

    func testSanitizer_truncatesByUTF8Bytes() {
        // 300 multi-byte scalars would blow past the ~255-byte component limit; cap is 180 bytes + ext.
        let raw = String(repeating: "e\u{0301}", count: 300)   // combining acute -> multi-byte
        let out = ShareViewController.sanitizedFilename(raw, fallback: "f", defaultExt: "jpg")
        XCTAssertLessThanOrEqual(out.utf8.count, 180 + ".jpg".utf8.count)
        XCTAssertTrue(out.hasSuffix(".jpg"))
    }

    // MARK: - shakeboard:// handoff validation (every rejection branch + the accept path)

    func testValidatedHandoffDir_acceptsValidFolder() throws {
        let dir = tmp.appendingPathComponent("ShakeBoardHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNotNil(AppDelegate.validatedHandoffDir(dir.path, container: tmp))
    }

    func testValidatedHandoffDir_rejectsEmpty() {
        XCTAssertNil(AppDelegate.validatedHandoffDir("", container: tmp))
    }

    func testValidatedHandoffDir_rejectsNonUUIDName() throws {
        let dir = tmp.appendingPathComponent("ShakeBoardHandoff-not-a-uuid", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(AppDelegate.validatedHandoffDir(dir.path, container: tmp))
    }

    func testValidatedHandoffDir_rejectsWrongContainerAndTraversal() throws {
        // A valid-looking folder sitting in a DIFFERENT container is refused.
        let other = tmp.appendingPathComponent("other", isDirectory: true)
        let dir = other.appendingPathComponent("ShakeBoardHandoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let realContainer = tmp.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: realContainer, withIntermediateDirectories: true)
        XCTAssertNil(AppDelegate.validatedHandoffDir(dir.path, container: realContainer))
        // A ../ escape out of the container is also refused (parent != base after standardizing).
        let escape = realContainer.appendingPathComponent("../ShakeBoardHandoff-\(UUID().uuidString)").path
        XCTAssertNil(AppDelegate.validatedHandoffDir(escape, container: realContainer))
    }

    func testValidatedHandoffDir_rejectsSymlink() throws {
        // A symlink named ShakeBoardHandoff-<uuid> pointing at a dir outside the container must not pass:
        // resolvingSymlinksInPath resolves it to the real target, whose parent != container.
        let target = tmp.appendingPathComponent("realdir", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let container = tmp.appendingPathComponent("c", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let link = container.appendingPathComponent("ShakeBoardHandoff-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(AppDelegate.validatedHandoffDir(link.path, container: container))
    }

    func testValidatedHandoffDir_rejectsPlainFile() throws {
        // Correct name + correct container, but it's a regular file, not a directory.
        let file = tmp.appendingPathComponent("ShakeBoardHandoff-\(UUID().uuidString)")
        try "x".data(using: .utf8)!.write(to: file)
        XCTAssertNil(AppDelegate.validatedHandoffDir(file.path, container: tmp))
    }

    // MARK: - Owned-copy delete boundary (P1-8): both the bit AND the path must hold

    func testDeleteOwnedCopy_gatesOnBitAndPath() throws {
        let model = ShelfModel(baseDir: tmp)
        let shelf = tmp.appendingPathComponent("Shelf", isDirectory: true)

        // 1) Owned copy inside Shelf/ -> deleted on remove.
        let ownedInside = try makeFile("owned.txt", in: shelf)
        model.add([ownedInside], owned: true)
        model.remove(model.items.first { $0.url.lastPathComponent == "owned.txt" }!)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedInside.path), "owned copy in Shelf/ should be deleted")

        // 2) Non-owned original inside Shelf/ -> the bit gate protects it.
        let bookmarkInside = try makeFile("bookmarked.txt", in: shelf)
        model.add([bookmarkInside], owned: false)
        model.remove(model.items.first { $0.url.lastPathComponent == "bookmarked.txt" }!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookmarkInside.path), "bookmarked original must never be deleted")

        // 3) Owned bit but path OUTSIDE Shelf/ -> the path gate protects it.
        let ownedOutside = try makeFile("outside.txt")
        model.add([ownedOutside], owned: true)
        model.remove(model.items.first { $0.url.lastPathComponent == "outside.txt" }!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedOutside.path), "must not delete outside the store")

        // 4) Finder original outside Shelf/ -> untouched.
        let plainOriginal = try makeFile("original.txt")
        model.add([plainOriginal], owned: false)
        model.remove(model.items.first { $0.url.lastPathComponent == "original.txt" }!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plainOriginal.path))
    }

    // MARK: - Dedup (P1-3): duplicate add moves the existing chip to front, no double-shelving

    func testAddDedup_movesExistingToFront() throws {
        let model = ShelfModel(baseDir: tmp)
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        model.add([a, b])
        XCTAssertEqual(model.items.map { $0.url.lastPathComponent }, ["a.txt", "b.txt"])
        model.add([b])   // re-add the second one
        XCTAssertEqual(model.items.count, 2, "duplicate must not double-shelve")
        XCTAssertEqual(model.items.first?.url.lastPathComponent, "b.txt", "duplicate moves to front")
    }

    // MARK: - Persistence round-trip

    func testSaveLoad_roundTrip() throws {
        let a = try makeFile("keep.txt")
        let m1 = ShelfModel(baseDir: tmp)
        m1.add([a], owned: true)

        let m2 = ShelfModel(baseDir: tmp)
        m2.load()
        XCTAssertEqual(m2.items.count, 1)
        XCTAssertEqual(m2.items.first?.url.lastPathComponent, "keep.txt")
        XCTAssertFalse(m2.items.first?.missing ?? true)
        XCTAssertTrue(m2.items.first?.ownedCopy ?? false, "ownedCopy bit must survive save/load")
    }

    // MARK: - Schema version migration (P1-9)

    func testMigration_legacyUnversionedFileLoadsAndUpgrades() throws {
        // Hand-build a pre-versioned (v0) bare-array shelf.json with a real, resolvable bookmark.
        let file = try makeFile("legacy.txt")
        let bm = try file.bookmarkData().base64EncodedString()
        let json = """
        [{"id":"\(UUID().uuidString)","bookmark":"\(bm)","name":"legacy.txt"}]
        """
        let store = tmp.appendingPathComponent("shelf.json")
        try json.data(using: .utf8)!.write(to: store)

        let model = ShelfModel(baseDir: tmp)
        model.load()
        XCTAssertEqual(model.items.count, 1, "legacy file must load")
        XCTAssertFalse(model.items.first?.ownedCopy ?? true, "missing ownedCopy defaults to false")

        // load() should have rewritten it in the versioned envelope.
        let raw = try Data(contentsOf: store)
        let obj = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(obj?["version"] as? Int, 1, "file should be upgraded to version 1")
    }

    func testMigration_unknownFutureVersionQuarantined() throws {
        let store = tmp.appendingPathComponent("shelf.json")
        try #"{"version":999,"items":[]}"#.data(using: .utf8)!.write(to: store)

        let model = ShelfModel(baseDir: tmp)
        model.load()
        XCTAssertTrue(model.items.isEmpty, "a future-version file must not be misread")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "original moved aside")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("shelf.json.corrupt").path), "quarantined copy exists")
    }

    // MARK: - Corrupt JSON quarantine (not silent data loss)

    func testCorruptJSON_isQuarantinedNotDropped() throws {
        let store = tmp.appendingPathComponent("shelf.json")
        try "this is not json {{{".data(using: .utf8)!.write(to: store)

        let model = ShelfModel(baseDir: tmp)
        model.load()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tmp.appendingPathComponent("shelf.json.corrupt").path),
            "corrupt file must be backed up, never overwritten by the next save")
    }

    // MARK: - Missing file greys out, is never dropped (F2)

    func testMissingFile_greyedNotDropped() throws {
        let a = try makeFile("gone.txt")
        let m1 = ShelfModel(baseDir: tmp)
        m1.add([a])
        try FileManager.default.removeItem(at: a)   // original vanishes (moved/deleted volume)

        let m2 = ShelfModel(baseDir: tmp)
        m2.load()
        XCTAssertEqual(m2.items.count, 1, "a missing item must survive load, greyed -- not be dropped")
        XCTAssertTrue(m2.items.first?.missing ?? false)
    }

    // MARK: - Shake detector: reversal counting

    func testShake_firesOnEnoughReversals() {
        let shake = ShakeDetector()
        shake.minTravel = 10; shake.neededReversals = 2; shake.windowSec = 1.0
        var fired = false
        shake.onShake = { fired = true }
        shake.feed(deltaX: 15, time: 0.0)    // establish direction
        shake.feed(deltaX: -15, time: 0.1)   // reversal 1
        shake.feed(deltaX: 15, time: 0.2)    // reversal 2 -> fire
        XCTAssertTrue(fired)
    }

    func testShake_doesNotFireBelowThreshold() {
        let shake = ShakeDetector()
        shake.minTravel = 10; shake.neededReversals = 5; shake.windowSec = 1.0
        var fired = false
        shake.onShake = { fired = true }
        shake.feed(deltaX: 15, time: 0.0)
        shake.feed(deltaX: -15, time: 0.1)
        shake.feed(deltaX: 15, time: 0.2)
        XCTAssertFalse(fired, "three reversals must not fire when five are required")
    }

    func testCalibrationAnalysisCountsSyntheticLeftRightSwings() {
        let result = AppDelegate.analyzeCalibrationSamples([30, -30, 30, -30])
        XCTAssertGreaterThanOrEqual(result.reversals, 2)
        XCTAssertGreaterThan(result.swing, 10)
    }

    // MARK: - Bounded-synchronous image optimization (P1-5)

    func testOptimizerSyncCap_smallDecodesLargeDefersToOriginal() {
        // Small + typical-phone images decode inline; past ~24MP we drag the original so drag start
        // never blocks; zero/overflow dimensions never decode.
        XCTAssertTrue(DragImageOptimizer.canOptimizeSynchronously(width: 1000, height: 1000))
        XCTAssertTrue(DragImageOptimizer.canOptimizeSynchronously(width: 4000, height: 3000))   // 12MP
        XCTAssertFalse(DragImageOptimizer.canOptimizeSynchronously(width: 6000, height: 5000))  // 30MP > cap
        XCTAssertFalse(DragImageOptimizer.canOptimizeSynchronously(width: 0, height: 100))
        XCTAssertFalse(DragImageOptimizer.canOptimizeSynchronously(width: Int.max, height: 2))  // overflow
    }

    // MARK: - Save failure surfaces a flag, not silent loss (P1-6)

    func testSaveFailure_setsFlag() throws {
        // Point the store base at a path UNDER a regular file so createDirectory + write can't succeed.
        let blocker = tmp.appendingPathComponent("blocker")
        try "x".data(using: .utf8)!.write(to: blocker)
        let model = ShelfModel(baseDir: blocker.appendingPathComponent("sub", isDirectory: true))
        let f = try makeFile("f.txt")
        model.add([f])
        XCTAssertTrue(model.lastSaveFailed, "a failed write (after one retry) must set the in-memory flag")
    }

    func testSaveSuccess_leavesFlagClear() throws {
        let model = ShelfModel(baseDir: tmp)
        let f = try makeFile("ok.txt")
        model.add([f])
        XCTAssertFalse(model.lastSaveFailed, "a normal save must not raise the failure flag")
    }

    // MARK: - Extracted constants stay sane (P3-2/P3-4)

    nonisolated func testLimits_constantsAreSane() {
        XCTAssertGreaterThan(Limits.maxHandoffFiles, 0)
        XCTAssertEqual(Limits.maxIngestFileBytes, 4 * 1024 * 1024 * 1024, "4 GiB ingest cap")
        XCTAssertGreaterThan(Limits.optimizerCacheEntries, 0, "the drag cache must be bounded, not unbounded")
    }
}
