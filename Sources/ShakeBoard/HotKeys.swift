//
//  HotKeys.swift
//  ShakeBoard -- global shortcuts (Carbon only).
//
//    Command-Space        show/hide the strip (the only default shortcut)
//    stack shortcut       toggle the paste stack -- UNSET by default; stored in prefs ("stackShortcut"),
//                         recorded in Settings > Shortcuts. The Stack button in the strip always works.
//
//  Nothing else is ever registered. In particular ShakeBoard never registers Command-C / Command-V (or any other
//  plain Command-letter editing key): a global Carbon hotkey swallows the keystroke system-wide, which would
//  break copy/paste and the paste stack's Command-V watcher. `HotKeyCombo.isAllowedForStack` enforces that
//  for the user-recordable shortcut too.
//

import Foundation
import Carbon

// A live hotkey registration; releasing it unregisters (GlobalHotKey's deinit does).
protocol HotKeyRegistration: AnyObject {}
extension GlobalHotKey: HotKeyRegistration {}

protocol HotKeyRegistrar {
    // nil = the combination is taken (another app or the system owns it).
    @MainActor func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> HotKeyRegistration?
}

struct CarbonHotKeyRegistrar: HotKeyRegistrar {
    @MainActor func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> HotKeyRegistration? {
        GlobalHotKey(keyCode: keyCode, modifiers: modifiers, action: action)
    }
}

// A key plus Carbon modifier bits (cmdKey / shiftKey / optionKey / controlKey).
struct HotKeyCombo: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let modifierMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)
    static let toggleStrip = HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    // Plain Command + these keys are everyday editing / app / system shortcuts; registering one globally
    // would steal it from every app.
    private static let reservedWithCommand: Set<Int> = [
        kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_A, kVK_ANSI_Z, kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H,
        kVK_ANSI_M, kVK_ANSI_S, kVK_ANSI_F, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_T, kVK_Tab, kVK_Space,
        kVK_Escape, kVK_ANSI_Grave,
    ]

    // A usable stack shortcut: has Command, Control or Option (Shift alone isn't a shortcut), isn't the strip
    // shortcut, and isn't a plain Command editing key (Command-C/V/X/... -- see the header).
    var isAllowedForStack: Bool {
        let core = modifiers & UInt32(cmdKey | optionKey | controlKey)
        guard core != 0 else { return false }
        guard self != Self.toggleStrip else { return false }
        // Copy / paste / cut with Command plus ANY other modifiers (Cmd-Shift-V "paste plain", Cmd-Opt-V
        // "paste and match style", ...) are app shortcuts people use every day.
        if modifiers & UInt32(cmdKey) != 0,
           [kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X].contains(Int(keyCode)) { return false }
        if modifiers == UInt32(cmdKey), Self.reservedWithCommand.contains(Int(keyCode)) { return false }
        if modifiers == UInt32(cmdKey | shiftKey), keyCode == UInt32(kVK_ANSI_Z) { return false }   // redo
        return true
    }

    var displayName: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "\u{2303}" }
        if modifiers & UInt32(optionKey) != 0 { s += "\u{2325}" }
        if modifiers & UInt32(shiftKey) != 0 { s += "\u{21E7}" }
        if modifiers & UInt32(cmdKey) != 0 { s += "\u{2318}" }
        return s + Self.keyName(keyCode)
    }

    private static let names: [Int: String] = {
        var m: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc", kVK_ANSI_Grave: "`",
            kVK_ANSI_Period: ".", kVK_ANSI_Comma: ",", kVK_ANSI_Slash: "/", kVK_ANSI_Semicolon: ";",
            kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Minus: "-",
            kVK_ANSI_Equal: "=", kVK_ANSI_Backslash: "\\",
        ]
        let f = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, k) in f.enumerated() { m[k] = "F\(i + 1)" }
        return m
    }()
    static func keyName(_ code: UInt32) -> String { names[Int(code)] ?? "Key \(code)" }

    // Prefs round-trip: ["keyCode": Int, "modifiers": Int].
    var plist: [String: Int] { ["keyCode": Int(keyCode), "modifiers": Int(modifiers)] }
    init?(plist: Any?) {
        guard let d = plist as? [String: Any], let k = d["keyCode"] as? Int, let m = d["modifiers"] as? Int,
              (0...0xFFFF).contains(k), (0...Int(UInt32.max)).contains(m) else { return nil }
        self.init(keyCode: UInt32(k), modifiers: UInt32(m))
    }
}

@MainActor
final class PerchHotKeys {
    static let stackShortcutKey = "stackShortcut"

    private let registrar: HotKeyRegistrar
    private let defaults: UserDefaults
    private let onToggleStrip: () -> Void
    private let onToggleStack: () -> Void

    private var stripReg: HotKeyRegistration?
    private var stackReg: HotKeyRegistration?
    private(set) var stripFailed = false
    private(set) var stackFailed = false
    private(set) var started = false
    // True while Settings records a new stack shortcut: the current one is unregistered so pressing it
    // reaches the recorder instead of toggling the stack (a Carbon hotkey swallows the keystroke).
    private(set) var stackSuspended = false

    init(registrar: HotKeyRegistrar = CarbonHotKeyRegistrar(), defaults: UserDefaults,
         onToggleStrip: @escaping () -> Void, onToggleStack: @escaping () -> Void) {
        self.registrar = registrar
        self.defaults = defaults
        self.onToggleStrip = onToggleStrip
        self.onToggleStack = onToggleStack
    }

    // The saved stack shortcut, or nil when unset (the default) or invalid (never registered).
    var stackShortcut: HotKeyCombo? {
        guard let c = HotKeyCombo(plist: defaults.object(forKey: Self.stackShortcutKey)), c.isAllowedForStack
        else { return nil }
        return c
    }

    // Save (or clear with nil) the stack shortcut and re-register it. False = not allowed; nothing changes.
    @discardableResult
    func setStackShortcut(_ combo: HotKeyCombo?) -> Bool {
        if let combo {
            guard combo.isAllowedForStack else { return false }
            defaults.set(combo.plist, forKey: Self.stackShortcutKey)
        } else {
            defaults.removeObject(forKey: Self.stackShortcutKey)
        }
        if started { registerStack() }
        return true
    }

    func start() {
        started = true
        if stripReg == nil {
            stripReg = registrar.register(keyCode: HotKeyCombo.toggleStrip.keyCode,
                                          modifiers: HotKeyCombo.toggleStrip.modifiers) { [weak self] in
                self?.onToggleStrip()
            }
            stripFailed = stripReg == nil
        }
        registerStack()
    }

    func stop() {
        started = false
        stackSuspended = false
        stripReg = nil
        stackReg = nil
        stripFailed = false
        stackFailed = false
    }

    func suspendStackShortcut(_ suspend: Bool) {
        guard suspend != stackSuspended else { return }
        stackSuspended = suspend
        if started { registerStack() }
    }

    private func registerStack() {
        stackReg = nil              // release the old registration first (re-recording the same combo)
        stackFailed = false
        guard !stackSuspended, let combo = stackShortcut else { return }
        stackReg = registrar.register(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
            self?.onToggleStack()
        }
        stackFailed = stackReg == nil
    }

    // Human-readable failures, listed in Settings (and the gear's warning dot). Never silent.
    var failures: [String] {
        var out: [String] = []
        if stripFailed {
            out.append("Command-Space (show/hide ShakeBoard) -- Command-Space is taken by another app or Spotlight")
        }
        if stackFailed, let c = stackShortcut {
            out.append("\(c.displayName) (paste stack) -- taken by another app")
        }
        return out
    }
}
