//
//  PasteStackTests.swift
//  Multiple paste stacks: collect (clipboard untouched) / ready (Cmd-V pastes in order) / archive on the last
//  paste, one collector + one ready stack at once, persistence (state resets to Idle), Cmd-V pairing,
//  conditional restore, caps, pins. Fake pasteboard + temp store; never touches the real clipboard.
//

import XCTest
import Carbon
@testable import ShakeBoard

@MainActor
final class PasteStackTests: XCTestCase {
    private var tmp: URL!
    private var pb: FakePasteboard!
    private var oldPB: PasteboardAccess!
    private var store: ClipStore!
    private var stack: PasteStack!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardStackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        pb = FakePasteboard()
        oldPB = ClipboardWriter.pasteboard
        ClipboardWriter.pasteboard = pb
        store = ClipStore(baseDir: tmp)
        store.load()
        stack = makeStack()
        store.pinned = { [unowned self] in self.stack.pinnedIDs }
    }
    override func tearDownWithError() throws {
        ClipboardWriter.pasteboard = oldPB
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStack() -> PasteStack {
        let s = PasteStack(store: store, baseDir: tmp)
        s.advanceDelay = 0
        s.pasteboard = { [unowned self] in self.pb }
        s.isTrusted = { true }
        s.onPinsReleased = { [unowned self] in self.store.prune() }
        return s
    }

    private func clip(_ s: String) -> Clip {
        let exp = expectation(description: "ingest")
        var out: Clip?
        store.ingest(CapturedClipboard(snapshot: RawSnapshot(changeCount: 0, allTypes: [], items: [[textRep(s)]]),
                                       sourceBundleID: nil, sourceAppName: nil, capturedAt: Date())) { c, _ in
            out = c; exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        store.flush()
        return out!
    }
    // Simulate the user copying `s`: it lands on the pasteboard, the monitor captures it, the stacks hear it.
    private func userCopies(_ s: String) {
        pb.set([[textRep(s)]])
        let count = pb.changeCount
        stack.didCapture(clip(s), capturedChangeCount: count)
    }
    private var clipboardText: String? {
        pb.items.first?.first { $0.type == ClipTypes.plainText }.flatMap { String(data: $0.data, encoding: .utf8) }
    }
    private func cmdV() {
        stack.keyDown(keyCode: kVK_ANSI_V, command: true, isRepeat: false)
        stack.keyUp(keyCode: kVK_ANSI_V)
    }
    // A stack holding `items`, collected the normal way, then collecting stopped.
    @discardableResult
    private func collected(_ items: [String], name: String? = nil) -> UUID {
        let id = stack.newStack(name: name)
        stack.collect(into: id)
        for s in items { userCopies(s) }
        stack.stopCollecting()
        return id
    }

    // MARK: collecting

    func testCollecting_appendsCopies_andLeavesClipboardAlone() {
        let id = stack.newStack()
        stack.collect(into: id)
        userCopies("A"); userCopies("B"); userCopies("C")
        XCTAssertEqual(stack.stack(id)?.slots.count, 3)
        XCTAssertEqual(clipboardText, "C", "collecting never rewrites the clipboard: Cmd-V pastes your copy")
        XCTAssertEqual(pb.writes, 0)
        cmdV()
        XCTAssertEqual(stack.stack(id)?.slots.count, 3, "Cmd-V while only collecting does nothing to the stack")
        XCTAssertEqual(pb.writes, 0)
    }

    func testIdle_ignoresCapturesAndKeys() {
        let id = stack.newStack()
        userCopies("A")
        cmdV()
        XCTAssertEqual(stack.stack(id)?.slots.count, 0)
        XCTAssertFalse(stack.isOn)
        XCTAssertEqual(pb.writes, 0)
    }

    func testCollectSwitchesTarget_oneCollectorAtATime() {
        let a = stack.newStack(), b = stack.newStack()
        stack.collect(into: a); userCopies("1")
        stack.collect(into: b); userCopies("2")
        XCTAssertEqual(stack.collectingID, b)
        XCTAssertEqual(stack.stack(a)?.slots.count, 1)
        XCTAssertEqual(stack.stack(b)?.slots.count, 1)
    }

    // MARK: ready -> paste in order -> archive

    func testReady_pastesInOrder_thenArchivesAndRestoresOriginal() {
        let id = collected(["A", "B", "C"], name: "Vendor")
        pb.set([[textRep("original")]])
        XCTAssertTrue(stack.arm(id))
        XCTAssertEqual(clipboardText, "A")
        cmdV(); XCTAssertEqual(clipboardText, "B")
        cmdV(); XCTAssertEqual(clipboardText, "C")
        cmdV()
        XCTAssertFalse(stack.isReady)
        XCTAssertNil(stack.stack(id), "a finished stack leaves the active list")
        XCTAssertEqual(stack.archived.first?.id, id, "and is archived, newest first")
        XCTAssertEqual(stack.archived.first?.slots.count, 3, "with every item kept for Paste Again")
        XCTAssertEqual(stack.archived.first?.pastedCount, 3)
        XCTAssertEqual(stack.finished, .init(id: id, name: "Vendor", count: 3))
        XCTAssertEqual(clipboardText, "original", "the clipboard from before arming comes back")
    }

    func testPasteAgain_restoresFromArchiveAndArmsFromTheTop() {
        let id = collected(["A", "B"])
        stack.arm(id); cmdV(); cmdV()
        XCTAssertNotNil(stack.archivedStack(id))
        stack.restore(id, arm: true)
        XCTAssertNil(stack.archivedStack(id))
        XCTAssertEqual(stack.readyID, id)
        XCTAssertEqual(stack.cursor, 0)
        XCTAssertEqual(clipboardText, "A")
    }

    func testArmEmptyStack_refuses() {
        let id = stack.newStack()
        XCTAssertFalse(stack.arm(id))
        XCTAssertNil(stack.readyID)
        XCTAssertNotNil(stack.notice)
    }

    func testDisarm_keepsItems_andRestoresOnlyIfStillShakeBoards() {
        let id = collected(["A", "B"])
        pb.set([[textRep("original")]])
        stack.arm(id)
        cmdV()
        stack.disarm()
        XCTAssertEqual(stack.stack(id)?.slots.count, 2, "Stop keeps every item")
        XCTAssertEqual(clipboardText, "original")
        XCTAssertNil(stack.readyID)

        pb.set([[textRep("original 2")]])
        stack.arm(id)
        pb.set([[textRep("something newer")]])
        stack.disarm()
        XCTAssertEqual(clipboardText, "something newer", "never clobber a newer external copy")
    }

    // MARK: both at once (one stack collects while a different one pastes)

    func testCollectingWhileAnotherIsReady() {
        let a = collected(["A1", "A2", "A3"])
        let b = stack.newStack()
        stack.arm(a)
        stack.collect(into: b)
        XCTAssertEqual(stack.readyID, a)
        XCTAssertEqual(stack.collectingID, b)
        userCopies("B1")
        XCTAssertEqual(stack.stack(b)?.clipIDs.count, 1, "the copy lands in the collecting stack")
        XCTAssertEqual(clipboardText, "A1", "and the ready stack's next item is put straight back")
        cmdV(); XCTAssertEqual(clipboardText, "A2")
        userCopies("B2")
        XCTAssertEqual(clipboardText, "A2")
        cmdV(); XCTAssertEqual(clipboardText, "A3")
        XCTAssertEqual(stack.stack(b)?.slots.count, 2)
    }

    func testArmingStopsCollectingOnThatStack_andCollectingDisarms() {
        let a = collected(["A"])
        stack.collect(into: a)
        stack.arm(a)
        XCTAssertNil(stack.collectingID, "arming a stack ends collecting on it")
        XCTAssertEqual(stack.readyID, a)
        stack.collect(into: a)
        XCTAssertNil(stack.readyID, "collecting into the ready stack disarms it")
        XCTAssertEqual(stack.collectingID, a)
    }

    func testOnlyOneReadyStack() {
        let a = collected(["A"]), b = collected(["B"])
        pb.set([[textRep("original")]])
        stack.arm(a)
        stack.arm(b)
        XCTAssertEqual(stack.readyID, b)
        XCTAssertEqual(clipboardText, "B")
        stack.disarm()
        XCTAssertEqual(clipboardText, "original", "the clipboard from before the first arm is what comes back")
    }

    func testUncollectedCopyWhileReady_isLeftAlone_andPauses() {
        let a = collected(["A", "B"])
        stack.arm(a)
        userCopies("stray")                       // nothing collecting
        XCTAssertEqual(clipboardText, "stray", "a copy that isn't collected stays on the clipboard")
        cmdV()
        XCTAssertTrue(stack.isPaused)
        XCTAssertEqual(stack.cursor, 0)
        stack.resume()
        XCTAssertEqual(clipboardText, "A")
        XCTAssertFalse(stack.isPaused)
    }

    // MARK: persistence

    func testStacksPersist_butEveryLaunchStartsIdle() {
        let a = collected(["A", "B"], name: "Kept")
        let b = stack.newStack()
        stack.arm(a); stack.collect(into: b)
        let again = makeStack()
        again.load()
        XCTAssertEqual(again.stacks.map(\.name), ["Kept", "Stack 2"])
        XCTAssertEqual(again.stack(a)?.slots.count, 2)
        XCTAssertNil(again.readyID, "Ready is never restored")
        XCTAssertNil(again.collectingID, "Collecting is never restored")
        XCTAssertFalse(again.isOn)
    }

    func testArchivePersists_andUnreadableFileIsSetAside() throws {
        let a = collected(["A"])
        stack.arm(a); cmdV()
        var again = makeStack(); again.load()
        XCTAssertEqual(again.archived.map(\.id), [a])
        try Data("{not json".utf8).write(to: tmp.appendingPathComponent("stacks.json"))
        again = makeStack(); again.load()
        XCTAssertTrue(again.stacks.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("stacks.json.unreadable-") }, "kept, not overwritten")
    }

    func testFileIsPrivate() throws {
        stack.newStack()
        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.appendingPathComponent("stacks.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPrune_dropsMissingClips_andEmptyArchivedStacks() {
        let a = collected(["A", "B"])
        let ids = stack.stack(a)!.clipIDs
        stack.prune(keeping: Set([ids[0]]))
        XCTAssertEqual(stack.stack(a)?.clipIDs, [ids[0]])
        let b = collected(["C"]); stack.archive(b)
        stack.prune(keeping: [])
        XCTAssertNil(stack.archivedStack(b), "an archived stack with nothing left goes")
        XCTAssertNotNil(stack.stack(a), "an empty ACTIVE stack stays (you may still collect into it)")
    }

    func testPrune_keepsReferencesWhileClipStoreIsDegraded() {
        let id = collected(["keep referenced"])
        let clipIDs = stack.stack(id)!.clipIDs
        let fm = FileManager.default
        let clipsDir = store.dir
        let operations = ClipStore.FileOperations(
            contentsOfDirectory: { url in
                if url == clipsDir { throw CocoaError(.fileReadNoPermission) }
                return try fm.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            },
            removeItem: { try fm.removeItem(at: $0) },
            writeAtomically: { try $0.write(to: $1, options: .atomic) })
        let unavailableStore = ClipStore(baseDir: tmp, fileOperations: operations)
        unavailableStore.load()
        let reloadedStack = PasteStack(store: unavailableStore, baseDir: tmp)
        reloadedStack.load()

        reloadedStack.prune(keeping: [])

        XCTAssertTrue(unavailableStore.isDegraded)
        XCTAssertEqual(reloadedStack.stack(id)?.clipIDs, clipIDs)
    }

    // MARK: pins / retention

    func testStackClipsSurviveRetentionAndClearHistory() {
        let a = collected(["keep me"])
        let kept = stack.stack(a)!.clipIDs[0]
        store.maxCount = 1
        _ = clip("newer 1"); _ = clip("newer 2")
        XCTAssertNotNil(store.clip(kept), "a stacked clip survives history eviction")
        store.clearAll()
        XCTAssertNotNil(store.clip(kept), "and Clear History, like a pin")
        stack.arm(a); cmdV()
        store.prune()
        XCTAssertNotNil(store.clip(kept), "archived stacks still protect their clips (Paste Again)")
    }

    func testDelete_keepsClipsWhileUndoIsOffered_thenReleases() {
        let a = collected(["old"])
        let kept = stack.stack(a)!.clipIDs[0]
        store.maxCount = 1
        _ = clip("newer")
        stack.delete(a)
        XCTAssertNil(stack.stack(a))
        store.prune()
        XCTAssertNotNil(store.clip(kept), "still protected while Undo is on offer")
        stack.performUndo()
        XCTAssertNotNil(stack.stack(a), "Undo restores the stack with its clips intact")
        XCTAssertNil(stack.undoOffer)
        stack.delete(a)
        stack.dismissUndo()
        XCTAssertNil(store.clip(kept), "evicted once the Undo offer ends")
    }

    func testNewerUndoSupersedesAndReleasesTheOlder() {
        let a = collected(["first"]), b = collected(["second"])
        let first = stack.stack(a)!.clipIDs[0]
        store.maxCount = 1
        _ = clip("newer")
        stack.delete(a)
        stack.delete(b)
        XCTAssertNil(store.clip(first), "only the latest delete can be undone")
    }

    func testCaptureGoesToTheStackCollectingWhenItWasSeen() {
        let a = stack.newStack(), b = stack.newStack()
        stack.collect(into: a)
        let seenBy = stack.collectingID
        stack.collect(into: b)                     // collecting moved while the copy was being saved
        pb.set([[textRep("late")]])
        stack.didCapture(clip("late"), capturedChangeCount: pb.changeCount, into: seenBy)
        XCTAssertEqual(stack.stack(a)?.slots.count, 1)
        XCTAssertEqual(stack.stack(b)?.slots.count, 0)
        stack.stopCollecting()
        stack.didCapture(clip("not collecting"), capturedChangeCount: pb.changeCount, into: nil)
        XCTAssertEqual(stack.stack(a)?.slots.count, 1, "a copy seen while nothing collected goes nowhere")
    }

    func testReplacingUndoNeverEvictsTheNewlyDeletedStack() {
        let a = collected(["first"]), b = collected(["second"])
        let second = stack.stack(b)!.clipIDs[0]
        store.maxCount = 1
        _ = clip("newer")
        stack.delete(a)
        stack.delete(b)
        XCTAssertNotNil(store.clip(second), "the stack Undo now offers keeps its clips")
        stack.performUndo()
        XCTAssertEqual(stack.entries(of: b).count, 1)
    }

    func testUnreadableStacksFile_isNeverOverwritten() throws {
        let url = tmp.appendingPathComponent("stacks.json")
        try Data("{\"version\":1,\"active\":[],\"archived\":[]}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let again = makeStack()
        again.load()
        XCTAssertTrue(again.readOnly)
        XCTAssertTrue(again.lastSaveFailed, "shown in Settings")
        again.newStack()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), Data("{\"version\":1,\"active\":[],\"archived\":[]}".utf8),
                       "the file that couldn't be read is left exactly as it was")
    }

    func testSaveFailureIsReported() throws {
        let blocked = tmp.appendingPathComponent("blocked")
        try Data().write(to: blocked)                  // a FILE where the data directory should be
        let s = PasteStack(store: store, baseDir: blocked)
        s.newStack()
        XCTAssertTrue(s.lastSaveFailed)
        var i = SettingsAlerts.Inputs(); i.stacksSaveFailed = true
        XCTAssertTrue(SettingsAlerts.compute(i).contains { $0.id == "stacks" })
    }

    func testDeleteReadyStack_disarmsFirst() {
        let a = collected(["A"])
        pb.set([[textRep("original")]])
        stack.arm(a)
        stack.delete(a)
        XCTAssertNil(stack.readyID)
        XCTAssertEqual(clipboardText, "original")
    }

    func testArchiveCap() {
        for i in 0..<(StackFile.maxArchived + 2) {
            let id = collected(["x\(i)"]); stack.archive(id)
        }
        XCTAssertEqual(stack.archived.count, StackFile.maxArchived)
    }

    // MARK: caps

    func testCountCap() {
        let id = stack.newStack()
        stack.collect(into: id)
        for i in 0..<(PasteStack.maxItems + 3) { userCopies("item \(i)") }
        XCTAssertEqual(stack.stack(id)?.slots.count, PasteStack.maxItems)
        XCTAssertNotNil(stack.notice)
    }

    // MARK: keys + ownership (carried over from the single stack)

    func testKeyPairing_ignoresRepeatsAndUnpairedKeyUps() {
        stack.arm(collected(["A", "B"]))
        stack.keyUp(keyCode: kVK_ANSI_V)
        XCTAssertEqual(clipboardText, "A")
        stack.keyDown(keyCode: kVK_ANSI_V, command: false, isRepeat: false)
        stack.keyUp(keyCode: kVK_ANSI_V)
        XCTAssertEqual(clipboardText, "A")
        stack.keyDown(keyCode: kVK_ANSI_V, command: true, isRepeat: false)
        stack.keyDown(keyCode: kVK_ANSI_V, command: true, isRepeat: true)
        stack.keyUp(keyCode: kVK_ANSI_V)
        XCTAssertEqual(clipboardText, "B", "one press advances exactly once")
    }

    func testAdvance_rechecksOwnership() {
        stack.arm(collected(["A", "B"]))
        stack.advanceDelay = 60
        cmdV()
        XCTAssertTrue(stack.advancePending)
        pb.set([[textRep("history paste")]])
        stack.advance()
        XCTAssertEqual(stack.cursor, 0)
        XCTAssertTrue(stack.isPaused)
    }

    private func waitBeat() {
        let exp = expectation(description: "beat")
        DispatchQueue.main.asyncAfter(deadline: .now() + PasteStack.defaultAdvanceDelay * 3) { exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    func testDoubleCmdV_withinProductionDelay_advancesOnce() {
        stack.advanceDelay = PasteStack.defaultAdvanceDelay
        stack.arm(collected(["A", "B", "C"]))
        cmdV(); cmdV()
        waitBeat()
        XCTAssertEqual(stack.cursor, 1, "B was not skipped")
        XCTAssertEqual(clipboardText, "B")
        XCTAssertFalse(stack.advancePending)
    }

    func testDelayedAdvance_voidAfterDisarmRearm() {
        stack.advanceDelay = PasteStack.defaultAdvanceDelay
        let a = collected(["A", "B"])
        stack.arm(a)
        cmdV()
        stack.disarm(); stack.arm(a)
        waitBeat()
        XCTAssertEqual(stack.cursor, 0, "the new armed period is untouched")
        XCTAssertEqual(clipboardText, "A")
    }

    func testDelayedAdvance_voidWhenHeadRemoved() {
        stack.advanceDelay = PasteStack.defaultAdvanceDelay
        let a = collected(["A", "B", "C"])
        stack.arm(a)
        let headToken = stack.stack(a)!.slots[0].token
        cmdV()
        stack.remove(token: headToken)
        waitBeat()
        XCTAssertEqual(stack.queue.count, 2, "B was not skipped")
        XCTAssertEqual(clipboardText, "B")
        XCTAssertFalse(stack.advancePending)
    }

    func testRestore_isFaithfulAcrossItemsAndTypes() {
        let a = collected(["A"])
        let rtf = RawRep(type: ClipTypes.rtf, data: Data("{\\rtf1 x}".utf8))
        let custom = RawRep(type: "com.example.private", data: Data([1, 2, 3]))
        pb.set([[textRep("one"), rtf, custom], [textRep("two")]], extra: ["org.nspasteboard.ConcealedType"])
        stack.arm(a)
        stack.disarm()
        XCTAssertEqual(pb.items.count, 2)
        XCTAssertEqual(Set(pb.items[0].map(\.type)),
                       [ClipTypes.plainText, ClipTypes.rtf, "com.example.private", "org.nspasteboard.ConcealedType"])
        XCTAssertEqual(pb.items[1].first?.data, Data("two".utf8))
    }

    func testRestore_emptyOriginalLeavesClipboard() {
        let a = collected(["A"])
        pb.set([])
        stack.arm(a)
        stack.disarm()
        XCTAssertEqual(clipboardText, "A")
    }

    func testArm_withoutAccessibility_setsNotice() {
        stack.isTrusted = { false }
        stack.arm(collected(["A"]))
        XCTAssertNotNil(stack.notice)
    }

    func testHeadReload_refusedWritePausesStack() {
        let a = collected(["A"])
        stack.arm(a)
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { (nil, nil) })
        ClipboardWriter.monitor = m
        defer { ClipboardWriter.monitor = nil; pb.bumpEveryRead = false }
        pb.set([[textRep("B still landing")]])
        pb.bumpEveryRead = true
        stack.resume()
        XCTAssertTrue(stack.isPaused)
        XCTAssertEqual(clipboardText, "B still landing")
    }

    // MARK: editing a stack

    func testDuplicateCopies_queueTwice() {
        let a = collected(["A", "B", "A"])
        let ids = stack.stack(a)!.clipIDs
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids[0], ids[2], "identical copies share a clip id")
        XCTAssertEqual(stack.entries(of: a).map(\.position), [0, 1, 2])
        XCTAssertNil(stack.badge(for: ids[0]), "no badge while the stack is idle")
        stack.collect(into: a)
        XCTAssertEqual(stack.badge(for: ids[0])?.text, "S1 #1,3")
    }

    func testRemoveToken_survivesShift_andRemovingBeforeCursorKeepsNext() {
        let a = collected(["A", "B", "C"])
        stack.arm(a)
        let tA = stack.stack(a)!.slots[0].token
        cmdV()                                    // A pasted, B is next
        stack.remove(token: tA)
        XCTAssertEqual(stack.cursor, 0)
        XCTAssertEqual(stack.queue.count, 2)
        XCTAssertEqual(clipboardText, "B", "removing an already-pasted item doesn't change what's next")
        stack.remove(token: tA)                   // already gone: no-op
        XCTAssertEqual(stack.stack(a)?.slots.count, 2)
    }

    func testRemovingLastRemainingItem_finishes() {
        let a = collected(["A", "B"])
        stack.arm(a)
        cmdV()
        stack.remove(at: 0)                       // B, the only one left
        XCTAssertNil(stack.readyID)
        XCTAssertNotNil(stack.archivedStack(a))
    }

    func testMove_reordersButNeverAcrossTheCursor() {
        let a = collected(["A", "B", "C"])
        let tC = stack.stack(a)!.slots[2].token
        stack.move(token: tC, by: -1)
        XCTAssertEqual(stack.entries(of: a).map(\.clip.preview), ["A", "C", "B"])
        stack.arm(a); cmdV()                      // A pasted, C next
        let tAfter = stack.stack(a)!.slots[1].token
        stack.move(token: tAfter, by: -1)         // would cross the cursor
        XCTAssertEqual(stack.entries(of: a).map(\.clip.preview), ["A", "C", "B"])
        let tB = stack.stack(a)!.slots[2].token
        stack.move(token: tB, by: -1)             // B becomes next: the clipboard follows
        XCTAssertEqual(clipboardText, "B")
    }

    func testAddByHand_andNames() {
        let a = stack.newStack()
        XCTAssertEqual(stack.stack(a)?.name, "Stack 1")
        XCTAssertTrue(stack.add(clip("X").id, to: a))
        XCTAssertEqual(stack.stack(a)?.slots.count, 1)
        stack.rename(a, to: "  Invoice  ")
        XCTAssertEqual(stack.stack(a)?.name, "Invoice")
        stack.rename(a, to: "   ")
        XCTAssertEqual(stack.stack(a)?.name, "Invoice", "a blank name is ignored")
        stack.newStack(select: false)
        XCTAssertEqual(stack.stacks.last?.name, "Stack 2")
    }

    func testShortcutToggle_collectsThenStopsEverything() {
        stack.toggle()
        XCTAssertTrue(stack.isCollecting, "with no stacks, the shortcut makes one and collects into it")
        XCTAssertEqual(stack.stacks.count, 1)
        userCopies("A")
        stack.toggle()
        XCTAssertFalse(stack.isOn)
        XCTAssertEqual(stack.stacks.first?.slots.count, 1, "stopping keeps the stack")
    }

    func testRailTapped_opensLaneAndStartsAFirstStack_thenHides() {
        stack.railTapped()
        XCTAssertTrue(stack.showsLane)
        XCTAssertTrue(stack.isCollecting)
        stack.railTapped()
        XCTAssertFalse(stack.showsLane)
        XCTAssertTrue(stack.isCollecting, "hiding the lane doesn't stop collecting")
        stack.railTapped()
        XCTAssertEqual(stack.stacks.count, 1, "no second stack when one exists")
    }
}

// MARK: - Split into Stack

final class StackSplitterTests: XCTestCase {
    func testLines_dropBlanksAndTrim() {
        let t = "  apples \n\nbananas\r\n  cherries  \n"
        XCTAssertEqual(StackSplitter.detect(t), .lines)
        XCTAssertEqual(StackSplitter.autoSplit(t)?.pieces, ["apples", "bananas", "cherries"])
        XCTAssertEqual(StackSplitter.menuLabel(t), "Split into Stack (3 lines)")
    }

    func testTSVRow() {
        let t = "Acme Ceramics\t123 Main St\tEdgecomb\tME"
        XCTAssertEqual(StackSplitter.detect(t), .tabs)
        XCTAssertEqual(StackSplitter.autoSplit(t)?.pieces, ["Acme Ceramics", "123 Main St", "Edgecomb", "ME"])
        XCTAssertEqual(StackSplitter.menuLabel(t), "Split into Stack (4 cells)")
    }

    func testCommaList_withQuotedFields() {
        let t = #"orders@example.com, "Edgecomb, ME", (207) 555-0142"#
        XCTAssertEqual(StackSplitter.detect(t), .commas)
        XCTAssertEqual(StackSplitter.autoSplit(t)?.pieces, ["orders@example.com", "Edgecomb, ME", "(207) 555-0142"])
        XCTAssertEqual(StackSplitter.csvFields(#""say ""hi""",x"#, separator: ","), [#"say "hi""#, "x"])
    }

    func testSemicolonListWins() {
        XCTAssertEqual(StackSplitter.autoSplit("red, dark; green; blue")?.pieces, ["red, dark", "green", "blue"])
    }

    func testProseIsNotSplit() {
        XCTAssertNil(StackSplitter.detect("Hi John, thanks for the order. We'll ship it Friday, weather permitting."))
        XCTAssertNil(StackSplitter.detect("When I got to the gallery this morning, the door was already open"))
        XCTAssertNil(StackSplitter.detect("just one thing"))
        XCTAssertNil(StackSplitter.menuLabel("single"))
    }

    func testForcedModes() {
        let t = "a,b\nc,d"
        XCTAssertEqual(StackSplitter.split(t, .lines), ["a,b", "c,d"])
        XCTAssertEqual(StackSplitter.split(t, .commas), ["a", "b", "c", "d"])
        XCTAssertEqual(StackSplitter.split("x\ty", .tabs), ["x", "y"])
        XCTAssertEqual(StackSplitter.split("no tabs here", .tabs), ["no tabs here"], "fewer than 2: the menu disables it")
    }

    func testLabelCapsAtMaxPieces() {
        let t = (1...60).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(StackSplitter.menuLabel(t), "Split into Stack (first 50 of 60 lines)")
    }
}
