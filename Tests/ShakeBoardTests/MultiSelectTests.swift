//
//  MultiSelectTests.swift -- ordered multi-select in the strip (Command-click order is the send order) and
//  Send N to Stack into new and existing stacks, with Undo. Fake pasteboard + temp dirs only.
//

import XCTest
import AppKit
import Carbon
@testable import ShakeBoard

final class ClipPicksTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    func testToggle_keepsClickOrder_andRenumbersOnRemove() {
        var p = ClipPicks()
        p.toggle(c); p.toggle(a); p.toggle(d)
        XCTAssertEqual(p.ids, [c, a, d])
        XCTAssertEqual(p.position(of: d), 3)
        p.toggle(a)                                  // unpick the middle one
        XCTAssertEqual(p.ids, [c, d])
        XCTAssertEqual(p.position(of: d), 2)
        XCTAssertNil(p.position(of: a))
    }

    func testFirstCommandClick_keepsTheSelectedCardAsNumberOne() {
        var p = ClipPicks()
        p.toggle(b, seed: d)
        XCTAssertEqual(p.ids, [d, b])
        p.toggle(e, seed: a)                         // the seed only applies to an empty pick list
        XCTAssertEqual(p.ids, [d, b, e])
        var q = ClipPicks()
        q.toggle(b, seed: b)                         // Command-clicking the selected card itself: just it
        XCTAssertEqual(q.ids, [b])
    }

    func testShiftClick_appendsTheRunInVisibleOrder_afterExistingPicks() {
        let visible = [a, b, c, d, e]
        var p = ClipPicks()
        p.toggle(e); p.toggle(b)                     // anchor = b
        p.extend(to: d, visible: visible)            // b...d, left to right; b is already picked
        XCTAssertEqual(p.ids, [e, b, c, d])
        var q = ClipPicks()
        q.toggle(d)
        q.extend(to: b, visible: visible)            // leftward run still reads left to right
        XCTAssertEqual(q.ids, [d, b, c])
    }

    func testShiftClick_withNothingPicked_startsAtTheSelectedCard() {
        var p = ClipPicks()
        p.extend(to: c, visible: [a, b, c, d], seed: a)
        XCTAssertEqual(p.ids, [a, b, c])
        var q = ClipPicks()
        q.extend(to: c, visible: [a, b, c, d])       // no seed, no anchor: just that card
        XCTAssertEqual(q.ids, [c])
    }

    func testClearAndRetain() {
        var p = ClipPicks()
        p.toggle(a); p.toggle(b); p.toggle(c)
        p.retain([a, c])
        XCTAssertEqual(p.ids, [a, c])
        XCTAssertEqual(p.position(of: c), 2)
        p.clear()
        XCTAssertTrue(p.isEmpty)
    }
}

@MainActor
final class SendToStackTests: XCTestCase {
    private var tmp: URL!
    private var pb: FakePasteboard!
    private var oldPB: PasteboardAccess!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardMultiSel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        pb = FakePasteboard()
        oldPB = ClipboardWriter.pasteboard
        ClipboardWriter.pasteboard = pb
    }
    override func tearDownWithError() throws {
        ClipboardWriter.pasteboard = oldPB
        try? FileManager.default.removeItem(at: tmp)
    }

    private func make() -> (StripController, PasteStack) {
        let store = ClipStore(baseDir: tmp); store.load()
        let pins = ClipPins(baseDir: tmp); pins.load()
        let state = StripState(shelf: ShelfModel(baseDir: tmp), store: store, pins: pins)
        let c = StripController(state: state)
        let s = PasteStack(store: store, baseDir: tmp)
        s.pasteboard = { [unowned self] in self.pb }
        store.pinned = { s.pinnedIDs }
        c.stacks = s
        return (c, s)
    }
    @discardableResult
    private func ingest(_ store: ClipStore, _ text: String) -> Clip {
        let exp = expectation(description: "ingest")
        var out: Clip?
        store.ingest(CapturedClipboard(snapshot: RawSnapshot(changeCount: 1, allTypes: [], items: [[textRep(text)]]),
                                       sourceBundleID: nil, sourceAppName: nil, capturedAt: Date())) { c, _ in
            out = c; exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        store.flush()
        return out!
    }

    func testClicks_buildThePickOrder_andPlainClickClears() {
        let (strip, _) = make()
        let st = strip.state
        let x = ingest(st.store, "one"), y = ingest(st.store, "two"), z = ingest(st.store, "three")
        st.clickClip(y.id, command: false, shift: false)          // select "two"
        st.clickClip(x.id, command: true, shift: false)           // Command-click "one": two is #1, one is #2
        st.clickClip(z.id, command: true, shift: false)
        XCTAssertEqual(st.picks.ids, [y.id, x.id, z.id])
        XCTAssertEqual(st.targets(for: x.id), [y.id, x.id, z.id], "a picked card's menu acts on all of them")
        let other = ingest(st.store, "four")
        XCTAssertEqual(st.targets(for: other.id), [other.id], "an unpicked card's menu acts on just it")
        st.clickClip(x.id, command: false, shift: false)
        XCTAssertTrue(st.picks.isEmpty)
        XCTAssertEqual(st.cursor, .clip(x.id))
    }

    func testEscapeClearsPicksFirst() {
        let (strip, _) = make()
        let st = strip.state
        let x = ingest(st.store, "one"), y = ingest(st.store, "two")
        st.clickClip(x.id, command: true, shift: false); st.clickClip(y.id, command: true, shift: false)
        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                   isARepeat: false, keyCode: UInt16(kVK_Escape))!
        XCTAssertTrue(strip.handleKey(esc))
        XCTAssertTrue(st.picks.isEmpty)
        XCTAssertEqual(st.cursor, .clip(y.id), "the selection itself stays until the next Escape")
    }

    func testSendToNewStack_inClickOrder_thenUndoRemovesIt() {
        let (strip, stacks) = make()
        let st = strip.state
        let a = ingest(st.store, "a"), b = ingest(st.store, "b"), c = ingest(st.store, "c")
        st.clickClip(c.id, command: true, shift: false)
        st.clickClip(a.id, command: true, shift: false)
        st.clickClip(b.id, command: true, shift: false)
        strip.sendToStack(st.targets(for: a.id), stack: nil)
        XCTAssertEqual(stacks.stacks.count, 1)
        XCTAssertEqual(stacks.stacks[0].clipIDs, [c.id, a.id, b.id])
        XCTAssertEqual(stacks.selectedID, stacks.stacks[0].id)
        XCTAssertTrue(stacks.laneOpen)
        XCTAssertTrue(st.picks.isEmpty, "sent: the picks clear")
        XCTAssertEqual(stacks.undoOffer?.message, "Sent 3 to \u{201C}\(stacks.stacks[0].name)\u{201D}")
        stacks.performUndo()
        XCTAssertTrue(stacks.stacks.isEmpty, "undo takes the new stack away again")
    }

    func testSendToExistingStack_appendsInOrder_thenUndoTakesOnlyThoseOut() {
        let (strip, stacks) = make()
        let st = strip.state
        let first = ingest(st.store, "first")
        let sid = stacks.newStack(name: "Vendor", clips: [first.id])
        let a = ingest(st.store, "a"), b = ingest(st.store, "b")
        strip.sendToStack([b.id, a.id], stack: sid)
        XCTAssertEqual(stacks.stack(sid)?.clipIDs, [first.id, b.id, a.id])
        XCTAssertEqual(st.notice, "Sent 2 to Vendor (3)")
        stacks.performUndo()
        XCTAssertEqual(stacks.stack(sid)?.clipIDs, [first.id])
    }

    func testSendStopsWhenTheStackIsFull() {
        let (strip, stacks) = make()
        let st = strip.state
        let base = ingest(st.store, "base")
        let sid = stacks.newStack(name: "Full", clips: [base.id])
        // Fill to one short of the cap with the same copy (a stack may repeat a copy).
        for _ in 1..<(PasteStack.maxItems - 1) { _ = stacks.add(base.id, to: sid) }
        let a = ingest(st.store, "a"), b = ingest(st.store, "b")
        strip.sendToStack([a.id, b.id], stack: sid)
        XCTAssertEqual(stacks.stack(sid)?.slots.count, PasteStack.maxItems)
        XCTAssertEqual(stacks.stack(sid)?.clipIDs.last, a.id, "the first pick fits; the second doesn't")
        XCTAssertTrue(st.notice?.hasPrefix("Sent 1 of 2 to Full") == true, st.notice ?? "nil")
    }

    func testSendSkipsCopiesThatAreGone() {
        let (strip, stacks) = make()
        let st = strip.state
        let a = ingest(st.store, "a")
        strip.sendToStack([UUID(), a.id], stack: nil)
        XCTAssertEqual(stacks.stacks.first?.clipIDs, [a.id])
    }

    func testDeletedCopyLeavesThePicks() {
        let (strip, _) = make()
        let st = strip.state
        let a = ingest(st.store, "a"), b = ingest(st.store, "b"), c = ingest(st.store, "c")
        for x in [a, b, c] { st.clickClip(x.id, command: true, shift: false) }
        st.store.remove(b.id)
        st.store.flush()
        let end = Date().addingTimeInterval(2)
        while st.picks.contains(b.id) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(st.picks.ids, [a.id, c.id])
        XCTAssertEqual(st.picks.position(of: c.id), 2)
    }

    func testUndo_doesNothingOnceTheStackIsPasting() {
        let (strip, stacks) = make()
        let st = strip.state
        let first = ingest(st.store, "first")
        let sid = stacks.newStack(name: "Vendor", clips: [first.id])
        let a = ingest(st.store, "a"), b = ingest(st.store, "b")
        strip.sendToStack([a.id, b.id], stack: sid)
        stacks.debugMarkReady(sid, cursor: 2)          // pasting: "b" is next
        stacks.performUndo()
        XCTAssertEqual(stacks.stack(sid)?.clipIDs, [first.id, a.id, b.id], "order in use is left alone")
        XCTAssertEqual(stacks.readyID, sid)
        XCTAssertTrue(stacks.notice?.hasPrefix("Can't undo") == true)
    }

    func testSearchOrFilterChange_dropsThePicks() {
        let (strip, _) = make()
        let st = strip.state
        let a = ingest(st.store, "alpha"), b = ingest(st.store, "beta")
        st.clickClip(a.id, command: true, shift: false); st.clickClip(b.id, command: true, shift: false)
        st.query = "alp"
        XCTAssertTrue(st.picks.isEmpty, "hidden cards are never sent")
        st.clickClip(a.id, command: true, shift: false); st.clickClip(b.id, command: true, shift: false)
        st.filter = .text
        XCTAssertTrue(st.picks.isEmpty)
    }

    func testPickPushedPastTheRecentCap_dropsOut() {
        let (strip, _) = make()
        let st = strip.state
        let oldest = ingest(st.store, "oldest")
        for i in 1..<StripSections.maxRecent { ingest(st.store, "fill \(i)") }
        let newest = st.store.clips.first!
        st.clickClip(oldest.id, command: true, shift: false); st.clickClip(newest.id, command: true, shift: false)
        XCTAssertEqual(st.picks.count, 2)
        ingest(st.store, "one more")                   // pushes "oldest" past the 80 shown
        let end = Date().addingTimeInterval(2)
        while st.picks.contains(oldest.id) && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(st.picks.ids, [newest.id])
    }
}
