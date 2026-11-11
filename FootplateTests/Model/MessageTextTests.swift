@testable import Footplate
import SwiftUI
import XCTest

// A block's words as a Text draws them (footplate-ios-qzxm): the marks of
// its Markdown in their faces, and the links and chips of `linked`, but no
// bead chip in code.
final class MessageTextTests: XCTestCase {
    private let beads: Set<String> = ["yd-links"]

    /// One run of a block's words: what it says and how it is drawn.
    private struct Run: Equatable {
        var words: String
        var font: Font?
        var background: Color?
        var underlined: Bool
        var link: URL?
    }

    /// The runs of the one block of `text`, drawn in `role`.
    private func runs(_ text: String, role: ThemeType = .body, file: StaticString = #filePath, line: UInt = #line) -> [Run] {
        let all = messageBlocks(text)
        XCTAssertEqual(all.count, 1, text, file: file, line: line)
        guard let block = all.first else { return [] }
        let drawn = styledWords(block, role: role, size: role.size, beads: beads)
        return drawn.runs.map { run in
            Run(
                words: String(drawn[run.range].characters),
                font: run.swiftUI.font,
                background: run.swiftUI.backgroundColor,
                underlined: run.swiftUI.underlineStyle != nil,
                link: run.link
            )
        }
    }

    func testBoldItalicAndCodeAreDrawnInTheirFaces() {
        let found = runs("a **bold**, an *italic* and `code` here")
        XCTAssertEqual(found.map(\.words), ["a ", "bold", ", an ", "italic", " and ", "code", " here"])
        // Plain words keep the role's own face.
        XCTAssertNil(found[0].font)
        // Bold is the semibold face, the bundled one.
        XCTAssertEqual(found[1].font, Font.custom("IBMPlexSans-SemiBold", size: 16, relativeTo: .body))
        // Italic is a face of its own, slanted: not the role's.
        XCTAssertNotNil(found[3].font)
        XCTAssertNotEqual(found[3].font, ThemeType.body.font)
        XCTAssertNotEqual(found[3].font, found[1].font)
        // Code is mono on the sunken surface, as a chip is.
        XCTAssertEqual(found[5].font, codeFont())
        XCTAssertEqual(found[5].background, ThemeColor.surfaceSunken.color)
        XCTAssertNil(found[1].background)
    }

    func testAHeadingsMarksStandInTheHeadingsSize() {
        let found = runs("## The `new` stage and **more**", role: .section)
        XCTAssertEqual(found[1].font, codeFont(in: .section))
        XCTAssertEqual(found[3].font, Font.custom("IBMPlexSans-SemiBold", size: 16, relativeTo: .headline))
    }

    // A mark's place counts Unicode scalars, so a picture of several of
    // them before it moves nothing.
    func testAMarkAfterAPictureStandsOnItsOwnWords() {
        let found = runs("👍🏽❤️‍🔥 **bold** and `code`")
        XCTAssertEqual(found.map(\.words), ["👍🏽❤️‍🔥 ", "bold", " and ", "code"])
        XCTAssertNotNil(found[1].font)
        XCTAssertNotNil(found[3].background)
    }

    func testALinkAndAKnownBeadChipInTextButAChipIsNoneInCode() {
        let found = runs("yd-links, `yd-links` and https://example.org/a_b_ now")
        XCTAssertEqual(found.map(\.words), ["yd-links", ", ", "yd-links", " and ", "https://example.org/a_b_", " now"])
        // The id outside code is a chip, opening its bead, in mono.
        XCTAssertEqual(found[0].link.flatMap(chippedBead), "yd-links")
        XCTAssertEqual(found[0].font, codeFont())
        // The one in a code span is code, and no chip.
        XCTAssertNil(found[2].link)
        XCTAssertEqual(found[2].font, codeFont())
        // The link keeps its underscores and opens as it stands.
        XCTAssertEqual(found[4].link?.absoluteString, "https://example.org/a_b_")
        XCTAssertTrue(found[4].underlined)
        XCTAssertNil(found[4].font)
    }

    func testACodeBlockHoldsNoChipAndItsWordsAsTheyStand() {
        let found = runs("```sh\nyardr bead show yd-links\n```")
        XCTAssertEqual(found.map(\.words), ["yardr bead show yd-links"])
        XCTAssertNil(found[0].link)
        // Its face is the Text's own: the role's, here the code's.
        XCTAssertNil(found[0].font)
    }

    /// A copy of prose drawn through `MessageText` (footplate-ios-0thy):
    /// the words entire, as written, never one link of them; none where
    /// it has none. A code block's own Copy is the code alone, without
    /// its fences.
    func testCopyOfProseIsItsWordsWhole() {
        let rows: [(text: String, copy: String?)] = [
            ("Meet at the shed.", "Meet at the shed."),
            ("Read https://x.example/a then.", "Read https://x.example/a then."),
            ("a **bold**, an *italic* and `code` here", "a **bold**, an *italic* and `code` here"),
            ("Run:\n```sh\n  cd yard\n```\nThen wait.", "Run:\n```sh\n  cd yard\n```\nThen wait."),
            ("", nil),
        ]
        for (text, copy) in rows {
            XCTAssertEqual(copyableProse(text), copy, text)
        }
    }
}
