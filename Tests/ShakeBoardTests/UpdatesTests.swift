//
//  UpdatesTests.swift
//  ShakeBoardTests
//

import XCTest
@testable import ShakeBoard

@MainActor
final class UpdatesTests: XCTestCase {
    private final class FakeUpdater: UpdaterDriving {
        var isConfigured: Bool
        var canCheckForUpdates: Bool
        var automaticallyChecksForUpdates: Bool
        var availableUpdate: String?
        var onStateChange: (() -> Void)?
        private(set) var checkCount = 0

        init(isConfigured: Bool = true, canCheckForUpdates: Bool = true,
             automaticallyChecksForUpdates: Bool = false, availableUpdate: String? = nil) {
            self.isConfigured = isConfigured
            self.canCheckForUpdates = canCheckForUpdates
            self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            self.availableUpdate = availableUpdate
        }

        func checkForUpdates() {
            checkCount += 1
            availableUpdate = nil
            onStateChange?()
        }
    }

    func testAutomaticChecksToggleWritesThroughUpdaterSeam() {
        let updater = FakeUpdater()
        let model = SettingsModel(defaults: UserDefaults(suiteName: "shakeboard.tests.updates.toggle.\(UUID())")!,
                                  updater: updater)

        model.setAutomaticallyChecksForUpdates(true)

        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertTrue(model.automaticallyChecksForUpdates)
    }

    func testCheckForUpdatesButtonCallsUpdaterSeam() {
        let updater = FakeUpdater()
        let model = SettingsModel(defaults: UserDefaults(suiteName: "shakeboard.tests.updates.check.\(UUID())")!,
                                  updater: updater)

        model.checkForUpdates()

        XCTAssertEqual(updater.checkCount, 1)
    }

    func testUpdateChoiceBannerRequiresConfiguredUpdaterAndUnansweredChoice() {
        let unanswered = UserDefaults(suiteName: "shakeboard.tests.updates.choice.unanswered.\(UUID())")!
        let answered = UserDefaults(suiteName: "shakeboard.tests.updates.choice.answered.\(UUID())")!
        answered.set(true, forKey: "updateChoiceMade")

        XCTAssertTrue(SettingsModel(defaults: unanswered, updater: FakeUpdater()).shouldShowUpdateChoice)
        XCTAssertFalse(SettingsModel(defaults: unanswered, updater: FakeUpdater(isConfigured: false)).shouldShowUpdateChoice)
        XCTAssertFalse(SettingsModel(defaults: answered, updater: FakeUpdater()).shouldShowUpdateChoice)
    }

    func testTurningOnAutomaticUpdatesPersistsChoiceAndEnablesUpdater() {
        let defaults = UserDefaults(suiteName: "shakeboard.tests.updates.choice.on.\(UUID())")!
        let updater = FakeUpdater()
        let model = SettingsModel(defaults: defaults, updater: updater)

        model.chooseAutomaticUpdates(true)

        XCTAssertTrue(defaults.bool(forKey: "updateChoiceMade"))
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(model.shouldShowUpdateChoice)
    }

    func testNotNowPersistsChoiceWithoutEnablingUpdater() {
        let defaults = UserDefaults(suiteName: "shakeboard.tests.updates.choice.not-now.\(UUID())")!
        let updater = FakeUpdater()
        let model = SettingsModel(defaults: defaults, updater: updater)

        model.chooseAutomaticUpdates(false)

        XCTAssertTrue(defaults.bool(forKey: "updateChoiceMade"))
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(model.shouldShowUpdateChoice)
    }

    func testUnansweredChoiceForcesAutomaticChecksOff() {
        let defaults = UserDefaults(suiteName: "shakeboard.tests.updates.choice.default-off.\(UUID())")!
        let updater = FakeUpdater(automaticallyChecksForUpdates: true)

        let model = SettingsModel(defaults: defaults, updater: updater)

        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(model.automaticallyChecksForUpdates)
        XCTAssertTrue(model.shouldShowUpdateChoice)
    }

    func testAvailableUpdateNoticeAppearsAndInstallChecksForUpdates() {
        let defaults = UserDefaults(suiteName: "shakeboard.tests.updates.available.\(UUID())")!
        let updater = FakeUpdater(availableUpdate: "1.2.3")
        let model = SettingsModel(defaults: defaults, updater: updater)

        let notice = model.alerts(in: .general).first { $0.id == "update-available" }
        XCTAssertEqual(notice?.text, "ShakeBoard 1.2.3 is available.")
        XCTAssertEqual(notice?.severity, .attentionNotice)
        XCTAssertEqual(notice?.action, .installUpdate)
        XCTAssertTrue(model.needsAttention)

        model.performAlertAction(.installUpdate)

        XCTAssertEqual(updater.checkCount, 1)
        XCTAssertFalse(model.alerts(in: .general).contains { $0.id == "update-available" })
    }

    func testUpdateControlsAreDisabledAndDoNotCheckWhenUnconfigured() {
        let updater = FakeUpdater(isConfigured: false)
        let model = SettingsModel(defaults: UserDefaults(suiteName: "shakeboard.tests.updates.disabled.\(UUID())")!,
                                  updater: updater)

        XCTAssertFalse(model.updatesConfigured)
        XCTAssertFalse(model.canCheckForUpdates)
        model.setAutomaticallyChecksForUpdates(true)
        model.checkForUpdates()

        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertEqual(updater.checkCount, 0)
    }

    func testPublicKeyConfigurationRejectsEmptyAndPlaceholderValues() {
        XCTAssertFalse(SparkleConfiguration.isConfigured(publicEDKey: ""))
        XCTAssertFalse(SparkleConfiguration.isConfigured(publicEDKey: "   "))
        XCTAssertFalse(SparkleConfiguration.isConfigured(publicEDKey: "UNSET_SPARKLE_PUBLIC_ED_KEY"))
    }

    func testPublicKeyConfigurationAcceptsOnlyBase64Encoded32ByteKeys() {
        let validKey = Data(repeating: 0xA5, count: 32).base64EncodedString()

        XCTAssertTrue(SparkleConfiguration.isConfigured(publicEDKey: validKey))
        XCTAssertFalse(SparkleConfiguration.isConfigured(publicEDKey: "not base64"))
        XCTAssertFalse(SparkleConfiguration.isConfigured(
            publicEDKey: Data(repeating: 0xA5, count: 31).base64EncodedString()
        ))
        XCTAssertFalse(SparkleConfiguration.isConfigured(
            publicEDKey: Data(repeating: 0xA5, count: 33).base64EncodedString()
        ))
    }
}
