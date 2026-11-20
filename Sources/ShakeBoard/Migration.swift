//
//  Migration.swift
//  ShakeBoard -- one-time migration from the former Perch app.
//

import Foundation
import CoreFoundation
import AppKit
import Darwin

struct PerchMigration {
    static let legacyBundleID = "com.dadequate.perch"
    static let shakeBoardBundleID = "com.thisradlife.shakeboard"
    static let migratedKey = "migratedFromPerch"
    static let welcomeKey = "showRenameWelcome"

    struct Paths {
        let legacyData: URL
        let shakeBoardData: URL
        let breadcrumb: URL
    }

    struct Preferences {
        var legacyKeys: () -> [String]
        var legacyValue: (String) -> Any?
        var newValue: (String) -> Any?
        var setNewValue: (Any, String) -> Void

        static func live(newDefaults: UserDefaults,
                         newDomain: String = PerchMigration.shakeBoardBundleID,
                         legacyDomain: String = PerchMigration.legacyBundleID) -> Preferences {
            Preferences(
                legacyKeys: {
                    (CFPreferencesCopyKeyList(legacyDomain as CFString,
                                              kCFPreferencesCurrentUser,
                                              kCFPreferencesAnyHost) as? [String]) ?? []
                },
                legacyValue: { key in
                    CFPreferencesCopyValue(key as CFString,
                                           legacyDomain as CFString,
                                           kCFPreferencesCurrentUser,
                                           kCFPreferencesAnyHost)
                },
                // persistentDomain is deliberately exact: registered/global/search-list values must not
                // masquerade as values the new app domain already owns.
                newValue: { newDefaults.persistentDomain(forName: newDomain)?[$0] },
                setNewValue: { newDefaults.set($0, forKey: $1) }
            )
        }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case oldAppStillRunning
        case refused(String)
        case operation(String)

        var description: String {
            switch self {
            case .oldAppStillRunning: return "the old Perch app is still running"
            case .refused(let reason), .operation(let reason): return reason
            }
        }
    }

    enum DataResult: Equatable {
        case notNeeded
        case notNeededLegacyLeftBehind(URL)
        case moved
        case usingLegacyInPlace(Failure)
    }

    struct Outcome: Equatable {
        let data: DataResult
        let migratedPreferences: Bool

        var changedThisLaunch: Bool { data == .moved || migratedPreferences }
        var isUsingLegacyInPlace: Bool {
            legacyFailure != nil
        }

        var legacyFailure: Failure? {
            if case .usingLegacyInPlace(let failure) = data { return failure }
            return nil
        }

        var legacyDataLeftBehind: URL? {
            if case .notNeededLegacyLeftBehind(let url) = data { return url }
            return nil
        }
    }

    typealias Rename = (_ from: URL, _ to: URL) throws -> Void
    typealias HasRealData = (_ folder: URL) throws -> Bool

    struct RunningApplication {
        let terminate: () -> Void
        let isTerminated: () -> Bool
    }

    typealias RunningApplications = () -> [RunningApplication]

    let paths: Paths
    let rename: Rename
    let hasRealData: HasRealData
    let preferences: Preferences
    let runningApplications: RunningApplications
    let uptime: () -> TimeInterval
    let sleep: (TimeInterval) -> Void
    let clock: () -> Date
    let logger: (String) -> Void
    let resolveDataDirectory: (URL) -> Void

    init(paths: Paths,
         rename: @escaping Rename = PerchMigration.atomicRename,
         hasRealData: @escaping HasRealData = PerchMigration.hasRealData,
         preferences: Preferences,
         runningApplications: @escaping RunningApplications = PerchMigration.liveRunningApplications,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         clock: @escaping () -> Date = Date.init,
         logger: @escaping (String) -> Void = { NSLog("%@", $0) },
         resolveDataDirectory: @escaping (URL) -> Void) {
        self.paths = paths
        self.rename = rename
        self.hasRealData = hasRealData
        self.preferences = preferences
        self.runningApplications = runningApplications
        self.uptime = uptime
        self.sleep = sleep
        self.clock = clock
        self.logger = logger
        self.resolveDataDirectory = resolveDataDirectory
    }

    func run() -> Outcome {
        let data = migrateData()
        let migratedPreferences = migratePreferences()
        let outcome = Outcome(data: data, migratedPreferences: migratedPreferences)
        if outcome.changedThisLaunch {
            preferences.setNewValue(true, Self.welcomeKey)
        }
        return outcome
    }

    func migrateData() -> DataResult {
        let newStatus = status(at: paths.shakeBoardData)
        let oldStatus = status(at: paths.legacyData)
        var setAsideEmptyShakeBoard = false
        let sourceInfo: stat

        switch newStatus {
        case .present(let newInfo):
            guard Self.isOwnedDirectory(newInfo) else {
                return useLegacy(.refused("the ShakeBoard path is not a real directory owned by the current user"))
            }

            // A valid ShakeBoard directory normally wins. The one exception is a shell left behind by an
            // interrupted first launch: if it has no user data and the valid Perch directory does, quarantine
            // the empty shell and continue through the exact same guarded atomic move used below.
            guard case .present(let oldInfo) = oldStatus else {
                resolveDataDirectory(paths.shakeBoardData)
                return .notNeeded
            }
            guard Self.isOwnedDirectory(oldInfo) else {
                resolveDataDirectory(paths.shakeBoardData)
                logger("ShakeBoard migration: both folders exist; using ShakeBoard, leaving Perch untouched")
                return .notNeeded
            }

            let newHasRealData: Bool
            let oldHasRealData: Bool
            do {
                newHasRealData = try hasRealData(paths.shakeBoardData)
                oldHasRealData = try hasRealData(paths.legacyData)
            } catch {
                resolveDataDirectory(paths.shakeBoardData)
                logger("ShakeBoard migration: couldn't inspect both folders for real data: \(error); using ShakeBoard, leaving Perch untouched")
                return .notNeeded
            }

            if newHasRealData {
                resolveDataDirectory(paths.shakeBoardData)
                logger("ShakeBoard migration: both folders exist; using ShakeBoard, leaving Perch untouched")
                return oldHasRealData ? .notNeededLegacyLeftBehind(paths.legacyData) : .notNeeded
            }
            guard oldHasRealData else {
                resolveDataDirectory(paths.shakeBoardData)
                logger("ShakeBoard migration: both folders exist but neither has real data; using ShakeBoard, leaving Perch untouched")
                return .notNeeded
            }
            sourceInfo = oldInfo
            setAsideEmptyShakeBoard = true
        case .failed(let code):
            return useLegacy(.operation("couldn't inspect the ShakeBoard folder: \(Self.errorText(code))"))
        case .missing:
            switch oldStatus {
            case .missing:
                resolveDataDirectory(paths.shakeBoardData)
                return .notNeeded
            case .failed(let code):
                return useLegacy(.operation("couldn't inspect the Perch folder: \(Self.errorText(code))"))
            case .present(let info):
                guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                    return useLegacy(.refused("the Perch path is not a real directory"))
                }
                guard info.st_uid == getuid() else {
                    return useLegacy(.refused("the Perch folder is not owned by the current user"))
                }
                sourceInfo = info
            }
        }

        guard stopRunningLegacyApplications() else {
            return useLegacy(.oldAppStillRunning)
        }

        if setAsideEmptyShakeBoard {
            do {
                let setAsideURL = try setAsideEmptyShakeBoardDirectory()
                logger("ShakeBoard migration: set aside empty ShakeBoard folder at \(setAsideURL.path)")
            } catch {
                return useLegacy(.operation("set aside empty ShakeBoard folder failed: \(error)"))
            }
        }

        // DESIGN DECISION: move the directory with one rename(2), never a copy. Both paths are on the
        // same Application Support volume, so rename is atomic and preserves every inode. That is essential:
        // shelf.json contains plain bookmarks to ShakeBoard-owned files inside Shelf/, and those bookmarks
        // follow file identity. shelf-ocr.json is keyed by item id + size + mtime, while 0700/0600 modes and
        // Time Machine exclusions must survive too. Copying would mint new inodes, strand those bookmarks on
        // the old folder, double disk use, and create partial state. rename either happened or it did not;
        // this migration never deletes the old folder.
        do {
            try rename(paths.legacyData, paths.shakeBoardData)
        } catch {
            return useLegacy(.operation("rename failed: \(error)"))
        }

        guard case .present(let destinationInfo) = status(at: paths.shakeBoardData),
              Self.sameFile(sourceInfo, destinationInfo),
              Self.isOwnedDirectory(destinationInfo) else {
            return useLegacy(.operation("rename did not leave the expected on-disk state"))
        }

        // Verify identity, not merely the spelling of the paths. If the old app recreates Perch after our
        // successful atomic move, the matching inode at ShakeBoard is still the migrated store. Leave the
        // newly-created Perch directory untouched, choose ShakeBoard, and report the race rather than switching
        // back to a different store for this process.
        if case .present = status(at: paths.legacyData) {
            logger("ShakeBoard migration: both folders exist after the move; using ShakeBoard, leaving Perch untouched")
        } else if case .failed(let code) = status(at: paths.legacyData) {
            logger("ShakeBoard migration: couldn't verify removal of the old path: \(Self.errorText(code)); using verified ShakeBoard inode")
        }

        resolveDataDirectory(paths.shakeBoardData)
        removeStaleLegacySocket()
        writeBreadcrumb()
        logger("ShakeBoard migration: moved Perch data to \(paths.shakeBoardData.path)")
        return .moved
    }

    func migratePreferences() -> Bool {
        // Presence, not the stored Bool, is the idempotence gate. Old preferences remain untouched.
        guard preferences.newValue(Self.migratedKey) == nil else { return false }
        let keys = preferences.legacyKeys().sorted()
        for key in keys where preferences.newValue(key) == nil {
            if let value = preferences.legacyValue(key) {
                preferences.setNewValue(value, key)
            }
        }
        preferences.setNewValue(true, Self.migratedKey)
        return !keys.isEmpty
    }

    private func useLegacy(_ failure: Failure) -> DataResult {
        resolveDataDirectory(paths.legacyData)
        logger("ShakeBoard migration: \(failure); using Perch in place and retrying next launch")
        return .usingLegacyInPlace(failure)
    }

    private func stopRunningLegacyApplications() -> Bool {
        let applications = runningApplications()
        guard !applications.isEmpty else { return true }

        for application in applications {
            application.terminate()
        }

        let deadline = uptime() + 5
        while applications.contains(where: { !$0.isTerminated() }) {
            let remaining = deadline - uptime()
            guard remaining > 0 else { return false }
            sleep(min(0.05, remaining))
        }
        return true
    }

    private func setAsideEmptyShakeBoardDirectory() throws -> URL {
        let parent = paths.shakeBoardData.deletingLastPathComponent()
        let baseName = "\(paths.shakeBoardData.lastPathComponent).empty-\(Int(clock().timeIntervalSince1970))"
        var attempt = 1

        while true {
            let name = attempt == 1 ? baseName : "\(baseName)-\(attempt)"
            let destination = parent.appendingPathComponent(name, isDirectory: true)
            do {
                try rename(paths.shakeBoardData, destination)
                return destination
            } catch {
                if Self.isAlreadyExists(error) {
                    attempt += 1
                } else {
                    throw error
                }
            }
        }
    }

    private func removeStaleLegacySocket() {
        let socket = paths.shakeBoardData
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("perch.sock")
        guard case .present(let info) = status(at: socket),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK) else { return }
        if unlink(socket.path) != 0 {
            logger("ShakeBoard migration: couldn't remove stale perch.sock: \(Self.errorText(errno))")
        }
    }

    private func writeBreadcrumb() {
        let formatter = ISO8601DateFormatter()
        let text = """
        Perch data moved on \(formatter.string(from: clock())).
        New location: \(paths.shakeBoardData.path)
        This breadcrumb is safe to delete.
        """ + "\n"
        let descriptor = open(paths.breadcrumb.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
                              mode_t(0o644))
        guard descriptor >= 0 else {
            logger("ShakeBoard migration: couldn't write breadcrumb: \(Self.errorText(errno))")
            return
        }
        defer { close(descriptor) }
        if fchmod(descriptor, mode_t(0o644)) != 0 {
            logger("ShakeBoard migration: couldn't set breadcrumb permissions: \(Self.errorText(errno))")
        }
        let bytes = Array(text.utf8)
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress?.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                break
            }
        }
        if offset != bytes.count {
            logger("ShakeBoard migration: couldn't finish writing breadcrumb")
        }
    }

    private enum NodeStatus {
        case present(stat)
        case missing
        case failed(Int32)
    }

    private func status(at url: URL) -> NodeStatus {
        var info = stat()
        if lstat(url.path, &info) == 0 { return .present(info) }
        let code = errno
        return code == ENOENT ? .missing : .failed(code)
    }

    static func atomicRename(from: URL, to: URL) throws {
        // RENAME_EXCL is the no-replace form of the Darwin rename(2) primitive. It closes the small race
        // between the destination lstat above and the move: a concurrently-created ShakeBoard folder is
        // never overwritten. The operation remains one same-volume, atomic directory rename.
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func hasRealData(_ folder: URL) throws -> Bool {
        let markerPaths = [
            "shelf.json",
            "Clips/clips.json",
            "pinboards.json",
            "stacks.json",
            "clip-pins.json",
        ]
        for path in markerPaths {
            let marker = folder.appendingPathComponent(path)
            var info = stat()
            if lstat(marker.path, &info) == 0 {
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) { return true }
            } else if errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        for name in ["Clips", "Shelf"] {
            let directory = folder.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            if lstat(directory.path, &info) != 0 {
                if errno == ENOENT { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { continue }
            let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if entries.contains(where: { !$0.hasPrefix(".") }) { return true }
        }
        return false
    }

    private static func liveRunningApplications() -> [RunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID).map { app in
            RunningApplication(
                terminate: { _ = app.terminate() },
                isTerminated: { app.isTerminated }
            )
        }
    }

    private static func isOwnedDirectory(_ info: stat) -> Bool {
        info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && info.st_uid == getuid()
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
    }

    private static func isAlreadyExists(_ error: Error) -> Bool {
        if let error = error as? POSIXError, error.code == .EEXIST { return true }
        let error = error as NSError
        return error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST)
    }

    private static func errorText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
