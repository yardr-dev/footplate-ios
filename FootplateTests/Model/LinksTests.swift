@testable import Footplate
import XCTest

// The web addresses in a card's words (design 3.5): the sign-in line of
// a harness login is a link to the page it names, so what is shown is
// what opens; only an explicit http or https address with a host is a
// link, and the punctuation of the sentence around it is not part of it.
// In mail, a bead id the app knows or the yard confirmed chips beside
// them, opening the bead whole; any other id-shaped word stays plain
// words, as does an id inside a link or a code span.
final class LinksTests: XCTestCase {
    /// The links of `text`: the words each is drawn with, and where it goes.
    private func links(_ text: String) -> [(words: String, url: String)] {
        let drawn = linked(text)
        return drawn.runs.compactMap { run in
            run.link.map { (String(drawn[run.range].characters), $0.absoluteString) }
        }
    }

    /// The chips of `text`: the words each is drawn with, and the bead
    /// id its tap opens.
    private func chips(_ text: String, beads: Set<String>, code: [Range<String.Index>]? = nil) -> [(words: String, bead: String)] {
        let drawn = linked(text, beads: beads, code: code)
        return drawn.runs.compactMap { run in
            run.link.flatMap(chippedBead).map { (String(drawn[run.range].characters), $0) }
        }
    }

    func testTheSignInLineIsALinkToThePageItNames() {
        let page = "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a&scope=user%3Ainference&state=Xk3v#top"
        let line = "Sign in on this page: \(page)"
        let found = links(line)
        XCTAssertEqual(found.map { $0.words }, [page])
        XCTAssertEqual(found.map { $0.url }, [page], "what is shown is what opens")
        XCTAssertEqual(String(linked(line).characters), line, "the words are kept whole")
    }

    func testEachAddressOfALineIsALinkAndSoIsEitherScheme() {
        let found = links("Read http://a.example/x, then HTTPS://B.EXAMPLE/y and https://c.example:8443/z?q=1.")
        XCTAssertEqual(found.map { $0.words }, ["http://a.example/x", "HTTPS://B.EXAMPLE/y", "https://c.example:8443/z?q=1"])
        XCTAssertTrue(links("Nothing to open here.").isEmpty)
        XCTAssertEqual(String(linked("Nothing to open here.").characters), "Nothing to open here.")
    }

    func testThePunctuationOfTheSentenceIsNotPartOfTheAddress() {
        let rows: [(String, String)] = [
            ("Open https://x.example/a.", "https://x.example/a"),
            ("Open https://x.example/a, then", "https://x.example/a"),
            ("Open https://x.example/a?b=1&c=2; then", "https://x.example/a?b=1&c=2"),
            ("Is it https://x.example/a?", "https://x.example/a"),
            ("(see https://x.example/a)", "https://x.example/a"),
            ("[https://x.example/a]", "https://x.example/a"),
            ("'https://x.example/a'", "https://x.example/a"),
            (#"say "https://x.example/a" aloud"#, "https://x.example/a"),
            ("<https://x.example/a>", "https://x.example/a"),
            // A bracket the address opened is its own.
            ("https://en.wikipedia.org/wiki/Foo_(bar)", "https://en.wikipedia.org/wiki/Foo_(bar)"),
            ("(https://en.wikipedia.org/wiki/Foo_(bar)).", "https://en.wikipedia.org/wiki/Foo_(bar)"),
        ]
        for (text, address) in rows {
            XCTAssertEqual(links(text).map { $0.words }, [address], text)
            XCTAssertEqual(links(text).map { $0.url }, [address], text)
            XCTAssertEqual(String(linked(text).characters), text, "the words are kept whole")
        }
    }

    func testOnlyAnExplicitWebAddressWithAHostIsALink() {
        let notLinks = [
            "example.com",
            "www.example.com/path",
            "mailto:jo@example.com",
            "tel:+441234567890",
            "sms:+441234567890",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "ftp://x.example/a",
            "yardr://decide/7",
            "https://",
            "https:// alone",
            "https:///no-host",
            // The old disguise of another host.
            "https://claude.ai@evil.example/login",
            "https://claude.ai:secret@evil.example/login",
            // Cyrillic а, a host that reads as another than it shows.
            "https://\u{0430}pple.example/login",
        ]
        for text in notLinks {
            XCTAssertTrue(links(text).isEmpty, text)
            XCTAssertEqual(String(linked(text).characters), text, text)
        }
        // One that is not beside one that is.
        XCTAssertEqual(links("https://claude.ai@evil.example/x and https://claude.ai/x").map { $0.words }, ["https://claude.ai/x"])
    }

    func testAKnownFullIdChipsAndOpensItsBead() {
        let beads: Set<String> = ["yardr-w311", "yd-crm"]
        let text = "yardr-w311 moves, and yd-crm with it; yardr-w311 lands first."
        let found = chips(text, beads: beads)
        XCTAssertEqual(found.map { $0.words }, ["yardr-w311", "yd-crm", "yardr-w311"])
        XCTAssertEqual(found.map { $0.bead }, ["yardr-w311", "yd-crm", "yardr-w311"], "what is shown is what opens")
        XCTAssertEqual(String(linked(text, beads: beads).characters), text, "the words are kept whole")
        // A chip's link is the app's own, never the system's.
        for run in linked(text, beads: beads).runs where run.link != nil {
            XCTAssertEqual(run.link?.scheme, "footplate-bead")
        }
        // With no bead known, nothing chips.
        XCTAssertTrue(chips(text, beads: []).isEmpty)
        XCTAssertEqual(String(linked(text).characters), text)
    }

    func testAnUnknownIdShapedWordAndABareSuffixStayPlain() {
        let beads: Set<String> = ["yd-crm"]
        let plain = [
            "land yd-train when it is green",
            "re-ask the yard",
            "w311 without its prefix",
            "ask 6926",
            "`yd-crm` in a code span",
            "```\nyd-crm\n``` in a fence",
            "see https://x.example/beads/yd-crm for the bead",
        ]
        for text in plain {
            XCTAssertTrue(chips(text, beads: beads).isEmpty, text)
            XCTAssertEqual(String(linked(text, beads: beads).characters), text, text)
        }
        // Where the caller names the code, as a message's blocks do with
        // their backticks left out, what it names is code and chips
        // nothing; the text's own fences and spans are looked for no more.
        let named = "yd-crm and yd-crm and `yd-crm`"
        let first = named.startIndex..<named.index(named.startIndex, offsetBy: 6)
        XCTAssertEqual(chips(named, beads: beads, code: [first]).count, 2, "the second, and the one a span would have kept")
        XCTAssertEqual(chips(named, beads: beads).count, 2, "the span alone is code where none is named")
        XCTAssertEqual(chips(named, beads: beads, code: []).count, 3)
        // The qualified ask names its bead, which chips as the bead
        // alone; the ask's number never chips.
        let qualified = chips("ask 18 on yd-crm", beads: beads)
        XCTAssertEqual(qualified.map { $0.words }, ["yd-crm"])
        XCTAssertEqual(qualified.map { $0.bead }, ["yd-crm"])
        XCTAssertEqual(beadIds("ask 18 on yd-crm"), ["yd-crm"])
        XCTAssertEqual(beadIds("ask 6926"), [])
    }

    func testALinkAndAChipStandSideBySideUnchanged() {
        let beads: Set<String> = ["yd-gate"]
        let text = "Read https://x.example/a, then land yd-gate."
        let drawn = linked(text, beads: beads)
        let urls = drawn.runs.compactMap { run in run.link.map { (String(drawn[run.range].characters), $0) } }
        XCTAssertEqual(urls.map { $0.0 }, ["https://x.example/a", "yd-gate"])
        XCTAssertEqual(urls[0].1.absoluteString, "https://x.example/a")
        XCTAssertEqual(chippedBead(urls[1].1), "yd-gate")
        XCTAssertEqual(String(drawn.characters), text, "the words are kept whole")
    }

    func testNamedBeadIdsAreEachOnceOutsideLinksAndCode() {
        let rows: [(String, [String])] = [
            ("land yd-gate.", ["yd-gate"]),
            ("yd-gate and yd-gate again", ["yd-gate"]),
            ("(yd-gate) [yd-train]", ["yd-gate", "yd-train"]),
            ("w311 without its prefix", []),
            ("no dash here", []),
            ("ask 6926", []),
            ("see https://x.example/beads/yd-gate first", []),
            ("`yd-gate` stays as it is", []),
            ("`` holds nothing", []),
            ("an `unclosed span names yd-gate", ["yd-gate"]),
            ("```\nyd-gate\n``` fenced", []),
            ("```\nunclosed names yd-gate", ["yd-gate"]),
            ("a peer's yd-crm@peer whole", ["yd-crm@peer"]),
            ("two peers yd-a@x@y are none", []),
        ]
        for (text, ids) in rows {
            XCTAssertEqual(beadIds(text), ids, text)
        }
        // A peer's id chips whole through its own link.
        let beads: Set<String> = ["yd-crm@peer"]
        let found = chips("read yd-crm@peer today", beads: beads)
        XCTAssertEqual(found.map { $0.words }, ["yd-crm@peer"])
        XCTAssertEqual(found.map { $0.bead }, ["yd-crm@peer"])
    }
}
