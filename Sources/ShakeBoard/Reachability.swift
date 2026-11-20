//
//  Reachability.swift
//  ShakeBoard -- how you reach an app with no menu-bar icon.
//
//  ShakeBoard is an agent (LSUIElement): no Dock icon, and since v2 PR 5 no menu-bar icon either. The ways in:
//    - Command-Space (the strip), the strip's gear and Command-comma (Settings), Command-Q in the strip (quit);
//    - relaunching ShakeBoard from Spotlight / Finder / the Dock while it runs -> Settings + the strip
//      (`applicationShouldHandleReopen`);
//    - a cold launch you started yourself (Spotlight / Finder) -> Settings once, so you can see it started.
//      A login-item launch stays silent;
//    - Command-Space failing to register -> Settings opens on Shortcuts with the failure shown, even at
//      login: without that key there is no other way in (except a Share-Extension launch: no focus theft).
//

import AppKit
import Darwin

enum LaunchGreeting {
    // Which Settings section to open at launch, or nil to stay silent.
    // `handoffLaunch`: the Share Extension cold-launched ShakeBoard to add something -- the strip reveals for that,
    // and a Settings window would steal focus from the app you shared from.
    static func section(loginLaunch: Bool, handoffLaunch: Bool = false, debugShow: Bool,
                        stripShortcutFailed: Bool, renameMigrationThisLaunch: Bool = false) -> SettingsSection? {
        if debugShow { return nil }                       // dev snapshot runs drive their own UI
        // A share wins even over a failed Command-Space: the strip is revealed for it, with the gear's warning
        // dot, and the next launch / relaunch opens Settings -- never steal focus from the app you shared from.
        if handoffLaunch { return nil }
        if stripShortcutFailed { return .shortcuts }      // no Command-Space = no way in; say so
        if renameMigrationThisLaunch { return .general }  // the renamed app needs one-click permission re-grants
        if loginLaunch { return nil }
        return .general
    }

    // A launch counts as a login launch when the open-application event says so, or (SMAppService login
    // items don't always set that flag) when launch-at-login is on AND it happens within `window` seconds of
    // the console login -- so opening ShakeBoard yourself right after signing in still greets you when it's off.
    static func isLoginLaunch(appleEventSaysLoginItem: Bool, loginItemEnabled: Bool, sessionStart: Date?,
                              now: Date, window: TimeInterval = 180) -> Bool {
        if appleEventSaysLoginItem { return true }
        guard loginItemEnabled, let start = sessionStart else { return false }
        let age = now.timeIntervalSince(start)
        return age >= 0 && age < window
    }

    // keyAELaunchedAsLogInItem on the launch's open-application Apple Event. Read during didFinishLaunching.
    @MainActor static func appleEventSaysLoginItem() -> Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent,
              e.eventID == AEEventID(kAEOpenApplication) else { return false }
        return e.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
    }

    // When the current user logged in at the console (utmpx), or nil if unknown.
    static func consoleLoginTime(user: String = NSUserName()) -> Date? {
        var latest: Date?
        setutxent()
        defer { endutxent() }
        while let p = getutxent() {
            let e = p.pointee
            guard e.ut_type == USER_PROCESS else { continue }
            let name = withUnsafeBytes(of: e.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: e.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == user, line == "console" else { continue }
            let t = Date(timeIntervalSince1970: TimeInterval(e.ut_tv.tv_sec))
            if latest == nil || t > latest! { latest = t }
        }
        return latest
    }
}
