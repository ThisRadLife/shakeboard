//
//  MCPTests.swift
//  The MCP bridge: JSON-RPC contract, tool schemas, redaction, gate / consent / rate limit / audit, the
//  socket (permissions, peer check, round trip) and the tool engine. Secret fixtures are assembled at runtime
//  from fragments so no real-looking token sits in the repo (push protection / scanners).
//

import XCTest
import Darwin
import Security
@testable import ShakeBoard

// MARK: - Fixtures

enum SecretFx {
    static func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }
    static var aws: String { "AK" + "IA" + "Q7W2E9R4T6Y1U3I8" }
    static var github: String { "gh" + "p_" + rep("aB3dE5", 6) }
    static var githubPAT: String { "github" + "_pat_" + rep("11AbCd", 5) }
    static var gitlab: String { "gl" + "pat-" + rep("x9Y", 8) }
    static var slack: String { "xo" + "xb-" + "1234567890-" + rep("abcDEF", 3) }
    static var slackHook: String { "https://hooks.slack" + ".com/services/" + "T000/B000/" + rep("XyZ", 6) }
    static var anthropic: String { "sk" + "-ant-" + "api03-" + rep("Zz9", 8) }
    static var openai: String { "sk" + "-proj-" + rep("Ab1_", 6) }
    static var stripe: String { "sk" + "_li" + "ve_" + rep("a1B2", 6) }
    static var google: String { "AI" + "za" + "Sy" + rep("A1b2C3d", 5).prefix(33) }
    static var jwt: String { "ey" + "JhbGciOiJIUzI1NiJ9" + "." + "ey" + "JzdWIiOiIxMjM0NTY3ODkwIn0" + "." + "abcDEF123_-xyz" }
    static var pem: String { "-----BEGIN " + "RSA PRIVATE" + " KEY-----\nMIIEow" + rep("Qk9", 10) + "\n-----END RSA " + "PRIVATE KEY-----" }
    static var card: String { "4111" + " 1111" + " 1111" + " 1111" }
    static var ssn: String { "123" + "-45-" + "6789" }
    static var randomKey: String { "Qx7" + "pL2mZ9vR4tB8nK1wE6yH3jC5uF0aS" + "dG7v" }
}

// MARK: - JSON-RPC / MCP contract

final class MCPServerTests: XCTestCase {
    private func json(_ d: Data?) -> [String: Any] {
        guard let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
    private func line(_ o: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    func testInitializeNegotiatesAndRecordsClient() {
        let s = MCPServer { _, _, _, _ in (true, "") }
        let r = json(s.handle(line: line(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                          "params": ["protocolVersion": "2025-03-26", "clientInfo": ["name": "claude-code", "version": "2.1"]]])))
        let res = r["result"] as? [String: Any]
        XCTAssertEqual(r["id"] as? Int, 1)
        XCTAssertEqual(res?["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((res?["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((res?["serverInfo"] as? [String: Any])?["name"] as? String, "shakeboard")
        XCTAssertEqual(s.clientName, "claude-code")
        XCTAssertEqual(s.clientVersion, "2.1")
    }

    func testUnsupportedVersionGetsLatest() {
        XCTAssertEqual(MCPServer.negotiate("1999-01-01"), MCPServer.supportedVersions[0])
        XCTAssertEqual(MCPServer.negotiate(nil), MCPServer.supportedVersions[0])
        XCTAssertEqual(MCPServer.negotiate("2024-11-05"), "2024-11-05")
    }

    func testPingNotificationsAndErrors() {
        let s = MCPServer { _, _, _, _ in (true, "") }
        XCTAssertNotNil(json(s.handle(line: line(["jsonrpc": "2.0", "id": "a", "method": "ping"])))["result"])
        XCTAssertNil(s.handle(line: line(["jsonrpc": "2.0", "method": "notifications/initialized"])))
        func code(_ d: Data?) -> Int? { (json(d)["error"] as? [String: Any])?["code"] as? Int }
        XCTAssertEqual(code(s.handle(line: Data("{not json".utf8))), -32700)
        XCTAssertEqual(code(s.handle(line: Data("[]".utf8))), -32600)
        XCTAssertEqual(code(s.handle(line: line(["jsonrpc": "1.0", "id": 2, "method": "ping"]))), -32600)
        XCTAssertEqual(code(s.handle(line: line(["jsonrpc": "2.0", "id": ["x"], "method": "ping"]))), -32600)
        XCTAssertEqual(code(s.handle(line: line(["jsonrpc": "2.0", "id": 3, "method": "resources/list"]))), -32601)
        XCTAssertEqual(code(s.handle(line: line(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                                 "params": ["name": "rm_rf", "arguments": [:]]]))), -32602)
        XCTAssertEqual(code(s.handle(line: line(["jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                                 "params": ["name": "shakeboard_stats", "arguments": "x"]]))), -32602)
    }

    func testToolsListSchemas() {
        let s = MCPServer { _, _, _, _ in (true, "") }
        let tools = (json(s.handle(line: line(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])))["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), MCPTools.names)
        for t in tools {
            let schema = t["inputSchema"] as? [String: Any]
            XCTAssertEqual(schema?["type"] as? String, "object", "\(t["name"] ?? "")")
            XCTAssertEqual(schema?["additionalProperties"] as? Bool, false)
            XCTAssertEqual((t["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool, true)
            XCTAssertFalse((t["description"] as? String ?? "").isEmpty)
        }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["tools": MCPTools.definitions]))
    }

    func testToolsCallForwardsAndMapsErrors() {
        var seen: (String, String, [String: Any])?
        let s = MCPServer { client, _, tool, args in
            seen = (client, tool, args)
            return tool == "shakeboard_get" ? (false, "nope") : (true, "{\"ok\":1}")
        }
        _ = s.handle(line: line(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                 "params": ["clientInfo": ["name": "codex-mcp-client"]]]))
        let ok = json(s.handle(line: line(["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                          "params": ["name": "shakeboard_search", "arguments": ["query": "x"]]])))["result"] as? [String: Any]
        XCTAssertEqual(ok?["isError"] as? Bool, false)
        XCTAssertEqual(((ok?["content"] as? [[String: Any]])?.first)?["text"] as? String, "{\"ok\":1}")
        XCTAssertEqual(seen?.0, "codex-mcp-client")
        XCTAssertEqual(seen?.1, "shakeboard_search")
        XCTAssertEqual(seen?.2["query"] as? String, "x")
        let bad = json(s.handle(line: line(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                           "params": ["name": "shakeboard_get", "arguments": ["id": "1"]]])))["result"] as? [String: Any]
        XCTAssertEqual(bad?["isError"] as? Bool, true)
    }

    func testWireRoundTrip() {
        let r = MCPBridge.Request(client: "c", clientVersion: "1", tool: "shakeboard_stats", args: ["limit": 3])
        let d = r.encode()!
        XCTAssertEqual(d.last, 0x0A)
        let back = MCPBridge.Request.decode(d.dropLast())
        XCTAssertEqual(back?.tool, "shakeboard_stats")
        XCTAssertEqual(back?.args["limit"] as? Int, 3)
        XCTAssertNil(MCPBridge.Request.decode(Data(#"{"v":99,"client":"c","tool":"t"}"#.utf8)))
        let resp = MCPBridge.Response(ok: false, text: "hi", code: "denied")
        XCTAssertEqual(MCPBridge.Response.decode(resp.encode().dropLast()), resp)
    }

    func testSocketPathResolution() {
        let legacy = MCPBridge.dataDir(env: ["PERCH_DATA_DIR": "/tmp/legacy-data"])
        XCTAssertEqual(legacy.path, "/tmp/legacy-data")
        let base = MCPBridge.dataDir(env: [
            "PERCH_DATA_DIR": "/tmp/legacy-data",
            "SHAKEBOARD_DATA_DIR": "/tmp/shakeboard-data",
        ])
        XCTAssertEqual(MCPBridge.socketURL(base: base).path, "/tmp/shakeboard-data/mcp/shakeboard.sock")
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-support-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(MCPBridge.dataDir(env: [:], applicationSupport: support).path.hasSuffix("/ShakeBoard"))
        XCTAssertNil(UnixSocket.address("/" + String(repeating: "x", count: 120)))
        XCTAssertNotNil(UnixSocket.address("/tmp/a.sock"))
        XCTAssertEqual(MCPBridge.dataDirCandidates(env: [
            "PERCH_DATA_DIR": "/tmp/legacy-data",
            "SHAKEBOARD_DATA_DIR": "/tmp/shakeboard-data",
        ]).map(\.path), ["/tmp/shakeboard-data"])
    }

    func testSocketPathUsesLegacyFolderWhenRenameFailedInTheApp() throws {
        let support = URL(fileURLWithPath: "/tmp/ShakeBoardMCPPath-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let old = support.appendingPathComponent("Perch", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        XCTAssertEqual(MCPBridge.dataDir(env: [:], applicationSupport: support), old)
        XCTAssertEqual(MCPBridge.dataDirCandidates(env: [:], applicationSupport: support).map(\.lastPathComponent),
                       ["ShakeBoard", "Perch"])

        let new = support.appendingPathComponent("ShakeBoard", isDirectory: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        XCTAssertEqual(MCPBridge.dataDir(env: [:], applicationSupport: support), new,
                       "ShakeBoard wins when both folders exist")
    }
}

// MARK: - Redaction

final class AIRedactorTests: XCTestCase {
    private func assertRedacts(_ secret: String, kind: String, file: StaticString = #filePath, line: UInt = #line) {
        let r = AIRedactor.redact("before \(secret) after", contacts: false)
        XCTAssertFalse(r.text.contains(secret), "leaked \(kind)", file: file, line: line)
        XCTAssertTrue(r.text.contains("[REDACTED: \(kind)]"), "\(r.text)", file: file, line: line)
        XCTAssertTrue(r.text.hasPrefix("before ") && r.text.hasSuffix(" after"), file: file, line: line)
    }

    func testKnownSecretKinds() {
        assertRedacts(SecretFx.aws, kind: "aws-access-key")
        assertRedacts(SecretFx.github, kind: "github-token")
        assertRedacts(SecretFx.githubPAT, kind: "github-token")
        assertRedacts(SecretFx.gitlab, kind: "gitlab-token")
        assertRedacts(SecretFx.slack, kind: "slack-token")
        assertRedacts(SecretFx.slackHook, kind: "slack-webhook")
        assertRedacts(SecretFx.anthropic, kind: "anthropic-key")
        assertRedacts(SecretFx.openai, kind: "openai-key")
        assertRedacts(SecretFx.stripe, kind: "stripe-key")
        assertRedacts(SecretFx.google, kind: "google-api-key")
        assertRedacts(SecretFx.jwt, kind: "jwt")
        assertRedacts(SecretFx.pem, kind: "private-key")
        assertRedacts(SecretFx.card, kind: "card-number")
        assertRedacts(SecretFx.ssn, kind: "ssn")
        assertRedacts(SecretFx.randomKey, kind: "high-entropy-secret")
    }

    func testValueOnlyRules() {
        let pw = "hunter2" + "Hunter"
        let r = AIRedactor.redact("password=\(pw)\nuser: example", contacts: false)
        XCTAssertEqual(r.text, "password=[REDACTED: secret-value]\nuser: example")
        let url = AIRedactor.redact("postgres://admin:" + "s3cretPass" + "@db.example.com/app", contacts: false)
        XCTAssertEqual(url.text, "postgres://admin:[REDACTED: url-password]@db.example.com/app")
        let bearer = AIRedactor.redact("Authorization: Bearer " + SecretFx.rep("tok3N", 4), contacts: false)
        XCTAssertTrue(bearer.text.hasSuffix("Bearer [REDACTED: bearer-token]"), bearer.text)
        let quoted = AIRedactor.redact(#"{"api_key": ""# + "abcd" + "1234efgh" + #""}"#, contacts: false)
        XCTAssertFalse(quoted.text.contains("abcd1234efgh"), quoted.text)
    }

    func testQuotedValuesAndHex() {
        let phrase = "correct horse " + "battery staple"
        for s in ["password=\"\(phrase)\"", "password: '\(phrase)'", "{\"password\": \"\(phrase)\"}", "secret = \"a, b; c\""] {
            let r = AIRedactor.redact(s, contacts: false)
            XCTAssertFalse(r.text.contains("battery") || r.text.contains("a, b"), r.text)
            XCTAssertEqual(r.counts["secret-value"], 1, s)
        }
        let hex = SecretFx.rep("0123456789abcdef", 4)   // 64 hex digits
        XCTAssertEqual(AIRedactor.redact("signing \(hex) end", contacts: false).counts["hex-secret"], 1)
        let mixed = SecretFx.rep("dead" + "BEEF", 7)     // 56 mixed-case hex digits
        XCTAssertEqual(AIRedactor.redact("k \(mixed) end", contacts: false).counts["hex-secret"], 1)
    }

    func testBenignTextUntouched() {
        for s in ["The quick brown fox jumps over the lazy dog.",
                  "/Users/example/Library/Application Support/ShakeBoard/Clips/clips.json",
                  "3f2a9c1e5b7d8f0a4c6e2b1d9f8a7c5e3b2a1d0f",
                  "550e8400-e29b-41d4-a716-446655440000",
                  "https://example.com/path?q=1&page=2",
                  "Order 12345678 shipped, version 1.2.3",
                  "the token bucket algorithm limits requests",
                  "func redact(_ input: String, contacts: Bool) -> Result {"] {
            let r = AIRedactor.redact(s, contacts: true)
            XCTAssertEqual(r.text, s)
            XCTAssertEqual(r.total, 0)
        }
    }

    func testContactsToggle() {
        let s = "mail alex" + "@example.com or call (207) 555-0142"
        XCTAssertEqual(AIRedactor.redact(s, contacts: false).text, s)
        let on = AIRedactor.redact(s, contacts: true)
        XCTAssertEqual(on.counts["email"], 1)
        XCTAssertEqual(on.counts["phone"], 1)
        XCTAssertFalse(on.text.contains("555-0142"))
    }

    func testCountsAndOverlaps() {
        // An Anthropic key also matches the generic sk- rule and the entropy rule: named once, by the first rule.
        let r = AIRedactor.redact("a \(SecretFx.anthropic) b \(SecretFx.aws)", contacts: false)
        XCTAssertEqual(r.counts, ["anthropic-key": 1, "aws-access-key": 1])
        XCTAssertEqual(r.total, 2)
    }

    func testHostileInputStaysLinear() {
        // Long runs that almost match (no @, no ://, hex then a letter, digits) must not go quadratic.
        // Compares 4x the input against 1x so it holds on slow CI runners: linear ~4x, quadratic ~16x.
        func elapsed(_ n: Int) -> TimeInterval {
            let inputs = [String(repeating: "a", count: n), String(repeating: "a.", count: n / 2),
                          String(repeating: "ab:", count: n / 3), String(repeating: "f", count: n) + "g",
                          String(repeating: "1", count: n), String(repeating: "x-", count: n / 2) + "://"]
            let start = Date()
            for s in inputs { _ = AIRedactor.redact(s, contacts: true) }
            return Date().timeIntervalSince(start)
        }
        _ = elapsed(16 * 1024) // warm up
        let small = elapsed(64 * 1024), big = elapsed(256 * 1024)
        XCTAssertLessThan(big / max(small, 0.001), 8, "redaction must stay linear on hostile input (\(small)s vs \(big)s)")
        XCTAssertLessThan(big, 60, "redaction must stay usable on hostile input")
    }

    func testLuhn() {
        XCTAssertTrue(AIRedactor.luhnValid(SecretFx.card))
        XCTAssertFalse(AIRedactor.luhnValid("4111 1111 1111 1112"))
        XCTAssertFalse(AIRedactor.luhnValid("0000 0000 0000 0000"))
        XCTAssertFalse(AIRedactor.luhnValid("12345"))
        XCTAssertEqual(AIRedactor.redact("ref 4111 1111 1111 1112", contacts: false).total, 0)
    }
}

// MARK: - Policy: client ids, gate, rate limit, prefs, audit

final class AIPolicyTests: XCTestCase {
    func testClientIDs() {
        XCTAssertEqual(AIClientID.normalize("Claude Code"), "claude-code")
        XCTAssertEqual(AIClientID.normalize("../../etc\u{0}"), "....etc")
        XCTAssertEqual(AIClientID.normalize(""), "unknown")
        XCTAssertEqual(AIClientID.normalize(String(repeating: "a", count: 200)).count, 64)
        XCTAssertEqual(AIClientID.displayName("claude-code"), "Claude Code")
        XCTAssertEqual(AIClientID.displayName("codex-mcp-client"), "Codex")
        XCTAssertEqual(AIClientID.displayName("cursor"), "cursor")
    }

    func testGateOrder() {
        var charged = 0
        let rate: (Bool) -> () -> Bool = { ok in { charged += 1; return ok } }
        XCTAssertEqual(AIGate.decide(enabled: false, consent: true, rateOK: rate(true), clientName: "X").code, "disabled")
        XCTAssertEqual(AIGate.decide(enabled: true, consent: false, rateOK: rate(true), clientName: "X").code, "denied")
        if case .askUser = AIGate.decide(enabled: true, consent: nil, rateOK: rate(true), clientName: "X") {} else { XCTFail() }
        XCTAssertEqual(charged, 0, "only an allowed app is charged against the rate limit")
        XCTAssertEqual(AIGate.decide(enabled: true, consent: true, rateOK: rate(false), clientName: "X").code, "rate_limited")
        XCTAssertEqual(AIGate.decide(enabled: true, consent: true, rateOK: rate(true), clientName: "X"), .run)
    }

    func testInvokerKeysAndVisibilityChain() {
        XCTAssertTrue(AIClientID.isValidKey("team:Q6L2SF6YDW:com.anthropic.claude-code"))
        XCTAssertTrue(AIClientID.isValidKey("path:/opt/homebrew/bin/node"))
        XCTAssertFalse(AIClientID.isValidKey(""))
        XCTAssertFalse(AIClientID.isValidKey("a\nb"))
        // This test process's own identity resolves (ad-hoc test host -> a path key).
        var me: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &me), errSecSuccess)
        let inv = AIInvoker.identity(code: me!, path: CodeIdentity.path(me!)!)
        XCTAssertTrue(inv.key.hasPrefix("path:") || inv.key.hasPrefix("team:"), inv.key)
        XCTAssertFalse(inv.name.isEmpty)
        XCTAssertEqual(AIInvoker.friendly("com.anthropic.claude-code", fallback: "x"), "Claude Code")
        XCTAssertFalse(AIInvoker.shells.contains("/tmp/zsh"))

        func clip(_ id: UUID, from: UUID?, app: String?, kind: ClipKind = .text) -> Clip {
            Clip(id: id, kind: kind, createdAt: Date(), lastUsedAt: Date(), sourceBundleID: app, sourceAppName: nil,
                 contentHash: id.uuidString, preview: "", reps: [], totalBytes: 0, derivedFrom: from)
        }
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let root = clip(a, from: nil, app: "com.example.secret")
        let child = clip(b, from: a, app: PerchID.appBundleID)
        let grandchild = clip(c, from: b, app: PerchID.appBundleID)
        let other = clip(d, from: nil, app: "com.apple.Notes")
        let byID = [a: root, b: child, c: grandchild, d: other]
        let apps: Set<String> = ["com.example.secret"]
        XCTAssertTrue(AIVisibility.isHidden(grandchild, byID: byID, hiddenApps: apps, hiddenClips: []))
        let hiddenImage = clip(UUID(), from: nil, app: "com.example.secret", kind: .image)
        XCTAssertTrue(AIVisibility.isHidden(hiddenImage, byID: [hiddenImage.id: hiddenImage],
                                            hiddenApps: apps, hiddenClips: []),
                      "hidden image clips are removed before their OCR loader can be served")
        XCTAssertFalse(AIVisibility.isHidden(other, byID: byID, hiddenApps: apps, hiddenClips: []))
        XCTAssertTrue(AIVisibility.isHidden(grandchild, byID: byID, hiddenApps: [], hiddenClips: [a]))
        // Durable: once marked, the grandchild stays hidden after its ancestors are gone.
        let marks = AIVisibility.inheritedMarks(clips: [root, child, grandchild, other], hiddenApps: apps, marks: [])
        XCTAssertEqual(marks, [b, c])
        XCTAssertTrue(AIVisibility.isHidden(grandchild, byID: [c: grandchild], hiddenApps: [], hiddenClips: marks))
        // Long chains have no depth cutoff.
        var chain: [UUID: Clip] = [:]
        var prev: UUID? = nil
        var last: Clip!
        for i in 0..<200 {
            let id = UUID()
            last = clip(id, from: prev, app: i == 0 ? "com.example.secret" : nil)
            chain[id] = last; prev = id
        }
        XCTAssertTrue(AIVisibility.isHidden(last, byID: chain, hiddenApps: apps, hiddenClips: []))
        // A cycle can't hang the walk.
        let loopA = clip(a, from: b, app: nil), loopB = clip(b, from: a, app: nil)
        XCTAssertFalse(AIVisibility.isHidden(loopA, byID: [a: loopA, b: loopB], hiddenApps: [], hiddenClips: []))
    }

    func testRateLimiter() {
        let rl = AIRateLimiter(limit: 30, window: 60)
        let t0 = Date(timeIntervalSince1970: 1000)
        for i in 0..<30 { XCTAssertTrue(rl.allow(now: t0.addingTimeInterval(Double(i))), "call \(i)") }
        XCTAssertFalse(rl.allow(now: t0.addingTimeInterval(30)))
        XCTAssertTrue(rl.allow(now: t0.addingTimeInterval(60.5)))   // the first call aged out
    }

    func testPrefsDefaultsAndSanitizing() {
        let d = UserDefaults(suiteName: "shakeboard.tests.ai.\(UUID().uuidString)")!
        var p = PerchPrefs(defaults: d)
        XCTAssertFalse(p.aiAccessEnabled, "AI access must be OFF by default")
        XCTAssertTrue(p.aiRedactContacts)
        XCTAssertFalse(p.aiIncludeShelfNames, "shelf names are opt-in")
        p.aiClients = ["team:Q6L2SF6YDW:com.anthropic.claude-code": true, "bad\u{0}key": true]
        XCTAssertEqual(p.aiClients, ["team:Q6L2SF6YDW:com.anthropic.claude-code": true])
        d.set(["ok": "yes", "bad\nkey": true], forKey: "aiClients")
        XCTAssertEqual(PerchPrefs(defaults: d).aiClients, [:])
        p.aiHiddenApps = ["com.example.app", "bad id", "com.example.app"]
        XCTAssertEqual(p.aiHiddenApps, ["com.example.app"])
    }

    func testAuditLogIsContentFreeAndOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shakeboard-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AIAuditLog(dir: dir)
        log.append(AIAuditEntry(time: Date(), client: "claude-code", tool: "shakeboard_search", outcome: "ok", items: 2, redactions: 1, bytes: 300))
        log.append(AIAuditEntry(time: Date(), client: "codex", tool: "shakeboard_get", outcome: "denied"))
        log.flush()
        let entries = log.load()
        XCTAssertEqual(entries.map(\.tool), ["shakeboard_get", "shakeboard_search"])   // newest first
        let attrs = try FileManager.default.attributesOfItem(atPath: log.url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // Only these keys are ever written -- no text, no query, no ids of copies.
        let raw = try String(contentsOf: log.url, encoding: .utf8)
        for l in raw.split(separator: "\n") {
            let o = try JSONSerialization.jsonObject(with: Data(l.utf8)) as! [String: Any]
            XCTAssertEqual(Set(o.keys), ["time", "client", "tool", "outcome", "items", "redactions", "bytes"])
        }
        log.clear()
        XCTAssertTrue(log.load().isEmpty)
    }

    func testAuditLogTrims() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shakeboard-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AIAuditLog(dir: dir)
        for i in 0...AIAuditLog.maxLines { log.append(AIAuditEntry(time: Date(), client: "c", tool: "t\(i)", outcome: "ok")) }
        log.flush()
        let n = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n").count
        XCTAssertLessThanOrEqual(n, AIAuditLog.maxLines)
        XCTAssertEqual(log.load(limit: 1).first?.tool, "t\(AIAuditLog.maxLines)")
    }

    func testPeerDecision() {
        let helper = URL(fileURLWithPath: "/Applications/ShakeBoard.app/Contents/MacOS/shakeboard-mcp")
        XCTAssertTrue(AIPeerCheck.allowed(sameUser: true, peerPath: helper, expected: helper, teamOK: true))
        XCTAssertFalse(AIPeerCheck.allowed(sameUser: false, peerPath: helper, expected: helper, teamOK: true))
        XCTAssertFalse(AIPeerCheck.allowed(sameUser: true, peerPath: URL(fileURLWithPath: "/tmp/shakeboard-mcp"), expected: helper, teamOK: true))
        XCTAssertFalse(AIPeerCheck.allowed(sameUser: true, peerPath: helper, expected: helper, teamOK: false))
        XCTAssertFalse(AIPeerCheck.allowed(sameUser: true, peerPath: nil, expected: helper, teamOK: true))
    }

    func testConnectCommandsQuoteThePath() {
        let p = "/Applications/ShakeBoard's Copy.app/Contents/MacOS/shakeboard-mcp"
        let c = AIConnectTarget.claude.command(helper: p)
        XCTAssertTrue(c.hasPrefix("claude mcp add --scope user --transport stdio shakeboard -- '"), c)
        XCTAssertTrue(c.contains(#"ShakeBoard'\''s Copy.app"#), c)
        XCTAssertTrue(AIConnectTarget.codex.command(helper: "/x/shakeboard-mcp").hasPrefix("codex mcp add shakeboard -- '/x/shakeboard-mcp'"))
    }
}

extension AIGate.Decision {
    var code: String? { if case .refuse(let c, _) = self { return c }; return nil }
}

// MARK: - Tool engine

final class AIToolEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func rec(_ text: String, kind: ClipKind = .text, app: String? = "Notes", hoursAgo: Double = 1,
                     boards: [String] = []) -> AIRecord {
        let t = now.addingTimeInterval(-hoursAgo * 3600)
        return AIRecord(id: UUID(), kind: kind, createdAt: t, lastUsedAt: t, sourceApp: app,
                        pixelWidth: kind == .image ? 10 : nil, pixelHeight: kind == .image ? 20 : nil,
                        preview: String(text.prefix(300)), boards: boards, textBytes: text.utf8.count,
                        loadText: { _ in kind == .image ? nil : text })
    }
    private func snap(_ r: [AIRecord], shelf: [String] = []) -> AISnapshot {
        AISnapshot(records: r, hiddenCount: 3, shelfNames: shelf, redactContacts: true)
    }
    private func body(_ out: AIToolOutput) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(out.text.utf8)) as? [String: Any]) ?? [:]
    }

    func testEnvelopeMarksUntrusted() {
        let out = AIToolEngine.run(tool: "shakeboard_recent", args: [:], snapshot: snap([rec("hello")]), now: now)
        let b = body(out)
        XCTAssertTrue(out.ok)
        XCTAssertEqual(b["untrusted_content"] as? Bool, true)
        XCTAssertNotNil(b["notice"] as? String)
        XCTAssertEqual(b["tool"] as? String, "shakeboard_recent")
    }

    func testRecentLimitKindAndRedaction() {
        let recs = [rec("key \(SecretFx.aws)"), rec("plain"), rec("", kind: .image), rec("https://x.com", kind: .url)]
        let out = AIToolEngine.run(tool: "shakeboard_recent", args: ["limit": 2], snapshot: snap(recs), now: now)
        let items = body(out)["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(out.text.contains(SecretFx.aws))
        XCTAssertEqual(out.redactions, 1)
        let links = body(AIToolEngine.run(tool: "shakeboard_recent", args: ["kind": "link"], snapshot: snap(recs), now: now))["items"] as? [[String: Any]]
        XCTAssertEqual(links?.map { $0["kind"] as? String }, ["link"])
        let img = body(AIToolEngine.run(tool: "shakeboard_recent", args: ["kind": "image"], snapshot: snap(recs), now: now))["items"] as? [[String: Any]]
        XCTAssertEqual(img?.first?["image_size"] as? String, "10x20")
        // A short copy whose whitespace collapses in the preview is not "truncated".
        let multi = body(AIToolEngine.run(tool: "shakeboard_recent", args: [:], snapshot: snap([rec("a\n\n  b")]), now: now))
        XCTAssertEqual((multi["items"] as? [[String: Any]])?.first?["truncated"] as? Bool, false)
        XCTAssertFalse(AIToolEngine.run(tool: "shakeboard_recent", args: ["kind": "video"], snapshot: snap(recs)).ok)
        XCTAssertFalse(AIToolEngine.run(tool: "shakeboard_recent", args: ["limit": "5"], snapshot: snap(recs)).ok)
        XCTAssertFalse(AIToolEngine.run(tool: "shakeboard_recent", args: ["limit": true], snapshot: snap(recs)).ok)
        XCTAssertFalse(AIToolEngine.run(tool: "shakeboard_recent", args: ["bogus": 1], snapshot: snap(recs)).ok)
    }

    func testServedClipIncludesOnlyItsBoardNamesAndRedactsThem() {
        let record = rec("public copy", boards: ["Gallery addresses", "password=BoardSecret123"])
        let out = AIToolEngine.run(tool: "shakeboard_recent", args: [:], snapshot: snap([record]), now: now)
        let item = (body(out)["items"] as? [[String: Any]])?.first
        let boards = item?["boards"] as? [String]
        XCTAssertEqual(boards?.first, "Gallery addresses")
        XCTAssertEqual(boards?.last, "password=[REDACTED: secret-value]")
        XCTAssertFalse(out.text.contains("BoardSecret123"))
    }

    func testSearchRunsOverRedactedTextOnly() {
        let recs = [rec("deploy key is \(SecretFx.github) ok"), rec("Lunch at noon"), rec("x", app: "Xcode")]
        // Guessing the secret finds nothing.
        let guess = body(AIToolEngine.run(tool: "shakeboard_search", args: ["query": SecretFx.github], snapshot: snap(recs)))
        XCTAssertEqual((guess["items"] as? [Any])?.count, 0)
        let hit = AIToolEngine.run(tool: "shakeboard_search", args: ["query": "DEPLOY"], snapshot: snap(recs))
        let items = body(hit)["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue((items.first?["snippet"] as? String ?? "").contains("[REDACTED: github-token]"))
        XCTAssertFalse(hit.text.contains(SecretFx.github))
        XCTAssertEqual((body(AIToolEngine.run(tool: "shakeboard_search", args: ["query": "xcode"], snapshot: snap(recs)))["items"] as? [Any])?.count, 1)
        XCTAssertFalse(AIToolEngine.run(tool: "shakeboard_search", args: [:], snapshot: snap(recs)).ok)
        XCTAssertFalse(AIToolEngine.run(tool: "shakeboard_search", args: ["query": String(repeating: "q", count: 201)], snapshot: snap(recs)).ok)
    }

    func testImageOCRSearchReturnsOnlyBoundedMatchSnippetAndGetReturnsFullOCRText() {
        let id = UUID()
        let raw = String(repeating: "unrelated beginning ", count: 400) + "label key " + SecretFx.github
        let image = AIRecord(id: id, kind: .image, createdAt: now, lastUsedAt: now, sourceApp: "Preview",
                             pixelWidth: 100, pixelHeight: 80, preview: "Image 100 x 80",
                             textBytes: raw.utf8.count, loadText: { _ in raw })
        let search = AIToolEngine.run(tool: "shakeboard_search", args: ["query": "label"], snapshot: snap([image]))
        let searchItem = (body(search)["items"] as? [[String: Any]])?.first
        XCTAssertNotNil(searchItem)
        XCTAssertNil(searchItem?["ocr_text"], "search exposes only the bounded match snippet")
        XCTAssertTrue((searchItem?["snippet"] as? String ?? "").contains("label"))
        XCTAssertLessThan((searchItem?["snippet"] as? String ?? "").count, 600)
        XCTAssertFalse(search.text.contains(SecretFx.github))

        let appSearch = AIToolEngine.run(tool: "shakeboard_search", args: ["query": "Preview"], snapshot: snap([image]))
        let appItem = (body(appSearch)["items"] as? [[String: Any]])?.first
        XCTAssertNil(appItem?["ocr_text"])
        XCTAssertFalse((appItem?["snippet"] as? String ?? "").contains("label key"),
                       "a source-app match must not expose unrelated OCR from the end of the image")

        let get = AIToolEngine.run(tool: "shakeboard_get", args: ["id": id.uuidString], snapshot: snap([image]))
        let getItem = body(get)["item"] as? [String: Any]
        XCTAssertTrue((getItem?["ocr_text"] as? String ?? "").contains("[REDACTED: github-token]"))
        XCTAssertNil(getItem?["text"])
        XCTAssertFalse(get.text.contains(SecretFx.github))
    }

    func testSearchShelfNames() {
        let out = body(AIToolEngine.run(tool: "shakeboard_search", args: ["query": "invoice"], snapshot: snap([], shelf: ["Invoice-2026.pdf", "cat.png"])))
        let items = out["items"] as? [[String: Any]] ?? []
        XCTAssertEqual(items.first?["name"] as? String, "Invoice-2026.pdf")
        XCTAssertEqual(items.first?["kind"] as? String, "shelf_file")
    }

    func testHugeHistoryStopsEarly() {
        let big = String(repeating: "a", count: 1_000_000)   // 1 MB each; 120 x 264 KB scanned is over the 24 MB budget
        let recs = (0..<120).map { _ in rec(big) }
        let out = body(AIToolEngine.run(tool: "shakeboard_search", args: ["query": "zzz", "limit": 50], snapshot: snap(recs)))
        XCTAssertEqual(out["partial"] as? Bool, true)
    }

    func testGetCapsAndHidesUnknown() {
        let big = String(repeating: "abcdefgh ", count: 6000)   // 54 KB
        let r = rec(big)
        let out = body(AIToolEngine.run(tool: "shakeboard_get", args: ["id": r.id.uuidString], snapshot: snap([r])))
        let item = out["item"] as? [String: Any]
        XCTAssertEqual(item?["truncated"] as? Bool, true)
        XCTAssertLessThanOrEqual((item?["text"] as? String ?? "").utf8.count, MCPTools.getCapBytes)
        XCTAssertEqual(item?["total_bytes"] as? Int, big.utf8.count)
        XCTAssertTrue(item?["total_chars"] is NSNull, "no byte count passed off as a character count")
        let missing = AIToolEngine.run(tool: "shakeboard_get", args: ["id": UUID().uuidString], snapshot: snap([r]))
        XCTAssertFalse(missing.ok)
        XCTAssertTrue(missing.text.hasPrefix("No copy with that id"))
        XCTAssertFalse(AIToolEngine.run(tool: "shakeboard_get", args: ["id": "../../etc/passwd"], snapshot: snap([r])).ok)
    }

    func testContextBudgetAndSince() {
        let recs = (0..<10).map { rec(String(repeating: "w", count: 3000), hoursAgo: Double($0)) }
        let out = body(AIToolEngine.run(tool: "shakeboard_context", args: ["max_chars": 5000], snapshot: snap(recs), now: now))
        let items = out["items"] as? [[String: Any]] ?? []
        let total = items.reduce(0) { $0 + ($1["text"] as? String ?? "").count }
        XCTAssertLessThanOrEqual(total, 5000)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(out["omitted"] as? Int, 8)
        let recentOnly = body(AIToolEngine.run(tool: "shakeboard_context", args: ["since_hours": 2, "max_chars": 32000], snapshot: snap(recs), now: now))
        XCTAssertEqual((recentOnly["items"] as? [Any])?.count, 3)   // 0, 1 and 2 hours ago
        // max_chars is clamped to the cap.
        let clamped = body(AIToolEngine.run(tool: "shakeboard_context", args: ["max_chars": 10_000_000], snapshot: snap(recs), now: now))
        XCTAssertEqual(clamped["max_chars"] as? Int, MCPTools.contextMaxChars)
    }

    func testStatsHasNoContent() {
        let recs = [rec("secret plans", app: "Notes"), rec("more", app: "Notes"), rec("", kind: .image, app: "Preview")]
        let out = AIToolEngine.run(tool: "shakeboard_stats", args: [:], snapshot: snap(recs, shelf: ["a.pdf"]))
        let b = body(out)
        XCTAssertEqual(b["total"] as? Int, 3)
        XCTAssertNil(b["hidden_from_ai"], "no hidden-count oracle")
        XCTAssertEqual(b["shelf_files"] as? Int, 1)
        XCTAssertEqual((b["by_kind"] as? [String: Int])?["text"], 2)
        XCTAssertFalse(out.text.contains("secret plans"))
    }
}

// MARK: - Socket server + service

final class AIBridgeSocketTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        // Short path: sun_path is 104 bytes, and the test temp dir is long.
        root = URL(fileURLWithPath: "/tmp/pmcp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func perms(_ path: String) -> Int {
        var st = stat(); lstat(path, &st); return Int(st.st_mode & 0o777)
    }

    func testRoundTripPermissionsAndStop() throws {
        let dir = root.appendingPathComponent("mcp")
        let server = AIBridgeServer(dir: dir, validatePeer: AIPeerCheck.sameUser) { req, _ in
            MCPBridge.Response(ok: true, text: "echo \(req.tool) from \(req.client)")
        }
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(perms(dir.path), 0o700)
        XCTAssertEqual(perms(server.socketPath), 0o600)
        let req = MCPBridge.Request(client: "t", clientVersion: "", tool: "shakeboard_stats", args: [:]).encode()!
        let exp = expectation(description: "reply")
        var reply: MCPBridge.Response?
        DispatchQueue.global().async {
            reply = UnixSocket.roundTrip(path: server.socketPath, request: req).flatMap(MCPBridge.Response.decode)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(reply?.text, "echo shakeboard_stats from t")
        // Garbage gets a polite refusal, not a crash.
        var bad: MCPBridge.Response?
        let exp2 = expectation(description: "bad")
        DispatchQueue.global().async {
            bad = UnixSocket.roundTrip(path: server.socketPath, request: Data("hello\n".utf8)).flatMap(MCPBridge.Response.decode)
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 5)
        XCTAssertEqual(bad?.code, "bad_request")
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: server.socketPath))
    }

    func testPeerRejected() throws {
        let server = AIBridgeServer(dir: root.appendingPathComponent("mcp"), validatePeer: { _ in false }) { _, _ in
            XCTFail("handler must not run"); return MCPBridge.Response(ok: true, text: "")
        }
        try server.start()
        defer { server.stop() }
        let exp = expectation(description: "reply")
        var reply: MCPBridge.Response?
        DispatchQueue.global().async {
            let req = MCPBridge.Request(client: "t", clientVersion: "", tool: "shakeboard_stats", args: [:]).encode()!
            reply = UnixSocket.roundTrip(path: server.socketPath, request: req).flatMap(MCPBridge.Response.decode)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(reply?.code, "peer")
        XCTAssertEqual(reply?.ok, false)
    }

    func testRealHelperPathCheckRejectsThisProcess() throws {
        // The test host is ShakeBoard.app itself, not its shakeboard-mcp: the full check must refuse it.
        let server = AIBridgeServer(dir: root.appendingPathComponent("mcp"), validatePeer: AIPeerCheck.validate) { _, _ in
            MCPBridge.Response(ok: true, text: "should not happen")
        }
        try server.start()
        defer { server.stop() }
        let exp = expectation(description: "reply")
        var reply: MCPBridge.Response?
        DispatchQueue.global().async {
            let req = MCPBridge.Request(client: "t", clientVersion: "", tool: "shakeboard_stats", args: [:]).encode()!
            reply = UnixSocket.roundTrip(path: server.socketPath, request: req).flatMap(MCPBridge.Response.decode)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(reply?.code, "peer")
    }

    func testRefusesUnsafeDirAndOccupiedPath() throws {
        // A symlinked mcp dir is refused (it could point anywhere).
        let target = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("mcp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try AIBridgeServer(dir: link, validatePeer: { _ in true }) { _, _ in .init(ok: true, text: "") }.start())
        try FileManager.default.removeItem(at: link)
        // A regular file where the socket goes is left alone, and start fails.
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        let squatter = link.appendingPathComponent(MCPBridge.socketName)
        try Data("keep me".utf8).write(to: squatter)
        XCTAssertThrowsError(try AIBridgeServer(dir: link, validatePeer: { _ in true }) { _, _ in .init(ok: true, text: "") }.start())
        XCTAssertEqual(try String(contentsOf: squatter, encoding: .utf8), "keep me")
        // A loose dir is tightened to 0700.
        try FileManager.default.removeItem(at: squatter)
        chmod(link.path, 0o755)
        let s = AIBridgeServer(dir: link, validatePeer: { _ in true }) { _, _ in .init(ok: true, text: "") }
        try s.start(); s.stop()
        XCTAssertEqual(perms(link.path), 0o700)
    }

    func testHelperRefusesAnUnverifiedServer() throws {
        let server = AIBridgeServer(dir: root.appendingPathComponent("mcp"), validatePeer: { _ in true }) { _, _ in
            MCPBridge.Response(ok: true, text: "fake clipboard")
        }
        try server.start()
        defer { server.stop() }
        let exp = expectation(description: "reply")
        var result: Result<Data, UnixSocket.TripError>?
        DispatchQueue.global().async {
            let req = MCPBridge.Request(client: "t", clientVersion: "", tool: "shakeboard_stats", args: [:]).encode()!
            // The helper's check: the listener must be ShakeBoard.app. This test process isn't that bundle path.
            let shakeboard = URL(fileURLWithPath: "/Applications/ShakeBoard.app")
            result = UnixSocket.roundTrip(path: server.socketPath, request: req, verify: { CodeIdentity.verifyPeer($0, expected: shakeboard) })
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        if case .failure(.untrusted)? = result {} else { XCTFail("expected untrusted, got \(String(describing: result))") }
    }

    func testPathTooLong() {
        let deep = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 110), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: deep) }
        XCTAssertThrowsError(try AIBridgeServer(dir: deep, validatePeer: { _ in true }) { _, _ in .init(ok: true, text: "") }.start())
    }
}

@MainActor
final class AIBridgeServiceTests: XCTestCase {
    static let claude = AIInvoker(key: "team:Q6L2SF6YDW:com.anthropic.claude-code", label: "claude")
    private func call(_ svc: AIBridgeService, client: String = "claude-code", tool: String = "shakeboard_stats",
                      invoker: AIInvoker? = AIBridgeServiceTests.claude) -> MCPBridge.Response {
        let exp = expectation(description: "call")
        var out: MCPBridge.Response!
        DispatchQueue.global().async {
            out = svc.handleOffMain(MCPBridge.Request(client: client, clientVersion: "", tool: tool, args: [:]), invoker: invoker)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return out
    }

    func testDisabledConsentAndRun() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shakeboard-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: MCPBridge.socketDir(base: base), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let d = UserDefaults(suiteName: "shakeboard.tests.svc.\(UUID().uuidString)")!
        let svc = AIBridgeService(baseDir: base)
        svc.prefs = { PerchPrefs(defaults: d) }
        var asked: [String] = []
        var pendingDone: ((Bool) -> Void)?
        svc.askConsent = { _, inv, done in asked.append(inv.key); pendingDone = done }
        svc.setConsent = { key, _, allow in var p = PerchPrefs(defaults: d); var c = p.aiClients; c[key] = allow; p.aiClients = c }
        svc.snapshot = { AISnapshot(records: [], hiddenCount: 0, shelfNames: [], redactContacts: true) }

        XCTAssertEqual(call(svc).code, "disabled")
        XCTAssertTrue(asked.isEmpty, "never prompts while access is off")

        var p = PerchPrefs(defaults: d); p.aiAccessEnabled = true
        XCTAssertEqual(call(svc).code, "pending")
        XCTAssertEqual(call(svc).code, "pending")
        XCTAssertEqual(asked, [Self.claude.key], "one prompt per app while it's open")

        pendingDone?(true)
        let ok = call(svc)
        XCTAssertTrue(ok.ok, ok.text)
        XCTAssertTrue(ok.text.contains("\"untrusted_content\":true"))
        // Another program claiming to be "claude-code" doesn't inherit the grant: consent follows the launcher.
        let impostor = AIInvoker(key: "path:/tmp/evil", label: "evil")
        XCTAssertEqual(call(svc, client: "claude-code", invoker: impostor).code, "pending")
        XCTAssertEqual(call(svc, invoker: nil).code, "unidentified")

        var q = PerchPrefs(defaults: d); q.aiClients = [Self.claude.key: false]
        XCTAssertEqual(call(svc).code, "denied")

        // Everything above was audited, content-free. Records hop through main.async: let them land first.
        let deadline = Date().addingTimeInterval(5)
        while svc.audit.load().count < 7, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        svc.audit.flush()
        let log = svc.audit.load()
        XCTAssertEqual(log.map(\.outcome), ["denied", "unidentified", "pending", "ok", "pending", "pending", "disabled"])
    }

    func testRateLimitThroughService() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shakeboard-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: MCPBridge.socketDir(base: base), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let d = UserDefaults(suiteName: "shakeboard.tests.svc.\(UUID().uuidString)")!
        let codex = AIInvoker(key: "team:2DC432GLL2:codex", label: "codex")
        var p = PerchPrefs(defaults: d); p.aiAccessEnabled = true; p.aiClients = [codex.key: true]
        let svc = AIBridgeService(baseDir: base)
        svc.prefs = { PerchPrefs(defaults: d) }
        let fixed = Date()
        svc.clock = { fixed }
        // Unapproved callers hammering first don't use up the allowed app's quota.
        for _ in 0..<40 { _ = call(svc, client: "x", invoker: AIInvoker(key: "path:/tmp/x", label: "x")) }
        for _ in 0..<30 { XCTAssertTrue(call(svc, client: "codex", invoker: codex).ok) }
        XCTAssertEqual(call(svc, client: "codex", invoker: codex).code, "rate_limited")
    }

    func testPromptCap() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shakeboard-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: MCPBridge.socketDir(base: base), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let d = UserDefaults(suiteName: "shakeboard.tests.svc.\(UUID().uuidString)")!
        var p = PerchPrefs(defaults: d); p.aiAccessEnabled = true
        let svc = AIBridgeService(baseDir: base)
        svc.prefs = { PerchPrefs(defaults: d) }
        var shown = 0
        svc.askConsent = { _, _, _ in shown += 1 }
        let codes = (0..<6).map { call(svc, invoker: AIInvoker(key: "path:/tmp/app\($0)", label: "a")).code }
        XCTAssertEqual(shown, AIBridgeService.maxOpenPrompts)
        XCTAssertEqual(codes.filter { $0 == "busy" }.count, 6 - AIBridgeService.maxOpenPrompts)
    }

    func testStoreAsksBeforeDroppingClips() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("shakeboard-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ClipStore(baseDir: base)
        var calls = 0
        store.willDrop = { calls += 1 }
        store.load()          // retention runs inside load()
        let afterLoad = calls
        XCTAssertGreaterThan(afterLoad, 0)
        store.prune()
        store.clearAll()
        XCTAssertEqual(calls, afterLoad + 2)
    }

    func testHiddenClipsStore() {
        let d = UserDefaults(suiteName: "shakeboard.tests.hidden.\(UUID().uuidString)")!
        let h = AIHiddenClips(defaults: d)
        let a = UUID(), b = UUID()
        h.toggle(a); h.toggle(b)
        XCTAssertTrue(AIHiddenClips(defaults: d).isHidden(a))
        h.prune(keeping: [b])
        XCTAssertEqual(AIHiddenClips(defaults: d).ids, [b])
        h.toggle(b)
        XCTAssertFalse(h.isHidden(b))
    }
}
