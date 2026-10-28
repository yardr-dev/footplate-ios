@testable import Footplate
import XCTest

// A long-press on a letter offers its whole text to copy, the
// person's own and the yard's alike; a letter with no text (an
// image alone) offers nothing.
final class ConversationModelTests: XCTestCase {
    func testCopyMessageOffersTheLettersWholeText() {
        let rows: [(text: String, copy: String?)] = [
            ("Meet at the shed.", "Meet at the shed."),
            ("Read https://x.example/a then.", "Read https://x.example/a then."),
            ("", nil),
        ]
        for (text, copy) in rows {
            let theirs = Shown(seq: 1, mine: false, text: text, time: "09:30")
            XCTAssertEqual(copyableMessage(theirs), copy, text)
            let mine = Shown(seq: 2, mine: true, text: text, time: "09:31")
            XCTAssertEqual(copyableMessage(mine), copy, "own: \(text)")
        }
    }
}
