//
//  PinboardTests.swift -- named, ordered pinboards and their retention behavior.
//  Every test uses an injected temporary data directory and never touches the real pasteboard.
//

import XCTest
@testable import ShakeBoard

@MainActor
final class PinboardTests: XCTestCase {
    private var tmp: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardPinboards-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func writeJSON(_ object: Any, to name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: tmp.appendingPathComponent(name), options: .atomic)
    }

    private func loadedStore() -> PinboardStore {
        let store = PinboardStore(baseDir: tmp)
        store.load()
        return store
    }

    private func ingest(_ store: ClipStore, _ text: String, at date: Date? = nil) -> Clip {
        let exp = expectation(description: "ingest \(text)")
        var result: Clip?
        let snapshot = RawSnapshot(changeCount: 1, allTypes: [ClipTypes.plainText], items: [[textRep(text)]])
        let captured = CapturedClipboard(snapshot: snapshot, sourceBundleID: nil, sourceAppName: nil,
                                         capturedAt: date ?? now)
        store.ingest(captured) { clip, _ in result = clip; exp.fulfill() }
        wait(for: [exp], timeout: 5)
        store.flush()
        return result!
    }

    func testMigrationKeepsLegacyPinOrderAndLeavesLegacyFileUntouched() throws {
        let ids = [UUID(), UUID(), UUID()]
        let legacy: [String: Any] = ["version": 1, "ids": ids.map(\.uuidString)]
        try writeJSON(legacy, to: "clip-pins.json")
        let legacyBytes = try Data(contentsOf: tmp.appendingPathComponent("clip-pins.json"))

        let store = loadedStore()

        XCTAssertEqual(store.boards.count, 1)
        XCTAssertEqual(store.defaultBoard?.name, "Pinned")
        XCTAssertEqual(store.defaultBoard?.color, .yellow)
        XCTAssertEqual(store.defaultBoard?.clipIDs, ids)
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("clip-pins.json")), legacyBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertFalse(store.retentionUnknown)
        XCTAssertNil(store.setAsideFileName)
        var inputs = SettingsAlerts.Inputs()
        inputs.pinboardsSetAside = store.setAsideFileName
        XCTAssertTrue(SettingsAlerts.compute(inputs).isEmpty)
    }

    func testPersistenceRoundTripKeepsBoardAndClipOrder() {
        let store = loadedStore()
        let a = UUID(), b = UUID(), c = UUID()
        let blue = store.create(name: "Gallery addresses", color: .blue, clipIDs: [a, b])!
        let pink = store.create(name: "Replies", color: .pink, clipIDs: [c])!
        XCTAssertTrue(store.moveBoard(pink, by: -1))
        XCTAssertTrue(store.moveClip(b, to: 0, in: blue))

        let reloaded = loadedStore()
        XCTAssertEqual(reloaded.boards.map(\.id), [store.defaultBoard!.id, pink, blue])
        XCTAssertEqual(reloaded.board(blue)?.clipIDs, [b, a])
        XCTAssertEqual(reloaded.board(blue)?.color, .blue)
        let perms = (try? FileManager.default.attributesOfItem(atPath: reloaded.url.path))?[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testLoadHardensExistingPinboardsPermissions() throws {
        let store = loadedStore()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
        let before = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(before, 0o644)

        let reloaded = loadedStore()

        let after = try FileManager.default.attributesOfItem(atPath: reloaded.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(after, 0o600)
    }

    func testMultiSelectAddKeepsPickOrderAndSkipsExistingAndInputDuplicates() {
        let store = loadedStore()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let board = store.create(name: "Orders", color: .orange, clipIDs: [a])!

        XCTAssertTrue(store.add([c, b, c, a, d], to: board))

        XCTAssertEqual(store.board(board)?.clipIDs, [c, b, d, a])
    }

    func testCorruptAndNewerFilesAreSetAsideAndNeverOverwritten() throws {
        let invalidFiles = [Data("not json".utf8),
                            try JSONSerialization.data(withJSONObject: ["version": 99, "boards": []])]
        for (index, bytes) in invalidFiles.enumerated() {
            let dir = tmp.appendingPathComponent("case-\(index)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("pinboards.json")
            try bytes.write(to: url)

            let store = PinboardStore(baseDir: dir)
            store.load()

            let asides = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("pinboards.json.unreadable-") }
            XCTAssertEqual(asides.count, 1)
            XCTAssertEqual(try Data(contentsOf: asides[0]), bytes)
            XCTAssertTrue(store.retentionUnknown)
            XCTAssertEqual(store.setAsideFileName, asides[0].lastPathComponent)
            XCTAssertEqual(store.boards.count, 1)
            XCTAssertTrue(store.defaultBoard?.isDefaultPinned == true)
            let freshData = try Data(contentsOf: store.url)
            let freshJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: freshData) as? [String: Any])
            XCTAssertEqual(freshJSON["version"] as? Int, 1)
            XCTAssertNotNil(freshJSON["boards"] as? [[String: Any]])
            XCTAssertNotNil(store.create(name: "After recovery", color: .teal))
            XCTAssertEqual(try Data(contentsOf: asides[0]), bytes, "the quarantined original is never overwritten")

            store.load()
            XCTAssertFalse(store.retentionUnknown)
            XCTAssertNil(store.setAsideFileName)
        }
    }

    func testSuccessfulQuarantineProtectsOldClipKnownOnlyToUnreadableBoardFile() throws {
        let initial = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        initial.load()
        let old = ingest(initial, "old board-only copy")
        initial.flush()

        let originalBoards = loadedStore()
        _ = originalBoards.create(name: "Only here", color: .purple, clipIDs: [old.id])
        let originalBytes = try Data(contentsOf: originalBoards.url)
        var corruptBytes = originalBytes
        corruptBytes.replaceSubrange(0..<1, with: Data([0]))
        try corruptBytes.write(to: originalBoards.url, options: .atomic)

        let boards = PinboardStore(baseDir: tmp, clock: { [unowned self] in self.now })
        boards.load()
        XCTAssertTrue(boards.retentionUnknown)

        now = now.addingTimeInterval(30 * 24 * 3600)
        let clips = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        clips.maxAge = 1
        clips.pinned = { [unowned clips, unowned boards] in
            var ids = boards.allClipIDs
            if boards.retentionUnknown { ids.formUnion(clips.clips.map(\.id)) }
            return ids
        }
        clips.load()
        clips.flush()

        XCTAssertNotNil(clips.clip(old.id))
        let asideName = try XCTUnwrap(boards.setAsideFileName)
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent(asideName)), corruptBytes)
    }

    func testFailedQuarantineProtectsEveryClipDuringLaunchRetention() throws {
        let initial = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        initial.load()
        let first = ingest(initial, "first")
        let second = ingest(initial, "second")
        initial.flush()
        try Data("not json".utf8).write(to: tmp.appendingPathComponent("pinboards.json"), options: .atomic)

        let boards = PinboardStore(baseDir: tmp, moveItem: { _, _ in
            throw NSError(domain: "PinboardTests", code: 1)
        })
        boards.load()
        XCTAssertTrue(boards.readOnly)
        XCTAssertTrue(boards.retentionUnknown)
        XCTAssertNil(boards.setAsideFileName)

        now = now.addingTimeInterval(30 * 24 * 3600)
        let clips = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        clips.maxAge = 1
        clips.pinned = { [unowned clips, unowned boards] in
            var ids = boards.allClipIDs
            if boards.retentionUnknown { ids.formUnion(clips.clips.map(\.id)) }
            return ids
        }
        clips.load()
        clips.flush()

        XCTAssertEqual(Set(clips.clips.map(\.id)), Set([first.id, second.id]))
    }

    func testWriteFailureRollsBackEveryMutation() throws {
        let store = loadedStore()
        let before = store.boards
        try FileManager.default.removeItem(at: store.url)
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)

        XCTAssertNil(store.create(name: "Must Roll Back", color: .red))
        XCTAssertEqual(store.boards, before)
        XCTAssertTrue(store.lastSaveFailed)
    }

    func testDefaultBoardIdentitySurvivesRenameMoveAndCannotBeDeleted() {
        let store = loadedStore()
        let defaultID = store.defaultBoard!.id
        let other = store.create(name: "Other", color: .green)!
        XCTAssertTrue(store.rename(defaultID, to: "Keep forever"))
        XCTAssertTrue(store.setColor(defaultID, to: .purple))
        XCTAssertTrue(store.moveBoard(defaultID, by: 1))

        XCTAssertFalse(store.delete(defaultID))
        XCTAssertEqual(store.defaultBoard?.id, defaultID)
        XCTAssertEqual(store.defaultBoard?.name, "Keep forever")
        XCTAssertEqual(store.defaultBoard?.color, .purple)
        XCTAssertNotNil(store.board(other))
    }

    func testOptionNumberMapsToBoardOrderAndOutOfRangeIsNil() {
        let store = loadedStore()
        _ = store.create(name: "Second", color: .teal)
        _ = store.create(name: "Third", color: .red)

        XCTAssertEqual(PinboardShortcut.boardID(for: 1, in: store.boards), store.boards[0].id)
        XCTAssertEqual(PinboardShortcut.boardID(for: 3, in: store.boards), store.boards[2].id)
        XCTAssertNil(PinboardShortcut.boardID(for: 0, in: store.boards))
        XCTAssertNil(PinboardShortcut.boardID(for: 4, in: store.boards))
    }

    func testBoardSelectionAndKindFilterAreMutuallyExclusive() {
        let clips = ClipStore(baseDir: tmp)
        clips.load()
        let pins = ClipPins(baseDir: tmp)
        pins.load()
        let board = pins.store.create(name: "Gallery", color: .green)!
        let state = StripState(shelf: ShelfModel(baseDir: tmp), store: clips, pins: pins)

        state.filter = .code
        state.toggleBoard(board)
        XCTAssertEqual(state.board, board)
        XCTAssertEqual(state.filter, .all)

        state.selectFilter(.images)
        XCTAssertNil(state.board)
        XCTAssertEqual(state.filter, .images)
    }

    func testBoardSectionUsesBoardOrderAndSearchWithoutChangingBoard() {
        let clips = ClipStore(baseDir: tmp)
        clips.load()
        let alpha = ingest(clips, "Alpha address")
        let beta = ingest(clips, "Beta address")
        let pins = ClipPins(baseDir: tmp)
        pins.load()
        let board = pins.store.create(name: "Gallery", color: .green, clipIDs: [alpha.id, beta.id])!
        let state = StripState(shelf: ShelfModel(baseDir: tmp), store: clips, pins: pins)

        state.toggleBoard(board)
        XCTAssertEqual(state.sections.board.map(\.id), [alpha.id, beta.id])
        XCTAssertEqual(state.sections.order, [.clip(alpha.id), .clip(beta.id)])
        state.query = "beta"
        XCTAssertEqual(state.sections.board.map(\.id), [beta.id])
        XCTAssertEqual(state.board, board)
        XCTAssertEqual(state.homeTarget, .clip(beta.id))
    }

    func testNonDefaultBoardSurvivesRetentionAndClearHistory() {
        let clips = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        clips.load()
        let kept = ingest(clips, "keep")
        _ = ingest(clips, "discard")
        let boards = loadedStore()
        let board = boards.create(name: "Saved", color: .green, clipIDs: [kept.id])!
        clips.pinned = { boards.allClipIDs }

        now = now.addingTimeInterval(30 * 24 * 3600)
        clips.maxAge = 1
        clips.prune()
        clips.flush()
        XCTAssertEqual(clips.clips.map(\.id), [kept.id])

        XCTAssertTrue(clips.clearAll())
        clips.flush()
        XCTAssertEqual(clips.clips.map(\.id), [kept.id])
        XCTAssertEqual(boards.board(board)?.clipIDs, [kept.id])
    }

    func testDeletingBoardReleasesClipUnlessAnotherBoardStillContainsIt() {
        let clips = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        clips.load()
        let only = ingest(clips, "only")
        let shared = ingest(clips, "shared")
        let boards = loadedStore()
        let first = boards.create(name: "First", color: .orange, clipIDs: [only.id, shared.id])!
        let second = boards.create(name: "Second", color: .teal, clipIDs: [shared.id])!
        clips.pinned = { boards.allClipIDs }

        now = now.addingTimeInterval(30 * 24 * 3600)
        clips.maxAge = 1
        XCTAssertTrue(boards.delete(first))
        clips.prune()
        clips.flush()

        XCTAssertNil(clips.clip(only.id))
        XCTAssertNotNil(clips.clip(shared.id))
        XCTAssertEqual(boards.board(second)?.clipIDs, [shared.id])
    }

    func testRetentionReleaseDoesNotPruneWhileClipStoreIsDegraded() {
        let boards = loadedStore()
        let board = boards.create(name: "Saved", color: .green, clipIDs: [UUID()])!
        let pins = ClipPins(store: boards)
        let pinnedID = UUID()
        XCTAssertTrue(pins.pin(pinnedID))
        var pruneCount = 0
        var isDegraded = true
        boards.onRetentionReleased = AppDelegate.retentionReleaseHandler(
            isDegraded: { isDegraded },
            prune: { pruneCount += 1 }
        )

        XCTAssertTrue(pins.unpin(pinnedID))
        XCTAssertTrue(boards.delete(board))
        XCTAssertEqual(pruneCount, 0)

        isDegraded = false
        let healthyBoard = boards.create(name: "Healthy", color: .blue, clipIDs: [UUID()])!
        XCTAssertTrue(boards.delete(healthyBoard))
        XCTAssertEqual(pruneCount, 1)
    }
}
