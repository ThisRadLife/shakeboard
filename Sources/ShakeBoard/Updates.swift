//
//  Updates.swift
//  ShakeBoard -- Sparkle 2 update integration and shared foreground activation.
//

import AppKit
import Combine
import Sparkle

@MainActor
protocol UpdaterDriving: AnyObject {
    var isConfigured: Bool { get }
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var availableUpdate: String? { get }
    var onStateChange: (() -> Void)? { get set }
    func checkForUpdates()
}

enum SparkleConfiguration {
    static let placeholderPublicEDKey = "UNSET_SPARKLE_PUBLIC_ED_KEY"

    static func isConfigured(publicEDKey: String) -> Bool {
        let key = publicEDKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != placeholderPublicEDKey,
              let decoded = Data(base64Encoded: key) else { return false }
        return decoded.count == 32
    }
}

// Settings and Sparkle both need an LSUIElement app to become a normal foreground app temporarily. One
// coordinator owns that transition so closing either UI cannot send the other one back to accessory mode.
@MainActor
final class AppActivationCoordinator {
    private enum Reason: Hashable { case settings, update }

    private var reasons: Set<Reason> = []
    private var previousApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: Any?

    init() {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { lastExternalApp = front }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.lastExternalApp = app
                if !self.reasons.isEmpty { self.previousApp = app }
            }
        }
    }

    func beginSettings() { acquire(.settings) }
    func endSettings() { release(.settings) }
    func beginUpdateUI() { acquire(.update) }
    func endUpdateUI() { release(.update) }

    func activateCurrentUI() {
        guard !reasons.isEmpty else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func acquire(_ reason: Reason) {
        guard reasons.insert(reason).inserted else {
            activateCurrentUI()
            return
        }
        if reasons.count == 1 {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApp : front
            NSApp.setActivationPolicy(.regular)
            NSApp.mainMenu = SettingsWindowController.makeMainMenu()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func release(_ reason: Reason) {
        guard reasons.remove(reason) != nil, reasons.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
        let app = previousApp
        previousApp = nil
        DispatchQueue.main.async {
            if let app, !app.isTerminated { app.activate() }
        }
    }
}

@MainActor
final class UpdateController: NSObject, ObservableObject, UpdaterDriving,
                              SPUUpdaterDelegate,
                              @preconcurrency SPUStandardUserDriverDelegate {
    let isConfigured: Bool
    @Published private(set) var canCheckForUpdates = false {
        didSet { onStateChange?() }
    }
    @Published private(set) var availableUpdate: String? {
        didSet { onStateChange?() }
    }
    var onStateChange: (() -> Void)?

    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
        set {
            guard isConfigured, let updater = updaterController?.updater else { return }
            updater.automaticallyChecksForUpdates = newValue
            onStateChange?()
        }
    }

    private let activation: AppActivationCoordinator
    private var updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: AnyCancellable?
    private var updateUIIsActive = false

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard,
         activation: AppActivationCoordinator) {
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        isConfigured = SparkleConfiguration.isConfigured(publicEDKey: publicKey)
        self.activation = activation
        super.init()

        // Do not even construct/start Sparkle for an unconfigured build. In particular, this prevents an appcast
        // request from a local Release build that explicitly opted past the build guard.
        guard isConfigured else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        updaterController = controller
        if !defaults.bool(forKey: "updateChoiceMade") {
            controller.updater.automaticallyChecksForUpdates = false
        }
        canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .receive(on: RunLoop.main)
            .sink { [weak self] canCheck in self?.canCheckForUpdates = canCheck }
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard isConfigured, canCheckForUpdates, let controller = updaterController else { return }
        setAvailableUpdate(nil)
        beginUpdateUI()
        controller.checkForUpdates(nil)
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            setAvailableUpdate(update.displayVersionString)
        } else {
            setAvailableUpdate(nil)
            beginUpdateUI()
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        // A scheduled reminder becomes foreground UI only after the user clicks or acts on it.
        setAvailableUpdate(nil)
        beginUpdateUI()
    }

    func standardUserDriverWillShowModalAlert() { beginUpdateUI() }

    func standardUserDriverDidShowModalAlert() { activation.activateCurrentUI() }

    func standardUserDriverWillFinishUpdateSession() {
        setAvailableUpdate(nil)
        guard updateUIIsActive else { return }
        updateUIIsActive = false
        activation.endUpdateUI()
    }

    private func beginUpdateUI() {
        guard !updateUIIsActive else {
            activation.activateCurrentUI()
            return
        }
        updateUIIsActive = true
        activation.beginUpdateUI()
    }

    private func setAvailableUpdate(_ version: String?) {
        if availableUpdate != version { availableUpdate = version }
    }
}
