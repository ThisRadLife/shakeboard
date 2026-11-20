//
//  AIRedactor.swift
//  ShakeBoard -- replaces secrets with `[REDACTED: kind]` before any clipboard text is served to an AI tool.
//
//  Every quantifier that can start anywhere in a run is bounded: copied text is hostile input, and an unbounded
//  `[class]+` before a literal that never comes (`aaaa...` with no `@`) makes the scan quadratic.
//
//  Pattern-based (gitleaks-style rules + entropy + Luhn), so it WILL miss things -- which is why AI access is
//  off by default, consented per client, read-only and audited. Redaction runs at serve time on every
//  response (search included: a query can't match a secret because search runs over redacted text).
//

import Foundation

enum AIRedactor {
    struct Rule {
        let kind: String
        let regex: NSRegularExpression
        let group: Int                              // capture group to redact (0 = whole match)
        let validate: ((String) -> Bool)?
        let contact: Bool                           // only when "hide emails and phone numbers" is on
    }

    private static func rule(_ kind: String, _ pattern: String, group: Int = 0, contact: Bool = false,
                             validate: ((String) -> Bool)? = nil) -> Rule {
        // Patterns are constants checked by the unit tests; a bad one is a programming error.
        Rule(kind: kind, regex: try! NSRegularExpression(pattern: pattern), group: group,
             validate: validate, contact: contact)
    }

    // Order breaks ties between rules that match the same span (the earlier rule names it).
    static let rules: [Rule] = [
        rule("private-key", #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|\z)"#),
        rule("aws-access-key", #"\b(?:AKIA|ASIA|ABIA|ACCA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}\b"#),
        rule("github-token", #"\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{22,255})"#),
        rule("gitlab-token", #"\bglpat-[A-Za-z0-9_\-]{20,}"#),
        rule("slack-token", #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#),
        rule("slack-webhook", #"https://hooks\.slack\.com/services/[A-Za-z0-9/_\-]+"#),
        rule("anthropic-key", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
        rule("openai-key", #"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}"#),
        rule("stripe-key", #"\b(?:(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}|whsec_[A-Za-z0-9]{20,})"#),
        rule("google-api-key", #"\bAIza[0-9A-Za-z_\-]{35}"#),
        rule("jwt", #"\beyJ[A-Za-z0-9_\-]{5,}\.eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}"#),
        rule("url-password", #"(?i)\b[a-z][a-z0-9+.\-]{0,31}://[^\s/:@]{1,256}:([^\s/@]{1,256})@"#, group: 1),
        rule("bearer-token", #"(?i)\bbearer\s+([A-Za-z0-9._~+/\-]{12,}=*)"#, group: 1),
        // key = value / "key": "value" / key: 'value with spaces'. The whole value goes, quotes included.
        rule("secret-value",
             #"(?i)\b(?:password|passwd|pwd|passphrase|secret|client[_-]?secret|api[_-]?key|apikey|access[_-]?key|secret[_-]?key|private[_-]?key|auth[_-]?token|access[_-]?token|refresh[_-]?token|token)\b["']?\s*[:=]\s*("[^"\n]{1,512}"|'[^'\n]{1,512}'|[^\s"'`,;]{4,})"#,
             group: 1),
        rule("card-number", #"\b(?:\d[ \-]?){12,18}\d\b"#, validate: { luhnValid($0) }),
        rule("ssn", #"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#),
        rule("email", #"\b[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,253}\.[A-Za-z]{2,24}\b"#, contact: true),
        rule("phone", #"(?<![\w.+\-/])(?:\+?\d{1,3}[ .\-]?)?(?:\(\d{3}\)|\d{3})[ .\-]?\d{3}[ .\-]?\d{4}(?![\w.\-/])"#,
             contact: true, validate: { s in let d = s.filter(\.isNumber).count; return d >= 10 && d <= 15 }),
        // Long bare hex (48+ digits: 192-bit+ keys, signing secrets). 40-digit git hashes stay readable.
        rule("hex-secret", #"(?i)\b[0-9a-f]{48,}\b"#),
        // Last: long random-looking tokens nothing above recognized (keys from services without a known prefix).
        rule("high-entropy-secret", #"[A-Za-z0-9+/_\-]{32,}={0,2}"#, validate: { looksRandom($0) }),
    ]

    struct Result: Equatable {
        var text: String
        var counts: [String: Int]
        var total: Int { counts.values.reduce(0, +) }
    }

    static func redact(_ input: String, contacts: Bool) -> Result {
        guard !input.isEmpty else { return Result(text: input, counts: [:]) }
        let ns = input as NSString
        let all = NSRange(location: 0, length: ns.length)
        struct Hit { let range: NSRange; let kind: String; let order: Int }
        var hits: [Hit] = []
        for (order, r) in rules.enumerated() where contacts || !r.contact {
            for m in r.regex.matches(in: input, range: all) {
                let range = m.range(at: r.group)
                guard range.location != NSNotFound, range.length > 0 else { continue }
                if let v = r.validate, !v(ns.substring(with: range)) { continue }
                hits.append(Hit(range: range, kind: r.kind, order: order))
            }
        }
        guard !hits.isEmpty else { return Result(text: input, counts: [:]) }
        // Earliest start wins; then the longest; then rule order. Overlaps are dropped.
        hits.sort { a, b in
            if a.range.location != b.range.location { return a.range.location < b.range.location }
            if a.range.length != b.range.length { return a.range.length > b.range.length }
            return a.order < b.order
        }
        var kept: [Hit] = []
        var end = 0
        for h in hits where h.range.location >= end {
            kept.append(h)
            end = h.range.location + h.range.length
        }
        let out = NSMutableString(string: input)
        var counts: [String: Int] = [:]
        for h in kept.reversed() {
            out.replaceCharacters(in: h.range, with: "[REDACTED: \(h.kind)]")
            counts[h.kind, default: 0] += 1
        }
        return Result(text: out as String, counts: counts)
    }

    // Luhn over the digits of a 13-19 digit candidate; rejects runs of one digit (0000 0000 ...).
    static func luhnValid(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    // Shannon entropy per character. Random base64-ish keys sit near 4.5-5.5; English words, paths and hex
    // hashes (max 4.0) stay below the threshold.
    static func entropy(_ s: String) -> Double {
        var freq: [Character: Int] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let n = Double(s.count)
        return freq.values.reduce(0) { acc, c in let p = Double(c) / n; return acc - p * log2(p) }
    }
    static func looksRandom(_ s: String) -> Bool {
        let core = s.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        guard core.count >= 32 else { return false }
        let hasUpper = core.contains { $0.isUppercase }, hasLower = core.contains { $0.isLowercase }
        let hasDigit = core.contains { $0.isNumber }
        guard hasDigit, hasUpper || hasLower, hasUpper && hasLower || core.count >= 40 else { return false }
        // Paths and slugs: mostly word-ish segments separated by / or -.
        if core.contains("/") && core.split(separator: "/").allSatisfy({ $0.count < 24 }) { return false }
        return entropy(core) >= 4.3
    }
}
