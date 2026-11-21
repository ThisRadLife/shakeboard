//
//  SettingsTests.swift
//  Settings window state: prefs (throwaway defaults suite, never the real prefs), the alert list that
//  drives the gear's warning dot, shortcut recording rules, and the user's ignored-apps filter.
//

import XCTest
import AppKit
import Carbon
@testable import ShakeBoard

@MainActor
final class DebugSnapshotTests: XCTestCase {
    func testDefaultScaleUsesLegacyRenderingBytes() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 16))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemPurple.cgColor

        let legacyRep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: legacyRep)
        let legacyPNG = try XCTUnwrap(legacyRep.representation(using: .png, properties: [:]))

        XCTAssertEqual(DebugSnapshot.png(of: view, environment: [:]), legacyPNG)
        XCTAssertEqual(DebugSnapshot.png(of: view, environment: ["PERCH_DEBUG_SCALE": "1"]), legacyPNG)
    }

    func testScaleIsParsedAndClampedToOneThroughThree() {
        XCTAssertEqual(DebugSnapshot.scale(environment: [:]), 1)
        XCTAssertEqual(DebugSnapshot.scale(environment: ["PERCH_DEBUG_SCALE": "not-a-number"]), 1)
        XCTAssertEqual(DebugSnapshot.scale(environment: ["PERCH_DEBUG_SCALE": "0.5"]), 1)
        XCTAssertEqual(DebugSnapshot.scale(environment: ["PERCH_DEBUG_SCALE": "2.25"]), 2.25)
        XCTAssertEqual(DebugSnapshot.scale(environment: ["PERCH_DEBUG_SCALE": "4"]), 3)
    }

    func testScaledRenderingUsesRequestedPixelDimensionsAndLogicalSize() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 16))
        let png = try XCTUnwrap(DebugSnapshot.png(of: view, environment: ["PERCH_DEBUG_SCALE": "2.5"]))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))

        XCTAssertEqual(rep.pixelsWide, 60)
        XCTAssertEqual(rep.pixelsHigh, 40)
        XCTAssertEqual(rep.size, view.bounds.size)
    }
}

final class PerchPrefsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "shakeboard.tests.prefs.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testDefaults() {
        let p = PerchPrefs(defaults: defaults)
        XCTAssertTrue(p.addImagesToShelf)
        XCTAssertTrue(p.showOnImageCopy, "default keeps today's behavior: the strip shows for a copied image")
        XCTAssertTrue(p.shakeToShow)
        XCTAssertFalse(p.capturePaused)
        XCTAssertTrue(p.recognizeTextInImages)
        XCTAssertFalse(p.debugShakeLog)
        XCTAssertFalse(p.reduceOnDrag)
        XCTAssertEqual(p.historyMaxCount, 200)
        XCTAssertEqual(p.historyMaxDays, 7)
        XCTAssertEqual(p.shakeVariance, 0.15, accuracy: 0.0001)
        XCTAssertEqual(p.ignoredApps, ["com.apple.Passwords"])
    }

    func testShowOnImageCopyOffSuppressesTheReveal() {
        var p = PerchPrefs(defaults: defaults)
        p.showOnImageCopy = false
        XCTAssertEqual(defaults.object(forKey: "showOnImageCopy") as? Bool, false)
        XCTAssertFalse(PerchPrefs(defaults: defaults).showOnImageCopy)
        let now = Date()
        XCTAssertFalse(AppDelegate.shouldRevealForImage(showOnImageCopy: false, lastReveal: .distantPast, now: now))
        XCTAssertTrue(AppDelegate.shouldRevealForImage(showOnImageCopy: true, lastReveal: .distantPast, now: now))
        XCTAssertFalse(AppDelegate.shouldRevealForImage(showOnImageCopy: true, lastReveal: now.addingTimeInterval(-1), now: now),
                       "at most one reveal per 2 s burst")
    }

    func testRoundTripAndKeysMatchExistingPrefs() {
        var p = PerchPrefs(defaults: defaults)
        p.addImagesToShelf = false
        p.shakeVariance = 0.30
        p.historyMaxCount = 500
        p.historyMaxDays = 30
        p.capturePaused = true
        p.shakeToShow = false
        p.recognizeTextInImages = false
        // Existing keys keep their names so the installed build's settings carry over.
        XCTAssertEqual(defaults.object(forKey: "addImagesToShelf") as? Bool, false)
        XCTAssertEqual(defaults.double(forKey: "shakeVariance"), 0.30, accuracy: 0.0001)
        let q = PerchPrefs(defaults: defaults)
        XCTAssertFalse(q.addImagesToShelf)
        XCTAssertEqual(q.historyMaxCount, 500)
        XCTAssertEqual(q.historyMaxDays, 30)
        XCTAssertTrue(q.capturePaused)
        XCTAssertFalse(q.shakeToShow)
        XCTAssertFalse(q.recognizeTextInImages)
    }

    func testOutOfRangeValuesFallBackToDefaults() {
        defaults.set(7, forKey: "historyMaxCount")
        defaults.set(-3, forKey: "historyMaxDays")
        defaults.set(9.0, forKey: "shakeVariance")
        let p = PerchPrefs(defaults: defaults)
        XCTAssertEqual(p.historyMaxCount, 200)
        XCTAssertEqual(p.historyMaxDays, 7)
        XCTAssertEqual(p.shakeVariance, 0.15, accuracy: 0.0001)
    }

    func testSettingAnUnlistedValueIsIgnored() {
        var p = PerchPrefs(defaults: defaults)
        p.historyMaxCount = 3
        p.historyMaxDays = 999
        XCTAssertEqual(p.historyMaxCount, 200)
        XCTAssertEqual(p.historyMaxDays, 7)
    }

    func testIgnoredAppsAreSanitizedSortedAndDeduped() {
        var p = PerchPrefs(defaults: defaults)
        p.ignoredApps = ["com.b.app", " com.a.app ", "", "com.b.app", "not a bundle id!"]
        XCTAssertEqual(p.ignoredApps, ["com.a.app", "com.b.app"])
        defaults.set(["ok.id", 5, "bad id"], forKey: "ignoredApps")
        XCTAssertEqual(PerchPrefs(defaults: defaults).ignoredApps, ["ok.id"])
    }

    func testPasswordsIsAddedToAnExistingIgnoredListOnce() {
        defaults.set(["com.example.Editor"], forKey: "ignoredApps")
        var p = PerchPrefs(defaults: defaults)
        p.seedPasswordsIgnoredAppIfNeeded()
        p.seedPasswordsIgnoredAppIfNeeded()
        XCTAssertEqual(p.ignoredApps, ["com.apple.Passwords", "com.example.Editor"])
        XCTAssertTrue(defaults.bool(forKey: "ignoredAppsPasswordsSeeded"))
    }

    func testPasswordsRemovedByUserStaysRemovedAfterMigration() {
        defaults.set([], forKey: "ignoredApps")
        defaults.set(true, forKey: "ignoredAppsPasswordsSeeded")
        var p = PerchPrefs(defaults: defaults)
        p.seedPasswordsIgnoredAppIfNeeded()
        XCTAssertEqual(p.ignoredApps, [])
    }

    func testRetentionSeconds() {
        var p = PerchPrefs(defaults: defaults)
        p.historyMaxDays = 1
        XCTAssertEqual(p.historyMaxAge, 24 * 3600)
    }
}

final class SettingsAlertsTests: XCTestCase {
    func testNoAlertsWhenHealthy() {
        XCTAssertTrue(SettingsAlerts.compute(.init()).isEmpty)
    }

    func testEveryFailureBecomesAnAlertInItsSection() {
        var s = SettingsAlerts.Inputs()
        s.accessibilityTrusted = false
        s.shelfSaveFailed = true
        s.addFailures = 2
        s.hotKeyFailures = ["Command-Space (show/hide ShakeBoard) -- taken"]
        s.historyClearFailed = true
        s.historySaveFailed = true
        s.pinsSaveFailed = true
        s.loginItemError = "nope"
        let a = SettingsAlerts.compute(s)
        XCTAssertEqual(a.count, 8)
        XCTAssertTrue(a.contains { $0.section == .general && $0.text.contains("Accessibility") })
        XCTAssertTrue(a.contains { $0.section == .shelf && $0.text.contains("Shelf couldn't save") })
        XCTAssertTrue(a.contains { $0.section == .shelf && $0.text.contains("Couldn't add 2 items") })
        XCTAssertTrue(a.contains { $0.section == .shortcuts && $0.text.contains("Command-Space") })
        XCTAssertTrue(a.contains { $0.section == .clipboard && $0.text.contains("fully clear") })
        XCTAssertTrue(a.contains { $0.section == .clipboard && $0.text.contains("History couldn't save") })
        XCTAssertTrue(a.contains { $0.section == .clipboard && $0.text.contains("Pins couldn't save") })
        XCTAssertTrue(a.contains { $0.section == .general && $0.text.contains("nope") })
        XCTAssertEqual(Set(a.map(\.id)).count, a.count, "ids must be unique for SwiftUI lists")
    }

    func testDegradedOnlyWhenClearDidNotFail() {
        var s = SettingsAlerts.Inputs()
        s.historyDegraded = true
        XCTAssertTrue(SettingsAlerts.compute(s).contains { $0.text.contains("History paused") })
        s.historyClearFailed = true
        let a = SettingsAlerts.compute(s)
        XCTAssertFalse(a.contains { $0.text.contains("History paused") })
        XCTAssertTrue(a.contains { $0.text.contains("fully clear") })
    }

    func testSetAsidePinboardsWarnsAndLightsAttentionDot() {
        var s = SettingsAlerts.Inputs()
        s.pinboardsSetAside = "pinboards.json.unreadable-1800000000"

        let alerts = SettingsAlerts.compute(s)

        XCTAssertTrue(alerts.contains {
            $0.section == .clipboard
                && $0.text == "Pinboards file was unreadable and set aside (pinboards.json.unreadable-1800000000). Copies are protected until you restart."
        })
        XCTAssertTrue(SettingsAlerts.needsAttention(alerts))
    }

    func testReadOnlyPinboardsWarnsThatCopiesAreProtected() {
        var s = SettingsAlerts.Inputs()
        s.pinboardsReadOnly = true

        let alerts = SettingsAlerts.compute(s)

        XCTAssertTrue(alerts.contains {
            $0.section == .clipboard
                && $0.text == "Pinboards file is unreadable and couldn't be set aside -- boards are read-only and copies are protected."
        })
        XCTAssertTrue(SettingsAlerts.needsAttention(alerts))
    }

    func testSingularAddFailure() {
        var s = SettingsAlerts.Inputs(); s.addFailures = 1
        XCTAssertTrue(SettingsAlerts.compute(s).contains { $0.text.contains("Couldn't add 1 item") && !$0.text.contains("items") })
    }

    func testPausedCaptureIsANoticeNotAFailure() {
        var s = SettingsAlerts.Inputs(); s.capturePaused = true
        let a = SettingsAlerts.compute(s)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a.first?.severity, .notice)
        XCTAssertFalse(SettingsAlerts.needsAttention(a), "a pause the user chose doesn't light the warning dot")
        s.shelfSaveFailed = true
        XCTAssertTrue(SettingsAlerts.needsAttention(SettingsAlerts.compute(s)))
    }
}

@MainActor
final class RenameWelcomeSettingsTests: XCTestCase {
    func testDoneClearsPersistedWelcomeFlag() {
        let suite = "shakeboard.tests.rename-welcome.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PerchMigration.welcomeKey)
        let model = SettingsModel(defaults: defaults)

        model.dismissRenameWelcome()

        XCTAssertFalse(model.prefs.showRenameWelcome)
        XCTAssertFalse(defaults.bool(forKey: PerchMigration.welcomeKey))
    }

    func testPermissionStatusesRefreshLiveWithoutReadingPasteboardContents() {
        let suite = "shakeboard.tests.rename-status.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsModel(defaults: defaults)
        var status = PasteboardAccessStatus.ask
        model.actions.pasteboardAccessStatus = { status }

        model.refresh(alertInputs: .init(), full: false)
        XCTAssertEqual(model.pasteboardAccessStatus, .ask)
        status = .alwaysAllow
        model.refresh(alertInputs: .init(), full: false)
        XCTAssertEqual(model.pasteboardAccessStatus, .alwaysAllow)
    }
}

final class ShortcutRecordingTests: XCTestCase {
    func testCocoaFlagsMapToCarbonModifiers() {
        let c = HotKeyCombo(keyCode: UInt16(kVK_ANSI_K), cocoaFlags: [.command, .option, .capsLock, .function])
        XCTAssertEqual(c.keyCode, UInt32(kVK_ANSI_K))
        XCTAssertEqual(c.modifiers, UInt32(cmdKey | optionKey))
        let d = HotKeyCombo(keyCode: UInt16(kVK_ANSI_K), cocoaFlags: [.control, .shift])
        XCTAssertEqual(d.modifiers, UInt32(controlKey | shiftKey))
    }

    func testRecordingVerdicts() {
        let ok = HotKeyCombo(keyCode: UInt16(kVK_ANSI_K), cocoaFlags: [.control, .option])
        XCTAssertEqual(ShortcutRecorderLogic.verdict(for: ok), .accept(ok))
        XCTAssertEqual(ShortcutRecorderLogic.verdict(keyCode: UInt16(kVK_Escape), flags: []), .cancel)
        XCTAssertEqual(ShortcutRecorderLogic.verdict(keyCode: UInt16(kVK_Delete), flags: []), .clear)
        // Pressing only a modifier keeps waiting.
        XCTAssertEqual(ShortcutRecorderLogic.verdict(keyCode: UInt16(kVK_Command), flags: [.command]), .keepWaiting)
        if case .reject(let why) = ShortcutRecorderLogic.verdict(keyCode: UInt16(kVK_ANSI_V), flags: [.command]) {
            XCTAssertTrue(why.contains("copy"), why)
        } else { XCTFail("Command-V must be rejected") }
        if case .reject(let why) = ShortcutRecorderLogic.verdict(keyCode: UInt16(kVK_Space), flags: [.command]) {
            XCTAssertTrue(why.contains("ShakeBoard"), why)
        } else { XCTFail("Command-Space must be rejected") }
        if case .reject(let why) = ShortcutRecorderLogic.verdict(keyCode: UInt16(kVK_ANSI_K), flags: [.shift]) {
            XCTAssertTrue(why.contains("Command, Control or Option"), why)
        } else { XCTFail("Shift-K must be rejected") }
    }
}

final class IgnoredAppsFilterTests: XCTestCase {
    func testUserIgnoredAppsAreSkippedAlongsideBuiltIns() {
        let ignored = ClipTypes.ignoredBundleIDs.union(["com.example.notes"])
        XCTAssertEqual(ClipFilter.skipReason(types: [ClipTypes.plainText], bundleID: "com.example.notes",
                                             secureInput: false, ignored: ignored), .ignoredApp)
        XCTAssertEqual(ClipFilter.skipReason(types: [ClipTypes.plainText], bundleID: "com.1password.1password",
                                             secureInput: false, ignored: ignored), .ignoredApp)
        XCTAssertNil(ClipFilter.skipReason(types: [ClipTypes.plainText], bundleID: "com.example.other",
                                           secureInput: false, ignored: ignored))
    }
}

@MainActor
final class SettingsMonitorTests: XCTestCase {
    func testMonitorSkipsUserIgnoredAppsAndPicksUpListChanges() {
        let pb = FakePasteboard()
        var extra: Set<String> = []
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { ("com.example.notes", "Notes") })
        m.extraIgnored = { extra }
        var got = 0
        m.onCapture = { _ in got += 1 }
        pb.set([[RawRep(type: ClipTypes.plainText, data: Data("a".utf8))]])
        m.tick()
        XCTAssertEqual(got, 1)
        extra = ["com.example.notes"]
        pb.set([[RawRep(type: ClipTypes.plainText, data: Data("b".utf8))]])
        m.tick()
        XCTAssertEqual(got, 1)
        XCTAssertEqual(m.lastSkip, .ignoredApp)
    }
}

@MainActor
final class SettingsHotKeySuspendTests: XCTestCase {
    func testRecordingSuspendsOnlyTheStackShortcutThenRestoresIt() {
        let suite = "shakeboard.tests.suspend.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let reg = FakeRegistrar()
        var stack = 0
        let keys = PerchHotKeys(registrar: reg, defaults: d, onToggleStrip: {}, onToggleStack: { stack += 1 })
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey))
        keys.setStackShortcut(combo)
        keys.start()
        XCTAssertEqual(reg.registered.count, 2)
        keys.suspendStackShortcut(true)     // so pressing the current combo reaches the recorder
        XCTAssertEqual(reg.registered.count, 1)
        XCTAssertEqual(reg.registered.first?.0, UInt32(kVK_Space))
        reg.press(combo.keyCode, combo.modifiers)
        XCTAssertEqual(stack, 0)
        XCTAssertFalse(keys.stackFailed, "suspension is not a failure")
        keys.suspendStackShortcut(false)
        XCTAssertEqual(reg.registered.count, 2)
        reg.press(combo.keyCode, combo.modifiers)
        XCTAssertEqual(stack, 1)
    }

    func testSettingAShortcutWhileSuspendedStaysSuspendedUntilResumed() {
        let suite = "shakeboard.tests.suspend2.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let reg = FakeRegistrar()
        let keys = PerchHotKeys(registrar: reg, defaults: d, onToggleStrip: {}, onToggleStack: {})
        keys.start()
        keys.suspendStackShortcut(true)
        keys.setStackShortcut(HotKeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)))
        XCTAssertEqual(reg.registered.count, 1)
        keys.suspendStackShortcut(false)
        XCTAssertEqual(reg.registered.count, 2)
    }
}

@MainActor
final class SettingsReviewFixTests: XCTestCase {
    // Codex r1 (high): a copy made in an ignored app is skipped even if another app is frontmost by the poll.
    func testCopyFromIgnoredAppSkippedAfterSwitchingAwayBeforeThePoll() {
        let pb = FakePasteboard()
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { ("com.example.other", "Other") })
        m.extraIgnored = { ["com.example.notes"] }
        var got = 0
        m.onCapture = { _ in got += 1 }
        pb.set([[RawRep(type: ClipTypes.plainText, data: Data("secret".utf8))]])   // copied in Notes...
        m.noteDeactivated(bundleID: "com.example.notes")                             // ...then switched away
        m.tick()
        XCTAssertEqual(got, 0)
        XCTAssertEqual(m.lastSkip, .ignoredApp)
        // The next copy, made in the other app with no ignored app active since the last poll, is saved.
        pb.set([[RawRep(type: ClipTypes.plainText, data: Data("fine".utf8))]])
        m.tick()
        XCTAssertEqual(got, 1)
    }

    func testBuiltInPasswordManagerAlsoCoveredBySwitchAway() {
        let pb = FakePasteboard()
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { ("com.apple.Safari", "Safari") })
        var got = 0
        m.onCapture = { _ in got += 1 }
        pb.set([[RawRep(type: ClipTypes.plainText, data: Data("pw".utf8))]])
        m.noteDeactivated(bundleID: "com.1password.1password")
        m.tick()
        XCTAssertEqual(got, 0)
    }

    // Codex r1 (medium): recording must end when you leave Shortcuts, and Cmd-W / Cmd-Q still work.
    func testLeavingShortcutsStopsRecordingAndResumesTheShortcut() {
        let suite = "shakeboard.tests.rec.\(UUID().uuidString)"
        let model = SettingsModel(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        var suspended: [Bool] = []
        model.actions.suspendStackShortcut = { suspended.append($0) }
        model.section = .shortcuts
        model.startRecording()
        XCTAssertTrue(model.recording)
        model.section = .clipboard
        XCTAssertFalse(model.recording)
        XCTAssertEqual(suspended, [true, false])
    }

    func testCommandWAndQPassThroughAndEndRecording() {
        let suite = "shakeboard.tests.rec2.\(UUID().uuidString)"
        let model = SettingsModel(defaults: UserDefaults(suiteName: suite)!)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        model.startRecording()
        XCTAssertFalse(model.handleRecorderKey(keyCode: UInt16(kVK_ANSI_W), flags: [.command]), "Cmd-W closes the window")
        XCTAssertFalse(model.recording)
        model.startRecording()
        XCTAssertFalse(model.handleRecorderKey(keyCode: UInt16(kVK_ANSI_Q), flags: [.command]), "Cmd-Q quits")
        XCTAssertFalse(model.recording)
    }
}

@MainActor
final class SettingsReviewFixR2Tests: XCTestCase {
    // Codex r2: a ShakeBoard write (markSeen) starts a new baseline -- an ignored app seen before it must not
    // block the next legitimate copy.
    func testMarkSeenClearsStaleIgnoredAttribution() {
        let pb = FakePasteboard()
        let m = ClipboardMonitor(pasteboard: pb, secureInput: { false }, frontmost: { ("com.example.other", "Other") })
        m.extraIgnored = { ["com.example.notes"] }
        var got = 0
        m.onCapture = { _ in got += 1 }
        m.noteDeactivated(bundleID: "com.example.notes")
        m.markSeen()
        pb.set([[RawRep(type: ClipTypes.plainText, data: Data("ok".utf8))]])
        m.tick()
        XCTAssertEqual(got, 1)
    }
}
