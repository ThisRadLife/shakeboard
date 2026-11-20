//
//  StripModelTests.swift -- v2 unified strip: classifier, highlighter, pins vs retention, sections/search.
//  Temp dirs only; never the real pasteboard or Application Support.
//

import XCTest
import AppKit
@testable import ShakeBoard

@MainActor
final class StripModelTests: XCTestCase {
    private var tmp: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ShakeBoardStripTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func clip(_ preview: String, kind: ClipKind = .text, reps: [String] = [ClipTypes.plainText],
                      app: String? = "Safari", used: Date? = nil) -> Clip {
        Clip(id: UUID(), kind: kind, createdAt: used ?? now, lastUsedAt: used ?? now, sourceBundleID: nil,
             sourceAppName: app, contentHash: UUID().uuidString, preview: preview,
             reps: reps.enumerated().map { StoredRep(item: 0, type: $1, file: "0-\($0).bin", bytes: 1) },
             totalBytes: 1, pixelWidth: nil, pixelHeight: nil)
    }

    // MARK: code detection

    func testDetector_recognizesCommonLanguages() {
        XCTAssertEqual(CodeDetector.language(of: "func total(_ xs: [Item]) -> Double {\n    let s = xs.reduce(0, +)\n    return s * 1.08\n}"), "Swift")
        XCTAssertEqual(CodeDetector.language(of: "def total(xs):\n    s = sum(xs)\n    return s * 1.08\n"), "Python")
        XCTAssertEqual(CodeDetector.language(of: "{\"order\": 48213, \"status\": \"shipped\"}"), "JSON")
        XCTAssertEqual(CodeDetector.language(of: "git log --oneline"), "Shell")
        XCTAssertEqual(CodeDetector.language(of: "$ npm install"), "Shell")
        XCTAssertEqual(CodeDetector.language(of: "SELECT id, name FROM vendors WHERE active = 1"), "SQL")
        XCTAssertEqual(CodeDetector.language(of: "const total = items.map(x => x.price);\nconsole.log(total);"), "JavaScript")
        XCTAssertEqual(CodeDetector.language(of: "<div class=\"a\">hi</div>"), "HTML")
    }

    func testDetector_leavesProseAlone() {
        XCTAssertNil(CodeDetector.language(of: "Order #48213 ships Friday to 123 Main St, Apt 4B. Leave at the door."))
        XCTAssertNil(CodeDetector.language(of: "open the door and let the cat in."))
        XCTAssertNil(CodeDetector.language(of: "Thanks (see attached) -- let me know if Friday works!"))
        XCTAssertNil(CodeDetector.language(of: "Pickup notes\nThursday: grab the glaze samples and confirm the Friday delivery."))
        XCTAssertNil(CodeDetector.language(of: "{not json at all}"), "brace-wrapped prose isn't JSON")
    }

    func testClassifier_kinds() {
        XCTAssertEqual(ClipClassifier.kind(of: clip("x", kind: .image), head: nil), .image)
        XCTAssertEqual(ClipClassifier.kind(of: clip("a.pdf", kind: .files), head: nil), .files)
        XCTAssertEqual(ClipClassifier.kind(of: clip("https://example.com", kind: .url), head: nil), .link)
        XCTAssertEqual(ClipClassifier.kind(of: clip("https://example.com/a"), head: nil), .link, "bare URL text")
        XCTAssertEqual(ClipClassifier.kind(of: clip("Hello there"), head: nil), .text)
        XCTAssertEqual(ClipClassifier.kind(of: clip("Hello there", reps: [ClipTypes.rtf, ClipTypes.plainText]), head: nil), .richText)
        // The collapsed preview hides newlines; the head (real text) decides code.
        let c = clip("def f(x):  return x")
        XCTAssertEqual(ClipClassifier.kind(of: c, head: "def f(x):\n    return x\n"), .code("Python"))
    }

    // MARK: highlighter

    func testHighlighter_tokens() {
        let toks = CodeHighlighter.tokenize("let s = \"hi\" // note\nreturn 42", language: "Swift")
        XCTAssertTrue(toks.contains { $0 == ("let", .keyword) })
        XCTAssertTrue(toks.contains { $0 == ("\"hi\"", .string) })
        XCTAssertTrue(toks.contains { $0 == ("// note", .comment) })
        XCTAssertTrue(toks.contains { $0 == ("42", .number) })
        XCTAssertEqual(toks.map(\.0).joined(), "let s = \"hi\" // note\nreturn 42", "lossless")
        let py = CodeHighlighter.tokenize("x = 1  # c", language: "Python")
        XCTAssertTrue(py.contains { $0 == ("# c", .comment) })
        let sql = CodeHighlighter.tokenize("select a from t", language: "SQL")
        XCTAssertTrue(sql.contains { $0 == ("select", .keyword) }, "SQL keywords are caseless")
        XCTAssertTrue(CodeHighlighter.tokenize("a1 \"unterminated", language: "Swift").map(\.0).joined() == "a1 \"unterminated")
    }

    // MARK: links

    func testLinkInfo_partsAndTitle() {
        let p = LinkInfo.parts("https://www.example.com/gallery/spring?x=1")
        XCTAssertEqual(p?.host, "example.com")
        XCTAssertEqual(p?.path, "/gallery/spring?x=1")
        XCTAssertEqual(LinkInfo.title(fromHTML: "<meta><a href=\"https://e.com\">Spring <b>Collection</b> &amp; more</a>"),
                       "Spring Collection & more")
        XCTAssertNil(LinkInfo.title(fromHTML: "<a href=\"https://e.com\">https://e.com</a>"), "URL-as-text isn't a title")
        XCTAssertEqual(LinkInfo.title(fromHTML: "<html><title>Shop</title></html>"), "Shop")
    }

    // MARK: pins

    func testPins_persistDedupeAndPrune() {
        let a = UUID(), b = UUID()
        let p = ClipPins(baseDir: tmp)
        p.load()
        p.pin(a); p.pin(b); p.pin(a)
        XCTAssertEqual(p.ids, [b, a], "most recently pinned first, no duplicates")
        let q = ClipPins(baseDir: tmp); q.load()
        XCTAssertEqual(q.ids, [b, a])
        q.prune(keeping: [a])
        XCTAssertEqual(q.ids, [a])
        let perms = (try? FileManager.default.attributesOfItem(atPath: q.url.path))?[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertFalse(q.url.path.contains("/Clips/"), "never inside Clips/ (its reconcile deletes unowned files)")
    }

    func testPins_unreadableFileSetAside() throws {
        try Data("garbage".utf8).write(to: tmp.appendingPathComponent("pinboards.json"))
        let p = ClipPins(baseDir: tmp); p.load()
        XCTAssertEqual(p.ids, [])
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("pinboards.json.unreadable-") })
    }

    // Pinned clips survive the 7-day age rule across a relaunch, as long as pins are wired BEFORE load().
    func testPins_exemptFromRetentionAcrossLoad() {
        let store = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        store.load()
        var ids: [UUID] = []
        for t in ["keep me", "let me go"] {
            let exp = expectation(description: t)
            store.ingest(CapturedClipboard(snapshot: RawSnapshot(changeCount: 1, allTypes: [ClipTypes.plainText],
                                                                 items: [[textRep(t)]]),
                                           sourceBundleID: nil, sourceAppName: nil, capturedAt: now)) { c, _ in
                if let c { ids.append(c.id) }; exp.fulfill()
            }
            wait(for: [exp], timeout: 5)
        }
        store.flush()
        let pins = ClipPins(baseDir: tmp); pins.load(); pins.pin(ids[0])

        now = now.addingTimeInterval(30 * 24 * 3600)
        let again = ClipStore(baseDir: tmp, clock: { [unowned self] in self.now })
        let pins2 = ClipPins(baseDir: tmp); pins2.load()
        again.pinned = { pins2.set }
        again.load()
        again.flush()
        XCTAssertEqual(again.clips.map(\.id), [ids[0]], "pinned clip kept; unpinned one aged out")
    }

    // MARK: sections + search

    private func build(_ clips: [Clip], pins: [UUID] = [], files: [ShelfItem] = [], q: String = "",
                       filter: StripFilter = .all, hideImages: Bool = false,
                       ocr: [UUID: String] = [:], fileOCR: [UUID: String] = [:]) -> StripSections {
        StripSections.build(clips: clips, pins: pins, files: files, query: q, filter: filter, hideImageClips: hideImages,
                            kind: { ClipClassifier.kind(of: $0, head: nil) }, text: { _ in nil },
                            ocr: { ocr[$0.id]?.lowercased() }, fileOCR: { fileOCR[$0.id]?.lowercased() },
                            isImageFile: { ["png", "jpg"].contains($0.url.pathExtension) })
    }
    private func file(_ name: String) -> ShelfItem {
        ShelfItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(name)"), bookmark: Data())
    }

    func testSections_pinnedThenFilesThenRecent_numbersFollowVisibleOrder() {
        let a = clip("alpha"), b = clip("beta"), c = clip("gamma")
        let f = file("Invoice.pdf")
        let s = build([a, b, c], pins: [c.id], files: [f])
        XCTAssertEqual(s.pinned.map(\.id), [c.id])
        XCTAssertEqual(s.files.map(\.id), [f.id])
        XCTAssertEqual(s.recent.map(\.id), [a.id, b.id], "pinned clips aren't repeated in Recent")
        XCTAssertEqual(s.order, [.clip(c.id), .file(f.id), .clip(a.id), .clip(b.id)])
    }

    func testSections_searchAndFilters() {
        let t = clip("ship to 123 Main St"), u = clip("https://example.com", kind: .url)
        let img = clip("Image 3 x 3", kind: .image)
        let pdf = file("Invoice-1042.pdf"), png = file("shot.png")
        XCTAssertEqual(build([t, u, img], q: "MAIN").recent.map(\.id), [t.id])
        XCTAssertEqual(build([t, u, img], q: "safari").recent.count, 3, "matches the source app")
        XCTAssertEqual(build([t, u], files: [pdf], q: "invoice").files.map(\.id), [pdf.id])
        XCTAssertEqual(build([t, u, img], filter: .links).recent.map(\.id), [u.id])
        let images = build([t, u, img], files: [pdf, png], filter: .images)
        XCTAssertEqual(images.recent.map(\.id), [img.id])
        XCTAssertEqual(images.files.map(\.id), [png.id], "image files count as Images")
        XCTAssertEqual(build([t], files: [pdf, png], filter: .files).files.count, 2)
        XCTAssertEqual(build([t], files: [pdf], filter: .text).files.count, 0)
    }

    func testSections_imageClipsHiddenWhenTheyGoToTheShelf_unlessPinned() {
        let img = clip("Image", kind: .image), img2 = clip("Image 2", kind: .image)
        let s = build([img, img2], pins: [img2.id], hideImages: true)
        XCTAssertEqual(s.recent.count, 0)
        XCTAssertEqual(s.pinned.map(\.id), [img2.id])
        XCTAssertEqual(build([img], hideImages: false).recent.count, 1)
    }

    func testSections_searchMatchesClipAndShelfOCRWhileKeepingFilters() {
        let image = clip("Image 4 x 4", kind: .image)
        let text = clip("ordinary note")
        let shelfImage = file("receipt.png")
        let pdf = file("manual.pdf")
        let clipOCR = [image.id: "Glaze firing schedule"]
        let shelfOCR = [shelfImage.id: "Vendor total 1042", pdf.id: "should not bypass filter"]

        XCTAssertEqual(build([image, text], files: [shelfImage], q: "FIRING", ocr: clipOCR,
                             fileOCR: shelfOCR).recent.map(\.id), [image.id])
        XCTAssertEqual(build([image], files: [shelfImage], q: "vendor", filter: .images,
                             ocr: clipOCR, fileOCR: shelfOCR).files.map(\.id), [shelfImage.id])
        XCTAssertTrue(build([image], files: [pdf], q: "bypass", filter: .images,
                            ocr: clipOCR, fileOCR: shelfOCR).files.isEmpty,
                      "OCR search must not bypass the active type filter")
    }

    func testBoardSearchMatchesImageOCR() {
        let image = clip("Image 4 x 4", kind: .image)
        let text = clip("ordinary note")
        let ocr = [image.id: "Glaze firing schedule"]
        let sections = StripSections.buildBoard(
            clips: [image, text], ids: [text.id, image.id], query: "FIRING",
            kind: { ClipClassifier.kind(of: $0, head: nil) }, text: { _ in nil },
            ocr: { ocr[$0.id]?.lowercased() })
        XCTAssertEqual(sections.board.map(\.id), [image.id])
    }

    func testOCRSearchIndexIsPreFoldedAndBounded() {
        let text = String(repeating: "A", count: OCRSearchIndex.maxBytes + 1000)
        let indexed = OCRSearchIndex.folded(text)
        XCTAssertLessThanOrEqual(indexed.utf8.count, OCRSearchIndex.maxBytes)
        XCTAssertFalse(indexed.contains("A"))
    }

    func testAge() {
        XCTAssertEqual(Age.short(now, now: now.addingTimeInterval(30)), "now")
        XCTAssertEqual(Age.short(now, now: now.addingTimeInterval(150)), "2m")
        XCTAssertEqual(Age.short(now, now: now.addingTimeInterval(7200)), "2h")
        XCTAssertEqual(Age.short(now, now: now.addingTimeInterval(3 * 86400)), "3d")
        XCTAssertEqual(Age.short(now, now: now.addingTimeInterval(15 * 86400)), "2w")
    }
}
