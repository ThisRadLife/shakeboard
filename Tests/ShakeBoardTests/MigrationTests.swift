//
//  MigrationTests.swift
//  ShakeBoardTests -- Perch data/defaults migration, always isolated from the real app.
//

import XCTest
import Foundation
import CoreFoundation
import Darwin
@testable import ShakeBoard

final class MigrationTests: XCTestCase {
    private var root: URL!
    private var legacyData: URL!
    private var shakeBoardData: URL!
    private var breadcrumb: URL!
    private var newSuite: String!
    private var oldSuite: String!
    private var inheritedSuite: String!
    private var newDefaults: UserDefaults!
    private var oldDefaults: UserDefaults!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ShakeBoardMigration-\(UUID().uuidString)", isDirectory: true)
        legacyData = root.appendingPathComponent("Perch", isDirectory: true)
        shakeBoardData = root.appendingPathComponent("ShakeBoard", isDirectory: true)
        breadcrumb = root.appendingPathComponent("Perch-moved-to-ShakeBoard.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        newSuite = "shakeboard.tests.migration.new.\(UUID().uuidString)"
        oldSuite = "shakeboard.tests.migration.old.\(UUID().uuidString)"
        inheritedSuite = "shakeboard.tests.migration.inherited.\(UUID().uuidString)"
        newDefaults = UserDefaults(suiteName: newSuite)!
        oldDefaults = UserDefaults(suiteName: oldSuite)!
        newDefaults.removePersistentDomain(forName: newSuite)
        oldDefaults.removePersistentDomain(forName: oldSuite)
    }

    override func tearDownWithError() throws {
        PerchPaths.resolveBase(nil)
        newDefaults.removePersistentDomain(forName: newSuite)
        oldDefaults.removePersistentDomain(forName: oldSuite)
        UserDefaults(suiteName: inheritedSuite)?.removePersistentDomain(forName: inheritedSuite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeMigration(rename: PerchMigration.Rename? = nil,
                               hasRealData: PerchMigration.HasRealData? = nil,
                               runningApplications: @escaping PerchMigration.RunningApplications = { [] },
                               uptime: @escaping () -> TimeInterval = { 0 },
                               sleep: @escaping (TimeInterval) -> Void = { _ in },
                               clock: @escaping () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) },
                               resolve: @escaping (URL) -> Void = { _ in }) -> PerchMigration {
        let paths = PerchMigration.Paths(legacyData: legacyData,
                                         shakeBoardData: shakeBoardData,
                                         breadcrumb: breadcrumb)
        let prefs = PerchMigration.Preferences.live(newDefaults: newDefaults,
                                                    newDomain: newSuite,
                                                    legacyDomain: oldSuite)
        return PerchMigration(paths: paths,
                              rename: rename ?? PerchMigration.atomicRename,
                              hasRealData: hasRealData ?? PerchMigration.hasRealData,
                              preferences: prefs,
                              runningApplications: runningApplications, uptime: uptime, sleep: sleep,
                              clock: clock, logger: { _ in }, resolveDataDirectory: resolve)
    }

    private func createLegacyDirectory() throws {
        try FileManager.default.createDirectory(at: legacyData, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: legacyData.path)
    }

    private func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return value
    }

    private func makeUnixSocket(at url: URL) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func testFreshInstallDoesNothingAndWritesNoBreadcrumbOrWelcome() {
        var resolved: URL?
        let outcome = makeMigration(resolve: { resolved = $0 }).run()

        XCTAssertEqual(outcome.data, .notNeeded)
        XCTAssertFalse(outcome.migratedPreferences)
        XCTAssertEqual(resolved, shakeBoardData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: breadcrumb.path))
        XCTAssertNil(newDefaults.object(forKey: PerchMigration.welcomeKey))
    }

    func testOldAppNotRunningMovesWithoutTerminationWait() throws {
        try createLegacyDirectory()
        var checkedForOldApp = false
        var slept = false

        let outcome = makeMigration(
            runningApplications: {
                checkedForOldApp = true
                return []
            },
            sleep: { _ in slept = true }
        ).run()

        XCTAssertEqual(outcome.data, .moved)
        XCTAssertTrue(checkedForOldApp)
        XCTAssertFalse(slept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyData.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shakeBoardData.path))
    }

    func testRunningOldAppIsTerminatedAndMoveProceedsAfterItExits() throws {
        try createLegacyDirectory()
        var terminateCalls = 0
        var terminationChecks = 0
        var sleeps: [TimeInterval] = []
        let oldApp = PerchMigration.RunningApplication(
            terminate: { terminateCalls += 1 },
            isTerminated: {
                terminationChecks += 1
                return terminateCalls == 1 && terminationChecks >= 2
            }
        )

        let outcome = makeMigration(
            runningApplications: { [oldApp] },
            uptime: { 0 },
            sleep: { sleeps.append($0) }
        ).run()

        XCTAssertEqual(outcome.data, .moved)
        XCTAssertEqual(terminateCalls, 1)
        XCTAssertGreaterThanOrEqual(terminationChecks, 2)
        XCTAssertFalse(sleeps.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyData.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shakeBoardData.path))
    }

    func testRunningOldAppThatDoesNotExitUsesLegacyWithoutTouchingFolder() throws {
        try createLegacyDirectory()
        let file = legacyData.appendingPathComponent("shelf.json")
        try Data("keep me".utf8).write(to: file)
        let inode = try info(file).st_ino
        var terminateCalls = 0
        var renameCalled = false
        var now: TimeInterval = 0
        var resolved: URL?
        let oldApp = PerchMigration.RunningApplication(
            terminate: { terminateCalls += 1 },
            isTerminated: { false }
        )

        let outcome = makeMigration(
            rename: { _, _ in renameCalled = true },
            runningApplications: { [oldApp] },
            uptime: {
                defer { now += 1 }
                return now
            },
            resolve: { resolved = $0 }
        ).run()

        XCTAssertEqual(outcome.data, .usingLegacyInPlace(.oldAppStillRunning))
        XCTAssertEqual(outcome.legacyFailure?.description, "the old Perch app is still running")
        XCTAssertEqual(terminateCalls, 1)
        XCTAssertFalse(renameCalled)
        XCTAssertEqual(resolved, legacyData)
        XCTAssertEqual(try info(file).st_ino, inode)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shakeBoardData.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: breadcrumb.path))

        var inputs = SettingsAlerts.Inputs()
        inputs.migrationFailure = outcome.legacyFailure
        let alerts = SettingsAlerts.compute(inputs)
        XCTAssertTrue(alerts.contains {
            $0.section == .general
                && $0.text == "Quit the old Perch app, then relaunch ShakeBoard to finish moving your data."
        })
    }

    func testOldFolderMovesAtomicallyPreservingIdentityBookmarkContentsAndPermissions() throws {
        try createLegacyDirectory()
        let shelf = legacyData.appendingPathComponent("Shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shelf.path)
        let file = shelf.appendingPathComponent("owned.txt")
        try Data("real shelf data".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let inodeBefore = try info(file).st_ino
        let bookmark = try file.bookmarkData()

        let mcp = legacyData.appendingPathComponent("mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: mcp, withIntermediateDirectories: true)
        let staleSocket = mcp.appendingPathComponent("perch.sock")
        try makeUnixSocket(at: staleSocket)

        var resolved: URL?
        let outcome = makeMigration(resolve: { resolved = $0 }).run()
        let movedFile = shakeBoardData.appendingPathComponent("Shelf/owned.txt")

        XCTAssertEqual(outcome.data, .moved)
        XCTAssertEqual(resolved, shakeBoardData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyData.path))
        XCTAssertEqual(try info(movedFile).st_ino, inodeBefore)
        XCTAssertEqual(try String(contentsOf: movedFile, encoding: .utf8), "real shelf data")
        XCTAssertEqual(try info(shakeBoardData).st_mode & mode_t(0o777), mode_t(0o700))
        XCTAssertEqual(try info(movedFile).st_mode & mode_t(0o777), mode_t(0o600))
        let movedStaleSocket = shakeBoardData.appendingPathComponent("mcp/perch.sock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedStaleSocket.path))

        var stale = false
        let resolvedBookmark = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                       relativeTo: nil, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolvedBookmark.standardizedFileURL.path, movedFile.standardizedFileURL.path)

        let breadcrumbText = try String(contentsOf: breadcrumb, encoding: .utf8)
        XCTAssertTrue(breadcrumbText.contains("2027"))
        XCTAssertTrue(breadcrumbText.contains(shakeBoardData.path))
        XCTAssertTrue(breadcrumbText.contains("safe to delete"))
        XCTAssertEqual(try info(breadcrumb).st_mode & mode_t(0o777), mode_t(0o644))
        XCTAssertTrue(newDefaults.bool(forKey: PerchMigration.welcomeKey))
    }

    func testRegularFileNamedPerchSocketIsNotRemoved() throws {
        try createLegacyDirectory()
        let mcp = legacyData.appendingPathComponent("mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: mcp, withIntermediateDirectories: true)
        let regular = mcp.appendingPathComponent("perch.sock")
        try Data("not a socket".utf8).write(to: regular)

        XCTAssertEqual(makeMigration().run().data, .moved)

        let moved = shakeBoardData.appendingPathComponent("mcp/perch.sock")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "not a socket")
        XCTAssertEqual(try info(moved).st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
    }

    func testEmptyShakeBoardWithRuntimeArtifactsIsSetAsideAndPopulatedPerchMoves() throws {
        try createLegacyDirectory()
        let legacyShelf = legacyData.appendingPathComponent("Shelf", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyShelf, withIntermediateDirectories: true)
        let legacyFile = legacyShelf.appendingPathComponent("owned.txt")
        try Data("real shelf data".utf8).write(to: legacyFile)
        let legacyInode = try info(legacyFile).st_ino

        let emptyClips = shakeBoardData.appendingPathComponent("Clips", isDirectory: true)
        let mcp = shakeBoardData.appendingPathComponent("mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyClips, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mcp, withIntermediateDirectories: true)
        try makeUnixSocket(at: mcp.appendingPathComponent("perch.sock"))
        let emptyDirectoryInode = try info(shakeBoardData).st_ino
        var logs: [String] = []
        var inspectedForRealData: [URL] = []
        let paths = PerchMigration.Paths(legacyData: legacyData, shakeBoardData: shakeBoardData, breadcrumb: breadcrumb)
        let migration = PerchMigration(
            paths: paths,
            hasRealData: { folder in
                inspectedForRealData.append(folder)
                return try PerchMigration.hasRealData(folder)
            },
            preferences: .live(newDefaults: newDefaults, newDomain: newSuite, legacyDomain: oldSuite),
            runningApplications: { [] },
            clock: { Date(timeIntervalSince1970: 1_800_000_000) },
            logger: { logs.append($0) },
            resolveDataDirectory: { _ in }
        )

        let outcome = migration.run()
        let setAside = root.appendingPathComponent("ShakeBoard.empty-1800000000", isDirectory: true)

        XCTAssertEqual(outcome.data, .moved)
        XCTAssertEqual(inspectedForRealData, [shakeBoardData, legacyData])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyData.path))
        XCTAssertEqual(try info(shakeBoardData.appendingPathComponent("Shelf/owned.txt")).st_ino, legacyInode)
        XCTAssertEqual(try info(setAside).st_ino, emptyDirectoryInode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: setAside.appendingPathComponent("Clips").path))
        XCTAssertEqual(try info(setAside.appendingPathComponent("mcp/perch.sock")).st_mode & mode_t(S_IFMT),
                       mode_t(S_IFSOCK))
        XCTAssertTrue(logs.contains { $0.contains("set aside empty ShakeBoard folder at \(setAside.path)") })
        XCTAssertTrue(logs.contains { $0.contains("moved Perch data to \(shakeBoardData.path)") })
    }

    func testBothEmptyFoldersStayPutWithoutAlert() throws {
        try createLegacyDirectory()
        try FileManager.default.createDirectory(
            at: shakeBoardData.appendingPathComponent("Clips", isDirectory: true),
            withIntermediateDirectories: true
        )
        let legacyInode = try info(legacyData).st_ino
        let shakeBoardInode = try info(shakeBoardData).st_ino
        var resolved: URL?

        let outcome = makeMigration(resolve: { resolved = $0 }).run()

        XCTAssertEqual(outcome.data, .notNeeded)
        XCTAssertNil(outcome.legacyDataLeftBehind)
        XCTAssertEqual(resolved, shakeBoardData)
        XCTAssertEqual(try info(legacyData).st_ino, legacyInode)
        XCTAssertEqual(try info(shakeBoardData).st_ino, shakeBoardInode)
        var inputs = SettingsAlerts.Inputs()
        inputs.migrationLegacyLeftBehind = outcome.legacyDataLeftBehind
        XCTAssertFalse(SettingsAlerts.compute(inputs).contains { $0.id == "perch-data-left-behind" })
    }

    func testBothPopulatedFoldersStayPutAndRaiseLegacyLeftBehindAlert() throws {
        try createLegacyDirectory()
        try FileManager.default.createDirectory(at: shakeBoardData, withIntermediateDirectories: true)
        let oldFile = legacyData.appendingPathComponent("shelf.json")
        let newFile = shakeBoardData.appendingPathComponent("stacks.json")
        try Data("old".utf8).write(to: oldFile)
        try Data("new".utf8).write(to: newFile)
        let oldInode = try info(oldFile).st_ino
        let newInode = try info(newFile).st_ino
        var logs: [String] = []
        let paths = PerchMigration.Paths(legacyData: legacyData, shakeBoardData: shakeBoardData, breadcrumb: breadcrumb)
        let migration = PerchMigration(
            paths: paths,
            preferences: .live(newDefaults: newDefaults, newDomain: newSuite, legacyDomain: oldSuite),
            runningApplications: { [] },
            logger: { logs.append($0) },
            resolveDataDirectory: { _ in }
        )

        let outcome = migration.run()

        XCTAssertEqual(outcome.data, .notNeededLegacyLeftBehind(legacyData))
        XCTAssertEqual(outcome.legacyDataLeftBehind, legacyData)
        XCTAssertEqual(try info(oldFile).st_ino, oldInode)
        XCTAssertEqual(try info(newFile).st_ino, newInode)
        XCTAssertEqual(try String(contentsOf: oldFile, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: newFile, encoding: .utf8), "new")
        XCTAssertTrue(logs.contains { $0.contains("both folders exist; using ShakeBoard, leaving Perch untouched") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: breadcrumb.path))

        var inputs = SettingsAlerts.Inputs()
        inputs.migrationLegacyLeftBehind = outcome.legacyDataLeftBehind
        let alerts = SettingsAlerts.compute(inputs)
        XCTAssertTrue(alerts.contains {
            $0.id == "perch-data-left-behind"
                && $0.section == .general
                && $0.text == "Found older Perch data at \(self.legacyData.path). It was not merged into ShakeBoard."
        })
        XCTAssertTrue(SettingsAlerts.needsAttention(alerts))
    }

    func testSetAsideFailureUsesPopulatedPerchInPlaceWithoutTouchingEitherFolder() throws {
        try createLegacyDirectory()
        let legacyFile = legacyData.appendingPathComponent("shelf.json")
        try Data("legacy".utf8).write(to: legacyFile)
        try FileManager.default.createDirectory(
            at: shakeBoardData.appendingPathComponent("Clips", isDirectory: true),
            withIntermediateDirectories: true
        )
        let legacyInode = try info(legacyData).st_ino
        let shakeBoardInode = try info(shakeBoardData).st_ino
        var renameCalls = 0
        var resolved: URL?

        let outcome = makeMigration(
            rename: { _, _ in
                renameCalls += 1
                throw POSIXError(.EACCES)
            },
            resolve: { resolved = $0 }
        ).run()

        guard case .usingLegacyInPlace(let failure) = outcome.data else {
            return XCTFail("expected a legacy-in-place result")
        }
        XCTAssertTrue(failure.description.contains("set aside empty ShakeBoard folder failed"))
        XCTAssertEqual(renameCalls, 1)
        XCTAssertEqual(resolved, legacyData)
        XCTAssertEqual(try info(legacyData).st_ino, legacyInode)
        XCTAssertEqual(try info(shakeBoardData).st_ino, shakeBoardInode)
        XCTAssertEqual(try String(contentsOf: legacyFile, encoding: .utf8), "legacy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shakeBoardData.appendingPathComponent("Clips").path))
    }

    func testSetAsideRetriesWithNumericSuffixWhenTimestampNameExists() throws {
        try createLegacyDirectory()
        try Data("legacy".utf8).write(to: legacyData.appendingPathComponent("shelf.json"))
        try FileManager.default.createDirectory(at: shakeBoardData, withIntermediateDirectories: true)
        let collision = root.appendingPathComponent("ShakeBoard.empty-1800000000", isDirectory: true)
        let secondCollision = root.appendingPathComponent("ShakeBoard.empty-1800000000-2", isDirectory: true)
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondCollision, withIntermediateDirectories: true)

        XCTAssertEqual(makeMigration().run().data, .moved)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ShakeBoard.empty-1800000000-3").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: collision.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondCollision.path))
    }

    func testRunningOldAppGuardPrecedesSettingAsideEmptyShakeBoard() throws {
        try createLegacyDirectory()
        try Data("legacy".utf8).write(to: legacyData.appendingPathComponent("shelf.json"))
        try FileManager.default.createDirectory(at: shakeBoardData, withIntermediateDirectories: true)
        var renameCalled = false
        var now: TimeInterval = 0
        let oldApp = PerchMigration.RunningApplication(terminate: {}, isTerminated: { false })

        let outcome = makeMigration(
            rename: { _, _ in renameCalled = true },
            runningApplications: { [oldApp] },
            uptime: {
                defer { now += 1 }
                return now
            }
        ).run()

        XCTAssertEqual(outcome.data, .usingLegacyInPlace(.oldAppStillRunning))
        XCTAssertFalse(renameCalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyData.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shakeBoardData.path))
    }

    func testHasRealDataRecognizesEveryMarkerFileWithoutFollowingSymlinks() throws {
        let markers = [
            "shelf.json",
            "Clips/clips.json",
            "pinboards.json",
            "stacks.json",
            "clip-pins.json",
        ]

        for marker in markers {
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let file = folder.appendingPathComponent(marker)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: file)
            XCTAssertTrue(try PerchMigration.hasRealData(folder), "\(marker) should count as real data")
        }

        let symlinkFolder = root.appendingPathComponent("symlink-marker", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkFolder, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("actual-shelf.json")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            at: symlinkFolder.appendingPathComponent("shelf.json"),
            withDestinationURL: target
        )
        XCTAssertFalse(try PerchMigration.hasRealData(symlinkFolder))
    }

    func testHasRealDataIgnoresDotfilesAndRuntimeOnlyDirectories() throws {
        let clips = shakeBoardData.appendingPathComponent("Clips", isDirectory: true)
        let shelf = shakeBoardData.appendingPathComponent("Shelf", isDirectory: true)
        let mcp = shakeBoardData.appendingPathComponent("mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mcp, withIntermediateDirectories: true)
        try Data().write(to: clips.appendingPathComponent(".DS_Store"))
        try Data().write(to: shelf.appendingPathComponent(".placeholder"))
        try Data().write(to: mcp.appendingPathComponent("audit.jsonl"))
        try makeUnixSocket(at: mcp.appendingPathComponent("perch.sock"))

        XCTAssertFalse(try PerchMigration.hasRealData(shakeBoardData))

        try Data().write(to: clips.appendingPathComponent("visible-entry"))
        XCTAssertTrue(try PerchMigration.hasRealData(shakeBoardData))
    }

    func testSymlinkAtOldPathIsRefusedAndUsedInPlace() throws {
        let target = root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: legacyData, withDestinationURL: target)
        var resolved: URL?
        var renameCalled = false

        let outcome = makeMigration(
            rename: { _, _ in renameCalled = true },
            resolve: { resolved = $0 }
        ).run()

        guard case .usingLegacyInPlace(let failure) = outcome.data else {
            return XCTFail("expected a legacy-in-place result")
        }
        XCTAssertTrue(failure.description.contains("not a real directory"))
        XCTAssertFalse(renameCalled)
        XCTAssertEqual(resolved, legacyData)
        XCTAssertEqual(try info(legacyData).st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shakeBoardData.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: breadcrumb.path))
    }

    func testSymlinkAtNewPathIsNeverAcceptedAsTheShakeBoardStore() throws {
        try createLegacyDirectory()
        let target = root.appendingPathComponent("unexpected-new-target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: shakeBoardData, withDestinationURL: target)
        var resolved: URL?
        var renameCalled = false

        let outcome = makeMigration(
            rename: { _, _ in renameCalled = true },
            resolve: { resolved = $0 }
        ).run()

        guard case .usingLegacyInPlace(let failure) = outcome.data else {
            return XCTFail("expected a legacy-in-place result")
        }
        XCTAssertTrue(failure.description.contains("ShakeBoard path is not a real directory"))
        XCTAssertFalse(renameCalled)
        XCTAssertEqual(resolved, legacyData)
        XCTAssertEqual(try info(shakeBoardData).st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
    }

    func testVerifiedMovedInodeWinsIfOldAppRecreatesLegacyFolderAfterRename() throws {
        try createLegacyDirectory()
        let original = legacyData.appendingPathComponent("shelf.json")
        try Data("migrated".utf8).write(to: original)
        let inode = try info(original).st_ino
        var resolved: URL?
        var logs: [String] = []
        let paths = PerchMigration.Paths(legacyData: legacyData,
                                         shakeBoardData: shakeBoardData,
                                         breadcrumb: breadcrumb)
        let migration = PerchMigration(
            paths: paths,
            rename: { from, to in
                guard Darwin.rename(from.path, to.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try FileManager.default.createDirectory(at: from, withIntermediateDirectories: false)
            },
            preferences: .live(newDefaults: newDefaults, newDomain: newSuite, legacyDomain: oldSuite),
            runningApplications: { [] },
            logger: { logs.append($0) },
            resolveDataDirectory: { resolved = $0 }
        )

        XCTAssertEqual(migration.run().data, .moved)
        XCTAssertEqual(resolved, shakeBoardData)
        XCTAssertEqual(try info(shakeBoardData.appendingPathComponent("shelf.json")).st_ino, inode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyData.path))
        XCTAssertTrue(logs.contains { $0.contains("both folders exist after the move") })
    }

    func testRenameFailureUsesOldFolderInPlaceAndRaisesSettingsAlert() throws {
        try createLegacyDirectory()
        let file = legacyData.appendingPathComponent("shelf.json")
        try Data("keep me".utf8).write(to: file)
        let inode = try info(file).st_ino
        PerchPaths.resolveBase(nil)
        let migration = makeMigration(
            rename: { _, _ in throw POSIXError(.EXDEV) },
            resolve: { PerchPaths.resolveBase($0) }
        )

        let outcome = migration.run()

        guard case .usingLegacyInPlace(let failure) = outcome.data else {
            return XCTFail("expected a legacy-in-place result")
        }
        XCTAssertTrue(failure.description.contains("rename failed"))
        XCTAssertEqual(PerchPaths.base, legacyData)
        XCTAssertEqual(try info(file).st_ino, inode)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shakeBoardData.path))
        var inputs = SettingsAlerts.Inputs()
        inputs.migrationFailure = outcome.legacyFailure
        let alerts = SettingsAlerts.compute(inputs)
        XCTAssertTrue(alerts.contains {
            $0.section == .general
                && $0.text == "ShakeBoard couldn't move your data from the old Perch folder, so it's using it in place. It will try again next launch."
        })
        XCTAssertTrue(SettingsAlerts.needsAttention(alerts))
    }

    func testPreferencesCopyOnlyLegacyDomainWithoutOverwritingAndAreIdempotent() {
        oldDefaults.set("old theme", forKey: "themeSelected")
        oldDefaults.set(7, forKey: "calibReversals")
        oldDefaults.set("old value", forKey: "existing")
        _ = oldDefaults.synchronize()
        newDefaults.set("new value", forKey: "existing")

        // Add an inherited search-list suite. dictionaryRepresentation() would include this key; the exact
        // CFPreferences legacy-domain key list used by the migration must not.
        let inherited = UserDefaults(suiteName: inheritedSuite)!
        inherited.set("must not copy", forKey: "globalOnly")
        oldDefaults.addSuite(named: inheritedSuite)
        XCTAssertEqual(oldDefaults.string(forKey: "globalOnly"), "must not copy")
        let oldKeysBefore = Set((CFPreferencesCopyKeyList(oldSuite as CFString,
                                                          kCFPreferencesCurrentUser,
                                                          kCFPreferencesAnyHost) as? [String]) ?? [])
        let oldValuesBefore = Dictionary(uniqueKeysWithValues: oldKeysBefore.map {
            ($0, String(describing: CFPreferencesCopyValue($0 as CFString, oldSuite as CFString,
                                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)))
        })
        let migration = makeMigration()

        let first = migration.run()

        XCTAssertTrue(first.migratedPreferences)
        XCTAssertEqual(newDefaults.string(forKey: "themeSelected"), "old theme")
        XCTAssertEqual(newDefaults.integer(forKey: "calibReversals"), 7)
        XCTAssertEqual(newDefaults.string(forKey: "existing"), "new value")
        XCTAssertNil(newDefaults.object(forKey: "globalOnly"))
        XCTAssertTrue(newDefaults.bool(forKey: PerchMigration.migratedKey))
        XCTAssertTrue(newDefaults.bool(forKey: PerchMigration.welcomeKey))

        let oldKeysAfterFirst = Set((CFPreferencesCopyKeyList(oldSuite as CFString,
                                                              kCFPreferencesCurrentUser,
                                                              kCFPreferencesAnyHost) as? [String]) ?? [])
        let oldValuesAfterFirst = Dictionary(uniqueKeysWithValues: oldKeysAfterFirst.map {
            ($0, String(describing: CFPreferencesCopyValue($0 as CFString, oldSuite as CFString,
                                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)))
        })
        XCTAssertEqual(oldKeysAfterFirst, oldKeysBefore)
        XCTAssertEqual(oldValuesAfterFirst, oldValuesBefore, "the migration never writes the old domain")

        oldDefaults.set("changed after first migration", forKey: "themeSelected")
        _ = oldDefaults.synchronize()
        let second = migration.run()
        XCTAssertFalse(second.migratedPreferences)
        XCTAssertEqual(newDefaults.string(forKey: "themeSelected"), "old theme")
        XCTAssertEqual(oldDefaults.string(forKey: "themeSelected"), "changed after first migration")
    }
}
