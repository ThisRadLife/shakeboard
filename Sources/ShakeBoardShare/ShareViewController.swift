//
//  ShareViewController.swift
//  ShakeBoardShare -- macOS Share Extension. Normalizes each shared item (file, image, web link,
//  or selected text) into a real file inside the extension's sandbox container, then hands the
//  folder off to the non-sandboxed ShakeBoard app via  shakeboard://add?dir=<folder> . ShakeBoard validates the
//  folder, copies the files onto its shelf, and deletes the handoff. Tiny confirmation, auto-dismiss.
//
//  Path B: the extension writes only to its own container; the non-sandboxed app reads it back via the
//  shakeboard:// URL scheme. (ShakeBoard now signs with a real Developer ID. The remaining cleanup is to move the
//  handoff to a shared App Group container -- group.com.thisradlife.shakeboard -- which also closes the shakeboard://
//  URL-scheme interception risk. The normalize->file->ingest flow is otherwise unchanged.)
//

import Cocoa
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {

    // The URL scheme the non-sandboxed ShakeBoard app registers. FORK INVARIANT: a unit-test bundle can't
    // depend on an app extension, so this can't share a symbol with the app's `PerchID.scheme` -- it is
    // mirrored here on purpose. If you rename the scheme, change it in BOTH places (and CFBundleURLSchemes
    // in Project.swift). (P3-3)
    private static let shakeboardScheme = "shakeboard"

    private let statusLabel = NSTextField(labelWithString: "Adding to ShakeBoard...")
    private let ioLock = NSLock()   // serializes name-selection + write across concurrent providers
    private var photoBlocked = false // set if an image couldn't be read (Photos sandbox); ioLock-guarded
    private var finalized = false    // set once the share is published/aborted; late writers must bail (F4)

    // MARK: UI (small confirmation card)
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 110))

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 26, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            statusLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            statusLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
        ])
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        process()
    }

    // MARK: pipeline
    private func process() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { finish(0); return }

        let handoff = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShakeBoardHandoff-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: handoff, withIntermediateDirectories: true)

        let group = DispatchGroup()
        let lock = NSLock()
        var written = 0
        var completed = false

        for (idx, provider) in providers.enumerated() {
            group.enter()
            materialize(provider, into: handoff, index: idx + 1) { ok in
                if ok { lock.lock(); written += 1; lock.unlock() }
                group.leave()
            }
        }

        // Finalize exactly once -- whichever comes first: all providers done, or the watchdog.
        // The watchdog stops a single misbehaving provider (a load callback that never fires) from
        // hanging the share sheet forever.
        let done: () -> Void = { [weak self] in
            lock.lock()
            let already = completed; completed = true
            let count = written
            lock.unlock()
            guard !already, let self else { return }
            self.ioLock.lock(); self.finalized = true; self.ioLock.unlock()   // late writers now bail (F4)
            if count > 0 {
                let ok = self.openShakeBoard(dir: handoff)
                self.finish(ok ? count : 0, failed: !ok)
            } else {
                try? FileManager.default.removeItem(at: handoff)
                self.finish(0)
            }
        }
        group.notify(queue: .main, execute: done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { done() }
    }

    // Turn one shared attachment into a real file in `dir`.
    private func materialize(_ provider: NSItemProvider, into dir: URL, index: Int,
                             completion: @escaping (Bool) -> Void) {
        let imageUT = UTType.image.identifier
        let urlUT = UTType.url.identifier
        let fileURLUT = UTType.fileURL.identifier
        let textUT = UTType.plainText.identifier

        // 1) A WEB link (Safari) -- conforms to public.url but NOT public.file-url. This must be
        //    checked before the file branch because real files ALSO conform to public.url; without
        //    the file-url exclusion a shared document would be misrouted here and dropped.
        if provider.hasItemConformingToTypeIdentifier(urlUT),
           !provider.hasItemConformingToTypeIdentifier(fileURLUT) {
            provider.loadItem(forTypeIdentifier: urlUT, options: nil) { [weak self] item, _ in
                guard let self, let link = item as? URL, !link.isFileURL,
                      let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https"
                else { completion(false); return }   // only shelve real web links (no javascript:/data:/file:)
                completion(self.writeWebloc(link, into: dir))
            }
            return
        }
        // 2) Image (Photos, screenshots, other apps). See loadImage() for the Photos sandbox caveat.
        if provider.hasItemConformingToTypeIdentifier(imageUT) {
            let concrete = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            } ?? imageUT
            loadImage(provider, concrete: concrete, into: dir, completion: completion)
            return
        }
        // 3) Selected text -- BEFORE the generic file branch. Plain text conforms to public.content, so
        //    bestFileType would otherwise claim it and loadFileRepresentation would fail (no file on
        //    disk), silently dropping the text. Gate on "not a file-url" so a real .txt document still
        //    takes the file branch below. (C10)
        if provider.hasItemConformingToTypeIdentifier(textUT),
           !provider.hasItemConformingToTypeIdentifier(fileURLUT) {
            provider.loadItem(forTypeIdentifier: textUT, options: nil) { [weak self] item, _ in
                let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                guard let self, let text, !text.isEmpty else { completion(false); return }
                completion(self.writeText(text, into: dir))
            }
            return
        }
        // 4) A real file/document on disk (Finder, Preview) -- copy its best file representation.
        if let fileType = Self.bestFileType(for: provider) {
            provider.loadFileRepresentation(forTypeIdentifier: fileType) { [weak self] url, _ in
                completion(self?.copyIn(url, into: dir) ?? false)
            }
            return
        }
        completion(false)
    }

    // The most specific type the provider can vend as an on-disk file.
    private static func bestFileType(for provider: NSItemProvider) -> String? {
        if let concrete = provider.registeredTypeIdentifiers.first(where: { id in
            guard let t = UTType(id) else { return false }
            return t.conforms(to: .data) || t.conforms(to: .content)
        }) { return concrete }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return UTType.fileURL.identifier }
        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) { return UTType.data.identifier }
        return nil
    }

    // Pull an image out of a provider. The robust path for a SANDBOXED share extension is to let the
    // SYSTEM move the bytes across the sandbox boundary for us: loadDataRepresentation (bytes) and
    // loadFileRepresentation (a transient readable copy) both do that. A raw loadItem URL, by contrast,
    // points into the SOURCE app's own container (e.g. Photos' ShareKit-Exports) which the extension
    // cannot read directly -- that was what dead-ended the Photos share. So we try the representation
    // APIs first and only fall back to loadItem for apps that vend inline Data / an NSImage / a URL we
    // can actually read. flagPhotoBlocked fires only if every path fails, so the card can tell the user
    // to drag the photo on instead.
    private func loadImage(_ provider: NSItemProvider, concrete: String, into dir: URL,
                           completion: @escaping (Bool) -> Void) {
        let suggested = provider.suggestedName
        // A) Raw bytes, delivered across the sandbox by the system.
        provider.loadDataRepresentation(forTypeIdentifier: concrete) { [weak self] data, _ in
            guard let self else { completion(false); return }
            if let data, !data.isEmpty {
                completion(self.writeImageData(data, suggestedName: suggested, type: concrete, into: dir))
                return
            }
            // B) A system-provided readable copy on disk -- read it inside the callback (it's transient).
            provider.loadFileRepresentation(forTypeIdentifier: concrete) { [weak self] url, _ in
                guard let self else { completion(false); return }
                let bytes = url.flatMap { try? Data(contentsOf: $0) }
                if let url, let bytes, !bytes.isEmpty {
                    completion(self.writeImageData(bytes, suggestedName: suggested ?? url.lastPathComponent,
                                                   type: concrete, into: dir))
                    return
                }
                // C) Non-Photos apps: inline Data, an NSImage, or a directly-readable URL.
                provider.loadItem(forTypeIdentifier: concrete, options: nil) { [weak self] item, _ in
                    guard let self else { completion(false); return }
                    if let data = item as? Data, !data.isEmpty {
                        completion(self.writeImageData(data, suggestedName: suggested, type: concrete, into: dir))
                        return
                    }
                    if let image = item as? NSImage, let png = Self.pngData(image) {
                        completion(self.writeImageData(png, suggestedName: suggested,
                                                       type: UTType.png.identifier, into: dir))
                        return
                    }
                    if let url = item as? URL, let bytes = try? Data(contentsOf: url), !bytes.isEmpty {
                        completion(self.writeImageData(bytes, suggestedName: suggested ?? url.lastPathComponent,
                                                       type: concrete, into: dir))
                        return
                    }
                    // D) Photos workaround for FB13531865 (open since 2024-01, confirmed still
                    // open by Apple DTS 2025-11, reproduced here on macOS 27.0 26A5388g).
                    // Photos' ShareKit export writes IMG_1234.jpeg but vends a URL naming
                    // IMG_1234.jpg, so A/B/C above all fail POSIX ENOENT on a path that was
                    // never written. loadObject(ofClass:) returns the URL that actually exists.
                    // Keep this AFTER A-C: those are the correct paths for every other app.
                    // Delete once Photos vends a matching filename.
                    _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                        guard let self else { completion(false); return }
                        guard let url else { self.flagPhotoBlocked(); completion(false); return }
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        if let bytes = try? Data(contentsOf: url), !bytes.isEmpty {
                            completion(self.writeImageData(bytes, suggestedName: suggested ?? url.lastPathComponent,
                                                           type: concrete, into: dir))
                            return
                        }
                        self.flagPhotoBlocked()   // no path could deliver the bytes (see caveat)
                        completion(false)
                    }
                }
            }
        }
    }

    private func flagPhotoBlocked() { ioLock.lock(); photoBlocked = true; ioLock.unlock() }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: writers (ioLock-guarded so concurrent providers can't pick the same destination name)
    private func copyIn(_ src: URL?, into dir: URL) -> Bool {
        guard let src else { return false }
        // Match the app's ingest policy: only regular, non-symlink files survive on the shelf. Copying a
        // directory/package/symlink would inflate the "Added" count for an item the app then discards. (C9)
        let vals = try? src.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard vals?.isSymbolicLink != true, vals?.isRegularFile == true else {
            NSLog("ShakeBoardShare: skipping non-regular file \(src.lastPathComponent)"); return false
        }
        let name = Self.sanitizedFilename(src.lastPathComponent, fallback: "shared-file",
                                          defaultExt: src.pathExtension)
        ioLock.lock(); defer { ioLock.unlock() }
        if finalized { return false }   // share already published/aborted (F4)
        let dest = Self.uniqueDest(in: dir, name: name)
        do { try FileManager.default.copyItem(at: src, to: dest); return true }
        catch { NSLog("ShakeBoardShare: copy failed: \(error)"); return false }
    }

    private func writeWebloc(_ link: URL, into dir: URL) -> Bool {
        let base = Self.sanitizedFilename((link.host ?? "link").replacingOccurrences(of: ".", with: "-"),
                                          fallback: "link", defaultExt: "")
        ioLock.lock(); defer { ioLock.unlock() }
        if finalized { return false }   // (F4)
        let dest = Self.uniqueDest(in: dir, name: "\(base).webloc")
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["URL": link.absoluteString], format: .xml, options: 0)
            try data.write(to: dest)
            return true
        } catch { NSLog("ShakeBoardShare: webloc write failed: \(error)"); return false }
    }

    private func writeText(_ text: String, into dir: URL) -> Bool {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "clip"
        let base = Self.sanitizedFilename(firstLine, fallback: "clip", defaultExt: "")
        ioLock.lock(); defer { ioLock.unlock() }
        if finalized { return false }   // (F4)
        let dest = Self.uniqueDest(in: dir, name: "\(base).txt")
        do { try text.write(to: dest, atomically: true, encoding: .utf8); return true }
        catch { NSLog("ShakeBoardShare: text write failed: \(error)"); return false }
    }

    // Photos (and some apps) only offer image BYTES, not an on-disk file -- persist them ourselves,
    // giving the file the right extension for its concrete image type.
    private func writeImageData(_ data: Data?, suggestedName: String?, type: String, into dir: URL) -> Bool {
        guard let data, !data.isEmpty else { return false }
        let ext = UTType(type)?.preferredFilenameExtension ?? "img"
        let name = Self.sanitizedFilename(suggestedName ?? "photo", fallback: "photo", defaultExt: ext)
        ioLock.lock(); defer { ioLock.unlock() }
        if finalized { return false }   // (F4)
        let dest = Self.uniqueDest(in: dir, name: name)
        do { try data.write(to: dest); return true }
        catch { NSLog("ShakeBoardShare: image data write failed: \(error)"); return false }
    }

    // Conservative, filesystem-safe name: strip separators / control / bidi chars, cap length, and
    // never produce a hidden (dot-leading) or empty name.
    // Internal (not private) so the ShakeBoardTests target can exercise each sanitizer branch. (P1-2)
    static func sanitizedFilename(_ raw: String, fallback: String, defaultExt: String) -> String {
        var s = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = String(s.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0x202A...0x202E).contains(scalar.value)   // bidi overrides
                && !(0x2066...0x2069).contains(scalar.value)   // bidi isolates
        })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        // Cap by UTF-8 BYTES, not characters -- the filesystem component limit (~255 bytes) counts bytes,
        // so an 80-grapheme name of multi-byte scalars could still overflow and fail the write. Truncate
        // on whole Characters (never split a scalar), leaving headroom for an extension + collision suffix. (C11)
        let maxBytes = 180
        if s.utf8.count > maxBytes {
            var truncated = ""; var used = 0
            for ch in s {
                let n = String(ch).utf8.count
                if used + n > maxBytes { break }
                truncated.append(ch); used += n
            }
            s = truncated
        }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { s = fallback }
        if !defaultExt.isEmpty && (s as NSString).pathExtension.isEmpty { s += ".\(defaultExt)" }
        return s
    }

    private static func uniqueDest(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var dest = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: dest.path) else { return dest }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = dir.appendingPathComponent(candidate)
            n += 1
        } while fm.fileExists(atPath: dest.path)
        return dest
    }

    // MARK: handoff + dismissal
    // Returns whether ShakeBoard was actually reached; on failure we clean up rather than orphan the copies.
    private func openShakeBoard(dir: URL) -> Bool {
        var comps = URLComponents()
        comps.scheme = Self.shakeboardScheme
        comps.host = "add"
        comps.queryItems = [URLQueryItem(name: "dir", value: dir.path)]
        guard let url = comps.url else { try? FileManager.default.removeItem(at: dir); return false }
        let ok = NSWorkspace.shared.open(url)
        if !ok { try? FileManager.default.removeItem(at: dir) }
        return ok
    }

    private func finish(_ count: Int, failed: Bool = false) {
        ioLock.lock(); let blocked = photoBlocked; ioLock.unlock()
        if failed { statusLabel.stringValue = "Couldn't reach ShakeBoard" }
        else if count > 0 { statusLabel.stringValue = "Added \(count) to ShakeBoard" }
        else if blocked { statusLabel.stringValue = "Can't read that photo -- drag it onto ShakeBoard instead" }
        else { statusLabel.stringValue = "Nothing to add" }
        // Linger on failures/notices so they're actually readable; dismiss a success quickly.
        let delay = count > 0 ? 0.7 : 2.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
