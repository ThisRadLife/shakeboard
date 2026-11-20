//
//  TransformTests.swift -- v2 PR 2: pure card transforms (plain, trim, case, JSON, URL tracking, Markdown link)
//  and which ones a card offers. No pasteboard, no disk.
//

import XCTest
@testable import ShakeBoard

final class TransformTests: XCTestCase {

    private func input(_ text: String, kind: CardKind = .text, rich: Bool = false, title: String? = nil,
                       items: Int = 1) -> TransformInput {
        TransformInput(text: text, kind: kind, hasRich: rich, linkTitle: title, itemCount: items)
    }

    // MARK: trim

    func testTrim_endsAndTrailingSpacesPerLine() {
        XCTAssertEqual(ClipTransform.trim.apply(input("  \n hello  \nworld\t \n\n")), "hello\nworld")
    }
    func testTrim_keepsIndentationInside() {
        XCTAssertEqual(ClipTransform.trim.apply(input("\nfunc a() {\n    b()   \n}\n")), "func a() {\n    b()\n}")
    }
    func testTrim_nilWhenNothingToTrim() {
        XCTAssertNil(ClipTransform.trim.apply(input("tidy")))
    }

    // MARK: case

    func testCase_upperLowerTitle() {
        XCTAssertEqual(ClipTransform.uppercase.apply(input("Mixed case")), "MIXED CASE")
        XCTAssertEqual(ClipTransform.lowercase.apply(input("Mixed CASE")), "mixed case")
        XCTAssertEqual(ClipTransform.titleCase.apply(input("the QUICK brown-fox\njumps over")),
                       "The Quick Brown-fox\nJumps Over")
        XCTAssertEqual(ClipTransform.titleCase.apply(input("don't stop")), "Don't Stop")
    }
    func testCase_nilWhenUnchanged() {
        XCTAssertNil(ClipTransform.uppercase.apply(input("ALREADY")))
        XCTAssertNil(ClipTransform.lowercase.apply(input("already")))
        XCTAssertNil(ClipTransform.titleCase.apply(input("Already Title")))
    }

    // MARK: JSON (key order and number spelling are preserved -- no JSONSerialization round trip)

    func testJSON_prettyKeepsKeyOrder() {
        let src = #"{"zeta":1,"alpha":[1,2.50,{"k":"a, b: {c}"}],"empty":{},"none":[],"s":"q\"uote"}"#
        let want = """
        {
          "zeta": 1,
          "alpha": [
            1,
            2.50,
            {
              "k": "a, b: {c}"
            }
          ],
          "empty": {},
          "none": [],
          "s": "q\\"uote"
        }
        """
        XCTAssertEqual(ClipTransform.jsonPretty.apply(input(src, kind: .code("JSON"))), want)
    }
    func testJSON_minifyRoundTrip() {
        let pretty = "{\n  \"a\" : [ 1, 2 ],\n  \"b\": \"x y\"\n}\n"
        XCTAssertEqual(ClipTransform.jsonMinify.apply(input(pretty, kind: .code("JSON"))),
                       #"{"a":[1,2],"b":"x y"}"#)
    }
    func testJSON_onlyOfferedForValidJSON() {
        let ok = input(#"{"a":1}"#, kind: .code("JSON"))
        XCTAssertTrue(ClipTransform.available(for: ok).contains(.jsonMinify) == false)   // already minified
        XCTAssertTrue(ClipTransform.available(for: ok).contains(.jsonPretty))
        let bad = input(#"{"a":1,}"#, kind: .code("JSON"))
        XCTAssertNil(ClipTransform.jsonPretty.apply(bad))
        XCTAssertFalse(ClipTransform.available(for: bad).contains(.jsonPretty))
        XCTAssertNil(ClipTransform.jsonPretty.apply(input("just words")))
    }

    func testJSON_strictValidator() {
        for ok in [#"{}"#, #"[]"#, #"{"a":[1,-2.5e+3,true,false,null,"\u00e9\n"]}"#, " [ 0 , {\"k\" : {}} ] "] {
            XCTAssertTrue(JSONFormatter.isValid(ok), ok)
        }
        for bad in [#"{"a":1,}"#, #"[1,]"#, #"{a:1}"#, #"[01]"#, #"["x\q"]"#, #"[1 2]"#, #"{"a":1"#, "[\"tab\there\"]",
                    #"[.5]"#, #"[1.]"#, #"[NaN]"#, #"{} x"#] {
            XCTAssertFalse(JSONFormatter.isValid(bad), bad)
        }
        XCTAssertFalse(JSONFormatter.isValid(String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)))
    }

    // MARK: URL tracking

    func testStripTracking_removesKnownParamsOnly() {
        let u = "https://shop.example.com/p/42?utm_source=news&id=7&fbclid=abc&UTM_Medium=x&gclid=1#reviews"
        XCTAssertEqual(ClipTransform.stripTracking.apply(input(u, kind: .link)), "https://shop.example.com/p/42?id=7#reviews")
    }
    func testStripTracking_dropsEmptyQuery() {
        XCTAssertEqual(ClipTransform.stripTracking.apply(input("https://a.com/x?utm_campaign=y&mc_eid=2", kind: .link)),
                       "https://a.com/x")
    }
    func testStripTracking_keepsEncodingAndNilWhenClean() {
        XCTAssertEqual(ClipTransform.stripTracking.apply(input("https://a.com/s?q=a%20b%26c&utm_x=1", kind: .link)),
                       "https://a.com/s?q=a%20b%26c")
        XCTAssertNil(ClipTransform.stripTracking.apply(input("https://a.com/s?q=1", kind: .link)))
        XCTAssertFalse(ClipTransform.available(for: input("https://a.com/s?q=1", kind: .link)).contains(.stripTracking))
    }

    // MARK: Markdown link

    func testMarkdownLink_usesTitleElseHost() {
        XCTAssertEqual(ClipTransform.markdownLink.apply(input("https://www.example.com/a", kind: .link, title: "Spring [Sale]")),
                       #"[Spring \[Sale\]](https://www.example.com/a)"#)
        XCTAssertEqual(ClipTransform.markdownLink.apply(input("https://www.example.com/a(b)", kind: .link)),
                       "[example.com](https://www.example.com/a%28b%29)")
        XCTAssertNil(ClipTransform.markdownLink.apply(input("not a link")))
    }

    // MARK: plain text

    func testPlainText_onlyForRichCopies() {
        XCTAssertEqual(ClipTransform.plainText.apply(input("Bold words", kind: .richText, rich: true)), "Bold words")
        XCTAssertNil(ClipTransform.plainText.apply(input("Bold words")))
    }

    // MARK: availability

    func testAvailable_byKind() {
        let text = ClipTransform.available(for: input(" Hello There "))
        XCTAssertEqual(text, [.trim, .uppercase, .lowercase])        // already title case; not rich, not JSON, not a link
        let link = ClipTransform.available(for: input("https://a.com/?utm_source=x", kind: .link, title: "A"))
        XCTAssertTrue(link.contains(.stripTracking))
        XCTAssertTrue(link.contains(.markdownLink))
        XCTAssertFalse(link.contains(.uppercase))                    // shouting a URL breaks it
        XCTAssertEqual(ClipTransform.available(for: input("x", kind: .image)), [])
        XCTAssertEqual(ClipTransform.available(for: input("a\nb", items: 2)), [])   // multi-item copies: not yet
    }
    func testEditable() {
        XCTAssertTrue(ClipTransform.isEditable(input("x")))
        XCTAssertTrue(ClipTransform.isEditable(input("x", kind: .code("Swift"))))
        XCTAssertTrue(ClipTransform.isEditable(input("https://a.com", kind: .link)))
        XCTAssertFalse(ClipTransform.isEditable(input("x", kind: .image)))
        XCTAssertFalse(ClipTransform.isEditable(input("x", kind: .files)))
        XCTAssertFalse(ClipTransform.isEditable(input("a", items: 3)))
    }
    // MARK: review round 1

    func testStripTracking_leavesCleanURLsByteForByte() {
        XCTAssertEqual(URLCleaner.stripTracking("https://a.com/x?a=1&&b=2"), "https://a.com/x?a=1&&b=2")
        XCTAssertNil(ClipTransform.stripTracking.apply(input("https://a.com/x?a=1&&b=2", kind: .link)))
        XCTAssertEqual(URLCleaner.stripTracking("https://a.com/x?a=1&&utm_x=2"), "https://a.com/x?a=1&")
    }
    func testMarkdownLink_encodesRawUnsafeCharacters() {
        let out = ClipTransform.markdownLink.apply(input("https://a.com/a<b>", kind: .link))
        XCTAssertEqual(out, "[a.com](https://a.com/a%3Cb%3E)")
    }
    func testRichHyperlink_usesURLRep() {
        let link = TransformInput(text: "OpenAI", kind: .link, hasRich: true, linkTitle: nil, itemCount: 1,
                                  url: "https://openai.com/?utm_source=x")
        XCTAssertEqual(ClipTransform.markdownLink.apply(link), "[OpenAI](https://openai.com/?utm_source=x)")
        XCTAssertEqual(ClipTransform.stripTracking.apply(link), "https://openai.com/")
        let offered = ClipTransform.available(for: link)
        XCTAssertTrue(offered.contains(.markdownLink) && offered.contains(.stripTracking))
    }
    func testJSONPretty_capsOutputSize() {
        let deep = String(repeating: "[", count: 300) + "1" + String(repeating: "]", count: 300)
        XCTAssertNotNil(JSONFormatter.pretty(deep))
        XCTAssertNil(JSONFormatter.pretty(deep, maxBytes: 10_000), "300 levels of indentation passes 10 KB")
    }
    func testAvailability_incompleteHeadIsOptimistic() {
        var head = TransformInput(text: "[\n  {\"a\": 1},", kind: .code("JSON"), hasRich: false, linkTitle: nil, itemCount: 1)
        XCTAssertFalse(ClipTransform.available(for: head).contains(.jsonPretty), "a complete text must validate")
        head.complete = false
        XCTAssertTrue(ClipTransform.available(for: head).contains(.jsonPretty), "the head of a long JSON clip")
        XCTAssertTrue(ClipTransform.available(for: head).contains(.trim))
    }
    func testTrim_handlesCRLF() {
        XCTAssertEqual(ClipTransform.trim.apply(input("a  \r\nb\r\n")), "a\nb")
        XCTAssertTrue(ClipTransform.needsTrim("a  \r\nb"))
    }
    func testCase_incompleteHeadOffersBothWays() {
        var head = input("ALL CAPS SO FAR")
        XCTAssertFalse(ClipTransform.available(for: head).contains(.uppercase))
        head.complete = false
        XCTAssertTrue(ClipTransform.available(for: head).contains(.uppercase), "the rest may have lowercase")
        XCTAssertTrue(ClipTransform.available(for: head).contains(.lowercase))
    }
    func testHTMLText_keepsPreIndentation() {
        let html = "<html><body><pre>  if x {\n      y()\n  }</pre><p>a &amp; b</p></body></html>"
        XCTAssertEqual(HTMLText.plain(html), "  if x {\n      y()\n  }\na & b\n")
    }
}
