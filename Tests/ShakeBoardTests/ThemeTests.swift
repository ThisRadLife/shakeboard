//
//  ThemeTests.swift
//  ShakeBoardTests
//

import XCTest
@testable import ShakeBoard

@MainActor
final class ThemeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "shakeboard.tests.themes.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testContrastMathUsesWCAGSRGB() throws {
        let white = try XCTUnwrap(ThemeColor(hex: "#ffffff"))
        let black = try XCTUnwrap(ThemeColor(hex: "#000000"))
        let gray = try XCTUnwrap(ThemeColor(hex: "#777777"))
        XCTAssertEqual(PerchTheme.contrastRatio(white, black), 21, accuracy: 0.001)
        XCTAssertEqual(PerchTheme.contrastRatio(gray, gray), 1, accuracy: 0.001)
        XCTAssertEqual(PerchTheme.contrastRatio(gray, white), 4.48, accuracy: 0.02)
    }

    func testBuiltInsHaveUniqueIDsReadableCardsAndRoundTrip() throws {
        let themes = PerchTheme.builtIns
        XCTAssertEqual(Set(themes.map(\.id)).count, themes.count)
        for theme in themes {
            XCTAssertGreaterThanOrEqual(
                PerchTheme.contrastRatio(theme.text, theme.card), 4.5,
                "\(theme.id) text must remain readable on cards"
            )
            let data = try JSONEncoder().encode(theme)
            XCTAssertEqual(try JSONDecoder().decode(PerchTheme.self, from: data), theme)
        }
    }

    func testSanitizingDropsInvalidColorsCollisionsAndDuplicateIDs() throws {
        let validID = "custom-\(UUID().uuidString.lowercased())"
        let valid = rawTheme(id: validID, name: " First ")
        let duplicate = rawTheme(id: validID, name: "Duplicate")
        let collision = rawTheme(id: "system", name: "Collision")
        let badHex = rawTheme(id: "custom-\(UUID().uuidString.lowercased())", name: "Bad", background: "#xyzxyz")
        let outOfRange = rawTheme(id: "custom-\(UUID().uuidString.lowercased())", name: "Range",
                                  background: ["red": 2, "green": 0, "blue": 0])
        defaults.set(try JSONSerialization.data(withJSONObject: [valid, duplicate, collision, badHex, outOfRange]),
                     forKey: "customThemes")

        let store = ThemeStore(prefs: PerchPrefs(defaults: defaults))
        XCTAssertEqual(store.customThemes.map(\.id), [validID])
        XCTAssertEqual(store.customThemes.first?.name, "First")
    }

    func testSanitizingCapsAtTwentyAndNormalizesNames() throws {
        var raw: [[String: Any]] = []
        for index in 0..<24 {
            raw.append(rawTheme(id: "custom-\(UUID().uuidString.lowercased())",
                                name: index == 0 ? " \u{0007}\n " : " Theme \(index) "))
        }
        defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: "customThemes")
        let store = ThemeStore(prefs: PerchPrefs(defaults: defaults))
        XCTAssertEqual(store.customThemes.count, 20)
        XCTAssertEqual(store.customThemes.first?.name, "Custom")
        XCTAssertEqual(store.customThemes[1].name, "Theme 1")
    }

    func testCorruptDataIsEmptyAndUnknownSelectionFallsBackWithoutOverwriting() {
        let corrupt = Data("not json".utf8)
        defaults.set(corrupt, forKey: "customThemes")
        defaults.set("missing", forKey: "themeSelected")
        let store = ThemeStore(prefs: PerchPrefs(defaults: defaults))
        XCTAssertTrue(store.customThemes.isEmpty)
        XCTAssertEqual(store.selectedID, "system")
        XCTAssertEqual(defaults.data(forKey: "customThemes"), corrupt)
    }

    func testPersistenceRoundTripAndDeletingSelectedReturnsToSystem() throws {
        let first = ThemeStore(prefs: PerchPrefs(defaults: defaults))
        let custom = try XCTUnwrap(first.duplicate(from: PerchTheme.midnight))
        XCTAssertEqual(first.selectedID, custom.id)

        let second = ThemeStore(prefs: PerchPrefs(defaults: defaults))
        XCTAssertEqual(second.customThemes, [custom])
        XCTAssertEqual(second.selectedID, custom.id)
        second.delete(id: custom.id)
        XCTAssertEqual(second.selectedID, "system")
        XCTAssertTrue(second.customThemes.isEmpty)
    }

    func testCustomThemeCapRejectsDuplicateWithoutChangingThemes() throws {
        let raw = (0..<20).map { index in
            rawTheme(id: "custom-\(UUID().uuidString.lowercased())", name: "Theme \(index)")
        }
        defaults.set(try JSONSerialization.data(withJSONObject: raw), forKey: "customThemes")
        let store = ThemeStore(prefs: PerchPrefs(defaults: defaults))

        XCTAssertFalse(store.canAddCustom)
        XCTAssertNil(store.duplicate(from: PerchTheme.midnight))
        XCTAssertNil(store.newTheme())
        XCTAssertEqual(store.customThemes.count, 20)
    }

    func testRapidUpdatesPersistCustomThemesOnceWhenFlushed() throws {
        let id = "custom-\(UUID().uuidString.lowercased())"
        defaults.set(try JSONSerialization.data(withJSONObject: [rawTheme(id: id, name: "Original")]),
                     forKey: "customThemes")
        var writes: [Data?] = []
        let store = ThemeStore(prefs: PerchPrefs(defaults: defaults), themeDataWriter: { writes.append($0) })
        var changed = try XCTUnwrap(store.theme(id: id))

        changed.name = "First"
        store.update(changed)
        changed.name = "Second"
        store.update(changed)
        changed.name = "Final"
        store.update(changed)

        XCTAssertTrue(writes.isEmpty)
        store.flushPendingSave()
        XCTAssertEqual(writes.count, 1)
        let data = try XCTUnwrap(writes[0])
        XCTAssertEqual(try JSONDecoder().decode([PerchTheme].self, from: data).first?.name, "Final")
        store.flushPendingSave()
        XCTAssertEqual(writes.count, 1)
    }

    func testBuiltInsCannotBeUpdatedOrDeleted() {
        let store = ThemeStore(prefs: PerchPrefs(defaults: defaults))
        var changed = PerchTheme.midnight
        changed.name = "Changed"
        store.update(changed)
        store.delete(id: "midnight")
        XCTAssertEqual(store.theme(id: "midnight"), PerchTheme.midnight)
        XCTAssertTrue(store.customThemes.isEmpty)
    }

    func testOnAccentUsesTheHigherContrastForegroundForEveryBuiltIn() {
        for theme in PerchTheme.builtIns {
            let blackContrast = PerchTheme.contrastRatio(theme.accent, .black)
            let whiteContrast = PerchTheme.contrastRatio(theme.accent, .white)
            let expected: ThemeColor = blackContrast >= whiteContrast ? .black : .white
            let actualContrast = PerchTheme.contrastRatio(theme.accent, theme.onAccent)

            XCTAssertEqual(theme.onAccent, expected, "\(theme.id) must use the higher-contrast foreground")
            XCTAssertGreaterThanOrEqual(actualContrast, 3, "\(theme.id) accent foreground must remain legible")
        }
    }

    func testOnCollectingUsesTheHigherContrastForegroundForEveryBuiltIn() {
        for theme in PerchTheme.builtIns {
            let blackContrast = PerchTheme.contrastRatio(theme.collecting, .black)
            let whiteContrast = PerchTheme.contrastRatio(theme.collecting, .white)
            let expected: ThemeColor = blackContrast >= whiteContrast ? .black : .white

            XCTAssertEqual(theme.onCollecting, expected, "\(theme.id) collecting badge must use the higher-contrast foreground")
        }
    }

    private func rawTheme(id: String, name: String, background: Any = "#123456") -> [String: Any] {
        [
            "id": id, "name": name, "background": background,
            "card": "#ffffff", "text": "#000000", "accent": "#3366ff", "collecting": "#ff0000",
        ]
    }
}
