import AppKit
import XCTest
@testable import ShakeBoard

@MainActor
final class CalibrationSessionTests: XCTestCase {
    private final class TestCancellation: CalibrationCancellable {
        private(set) var cancelCount = 0
        func cancel() { cancelCount += 1 }
    }

    @MainActor
    private final class Harness {
        let monitor = NSObject()
        let cancellation = TestCancellation()
        var addMonitorCount = 0
        var removeMonitorCount = 0
        var beginTrackingCount = 0
        var endTrackingCount = 0
        var scheduledDelay: TimeInterval?
        var scheduledCallback: (() -> Void)?
        var progress: [Int] = []
        var finishes: [(reversals: Int, swing: CGFloat)] = []

        func makeSession() -> CalibrationSession {
            CalibrationSession(
                addLocalMonitor: { [self] handler in
                    addMonitorCount += 1
                    return monitor
                },
                removeMonitor: { [self] token in
                    XCTAssertTrue(token as AnyObject === monitor)
                    removeMonitorCount += 1
                },
                schedule: { [self] delay, callback in
                    scheduledDelay = delay
                    scheduledCallback = callback
                    return cancellation
                },
                beginTracking: { [self] in beginTrackingCount += 1 },
                endTracking: { [self] in endTrackingCount += 1 },
                onProgress: { [self] in progress.append($0) },
                onFinish: { [self] in finishes.append(($0, $1)) }
            )
        }
    }

    func testStartInstallsOneMonitorBeginsTrackingAndSchedulesFinish() {
        let harness = Harness()
        let session = harness.makeSession()

        session.start()
        session.start()

        XCTAssertEqual(harness.addMonitorCount, 1)
        XCTAssertEqual(harness.beginTrackingCount, 1)
        XCTAssertEqual(harness.scheduledDelay, 2.5)
        XCTAssertEqual(harness.progress, [0])
    }

    func testFinishCleansUpOnceClearsSamplesAndReportsReversals() {
        let harness = Harness()
        let session = harness.makeSession()
        session.start()
        [30, -30, 30].forEach { session.record(deltaX: CGFloat($0)) }

        session.finish()
        session.finish()

        XCTAssertEqual(harness.removeMonitorCount, 1)
        XCTAssertEqual(harness.endTrackingCount, 1)
        XCTAssertEqual(harness.cancellation.cancelCount, 1)
        XCTAssertEqual(harness.finishes.count, 1)
        XCTAssertEqual(harness.finishes[0].reversals, 2)
        XCTAssertEqual(harness.finishes[0].swing, 30)

        session.start()
        session.finish()
        XCTAssertEqual(harness.finishes.last?.reversals, 0, "a new session must not retain old samples")
    }

    func testCancelBeforeFinishMakesLateScheduledCallbackHarmless() {
        let harness = Harness()
        let session = harness.makeSession()
        session.start()
        session.record(deltaX: 30)
        let lateCallback = harness.scheduledCallback

        session.cancel()
        lateCallback?()

        XCTAssertEqual(harness.removeMonitorCount, 1)
        XCTAssertEqual(harness.endTrackingCount, 1)
        XCTAssertEqual(harness.cancellation.cancelCount, 1)
        XCTAssertTrue(harness.finishes.isEmpty)
    }

    func testDoubleCancelIsHarmless() {
        let harness = Harness()
        let session = harness.makeSession()
        session.start()

        session.cancel()
        session.cancel()

        XCTAssertEqual(harness.removeMonitorCount, 1)
        XCTAssertEqual(harness.endTrackingCount, 1)
        XCTAssertEqual(harness.cancellation.cancelCount, 1)
    }

    func testRecordBeforeStartIsIgnored() {
        let harness = Harness()
        let session = harness.makeSession()

        session.record(deltaX: 30)
        session.start()
        session.finish()

        XCTAssertEqual(harness.progress, [0])
        XCTAssertEqual(harness.finishes.first?.reversals, 0)
    }
}

@MainActor
final class CalibrationMouseTrackingTests: XCTestCase {
    func testEndCalibrationTrackingRestoresFalse() {
        exerciseRestore(prior: false)
    }

    func testEndCalibrationTrackingRestoresTrue() {
        exerciseRestore(prior: true)
    }

    private func exerciseRestore(prior: Bool) {
        let suite = "shakeboard.tests.calibration-window.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.acceptsMouseMovedEvents = prior
        let controller = SettingsWindowController(
            model: SettingsModel(defaults: defaults),
            themes: ThemeStore(prefs: PerchPrefs(defaults: defaults)),
            window: window
        )

        controller.beginCalibrationMouseTracking()
        XCTAssertTrue(window.acceptsMouseMovedEvents)
        controller.endCalibrationMouseTracking()

        XCTAssertEqual(window.acceptsMouseMovedEvents, prior)
    }
}
