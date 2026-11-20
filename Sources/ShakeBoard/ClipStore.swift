//
//  ClipStore.swift
//  ShakeBoard -- clipboard history: normalization (pure) + crash-consistent persistence.
//
//  On disk (all under PerchPaths.base/Clips, never inside Shelf/):
//    clips.json            versioned index (newest-used first), written LAST
//    <uuid>/<i>-<j>.bin    one sidecar per kept representation (item i, rep j)
//    .staging-<uuid>/      in-flight payload; renamed to <uuid>/ only once fully written
//  Launch reconciles the two: payload dirs not in the index are deleted, index entries whose payload
//  is missing are dropped. A crash at any point therefore leaves either the old or the new state,
//  never a dangling reference.
//
//  Retention: newest-used 200, or 7 days since last use, or 500 MB total -- whichever bites first.
//  Clips referenced by the paste stack are pinned and never evicted while queued.
//  Clear History physically deletes payloads (no tombstones: nothing secret lingers).
//

import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Model

enum ClipKind: String, Codable { case text, url, image, files }

struct StoredRep: Codable, Equatable {
    let item: Int
    let type: String
    let file: String
    let bytes: Int
}

struct Clip: Codable, Identifiable, Equatable {
    let id: UUID
    var kind: ClipKind
    let createdAt: Date
    var lastUsedAt: Date
    var sourceBundleID: String?
    var sourceAppName: String?
    let contentHash: String
    var preview: String
    var reps: [StoredRep]
    var totalBytes: Int
    var pixelWidth: Int?
    var pixelHeight: Int?
    // The clip an Edit or transform was made from (v2). Optional and absent on captures, so clips.json
    // stays version 1: older builds ignore the key, and an index without it decodes as nil.
    var derivedFrom: UUID? = nil

    var imageRep: StoredRep? { reps.first { $0.type == ClipTypes.png } }
    var itemCount: Int { (reps.map(\.item).max() ?? -1) + 1 }
}

// MARK: - Normalization (pure; runs off main)

struct NormalizedClip {
    let kind: ClipKind
    let preview: String
    let items: [[RawRep]]
    let hash: String
    let pixelWidth: Int?
    let pixelHeight: Int?
    var totalBytes: Int { items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } } }
}

enum ClipNormalizer {
    static let previewChars = 300

    static func normalize(_ snap: RawSnapshot) -> NormalizedClip? {
        let items = snap.items
        guard !items.isEmpty else { return nil }
        let has: (String) -> Bool = { t in items.contains { $0.contains { $0.type == t } } }

        // 1) Files win: Finder puts file URLs + a TIFF icon preview + the filename as text. Shelving the
        //    preview icon as an "image" would be wrong, so keep only the URL + its text.
        if has(ClipTypes.fileURL) {
            let kept = items.map { $0.filter { $0.type == ClipTypes.fileURL || $0.type == ClipTypes.plainText } }
                .filter { !$0.isEmpty }
            let names = kept.compactMap { reps -> String? in
                guard let d = reps.first(where: { $0.type == ClipTypes.fileURL })?.data,
                      let s = String(data: d, encoding: .utf8), let u = URL(string: s) else { return nil }
                return u.lastPathComponent
            }
            let preview = names.isEmpty ? "Files" : names.joined(separator: ", ")
            return finish(.files, String(preview.prefix(previewChars)), kept, nil, nil)
        }

        // 2) Text. An app that also attaches a rendered image of the text (Word, Pages) is still a TEXT
        //    copy -- drop the image reps so the history shows text and nothing shelves.
        let plain = firstData(items, ClipTypes.plainText).flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasImage = has(ClipTypes.png) || has(ClipTypes.tiff)
        let hasRich = has(ClipTypes.rtf) || has(ClipTypes.html) || has(ClipTypes.url)
        if !plain.isEmpty || (!hasImage && hasRich) {
            let kept = items.map { reps in
                reps.filter { r in
                    switch r.type {
                    case ClipTypes.plainText, ClipTypes.url: return r.data.count <= ClipLimits.maxTextBytes
                    case ClipTypes.rtf, ClipTypes.html: return r.data.count <= ClipLimits.maxRichTextBytes
                    default: return false
                    }
                }
            }.filter { !$0.isEmpty }
            // RTF-only / HTML-only / URL-only copies are accepted with a preview derived from the rich data.
            let shown = !plain.isEmpty ? plain : derivedText(kept)
            guard !kept.isEmpty, !shown.isEmpty else { return nil }
            let kind: ClipKind = (has(ClipTypes.url) || isSingleWebURL(shown)) ? .url : .text
            return finish(kind, collapse(shown), kept, nil, nil)
        }

        // 3) Images: every bounded image item (multi-image copies keep all of them). Native PNG bytes are
        //    kept; TIFF is converted only after a header-only pixel check.
        var pngs: [[RawRep]] = []
        var firstSize: (w: Int, h: Int)?
        for reps in items {
            let png = reps.first(where: { $0.type == ClipTypes.png })?.data
            let tiff = reps.first(where: { $0.type == ClipTypes.tiff })?.data
            guard let src = png ?? tiff, let size = pixelSize(src), withinPixelCap(size) else { continue }
            guard let out = png ?? convertToPNG(src) else { continue }
            pngs.append([RawRep(type: ClipTypes.png, data: out)])
            if firstSize == nil { firstSize = size }
        }
        guard let size = firstSize else { return nil }
        let preview = pngs.count == 1 ? "Image \(size.w) x \(size.h)" : "\(pngs.count) images"
        return finish(.image, preview, pngs, size.w, size.h)
    }

    // w * h without trapping: a hostile header can claim dimensions whose product overflows Int.
    static func withinPixelCap(_ size: (w: Int, h: Int)) -> Bool {
        let (product, overflow) = size.w.multipliedReportingOverflow(by: size.h)
        return !overflow && product <= ClipLimits.maxImagePixels
    }

    // Readable text from rich reps when there's no plain text: URL string, RTF text, or tag-stripped HTML.
    static func derivedText(_ items: [[RawRep]]) -> String {
        if let d = firstData(items, ClipTypes.url), let s = String(data: d, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { return t }
        }
        if let d = firstData(items, ClipTypes.rtf),
           let a = try? NSAttributedString(data: d, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                           documentAttributes: nil) {
            let t = a.string.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { return t }
        }
        if let d = firstData(items, ClipTypes.html), let s = String(data: d, encoding: .utf8) {
            // No HTML parser here: NSAttributedString's HTML importer is main-thread/WebKit only.
            var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            for (e, r) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
                t = t.replacingOccurrences(of: e, with: r)
            }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    // Framed, unambiguous hash input: kind, then counts and byte lengths before every variable field, so
    // ("x" + "public.html", "y") can never collide with ("x", "public.htmly").
    static func contentHash(_ kind: ClipKind, _ items: [[RawRep]]) -> String {
        var h = SHA256()
        func u64(_ n: Int) { var v = UInt64(n).bigEndian; withUnsafeBytes(of: &v) { h.update(bufferPointer: $0) } }
        func field(_ d: Data) { u64(d.count); h.update(data: d) }
        field(Data(kind.rawValue.utf8))
        u64(items.count)
        for reps in items {
            u64(reps.count)
            for r in reps { field(Data(r.type.utf8)); field(r.data) }
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func finish(_ kind: ClipKind, _ preview: String, _ items: [[RawRep]],
                               _ w: Int?, _ h: Int?) -> NormalizedClip {
        NormalizedClip(kind: kind, preview: preview, items: items, hash: contentHash(kind, items),
                       pixelWidth: w, pixelHeight: h)
    }

    private static func firstData(_ items: [[RawRep]], _ type: String) -> Data? {
        for reps in items { if let d = reps.first(where: { $0.type == type })?.data { return d } }
        return nil
    }
    static func collapse(_ s: String) -> String {
        let one = s.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "  ")
        return String(one.prefix(previewChars))
    }
    static func isSingleWebURL(_ s: String) -> Bool {
        guard !s.contains(where: { $0.isWhitespace }), let u = URL(string: s),
              let scheme = u.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && u.host != nil
    }

    // Pixel dimensions from the header only -- no full decode, so a hostile tiny-file/huge-image can't
    // blow memory before we've decided to reject it.
    static func pixelSize(_ data: Data) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        return (w, h)
    }
    static func pixelSize(_ url: URL) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        return (w, h)
    }
    // AddImageFromSource keeps the color profile, alpha and orientation metadata.
    static func convertToPNG(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(dst, src, 0, nil)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }
}

// MARK: - Store

struct ClipStoreFileOperations {
    let contentsOfDirectory: (URL) throws -> [URL]
    let removeItem: (URL) throws -> Void
    let writeAtomically: (Data, URL) throws -> Void

    static let live = ClipStoreFileOperations(
        contentsOfDirectory: {
            try FileManager.default.contentsOfDirectory(
                at: $0,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        },
        removeItem: { try FileManager.default.removeItem(at: $0) },
        writeAtomically: { try $0.write(to: $1, options: .atomic) })
}

@MainActor
final class ClipStore: ObservableObject {
    typealias FileOperations = ClipStoreFileOperations
    @Published private(set) var clips: [Clip] = []          // most recently used first
    @Published private(set) var lastSaveFailed = false
    // History could not be safely verified (for example, a transient listing/read failure or an index that
    // could not be set aside). The store is NOT treated as empty and clean: capture is refused and the index
    // is never rewritten, so the files stay put for a later load (or Clear History after failed quarantine).
    @Published private(set) var isDegraded = false
    // History needs attention (a failed Clear History or a load that could not be safely verified).
    @Published private(set) var clearFailed = false

    let dir: URL
    private let baseDir: URL
    private let clock: () -> Date
    private let io = DispatchQueue(label: "com.thisradlife.shakeboard.clips.io")
    private let fm = FileManager.default
    private let fileOperations: FileOperations
    // Clear History may recover a failed quarantine, but it must not act on an empty in-memory view when
    // load never obtained an authoritative index. Only a new load may clear this fail-closed state.
    private(set) var clearBlockedByUnavailableIndex = false

    var maxCount = 200
    var maxAge: TimeInterval = 7 * 24 * 3600
    var maxBytes = 500 * 1024 * 1024
    // Clip ids the paste stack still needs -- never evicted while referenced.
    var pinned: () -> Set<UUID> = { [] }
    // Called just before clips can leave the index (retention, Clear History, delete), while every clip is still
    // in `clips` -- the AI bridge uses it to copy "hidden from AI" down to descendants before an ancestor goes.
    var willDrop: () -> Void = {}
    // Bumped by clearAll(): an ingest that started before a Clear must not resurrect its clip.
    private(set) var generation = 0

    private struct IndexFile: Codable { var version: Int; var clips: [Clip] }
    private static let currentVersion = 1

    init(baseDir: URL = PerchPaths.base, clock: @escaping () -> Date = Date.init,
         fileOperations: FileOperations = .live) {
        self.baseDir = baseDir
        self.dir = baseDir.appendingPathComponent("Clips", isDirectory: true)
        self.clock = clock
        self.fileOperations = fileOperations
    }

    private var indexURL: URL { dir.appendingPathComponent("clips.json") }
    private var clearPendingURL: URL { dir.appendingPathComponent("clear-pending") }
    func payloadDir(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString, isDirectory: true) }

    // MARK: load + reconcile
    func load() {
        prepareDir()
        isDegraded = false
        clearFailed = false
        clearBlockedByUnavailableIndex = false
        if itemExists(at: clearPendingURL) {
            recoverPendingClear()
            return
        }
        var loaded: [Clip] = []
        switch indexState() {
        case .unavailable:
            clearBlockedByUnavailableIndex = true
            isDegraded = true
            clearFailed = true
            NSLog("ShakeBoard: Clips could not be listed -- history paused without changing it")
            return
        case .damaged:
            if !quarantineAll("clips.json is not a regular file") { isDegraded = true }
            clips = []
            return
        case .regular:
            guard let data = try? Data(contentsOf: indexURL) else {
                clearBlockedByUnavailableIndex = true
                isDegraded = true
                clearFailed = true
                NSLog("ShakeBoard: clips.json could not be read -- history paused without changing it")
                return
            }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let file = try? dec.decode(IndexFile.self, from: data), file.version <= Self.currentVersion {
                loaded = file.clips
            } else {
                // Unreadable or future index: set the WHOLE Clips dir aside (index + payloads together) and
                // start empty. Never reconcile against an index we couldn't read -- that would delete every
                // payload as an "orphan".
                if !quarantineAll("unreadable or future-version clips.json") { isDegraded = true }
                clips = []
                return
            }
        case .missing:
            break
        }
        // Drop index entries whose payload is incomplete.
        var dirty = false
        loaded = loaded.filter { clip in
            let ok = clip.reps.allSatisfy { fm.fileExists(atPath: payloadDir(clip.id).appendingPathComponent($0.file).path) }
            if !ok { dirty = true }
            return ok
        }
        clips = loaded.sorted { $0.lastUsedAt > $1.lastUsedAt }
        // Delete everything under Clips/ the index doesn't own (orphan payloads, stale staging dirs, a
        // legacy clips.json.corrupt). If that can't be done -- removal fails or Clips/ can't even be listed
        // -- the leftovers on disk put the store in the degraded state: no capture, menu notice. This is how
        // a failed reconcile stays failed across a restart; Clear History also has a durable marker.
        if Self.removeUnowned(in: dir, keeping: Set(clips.map { $0.id.uuidString }),
                              fileOperations: fileOperations) == false {
            isDegraded = true
            clearFailed = true
            NSLog("ShakeBoard: Clips has entries the index doesn't own that couldn't be removed -- history paused")
            return
        }
        if evict() || dirty { saveIndex() }
    }

    // Remove every entry in `dir` except clips.json and `keeping` (payload dir names). Returns true only if
    // the directory could be listed, every removal was attempted, and a re-listing shows nothing unowned.
    nonisolated static func removeUnowned(in dir: URL, keeping: Set<String>,
                                          preservingRegularFiles: Set<String> = [],
                                          fileOperations: FileOperations = .live) -> Bool {
        guard let entries = try? fileOperations.contentsOfDirectory(dir) else { return false }
        for entry in entries {
            let name = entry.lastPathComponent
            let isIndex = name == "clips.json" && isRegularFile(entry)
            let isPreservedFile = preservingRegularFiles.contains(name) && isRegularFile(entry)
            if !keeping.contains(name), !isIndex, !isPreservedFile { try? fileOperations.removeItem(entry) }
        }
        guard let after = try? fileOperations.contentsOfDirectory(dir) else { return false }
        return after.allSatisfy {
            keeping.contains($0.lastPathComponent)
                || ($0.lastPathComponent == "clips.json" && isRegularFile($0))
                || (preservingRegularFiles.contains($0.lastPathComponent) && isRegularFile($0))
        }
    }

    nonisolated private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static let quarantinePrefix = "Clips-quarantine-"

    @discardableResult
    private func quarantineAll(_ reason: String) -> Bool {
        let stamp = Int(clock().timeIntervalSince1970)
        var dest = baseDir.appendingPathComponent("\(Self.quarantinePrefix)\(stamp)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = baseDir.appendingPathComponent("\(Self.quarantinePrefix)\(stamp)-\(n)", isDirectory: true); n += 1
        }
        do { try fm.moveItem(at: dir, to: dest) } catch {
            NSLog("ShakeBoard: clips quarantine move failed (\(reason)): \(error) -- history disabled until cleared")
            return false
        }
        prepareDir()
        NSLog("ShakeBoard: Clips quarantined (\(reason)) -> \(dest.lastPathComponent)")
        return true
    }
    func quarantinedDirs() throws -> [URL] {
        try fileOperations.contentsOfDirectory(baseDir)
            .filter { $0.lastPathComponent.hasPrefix(Self.quarantinePrefix) }
    }

    private enum IndexState { case missing, regular, damaged, unavailable }
    private func indexState() -> IndexState {
        guard let entries = try? fileOperations.contentsOfDirectory(dir) else { return .unavailable }
        guard let entry = entries.first(where: { $0.lastPathComponent == "clips.json" }) else { return .missing }
        guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return .unavailable
        }
        return values.isRegularFile == true && values.isSymbolicLink != true ? .regular : .damaged
    }

    private func itemExists(at url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    private func recoverPendingClear() {
        switch indexState() {
        case .missing, .damaged:
            clips = []
            _ = clearAll()
            return
        case .regular:
            break
        case .unavailable:
            clearBlockedByUnavailableIndex = true
            isDegraded = true
            clearFailed = true
            NSLog("ShakeBoard: pending Clear History could not read its old index -- history paused for retry")
            return
        }
        guard let data = try? Data(contentsOf: indexURL) else {
            clearBlockedByUnavailableIndex = true
            isDegraded = true
            clearFailed = true
            NSLog("ShakeBoard: pending Clear History could not read its old index -- history paused for retry")
            return
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let file = try? dec.decode(IndexFile.self, from: data), file.version <= Self.currentVersion else {
            clearBlockedByUnavailableIndex = true
            isDegraded = true
            clearFailed = true
            NSLog("ShakeBoard: pending Clear History could not decode its old index -- history paused for retry")
            return
        }
        // The valid old index is authoritative here. Keep the full view until clearAll() calls willDrop(),
        // then let clearAll() retain the pinned subset.
        clips = file.clips.sorted { $0.lastUsedAt > $1.lastUsedAt }
        _ = clearAll()
    }

    // Clips holds copied text that may be sensitive: owner-only permissions, and excluded from Time
    // Machine (history is ephemeral by design -- 7 days).
    private func prepareDir() {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        var url = dir
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? url.setResourceValues(rv)
    }

    // MARK: ingest
    // Normalize + stage off main, then commit on main. `completion` gets the committed clip (new, or the
    // existing one bumped by dedupe), or nil if the copy was rejected.
    // `derivedFrom`: set for an Edit / transform result -- always a new clip, even when the same text is
    // already in history (the original is never changed). `requireSource`: refuse the result if the source
    // clip was deleted while it was being made (a transform must not bring deleted content back); without
    // it a missing source just leaves derivedFrom nil (an Edit draft is text the user typed).
    func ingest(_ cap: CapturedClipboard, derivedFrom: UUID? = nil, requireSource: Bool = false,
                completion: @escaping (Clip?, _ isNew: Bool) -> Void) {
        guard !isDegraded else { completion(nil, false); return }
        let gen = generation
        io.async { [dir] in
            guard let norm = ClipNormalizer.normalize(cap.snapshot) else {
                DispatchQueue.main.async { completion(nil, false) }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.generation else { completion(nil, false); return }   // cleared meanwhile
                    // Dedupe: identical content just becomes "used now" -- createdAt and source stay put.
                    // Not for an Edit / transform result: that is always its own new clip (with derivedFrom).
                    if derivedFrom == nil, let idx = self.clips.firstIndex(where: { $0.contentHash == norm.hash }) {
                        var c = self.clips.remove(at: idx)
                        c.lastUsedAt = cap.capturedAt
                        self.clips.insert(c, at: 0)
                        self.saveIndex()
                        completion(c, false)
                        return
                    }
                    let id = UUID()
                    self.io.async {
                        let reps = Self.writePayload(norm, id: id, dir: dir)
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let reps else { completion(nil, false); return }
                                let sourceGone = derivedFrom.map { self.clip($0) == nil } ?? false
                                guard gen == self.generation, !(requireSource && sourceGone) else {
                                    // History was cleared (or a transform's source deleted) while this
                                    // payload was being written: delete it.
                                    let d = self.payloadDir(id)
                                    self.io.async { try? FileManager.default.removeItem(at: d) }
                                    completion(nil, false); return
                                }
                                let clip = Clip(id: id, kind: norm.kind, createdAt: cap.capturedAt,
                                                lastUsedAt: cap.capturedAt, sourceBundleID: cap.sourceBundleID,
                                                sourceAppName: cap.sourceAppName, contentHash: norm.hash,
                                                preview: norm.preview, reps: reps, totalBytes: norm.totalBytes,
                                                pixelWidth: norm.pixelWidth, pixelHeight: norm.pixelHeight,
                                                derivedFrom: sourceGone ? nil : derivedFrom)
                                self.clips.insert(clip, at: 0)
                                // A transform of the oldest clip at the limit must not push out its own
                                // source ("the original is unchanged"); normal retention applies later.
                                _ = self.evict(protecting: clip.derivedFrom.map { [$0] } ?? [])
                                self.saveIndex()
                                completion(clip, true)
                            }
                        }
                    }
                }
            }
        }
    }

    // Write every rep into a staging dir, fsync-equivalent via atomic writes, then rename into place.
    // Returns nil (and leaves nothing behind) on any failure.
    nonisolated private static func writePayload(_ norm: NormalizedClip, id: UUID, dir: URL) -> [StoredRep]? {
        let fm = FileManager.default
        let staging = dir.appendingPathComponent(".staging-\(id.uuidString)", isDirectory: true)
        let final = dir.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var out: [StoredRep] = []
            for (i, reps) in norm.items.enumerated() {
                for (j, r) in reps.enumerated() {
                    let name = "\(i)-\(j).bin"
                    let f = staging.appendingPathComponent(name)
                    try r.data.write(to: f, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
                    out.append(StoredRep(item: i, type: r.type, file: name, bytes: r.data.count))
                }
            }
            try fm.moveItem(at: staging, to: final)
            return out
        } catch {
            NSLog("ShakeBoard: clip payload write failed: \(error)")
            try? fm.removeItem(at: staging)
            return nil
        }
    }

    // MARK: index
    private func saveIndex() {
        guard !isDegraded else { return }   // never overwrite the damaged index we couldn't set aside
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(IndexFile(version: Self.currentVersion, clips: clips)) else {
            lastSaveFailed = true; return
        }
        let url = indexURL
        let operations = fileOperations
        io.async {
            let ok = (try? operations.writeAtomically(data, url)) != nil
            if ok { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.lastSaveFailed = !ok } }
        }
    }

    // Block until queued disk work is done (tests + quit).
    nonisolated func flush() { io.sync {} }

    // MARK: retention
    // Apply retention now (e.g. right after the paste stack releases its pins).
    func prune() { evict() }

    // Returns true if anything was evicted. Index is saved BEFORE payload deletion (crash => orphan dir,
    // which load() reconciles, never a dangling index entry).
    @discardableResult
    private func evict(protecting extra: Set<UUID> = []) -> Bool {
        willDrop()
        let now = clock()
        let keep = pinned().union(extra)
        var victims: [Clip] = []
        var kept: [Clip] = []
        var bytes = 0
        for c in clips {   // newest first
            let tooOld = now.timeIntervalSince(c.lastUsedAt) > maxAge
            let overCount = kept.count >= maxCount
            let overBytes = bytes + c.totalBytes > maxBytes
            if !keep.contains(c.id) && (tooOld || overCount || overBytes) {
                victims.append(c)
            } else {
                kept.append(c); bytes += c.totalBytes
            }
        }
        guard !victims.isEmpty else { return false }
        clips = kept
        let dirs = victims.map { payloadDir($0.id) }
        saveIndex()
        io.async { for d in dirs { try? FileManager.default.removeItem(at: d) } }
        return true
    }

    // MARK: access
    func clip(_ id: UUID) -> Clip? { clips.first { $0.id == id } }

    // Rebuild the ordered pasteboard items for a clip from its sidecars.
    func payload(for clip: Clip) -> [[RawRep]]? {
        var items: [[RawRep]] = Array(repeating: [], count: clip.itemCount)
        for r in clip.reps {
            guard let d = try? Data(contentsOf: payloadDir(clip.id).appendingPathComponent(r.file)) else { return nil }
            items[r.item].append(RawRep(type: r.type, data: d))
        }
        return items.filter { !$0.isEmpty }
    }
    func imageURLs(for clip: Clip) -> [URL] {
        clip.reps.filter { $0.type == ClipTypes.png }.map { payloadDir(clip.id).appendingPathComponent($0.file) }
    }
    func imageURL(for clip: Clip) -> URL? {
        guard let r = clip.imageRep else { return nil }
        return payloadDir(clip.id).appendingPathComponent(r.file)
    }
    func fullText(for clip: Clip) -> String? {
        guard let r = clip.reps.first(where: { $0.type == ClipTypes.plainText }),
              let d = try? Data(contentsOf: payloadDir(clip.id).appendingPathComponent(r.file)) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func markUsed(_ id: UUID) {
        guard let idx = clips.firstIndex(where: { $0.id == id }) else { return }
        var c = clips.remove(at: idx)
        c.lastUsedAt = clock()
        clips.insert(c, at: 0)
        saveIndex()
    }

    func remove(_ id: UUID) {
        guard !pinned().contains(id), clips.contains(where: { $0.id == id }) else { return }
        willDrop()
        guard let idx = clips.firstIndex(where: { $0.id == id }) else { return }
        let c = clips.remove(at: idx)
        saveIndex()
        let d = payloadDir(c.id)
        io.async { try? FileManager.default.removeItem(at: d) }
    }

    // Physically delete everything not pinned by an active stack (callers end the stack first).
    // A durable marker is written before deletion and removed only after deletion was verified and the
    // index replacement succeeded. A launch that sees the marker retries the clear instead of trusting an
    // old index that may still name clips the user cleared.
    @discardableResult
    func clearAll() -> Bool {
        guard !clearBlockedByUnavailableIndex else {
            NSLog("ShakeBoard: Clear History refused because the history index was not loaded")
            clearFailed = true
            return false
        }
        let markerURL = clearPendingURL
        let operations = fileOperations
        let markerWritten: Bool = io.sync {
            guard (try? operations.writeAtomically(Data("pending".utf8), markerURL)) != nil else { return false }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL.path)
            return true
        }
        guard markerWritten else {
            NSLog("ShakeBoard: Clear History could not persist its pending marker -- history unchanged")
            lastSaveFailed = true
            isDegraded = true
            clearFailed = true
            return false
        }
        willDrop()
        generation += 1
        let keep = pinned()
        clips = clips.filter { keep.contains($0.id) }
        let keepNames = Set(keep.map(\.uuidString))
        let target = dir
        let extra: [URL]
        do {
            extra = try quarantinedDirs()
        } catch {
            NSLog("ShakeBoard: Clear History could not list quarantined history -- history paused")
            isDegraded = true
            clearFailed = true
            return false
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let index = try? enc.encode(IndexFile(version: Self.currentVersion, clips: clips))
        let indexURL = self.indexURL
        let historyBase = baseDir
        let quarantinePrefix = Self.quarantinePrefix
        let (cleared, indexWritten, markerRemoved): (Bool, Bool, Bool) = io.sync {
            var ok = Self.removeUnowned(in: target, keeping: keepNames,
                                        preservingRegularFiles: [markerURL.lastPathComponent],
                                        fileOperations: operations)
            for d in extra { try? operations.removeItem(d) }
            if let remaining = try? operations.contentsOfDirectory(historyBase) {
                if remaining.contains(where: { $0.lastPathComponent.hasPrefix(quarantinePrefix) }) { ok = false }
            } else {
                ok = false
            }
            var wrote = false
            if let index, (try? operations.writeAtomically(index, indexURL)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
                wrote = true
            }
            var removed = false
            if ok && wrote {
                try? operations.removeItem(markerURL)
                removed = (try? FileManager.default.attributesOfItem(atPath: markerURL.path)) == nil
            }
            return (ok, wrote, removed)
        }
        lastSaveFailed = !indexWritten
        guard cleared, indexWritten, markerRemoved else {
            NSLog("ShakeBoard: Clear History incomplete -- history paused until the leftovers can be removed")
            isDegraded = true
            clearFailed = true
            return false
        }
        isDegraded = false
        clearFailed = false
        return true
    }
}
