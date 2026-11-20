import XCTest
import SwiftUI
@testable import ShakeBoard

final class EasedScrollTests: XCTestCase {
    func testTicksAccumulateIntoTheTarget() {
        var m = EasedScroll(position: 100, upper: 1000)
        m.add(40); m.add(40); m.add(40)
        XCTAssertEqual(m.target, 220)
        XCTAssertEqual(m.position, 100, "a tick moves the target, not the view")
    }

    func testTargetClampsAtBothEdges() {
        var m = EasedScroll(position: 950, upper: 1000)
        m.add(400)
        XCTAssertEqual(m.target, 1000)
        m.add(-5000)
        XCTAssertEqual(m.target, 0)
        var lowStart = EasedScroll(position: -50, upper: 1000)
        XCTAssertEqual(lowStart.position, 0, "starts clamped")
        lowStart.add(-10)
        XCTAssertEqual(lowStart.target, 0)
    }

    func testEasesOutMonotonicallyWithoutOvershootAndSettles() {
        var m = EasedScroll(position: 0, upper: 1000)
        m.add(400)
        var last: CGFloat = 0
        var steps = 0
        var deltas: [CGFloat] = []
        while m.step(1.0 / 120.0) {
            XCTAssertGreaterThanOrEqual(m.position, last, "never moves backwards")
            XCTAssertLessThanOrEqual(m.position, 400, "never overshoots")
            deltas.append(m.position - last)
            last = m.position
            steps += 1
            XCTAssertLessThan(steps, 1000)
        }
        XCTAssertEqual(m.position, 400, "snaps exactly onto the target")
        // Ease-OUT: each frame's move is no bigger than the one before.
        for (a, b) in zip(deltas, deltas.dropFirst()) { XCTAssertLessThanOrEqual(b, a + 0.0001) }
        // Settles in roughly 200-300 ms at 120 Hz.
        XCTAssertGreaterThan(Double(steps) / 120.0, 0.15)
        XCTAssertLessThan(Double(steps) / 120.0, 0.35)
    }

    func testFrameRateIndependent() {
        var a = EasedScroll(position: 0, upper: 1000); a.add(300)
        var b = EasedScroll(position: 0, upper: 1000); b.add(300)
        for _ in 0..<6 { a.step(1.0 / 60.0) }   // 100 ms at 60 Hz
        for _ in 0..<12 { b.step(1.0 / 120.0) } // 100 ms at 120 Hz
        XCTAssertEqual(a.position, b.position, accuracy: 0.5)
    }

    func testReboundKeepsPositionAndTargetInsideShrunkContent() {
        var m = EasedScroll(position: 800, upper: 1000)
        m.add(150)
        m.rebound(lower: 0, upper: 500)
        XCTAssertEqual(m.position, 500)
        XCTAssertEqual(m.target, 500)
        XCTAssertFalse(m.step(0.016))
    }

    func testNoRoomMeansSettled() {
        var m = EasedScroll(position: 0, upper: -20)   // content narrower than the view
        m.add(100)
        XCTAssertEqual(m.target, 0)
        XCTAssertTrue(m.isSettled)
    }

    func testZeroOrNegativeDtDoesNothing() {
        var m = EasedScroll(position: 0, upper: 1000); m.add(100)
        m.step(0); m.step(-1)
        XCTAssertEqual(m.position, 0)
    }
}

final class WheelMappingTests: XCTestCase {
    func testVerticalWheelDrivesAHorizontalStrip() {
        // Wheel away from you (deltaY > 0) heads toward the start, like AppKit.
        XCTAssertEqual(WheelMapping.delta(axis: .horizontal, deltaX: 0, deltaY: 1, flipped: true), -40)
        XCTAssertEqual(WheelMapping.delta(axis: .horizontal, deltaX: 0, deltaY: -2, flipped: true), 80)
    }

    func testTiltWheelWinsWhenDominant() {
        XCTAssertEqual(WheelMapping.delta(axis: .horizontal, deltaX: -3, deltaY: 1, flipped: true), 120)
    }

    func testVerticalRespectsFlippedDocuments() {
        XCTAssertEqual(WheelMapping.delta(axis: .vertical, deltaX: 0, deltaY: -1, flipped: true), 40, "toward you = further down")
        XCTAssertEqual(WheelMapping.delta(axis: .vertical, deltaX: 0, deltaY: -1, flipped: false), -40)
    }

    func testOneBurstIsCapped() {
        XCTAssertEqual(WheelMapping.delta(axis: .horizontal, deltaX: 0, deltaY: -1000, flipped: true), WheelMapping.maxPerEvent)
        XCTAssertEqual(WheelMapping.delta(axis: .horizontal, deltaX: 0, deltaY: 1000, flipped: true), -WheelMapping.maxPerEvent)
    }
}

final class ShakeToggleTests: XCTestCase {
    func testShakeOpensThenShakeCloses() {
        var t = ShakeToggle()
        XCTAssertEqual(t.shake(at: 10, shown: false, dragging: false, inUse: false), .reveal)
        XCTAssertTrue(t.canCloseByShake)
        XCTAssertEqual(t.shake(at: 12, shown: true, dragging: false, inUse: false), .close)
        XCTAssertFalse(t.canCloseByShake)
    }

    func testCooldownSwallowsTheTailOfTheOpeningShake() {
        var t = ShakeToggle()
        XCTAssertEqual(t.shake(at: 10, shown: false, dragging: false, inUse: false), .reveal)
        XCTAssertEqual(t.shake(at: 10.5, shown: true, dragging: false, inUse: false), .ignore)
        XCTAssertEqual(t.shake(at: 11.1, shown: true, dragging: false, inUse: false), .close)
        // ...and the tail of the closing shake doesn't reopen it.
        XCTAssertEqual(t.shake(at: 11.6, shown: false, dragging: false, inUse: false), .ignore)
        XCTAssertEqual(t.shake(at: 12.2, shown: false, dragging: false, inUse: false), .reveal)
    }

    func testShakeWhileDraggingKeepsItUp() {
        var t = ShakeToggle()
        _ = t.shake(at: 0, shown: false, dragging: true, inUse: false)
        XCTAssertEqual(t.shake(at: 5, shown: true, dragging: true, inUse: false), .reveal)
        XCTAssertTrue(t.canCloseByShake, "a drag-shake doesn't spend the close")
        XCTAssertEqual(t.shake(at: 7, shown: true, dragging: false, inUse: false), .close)
    }

    func testOnlyShakeOpenedStripsClose() {
        var t = ShakeToggle()
        // Revealed by a copied image or summoned with Command-Space: a shake keeps the old behavior.
        XCTAssertEqual(t.shake(at: 5, shown: true, dragging: false, inUse: false), .reveal)
        _ = t.shake(at: 10, shown: false, dragging: false, inUse: false)
        t.reset()   // e.g. Command-Space took it over
        XCTAssertEqual(t.shake(at: 20, shown: true, dragging: false, inUse: false), .reveal)
    }

    func testInUseStripDoesNotClose() {
        var t = ShakeToggle()
        _ = t.shake(at: 0, shown: false, dragging: false, inUse: false)
        XCTAssertEqual(t.shake(at: 5, shown: true, dragging: false, inUse: true), .reveal)
        XCTAssertEqual(t.shake(at: 9, shown: true, dragging: false, inUse: false), .close)
    }
}
