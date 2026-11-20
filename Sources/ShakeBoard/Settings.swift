//
//  Settings.swift
//  ShakeBoard -- the Settings window (opened from the gear in the strip, Command-comma in the strip, and by
//  relaunching ShakeBoard from Spotlight / Finder / the Dock -- ShakeBoard has no menu-bar icon).
//
//    PerchPrefs            typed, sanitized wrapper over ShakeBoard's prefs suite (keys kept from earlier builds)
//    SettingsAlerts        every failure line (once status-menu lines), by section; any
//                          failure lights the warning dot on the strip's gear
//    ShortcutRecorderLogic what a key press means while recording the stack shortcut
//    SettingsModel         the window's observable state + the actions AppDelegate wires in
//    SettingsWindowController  a plain AppKit NSWindow hosting SwiftUI. NOT the SwiftUI `Settings` scene /
//                          openSettings (unreliable from an agent app). ShakeBoard is `.regular` (Dock icon, menu
//                          bar, real activation) ONLY while this window is open; closing it returns to
//                          `.accessory` and re-activates the app you were in. The strip's no-focus-steal rules
//                          are untouched: opening Settings is an explicit click, and the strip is dismissed
//                          first.
//

import AppKit
import SwiftUI
import Combine
import Carbon
import UniformTypeIdentifiers

// MARK: - Prefs

struct PerchPrefs {
    let defaults: UserDefaults

    static let passwordsBundleID = "com.apple.Passwords"

    static let countChoices = [50, 100, 200, 500]
    static let dayChoices = [1, 7, 30]
    static let sensitivities: [(label: String, value: Double)] = [("Tight", 0.05), ("Medium", 0.15), ("Loose", 0.30)]
    static let defaultCount = 200, defaultDays = 7, defaultVariance = 0.15

    var themeSelected: String {
        get { defaults.string(forKey: "themeSelected") ?? "system" }
        set { defaults.set(newValue, forKey: "themeSelected") }
    }
    var customThemesData: Data? {
        get { defaults.data(forKey: "customThemes") }
        set { defaults.set(newValue, forKey: "customThemes") }
    }
    var showRenameWelcome: Bool {
        get { defaults.bool(forKey: PerchMigration.welcomeKey) }
        set { defaults.set(newValue, forKey: PerchMigration.welcomeKey) }
    }

    var addImagesToShelf: Bool {
        get { defaults.object(forKey: "addImagesToShelf") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "addImagesToShelf") }
    }
    // Reveal the strip when a copied image (incl. a copied screenshot) lands on the shelf. Off: it still lands.
    var showOnImageCopy: Bool {
        get { defaults.object(forKey: "showOnImageCopy") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showOnImageCopy") }
    }
    var shakeToShow: Bool {
        get { defaults.object(forKey: "shakeToShow") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "shakeToShow") }
    }
    var capturePaused: Bool {
        get { defaults.object(forKey: "capturePaused") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "capturePaused") }
    }
    var recognizeTextInImages: Bool {
        get { defaults.object(forKey: "recognizeTextInImages") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "recognizeTextInImages") }
    }
    var debugShakeLog: Bool {
        get { defaults.object(forKey: "debugShakeLog") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "debugShakeLog") }
    }
    var reduceOnDrag: Bool {
        get { defaults.object(forKey: "reduceOnDrag") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "reduceOnDrag") }
    }
    var historyMaxCount: Int {
        get {
            let v = defaults.object(forKey: "historyMaxCount") as? Int ?? Self.defaultCount
            return Self.countChoices.contains(v) ? v : Self.defaultCount
        }
        set { if Self.countChoices.contains(newValue) { defaults.set(newValue, forKey: "historyMaxCount") } }
    }
    var historyMaxDays: Int {
        get {
            let v = defaults.object(forKey: "historyMaxDays") as? Int ?? Self.defaultDays
            return Self.dayChoices.contains(v) ? v : Self.defaultDays
        }
        set { if Self.dayChoices.contains(newValue) { defaults.set(newValue, forKey: "historyMaxDays") } }
    }
    var historyMaxAge: TimeInterval { TimeInterval(historyMaxDays) * 24 * 3600 }
    var shakeVariance: Double {
        get {
            let v = defaults.object(forKey: "shakeVariance") as? Double ?? Self.defaultVariance
            return Self.sensitivities.contains { abs($0.value - v) < 0.001 } ? v : Self.defaultVariance
        }
        set {
            if Self.sensitivities.contains(where: { abs($0.value - newValue) < 0.001 }) {
                defaults.set(newValue, forKey: "shakeVariance")
            }
        }
    }
    // Bundle IDs shown in Settings > Clipboard. Apple Passwords is the initial default and remains removable.
    var ignoredApps: [String] {
        get {
            guard let stored = defaults.array(forKey: "ignoredApps") else { return [Self.passwordsBundleID] }
            return Self.sanitize(stored.compactMap { $0 as? String })
        }
        set { defaults.set(Self.sanitize(newValue), forKey: "ignoredApps") }
    }
    mutating func seedPasswordsIgnoredAppIfNeeded() {
        guard !defaults.bool(forKey: "ignoredAppsPasswordsSeeded") else { return }
        if defaults.object(forKey: "ignoredApps") != nil, !ignoredApps.contains(Self.passwordsBundleID) {
            ignoredApps.append(Self.passwordsBundleID)
        }
        defaults.set(true, forKey: "ignoredAppsPasswordsSeeded")
    }
    static func sanitize(_ ids: [String]) -> [String] {
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        let clean = ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains(".") && $0.unicodeScalars.allSatisfy(ok.contains) && $0.count <= 255 }
        return Array(Set(clean)).sorted()
    }
}

enum SystemSettingsLink {
    case accessibility, loginItems, keyboardShortcuts, pasteboard

    var url: URL? {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .loginItems:
            return URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        case .keyboardShortcuts:
            return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts")
        case .pasteboard:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard")
        }
    }

    static func open(_ link: SystemSettingsLink) {
        if let url = link.url { NSWorkspace.shared.open(url) }
    }
}

enum PasteboardAccessStatus: Equatable {
    case notRequested, ask, alwaysAllow, alwaysDeny, checkInSystemSettings

    static func current() -> PasteboardAccessStatus {
        guard #available(macOS 15.4, *) else { return .checkInSystemSettings }
        switch NSPasteboard.general.accessBehavior {
        case .default: return .notRequested
        case .ask: return .ask
        case .alwaysAllow: return .alwaysAllow
        case .alwaysDeny: return .alwaysDeny
        @unknown default: return .checkInSystemSettings
        }
    }

    var label: String {
        switch self {
        case .notRequested: return "Not requested yet"
        case .ask: return "Ask"
        case .alwaysAllow: return "Always Allow"
        case .alwaysDeny: return "Denied"
        case .checkInSystemSettings: return "Check in System Settings"
        }
    }

    var isGranted: Bool { self == .alwaysAllow }
}

// MARK: - Alerts (the old status-menu lines)

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, shortcuts, clipboard, shelf, privacy, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .clipboard: return "Clipboard"
        case .shelf: return "Shelf & Shake"
        case .privacy: return "Privacy & AI"
        case .about: return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .shortcuts: return "keyboard"
        case .clipboard: return "doc.on.clipboard"
        case .shelf: return "tray"
        case .privacy: return "hand.raised"
        case .about: return "info.circle"
        }
    }
}

struct SettingsAlert: Identifiable, Equatable {
    enum Severity: Equatable { case failure, notice }
    enum Action: Equatable { case openAccessibility }
    let id: String
    let section: SettingsSection
    let text: String
    var severity: Severity = .failure
    var action: Action? = nil
}

enum SettingsAlerts {
    struct Inputs: Equatable {
        var accessibilityTrusted = true
        var shelfSaveFailed = false
        var addFailures = 0
        var hotKeyFailures: [String] = []
        var historyClearFailed = false
        var historyDegraded = false
        var historySaveFailed = false
        var pinsSaveFailed = false
        var pinboardsSetAside: String? = nil
        var pinboardsReadOnly = false
        var stacksSaveFailed = false
        var capturePaused = false
        var migrationFailure: PerchMigration.Failure? = nil
        var migrationLegacyLeftBehind: URL? = nil
        var loginItemError: String? = nil
        var aiBridgeError: String? = nil      // only reported while AI access is on
    }

    static func compute(_ s: Inputs) -> [SettingsAlert] {
        var out: [SettingsAlert] = []
        if !s.accessibilityTrusted {
            out.append(.init(id: "ax", section: .general,
                             text: "Accessibility is off for ShakeBoard, so shake-to-show doesn't work.",
                             action: .openAccessibility))
        }
        if let failure = s.migrationFailure {
            let text: String
            switch failure {
            case .oldAppStillRunning:
                text = "Quit the old Perch app, then relaunch ShakeBoard to finish moving your data."
            case .refused, .operation:
                text = "ShakeBoard couldn't move your data from the old Perch folder, so it's using it in place. It will try again next launch."
            }
            out.append(.init(
                id: "perch-migration",
                section: .general,
                text: text
            ))
        }
        if let legacy = s.migrationLegacyLeftBehind {
            out.append(.init(
                id: "perch-data-left-behind",
                section: .general,
                text: "Found older Perch data at \(legacy.path). It was not merged into ShakeBoard."
            ))
        }
        if let e = s.loginItemError {
            out.append(.init(id: "login", section: .general, text: "Launch at Login couldn't change: \(e)"))
        }
        for (i, f) in s.hotKeyFailures.enumerated() {
            out.append(.init(id: "hotkey\(i)", section: .shortcuts, text: "Shortcut unavailable: \(f)"))
        }
        if s.historyClearFailed {
            out.append(.init(id: "clear", section: .clipboard,
                             text: "Couldn't fully clear history -- check ShakeBoard's Clips folder."))
        } else if s.historyDegraded {
            out.append(.init(id: "degraded", section: .clipboard,
                             text: "History paused -- damaged history couldn't be set aside. Clear History resets it."))
        }
        if s.historySaveFailed {
            out.append(.init(id: "histsave", section: .clipboard, text: "History couldn't save -- check disk space."))
        }
        if s.pinsSaveFailed {
            out.append(.init(id: "pins", section: .clipboard, text: "Pins couldn't save -- check disk space."))
        }
        if s.pinboardsReadOnly {
            out.append(.init(id: "pinboards-readonly", section: .clipboard,
                             text: "Pinboards file is unreadable and couldn't be set aside -- boards are read-only and copies are protected."))
        } else if let name = s.pinboardsSetAside {
            out.append(.init(id: "pinboards-set-aside", section: .clipboard,
                             text: "Pinboards file was unreadable and set aside (\(name)). Copies are protected until you restart."))
        }
        if s.stacksSaveFailed {
            out.append(.init(id: "stacks", section: .clipboard,
                             text: "Paste stacks couldn't save -- check disk space and ShakeBoard's stacks.json."))
        }
        if s.capturePaused {
            out.append(.init(id: "paused", section: .clipboard,
                             text: "Clipboard history is paused -- new copies aren't saved.", severity: .notice))
        }
        if let e = s.aiBridgeError {
            out.append(.init(id: "aibridge", section: .privacy, text: e))
        }
        if s.shelfSaveFailed {
            out.append(.init(id: "shelfsave", section: .shelf, text: "Shelf couldn't save -- check disk space."))
        }
        if s.addFailures > 0 {
            let n = s.addFailures
            out.append(.init(id: "add", section: .shelf, text: "Couldn't add \(n) item\(n == 1 ? "" : "s") to the shelf."))
        }
        return out
    }

    // The gear's warning dot: real failures only (a pause the user chose is shown, but isn't a warning).
    static func needsAttention(_ alerts: [SettingsAlert]) -> Bool { alerts.contains { $0.severity == .failure } }
}

// MARK: - Shortcut recording

extension HotKeyCombo {
    init(keyCode: UInt16, cocoaFlags: NSEvent.ModifierFlags) {
        var m: UInt32 = 0
        if cocoaFlags.contains(.command) { m |= UInt32(cmdKey) }
        if cocoaFlags.contains(.shift) { m |= UInt32(shiftKey) }
        if cocoaFlags.contains(.option) { m |= UInt32(optionKey) }
        if cocoaFlags.contains(.control) { m |= UInt32(controlKey) }
        self.init(keyCode: UInt32(keyCode), modifiers: m)
    }
}

enum ShortcutRecorderLogic {
    enum Verdict: Equatable { case accept(HotKeyCombo), reject(String), cancel, clear, keepWaiting }

    private static let modifierKeys: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]

    static func verdict(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Verdict {
        if modifierKeys.contains(Int(keyCode)) { return .keepWaiting }
        let mods = flags.intersection([.command, .shift, .option, .control])
        if mods.isEmpty && keyCode == UInt16(kVK_Escape) { return .cancel }
        if mods.isEmpty && (keyCode == UInt16(kVK_Delete) || keyCode == UInt16(kVK_ForwardDelete)) { return .clear }
        return verdict(for: HotKeyCombo(keyCode: keyCode, cocoaFlags: flags))
    }

    static func verdict(for c: HotKeyCombo) -> Verdict {
        if c.isAllowedForStack { return .accept(c) }
        if c.modifiers & UInt32(cmdKey | optionKey | controlKey) == 0 {
            return .reject("Use Command, Control or Option with a key.")
        }
        if c == HotKeyCombo.toggleStrip { return .reject("Command-Space already shows ShakeBoard -- pick another.") }
        if c.modifiers & UInt32(cmdKey) != 0, [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X].contains(Int(c.keyCode)) {
            return .reject("\(c.displayName) is copy, paste or cut in every app -- pick another.")
        }
        return .reject("\(c.displayName) is a standard shortcut in every app -- pick another.")
    }
}

// MARK: - Model

@MainActor
final class SettingsModel: ObservableObject {
    enum Calibration: Equatable { case idle, recording(swings: Int), done(swings: Int), failed }

    // Everything the window can do, wired by AppDelegate (so the model stays testable).
    struct Actions {
        var prefsChanged: () -> Void = {}
        var setLaunchAtLogin: (Bool) -> Void = { _ in }
        var launchAtLoginEnabled: () -> Bool = { false }
        var accessibilityTrusted: () -> Bool = { true }
        var pasteboardAccessStatus: () -> PasteboardAccessStatus = { .checkInSystemSettings }
        var openAccessibility: () -> Void = {}
        var stackShortcut: () -> HotKeyCombo? = { nil }
        var setStackShortcut: (HotKeyCombo?) -> Bool = { _ in false }
        var stackShortcutFailed: () -> Bool = { false }
        var stripShortcutFailed: () -> Bool = { false }
        var suspendStackShortcut: (Bool) -> Void = { _ in }
        var calibrate: () -> Void = {}
        var cancelCalibration: () -> Void = {}
        var clearHistory: () -> Void = {}
        var clearShelf: () -> Void = {}
        var counts: () -> (history: Int, pinned: Int, shelf: Int, owned: Int) = { (0, 0, 0, 0) }
        var quit: () -> Void = {}
        // Privacy & AI
        var aiAuditEntries: () -> [AIAuditEntry] = { [] }
        var clearAIAudit: () -> Void = {}
        var aiHelperPath: () -> String = { "" }
        var connectAI: (AIConnectTarget, @escaping (String) -> Void) -> Void = { _, done in done("") }
        var isDevRun: () -> Bool = { false }
    }

    @Published var prefs: PerchPrefs
    // Leaving Shortcuts ends a recording (otherwise the saved stack shortcut would stay unregistered).
    @Published var section: SettingsSection = .general { didSet { if section != .shortcuts { stopRecording() } } }
    @Published private(set) var alerts: [SettingsAlert] = []
    @Published private(set) var launchAtLogin = false
    @Published private(set) var accessibilityTrusted = true
    @Published private(set) var pasteboardAccessStatus: PasteboardAccessStatus = .checkInSystemSettings
    @Published private(set) var stackShortcutName: String?
    @Published private(set) var recording = false
    @Published var recorderMessage: String?
    @Published var calibration: Calibration = .idle
    @Published private(set) var counts: (history: Int, pinned: Int, shelf: Int, owned: Int) = (0, 0, 0, 0)
    @Published private(set) var auditEntries: [AIAuditEntry] = []
    @Published var connectOutput: [AIConnectTarget: String] = [:]
    @Published private(set) var connecting: Set<AIConnectTarget> = []
    var actions = Actions()

    init(defaults: UserDefaults) { prefs = PerchPrefs(defaults: defaults) }

    var needsAttention: Bool { SettingsAlerts.needsAttention(alerts) }
    func alerts(in s: SettingsSection) -> [SettingsAlert] { alerts.filter { $0.section == s } }

    // Pull live state (cheap; called on open, on a timer while open, and whenever a failure flag moves).
    // `full` = the window is open: also re-read login item, shortcut and counts (skipped by the background
    // tick that only keeps the gear's warning dot current).
    func refresh(alertInputs: SettingsAlerts.Inputs, full: Bool = true) {
        let a = SettingsAlerts.compute(alertInputs)
        if a != alerts { alerts = a }
        if alertInputs.accessibilityTrusted != accessibilityTrusted { accessibilityTrusted = alertInputs.accessibilityTrusted }
        let pasteboard = actions.pasteboardAccessStatus()
        if pasteboard != pasteboardAccessStatus { pasteboardAccessStatus = pasteboard }
        guard full else { return }
        let login = actions.launchAtLoginEnabled()
        if login != launchAtLogin { launchAtLogin = login }
        let name = actions.stackShortcut()?.displayName
        if name != stackShortcutName { stackShortcutName = name }
        let c = actions.counts()
        if c != counts { counts = c }
        let log = actions.aiAuditEntries()
        if log != auditEntries { auditEntries = log }
    }

    // Privacy & AI
    func setAIConsent(_ key: String, _ allowed: Bool?, label: String? = nil) {
        update { p in
            var c = p.aiClients; c[key] = allowed; p.aiClients = c
            var l = p.aiClientLabels
            if allowed == nil { l[key] = nil } else if let label { l[key] = label }
            p.aiClientLabels = l
        }
    }
    func clearAIAudit() { actions.clearAIAudit(); auditEntries = actions.aiAuditEntries() }
    func connect(_ t: AIConnectTarget) {
        guard !connecting.contains(t) else { return }
        connecting.insert(t)
        connectOutput[t] = "Running\u{2026}"
        actions.connectAI(t) { [weak self] out in
            self?.connecting.remove(t)
            self?.connectOutput[t] = out
        }
    }
    func addAIHiddenApp(bundleID: String) { update { $0.aiHiddenApps = $0.aiHiddenApps + [bundleID] } }
    func removeAIHiddenApp(_ id: String) { update { $0.aiHiddenApps = $0.aiHiddenApps.filter { $0 != id } } }

    func update(_ change: (inout PerchPrefs) -> Void) {
        change(&prefs)
        actions.prefsChanged()
    }
    func binding<T>(_ kp: WritableKeyPath<PerchPrefs, T>) -> Binding<T> {
        Binding(get: { self.prefs[keyPath: kp] }, set: { v in self.update { $0[keyPath: kp] = v } })
    }

    func setLaunchAtLogin(_ on: Bool) { actions.setLaunchAtLogin(on); launchAtLogin = actions.launchAtLoginEnabled() }
    func dismissRenameWelcome() { update { $0.showRenameWelcome = false } }

    // Recording the stack shortcut. While recording, the current one is unregistered so it can be re-typed.
    func startRecording() {
        guard !recording else { return }
        recorderMessage = nil
        recording = true
        actions.suspendStackShortcut(true)
    }
    func stopRecording() {
        guard recording else { return }
        recording = false
        actions.suspendStackShortcut(false)
        stackShortcutName = actions.stackShortcut()?.displayName
        if actions.stackShortcutFailed(), let n = stackShortcutName {
            recorderMessage = "\(n) is taken by another app -- pick another."
        }
    }
    // Returns true when the key press was consumed by the recorder.
    @discardableResult
    func handleRecorderKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        guard recording else { return false }
        // Cmd-W / Cmd-Q keep closing and quitting: end the recording and let the event through.
        let mods = flags.intersection([.command, .shift, .option, .control])
        if mods == .command, keyCode == UInt16(kVK_ANSI_W) || keyCode == UInt16(kVK_ANSI_Q) {
            stopRecording(); return false
        }
        switch ShortcutRecorderLogic.verdict(keyCode: keyCode, flags: flags) {
        case .keepWaiting: break
        case .cancel: recorderMessage = nil; stopRecording()
        case .clear: _ = actions.setStackShortcut(nil); recorderMessage = nil; stopRecording()
        case .reject(let why): recorderMessage = why
        case .accept(let c):
            if actions.setStackShortcut(c) { recorderMessage = nil; stopRecording() }
            else { recorderMessage = "\(c.displayName) can't be used -- pick another." }
        }
        return true
    }
    func clearStackShortcut() {
        _ = actions.setStackShortcut(nil)
        recorderMessage = nil
        stackShortcutName = actions.stackShortcut()?.displayName
    }

    func addIgnoredApp(bundleID: String) { update { $0.ignoredApps = $0.ignoredApps + [bundleID] } }
    func removeIgnoredApp(_ id: String) { update { $0.ignoredApps = $0.ignoredApps.filter { $0 != id } } }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    let themes: ThemeStore
    private(set) var window: NSWindow?
    private var keyMonitor: Any?
    private var refreshTimer: Timer?
    private var previousApp: NSRunningApplication?
    private var activationObserver: Any?
    private var themeBag: AnyCancellable?
    var willShow: () -> Void = {}
    var refresh: () -> Void = {}

    init(model: SettingsModel, themes: ThemeStore, window: NSWindow? = nil) {
        self.model = model
        self.themes = themes
        self.window = window
        super.init()
        themeBag = themes.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                ThemeAppearance.apply(self.themes.current, to: self.window)
            }
        }
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func show(section: SettingsSection? = nil) {
        willShow()
        if let section { model.section = section }
        let w = window ?? makeWindow()
        window = w
        if !isOpen {
            let front = NSWorkspace.shared.frontmostApplication
            if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        }
        refresh()
        // A regular app only while Settings is open: Dock icon, menu bar (Edit menu for the text fields,
        // Cmd-W, Cmd-Q) and real activation so the window takes the keyboard.
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = Self.makeMainMenu()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        installKeyMonitor()
        // Track the app the user was most recently in while Settings is open, so closing returns there
        // (not to whichever app was in front when Settings first opened).
        if activationObserver == nil {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { self?.previousApp = app }
                }
            }
        }
        if refreshTimer == nil {
            let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        }
    }

    func close() { window?.performClose(nil) }

    // Clicking away from Settings ends a recording too.
    func windowDidResignKey(_ notification: Notification) { model.stopRecording() }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
        model.actions.cancelCalibration()
        themes.flushPendingSave()
        refreshTimer?.invalidate(); refreshTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        NSApp.setActivationPolicy(.accessory)
        // Hand the screen back to the app you were in. Never NSApp.hide(): that would also hide the strip and
        // the stack bar panels.
        let prev = previousApp
        previousApp = nil
        DispatchQueue.main.async {
            if let prev, !prev.isTerminated { prev.activate() }
        }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "ShakeBoard Settings"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: ThemedHostingRoot(themes: themes) {
            SettingsView(model: model)
        })
        ThemeAppearance.apply(themes.current, to: w)
        w.setContentSize(NSSize(width: 720, height: 500))
        w.center()
        w.setFrameAutosaveName("ShakeBoardSettings")
        w.delegate = self
        return w
    }

    private var calibrationMouseMovedEvents: Bool?
    func beginCalibrationMouseTracking() {
        guard calibrationMouseMovedEvents == nil, let window else { return }
        calibrationMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
    }
    func endCalibrationMouseTracking() {
        guard let prior = calibrationMouseMovedEvents else { return }
        window?.acceptsMouseMovedEvents = prior
        calibrationMouseMovedEvents = nil
    }

    // While recording, every key press in the Settings window goes to the recorder (Cmd-Q / Cmd-W too).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            return MainActor.assumeIsolated {
                self.model.handleRecorderKey(keyCode: e.keyCode, flags: e.modifierFlags) ? nil : e
            }
        }
    }

    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            host.submenu = m
            main.addItem(host)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; return i
        }
        sub("ShakeBoard", [item("About ShakeBoard", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
                      .separator(), item("Hide ShakeBoard", #selector(NSApplication.hide(_:)), "h"), .separator(),
                      item("Quit ShakeBoard", #selector(NSApplication.terminate(_:)), "q")])
        sub("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]),
                     .separator(),
                     item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                     item("Paste", #selector(NSText.paste(_:)), "v"),
                     item("Select All", #selector(NSText.selectAll(_:)), "a")])
        sub("Window", [item("Close", #selector(NSWindow.performClose(_:)), "w"),
                       item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        return main
    }

    // Dev-only (PERCH_DEBUG_SHOW=settings,snapshot): render each section to <dir>/settings-<section>.png.
    func snapshotSections(to dir: URL) {
        // Tall enough that long panes (Privacy & AI's client list and request log) fit in one image.
        if let w = window { w.setContentSize(NSSize(width: max(w.contentLayoutRect.width, 760), height: 1250)) }
        var sections = SettingsSection.allCases
        func next() {
            guard !sections.isEmpty else { return }
            model.section = sections.removeFirst()
            let name = model.section.rawValue
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let v = self?.window?.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("settings-\(name).png"))
                NSLog("ShakeBoard debug: settings snapshot \(name) written")
                next()
            }
        }
        next()
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @EnvironmentObject private var themes: ThemeStore

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.section.title).font(.system(size: 20, weight: .semibold))
                    if model.section == .general, model.prefs.showRenameWelcome {
                        RenameWelcomeBanner(model: model)
                    }
                    ForEach(model.alerts(in: model.section)) { AlertRow(alert: $0, model: model) }
                    detail
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 680, minHeight: 460)
        .tint(themes.current.isSystem ? nil : themes.current.accent.color)
        .foregroundStyle(themes.current.isSystem ? Color.primary : themes.current.text.color)
        .background(themes.current.isSystem ? Color.clear : themes.current.background.color)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { s in
                Button { model.section = s } label: {
                    HStack(spacing: 8) {
                        Image(systemName: s.symbol).frame(width: 18)
                        Text(s.title)
                        Spacer(minLength: 4)
                        if model.alerts(in: s).contains(where: { $0.severity == .failure }) {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                                .accessibilityLabel("Needs attention")
                        }
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(model.section == s ? Color.accentColor.opacity(0.18) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 40).padding(.horizontal, 10).padding(.bottom, 12)
        .frame(width: 190)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder private var detail: some View {
        switch model.section {
        case .general: GeneralPane(model: model)
        case .appearance: AppearancePane()
        case .shortcuts: ShortcutsPane(model: model)
        case .clipboard: ClipboardPane(model: model)
        case .shelf: ShelfPane(model: model)
        case .privacy: PrivacyPane(model: model)
        case .about: AboutPane(model: model)
        }
    }
}

private struct RenameWelcomeBanner: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Welcome to ShakeBoard -- formerly Perch. Your data and settings came with you. macOS treats ShakeBoard as a new app, so grant it access again:")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            permissionRow(
                title: "Accessibility",
                status: model.accessibilityTrusted ? "On" : "Off",
                granted: model.accessibilityTrusted,
                button: "Open Accessibility Settings",
                action: { model.actions.openAccessibility() }
            )
            permissionRow(
                title: "Paste from Other Apps",
                status: model.pasteboardAccessStatus.label,
                granted: model.pasteboardAccessStatus.isGranted,
                button: "Open Paste from Other Apps",
                action: { SystemSettingsLink.open(.pasteboard) }
            )
            HStack {
                Spacer()
                Button("Done") { model.dismissRenameWelcome() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.35)))
    }

    private func permissionRow(title: String, status: String, granted: Bool,
                               button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Text("\(title): \(status)")
            Spacer(minLength: 8)
            Button(button, action: action).controlSize(.small)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(status)")
    }
}

private struct AlertRow: View {
    let alert: SettingsAlert
    @ObservedObject var model: SettingsModel
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: alert.severity == .failure ? "exclamationmark.triangle.fill" : "pause.circle.fill")
                .foregroundStyle(alert.severity == .failure ? Color.orange : Color.secondary)
            Text(alert.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if alert.action == .openAccessibility {
                Button("Open Accessibility Settings") { model.actions.openAccessibility() }.controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill((alert.severity == .failure ? Color.orange : Color.secondary).opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder((alert.severity == .failure ? Color.orange : Color.secondary).opacity(0.35)))
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
        }
    }
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        SettingsGroup(title: "Startup") {
            HStack {
                Toggle("Launch ShakeBoard at login", isOn: Binding(get: { model.launchAtLogin },
                                                              set: { model.setLaunchAtLogin($0) }))
                Spacer()
                Button("Open Login Items Settings") { SystemSettingsLink.open(.loginItems) }.controlSize(.small)
            }
        }
        SettingsGroup(title: "Copied images") {
            Toggle("Put copied images on the shelf as files", isOn: model.binding(\.addImagesToShelf))
            Hint("Screenshots and copied images become shelf files you can drag anywhere. Off: they stay in Recent.")
            Toggle("Show ShakeBoard when an image is copied", isOn: model.binding(\.showOnImageCopy))
                .disabled(!model.prefs.addImagesToShelf)
            Hint("Off: copied images and screenshots still land on the shelf, but the strip doesn't pop up.")
        }
        SettingsGroup(title: "Permissions") {
            HStack {
                Image(systemName: model.accessibilityTrusted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(model.accessibilityTrusted ? Color.green : Color.orange)
                Text(model.accessibilityTrusted ? "Accessibility is on" : "Accessibility is off")
                Spacer()
                Button("Open Accessibility Settings") { model.actions.openAccessibility() }
            }
            Hint("ShakeBoard needs Accessibility to notice a shake and to paste into the app you were using.")
        }
    }
}

private struct AppearancePane: View {
    @EnvironmentObject private var themes: ThemeStore
    @State private var confirmDelete = false
    private let columns = [GridItem(.adaptive(minimum: 126), spacing: 10)]

    var body: some View {
        SettingsGroup(title: "Themes") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(themes.allThemes) { theme in
                    Button { themes.select(theme.id); confirmDelete = false } label: { tile(theme) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(theme.name) theme")
                        .accessibilityAddTraits(theme.id == themes.selectedID ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button("Duplicate") { _ = themes.duplicate(from: themes.current) }
                    Button("New Theme") { _ = themes.newTheme() }
                }
                .disabled(!themes.canAddCustom)
                Text("Up to 20 custom themes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        if !themes.current.isSystem && themes.current.id.hasPrefix("custom-") {
            editor(themes.current)
        }
    }

    private func tile(_ theme: PerchTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(theme.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            HStack(spacing: 5) {
                swatch(theme.card.color)
                swatch(theme.accent.color)
                swatch(theme.collecting.color)
            }
        }
        .foregroundStyle(theme.text.color)
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.background.color))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
            theme.id == themes.selectedID ? theme.accent.color : theme.text.color.opacity(0.12),
            lineWidth: theme.id == themes.selectedID ? 3 : 1))
        .shadow(color: theme.isSystem ? Color.black.opacity(0.18) : .clear, radius: 5, y: 2)
    }

    private func swatch(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 13, height: 13)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
    }

    private func editor(_ theme: PerchTheme) -> some View {
        let cardContrast = PerchTheme.contrastRatio(theme.text, theme.card)
        let accentContrast = PerchTheme.contrastRatio(theme.accent, theme.background)
        return SettingsGroup(title: "Edit custom theme") {
            TextField("Theme name", text: binding(theme, \.name))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 300)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    colorPicker("Background", theme, \.background)
                    colorPicker("Cards", theme, \.card)
                    colorPicker("Text", theme, \.text)
                    colorPicker("Accent", theme, \.accent)
                    colorPicker("Collecting", theme, \.collecting)
                }
                ThemePreview(theme: theme)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: "Text on cards: %.1f:1", cardContrast))
                if cardContrast < 4.5 { warning("Text may be hard to read") }
                Text(String(format: "Accent on background: %.1f:1", accentContrast))
                if accentContrast < 3 { warning("Accent may be hard to see") }
            }
            .font(.system(size: 11))
            if confirmDelete {
                HStack {
                    Text("Delete this custom theme?").font(.system(size: 11)).foregroundStyle(.orange)
                    Button("Confirm Delete", role: .destructive) { themes.delete(id: theme.id); confirmDelete = false }
                    Button("Cancel") { confirmDelete = false }
                }
            } else {
                Button("Delete", role: .destructive) { confirmDelete = true }
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
    }

    private func binding(_ theme: PerchTheme, _ keyPath: WritableKeyPath<PerchTheme, String>) -> Binding<String> {
        Binding(get: { themes.theme(id: theme.id)?[keyPath: keyPath] ?? "" }, set: { value in
            guard var changed = themes.theme(id: theme.id) else { return }
            changed[keyPath: keyPath] = value
            themes.update(changed)
        })
    }

    private func colorPicker(_ title: String, _ theme: PerchTheme,
                             _ keyPath: WritableKeyPath<PerchTheme, ThemeColor>) -> some View {
        ColorPicker(title, selection: Binding(get: {
            themes.theme(id: theme.id)?[keyPath: keyPath].color ?? .black
        }, set: { value in
            guard var changed = themes.theme(id: theme.id) else { return }
            changed[keyPath: keyPath] = ThemeColor(color: value)
            themes.update(changed)
        }), supportsOpacity: false)
        .frame(width: 190)
    }
}

private struct ThemePreview: View {
    let theme: PerchTheme
    var body: some View {
        HStack(spacing: 7) {
            VStack(spacing: 5) {
                previewCard(width: 70)
                previewCard(width: 54)
            }
            VStack(spacing: 1) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 17, weight: .semibold))
                Text("Stacks").font(.system(size: 6, weight: .semibold))
            }
            .foregroundStyle(theme.isSystem ? Color(nsColor: .selectedControlTextColor) : theme.onAccent.color)
            .frame(width: 29, height: 42)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.accent.color))
            .shadow(color: theme.accent.color.opacity(0.45), radius: 4, y: 2)
        }
        .padding(10)
        .frame(width: 150, height: 80)
        .background(RoundedRectangle(cornerRadius: 13).fill(theme.background.color))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(theme.text.color.opacity(0.12)))
    }
    private func previewCard(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5).fill(theme.card.color).frame(width: width, height: 18)
            .overlay(alignment: .leading) {
                Capsule().fill(theme.text.color.opacity(0.7)).frame(width: width * 0.55, height: 3).padding(.leading, 6)
            }
    }
}

private struct ShortcutsPane: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        SettingsGroup(title: "Global shortcuts") {
            HStack {
                Text("Show or hide ShakeBoard")
                Spacer()
                KeyCap(text: "\u{2318} Space")
            }
            HStack {
                Hint(model.actions.stripShortcutFailed()
                     ? "Command-Space is taken. Move Spotlight off Command-Space in Keyboard Shortcuts."
                     : "Move Spotlight off Command-Space in Keyboard Shortcuts.")
                Spacer()
                Button("Open Keyboard Shortcuts Settings") { SystemSettingsLink.open(.keyboardShortcuts) }
                    .controlSize(.small)
            }
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Turn the paste stack on or off")
                    Hint("Optional. The Stack button in the strip always works.")
                }
                Spacer()
                if model.recording {
                    KeyCap(text: "Type a shortcut\u{2026}", active: true)
                    Button("Cancel") { model.stopRecording() }
                } else {
                    KeyCap(text: model.stackShortcutName ?? "Not set", dim: model.stackShortcutName == nil)
                    Button(model.stackShortcutName == nil ? "Record" : "Change") { model.startRecording() }
                    if model.stackShortcutName != nil { Button("Clear") { model.clearStackShortcut() } }
                }
            }
            if let msg = model.recorderMessage {
                Text(msg).font(.system(size: 11)).foregroundStyle(.orange)
            } else if model.recording {
                Hint("Press keys with Command, Control or Option. Esc cancels, Delete clears.")
            }
        }
        SettingsGroup(title: "In the strip") {
            ForEach([("Return", "Paste"), ("\u{21E7} Return", "Paste as plain text"), ("1 - 9", "Paste that card"),
                     ("Space", "Preview"), ("\u{2318} E", "Edit"), ("\u{2318} T", "Transform"),
                     ("\u{2318} P", "Pin"), ("\u{2318} C", "Copy"), ("\u{2318} \u{232B}", "Delete"),
                     ("Esc", "Close")], id: \.0) { k, v in
                HStack { Text(v); Spacer(); KeyCap(text: k) }
            }
        }
    }
}

private struct KeyCap: View {
    let text: String
    var active = false
    var dim = false
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(dim ? Color.secondary : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor : Color.primary.opacity(0.15)))
    }
}

private struct ClipboardPane: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmClear = false
    var body: some View {
        SettingsGroup(title: "History") {
            Toggle("Save copies to history", isOn: Binding(get: { !model.prefs.capturePaused },
                                                           set: { v in model.update { $0.capturePaused = !v } }))
            HStack {
                Hint("If macOS blocks capture, allow Paste from other apps.")
                Spacer()
                Button("Open Paste Privacy Settings") { SystemSettingsLink.open(.pasteboard) }.controlSize(.small)
            }
            HStack {
                Text("Keep up to")
                Picker("", selection: model.binding(\.historyMaxCount)) {
                    ForEach(PerchPrefs.countChoices, id: \.self) { Text("\($0) copies").tag($0) }
                }.labelsHidden().frame(width: 120)
                Text("for")
                Picker("", selection: model.binding(\.historyMaxDays)) {
                    ForEach(PerchPrefs.dayChoices, id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                }.labelsHidden().frame(width: 100)
            }
            Hint("Pinned cards never expire. \(model.counts.history) in history now, \(model.counts.pinned) pinned.")
            Toggle("Recognize text in images", isOn: model.binding(\.recognizeTextInImages))
            Hint("Finds text in copied images on this Mac so you can search and copy it. Nothing leaves your Mac. Turning this off deletes recognized text.")
            HStack {
                Button("Clear History\u{2026}") { confirmClear = true }
                Spacer()
            }
        }
        .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.actions.clearHistory() }
        } message: {
            Text(model.counts.pinned > 0 ? "Pinned cards are kept. This can't be undone." : "This can't be undone.")
        }
        SettingsGroup(title: "Never save copies from") {
            if model.prefs.ignoredApps.isEmpty {
                Hint("No apps added.")
            } else {
                ForEach(model.prefs.ignoredApps, id: \.self) { id in
                    HStack {
                        AppLabel(bundleID: id)
                        Spacer()
                        Button { model.removeIgnoredApp(id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help("Remove")
                    }
                }
            }
            Button("Add App\u{2026}") { pickApp() }
            Hint("Always skipped: password managers (1Password, Bitwarden, Keychain Access, Passwords and others), "
                 + "copies marked secret, and anything copied while a password field has the keyboard.")
        }
    }

    private func pickApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        p.prompt = "Ignore"
        guard p.runModal() == .OK else { return }
        for url in p.urls { if let id = Bundle(url: url)?.bundleIdentifier { model.addIgnoredApp(bundleID: id) } }
    }
}

private struct AppLabel: View {
    let bundleID: String
    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "app.dashed").frame(width: 18)
                Text(bundleID)
            }
        }
    }
}

private struct ShelfPane: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmClear = false
    var body: some View {
        SettingsGroup(title: "Shake") {
            Toggle("Shake the pointer to show the strip", isOn: model.binding(\.shakeToShow))
            if !model.accessibilityTrusted {
                HStack {
                    Label("Shake needs Accessibility permission.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Spacer()
                    Button("Open Accessibility Settings") { SystemSettingsLink.open(.accessibility) }
                        .controlSize(.small)
                }
            }
            HStack {
                Text("Sensitivity")
                Picker("", selection: model.binding(\.shakeVariance)) {
                    ForEach(PerchPrefs.sensitivities, id: \.value) { Text($0.label).tag($0.value) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            HStack(spacing: 10) {
                Button(isRecording ? "Cancel Calibration" : "Calibrate Shake") {
                    if isRecording { model.actions.cancelCalibration() } else { model.actions.calibrate() }
                }
                calibrationText
            }
            Hint("Calibrate records 2.5 seconds of your own shake and tunes detection to it.")
        }
        SettingsGroup(title: "Shelf") {
            Hint("\(model.counts.shelf) file\(model.counts.shelf == 1 ? "" : "s") on the shelf.")
            Toggle("Shrink images when dragging out (~\(DragImageOptimizer.claudeMaxEdge) px)",
                   isOn: model.binding(\.reduceOnDrag))
            Button("Clear Shelf\u{2026}") { confirmClear = true }.disabled(model.counts.shelf == 0)
        }
        .confirmationDialog("Clear the shelf?", isPresented: $confirmClear) {
            Button("Clear Shelf", role: .destructive) { model.actions.clearShelf() }
        } message: {
            Text("Images ShakeBoard saved from the clipboard are deleted. Files you dragged in stay where they are.")
        }
    }
    private var isRecording: Bool { if case .recording = model.calibration { return true }; return false }
    @ViewBuilder private var calibrationText: some View {
        switch model.calibration {
        case .idle: EmptyView()
        case .recording(let n): Text("\(n) swing\(n == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(.secondary)
        case .done(let n):
            Label("Calibrated to your shake (\(n) swings)", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(.green)
        case .failed:
            Label("No shake noticed -- try again, moving side to side quickly", systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(.orange)
        }
    }
}

private struct PrivacyPane: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmClearLog = false
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .medium; return f
    }()

    var body: some View {
        SettingsGroup(title: "Let Claude and Codex read your history") {
            Toggle("Allow AI tools to search and read clipboard history", isOn: model.binding(\.aiAccessEnabled))
            Toggle("Also hide email addresses and phone numbers", isOn: model.binding(\.aiRedactContacts))
                .disabled(!model.prefs.aiAccessEnabled)
            Toggle("Let search see shelf file names (never file contents)", isOn: model.binding(\.aiIncludeShelfNames))
                .disabled(!model.prefs.aiAccessEnabled)
            Hint("Read-only, on this Mac only. Each app asks once. ShakeBoard replaces passwords, keys, tokens, card numbers "
                 + "and other secrets it recognizes with [REDACTED] -- best effort: it can miss unusual formats, so hide "
                 + "sensitive apps or cards below. Every request is logged. Off: nothing is shared.")
        }
        SettingsGroup(title: "Connect") {
            ForEach(AIConnectTarget.allCases) { t in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(t.title)
                        Spacer()
                        Button("Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(t.command(helper: model.actions.aiHelperPath()), forType: .string)
                        }
                        Button(model.connecting.contains(t) ? "Connecting\u{2026}" : "Connect") { model.connect(t) }
                            .disabled(model.connecting.contains(t) || model.actions.isDevRun())
                    }
                    Text(t.command(helper: model.actions.aiHelperPath()))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    if let out = model.connectOutput[t], !out.isEmpty {
                        Text(out).font(.system(size: 10, design: .monospaced))
                            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                            .textSelection(.enabled)
                    }
                }
            }
            Hint("Upgrading from Perch? Remove the old connection with: claude mcp remove perch (and codex mcp remove perch)")
            if model.actions.isDevRun() { Hint("Connect is off in a dev run (it would register this build).") }
        }
        SettingsGroup(title: "Apps allowed to connect") {
            let clients = model.prefs.aiClients.sorted { $0.key < $1.key }
            if clients.isEmpty {
                Hint("None yet. The first time an app connects, ShakeBoard asks you.")
            } else {
                ForEach(clients, id: \.key) { id, allowed in
                    HStack {
                        Image(systemName: allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(allowed ? Color.green : Color.secondary)
                        Text(model.prefs.aiClientLabels[id] ?? id).lineLimit(2).truncationMode(.middle)
                        Spacer()
                        Button(allowed ? "Revoke" : "Allow") { model.setAIConsent(id, !allowed) }
                        Button { model.setAIConsent(id, nil) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help("Forget (it asks again next time)")
                    }
                }
            }
        }
        SettingsGroup(title: "Never show AI copies from") {
            if !model.prefs.aiHiddenApps.isEmpty {
                ForEach(model.prefs.aiHiddenApps, id: \.self) { id in
                    HStack {
                        AppLabel(bundleID: id)
                        Spacer()
                        Button { model.removeAIHiddenApp(id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help("Remove")
                    }
                }
            }
            Button("Add App\u{2026}") { pickApp() }
            Hint("Always hidden: password managers. Right-click a card in the strip > Hide from AI to hide one copy.")
        }
        SettingsGroup(title: "Request log") {
            if model.auditEntries.isEmpty {
                Hint("No requests yet. The log records time, app, tool and counts -- never what was copied or searched for.")
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.auditEntries.prefix(50)) { e in
                        HStack(spacing: 8) {
                            Text(Self.timeFmt.string(from: e.time)).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
                            Text(AIClientID.displayName(e.client)).frame(width: 90, alignment: .leading)
                            Text(e.tool).font(.system(size: 11, design: .monospaced)).frame(width: 100, alignment: .leading)
                            Text(e.outcome == "ok" ? "\(e.items) item\(e.items == 1 ? "" : "s")" : e.outcome.replacingOccurrences(of: "_", with: " "))
                                .foregroundStyle(e.outcome == "ok" ? Color.primary : Color.orange)
                            if e.redactions > 0 { Text("\(e.redactions) redacted").foregroundStyle(.secondary) }
                            Spacer()
                        }
                        .font(.system(size: 11))
                    }
                }
                Button("Clear Log\u{2026}") { confirmClearLog = true }
            }
        }
        .confirmationDialog("Clear the request log?", isPresented: $confirmClearLog) {
            Button("Clear Log", role: .destructive) { model.clearAIAudit() }
        }
    }

    private func pickApp() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.application]
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowsMultipleSelection = true
        p.prompt = "Hide from AI"
        guard p.runModal() == .OK else { return }
        for url in p.urls { if let id = Bundle(url: url)?.bundleIdentifier { model.addAIHiddenApp(bundleID: id) } }
    }
}

private struct AboutPane: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text("ShakeBoard").font(.system(size: 18, weight: .semibold))
                Text("Version \(Self.version)").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Formerly Perch").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("A local shelf for files and everything you copy. Nothing leaves your Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        SettingsGroup(title: "Data") {
            HStack {
                Text(PerchPaths.base.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([PerchPaths.base]) }
            }
        }
        Button("Quit ShakeBoard") { model.actions.quit() }.keyboardShortcut("q", modifiers: .command)
    }
    static var version: String {
        let i = Bundle.main.infoDictionary
        let v = i?["CFBundleShortVersionString"] as? String ?? "?"
        let b = i?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
