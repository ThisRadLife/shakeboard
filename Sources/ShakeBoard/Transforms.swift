//
//  Transforms.swift
//  ShakeBoard v2 -- card transforms (Plain text, Trim, Case, JSON pretty/minify, strip URL tracking, Markdown link).
//
//  Pure string functions: no pasteboard, no disk. A transform never changes the clip it came from -- the
//  strip saves the result as a NEW clip (StripController.saveDerived). `apply` returns nil when the
//  transform doesn't fit the input or wouldn't change anything. `available` is the cheap version the
//  menu uses: linear scans only, never a full reformat, so building a context menu stays instant.
//

import Foundation

// What a transform needs to know about a card: its text (one item), how it's shown, whether the copy
// carried rich data (RTF/HTML) that "Plain text" would drop, and its URL representation if it had one (a
// rich hyperlink copies as the label text plus the URL).
struct TransformInput: Equatable {
    let text: String
    let kind: CardKind
    let hasRich: Bool
    let linkTitle: String?
    let itemCount: Int
    var url: String? = nil
    // false: `text` is only the start of the clip (the in-memory head), so checks that depend on the whole
    // text answer optimistically and the run itself decides.
    var complete = true
}

enum ClipTransform: String, CaseIterable, Identifiable {
    case plainText, trim, uppercase, lowercase, titleCase, jsonPretty, jsonMinify, stripTracking, markdownLink

    var id: String { rawValue }

    // Results are clips, so they share the text cap.
    static let maxOutputBytes = ClipLimits.maxTextBytes

    var title: String {
        switch self {
        case .plainText: return "Plain Text"
        case .trim: return "Trim Whitespace"
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        case .jsonPretty: return "JSON Pretty"
        case .jsonMinify: return "JSON Minify"
        case .stripTracking: return "Strip Tracking Params"
        case .markdownLink: return "Markdown Link"
        }
    }
    // Shown in the notice after a transform ("New copy (trimmed)").
    var pastTense: String {
        switch self {
        case .plainText: return "plain text"
        case .trim: return "trimmed"
        case .uppercase: return "uppercase"
        case .lowercase: return "lowercase"
        case .titleCase: return "title case"
        case .jsonPretty: return "pretty JSON"
        case .jsonMinify: return "minified JSON"
        case .stripTracking: return "tracking removed"
        case .markdownLink: return "Markdown link"
        }
    }

    // Text cards only, one item per copy (a multi-item copy would need per-item results -- later).
    static func isEditable(_ input: TransformInput) -> Bool {
        guard input.itemCount == 1 else { return false }
        switch input.kind {
        case .text, .richText, .code, .link: return true
        case .image, .files: return false
        }
    }

    // The URL the link transforms work on: the copy's URL representation, else the text when it is one URL.
    static func linkURL(_ input: TransformInput) -> String? {
        if let u = input.url, webURL(u) != nil { return u.trimmingCharacters(in: .whitespacesAndNewlines) }
        return webURL(input.text) != nil ? input.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    // What the menu offers, in menu order. Cheap: linear scans of the (head) text, no reformatting.
    static func available(for input: TransformInput) -> [ClipTransform] {
        guard isEditable(input) else { return [] }
        return allCases.filter { $0.offered(input) }
    }

    func offered(_ input: TransformInput) -> Bool {
        guard Self.isEditable(input) else { return false }
        let text = input.text
        let isLink = input.kind == .link
        switch self {
        case .plainText: return input.hasRich && !text.isEmpty
        case .trim: return !input.complete || Self.needsTrim(text)
        // A head can't say what the rest of a long clip holds: any letters -> offer, the run decides.
        case .uppercase: return !isLink && text.contains { input.complete ? $0.isLowercase : $0.isLetter }
        case .lowercase: return !isLink && text.contains { input.complete ? $0.isUppercase : $0.isLetter }
        case .titleCase: return !isLink && (!input.complete ? text.contains { $0.isLetter } : Self.titleCased(text) != text)
        case .jsonPretty:
            // Valid JSON on one line can always be laid out; multi-line JSON may already be pretty -- the
            // run says "nothing to change" then.
            if !input.complete { return Self.looksLikeJSON(text) }
            return Self.isJSONContainer(text)
        case .jsonMinify:
            if !input.complete { return Self.looksLikeJSON(text) }
            return Self.isJSONContainer(text) && JSONFormatter.hasInsignificantWhitespace(text)
        case .stripTracking:
            guard let u = Self.linkURL(input) else { return false }
            return URLCleaner.stripTracking(u) != u
        case .markdownLink:
            return Self.linkURL(input) != nil
        }
    }

    func apply(_ input: TransformInput) -> String? {
        guard Self.isEditable(input) else { return nil }
        let text = input.text
        let isLink = input.kind == .link
        let out: String?
        switch self {
        case .plainText:
            // Same characters, minus the formatting -- the derived clip is saved with plain text only.
            return input.hasRich && !text.isEmpty ? text : nil
        case .trim:
            out = Self.trimmed(text)
        case .uppercase:
            out = isLink ? nil : text.uppercased()
        case .lowercase:
            out = isLink ? nil : text.lowercased()
        case .titleCase:
            out = isLink ? nil : Self.titleCased(text)
        case .jsonPretty:
            out = Self.isJSONContainer(text) ? JSONFormatter.pretty(text, maxBytes: Self.maxOutputBytes) : nil
        case .jsonMinify:
            out = Self.isJSONContainer(text) ? JSONFormatter.minify(text) : nil
        case .stripTracking:
            guard let u = Self.linkURL(input) else { return nil }
            let cleaned = URLCleaner.stripTracking(u)
            return cleaned == u ? nil : cleaned
        case .markdownLink:
            guard let u = Self.linkURL(input) else { return nil }
            // A rich hyperlink's label is its title; a bare URL falls back to the copied page title / host.
            let label = input.url != nil && Self.webURL(text) == nil ? text : input.linkTitle
            return Self.markdownLink(u, title: label)
        }
        guard let out, !out.isEmpty, out != text else { return nil }
        return out
    }

    // MARK: pieces

    // Whole-text ends, plus trailing spaces/tabs on each line. Indentation inside is kept.
    static func trimmed(_ s: String) -> String {
        // "\r\n" is one Character in Swift; both line endings split (and come back as "\n").
        let lines = s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { line -> Substring in
            var l = line
            while let last = l.last, last == " " || last == "\t" || last == "\r" { l = l.dropLast() }
            return l
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // First letter of every whitespace-separated word up, the rest down ("don't" -> "Don't").
    static func titleCased(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var atWordStart = true
        for ch in s {
            if ch.isWhitespace {
                out.append(ch); atWordStart = true
            } else if atWordStart {
                out += ch.uppercased(); atWordStart = false
            } else {
                out += ch.lowercased()
            }
        }
        return out
    }

    // Strict RFC 8259 object/array (JSONSerialization on macOS 27 also takes trailing commas, which the
    // reformatter would then carry along).
    static func isJSONContainer(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let f = t.first, f == "{" || f == "[" else { return false }
        return JSONFormatter.isValid(t)
    }

    static func needsTrim(_ s: String) -> Bool {
        if let f = s.first, f.isWhitespace { return true }
        if let l = s.last, l.isWhitespace { return true }
        var prev: Character = "x"
        for ch in s {
            if ch == "\n" || ch == "\r\n", prev == " " || prev == "\t" { return true }
            prev = ch
        }
        return false
    }

    // Starts like an object/array: the head of a long clip can't be validated, the run will.
    static func looksLikeJSON(_ s: String) -> Bool {
        guard let f = s.first(where: { !$0.isWhitespace }) else { return false }
        return f == "{" || f == "["
    }

    static func webURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClipNormalizer.isSingleWebURL(t) else { return nil }
        return URL(string: t)
    }

    static func markdownLink(_ s: String, title: String?) -> String? {
        guard let u = webURL(s), let host = u.host else { return nil }
        let label = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
        let escaped = label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
        // The parsed URL's percent-encoded form (raw <, >, spaces, backslashes are encoded by Foundation);
        // parentheses are legal in URLs but would end a Markdown destination early.
        var target = u.absoluteString
        for (c, e) in [("(", "%28"), (")", "%29"), ("<", "%3C"), (">", "%3E"), (" ", "%20"), ("\\", "%5C")] {
            target = target.replacingOccurrences(of: c, with: e)
        }
        return "[\(escaped)](\(target))"
    }
}

// MARK: - JSON reformatting that keeps key order and number spelling

// JSONSerialization would reorder keys (NSDictionary) and respell numbers (2.50 -> 2.5), so the text is
// re-laid-out token by token instead. Only called on text JSONSerialization already accepted.
enum JSONFormatter {
    // Strict validator (recursive descent over UTF-8; depth-capped so hostile nesting can't blow the stack).
    static func isValid(_ s: String) -> Bool {
        let b = Array(s.utf8)
        var i = 0
        func ws() { while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 } }
        func lit(_ word: String) -> Bool {
            let w = Array(word.utf8)
            guard i + w.count <= b.count, Array(b[i..<(i + w.count)]) == w else { return false }
            i += w.count; return true
        }
        func string() -> Bool {
            guard i < b.count, b[i] == 0x22 else { return false }
            i += 1
            while i < b.count {
                let c = b[i]
                if c == 0x22 { i += 1; return true }
                if c < 0x20 { return false }
                if c == 0x5C {
                    i += 1
                    guard i < b.count else { return false }
                    switch b[i] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: i += 1
                    case 0x75:
                        guard i + 4 < b.count else { return false }
                        for k in 1...4 {
                            let h = b[i + k], lower = h | 0x20
                            let isHex = (h >= 0x30 && h <= 0x39) || (lower >= 0x61 && lower <= 0x66)
                            if !isHex { return false }
                        }
                        i += 5
                    default: return false
                    }
                } else { i += 1 }
            }
            return false
        }
        func digits() -> Int { let s = i; while i < b.count, b[i] >= 0x30 && b[i] <= 0x39 { i += 1 }; return i - s }
        func number() -> Bool {
            if i < b.count, b[i] == 0x2D { i += 1 }
            guard i < b.count else { return false }
            if b[i] == 0x30 { i += 1 } else if digits() == 0 { return false }
            if i < b.count, b[i] == 0x2E { i += 1; if digits() == 0 { return false } }
            if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
                i += 1
                if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
                if digits() == 0 { return false }
            }
            return true
        }
        func value(_ depth: Int) -> Bool {
            guard depth < 512 else { return false }
            ws()
            guard i < b.count else { return false }
            switch b[i] {
            case 0x7B:                                                   // {
                i += 1; ws()
                if i < b.count, b[i] == 0x7D { i += 1; return true }
                while true {
                    ws()
                    guard string() else { return false }
                    ws()
                    guard i < b.count, b[i] == 0x3A else { return false }
                    i += 1
                    guard value(depth + 1) else { return false }
                    ws()
                    guard i < b.count else { return false }
                    if b[i] == 0x2C { i += 1; continue }
                    if b[i] == 0x7D { i += 1; return true }
                    return false
                }
            case 0x5B:                                                   // [
                i += 1; ws()
                if i < b.count, b[i] == 0x5D { i += 1; return true }
                while true {
                    guard value(depth + 1) else { return false }
                    ws()
                    guard i < b.count else { return false }
                    if b[i] == 0x2C { i += 1; continue }
                    if b[i] == 0x5D { i += 1; return true }
                    return false
                }
            case 0x22: return string()
            case 0x74: return lit("true")
            case 0x66: return lit("false")
            case 0x6E: return lit("null")
            default: return number()
            }
        }
        guard value(0) else { return false }
        ws()
        return i == b.count
    }

    static func minify(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var inString = false, escaped = false
        for ch in s {
            if inString {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true; out.append(ch)
            } else if !ch.isWhitespace {
                out.append(ch)
            }
        }
        return out
    }

    // Any whitespace outside string literals (what Minify would remove).
    static func hasInsignificantWhitespace(_ s: String) -> Bool {
        var inString = false, escaped = false
        for ch in s {
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
            } else if ch == "\"" { inString = true } else if ch.isWhitespace { return true }
        }
        return false
    }

    // nil once the result would pass `maxBytes`: deep nesting multiplies indentation, so a valid 1 MB
    // document could otherwise expand to hundreds of MB.
    static func pretty(_ s: String, indent: String = "  ", maxBytes: Int = .max) -> String? {
        let chars = Array(minify(s))
        var out = ""
        out.reserveCapacity(chars.count * 2)
        var depth = 0
        var i = 0
        func newline() { out.append("\n"); out.append(String(repeating: indent, count: depth)) }
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "\"":
                // Copy the whole string literal verbatim.
                out.append(ch); i += 1
                var escaped = false
                while i < chars.count {
                    let c = chars[i]; out.append(c); i += 1
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break }
                }
                continue
            case "{", "[":
                let close: Character = ch == "{" ? "}" : "]"
                if i + 1 < chars.count, chars[i + 1] == close {      // {} and [] stay on one line
                    out.append(ch); out.append(close); i += 2; continue
                }
                out.append(ch); depth += 1; newline()
            case "}", "]":
                depth = max(0, depth - 1); newline(); out.append(ch)
            case ",":
                out.append(ch); newline()
            case ":":
                out.append(": ")
            default:
                out.append(ch)
            }
            i += 1
            if out.utf8.count > maxBytes { return nil }
        }
        return out.utf8.count > maxBytes ? nil : out
    }
}

// MARK: - URL tracking parameters

enum URLCleaner {
    // Ad/analytics click ids and campaign tags. Deliberately conservative: nothing that a site might need
    // to show the page (no "ref", "si", "s", "source").
    static let exact: Set<String> = [
        "fbclid", "gclid", "dclid", "gbraid", "wbraid", "gclsrc", "msclkid", "yclid", "twclid", "ttclid",
        "li_fat_id", "igshid", "igsh", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id",
        "oly_enc_id", "vero_id", "vero_conv", "_ga", "_gl", "ref_src", "ref_url",
    ]
    static func isTracking(_ name: String) -> Bool {
        let n = (name.removingPercentEncoding ?? name).lowercased()
        return n.hasPrefix("utm_") || exact.contains(n)
    }

    // Works on the raw text so the remaining parameters keep their exact encoding.
    static func stripTracking(_ url: String) -> String {
        var base = url
        var fragment = ""
        if let hash = base.firstIndex(of: "#") { fragment = String(base[hash...]); base = String(base[..<hash]) }
        guard let q = base.firstIndex(of: "?") else { return url }
        let path = String(base[..<q])
        let query = base[base.index(after: q)...]
        let parts = query.split(separator: "&", omittingEmptySubsequences: false)
        // Empty segments ("a=1&&b=2") are kept as they are: only recognised tracking parameters go, and a URL
        // with none comes back byte-for-byte (signed / exact-match URLs).
        let kept = parts.filter { part in
            let name = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return name.isEmpty || !isTracking(name)
        }
        guard kept.count != parts.count else { return url }
        let rest = kept.allSatisfy(\.isEmpty) ? "" : "?" + kept.joined(separator: "&")
        return path + rest + fragment
    }
}

// MARK: - Readable text from copied HTML, whitespace kept

// For editing an HTML-only copy (rare: most apps also put plain text). Line breaks for block ends, tags
// dropped, common entities decoded -- and unlike the card preview, nothing is trimmed, so <pre> indentation
// survives. Thread-safe (no WebKit / NSAttributedString HTML import).
enum HTMLText {
    static func plain(_ html: String) -> String {
        var s = html
        let rules: [(String, String)] = [
            (#"(?is)<(script|style)\b[^>]*>.*?</\1\s*>"#, ""),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)</(p|div|li|tr|h[1-6]|pre|blockquote)\s*>"#, "\n"),
            (#"<[^>]*>"#, ""),
        ]
        for (pattern, with) in rules {
            s = s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        for (e, c) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: e, with: c)
        }
        return s
    }
}
