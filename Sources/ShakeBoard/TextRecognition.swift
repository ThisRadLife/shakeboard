//
//  TextRecognition.swift
//  On-device OCR for clipboard images and bookmarked shelf image files.
//

import AppKit
import Combine
import Darwin
import Vision

protocol TextRecognizer {
    func recognize(imageAt url: URL) throws -> String
}

enum TextRecognitionError: Error {
    case unreadableImage
    case imageTooLarge
}

struct VisionTextRecognizer: TextRecognizer {
    func recognize(imageAt url: URL) throws -> String {
        guard let size = ClipNormalizer.pixelSize(url) else { throw TextRecognitionError.unreadableImage }
        guard ClipNormalizer.withinPixelCap(size) else { throw TextRecognitionError.imageTooLarge }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(url: url, options: [:]).perform([request])
        let byHeight = (request.results ?? []).sorted {
            if $0.boundingBox.midY != $1.boundingBox.midY { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        var rows: [[VNRecognizedTextObservation]] = []
        for observation in byHeight {
            if let anchor = rows.last?.first, abs(anchor.boundingBox.midY - observation.boundingBox.midY) <= 0.02 {
                rows[rows.count - 1].append(observation)
            } else {
                rows.append([observation])
            }
        }
        let observations = rows.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

enum OCRStatus: Equatable {
    case notStarted
    case queued
    case complete
    case failed
}

struct ShelfFileMetadata {
    let url: URL
    let size: Int
    let mtime: Double
}

enum OCRSearchIndex {
    static let maxBytes = 64 * 1024

    static func folded(_ text: String) -> String {
        let prefix: String
        if text.utf8.count <= maxBytes {
            prefix = text
        } else {
            var end = text.startIndex
            var bytes = 0
            while end < text.endIndex {
                let next = text.index(after: end)
                let width = text[end..<next].utf8.count
                guard bytes + width <= maxBytes else { break }
                bytes += width
                end = next
            }
            prefix = String(text[..<end])
        }
        return prefix.lowercased()
    }
}

final class ShelfCacheWriter<Snapshot>: @unchecked Sendable {
    private enum Action {
        case write(Snapshot)
        case delete
    }
    private struct Pending {
        let revision: Int
        let action: Action
        let url: URL
    }

    private let queue = DispatchQueue(label: "com.thisradlife.shakeboard.ocr-cache", qos: .userInitiated)
    private let lock = NSLock()
    private let encode: (Snapshot) -> Data?
    private let write: (Data, URL) -> Bool
    private let remove: (URL) -> Void
    private var latest: Pending?
    private var draining = false

    init(encode: @escaping (Snapshot) -> Data?, write: @escaping (Data, URL) -> Bool,
         remove: @escaping (URL) -> Void = { try? FileManager.default.removeItem(at: $0) }) {
        self.encode = encode
        self.write = write
        self.remove = remove
    }

    func schedule(_ snapshot: Snapshot, to url: URL, revision: Int) {
        schedule(.write(snapshot), to: url, revision: revision)
    }

    func deleteFile(at url: URL, revision: Int) {
        schedule(.delete, to: url, revision: revision)
    }

    private func schedule(_ action: Action, to url: URL, revision: Int) {
        var start = false
        lock.lock()
        if latest == nil || revision >= latest!.revision {
            latest = Pending(revision: revision, action: action, url: url)
        }
        if !draining { draining = true; start = true }
        lock.unlock()
        if start { queue.async { [weak self] in self?.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let candidate = latest else { draining = false; lock.unlock(); return }
            lock.unlock()

            let data: Data?
            switch candidate.action {
            case .write(let snapshot): data = encode(snapshot)
            case .delete: data = nil
            }
            lock.lock()
            guard latest?.revision == candidate.revision else {
                lock.unlock()
                continue
            }
            latest = nil
            lock.unlock()
            switch candidate.action {
            case .write:
                if let data { _ = write(data, candidate.url) }
            case .delete:
                remove(candidate.url)
            }
        }
    }

    func flush(timeout: TimeInterval) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    func whenFlushed(_ completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }
}

@discardableResult
private func writeOwnerOnlyFile(_ data: Data, to url: URL) -> Bool {
    do {
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return false
        }
        defer { try? fm.removeItem(at: temp) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        guard rename(temp.path, url.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return true
    } catch {
        NSLog("ShakeBoard OCR: cache write failed: \(error)")
        return false
    }
}

@MainActor
final class OCRService: ObservableObject {
    @Published private(set) var revision = 0

    struct ShelfCacheEntry: Codable, Equatable, Sendable {
        let size: Int
        let mtime: Double
        let text: String
    }
    private struct ShelfSignature: Equatable {
        let size: Int
        let mtime: Double
    }
    private struct ClipJob {
        let clip: Clip
        let payloadDir: URL
        let imageURLs: [URL]
        let generation: Int
        let delay: TimeInterval
    }
    private struct ShelfJob {
        let item: ShelfItem
        let url: URL
        let cached: ShelfCacheEntry?
        let signature: ShelfSignature
        let version: Int
        let delay: TimeInterval
    }
    private struct ShelfReuse {
        let clipID: UUID
        let imageIndex: Int
    }
    private enum Job {
        case clip(ClipJob)
        case shelf(ShelfJob)
        case loadShelf(URL)

        var clipID: UUID? { if case .clip(let j) = self { return j.clip.id }; return nil }
        var shelfID: UUID? {
            switch self {
            case .shelf(let j): return j.item.id
            default: return nil
            }
        }
        var shelfVersion: Int? {
            switch self {
            case .shelf(let j): return j.version
            default: return nil
            }
        }
        var shelfSignature: ShelfSignature? {
            if case .shelf(let j) = self { return j.signature }
            return nil
        }
        var delay: TimeInterval {
            switch self {
            case .clip(let j): return j.delay
            case .shelf(let j): return j.delay
            case .loadShelf: return 0
            }
        }
    }

    private enum Result {
        case clip(UUID, String?, parts: [String]?, search: String?, partSearch: [String]?, wroteSidecar: Bool)
        case clipFailed(UUID)
        case shelfValidated(UUID, ShelfCacheEntry, search: String)
        case shelfRecognized(UUID, ShelfCacheEntry, search: String)
        case shelfFailed(UUID, ShelfSignature)
        case loadedShelf([String: ShelfCacheEntry], [UUID: String])
        case none
    }

    let store: ClipStore
    private weak var shelf: ShelfModel?
    private let baseDir: URL
    nonisolated(unsafe) private let recognizer: TextRecognizer
    private let defaults: UserDefaults
    private let backfillDelay: TimeInterval
    nonisolated(unsafe) private let shelfMetadata: (ShelfItem) -> ShelfFileMetadata?
    private let queue = DispatchQueue(label: "com.thisradlife.shakeboard.ocr", qos: .utility)
    private let cacheWriter: ShelfCacheWriter<[String: ShelfCacheEntry]>
    nonisolated(unsafe) private let fm = FileManager.default
    private var pending: [Job] = []
    private var active = false
    private var resolvingShelf = 0
    private var completedClips: Set<UUID> = []
    private var failedClips: Set<UUID> = []
    private var clipText: [UUID: String] = [:]
    private var clipSearchText: [UUID: String] = [:]
    private var clipParts: [UUID: [String]] = [:]
    private var clipPartSearch: [UUID: [String]] = [:]
    private var shelfCache: [String: ShelfCacheEntry] = [:]
    private var shelfSearchText: [UUID: String] = [:]
    private var validatedShelfIDs: Set<UUID> = []
    private var failedShelfItems: [UUID: ShelfSignature] = [:]
    private var shelfCacheLoaded = false
    private var hasShelfSnapshot = false
    private var liveShelfIDs: Set<UUID> = []
    private var eligibleShelfIDs: Set<UUID> = []
    private var shelfItemsByID: [UUID: ShelfItem] = [:]
    private var shelfMetadataByID: [UUID: ShelfFileMetadata] = [:]
    private var shelfVersions: [UUID: Int] = [:]
    private var shelfSnapshotRevision = 0
    private var shelfCacheRevision = 0
    private var shelfReuse: [UUID: ShelfReuse] = [:]
    private var linkedShelfByClip: [UUID: Set<UUID>] = [:]
    private var idleCallbacks: [() -> Void] = []
    private var bags: [AnyCancellable] = []
    private var preferenceEpoch = 0
    private var enabledState: Bool
    private var clipPurgeInProgress = false

    var isEnabled: Bool { PerchPrefs(defaults: defaults).recognizeTextInImages }
    private var shelfCacheURL: URL { baseDir.appendingPathComponent("shelf-ocr.json") }
    private static var debug: Bool { ProcessInfo.processInfo.environment["PERCH_DEBUG_OCR"] == "1" }

    init(baseDir: URL = PerchPaths.base, store: ClipStore, shelf: ShelfModel? = nil,
         recognizer: TextRecognizer = VisionTextRecognizer(), defaults: UserDefaults = PerchPaths.defaults,
         backfillDelay: TimeInterval = 0.3,
         shelfMetadata: @escaping (ShelfItem) -> ShelfFileMetadata? = OCRService.readShelfMetadata,
         cacheEncode: @escaping ([String: ShelfCacheEntry]) -> Data? = { try? JSONEncoder().encode($0) }) {
        self.baseDir = baseDir
        self.store = store
        self.shelf = shelf
        self.recognizer = recognizer
        self.defaults = defaults
        self.backfillDelay = backfillDelay
        self.shelfMetadata = shelfMetadata
        self.cacheWriter = ShelfCacheWriter(encode: cacheEncode, write: writeOwnerOnlyFile)
        self.enabledState = PerchPrefs(defaults: defaults).recognizeTextInImages
        if enabledState {
            pending.append(.loadShelf(baseDir.appendingPathComponent("shelf-ocr.json")))
        } else {
            shelfCacheLoaded = true
        }
        pump()
        bags.append(store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.storeChanged() } }
        })
        if let shelf {
            bags.append(shelf.$items.sink { [weak self] items in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.syncShelf(items) } }
            })
        }
    }

    func text(for clip: Clip) -> String? {
        guard isEnabled, let text = clipText[clip.id], !text.isEmpty else { return nil }
        return text
    }

    func searchText(for clip: Clip) -> String? {
        guard isEnabled else { return nil }
        return clipSearchText[clip.id]
    }

    func text(for item: ShelfItem) -> String? {
        guard isEnabled, !item.missing, validatedShelfIDs.contains(item.id),
              let text = shelfCache[item.id.uuidString]?.text, !text.isEmpty else { return nil }
        return text
    }

    func searchText(for item: ShelfItem) -> String? {
        guard isEnabled, !item.missing, validatedShelfIDs.contains(item.id) else { return nil }
        return shelfSearchText[item.id]
    }

    func status(for clip: Clip) -> OCRStatus {
        guard isEnabled else { return .notStarted }
        if completedClips.contains(clip.id) { return .complete }
        if failedClips.contains(clip.id) { return .failed }
        if activeClipID == clip.id || pending.contains(where: { $0.clipID == clip.id }) { return .queued }
        return .notStarted
    }

    func status(for item: ShelfItem) -> OCRStatus {
        guard isEnabled else { return .notStarted }
        if failedShelfItems[item.id] != nil { return .failed }
        if activeShelfID == item.id || pending.contains(where: { $0.shelfID == item.id }) { return .queued }
        if validatedShelfIDs.contains(item.id), shelfCache[item.id.uuidString] != nil { return .complete }
        return .notStarted
    }

    private var activeClipID: UUID?
    private var activeShelfID: UUID?
    private var activeShelfSignature: ShelfSignature?

    func enqueue(_ clip: Clip, priority: Bool = false, backfill: Bool = false) {
        guard isEnabled, clip.kind == .image else { return }
        if completedClips.contains(clip.id) || failedClips.contains(clip.id) || activeClipID == clip.id { return }
        if let i = pending.firstIndex(where: { $0.clipID == clip.id }) {
            if priority { let job = pending.remove(at: i); pending.insert(job, at: 0) }
            return
        }
        let job = Job.clip(ClipJob(clip: clip, payloadDir: store.payloadDir(clip.id),
                                   imageURLs: store.imageURLs(for: clip), generation: store.generation,
                                   delay: backfill ? backfillDelay : 0))
        if priority { pending.insert(job, at: 0) } else { pending.append(job) }
        revision += 1
        pump()
    }

    func prioritize(_ clip: Clip) { enqueue(clip, priority: true) }

    func startBackfill() {
        guard isEnabled else { return }
        for clip in store.clips where clip.kind == .image { enqueue(clip, backfill: true) }
        if let shelf { syncShelf(shelf.items, backfill: true) }
        else if hasShelfSnapshot { syncShelf(Array(shelfItemsByID.values), backfill: true) }
    }

    func preferencesChanged() {
        let enabled = isEnabled
        guard enabledState != enabled else { return }
        enabledState = enabled
        preferenceEpoch += 1
        if !enabled {
            pending.removeAll()
            completedClips.removeAll()
            failedClips.removeAll()
            clipText.removeAll()
            clipSearchText.removeAll()
            clipParts.removeAll()
            clipPartSearch.removeAll()
            shelfCache.removeAll()
            shelfSearchText.removeAll()
            validatedShelfIDs.removeAll()
            failedShelfItems.removeAll()
            shelfReuse.removeAll()
            linkedShelfByClip.removeAll()
            shelfCacheLoaded = true

            shelfCacheRevision += 1
            cacheWriter.deleteFile(at: shelfCacheURL, revision: shelfCacheRevision)
            clipPurgeInProgress = true
            let clipsDir = store.dir
            queue.async { [weak self] in
                Self.deleteClipSidecars(in: clipsDir)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.clipPurgeInProgress = false
                        self.finishIdleIfNeeded()
                    }
                }
            }
            revision += 1
            finishIdleIfNeeded()
        } else {
            startBackfill()
            revision += 1
        }
    }

    func syncShelf(_ items: [ShelfItem], backfill: Bool = false) {
        hasShelfSnapshot = true
        shelfSnapshotRevision += 1
        let snapshotRevision = shelfSnapshotRevision
        let oldLive = liveShelfIDs
        liveShelfIDs = Set(items.map(\.id))
        eligibleShelfIDs = Set(items.filter { !$0.missing && StripState.isImageFile($0) }.map(\.id))
        shelfItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        validatedShelfIDs.formIntersection(eligibleShelfIDs)
        failedShelfItems = failedShelfItems.filter { eligibleShelfIDs.contains($0.key) }
        let removed = oldLive.subtracting(liveShelfIDs)
        for id in removed { shelfVersions[id, default: 0] += 1 }
        pending.removeAll { $0.shelfID.map { removed.contains($0) } ?? false }
        for id in removed {
            if let reuse = shelfReuse.removeValue(forKey: id) {
                linkedShelfByClip[reuse.clipID]?.remove(id)
            }
            shelfSearchText.removeValue(forKey: id)
            shelfMetadataByID.removeValue(forKey: id)
        }
        let liveKeys = Set(items.map { $0.id.uuidString })
        let oldCount = shelfCache.count
        shelfCache = shelfCache.filter { liveKeys.contains($0.key) }
        shelfSearchText = shelfSearchText.filter { liveShelfIDs.contains($0.key) }
        if shelfCache.count != oldCount { scheduleShelfWrite() }
        guard shelfCacheLoaded, isEnabled else { return }
        resolveShelfItems(items.filter { !$0.missing && StripState.isImageFile($0) },
                          snapshotRevision: snapshotRevision, priority: false, backfill: backfill)
    }

    func prioritize(_ item: ShelfItem) {
        guard isEnabled, !item.missing, StripState.isImageFile(item) else { return }
        liveShelfIDs.insert(item.id)
        eligibleShelfIDs.insert(item.id)
        shelfItemsByID[item.id] = item
        resolveShelfItems([item], snapshotRevision: shelfSnapshotRevision, priority: true, backfill: false)
    }

    func reuseOCR(from clip: Clip, imageIndex: Int, for item: ShelfItem) {
        guard isEnabled, imageIndex >= 0 else { return }
        let reuse = ShelfReuse(clipID: clip.id, imageIndex: imageIndex)
        shelfReuse[item.id] = reuse
        linkedShelfByClip[clip.id, default: []].insert(item.id)
        pending.removeAll { $0.shelfID == item.id }
        shelfVersions[item.id, default: 0] += 1
        if let parts = clipParts[clip.id], parts.indices.contains(imageIndex) {
            let searches = clipPartSearch[clip.id] ?? []
            applyReusedOCR(parts[imageIndex], search: searches.indices.contains(imageIndex) ? searches[imageIndex] : "",
                           to: item.id)
        }
    }

    private func resolveShelfItems(_ items: [ShelfItem], snapshotRevision: Int,
                                   priority: Bool, backfill: Bool) {
        guard !items.isEmpty else { finishIdleIfNeeded(); return }
        resolvingShelf += 1
        let resolver = shelfMetadata
        queue.async { [weak self] in
            let resolved = items.compactMap { item -> (ShelfItem, ShelfFileMetadata)? in
                resolver(item).map { (item, $0) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyResolvedShelf(resolved, snapshotRevision: snapshotRevision,
                                             priority: priority, backfill: backfill)
                }
            }
        }
    }

    private func applyResolvedShelf(_ resolved: [(ShelfItem, ShelfFileMetadata)], snapshotRevision: Int,
                                    priority: Bool, backfill: Bool) {
        resolvingShelf = max(0, resolvingShelf - 1)
        guard snapshotRevision == shelfSnapshotRevision, isEnabled else {
            finishIdleIfNeeded()
            return
        }
        for (item, metadata) in resolved where eligibleShelfIDs.contains(item.id) {
            shelfMetadataByID[item.id] = metadata
            if let reuse = shelfReuse[item.id] {
                if let parts = clipParts[reuse.clipID], parts.indices.contains(reuse.imageIndex) {
                    let searches = clipPartSearch[reuse.clipID] ?? []
                    applyReusedOCR(parts[reuse.imageIndex],
                                   search: searches.indices.contains(reuse.imageIndex) ? searches[reuse.imageIndex] : "",
                                   to: item.id)
                    continue
                }
                if store.clip(reuse.clipID) != nil, !failedClips.contains(reuse.clipID) { continue }
                removeShelfReuse(for: item.id)
            }
            let signature = ShelfSignature(size: metadata.size, mtime: metadata.mtime)
            if let failed = failedShelfItems[item.id] {
                guard failed != signature else { continue }
                failedShelfItems.removeValue(forKey: item.id)
            }
            if activeShelfID == item.id, activeShelfSignature == signature { continue }
            if let queued = pending.first(where: { $0.shelfID == item.id }), queued.shelfSignature == signature {
                continue
            }
            if let cached = shelfCache[item.id.uuidString],
               cached.size == signature.size, cached.mtime == signature.mtime {
                validatedShelfIDs.insert(item.id)
                continue
            }
            validatedShelfIDs.remove(item.id)
            shelfVersions[item.id, default: 0] += 1
            enqueueShelf(item, url: metadata.url, signature: signature,
                         priority: priority, backfill: backfill)
        }
        revision += 1
        pump()
    }

    private func enqueueShelf(_ item: ShelfItem, url: URL, signature: ShelfSignature,
                              priority: Bool, backfill: Bool) {
        guard failedShelfItems[item.id] == nil else { return }
        if activeShelfID == item.id { return }
        if let i = pending.firstIndex(where: { $0.shelfID == item.id }) {
            if priority { let job = pending.remove(at: i); pending.insert(job, at: 0) }
            return
        }
        let job = Job.shelf(ShelfJob(item: item, url: url, cached: shelfCache[item.id.uuidString],
                                     signature: signature,
                                     version: shelfVersions[item.id, default: 0],
                                     delay: backfill ? backfillDelay : 0))
        if priority { pending.insert(job, at: 0) } else { pending.append(job) }
    }

    func whenIdle(_ completion: @escaping () -> Void) {
        if !active && pending.isEmpty && resolvingShelf == 0 && !clipPurgeInProgress {
            cacheWriter.whenFlushed { DispatchQueue.main.async { completion() } }
        }
        else { idleCallbacks.append(completion) }
    }

    private func storeChanged() {
        let live = Set(store.clips.map(\.id))
        let removedReuseSources = Set(linkedShelfByClip.keys).subtracting(live)
        completedClips.formIntersection(live)
        failedClips.formIntersection(live)
        clipText = clipText.filter { live.contains($0.key) }
        clipSearchText = clipSearchText.filter { live.contains($0.key) }
        clipParts = clipParts.filter { live.contains($0.key) }
        clipPartSearch = clipPartSearch.filter { live.contains($0.key) }
        pending.removeAll { $0.clipID.map { !live.contains($0) } ?? false }
        for id in removedReuseSources { releaseShelfReuseLinks(from: id) }
        if isEnabled {
            for clip in store.clips where clip.kind == .image { enqueue(clip, backfill: true) }
        }
        revision += 1
    }

    nonisolated private static func readShelfMetadata(_ item: ShelfItem) -> ShelfFileMetadata? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: item.bookmark, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return ShelfFileMetadata(url: url, size: size, mtime: date.timeIntervalSince1970)
    }

    private func scheduleShelfWrite() {
        guard isEnabled else { return }
        shelfCacheRevision += 1
        cacheWriter.schedule(shelfCache, to: shelfCacheURL, revision: shelfCacheRevision)
    }

    private func applyReusedOCR(_ text: String, search: String, to id: UUID) {
        guard isEnabled, eligibleShelfIDs.contains(id), let metadata = shelfMetadataByID[id] else { return }
        removeShelfReuse(for: id)
        let entry = ShelfCacheEntry(size: metadata.size, mtime: metadata.mtime, text: text)
        shelfCache[id.uuidString] = entry
        shelfSearchText[id] = search
        validatedShelfIDs.insert(id)
        failedShelfItems.removeValue(forKey: id)
        scheduleShelfWrite()
        revision += 1
    }

    func flushShelfCacheWrites(timeout: TimeInterval = 1) -> Bool {
        return cacheWriter.flush(timeout: timeout)
    }

    private func removeShelfReuse(for shelfID: UUID) {
        guard let reuse = shelfReuse.removeValue(forKey: shelfID) else { return }
        linkedShelfByClip[reuse.clipID]?.remove(shelfID)
        if linkedShelfByClip[reuse.clipID]?.isEmpty == true {
            linkedShelfByClip.removeValue(forKey: reuse.clipID)
        }
    }

    private func releaseShelfReuseLinks(from clipID: UUID) {
        let shelfIDs = linkedShelfByClip.removeValue(forKey: clipID) ?? []
        for shelfID in shelfIDs where shelfReuse[shelfID]?.clipID == clipID {
            shelfReuse.removeValue(forKey: shelfID)
        }
        guard shelfCacheLoaded, isEnabled else { return }
        let items = shelfIDs.compactMap { eligibleShelfIDs.contains($0) ? shelfItemsByID[$0] : nil }
        if !items.isEmpty {
            resolveShelfItems(items, snapshotRevision: shelfSnapshotRevision, priority: true, backfill: false)
        }
    }

    private func pump() {
        guard !active, !pending.isEmpty else { finishIdleIfNeeded(); return }
        active = true
        let job = pending.removeFirst()
        activeClipID = job.clipID
        activeShelfID = job.shelfID
        activeShelfSignature = job.shelfSignature
        let epoch = preferenceEpoch
        queue.async { [weak self] in
            guard let self else { return }
            if job.delay > 0 { Thread.sleep(forTimeInterval: job.delay) }
            let start = DispatchTime.now().uptimeNanoseconds
            let result = self.run(job, epoch: epoch)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finished(job, result: result, epoch: epoch, elapsedMS: elapsed) }
            }
        }
    }

    nonisolated private func run(_ job: Job, epoch: Int) -> Result {
        switch job {
        case .clip(let j): return runClip(j, epoch: epoch)
        case .shelf(let j): return runShelf(j, epoch: epoch)
        case .loadShelf(let url):
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([String: ShelfCacheEntry].self, from: data) else {
                return .loadedShelf([:], [:])
            }
            var search: [UUID: String] = [:]
            for (key, entry) in decoded {
                if let id = UUID(uuidString: key) { search[id] = OCRSearchIndex.folded(entry.text) }
            }
            return .loadedShelf(decoded, search)
        }
    }

    nonisolated private func runClip(_ job: ClipJob, epoch: Int) -> Result {
        let sidecar = job.payloadDir.appendingPathComponent("ocr.txt")
        if fm.fileExists(atPath: sidecar.path) {
            let text = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
            let parts = text.components(separatedBy: "\n\n")
            return .clip(job.clip.id, text, parts: parts, search: OCRSearchIndex.folded(text),
                         partSearch: parts.map(OCRSearchIndex.folded), wroteSidecar: false)
        }
        var parts: [String] = []
        do {
            for url in job.imageURLs {
                do { parts.append(try recognizer.recognize(imageAt: url)) }
                catch TextRecognitionError.imageTooLarge { parts.append("") }
            }
        } catch {
            return .clipFailed(job.clip.id)
        }
        let text = parts.joined(separator: "\n\n")
        let mayWrite = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                self.preferenceEpoch == epoch && self.isEnabled && self.store.generation == job.generation
                    && self.store.clip(job.clip.id) != nil
            }
        }
        var isDir: ObjCBool = false
        guard mayWrite, fm.fileExists(atPath: job.payloadDir.path, isDirectory: &isDir), isDir.boolValue else {
            return .clip(job.clip.id, nil, parts: nil, search: nil, partSearch: nil, wroteSidecar: false)
        }
        guard writeOwnerOnlyFile(Data(text.utf8), to: sidecar) else {
            return .clip(job.clip.id, nil, parts: nil, search: nil, partSearch: nil, wroteSidecar: false)
        }
        return .clip(job.clip.id, text, parts: parts, search: OCRSearchIndex.folded(text),
                     partSearch: parts.map(OCRSearchIndex.folded), wroteSidecar: true)
    }

    nonisolated private func runShelf(_ job: ShelfJob, epoch: Int) -> Result {
        let accessed = job.url.startAccessingSecurityScopedResource()
        defer { if accessed { job.url.stopAccessingSecurityScopedResource() } }
        let signature = job.signature
        if let cached = job.cached, cached.size == signature.size, cached.mtime == signature.mtime {
            return .shelfValidated(job.item.id, cached, search: OCRSearchIndex.folded(cached.text))
        }
        let text: String
        do { text = try recognizer.recognize(imageAt: job.url) }
        catch TextRecognitionError.imageTooLarge { text = "" }
        catch { return .shelfFailed(job.item.id, signature) }
        let entry = ShelfCacheEntry(size: signature.size, mtime: signature.mtime, text: text)
        return .shelfRecognized(job.item.id, entry, search: OCRSearchIndex.folded(text))
    }

    nonisolated private static func deleteClipSidecars(in clipsDir: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let root = try? clipsDir.resourceValues(forKeys: keys),
              root.isDirectory == true, root.isSymbolicLink != true,
              let payloads = try? FileManager.default.contentsOfDirectory(
                at: clipsDir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
              ) else { return }
        for payload in payloads where UUID(uuidString: payload.lastPathComponent) != nil {
            guard let values = try? payload.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let sidecar = payload.appendingPathComponent("ocr.txt", isDirectory: false)
            guard let sidecarValues = try? sidecar.resourceValues(forKeys: keys),
                  sidecarValues.isRegularFile == true, sidecarValues.isSymbolicLink != true else { continue }
            try? FileManager.default.removeItem(at: sidecar)
        }
    }

    private func finished(_ job: Job, result: Result, epoch: Int, elapsedMS: Int) {
        active = false
        activeClipID = nil
        activeShelfID = nil
        activeShelfSignature = nil
        var debugID: String?
        var chars = 0
        switch result {
        case .clip(let id, let text, let parts, let search, let partSearch, let wroteSidecar):
            debugID = id.uuidString
            let valid: Bool
            if case .clip(let clipJob) = job {
                valid = isEnabled && preferenceEpoch == epoch
                    && store.generation == clipJob.generation && store.clip(id) != nil
            } else { valid = false }
            if let text, valid {
                completedClips.insert(id)
                clipText[id] = text
                clipSearchText[id] = search ?? ""
                clipParts[id] = parts ?? [text]
                clipPartSearch[id] = partSearch ?? [search ?? ""]
                chars = text.count
                revision += 1
                for shelfID in linkedShelfByClip[id] ?? [] {
                    guard let reuse = shelfReuse[shelfID], let parts = clipParts[id],
                          parts.indices.contains(reuse.imageIndex) else { continue }
                    let searches = clipPartSearch[id] ?? []
                    applyReusedOCR(parts[reuse.imageIndex],
                                   search: searches.indices.contains(reuse.imageIndex) ? searches[reuse.imageIndex] : "",
                                   to: shelfID)
                }
            } else if valid {
                releaseShelfReuseLinks(from: id)
            } else if wroteSidecar, case .clip(let clipJob) = job {
                let sidecar = clipJob.payloadDir.appendingPathComponent("ocr.txt")
                queue.async { try? FileManager.default.removeItem(at: sidecar) }
            }
            if !valid, isEnabled, let clip = store.clip(id), clip.kind == .image {
                enqueue(clip, priority: true)
            }
        case .clipFailed(let id):
            debugID = id.uuidString
            let valid: Bool
            if case .clip(let clipJob) = job {
                valid = isEnabled && preferenceEpoch == epoch
                    && store.generation == clipJob.generation && store.clip(id)?.kind == .image
            } else { valid = false }
            if valid {
                failedClips.insert(id)
                releaseShelfReuseLinks(from: id)
                revision += 1
            } else if isEnabled, let clip = store.clip(id), clip.kind == .image {
                enqueue(clip, priority: true)
            }
        case .shelfValidated(let id, let entry, let search):
            debugID = id.uuidString
            if isCurrent(job, epoch: epoch), eligibleShelfIDs.contains(id) {
                shelfCache[id.uuidString] = entry
                shelfSearchText[id] = search
                validatedShelfIDs.insert(id)
                chars = entry.text.count
                revision += 1
            } else { requeueShelf(id) }
        case .shelfRecognized(let id, let entry, let search):
            debugID = id.uuidString
            if isCurrent(job, epoch: epoch), eligibleShelfIDs.contains(id) {
                shelfCache[id.uuidString] = entry
                shelfSearchText[id] = search
                validatedShelfIDs.insert(id)
                chars = entry.text.count
                scheduleShelfWrite()
                revision += 1
            } else {
                requeueShelf(id)
            }
        case .shelfFailed(let id, let signature):
            debugID = id.uuidString
            if isCurrent(job, epoch: epoch), eligibleShelfIDs.contains(id) {
                failedShelfItems[id] = signature
                revision += 1
            } else { requeueShelf(id) }
        case .loadedShelf(let decoded, let search):
            if isCurrent(job, epoch: epoch) {
                shelfCacheLoaded = true
                shelfCache = decoded
                shelfSearchText = search
                if let shelf { syncShelf(shelf.items, backfill: true) }
                else if hasShelfSnapshot { syncShelf(Array(shelfItemsByID.values), backfill: true) }
            }
        case .none: break
        }
        if Self.debug, let debugID { NSLog("ShakeBoard OCR: job \(debugID) \(elapsedMS)ms \(chars) chars") }
        pump()
    }

    private func isCurrent(_ job: Job, epoch: Int) -> Bool {
        guard isEnabled, preferenceEpoch == epoch else { return false }
        if case .clip(let clipJob) = job { return store.generation == clipJob.generation }
        if let id = job.shelfID, let version = job.shelfVersion {
            return shelfVersions[id] == version
        }
        return true
    }

    private func requeueShelf(_ id: UUID) {
        guard isEnabled, eligibleShelfIDs.contains(id), let item = shelfItemsByID[id] else { return }
        resolveShelfItems([item], snapshotRevision: shelfSnapshotRevision, priority: true, backfill: false)
    }

    private func finishIdleIfNeeded() {
        guard !active, pending.isEmpty, resolvingShelf == 0, !clipPurgeInProgress,
              !idleCallbacks.isEmpty else { return }
        let callbacks = idleCallbacks
        idleCallbacks = []
        cacheWriter.whenFlushed {
            DispatchQueue.main.async { callbacks.forEach { $0() } }
        }
    }
}

// MARK: - Derived text actions

@MainActor
extension StripController {
    // Save OCR as a real text clip first, preserving the source relationship and hidden-from-AI inheritance,
    // then use the normal tagged writer / paste path on that new clip.
    func useRecognizedText(_ text: String, from source: UUID?, paste: Bool,
                           completion: @escaping (PasteOutcome) -> Void = { _ in }) {
        let data = Data(text.utf8)
        guard !text.isEmpty, data.count <= ClipLimits.maxTextBytes else {
            state.notice = text.isEmpty ? "No text found." : "Recognized text is over 1 MB."
            completion(.payloadMissing)
            return
        }
        let snap = RawSnapshot(changeCount: -1, allTypes: [ClipTypes.plainText],
                               items: [[RawRep(type: ClipTypes.plainText, data: data)]])
        let cap = CapturedClipboard(snapshot: snap, sourceBundleID: PerchID.appBundleID,
                                    sourceAppName: "ShakeBoard", capturedAt: now())
        let inheritHidden = source.map { AIVisibility.isHidden($0, store: state.store) } ?? false
        let targetPID = paste ? (frontmostPID() ?? target) : nil
        state.store.ingest(cap, derivedFrom: source, requireSource: source != nil) { [weak self] clip, isNew in
            guard let self else { completion(.payloadMissing); return }
            guard let clip else {
                self.state.notice = source.map { self.state.clip($0) == nil } == true
                    ? "The image was deleted -- nothing copied." : "Couldn't save the recognized text."
                completion(.payloadMissing)
                return
            }
            if isNew, inheritHidden { AIHiddenClips.shared.hide(clip.id) }
            if !self.state.query.isEmpty { self.state.query = "" }
            if self.state.filter != .all { self.state.filter = .all }
            self.state.cursor = .clip(clip.id)
            let paster = ClipPaster(store: self.state.store, poster: self.poster, frontmostPID: self.frontmostPID)
            let perform = {
                let outcome = paster.paste(clip, into: targetPID, copyOnly: !paste)
                switch outcome {
                case .copiedOnly: self.state.notice = "Copied recognized text"
                case .clipboardBusy: self.state.notice = "Clipboard busy -- try again."
                default: break
                }
                completion(outcome)
            }
            if paste {
                self.dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + self.pasteDelay) { perform() }
            } else {
                perform()
            }
        }
    }

    func splitRecognizedText(_ text: String, from source: UUID?, mode: SplitMode? = nil) {
        guard let stacks, source.map({ state.clip($0) != nil }) ?? true else {
            state.notice = "That image is gone."
            return
        }
        let pieces: [String]
        if let mode { pieces = StackSplitter.split(text, mode) }
        else { pieces = StackSplitter.autoSplit(text)?.pieces ?? [] }
        guard pieces.count >= 2 else { state.notice = "Nothing to split there."; return }
        let capped = Array(pieces.prefix(StackSplitter.maxPieces))
        let inheritHidden = source.map { AIVisibility.isHidden($0, store: state.store) } ?? false
        let generation = state.store.generation
        var ids: [UUID] = []
        var created: [UUID] = []

        func rollback(_ message: String) {
            for id in created { state.store.remove(id) }
            state.notice = message
        }
        func next(_ index: Int) {
            guard generation == state.store.generation, source.map({ state.clip($0) != nil }) ?? true else {
                rollback("The image was removed -- split cancelled.")
                return
            }
            guard index < capped.count else {
                stacks.newStack(name: "Split: Recognized text", clips: ids)
                let more = pieces.count > capped.count ? " (first \(capped.count) of \(pieces.count))" : ""
                state.notice = "New stack with \(ids.count) pieces\(more) -- click Ready to paste"
                return
            }
            let data = Data(capped[index].utf8)
            let snap = RawSnapshot(changeCount: -1, allTypes: [ClipTypes.plainText],
                                   items: [[RawRep(type: ClipTypes.plainText, data: data)]])
            let cap = CapturedClipboard(snapshot: snap, sourceBundleID: PerchID.appBundleID,
                                        sourceAppName: "ShakeBoard", capturedAt: now())
            state.store.ingest(cap, derivedFrom: source, requireSource: source != nil) { clip, isNew in
                guard let clip else { rollback("Couldn't save the pieces -- check disk space."); return }
                if isNew { created.append(clip.id) }
                if inheritHidden { AIHiddenClips.shared.hide(clip.id) }
                ids.append(clip.id)
                next(index + 1)
            }
        }
        next(0)
    }
}
