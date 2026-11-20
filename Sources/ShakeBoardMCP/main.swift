//
//  main.swift
//  shakeboard-mcp -- the stdio MCP server Claude Code / Codex launch. Bundled at
//  ShakeBoard.app/Contents/MacOS/shakeboard-mcp.
//
//  A dumb pipe on purpose: it speaks MCP on stdin/stdout and forwards each tool call to the RUNNING ShakeBoard
//  app over its owner-only Unix socket. It never opens ShakeBoard's data folder, so every check (master switch,
//  consent, redaction, rate limit, audit) happens in the app. stdout carries protocol only; diagnostics go
//  to stderr.
//

import Foundation
import Darwin

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

let socketPaths = MCPBridge.dataDirCandidates().map { MCPBridge.socketURL(base: $0).path }

let notRunning = "ShakeBoard isn't running, so its clipboard history can't be read. Open ShakeBoard (Spotlight: ShakeBoard) and try again."

let server = MCPServer { client, version, tool, args in
    guard let req = MCPBridge.Request(client: client, clientVersion: version, tool: tool, args: args).encode() else {
        return (false, "That request couldn't be encoded.")
    }
    guard socketPaths.allSatisfy({ UnixSocket.address($0) != nil }) else {
        return (false, "ShakeBoard's data folder path is too long for its local connection.")
    }
    // Before sending anything, check who is listening: it must be this bundle's ShakeBoard (same user, same Team ID).
    // Otherwise another process could replace the socket and feed back made-up "clipboard" content.
    // shakeboard-mcp lives at ShakeBoard.app/Contents/MacOS/; Security reports an app's path as its bundle (ShakeBoard.app).
    let shakeboard = CodeIdentity.ownExecutable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var line: Data?
    var foundUntrustedPeer = false
    for socketPath in socketPaths {
        switch UnixSocket.roundTrip(path: socketPath, request: req, timeout: 15,
                                    verify: { CodeIdentity.verifyPeer($0, expected: shakeboard) }) {
        case .success(let data):
            line = data
        case .failure(.unreachable):
            continue
        case .failure(.untrusted):
            foundUntrustedPeer = true
            continue
        case .failure(.io):
            return (false, "ShakeBoard didn't answer in time. Try again.")
        }
        if line != nil { break }
    }
    guard let line else {
        if foundUntrustedPeer {
            return (false, "Refused: the process answering at ShakeBoard's socket isn't this copy of ShakeBoard.")
        }
        return (false, notRunning)
    }
    guard let resp = MCPBridge.Response.decode(line) else {
        return (false, "ShakeBoard sent a reply this helper doesn't understand -- update ShakeBoard.")
    }
    return (resp.ok, resp.text)
}

// Newline-delimited JSON-RPC on stdin. A line over 1 MB is answered with a parse error and skipped.
let maxLine = 1 << 20
var pending = Data()
var dropping = false
let stdinHandle = FileHandle.standardInput
while true {
    let chunk = stdinHandle.availableData
    if chunk.isEmpty { break }   // EOF: the client closed us
    var rest = chunk[...]
    while let nl = rest.firstIndex(of: 0x0A) {
        let piece = rest[rest.startIndex..<nl]
        rest = rest[rest.index(after: nl)...]
        if dropping { dropping = false; pending.removeAll(); continue }
        pending.append(contentsOf: piece)
        let line = pending
        pending.removeAll(keepingCapacity: true)
        if line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
        if let out = server.handle(line: line) { FileHandle.standardOutput.write(out) }
    }
    if dropping { continue }
    pending.append(contentsOf: rest)
    if pending.count > maxLine {
        pending.removeAll()
        dropping = true
        FileHandle.standardOutput.write(MCPServer.error(id: NSNull(), code: -32700, message: "Message too large"))
    }
}
exit(0)
