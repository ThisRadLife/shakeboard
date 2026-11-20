//
//  Pinboards.swift
//  ShakeBoard -- ordered, named collections of clips. pinboards.json is the source of truth; ClipPins is the
//  compatibility view of the board carrying the stable `isDefaultPinned` identity.
//

import AppKit
import Combine
import SwiftUI

enum BoardColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, purple, orange, red, teal, pink

    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var nsColor: NSColor {
        switch self {
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .orange: return .systemOrange
        case .red: return .systemRed
        case .teal: return .systemTeal
        case .pink: return .systemPink
        }
    }
    var color: Color { Color(nsColor: nsColor) }
}

struct Pinboard: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var color: BoardColor
    var clipIDs: [UUID]
    var isDefaultPinned: Bool

    init(id: UUID = UUID(), name: String, color: BoardColor, clipIDs: [UUID] = [], isDefaultPinned: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.clipIDs = clipIDs
        self.isDefaultPinned = isDefaultPinned
    }

    private enum CodingKeys: String, CodingKey { case id, name, color, clipIDs, isDefaultPinned }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decode(BoardColor.self, forKey: .color)
        clipIDs = try c.decode([UUID].self, forKey: .clipIDs)
        isDefaultPinned = try c.decodeIfPresent(Bool.self, forKey: .isDefaultPinned) ?? false
    }
}

@MainActor
final class PinboardStore: ObservableObject {
    @Published private(set) var boards: [Pinboard] = []
    @Published private(set) var lastSaveFailed = false
    @Published private(set) var readOnly = false
    @Published private(set) var retentionUnknown = false
    @Published private(set) var setAsideFileName: String?

    let url: URL
    private let legacyURL: URL
    private let clock: () -> Date
    private let moveItem: (URL, URL) throws -> Void
    private static let currentVersion = 1
    private struct File: Codable { var version: Int; var boards: [Pinboard] }
    private struct LegacyFile: Codable { var version: Int; var ids: [UUID] }

    // Called only after a successful mutation releases one or more memberships.
    var onRetentionReleased: () -> Void = { }

    init(baseDir: URL = PerchPaths.base, clock: @escaping () -> Date = Date.init,
         moveItem: @escaping (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) {
        url = baseDir.appendingPathComponent("pinboards.json")
        legacyURL = baseDir.appendingPathComponent("clip-pins.json")
        self.clock = clock
        self.moveItem = moveItem
    }

    var defaultBoard: Pinboard? { boards.first { $0.isDefaultPinned } }
    var defaultBoardID: UUID? { defaultBoard?.id }
    var allClipIDs: Set<UUID> { Set(boards.flatMap(\.clipIDs)) }

    func board(_ id: UUID) -> Pinboard? { boards.first { $0.id == id } }
    func boards(containing clipID: UUID) -> [Pinboard] { boards.filter { $0.clipIDs.contains(clipID) } }
    func contains(_ clipID: UUID, in boardID: UUID) -> Bool { board(boardID)?.clipIDs.contains(clipID) == true }

    func load() {
        readOnly = false
        retentionUnknown = false
        setAsideFileName = nil
        lastSaveFailed = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { migrateAndPersist(); return }
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version <= Self.currentVersion,
              let clean = Self.sanitize(file.boards) else {
            guard let setAsideFileName = quarantine() else {
                boards = []
                readOnly = true
                retentionUnknown = true
                lastSaveFailed = true
                return
            }
            migrateAndPersist()
            retentionUnknown = true
            self.setAsideFileName = setAsideFileName
            return
        }
        boards = clean
        _ = enforcePrivatePermissions()
    }

    @discardableResult
    func create(name: String, color: BoardColor, clipIDs: [UUID] = []) -> UUID? {
        let cleanName = Self.cleanName(name)
        guard !cleanName.isEmpty else { return nil }
        let id = UUID()
        let unique = Self.unique(clipIDs)
        guard commit({ $0.append(Pinboard(id: id, name: cleanName, color: color, clipIDs: unique)) }) else { return nil }
        return id
    }

    @discardableResult
    func rename(_ id: UUID, to name: String) -> Bool {
        let clean = Self.cleanName(name)
        guard !clean.isEmpty, let current = board(id) else { return false }
        if current.name == clean { return true }
        return commit { value in
            guard let i = value.firstIndex(where: { $0.id == id }) else { return }
            value[i].name = clean
        }
    }

    @discardableResult
    func setColor(_ id: UUID, to color: BoardColor) -> Bool {
        guard let current = board(id) else { return false }
        if current.color == color { return true }
        return commit { value in
            guard let i = value.firstIndex(where: { $0.id == id }) else { return }
            value[i].color = color
        }
    }

    @discardableResult
    func moveBoard(_ id: UUID, by delta: Int) -> Bool {
        guard let i = boards.firstIndex(where: { $0.id == id }), boards.indices.contains(i + delta) else { return false }
        return commit { $0.swapAt(i, i + delta) }
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard let i = boards.firstIndex(where: { $0.id == id }), !boards[i].isDefaultPinned else { return false }
        guard commit({ $0.remove(at: i) }) else { return false }
        onRetentionReleased()
        return true
    }

    // New memberships land as one ordered block at the front. Existing membership never moves.
    @discardableResult
    func add(_ clipIDs: [UUID], to boardID: UUID) -> Bool {
        let incoming = Self.unique(clipIDs)
        guard let current = board(boardID) else { return false }
        let new = incoming.filter { !current.clipIDs.contains($0) }
        guard !new.isEmpty else { return true }
        return commit { value in
            guard let i = value.firstIndex(where: { $0.id == boardID }) else { return }
            value[i].clipIDs.insert(contentsOf: new, at: 0)
        }
    }

    @discardableResult
    func remove(_ clipIDs: [UUID], from boardID: UUID) -> Bool {
        let removing = Set(clipIDs)
        guard let current = board(boardID), current.clipIDs.contains(where: removing.contains) else { return true }
        guard commit({ value in
            guard let i = value.firstIndex(where: { $0.id == boardID }) else { return }
            value[i].clipIDs.removeAll { removing.contains($0) }
        }) else { return false }
        onRetentionReleased()
        return true
    }

    @discardableResult
    func toggle(_ clipIDs: [UUID], in boardID: UUID) -> Bool {
        let ids = Self.unique(clipIDs)
        guard !ids.isEmpty, let target = board(boardID) else { return false }
        return ids.allSatisfy { target.clipIDs.contains($0) }
            ? remove(ids, from: boardID) : add(ids, to: boardID)
    }

    // Used by clip deletion: all memberships leave in one transaction, so a write failure cannot partly unprotect it.
    @discardableResult
    func removeFromAll(_ clipID: UUID) -> Bool {
        guard boards.contains(where: { $0.clipIDs.contains(clipID) }) else { return true }
        guard commit({ value in
            for i in value.indices { value[i].clipIDs.removeAll { $0 == clipID } }
        }) else { return false }
        onRetentionReleased()
        return true
    }

    @discardableResult
    func moveClip(_ clipID: UUID, to destination: Int, in boardID: UUID) -> Bool {
        guard let board = board(boardID), let source = board.clipIDs.firstIndex(of: clipID) else { return false }
        let target = min(max(destination, 0), max(board.clipIDs.count - 1, 0))
        guard source != target else { return true }
        return commit { value in
            guard let i = value.firstIndex(where: { $0.id == boardID }) else { return }
            let id = value[i].clipIDs.remove(at: source)
            value[i].clipIDs.insert(id, at: target)
        }
    }

    @discardableResult
    func moveClip(_ clipID: UUID, before targetID: UUID, in boardID: UUID) -> Bool {
        guard let b = board(boardID), let source = b.clipIDs.firstIndex(of: clipID),
              let target = b.clipIDs.firstIndex(of: targetID) else { return false }
        return moveClip(clipID, to: source < target ? target - 1 : target, in: boardID)
    }

    func prune(keeping existing: Set<UUID>) {
        guard !retentionUnknown else { return }
        guard boards.contains(where: { !$0.clipIDs.allSatisfy(existing.contains) }) else { return }
        if commit({ value in
            for i in value.indices { value[i].clipIDs.removeAll { !existing.contains($0) } }
        }) { onRetentionReleased() }
    }

    private func migrateAndPersist() {
        var ids: [UUID] = []
        if let data = try? Data(contentsOf: legacyURL),
           let legacy = try? JSONDecoder().decode(LegacyFile.self, from: data), legacy.version <= 1 {
            ids = Self.unique(legacy.ids)
        }
        boards = [Pinboard(name: "Pinned", color: .yellow, clipIDs: ids, isDefaultPinned: true)]
        if !save() { lastSaveFailed = true }
    }

    private func quarantine() -> String? {
        let fm = FileManager.default
        let base = url.deletingLastPathComponent()
        let stamp = Int(clock().timeIntervalSince1970)
        var aside = base.appendingPathComponent("pinboards.json.unreadable-\(stamp)")
        var suffix = 2
        while fm.fileExists(atPath: aside.path) {
            aside = base.appendingPathComponent("pinboards.json.unreadable-\(stamp)-\(suffix)")
            suffix += 1
        }
        guard (try? moveItem(url, aside)) != nil else { return nil }
        return aside.lastPathComponent
    }

    private func commit(_ mutation: (inout [Pinboard]) -> Void) -> Bool {
        guard !readOnly else { lastSaveFailed = true; return false }
        let old = boards
        var next = old
        mutation(&next)
        guard next != old else { return false }
        boards = next
        guard save() else { boards = old; return false }
        return true
    }

    private func save() -> Bool {
        guard !readOnly else { lastSaveFailed = true; return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(File(version: Self.currentVersion, boards: boards)) else {
            lastSaveFailed = true
            return false
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let wrote = (try? data.write(to: url, options: .atomic)) != nil
        let ok = wrote && enforcePrivatePermissions()
        lastSaveFailed = !ok
        return ok
    }

    private func enforcePrivatePermissions() -> Bool {
        let fm = FileManager.default
        do {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let attributes = try fm.attributesOfItem(atPath: url.path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o777 == 0o600 else {
                NSLog("ShakeBoard: pinboards.json permissions could not be verified as 0600")
                return false
            }
            return true
        } catch {
            NSLog("ShakeBoard: pinboards.json permissions could not be set to 0600: \(error)")
            return false
        }
    }

    private static func sanitize(_ input: [Pinboard]) -> [Pinboard]? {
        guard input.filter(\.isDefaultPinned).count == 1 else { return nil }
        var boardIDs = Set<UUID>()
        var out: [Pinboard] = []
        for var board in input {
            guard boardIDs.insert(board.id).inserted else { return nil }
            board.name = cleanName(board.name)
            guard !board.name.isEmpty else { return nil }
            board.clipIDs = unique(board.clipIDs)
            out.append(board)
        }
        return out
    }

    private static func cleanName(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines).prefix(60).description
    }

    private static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }
}

enum PinboardShortcut {
    static func boardID(for number: Int, in boards: [Pinboard]) -> UUID? {
        let index = number - 1
        return boards.indices.contains(index) ? boards[index].id : nil
    }
}

// Existing pin callers keep their API, but their state is the stable default board in PinboardStore.
@MainActor
final class ClipPins: ObservableObject {
    let store: PinboardStore
    private var bag: AnyCancellable?
    var onUnpinned: (() -> Void)?

    init(baseDir: URL = PerchPaths.base) { self.store = PinboardStore(baseDir: baseDir); observe() }
    init(store: PinboardStore) { self.store = store; observe() }

    private func observe() {
        bag = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var url: URL { store.url }
    var ids: [UUID] { store.defaultBoard?.clipIDs ?? [] }
    var set: Set<UUID> { Set(ids) }
    var lastSaveFailed: Bool { store.lastSaveFailed }
    func isPinned(_ id: UUID) -> Bool { ids.contains(id) }
    func load() { store.load() }

    @discardableResult
    func pin(_ id: UUID) -> Bool {
        guard let board = store.defaultBoardID else { return false }
        return store.add([id], to: board)
    }
    @discardableResult
    func unpin(_ id: UUID) -> Bool {
        guard let board = store.defaultBoardID else { return false }
        let had = isPinned(id)
        guard store.remove([id], from: board) else { return false }
        if had { onUnpinned?() }
        return true
    }
    @discardableResult
    func toggle(_ id: UUID) -> Bool { isPinned(id) ? unpin(id) : pin(id) }
    func prune(keeping existing: Set<UUID>) { store.prune(keeping: existing) }
}
