//
//  Stacks.swift
//  ShakeBoard -- the pure pieces behind multiple paste stacks: the stack model and its file (stacks.json, next to
//  shelf.json), and the "Split into Stack" splitter. The live state machine (collect / ready / Cmd-V) is
//  PasteStack.swift; the UI is StackLane (Strip.swift) and the bar under the menu bar (PasteStack.swift).
//
//  A stack holds clip ids (occurrences, each with its own token), never copies of the data -- the clips live in
//  ClipStore like any other copy, and every clip a stack (active or archived) references is protected from
//  history retention and Clear History, the same as a pin.
//

import Foundation

struct StackSlot: Codable, Equatable {
    var token = UUID()
    var clip: UUID
}

struct ClipStack: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var slots: [StackSlot] = []
    var createdAt: Date
    var archivedAt: Date?          // set when it finished pasting (or was archived by hand)
    var pastedCount: Int?          // how many it pasted in the run that archived it

    var clipIDs: [UUID] { slots.map(\.clip) }
}

// stacks.json: { version, active, archived }. Which stack is collecting / ready is NOT stored -- every launch
// starts Idle, so a crash can never leave a stack silently capturing or rewriting the clipboard.
struct StackFile: Codable, Equatable {
    var version = 1
    var active: [ClipStack] = []
    var archived: [ClipStack] = []

    static let maxArchived = 30

    enum LoadResult: Equatable { case missing, loaded(StackFile), setAside, failed }

    // missing = fresh install. Undecodable or from a newer ShakeBoard: moved aside (never overwritten) -> start empty.
    // A file that exists but can't be read, or can't be moved aside, is `failed`: the caller must not write over it.
    static func load(from url: URL) -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .failed }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let f = try? dec.decode(StackFile.self, from: data), f.version <= 1 { return .loaded(f) }
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("stacks.json.unreadable-\(Int(Date().timeIntervalSince1970))")
        guard (try? fm.moveItem(at: url, to: aside)) != nil else { return .failed }
        return .setAside
    }

    func save(to url: URL) -> Bool {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}

// MARK: - Split into Stack

enum SplitMode: String, CaseIterable, Identifiable {
    case lines, tabs, commas
    var id: String { rawValue }
    var menuTitle: String {
        switch self { case .lines: return "By Line"; case .tabs: return "By Tab"; case .commas: return "By Comma" }
    }
    func unit(_ n: Int) -> String {
        let one: String, many: String
        switch self {
        case .lines: (one, many) = ("line", "lines")
        case .tabs: (one, many) = ("cell", "cells")
        case .commas: (one, many) = ("item", "items")
        }
        return "\(n) \(n == 1 ? one : many)"
    }
}

enum StackSplitter {
    static let maxPieces = 50       // = PasteStack.maxItems

    // The mode "Split into Stack" offers on its own, or nil when no sensible split gives 2+ pieces:
    // several lines -> lines; one TSV row -> cells; a short list -> comma (or semicolon) items; prose -> nil.
    static func detect(_ text: String) -> SplitMode? {
        if split(text, .lines).count >= 2 { return .lines }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.contains("\t"), split(line, .tabs).count >= 2 { return .tabs }
        if looksLikeList(line), autoListPieces(line).count >= 2 { return .commas }
        return nil
    }

    // Pieces for the auto-detected mode (what the plain menu item creates).
    static func autoSplit(_ text: String) -> (mode: SplitMode, pieces: [String])? {
        guard let mode = detect(text) else { return nil }
        let pieces = mode == .commas ? autoListPieces(text.trimmingCharacters(in: .whitespacesAndNewlines)) : split(text, mode)
        return (mode, pieces)
    }

    // A forced split. Pieces are trimmed; empty pieces are dropped.
    static func split(_ text: String, _ mode: SplitMode) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let raw: [String]
        switch mode {
        case .lines: raw = normalized.components(separatedBy: "\n")
        case .tabs: raw = normalized.components(separatedBy: CharacterSet(charactersIn: "\t\n"))
        case .commas: raw = csvFields(normalized.replacingOccurrences(of: "\n", with: ","), separator: ",")
        }
        return raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // Auto list split: semicolons win when present (they're the stronger separator), else commas.
    private static func autoListPieces(_ line: String) -> [String] {
        let sep: Character = line.contains(";") ? ";" : ","
        return csvFields(line, separator: sep).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // A one-line list, not prose: has a separator, no sentence breaks inside, and short pieces.
    static func looksLikeList(_ line: String) -> Bool {
        guard !line.contains("\n"), line.contains(",") || line.contains(";") else { return false }
        // "Hi John, how are you? I'm fine." -- several sentences stay one piece.
        if line.range(of: #"[.!?]["')\]]?\s+\S"#, options: .regularExpression) != nil { return false }
        let pieces = autoListPieces(line)
        guard pieces.count >= 2 else { return false }
        let words = pieces.map { $0.split(whereSeparator: { $0.isWhitespace }).count }
        // Lists are short items; a clause-y sentence ("When I got there, the door was open") isn't.
        return words.max()! <= 6 && Double(words.reduce(0, +)) / Double(words.count) <= 4
    }

    // Simple CSV: double-quoted fields may contain the separator; "" inside quotes is a literal quote.
    static func csvFields(_ s: String, separator: Character) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuotes = false
        var chars = Array(s)[...]
        while let c = chars.popFirst() {
            if inQuotes {
                if c == "\"" {
                    if chars.first == "\"" { cur.append("\""); chars.removeFirst() } else { inQuotes = false }
                } else { cur.append(c) }
            } else if c == "\"" && cur.trimmingCharacters(in: .whitespaces).isEmpty {
                cur = ""; inQuotes = true
            } else if c == separator {
                out.append(cur); cur = ""
            } else { cur.append(c) }
        }
        out.append(cur)
        return out
    }

    // Menu label for the auto mode, e.g. "Split into Stack (12 lines)". nil = don't offer it.
    static func menuLabel(_ text: String) -> String? {
        guard let (mode, pieces) = autoSplit(text) else { return nil }
        let n = pieces.count
        return n > maxPieces ? "Split into Stack (first \(maxPieces) of \(mode.unit(n)))" : "Split into Stack (\(mode.unit(n)))"
    }
}
