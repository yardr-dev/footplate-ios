@testable import Footplate
import XCTest

// The web addresses in a card's words (design 3.5): the sign-in line of
// a harness login is a link to the page it names, so what is shown is
// what opens; only an explicit http or https address with a host is a
// link, and the punctuation of the sentence around it is not part of it.
final class LinksTests: XCTestCase {
    /// The links of `text`: the words each is drawn with, and where it goes.
    private func links(_ text: String) -> [(words: String, url: String)] {
        let drawn = linked(text)
        return drawn.runs.compactMap { run in
            run.link.map { (String(drawn[run.range].characters), $0.absoluteString) }
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
}
