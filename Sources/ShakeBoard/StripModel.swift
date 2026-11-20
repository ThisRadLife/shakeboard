//
//  StripModel.swift
//  ShakeBoard v2 -- the pure pieces behind the unified bottom strip: what kind of card a clip is (text, code,
//  link, rich text, image, files), a small dependency-free code highlighter, default-board pin state,
//  pinboard filtering, and how the strip's sections (Pinned / Shelf / Recent) are built from the stores.
//
//  Storage is deliberately unchanged: shelf files stay in ShelfModel (shelf.json bookmarks), copies stay in
//  ClipStore (Clips/). The strip only composes them. Pinboards live in their own small file next to shelf.json --
//  NOT inside Clips/, whose launch reconcile deletes anything the clips index doesn't own.
//

import AppKit
import SwiftUI

// MARK: - Card kinds

enum CardKind: Equatable {
    case text, richText, code(String), link, image, files

    var label: String {
        switch self {
        case .text: return "Text"
        case .richText: return "Text"
        case .code: return "Code"
        case .link: return "Link"
        case .image: return "Image"
        case .files: return "File"
        }
    }
    var symbol: String {
        switch self {
        case .text, .richText: return "textformat"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .link: return "link"
        case .image: return "photo"
        case .files: return "doc"
        }
    }
    var isCode: Bool { if case .code = self { return true }; return false }
}

// Display classification only -- nothing here is persisted. `head` is the start of the clip's plain text
// (newlines kept), or the collapsed preview until the head has been read from disk.
enum ClipClassifier {
    static func kind(of clip: Clip, head: String?) -> CardKind {
        switch clip.kind {
        case .image: return .image
        case .files: return .files
        case .url: return .link
        case .text:
            let text = head ?? clip.preview
            if ClipNormalizer.isSingleWebURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return .link }
            if let lang = CodeDetector.language(of: text) { return .code(lang) }
            let rich = clip.reps.contains { $0.type == ClipTypes.rtf || $0.type == ClipTypes.html }
            return rich ? .richText : .text
        }
    }
}

// MARK: - Code detection (heuristic, local, cheap)

enum CodeDetector {
    private struct Lang { let name: String; let patterns: [NSRegularExpression] }
    private static func rx(_ s: [String]) -> [NSRegularExpression] {
        s.compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
    }
    // Order breaks ties (first wins).
    private static let langs: [Lang] = [
        Lang(name: "Swift", patterns: rx([#"\bfunc \w+\s*[(<]"#, #"\b(let|var) \w+(\s*:\s*[\w\[\]?<>, ]+)?\s*="#,
                                          #"\bguard\b.*\belse\b"#, #"^\s*import (SwiftUI|Foundation|AppKit|UIKit|Combine|XCTest)\b"#,
                                          #"\)\s*->\s*[\w\[(]"#, #"@(MainActor|State|Published|objc|ObservedObject|discardableResult)\b"#,
                                          #"\b(struct|enum|extension|protocol) \w+.*\{"#, #"\bif let \w+"#])),
        Lang(name: "Python", patterns: rx([#"^\s*def \w+\(.*\)\s*(->\s*[\w\[\], ]+)?:\s*$"#, #"^\s*from [\w.]+ import \w+"#,
                                           #"\bself\.\w+"#, #"^\s*(elif|except|with|for|while|if) .*:\s*$"#,
                                           #"\bprint\("#, #"^\s*class \w+(\(.*\))?:\s*$"#, #"^\s*import [a-z_][\w.]*\s*$"#])),
        Lang(name: "Go", patterns: rx([#"^package \w+"#, #"\bfunc (\(\w+ \*?\w+\) )?\w+\("#, #"\w+ :="#, #"\bfmt\.\w+\("#])),
        Lang(name: "Rust", patterns: rx([#"\bfn \w+\s*[(<]"#, #"\blet mut\b"#, #"^\s*impl\b"#, #"\bpub (fn|struct|enum)\b"#,
                                         #"\b\w+!\("#, #"\buse \w+::"#])),
        Lang(name: "TypeScript", patterns: rx([#"\binterface \w+\s*\{"#, #"\w+\??:\s*(string|number|boolean|any)\b"#,
                                               #"\btype \w+\s*="#, #"\b(const|let) \w+\s*(:\s*\w+)?\s*="#, #"=>"#])),
        Lang(name: "JavaScript", patterns: rx([#"\b(const|let|var) \w+\s*="#, #"\bfunction\s*\w*\s*\("#, #"=>"#,
                                               #"\bconsole\.\w+\("#, #"^\s*(export|import) .*from\s+['"]"#,
                                               #"\b(document|window)\.\w+"#, #"===|!=="#])),
        Lang(name: "CSS", patterns: rx([#"^\s*[.#]?[a-zA-Z][\w-]*([\s>+~.#:][\w-]+)*\s*\{\s*$"#, #"^\s*[a-z-]+\s*:\s*[^;]+;\s*$"#])),
    ]
    private static let shellCommands: Set<String> = [
        "git", "npm", "npx", "yarn", "pnpm", "brew", "cd", "ls", "curl", "wget", "tuist", "xcodebuild", "python",
        "python3", "pip", "pip3", "docker", "ssh", "scp", "make", "rm", "mkdir", "cp", "mv", "export", "echo",
        "grep", "sed", "awk", "chmod", "chown", "codex", "claude", "gh", "kill", "pkill", "ps", "tail", "swift",
        "cargo", "node", "deno", "bun", "sudo", "defaults", "launchctl", "xcrun", "rsync", "tar", "unzip", "pytest",
        "railway", "tailscale", "codesign", "security", "osascript", "pbcopy", "jq", "rg", "find", "cat", "open",
    ]
    private static let sql = rx([#"(?i)^\s*(select|insert|update|delete|create|alter|drop|with)\b"#,
                                 #"(?i)\b(from|into|set|table|where|join|values|group by|order by)\b"#])

    // A language label for code, or nil for prose.
    static func language(of raw: String) -> String? {
        let text = String(raw.prefix(4000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4 else { return nil }
        if isJSON(text) { return "JSON" }
        if isShell(text) { return "Shell" }
        if text.hasPrefix("<"), text.contains("</") || text.lowercased().hasPrefix("<!doctype") { return "HTML" }
        let range = NSRange(text.startIndex..., in: text)
        if sql.allSatisfy({ $0.firstMatch(in: text, range: range) != nil }), symbolDensity(text) < 0.2 {
            return "SQL"
        }
        var best: (String, Int)?
        for lang in langs {
            let score = lang.patterns.filter { $0.firstMatch(in: text, range: range) != nil }.count
            if score > (best?.1 ?? 0) { best = (lang.name, score) }
        }
        guard let (name, score) = best else { return looksLikeCode(text) ? "Code" : nil }
        // Two independent signals, or one plus code-shaped text. A single keyword in prose isn't code.
        if score >= 2 || (score == 1 && looksLikeCode(text)) {
            // TypeScript also matches the JavaScript patterns; only call it TS with a type annotation.
            return name
        }
        return looksLikeCode(text) ? "Code" : nil
    }

    static func isJSON(_ text: String) -> Bool {
        guard let f = text.first, let l = text.last, (f == "{" && l == "}") || (f == "[" && l == "]"),
              let d = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: d)) != nil
    }

    static func isShell(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard let first = lines.first, lines.count <= 30 else { return false }
        var line = first.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("$ ") { return true }
        if line.hasPrefix("#!/") { return true }
        if line.hasPrefix("sudo ") { line.removeFirst(5) }
        let cmd = line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? line
        guard shellCommands.contains(cmd) else { return false }
        // "open the door." / "find the receipt" are prose: require something command-shaped.
        let rest = line.dropFirst(cmd.count)
        let shaped = rest.isEmpty || rest.contains(" -") || rest.contains("/") || rest.contains("|")
            || rest.contains("&&") || rest.contains("=") || rest.contains("~") || rest.contains("\"") || rest.contains("'")
        let prose = line.hasSuffix(".") && line.split(separator: " ").count > 3
        return shaped && !prose
    }

    static func symbolDensity(_ text: String) -> Double {
        let syms = text.filter { "{}[]();=<>|&*$#@".contains($0) }.count
        return Double(syms) / Double(max(text.count, 1))
    }

    // Generic "is this code-shaped": several lines, many ending in code punctuation or indented.
    static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else { return symbolDensity(text) > 0.12 && !text.contains(". ") }
        let codey = lines.filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.hasSuffix("{") || t.hasSuffix("}") || t.hasSuffix(";") || t.hasSuffix(")") || t.hasSuffix(",")
                || t.hasPrefix("//") || t.hasPrefix("#") || l.hasPrefix("    ") || l.hasPrefix("\t")
        }.count
        return Double(codey) / Double(lines.count) >= 0.5 && symbolDensity(text) > 0.03
    }
}

// MARK: - Highlighter (keywords / strings / comments / numbers -- no dependency)

enum CodeToken: Equatable { case plain, keyword, string, comment, number }

enum CodeHighlighter {
    static let keywords: [String: Set<String>] = [
        "Swift": ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "case", "switch",
                  "for", "in", "while", "import", "extension", "protocol", "private", "public", "static", "self",
                  "nil", "true", "false", "init", "throws", "try", "await", "async", "where", "defer", "some"],
        "Python": ["def", "class", "import", "from", "as", "return", "if", "elif", "else", "for", "while", "in",
                   "not", "and", "or", "None", "True", "False", "with", "try", "except", "self", "lambda", "yield"],
        "JavaScript": ["const", "let", "var", "function", "return", "if", "else", "for", "while", "import", "export",
                       "from", "class", "new", "this", "null", "undefined", "true", "false", "async", "await"],
        "Go": ["package", "import", "func", "return", "if", "else", "for", "range", "var", "const", "type",
               "struct", "nil", "true", "false", "go", "defer"],
        "Rust": ["fn", "let", "mut", "pub", "impl", "struct", "enum", "use", "match", "if", "else", "return",
                 "self", "Self", "true", "false", "for", "in", "loop", "while"],
        "SQL": ["select", "from", "where", "insert", "into", "update", "set", "delete", "create", "table", "join",
                "on", "and", "or", "not", "null", "group", "by", "order", "limit", "as", "values", "with"],
        "Shell": ["if", "then", "else", "fi", "for", "do", "done", "export", "sudo", "cd", "echo", "in"],
        "JSON": ["true", "false", "null"],
    ]
    static func keywordSet(_ lang: String) -> Set<String> {
        if lang == "TypeScript" { return keywords["JavaScript"]!.union(["interface", "type", "string", "number", "boolean"]) }
        return keywords[lang] ?? keywords["Swift"]!.union(keywords["JavaScript"]!)
    }
    static func hashComments(_ lang: String) -> Bool { ["Python", "Shell"].contains(lang) }

    // Token runs over `text` (UTF-16 offsets would be overkill for a card: Character indices are fine).
    static func tokenize(_ text: String, language lang: String) -> [(String, CodeToken)] {
        let kw = keywordSet(lang)
        let caseless = lang == "SQL"
        let chars = Array(text)
        var out: [(String, CodeToken)] = []
        var i = 0
        func emit(_ s: String, _ t: CodeToken) {
            if let last = out.last, last.1 == t { out[out.count - 1].0 += s } else { out.append((s, t)) }
        }
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            // Comments to end of line.
            if (c == "/" && next == "/" && !hashComments(lang)) || (c == "#" && hashComments(lang))
                || (c == "-" && next == "-" && lang == "SQL") {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                emit(String(chars[i..<j]), .comment); i = j; continue
            }
            if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < chars.count, !(chars[j] == "*" && chars[j + 1] == "/") { j += 1 }
                j = min(j + 2, chars.count)
                emit(String(chars[i..<j]), .comment); i = j; continue
            }
            if c == "\"" || c == "'" || c == "`" {
                var j = i + 1
                while j < chars.count, chars[j] != c, chars[j] != "\n" { j += chars[j] == "\\" ? 2 : 1 }
                j = min(j + 1, chars.count)
                emit(String(chars[i..<j]), .string); i = j; continue
            }
            if c.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "_" { j += 1 }
                emit(String(chars[i..<j]), .number); i = j; continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                emit(word, kw.contains(caseless ? word.lowercased() : word) ? .keyword : .plain); i = j; continue
            }
            emit(String(c), .plain); i += 1
        }
        return out
    }

    static func attributed(_ text: String, language: String) -> AttributedString {
        var out = AttributedString()
        for (s, t) in tokenize(text, language: language) {
            var a = AttributedString(s)
            switch t {
            case .keyword: a.foregroundColor = Color(nsColor: .systemPurple)
            case .string: a.foregroundColor = Color(nsColor: .systemRed)
            case .comment: a.foregroundColor = .secondary
            case .number: a.foregroundColor = Color(nsColor: .systemBlue)
            case .plain: break
            }
            out += a
        }
        return out
    }
}

// MARK: - Link display (from the copied text / HTML; never fetched)

enum LinkInfo {
    // Host and path of the first web URL in `text`.
    static func parts(_ text: String) -> (host: String, path: String)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? t),
              let host = u.host else { return nil }
        let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var path = u.path
        if let q = u.query, !q.isEmpty { path += "?" + q }
        return (h, path)
    }
    // A human title from copied HTML: the anchor text, else <title>. Tags stripped, entities decoded.
    static func title(fromHTML html: String) -> String? {
        for pattern in [#"<a\b[^>]*>(.*?)</a>"#, #"<title[^>]*>(.*?)</title>"#] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let r = Range(m.range(at: 1), in: html) else { continue }
            let inner = String(html[r]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            var t = inner
            for (e, s) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
                t = t.replacingOccurrences(of: e, with: s)
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            // An anchor whose text is just the URL again isn't a title.
            if !t.isEmpty, URL(string: t)?.host == nil { return String(t.prefix(200)) }
        }
        return nil
    }
}

// MARK: - Sections + search (pure)

enum StripFilter: String, CaseIterable, Identifiable {
    case all = "All", text = "Text", code = "Code", links = "Links", images = "Images", files = "Files"
    // Not a card kind: shows the stacks (active + finished/archived) instead of cards.
    case stacks = "Stacks"
    var id: String { rawValue }

    func matches(_ kind: CardKind) -> Bool {
        switch self {
        case .all: return true
        case .text: return kind == .text || kind == .richText
        case .code: return kind.isCode
        case .links: return kind == .link
        case .images: return kind == .image
        case .files: return kind == .files
        case .stacks: return false
        }
    }
    // Shelf files: images count as Images, everything counts as Files.
    func matchesShelfFile(isImage: Bool) -> Bool {
        switch self {
        case .all, .files: return true
        case .images: return isImage
        default: return false
        }
    }
}

enum CardID: Hashable {
    case file(UUID), clip(UUID)
}

struct StripSections: Equatable {
    var board: [Clip] = []
    var pinned: [Clip] = []
    var files: [ShelfItem] = []
    var recent: [Clip] = []

    // Visible order -- what arrows walk and 1-9 index.
    var order: [CardID] {
        board.map { .clip($0.id) } + pinned.map { .clip($0.id) }
            + files.map { .file($0.id) } + recent.map { .clip($0.id) }
    }
    var isEmpty: Bool { board.isEmpty && pinned.isEmpty && files.isEmpty && recent.isEmpty }

    static func == (a: StripSections, b: StripSections) -> Bool { a.order == b.order }

    static let maxRecent = 80

    static func buildBoard(clips: [Clip], ids: [UUID], query: String,
                           kind: (Clip) -> CardKind, text: (Clip) -> String?,
                           ocr: (Clip) -> String?) -> StripSections {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let byID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func matches(_ c: Clip) -> Bool {
            guard !q.isEmpty else { return true }
            let k = kind(c)
            if c.preview.lowercased().contains(q) { return true }
            if let t = text(c), t.lowercased().contains(q) { return true }
            if let t = ocr(c), t.contains(q) { return true }
            if c.sourceAppName?.lowercased().contains(q) == true { return true }
            if k.label.lowercased() == q { return true }
            if case .code(let language) = k, language.lowercased() == q { return true }
            return false
        }
        return StripSections(board: ids.compactMap { byID[$0] }.filter(matches))
    }

    // `hideImageClips`: copied images are already on the shelf as files (Add Copied Images to Shelf), so
    // their clips would show twice -- Recent leaves them out (pinned ones still show).
    static func build(clips: [Clip], pins: [UUID], files: [ShelfItem], query: String, filter: StripFilter,
                      hideImageClips: Bool, kind: (Clip) -> CardKind, text: (Clip) -> String?,
                      ocr: (Clip) -> String?, fileOCR: (ShelfItem) -> String?,
                      isImageFile: (ShelfItem) -> Bool) -> StripSections {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let byID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinSet = Set(pins)
        func clipMatches(_ c: Clip) -> Bool {
            let k = kind(c)
            guard filter.matches(k) else { return false }
            guard !q.isEmpty else { return true }
            if c.preview.lowercased().contains(q) { return true }
            if let t = text(c), t.lowercased().contains(q) { return true }
            if let t = ocr(c), t.contains(q) { return true }
            if c.sourceAppName?.lowercased().contains(q) == true { return true }
            if k.label.lowercased() == q { return true }
            if case .code(let lang) = k, lang.lowercased() == q { return true }
            return false
        }
        var s = StripSections()
        s.pinned = pins.compactMap { byID[$0] }.filter(clipMatches)
        s.files = files.filter { f in
            filter.matchesShelfFile(isImage: isImageFile(f))
                && (q.isEmpty || f.url.lastPathComponent.lowercased().contains(q)
                    || fileOCR(f)?.contains(q) == true)
        }
        s.recent = Array(clips.filter { c in
            !pinSet.contains(c.id) && !(hideImageClips && c.kind == .image) && clipMatches(c)
        }.prefix(maxRecent))
        return s
    }
}

extension ShelfItem: Equatable {
    static func == (a: ShelfItem, b: ShelfItem) -> Bool {
        a.id == b.id && a.url == b.url && a.missing == b.missing && a.ownedCopy == b.ownedCopy
    }
}

// Short relative age for card footers.
enum Age {
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        if s < 7 * 86400 { return "\(s / 86400)d" }
        return "\(s / (7 * 86400))w"
    }
}

// MARK: - Ordered multi-select (Command-click order is the send order)

// Copies picked with Command-click / Shift-click, in the order they were picked -- an ordered list, not a set,
// because "Send to Stack" appends them in exactly this order. Only copies (clips) are pickable: a stack holds
// clips, never shelf files.
struct ClipPicks: Equatable {
    private(set) var ids: [UUID] = []
    // Where the next Shift-click range starts: the last card clicked (picked or unpicked).
    private(set) var anchor: UUID?

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
    // 1-based place in the send order, for the card badge.
    func position(of id: UUID) -> Int? { ids.firstIndex(of: id).map { $0 + 1 } }

    // Command-click. The first Command-click keeps the card that was already selected (Finder does the same),
    // so `seed` -- the cursor's copy -- becomes #1 and the clicked card #2. Clicking a picked card unpicks it and
    // the rest renumber.
    mutating func toggle(_ id: UUID, seed: UUID? = nil) {
        if ids.isEmpty, let seed, seed != id { ids = [seed] }
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
        anchor = id
    }

    // Shift-click: every copy between the anchor and `id`, in the strip's visible (left-to-right) order, is appended after what's
    // already picked (cards already picked keep their number). With nothing picked yet the range starts at
    // `seed` (the selected card).
    mutating func extend(to id: UUID, visible: [UUID], seed: UUID? = nil) {
        let from = anchor.flatMap { a in visible.contains(a) ? a : nil } ?? seed.flatMap { s in visible.contains(s) ? s : nil }
        guard let to = visible.firstIndex(of: id) else { return }
        let start = from.flatMap { visible.firstIndex(of: $0) } ?? to
        let range = visible[min(start, to)...max(start, to)]       // always left to right, as the strip reads
        for r in range where !ids.contains(r) { ids.append(r) }
        anchor = id
    }

    mutating func clear() { ids = []; anchor = nil }

    // Drop copies that left history (deleted, evicted, Clear History); the rest renumber.
    mutating func retain(_ live: Set<UUID>) {
        ids.removeAll { !live.contains($0) }
        if let a = anchor, !live.contains(a) { anchor = nil }
    }
}
