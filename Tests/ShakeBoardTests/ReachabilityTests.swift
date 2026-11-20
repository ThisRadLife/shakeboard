//
//  ReachabilityTests.swift -- v2 PR 5: no menu-bar icon. Launch greeting, login detection, strip Cmd-, / Cmd-Q.
//

import XCTest
import AppKit
import Carbon
@testable import ShakeBoard

@MainActor
final class ReachabilityTests: XCTestCase {
    func testColdLaunchYouStartedOpensSettings() {
        XCTAssertEqual(LaunchGreeting.section(loginLaunch: false, debugShow: false, stripShortcutFailed: false), .general)
    }
    func testLoginLaunchStaysSilent() {
        XCTAssertNil(LaunchGreeting.section(loginLaunch: true, debugShow: false, stripShortcutFailed: false))
    }
    func testCommandSpaceFailureOpensShortcutsEvenAtLogin() {
        XCTAssertEqual(LaunchGreeting.section(loginLaunch: true, debugShow: false, stripShortcutFailed: true), .shortcuts)
        XCTAssertEqual(LaunchGreeting.section(loginLaunch: false, debugShow: false, stripShortcutFailed: true), .shortcuts)
    }
    func testDevSnapshotRunsStaySilent() {
        XCTAssertNil(LaunchGreeting.section(loginLaunch: false, debugShow: true, stripShortcutFailed: true))
    }

    func testLoginDetection() {
        let now = Date()
        XCTAssertTrue(LaunchGreeting.isLoginLaunch(appleEventSaysLoginItem: true, loginItemEnabled: false, sessionStart: nil, now: now))
        XCTAssertTrue(LaunchGreeting.isLoginLaunch(appleEventSaysLoginItem: false, loginItemEnabled: true,
                                                   sessionStart: now.addingTimeInterval(-30), now: now))
        XCTAssertFalse(LaunchGreeting.isLoginLaunch(appleEventSaysLoginItem: false, loginItemEnabled: true,
                                                    sessionStart: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(LaunchGreeting.isLoginLaunch(appleEventSaysLoginItem: false, loginItemEnabled: true, sessionStart: nil, now: now))
        XCTAssertFalse(LaunchGreeting.isLoginLaunch(appleEventSaysLoginItem: false, loginItemEnabled: true,
                                                    sessionStart: now.addingTimeInterval(60), now: now),
                       "a clock in the future is not a login")
    }
    func testRecentLoginOnlyCountsWhenLaunchAtLoginIsOn() {
        let now = Date()
        XCTAssertFalse(LaunchGreeting.isLoginLaunch(appleEventSaysLoginItem: false, loginItemEnabled: false,
                                                    sessionStart: now.addingTimeInterval(-30), now: now),
                       "opening ShakeBoard yourself right after login still greets you when launch-at-login is off")
    }
    func testShareExtensionColdLaunchStaysSilent() {
        XCTAssertNil(LaunchGreeting.section(loginLaunch: false, handoffLaunch: true, debugShow: false,
                                            stripShortcutFailed: false))
        XCTAssertNil(LaunchGreeting.section(loginLaunch: false, handoffLaunch: true, debugShow: false,
                                            stripShortcutFailed: true), "a share never steals focus")
    }
    func testRenameMigrationOpensGeneralAtLoginButPreservesHigherPriorityRules() {
        XCTAssertEqual(LaunchGreeting.section(loginLaunch: true, debugShow: false,
                                              stripShortcutFailed: false,
                                              renameMigrationThisLaunch: true), .general)
        XCTAssertNil(LaunchGreeting.section(loginLaunch: true, handoffLaunch: true, debugShow: false,
                                            stripShortcutFailed: false,
                                            renameMigrationThisLaunch: true))
        XCTAssertEqual(LaunchGreeting.section(loginLaunch: true, debugShow: false,
                                              stripShortcutFailed: true,
                                              renameMigrationThisLaunch: true), .shortcuts)
    }
    func testConsoleLoginTimeIsInThePastIfKnown() {
        if let t = LaunchGreeting.consoleLoginTime() { XCTAssertLessThanOrEqual(t, Date()) }
    }

    // MARK: strip keys

    private var tmp: URL!
    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardReach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func makeStrip() -> StripController {
        let store = ClipStore(baseDir: tmp); store.load()
        let pins = ClipPins(baseDir: tmp); pins.load()
        let state = StripState(shelf: ShelfModel(baseDir: tmp), store: store, pins: pins)
        return StripController(state: state)
    }
    private func key(_ code: Int, _ chars: String, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: UInt16(code))!
    }

    func testCommandCommaOpensSettingsAndCommandQQuits() {
        let strip = makeStrip()
        var settings = 0, quits = 0
        strip.openSettings = { settings += 1 }
        strip.quit = { quits += 1 }
        XCTAssertTrue(strip.handleKey(key(kVK_ANSI_Comma, ",", .command)))
        XCTAssertEqual(settings, 1)
        XCTAssertTrue(strip.handleKey(key(kVK_ANSI_Q, "q", .command)))
        XCTAssertEqual(quits, 1)
        XCTAssertFalse(strip.handleKey(key(kVK_ANSI_Q, "q")), "a bare q types into search")
        XCTAssertEqual(quits, 1)
    }
}
