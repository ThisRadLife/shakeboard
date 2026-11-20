//
//  HotKeysTests.swift
//  Global shortcuts: fake registrar (no Carbon), throwaway defaults suite (never the real prefs).
//

import XCTest
import Carbon
@testable import ShakeBoard

@MainActor
final class FakeRegistrar: HotKeyRegistrar {
    final class Reg: HotKeyRegistration {
        let keyCode: UInt32, modifiers: UInt32, action: () -> Void
        weak var owner: FakeRegistrar?
        init(_ k: UInt32, _ m: UInt32, _ a: @escaping () -> Void) { keyCode = k; modifiers = m; action = a }
        deinit { let k = keyCode; let o = owner; MainActor.assumeIsolated { o?.unregistered.append(k) } }
    }
    var refuse: Set<UInt32> = []
    var unregistered: [UInt32] = []
    private(set) var attempts: [(UInt32, UInt32)] = []
    private var live: [WeakReg] = []
    struct WeakReg { weak var reg: Reg? }

    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> HotKeyRegistration? {
        attempts.append((keyCode, modifiers))
        guard !refuse.contains(keyCode) else { return nil }
        let r = Reg(keyCode, modifiers, action); r.owner = self
        live.append(WeakReg(reg: r))
        return r
    }
    var registered: [(UInt32, UInt32)] { live.compactMap { $0.reg }.map { ($0.keyCode, $0.modifiers) } }
    func press(_ keyCode: UInt32, _ modifiers: UInt32) {
        live.compactMap(\.reg).first { $0.keyCode == keyCode && $0.modifiers == modifiers }?.action()
    }
}

@MainActor
final class HotKeysTests: XCTestCase {
    private var reg: FakeRegistrar!
    private var defaults: UserDefaults!
    private var suite: String!
    private var stripToggles = 0
    private var stackToggles = 0
    private var keys: PerchHotKeys!

    private let CMD = UInt32(cmdKey), SHIFT = UInt32(shiftKey), OPT = UInt32(optionKey), CTRL = UInt32(controlKey)
    private let C = UInt32(kVK_ANSI_C), V = UInt32(kVK_ANSI_V), S = UInt32(kVK_ANSI_S), SPACE = UInt32(kVK_Space)

    override func setUp() {
        super.setUp()
        suite = "shakeboard.tests.hotkeys.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        reg = FakeRegistrar()
        stripToggles = 0; stackToggles = 0
        makeKeys()
    }
    override func tearDown() {
        keys = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }
    private func makeKeys() {
        keys = PerchHotKeys(registrar: reg, defaults: defaults,
                            onToggleStrip: { [unowned self] in self.stripToggles += 1 },
                            onToggleStack: { [unowned self] in self.stackToggles += 1 })
    }

    // MARK: default: Command-Space only

    func testStartRegistersOnlyCommandSpace() {
        keys.start()
        XCTAssertEqual(reg.registered.count, 1)
        XCTAssertEqual(reg.registered.first?.0, SPACE)
        XCTAssertEqual(reg.registered.first?.1, CMD)
        XCTAssertNil(keys.stackShortcut, "the stack shortcut is unset by default")
        XCTAssertTrue(keys.failures.isEmpty)
    }

    func testCommandSpaceTogglesStripEveryPress() {
        keys.start()
        reg.press(SPACE, CMD); reg.press(SPACE, CMD); reg.press(SPACE, CMD)
        XCTAssertEqual(stripToggles, 3)
        XCTAssertEqual(stackToggles, 0)
    }

    func testNeverRegistersCommandCOrV() {
        keys.start()
        reg.press(SPACE, CMD)
        keys.setStackShortcut(HotKeyCombo(keyCode: C, modifiers: CMD))
        keys.setStackShortcut(HotKeyCombo(keyCode: V, modifiers: CMD))
        for (k, m) in reg.attempts where m == CMD {
            XCTAssertFalse(k == C || k == V, "Command-C / Command-V must never be registered globally")
        }
    }

    func testStartIsIdempotent() {
        keys.start(); keys.start()
        XCTAssertEqual(reg.registered.filter { $0.0 == SPACE }.count, 1)
    }

    func testCommandSpaceFailureIsReported() {
        reg.refuse = [SPACE]
        keys.start()
        XCTAssertTrue(keys.stripFailed)
        XCTAssertEqual(keys.failures.count, 1)
        XCTAssertTrue(keys.failures[0].contains("Command-Space"))
    }

    func testStopUnregistersEverything() {
        keys.setStackShortcut(HotKeyCombo(keyCode: S, modifiers: CTRL | OPT))
        keys.start()
        XCTAssertEqual(reg.registered.count, 2)
        keys.stop()
        XCTAssertTrue(reg.registered.isEmpty)
    }

    // MARK: optional stack shortcut

    func testSavedStackShortcutRegistersAtStartAndToggles() {
        XCTAssertTrue(keys.setStackShortcut(HotKeyCombo(keyCode: S, modifiers: CTRL | OPT)))
        keys.start()
        reg.press(S, CTRL | OPT)
        XCTAssertEqual(stackToggles, 1)
        XCTAssertEqual(stripToggles, 0)
    }

    func testStackShortcutPersistsAcrossInstances() {
        keys.setStackShortcut(HotKeyCombo(keyCode: S, modifiers: CTRL | OPT))
        keys = nil
        makeKeys()
        XCTAssertEqual(keys.stackShortcut, HotKeyCombo(keyCode: S, modifiers: CTRL | OPT))
    }

    func testChangingStackShortcutWhileRunningReRegisters() {
        keys.start()
        keys.setStackShortcut(HotKeyCombo(keyCode: S, modifiers: CTRL | OPT))
        reg.press(S, CTRL | OPT)
        XCTAssertEqual(stackToggles, 1)
        keys.setStackShortcut(HotKeyCombo(keyCode: V, modifiers: CTRL | OPT))
        reg.press(S, CTRL | OPT)                        // old combo is gone
        XCTAssertEqual(stackToggles, 1)
        reg.press(V, CTRL | OPT)
        XCTAssertEqual(stackToggles, 2)
        XCTAssertEqual(reg.registered.count, 2)         // Command-Space + the new one, nothing leaked
    }

    func testClearingStackShortcutUnregistersIt() {
        keys.setStackShortcut(HotKeyCombo(keyCode: S, modifiers: CTRL | OPT))
        keys.start()
        keys.setStackShortcut(nil)
        XCTAssertNil(keys.stackShortcut)
        reg.press(S, CTRL | OPT)
        XCTAssertEqual(stackToggles, 0)
        XCTAssertEqual(reg.registered.count, 1)
    }

    func testStackShortcutFailureIsReportedWithItsName() {
        reg.refuse = [S]
        keys.setStackShortcut(HotKeyCombo(keyCode: S, modifiers: CTRL | OPT))
        keys.start()
        XCTAssertTrue(keys.stackFailed)
        XCTAssertFalse(keys.stripFailed)
        XCTAssertEqual(keys.failures.count, 1)
        XCTAssertTrue(keys.failures[0].contains("\u{2303}\u{2325}S"), keys.failures[0])
    }

    func testRejectedShortcutChangesNothing() {
        keys.setStackShortcut(HotKeyCombo(keyCode: S, modifiers: CTRL | OPT))
        keys.start()
        XCTAssertFalse(keys.setStackShortcut(HotKeyCombo(keyCode: C, modifiers: CMD)))
        XCTAssertEqual(keys.stackShortcut, HotKeyCombo(keyCode: S, modifiers: CTRL | OPT))
        reg.press(S, CTRL | OPT)
        XCTAssertEqual(stackToggles, 1)
    }

    func testInvalidSavedShortcutIsIgnored() {
        defaults.set(["keyCode": Int(C), "modifiers": Int(CMD)], forKey: PerchHotKeys.stackShortcutKey)
        XCTAssertNil(keys.stackShortcut)
        keys.start()
        XCTAssertEqual(reg.registered.count, 1)
        defaults.set("garbage", forKey: PerchHotKeys.stackShortcutKey)
        XCTAssertNil(keys.stackShortcut)
        // Out-of-range numbers must be rejected, not trap converting to UInt32 at launch.
        defaults.set(["keyCode": 1, "modifiers": Int(UInt32.max) + 1], forKey: PerchHotKeys.stackShortcutKey)
        XCTAssertNil(keys.stackShortcut)
        defaults.set(["keyCode": -1, "modifiers": Int(CTRL)], forKey: PerchHotKeys.stackShortcutKey)
        XCTAssertNil(keys.stackShortcut)
    }

    // MARK: HotKeyCombo rules

    func testAllowedForStack() {
        XCTAssertTrue(HotKeyCombo(keyCode: S, modifiers: CTRL | OPT).isAllowedForStack)
        XCTAssertTrue(HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: CMD | SHIFT).isAllowedForStack)
        XCTAssertTrue(HotKeyCombo(keyCode: V, modifiers: CTRL | OPT).isAllowedForStack, "no Command")
        XCTAssertTrue(HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: CMD).isAllowedForStack)
        XCTAssertTrue(HotKeyCombo(keyCode: UInt32(kVK_F5), modifiers: CTRL).isAllowedForStack)
    }

    func testRejectedForStack() {
        XCTAssertFalse(HotKeyCombo(keyCode: C, modifiers: CMD).isAllowedForStack)
        XCTAssertFalse(HotKeyCombo(keyCode: V, modifiers: CMD).isAllowedForStack)
        XCTAssertFalse(HotKeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: CMD).isAllowedForStack)
        XCTAssertFalse(HotKeyCombo(keyCode: V, modifiers: CMD | SHIFT).isAllowedForStack, "paste plain")
        XCTAssertFalse(HotKeyCombo(keyCode: V, modifiers: CMD | OPT | SHIFT).isAllowedForStack, "paste and match style")
        XCTAssertFalse(HotKeyCombo(keyCode: C, modifiers: CMD | CTRL).isAllowedForStack)
        XCTAssertFalse(HotKeyCombo(keyCode: UInt32(kVK_ANSI_Z), modifiers: CMD | SHIFT).isAllowedForStack)
        XCTAssertFalse(HotKeyCombo(keyCode: SPACE, modifiers: CMD).isAllowedForStack, "the strip shortcut")
        XCTAssertFalse(HotKeyCombo(keyCode: S, modifiers: 0).isAllowedForStack, "no modifier")
        XCTAssertFalse(HotKeyCombo(keyCode: S, modifiers: SHIFT).isAllowedForStack, "shift alone")
    }

    func testModifierBitsOutsideTheMaskAreDropped() {
        let c = HotKeyCombo(keyCode: S, modifiers: CTRL | OPT | UInt32(alphaLock))
        XCTAssertEqual(c.modifiers, CTRL | OPT)
    }

    func testDisplayName() {
        XCTAssertEqual(HotKeyCombo(keyCode: S, modifiers: CTRL | OPT | SHIFT | CMD).displayName, "\u{2303}\u{2325}\u{21E7}\u{2318}S")
        XCTAssertEqual(HotKeyCombo.toggleStrip.displayName, "\u{2318}Space")
    }
}
