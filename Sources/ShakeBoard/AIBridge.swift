//
//  AIBridge.swift
//  ShakeBoard -- the app end of the MCP bridge: an owner-only Unix socket the bundled `shakeboard-mcp` helper talks to,
//  the peer check, the service that gates + runs tool calls, and the one-time consent panel.
//
//  Socket: <data>/mcp/shakeboard.sock. The dir is 0700 and must be a real directory owned by this user (never a
//  symlink); the socket is 0600. Every connection must come from this uid (getpeereid). The peer's code is
//  then checked via its audit token: it must be THIS bundle's shakeboard-mcp and, when ShakeBoard itself is signed with a
//  Team ID, signed by that same team. The checks are hygiene -- any process running as the user can launch the
//  real helper -- so the real gates are the master switch, per-client consent, redaction and the audit log.
//

import AppKit
import SwiftUI
import Security
import Darwin

// MARK: - Socket server

final class AIBridgeServer {
    enum StartError: Error, CustomStringConvertible {
        case pathTooLong, unsafeDir(String), occupied, socket(String)
        var description: String {
            switch self {
            case .pathTooLong: return "ShakeBoard's data folder path is too long for a local socket."
            case .unsafeDir(let why): return "ShakeBoard's AI connection folder isn't safe to use (\(why))."
            case .occupied: return "Something that isn't ShakeBoard's socket is in the way at mcp/shakeboard.sock."
            case .socket(let why): return "ShakeBoard couldn't open its local AI connection (\(why))."
            }
        }
    }

    let dir: URL
    var socketPath: String { dir.appendingPathComponent(MCPBridge.socketName).path }
    private let validatePeer: (Int32) -> Bool
    private let handler: (MCPBridge.Request, Int32) -> MCPBridge.Response
    var onPeerRefused: () -> Void = {}       // audited (content-free) by the service
    private let work = DispatchQueue(label: "com.thisradlife.shakeboard.ai.bridge")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var active = 0
    static let maxConnections = 4

    init(dir: URL, validatePeer: @escaping (Int32) -> Bool, handler: @escaping (MCPBridge.Request, Int32) -> MCPBridge.Response) {
        self.dir = dir
        self.validatePeer = validatePeer
        self.handler = handler
    }

    // Creates (or re-secures) the 0700 dir, removes a stale socket of ours, binds, 0600, listens.
    static func prepareDir(_ dir: URL) throws {
        let path = dir.path
        var st = stat()
        if lstat(path, &st) != 0 {
            guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw StartError.unsafeDir("can't create it") }
            guard lstat(path, &st) == 0 else { throw StartError.unsafeDir("can't read it") }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw StartError.unsafeDir("not a plain folder") }
        guard st.st_uid == getuid() else { throw StartError.unsafeDir("owned by another user") }
        guard chmod(path, 0o700) == 0 else { throw StartError.unsafeDir("can't set permissions") }
    }

    func start() throws {
        try FileManager.default.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.prepareDir(dir)
        let path = socketPath
        guard var addr = UnixSocket.address(path) else { throw StartError.pathTooLong }
        var st = stat()
        if lstat(path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { throw StartError.occupied }
            unlink(path)    // a stale socket from a previous run (only one ShakeBoard runs at a time)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket("socket") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw StartError.socket("bind errno \(errno)") }
        // The dir is already 0700, so nobody else can reach the socket in the instant before this chmod.
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); unlink(path); throw StartError.socket("listen") }
        lock.lock(); listenFD = fd; running = true; lock.unlock()
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "ShakeBoard AI bridge"
        t.start()
    }

    func stop() {
        lock.lock()
        let fd = listenFD
        running = false; listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd); unlink(socketPath) }
    }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 500)
            if r <= 0 { continue }
            let c = accept(fd, nil, nil)
            if c < 0 { if !isRunning { break }; continue }
            lock.lock()
            let full = active >= Self.maxConnections
            if !full { active += 1 }
            lock.unlock()
            if full { close(c); continue }
            work.async { [weak self] in
                self?.serve(c)
                close(c)
                guard let self else { return }
                self.lock.lock(); self.active -= 1; self.lock.unlock()
            }
        }
    }

    private func serve(_ c: Int32) {
        UnixSocket.setTimeouts(c, seconds: 5)
        guard validatePeer(c) else {
            onPeerRefused()
            _ = UnixSocket.writeAll(c, MCPBridge.Response(ok: false, text: "ShakeBoard refused this connection.", code: "peer").encode())
            return
        }
        guard let line = UnixSocket.readLine(c, limit: MCPBridge.maxRequestBytes),
              let req = MCPBridge.Request.decode(line) else {
            _ = UnixSocket.writeAll(c, MCPBridge.Response(ok: false, text: "ShakeBoard couldn't read that request.", code: "bad_request").encode())
            return
        }
        _ = UnixSocket.writeAll(c, handler(req, c).encode())
    }
}

// MARK: - Peer check + invoker identity

enum AIPeerCheck {
    static var expectedHelper: URL? {
        CodeIdentity.ownExecutable?.deletingLastPathComponent().appendingPathComponent("shakeboard-mcp")
            .resolvingSymlinksInPath().standardizedFileURL
    }
    static func sameUser(_ fd: Int32) -> Bool { CodeIdentity.sameUser(fd) }
    static func allowed(sameUser: Bool, peerPath: URL?, expected: URL?, teamOK: Bool) -> Bool {
        CodeIdentity.allowed(sameUser: sameUser, peerPath: peerPath, expected: expected, teamOK: teamOK)
    }
    static func validate(_ fd: Int32) -> Bool { CodeIdentity.verifyPeer(fd, expected: expectedHelper) }
}

// Who launched the helper -- Claude Code, Codex, or something else. Consent is keyed by THIS (the parent's
// verified code signature: Team ID + signing identifier, else its executable path), never by the client name the
// MCP client reports about itself, so another program can't inherit Claude Code's "Allow" by claiming its name.
//
// Threat model: this is a "which AI tool did the user approve" guard, NOT a wall against malicious code running as
// the user -- such code can read ShakeBoard's data folder directly. So the launcher identity is best-effort (a parent
// pid can in theory be reused between lookups; an interpreter like node or python is one identity for every script
// it runs), and the panel says exactly what was verified.
struct AIInvoker: Equatable {
    let key: String       // consent key: "team:<TEAM>:<identifier>" or "path:<executable>"
    let label: String     // shown in the consent panel and Settings
    var name: String = "" // short verified name for the panel headline and the audit log

    // Only the system's own shells (SIP-protected paths) are skipped -- never "anything named zsh".
    static let shells: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh", "/bin/tcsh",
                                      "/bin/csh", "/usr/bin/env", "/usr/bin/login"]

    // From the helper's connection: its parent (skipping up to 5 wrapper shells, e.g. `sh -c` launchers).
    static func from(fd: Int32) -> AIInvoker? {
        guard let helper = CodeIdentity.peerPID(fd), var pid = CodeIdentity.parentPID(of: helper) else { return nil }
        for _ in 0..<6 {
            guard let code = CodeIdentity.code(pid: pid), let path = CodeIdentity.path(code) else { return nil }
            if shells.contains(path.path), let up = CodeIdentity.parentPID(of: pid) { pid = up; continue }
            // Re-check the parent link after reading the code: if the process changed under us, fail closed.
            guard let again = CodeIdentity.code(pid: pid), CodeIdentity.path(again) == path else { return nil }
            return identity(code: code, path: path)
        }
        return nil
    }
    static func identity(code: SecCode, path: URL) -> AIInvoker {
        if let s = CodeIdentity.signer(code) {
            return AIInvoker(key: "team:\(s.team):\(s.identifier)", label: "\(s.identifier), signed by team \(s.team)",
                             name: friendly(s.identifier, fallback: path.lastPathComponent))
        }
        return AIInvoker(key: "path:\(path.path)", label: "not signed by a developer: \(path.path)",
                         name: path.lastPathComponent)
    }
    // Known signing identifiers get a friendly name (verified via the signature, unlike the MCP client name).
    static func friendly(_ identifier: String, fallback: String) -> String {
        switch identifier {
        case "com.anthropic.claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return fallback
        }
    }
}

// MARK: - Service (gate + run + audit)

@MainActor
final class AIBridgeService {
    let audit: AIAuditLog
    private var limiters: [String: AIRateLimiter] = [:]     // per verified invoker, charged only once allowed
    static let maxOpenPrompts = 3
    private(set) var startError: String?
    private var server: AIBridgeServer?
    private let dir: URL
    private var asking: Set<String> = []

    // Wired by AppDelegate.
    var prefs: () -> PerchPrefs = { PerchPrefs(defaults: PerchPaths.defaults) }
    var setConsent: (_ key: String, _ label: String, _ allowed: Bool) -> Void = { _, _, _ in }
    var snapshot: () -> AISnapshot = { AISnapshot(records: [], hiddenCount: 0, shelfNames: [], redactContacts: true) }
    var askConsent: (_ client: String, _ invoker: AIInvoker, _ done: @escaping (Bool) -> Void) -> Void = { _, _, _ in }
    var onAudit: () -> Void = {}
    var validatePeer: (Int32) -> Bool = AIPeerCheck.validate
    var clock: () -> Date = Date.init

    init(baseDir: URL = PerchPaths.base) {
        dir = MCPBridge.socketDir(base: baseDir)
        audit = AIAuditLog(dir: dir)
    }

    func start() {
        guard server == nil else { return }
        let s = AIBridgeServer(dir: dir, validatePeer: { [weak self] fd in
            // Read on the bridge queue; the closure itself is immutable after start.
            (self?.peerValidator ?? AIPeerCheck.validate)(fd)
        }, handler: { [weak self] req, fd in
            guard let self else { return MCPBridge.Response(ok: false, text: "ShakeBoard is shutting down.", code: "error") }
            return self.handleOffMain(req, invoker: AIInvoker.from(fd: fd))
        })
        peerValidator = validatePeer
        s.onPeerRefused = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.record(AIAuditEntry(time: Date(), client: "unverified-process", tool: "-", outcome: "peer_refused"))
                }
            }
        }
        do { try s.start(); server = s; startError = nil }
        catch { startError = "\(error)"; NSLog("ShakeBoard AI bridge: \(error)") }
    }
    func stop() { server?.stop(); server = nil }
    var isListening: Bool { server?.isRunning ?? false }
    nonisolated(unsafe) private var peerValidator: (Int32) -> Bool = AIPeerCheck.validate

    private enum Prep { case respond(MCPBridge.Response, AIAuditEntry); case run(AISnapshot, String) }

    // Called on the bridge queue: decide + snapshot on main, run the tool (disk reads, redaction) off main.
    nonisolated func handleOffMain(_ req: MCPBridge.Request, invoker: AIInvoker?) -> MCPBridge.Response {
        let prep: Prep = DispatchQueue.main.sync { MainActor.assumeIsolated { self.prepare(req, invoker: invoker) } }
        switch prep {
        case .respond(let resp, let entry):
            DispatchQueue.main.async { MainActor.assumeIsolated { self.record(entry) } }
            return resp
        case .run(let snap, let client):
            let out = AIToolEngine.run(tool: req.tool, args: req.args, snapshot: snap)
            let entry = AIAuditEntry(time: Date(), client: client, tool: req.tool, outcome: out.ok ? "ok" : "bad_request",
                                     items: out.items, redactions: out.redactions, bytes: out.text.utf8.count)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.record(entry) } }
            return MCPBridge.Response(ok: out.ok, text: out.text, code: out.ok ? "ok" : "bad_request")
        }
    }

    private func prepare(_ req: MCPBridge.Request, invoker: AIInvoker?) -> Prep {
        let reported = AIClientID.normalize(req.client)
        // Headline + audit use the VERIFIED launcher; the self-reported MCP client name is only a fallback label.
        // Audit identity is never the caller's own claim: an unidentified launcher is logged as such.
        let client = invoker.map { $0.name.isEmpty ? "unnamed-launcher" : $0.name } ?? "unidentified"
        let name = invoker.map { $0.name.isEmpty ? AIClientID.displayName(reported) : $0.name } ?? AIClientID.displayName(reported)
        let tool = MCPTools.names.contains(req.tool) ? req.tool : "unknown"
        let p = prefs()
        func refuse(_ code: String, _ msg: String) -> Prep {
            .respond(MCPBridge.Response(ok: false, text: msg, code: code),
                     AIAuditEntry(time: clock(), client: client, tool: tool, outcome: code))
        }
        guard p.aiAccessEnabled else {
            return refuse("disabled", AIGate.decide(enabled: false, consent: nil, rateOK: { true }, clientName: name).message)
        }
        guard let invoker else {
            return refuse("unidentified", "ShakeBoard couldn't tell which app launched shakeboard-mcp, so it can't ask for permission.")
        }
        let now = clock()
        let decision = AIGate.decide(enabled: true, consent: p.aiClients[invoker.key], rateOK: {
            let l = self.limiters[invoker.key] ?? AIRateLimiter()
            self.limiters[invoker.key] = l
            return l.allow(now: now)
        }, clientName: name)
        switch decision {
        case .refuse(let code, let msg): return refuse(code, msg)
        case .askUser(let msg):
            if !asking.contains(invoker.key) {
                // A burst of new identities can't stack up panels.
                guard asking.count < Self.maxOpenPrompts else {
                    return refuse("busy", "ShakeBoard is already asking about other apps. Try again in a moment.")
                }
                asking.insert(invoker.key)
                askConsent(reported, invoker) { [weak self] allow in
                    self?.asking.remove(invoker.key)
                    self?.setConsent(invoker.key, "\(name) -- \(invoker.label)", allow)
                }
            }
            return refuse("pending", msg)
        case .run:
            guard tool != "unknown" else { return refuse("bad_request", "Unknown tool.") }
            return .run(snapshot(), client)
        }
    }

    private func record(_ e: AIAuditEntry) { audit.append(e); onAudit() }
}

// MARK: - Consent panel

// A small floating, NON-activating panel: it never takes the keyboard from the app you're in (a stray Return
// can't approve), and there's no default button.
@MainActor
final class AIConsentPanel {
    private var panel: NSPanel?
    private var queue: [(name: String, detail: String, reported: String, done: (Bool) -> Void)] = []

    func ask(name: String, detail: String, reported: String, done: @escaping (Bool) -> Void) {
        queue.append((name, detail, reported, done))
        if panel == nil { showNext() }
    }

    private func showNext() {
        guard let next = queue.first else { panel?.orderOut(nil); panel = nil; return }
        let view = AIConsentView(name: next.name, detail: next.detail, reported: next.reported) { [weak self] allow in
            guard let self else { return }
            let item = self.queue.removeFirst()
            item.done(allow)
            self.panel?.orderOut(nil); self.panel = nil
            self.showNext()
        }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230),
                        styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: view)
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: vf.maxX - 440, y: vf.maxY - 250))
        }
        p.orderFrontRegardless()
        panel = p
    }

    // Dev: write the panel's own rendering (scripts can't screen-record).
    func snapshot(to url: URL) {
        guard let v = panel?.contentView, let png = DebugSnapshot.png(of: v) else { return }
        try? png.write(to: url)
    }
}

struct AIConsentView: View {
    let name: String        // verified (code signature) name of the program that launched shakeboard-mcp
    let detail: String      // what was verified
    let reported: String    // what the MCP client says it is (unverified)
    let decide: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").font(.system(size: 22)).foregroundStyle(Color.accentColor)
                Text("Allow \(name) to read your clipboard history?").font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("\(name) asked ShakeBoard for your copies through ShakeBoard's AI connection. It can search and read them; "
                 + "ShakeBoard replaces the passwords, keys and tokens it recognizes with [REDACTED] (best effort). It can't "
                 + "change or delete anything. Every request is logged in Settings > Privacy & AI, where you can revoke this.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Verified: \(detail)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
            Text("Says it is: \(reported) (not verified)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
            HStack {
                Spacer()
                Button("Don't Allow") { decide(false) }
                Button("Allow") { decide(true) }
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}
