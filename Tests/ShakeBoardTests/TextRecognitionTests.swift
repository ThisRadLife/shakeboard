//
//  TextRecognitionTests.swift
//  On-device OCR persistence, cancellation, shelf caching, and derived text actions.
//  Every dependency is injected; these tests never touch the real pasteboard or ShakeBoard data directory.
//

import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import ShakeBoard

private final class FakeTextRecognizer: TextRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [String]
    private var failuresRemaining: Int
    private(set) var calls: [URL] = []
    var onStart: (() -> Void)?
    var release: DispatchSemaphore?

    init(_ results: [String], failures: Int = 0) {
        self.results = results
        self.failuresRemaining = failures
    }

    func recognize(imageAt url: URL) throws -> String {
        lock.lock()
        calls.append(url)
        let shouldFail = failuresRemaining > 0
        if shouldFail { failuresRemaining -= 1 }
        let result = shouldFail ? "" : (results.isEmpty ? "" : results.removeFirst())
        let onStart = self.onStart
        let release = self.release
        lock.unlock()
        onStart?()
        release?.wait()
        if shouldFail { throw TextRecognitionError.unreadableImage }
        return result
    }

    var callCount: Int { lock.withLock { calls.count } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

private final class CacheWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var encoded: [Int] = []
    private(set) var encodedOnMain = false
    private(set) var written: [String] = []

    func recordEncode(_ value: Int) {
        lock.withLock {
            encoded.append(value)
            encodedOnMain = encodedOnMain || Thread.isMainThread
        }
    }

    func recordWrite(_ value: String) { lock.withLock { written.append(value) } }

    var snapshot: (encoded: [Int], encodedOnMain: Bool, written: [String]) {
        lock.withLock { (encoded, encodedOnMain, written) }
    }
}

private final class CacheEncodingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var ranOnMain = false

    func record() {
        lock.withLock {
            count += 1
            ranOnMain = ranOnMain || Thread.isMainThread
        }
    }

    var snapshot: (count: Int, ranOnMain: Bool) { lock.withLock { (count, ranOnMain) } }
}

@MainActor
final class TextRecognitionTests: XCTestCase {
    private var tmp: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ClipStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardOCRTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        suite = "ShakeBoardOCRTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = ClipStore(baseDir: tmp)
        store.load()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: tmp)
    }

    private func imageClip(_ count: Int = 1) -> Clip {
        let reps = (0..<count).map { _ in [RawRep(type: ClipTypes.png, data: imageData(4, 4, type: .png))] }
        let cap = CapturedClipboard(snapshot: RawSnapshot(changeCount: 1, allTypes: [ClipTypes.png], items: reps),
                                    sourceBundleID: "com.apple.Preview", sourceAppName: "Preview", capturedAt: Date())
        let done = expectation(description: "image ingest")
        var clip: Clip?
        store.ingest(cap) { saved, _ in clip = saved; done.fulfill() }
        wait(for: [done], timeout: 5)
        store.flush()
        return try! XCTUnwrap(clip)
    }

    private func waitForIdle(_ service: OCRService, file: StaticString = #filePath, line: UInt = #line) {
        let done = expectation(description: "OCR idle")
        service.whenIdle { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testShelfCacheWriterEncodesOffMainAndWritesOnlyNewestPendingRevision() {
        let probe = CacheWriterProbe()
        let firstEncodeStarted = expectation(description: "first cache encode started")
        let releaseFirstEncode = DispatchSemaphore(value: 0)
        let writer = ShelfCacheWriter<Int>(encode: { value in
            probe.recordEncode(value)
            if value == 1 {
                firstEncodeStarted.fulfill()
                releaseFirstEncode.wait()
            }
            return Data(String(value).utf8)
        }, write: { data, _ in
            probe.recordWrite(String(decoding: data, as: UTF8.self))
            return true
        })
        let url = tmp.appendingPathComponent("coalesced-cache.json")

        writer.schedule(1, to: url, revision: 1)
        wait(for: [firstEncodeStarted], timeout: 2)
        writer.schedule(2, to: url, revision: 2)
        writer.schedule(3, to: url, revision: 3)
        releaseFirstEncode.signal()
        XCTAssertTrue(writer.flush(timeout: 1))

        let afterDrain = probe.snapshot
        XCTAssertEqual(afterDrain.encoded, [1, 3])
        XCTAssertFalse(afterDrain.encodedOnMain)
        XCTAssertEqual(afterDrain.written, ["3"])

        XCTAssertTrue(writer.flush(timeout: 1))
        XCTAssertEqual(probe.snapshot.encoded, afterDrain.encoded,
                       "waiting for an idle writer must not schedule another encoding")
    }

    func testClipSidecarWrittenOnceAcrossEnqueuesAndReloadWithOwnerOnlyPermissions() throws {
        let clip = imageClip(2)
        let fake = FakeTextRecognizer(["first image", "second image"])
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake, defaults: defaults, backfillDelay: 0)

        service.enqueue(clip)
        service.enqueue(clip)
        waitForIdle(service)

        let sidecar = store.payloadDir(clip.id).appendingPathComponent("ocr.txt")
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "first image\n\nsecond image")
        XCTAssertEqual(fake.callCount, 2, "each PNG is recognized once, not each enqueue")
        let mode = try FileManager.default.attributesOfItem(atPath: sidecar.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        let reloadedFake = FakeTextRecognizer(["must not run"])
        let reloaded = OCRService(baseDir: tmp, store: store, recognizer: reloadedFake, defaults: defaults, backfillDelay: 0)
        reloaded.enqueue(clip)
        waitForIdle(reloaded)
        XCTAssertEqual(reloadedFake.callCount, 0)
        XCTAssertEqual(reloaded.text(for: clip), "first image\n\nsecond image")
    }

    func testEmptyOCRResultIsCachedAndNeverRetried() throws {
        let clip = imageClip()
        let fake = FakeTextRecognizer([""])
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake, defaults: defaults, backfillDelay: 0)
        service.enqueue(clip)
        waitForIdle(service)
        service.enqueue(clip)
        waitForIdle(service)

        let sidecar = store.payloadDir(clip.id).appendingPathComponent("ocr.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(try Data(contentsOf: sidecar), Data())
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(service.status(for: clip), .complete)
        XCTAssertNil(service.text(for: clip), "empty completed OCR is not exposed as useful text")
    }

    func testFailedClipIsNotRetriedByStoreChangesOrExplicitEnqueue() {
        let clip = imageClip()
        let fake = FakeTextRecognizer(["must not recover in this launch"], failures: 1)
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake, defaults: defaults, backfillDelay: 0)

        service.enqueue(clip)
        waitForIdle(service)
        XCTAssertEqual(service.status(for: clip), .failed)

        store.markUsed(clip.id)
        service.enqueue(clip)
        waitForIdle(service)

        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(service.status(for: clip), .failed)
        XCTAssertNil(service.text(for: clip))
    }

    func testFailedClipCanRetryAfterServiceRelaunch() {
        let clip = imageClip()
        let failing = FakeTextRecognizer([], failures: 1)
        var service: OCRService? = OCRService(baseDir: tmp, store: store, recognizer: failing,
                                              defaults: defaults, backfillDelay: 0)

        service?.enqueue(clip)
        waitForIdle(try! XCTUnwrap(service))
        XCTAssertEqual(service?.status(for: clip), .failed)
        service = nil

        let retry = FakeTextRecognizer(["read after relaunch"])
        let relaunched = OCRService(baseDir: tmp, store: store, recognizer: retry,
                                    defaults: defaults, backfillDelay: 0)
        relaunched.enqueue(clip)
        waitForIdle(relaunched)

        XCTAssertEqual(retry.callCount, 1)
        XCTAssertEqual(relaunched.status(for: clip), .complete)
        XCTAssertEqual(relaunched.text(for: clip), "read after relaunch")
    }

    func testRemovedClipQueuedBehindAnotherJobDoesNotWriteOrRecreatePayloadDirectory() {
        let first = imageClip(), removed = imageClip()
        let fake = FakeTextRecognizer(["one", "two"])
        let started = expectation(description: "first OCR started")
        fake.onStart = { started.fulfill() }
        fake.release = DispatchSemaphore(value: 0)
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake, defaults: defaults, backfillDelay: 0)
        service.enqueue(first)
        wait(for: [started], timeout: 2)
        service.enqueue(removed)
        store.remove(removed.id)
        store.flush()
        fake.release?.signal()
        waitForIdle(service)

        XCTAssertEqual(fake.callCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.payloadDir(removed.id).path))
    }

    func testClearAllWhileJobQueuedDropsItWithoutRecreatingPayloadDirectory() {
        let first = imageClip(), cleared = imageClip()
        let fake = FakeTextRecognizer(["one", "two"])
        let started = expectation(description: "first OCR started")
        fake.onStart = { started.fulfill() }
        fake.release = DispatchSemaphore(value: 0)
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake, defaults: defaults, backfillDelay: 0)
        service.enqueue(first)
        wait(for: [started], timeout: 2)
        service.enqueue(cleared)
        XCTAssertTrue(store.clearAll())
        fake.release?.signal()
        waitForIdle(service)

        XCTAssertEqual(fake.callCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.payloadDir(cleared.id).path))
    }

    func testPreferenceOffDropsOCRJobs() {
        var prefs = PerchPrefs(defaults: defaults)
        prefs.recognizeTextInImages = false
        let clip = imageClip()
        let fake = FakeTextRecognizer(["must not run"])
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake, defaults: defaults, backfillDelay: 0)
        service.enqueue(clip)
        service.startBackfill()
        waitForIdle(service)
        XCTAssertEqual(fake.callCount, 0)
        XCTAssertEqual(service.status(for: clip), .notStarted)
    }

    func testTurningPreferenceOffPurgesRecognizedTextFromMemoryAndDiskThenReenableRebuildsIt() throws {
        let clip = imageClip()
        let shelfImage = tmp.appendingPathComponent("private-shelf.png")
        try imageData(4, 4, type: .png).write(to: shelfImage)
        let item = ShelfItem(id: UUID(), url: shelfImage, bookmark: try shelfImage.bookmarkData())
        let fake = FakeTextRecognizer([
            "private clip needle", "private shelf needle",
            "fresh clip needle", "fresh shelf needle"
        ])
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake,
                                 defaults: defaults, backfillDelay: 0)

        service.enqueue(clip)
        service.syncShelf([item])
        waitForIdle(service)

        let sidecar = store.payloadDir(clip.id).appendingPathComponent("ocr.txt")
        let shelfCache = tmp.appendingPathComponent("shelf-ocr.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shelfCache.path))
        XCTAssertEqual(fake.callCount, 2)

        let nested = store.payloadDir(clip.id).appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedOCR = nested.appendingPathComponent("ocr.txt")
        try Data("not a direct sidecar".utf8).write(to: nestedOCR)
        let outside = tmp.appendingPathComponent("outside-payload", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideOCR = outside.appendingPathComponent("ocr.txt")
        try Data("must survive".utf8).write(to: outsideOCR)
        try FileManager.default.createSymbolicLink(
            at: store.dir.appendingPathComponent(UUID().uuidString, isDirectory: true),
            withDestinationURL: outside
        )

        func matchingSections() -> StripSections {
            StripSections.build(
                clips: [clip], pins: [], files: [item], query: "needle", filter: .all,
                hideImageClips: false, kind: { ClipClassifier.kind(of: $0, head: nil) },
                text: { _ in nil }, ocr: { service.searchText(for: $0) },
                fileOCR: { service.searchText(for: $0) },
                isImageFile: { _ in true }
            )
        }
        XCTAssertEqual(matchingSections().order.count, 2)

        var prefs = PerchPrefs(defaults: defaults)
        prefs.recognizeTextInImages = false
        service.preferencesChanged()
        waitForIdle(service)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shelfCache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nestedOCR.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideOCR.path))
        XCTAssertNil(service.text(for: clip))
        XCTAssertNil(service.searchText(for: clip))
        XCTAssertNil(service.text(for: item))
        XCTAssertNil(service.searchText(for: item))
        XCTAssertEqual(service.status(for: clip), .notStarted)
        XCTAssertEqual(service.status(for: item), .notStarted)
        XCTAssertTrue(matchingSections().isEmpty)

        prefs.recognizeTextInImages = true
        service.preferencesChanged()
        waitForIdle(service)

        XCTAssertEqual(fake.callCount, 4)
        XCTAssertEqual(service.text(for: clip), "fresh clip needle")
        XCTAssertEqual(service.text(for: item), "fresh shelf needle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shelfCache.path))
    }

    func testClipRecognitionFinishingAfterDisableCannotRestoreSidecarOrShelfCache() {
        let clip = imageClip()
        let fake = FakeTextRecognizer(["stale private text"])
        let started = expectation(description: "clip recognition started")
        let release = DispatchSemaphore(value: 0)
        fake.onStart = { started.fulfill() }
        fake.release = release
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake,
                                 defaults: defaults, backfillDelay: 0)

        service.enqueue(clip)
        wait(for: [started], timeout: 2)
        var prefs = PerchPrefs(defaults: defaults)
        prefs.recognizeTextInImages = false
        service.preferencesChanged()
        fake.onStart = nil
        fake.release = nil
        release.signal()
        waitForIdle(service)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.payloadDir(clip.id).appendingPathComponent("ocr.txt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("shelf-ocr.json").path))
        XCTAssertNil(service.searchText(for: clip))
        XCTAssertEqual(service.status(for: clip), .notStarted)
    }

    func testShelfRecognitionFinishingAfterDisableCannotRestoreShelfCache() throws {
        let image = tmp.appendingPathComponent("blocked-shelf.png")
        try imageData(4, 4, type: .png).write(to: image)
        let item = ShelfItem(id: UUID(), url: image, bookmark: try image.bookmarkData())
        let fake = FakeTextRecognizer(["stale shelf text"])
        let started = expectation(description: "shelf recognition started")
        let release = DispatchSemaphore(value: 0)
        fake.onStart = { started.fulfill() }
        fake.release = release
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake,
                                 defaults: defaults, backfillDelay: 0)

        service.syncShelf([item])
        wait(for: [started], timeout: 2)
        var prefs = PerchPrefs(defaults: defaults)
        prefs.recognizeTextInImages = false
        service.preferencesChanged()
        fake.onStart = nil
        fake.release = nil
        release.signal()
        waitForIdle(service)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("shelf-ocr.json").path))
        XCTAssertNil(service.searchText(for: item))
        XCTAssertEqual(service.status(for: item), .notStarted)
    }

    func testTurningPreferenceOffAndBackOnRequeuesActiveRecognition() throws {
        let clip = imageClip()
        let fake = FakeTextRecognizer(["stale", "current"])
        let started = expectation(description: "first OCR started")
        let release = DispatchSemaphore(value: 0)
        fake.onStart = { started.fulfill() }
        fake.release = release
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake, defaults: defaults, backfillDelay: 0)

        service.enqueue(clip)
        wait(for: [started], timeout: 2)
        var prefs = PerchPrefs(defaults: defaults)
        prefs.recognizeTextInImages = false
        service.preferencesChanged()
        prefs.recognizeTextInImages = true
        service.preferencesChanged()
        fake.onStart = nil
        fake.release = nil
        release.signal()
        waitForIdle(service)

        XCTAssertEqual(fake.callCount, 2)
        XCTAssertEqual(service.text(for: clip), "current")
        XCTAssertEqual(try String(contentsOf: store.payloadDir(clip.id).appendingPathComponent("ocr.txt")),
                       "current")
    }

    func testShelfCacheRerunsOnMtimeChangeAndPrunesRemovedItems() throws {
        let image = tmp.appendingPathComponent("shelf.png")
        try imageData(4, 4, type: .png).write(to: image)
        let item = ShelfItem(id: UUID(), url: image, bookmark: try image.bookmarkData())
        let fake = FakeTextRecognizer(["old label", "new label"])
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake, defaults: defaults, backfillDelay: 0)

        service.syncShelf([item])
        waitForIdle(service)
        XCTAssertEqual(service.text(for: item), "old label")
        XCTAssertEqual(fake.callCount, 1)

        let changed = Date(timeIntervalSinceNow: 10)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: image.path)
        service.syncShelf([item])
        waitForIdle(service)
        XCTAssertEqual(service.text(for: item), "new label")
        XCTAssertEqual(fake.callCount, 2)

        service.syncShelf([])
        waitForIdle(service)
        let cacheURL = tmp.appendingPathComponent("shelf-ocr.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        XCTAssertNil(object[item.id.uuidString])
        let mode = try FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testShelfCacheFlushWaitsWithoutEncodingAgainOnMain() throws {
        let image = tmp.appendingPathComponent("flush-cache.png")
        try imageData(4, 4, type: .png).write(to: image)
        let item = ShelfItem(id: UUID(), url: image, bookmark: try image.bookmarkData())
        let probe = CacheEncodingProbe()
        let service = OCRService(baseDir: tmp, store: store, recognizer: FakeTextRecognizer(["cache text"]),
                                 defaults: defaults, backfillDelay: 0, cacheEncode: { snapshot in
            probe.record()
            return try? JSONEncoder().encode(snapshot)
        })

        service.syncShelf([item])
        waitForIdle(service)
        let beforeFlush = probe.snapshot
        XCTAssertEqual(beforeFlush.count, 1)
        XCTAssertFalse(beforeFlush.ranOnMain)

        XCTAssertTrue(service.flushShelfCacheWrites(timeout: 1))
        XCTAssertEqual(probe.snapshot.count, beforeFlush.count)
    }

    func testShelfRemovalRewritesCacheWithoutWaitingForBlockedVisionWork() throws {
        let image = tmp.appendingPathComponent("shelf-remove.png")
        try imageData(4, 4, type: .png).write(to: image)
        let item = ShelfItem(id: UUID(), url: image, bookmark: try image.bookmarkData())
        let fake = FakeTextRecognizer(["shelf label", "blocked clip"])
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake,
                                 defaults: defaults, backfillDelay: 0)
        service.syncShelf([item])
        waitForIdle(service)

        let clip = imageClip()
        let started = expectation(description: "clip OCR blocks the Vision queue")
        let release = DispatchSemaphore(value: 0)
        fake.onStart = { started.fulfill() }
        fake.release = release
        service.enqueue(clip, priority: true)
        wait(for: [started], timeout: 2)

        service.syncShelf([])
        XCTAssertTrue(service.flushShelfCacheWrites(timeout: 1),
                      "cache deletion uses its own queue and must finish while Vision is blocked")
        let cacheURL = tmp.appendingPathComponent("shelf-ocr.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        XCTAssertNil(object[item.id.uuidString])

        fake.onStart = nil
        fake.release = nil
        release.signal()
        waitForIdle(service)
    }

    func testRemovedShelfRejectsActiveRecognitionAndCannotRestoreCacheEntry() throws {
        let image = tmp.appendingPathComponent("active-remove.png")
        try imageData(4, 4, type: .png).write(to: image)
        let item = ShelfItem(id: UUID(), url: image, bookmark: try image.bookmarkData())
        let fake = FakeTextRecognizer(["old text", "stale text"])
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake,
                                 defaults: defaults, backfillDelay: 0)
        service.syncShelf([item])
        waitForIdle(service)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 20)],
                                              ofItemAtPath: image.path)
        let started = expectation(description: "replacement shelf OCR started")
        let release = DispatchSemaphore(value: 0)
        fake.onStart = { started.fulfill() }
        fake.release = release
        service.syncShelf([item])
        wait(for: [started], timeout: 2)

        service.syncShelf([])
        XCTAssertTrue(service.flushShelfCacheWrites(timeout: 1))
        fake.onStart = nil
        fake.release = nil
        release.signal()
        waitForIdle(service)
        XCTAssertTrue(service.flushShelfCacheWrites(timeout: 1))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: tmp.appendingPathComponent("shelf-ocr.json"))) as? [String: Any])
        XCTAssertNil(object[item.id.uuidString])
        XCTAssertNil(service.text(for: item))
    }

    func testShelfMetadataResolutionAndStatRunOnceOffMain() throws {
        let image = tmp.appendingPathComponent("metadata.png")
        try imageData(4, 4, type: .png).write(to: image)
        let item = ShelfItem(id: UUID(), url: image, bookmark: Data())
        let fake = FakeTextRecognizer(["metadata text"])
        let lock = NSLock()
        var metadataCalls = 0
        var metadataRanOnMain = false
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake, defaults: defaults,
                                 backfillDelay: 0, shelfMetadata: { _ in
            lock.withLock {
                metadataCalls += 1
                metadataRanOnMain = metadataRanOnMain || Thread.isMainThread
            }
            return ShelfFileMetadata(url: image, size: 123, mtime: 456)
        })

        service.syncShelf([item])
        waitForIdle(service)

        XCTAssertEqual(lock.withLock { metadataCalls }, 1)
        XCTAssertFalse(lock.withLock { metadataRanOnMain })
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(service.text(for: item), "metadata text")
    }

    func testOwnedShelfItemReusesMatchingClipOCRWithoutSecondVisionRequest() throws {
        let clip = imageClip()
        let shelfImage = tmp.appendingPathComponent("owned-copy.png")
        try Data(contentsOf: try XCTUnwrap(store.imageURLs(for: clip).first)).write(to: shelfImage)
        let item = ShelfItem(id: UUID(), url: shelfImage, bookmark: try shelfImage.bookmarkData(), ownedCopy: true)
        let fake = FakeTextRecognizer(["shared OCR result"])
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake,
                                 defaults: defaults, backfillDelay: 0)

        service.reuseOCR(from: clip, imageIndex: 0, for: item)
        service.syncShelf([item])
        service.enqueue(clip, priority: true)
        waitForIdle(service)
        XCTAssertTrue(service.flushShelfCacheWrites(timeout: 1))

        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(service.text(for: clip), "shared OCR result")
        XCTAssertEqual(service.text(for: item), "shared OCR result")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: tmp.appendingPathComponent("shelf-ocr.json"))) as? [String: Any])
        XCTAssertNotNil(object[item.id.uuidString])
    }

    func testOwnedShelfFallsBackToItsFileWhenSourceClipOCRFails() throws {
        let clip = imageClip()
        let shelfImage = tmp.appendingPathComponent("owned-failed-source.png")
        try Data(contentsOf: try XCTUnwrap(store.imageURLs(for: clip).first)).write(to: shelfImage)
        let item = ShelfItem(id: UUID(), url: shelfImage, bookmark: try shelfImage.bookmarkData(), ownedCopy: true)
        let fake = FakeTextRecognizer(["shelf fallback"], failures: 1)
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake,
                                 defaults: defaults, backfillDelay: 0)

        service.reuseOCR(from: clip, imageIndex: 0, for: item)
        service.syncShelf([item])
        service.enqueue(clip, priority: true)
        waitForIdle(service)

        XCTAssertEqual(service.status(for: clip), .failed)
        XCTAssertEqual(fake.callCount, 2)
        XCTAssertEqual(service.text(for: item), "shelf fallback")
    }

    func testOwnedShelfFallsBackToItsFileWhenHistoryClearsDuringClipOCR() throws {
        let clip = imageClip()
        let shelfImage = tmp.appendingPathComponent("owned-cleared-source.png")
        try Data(contentsOf: try XCTUnwrap(store.imageURLs(for: clip).first)).write(to: shelfImage)
        let item = ShelfItem(id: UUID(), url: shelfImage, bookmark: try shelfImage.bookmarkData(), ownedCopy: true)
        let fake = FakeTextRecognizer(["discarded clip text", "shelf after clear"])
        let started = expectation(description: "clip OCR started")
        let release = DispatchSemaphore(value: 0)
        fake.onStart = { started.fulfill() }
        fake.release = release
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake,
                                 defaults: defaults, backfillDelay: 0)

        service.reuseOCR(from: clip, imageIndex: 0, for: item)
        service.syncShelf([item])
        service.enqueue(clip, priority: true)
        wait(for: [started], timeout: 2)
        XCTAssertTrue(store.clearAll())
        fake.onStart = nil
        fake.release = nil
        release.signal()
        waitForIdle(service)

        XCTAssertEqual(fake.callCount, 2)
        XCTAssertEqual(service.text(for: item), "shelf after clear")
    }

    func testFailedShelfImageRetriesOnlyAfterFileSignatureChanges() throws {
        let image = tmp.appendingPathComponent("failed-shelf.png")
        try imageData(4, 4, type: .png).write(to: image)
        let item = ShelfItem(id: UUID(), url: image, bookmark: try image.bookmarkData())
        let fake = FakeTextRecognizer(["recovered text"], failures: 1)
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake, defaults: defaults, backfillDelay: 0)

        service.syncShelf([item])
        waitForIdle(service)
        XCTAssertEqual(service.status(for: item), .failed)

        service.syncShelf([item])
        waitForIdle(service)
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(service.status(for: item), .failed)

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)],
                                              ofItemAtPath: image.path)
        service.syncShelf([item])
        waitForIdle(service)

        XCTAssertEqual(fake.callCount, 2)
        XCTAssertEqual(service.status(for: item), .complete)
        XCTAssertEqual(service.text(for: item), "recovered text")
    }

    func testLoadedShelfCacheIsHiddenUntilSignatureValidationAndMissingItemsNeverExposeIt() throws {
        let image = tmp.appendingPathComponent("loaded-shelf.png")
        try imageData(4, 4, type: .png).write(to: image)
        let item = ShelfItem(id: UUID(), url: image, bookmark: try image.bookmarkData())
        let firstFake = FakeTextRecognizer(["private old label"])
        var service: OCRService? = OCRService(baseDir: tmp, store: store, recognizer: firstFake,
                                              defaults: defaults, backfillDelay: 0)
        service?.syncShelf([item])
        waitForIdle(try XCTUnwrap(service))
        XCTAssertEqual(service?.text(for: item), "private old label")
        service = nil

        let reloadFake = FakeTextRecognizer(["must not rerun"])
        let reloaded = OCRService(baseDir: tmp, store: store, recognizer: reloadFake,
                                  defaults: defaults, backfillDelay: 0)
        reloaded.syncShelf([item])
        XCTAssertNil(reloaded.text(for: item), "disk cache is unavailable until size and mtime are checked")
        waitForIdle(reloaded)
        XCTAssertEqual(reloaded.text(for: item), "private old label")
        XCTAssertEqual(reloadFake.callCount, 0)

        let missing = ShelfItem(id: item.id, url: item.url, bookmark: item.bookmark, missing: true)
        reloaded.syncShelf([missing])
        XCTAssertNil(reloaded.text(for: missing))
        XCTAssertNotEqual(reloaded.status(for: missing), .complete)
    }

    func testShelfChangeDuringActiveRecognitionDropsOldResultAndRunsAgain() throws {
        let image = tmp.appendingPathComponent("changing-shelf.png")
        try imageData(4, 4, type: .png).write(to: image)
        let item = ShelfItem(id: UUID(), url: image, bookmark: try image.bookmarkData())
        let fake = FakeTextRecognizer(["obsolete label", "current label"])
        let started = expectation(description: "shelf OCR started")
        let release = DispatchSemaphore(value: 0)
        fake.onStart = { started.fulfill() }
        fake.release = release
        let service = OCRService(baseDir: tmp, store: store, recognizer: fake,
                                 defaults: defaults, backfillDelay: 0)

        service.syncShelf([item])
        wait(for: [started], timeout: 2)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 20)],
                                              ofItemAtPath: image.path)
        service.syncShelf([item])
        fake.onStart = nil
        fake.release = nil
        release.signal()
        waitForIdle(service)

        XCTAssertEqual(fake.callCount, 2)
        XCTAssertEqual(service.text(for: item), "current label")
    }

    func testShelfHoverPublicationDoesNotInvalidateOCR() throws {
        let image = tmp.appendingPathComponent("hover-shelf.png")
        try imageData(4, 4, type: .png).write(to: image)
        let item = ShelfItem(id: UUID(), url: image, bookmark: try image.bookmarkData())
        let shelf = ShelfModel(baseDir: tmp)
        shelf.items = [item]
        let fake = FakeTextRecognizer(["stable label"])
        let service = OCRService(baseDir: tmp, store: store, shelf: shelf, recognizer: fake,
                                 defaults: defaults, backfillDelay: 0)
        waitForIdle(service)
        XCTAssertEqual(service.text(for: item), "stable label")

        shelf.hovering = true
        shelf.hoveredID = item.id
        XCTAssertEqual(service.text(for: item), "stable label")
        XCTAssertEqual(service.status(for: item), .complete)
        XCTAssertEqual(fake.callCount, 1)
    }

    func testVisionRecognizerChecksPixelCapFromURLHeader() throws {
        let image = tmp.appendingPathComponent("pixel-cap.png")
        var data = imageData(4, 4, type: .png)
        data.append(Data(repeating: 0, count: 1_000_000))
        try data.write(to: image)
        XCTAssertEqual(ClipNormalizer.pixelSize(image)?.w, 4)
        XCTAssertEqual(ClipNormalizer.pixelSize(image)?.h, 4)

        let old = ClipLimits.maxImagePixels
        ClipLimits.maxImagePixels = 15
        defer { ClipLimits.maxImagePixels = old }
        XCTAssertThrowsError(try VisionTextRecognizer().recognize(imageAt: image)) { error in
            guard case TextRecognitionError.imageTooLarge = error else {
                return XCTFail("expected imageTooLarge, got \(error)")
            }
        }
    }

    func testCopyRecognizedTextCreatesDerivedClipAndUsesTaggedPasteboardWriter() throws {
        let source = imageClip()
        let state = StripState(shelf: ShelfModel(baseDir: tmp), store: store, pins: ClipPins(baseDir: tmp))
        let controller = StripController(state: state)
        let pasteboard = FakePasteboard()
        let oldPasteboard = ClipboardWriter.pasteboard
        ClipboardWriter.pasteboard = pasteboard
        defer { ClipboardWriter.pasteboard = oldPasteboard }
        let done = expectation(description: "copy recognized text")

        controller.useRecognizedText("Kiln schedule Friday", from: source.id, paste: false) { outcome in
            XCTAssertEqual(outcome, .copiedOnly)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        store.flush()

        let derived = try XCTUnwrap(store.clips.first { $0.derivedFrom == source.id })
        XCTAssertEqual(derived.kind, .text)
        XCTAssertEqual(store.fullText(for: derived), "Kiln schedule Friday")
        XCTAssertEqual(pasteboard.items.first?.first?.type, ClipTypes.plainText)
        XCTAssertEqual(String(data: try XCTUnwrap(pasteboard.items.first?.first?.data), encoding: .utf8),
                       "Kiln schedule Friday")
        XCTAssertTrue(pasteboard.extraTypes.contains(ClipTypes.shakeboardMarker))
    }
}
