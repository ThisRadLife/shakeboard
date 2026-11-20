//
//  Themes.swift
//  ShakeBoard -- built-in and user-defined color themes.
//

import AppKit
import SwiftUI

struct ThemeColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = ThemeColor(red: 0, green: 0, blue: 0)
    static let white = ThemeColor(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        guard hex.count == 7, hex.first == "#",
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
    }

    var isValid: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
               Int((blue * 255).rounded()))
    }

    init(color: Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .black
        red = Double(converted.redComponent)
        green = Double(converted.greenComponent)
        blue = Double(converted.blueComponent)
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self),
           let parsed = ThemeColor(hex: value) {
            self = parsed
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        red = try values.decode(Double.self, forKey: .red)
        green = try values.decode(Double.self, forKey: .green)
        blue = try values.decode(Double.self, forKey: .blue)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(red, forKey: .red)
        try values.encode(green, forKey: .green)
        try values.encode(blue, forKey: .blue)
    }

    private enum CodingKeys: String, CodingKey { case red, green, blue }
}

struct PerchTheme: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var background: ThemeColor
    var card: ThemeColor
    var text: ThemeColor
    var accent: ThemeColor
    var collecting: ThemeColor

    var isSystem: Bool { id == "system" }
    var isLight: Bool { Self.relativeLuminance(background) > 0.5 }
    var secondaryText: Color { text.color.opacity(0.6) }
    var onAccent: ThemeColor {
        Self.contrastingForeground(for: accent)
    }
    var onCollecting: ThemeColor { Self.contrastingForeground(for: collecting) }

    static func contrastingForeground(for color: ThemeColor) -> ThemeColor {
        contrastRatio(color, .black) >= contrastRatio(color, .white) ? .black : .white
    }

    static func relativeLuminance(_ color: ThemeColor) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    static func contrastRatio(_ first: ThemeColor, _ second: ThemeColor) -> Double {
        let values = [relativeLuminance(first), relativeLuminance(second)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }

    private static func color(_ hex: String) -> ThemeColor { ThemeColor(hex: hex)! }
    private static func solid(_ id: String, _ name: String, _ values: [String]) -> PerchTheme {
        PerchTheme(id: id, name: name, background: color(values[0]), card: color(values[1]),
                   text: color(values[2]), accent: color(values[3]), collecting: color(values[4]))
    }

    // System colors are swatches only. The System rendering path keeps the existing dynamic colors and glass.
    static let system = solid("system", "System", ["#25262A", "#34363B", "#F2F2F2", "#0A84FF", "#FF3B30"])
    static let graphite = solid("graphite", "Graphite", ["#26272B", "#33353A", "#E6E6E6", "#8E8E93", "#FF6B5E"])
    static let midnight = solid("midnight", "Midnight", ["#0D1321", "#1B2338", "#DFE6F5", "#5E9CFF", "#FF5C7A"])
    static let ocean = solid("ocean", "Ocean", ["#0F3446", "#17485F", "#E3F4FB", "#4FD1E8", "#FF8A65"])
    static let forest = solid("forest", "Forest", ["#1C2B22", "#26392D", "#E5EFE6", "#6FCF7F", "#FF7A59"])
    static let clay = solid("clay", "Clay", ["#3A2A22", "#4B372C", "#F6E9DE", "#E0915A", "#FF5D4D"])
    static let sunset = solid("sunset", "Sunset", ["#3B1F2B", "#4F2A3A", "#FDE8EE", "#FF9F43", "#FF4D6D"])
    static let grape = solid("grape", "Grape", ["#2A1F3D", "#382A52", "#EFE7FB", "#B48CFF", "#FF5C8A"])
    static let paper = solid("paper", "Paper", ["#F4F1EA", "#FFFFFF", "#2A2723", "#C2410C", "#D92D20"])
    static let mint = solid("mint", "Mint", ["#E9F5EF", "#FFFFFF", "#1F3329", "#0F9D6B", "#E5484D"])
    static let highcontrast = solid("highcontrast", "High Contrast", ["#000000", "#141414", "#FFFFFF", "#FFD60A", "#FF453A"])

    static let builtIns = [system, graphite, midnight, ocean, forest, clay, sunset, grape, paper, mint, highcontrast]
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var customThemes: [PerchTheme]
    @Published private(set) var selectedID: String

    private var prefs: PerchPrefs
    private let themeDataWriter: (Data?) -> Void
    private var pendingSave: Task<Void, Never>?
    private static let builtInIDs = Set(PerchTheme.builtIns.map(\.id))
    private static let maxCustomThemes = 20

    init(prefs: PerchPrefs, themeDataWriter: ((Data?) -> Void)? = nil) {
        self.prefs = prefs
        self.themeDataWriter = themeDataWriter ?? { prefs.defaults.set($0, forKey: "customThemes") }
        let customs = Self.readThemes(prefs.customThemesData)
        customThemes = customs
        let requested = prefs.themeSelected
        selectedID = (PerchTheme.builtIns + customs).contains { $0.id == requested } ? requested : "system"
    }

    var allThemes: [PerchTheme] { PerchTheme.builtIns + customThemes }
    var current: PerchTheme { theme(id: selectedID) ?? .system }
    var canAddCustom: Bool { customThemes.count < Self.maxCustomThemes }

    func theme(id: String) -> PerchTheme? { allThemes.first { $0.id == id } }

    func select(_ id: String) { select(id, persist: true) }
    func select(_ id: String, persist: Bool) {
        flushPendingSave()
        let clean = theme(id: id)?.id ?? "system"
        guard selectedID != clean else { return }
        selectedID = clean
        if persist { prefs.themeSelected = clean }
    }

    @discardableResult
    func duplicate(from theme: PerchTheme) -> PerchTheme? {
        flushPendingSave()
        guard canAddCustom else { return nil }
        var copy = theme
        copy.id = "custom-\(UUID().uuidString.lowercased())"
        copy.name = Self.cleanName("\(theme.name) Copy")
        customThemes = Self.sanitize(customThemes + [copy])
        persistThemes()
        select(copy.id)
        return customThemes.first { $0.id == copy.id } ?? copy
    }

    @discardableResult
    func newTheme() -> PerchTheme? { duplicate(from: current) }

    func update(_ theme: PerchTheme, persist: Bool = true) {
        guard let index = customThemes.firstIndex(where: { $0.id == theme.id }) else { return }
        var changed = theme
        changed.name = Self.cleanName(changed.name)
        var next = customThemes
        next[index] = changed
        let clean = Self.sanitize(next)
        guard clean != customThemes else { return }
        customThemes = clean
        if persist { scheduleThemesSave() }
        if self.theme(id: selectedID) == nil { select("system") }
    }

    func delete(id: String) {
        guard !Self.builtInIDs.contains(id), customThemes.contains(where: { $0.id == id }) else { return }
        flushPendingSave()
        customThemes.removeAll { $0.id == id }
        persistThemes()
        if selectedID == id { select("system") }
    }

    func flushPendingSave() {
        guard pendingSave != nil else { return }
        cancelPendingSave()
        writeThemes()
    }

    private func scheduleThemesSave() {
        cancelPendingSave()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.flushPendingSave()
        }
    }

    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    private func persistThemes() {
        cancelPendingSave()
        writeThemes()
    }

    private func writeThemes() {
        customThemes = Self.sanitize(customThemes)
        themeDataWriter(try? JSONEncoder().encode(customThemes))
    }

    private static func readThemes(_ data: Data?) -> [PerchTheme] {
        guard let data,
              let values = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        let decoded = values.compactMap { value -> PerchTheme? in
            guard JSONSerialization.isValidJSONObject(value),
                  let item = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(PerchTheme.self, from: item)
        }
        return sanitize(decoded)
    }

    private static func sanitize(_ themes: [PerchTheme]) -> [PerchTheme] {
        var ids = Set<String>()
        var result: [PerchTheme] = []
        for var theme in themes {
            guard result.count < maxCustomThemes,
                  !builtInIDs.contains(theme.id), !ids.contains(theme.id), validCustomID(theme.id),
                  [theme.background, theme.card, theme.text, theme.accent, theme.collecting].allSatisfy(\.isValid)
            else { continue }
            theme.name = cleanName(theme.name)
            ids.insert(theme.id)
            result.append(theme)
        }
        return result
    }

    private static func validCustomID(_ id: String) -> Bool {
        guard id.hasPrefix("custom-") else { return false }
        return UUID(uuidString: String(id.dropFirst("custom-".count))) != nil
    }

    private static func cleanName(_ name: String) -> String {
        let withoutControls = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(withoutControls)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Custom" : String(trimmed.prefix(40))
    }
}

/// Keeps a hosting root's SwiftUI color scheme bound to the selected theme instead of capturing the
/// selection once when its NSHostingView/NSHostingController is created.
@MainActor
struct ThemedHostingRoot<Content: View>: View {
    @ObservedObject var themes: ThemeStore
    private let content: Content

    init(themes: ThemeStore, @ViewBuilder content: () -> Content) {
        self.themes = themes
        self.content = content()
    }

    var body: some View {
        content
            .environmentObject(themes)
            .preferredColorScheme(themes.current.isSystem ? nil : (themes.current.isLight ? .light : .dark))
    }
}
