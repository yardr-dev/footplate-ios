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
        var foreground: Color?
        var underlined: Bool
        var link: URL?
    }

    /// The runs of an attributed text: what each says and how it is drawn.
    private func runs(of drawn: AttributedString) -> [Run] {
        drawn.runs.map { run in
            Run(
                words: String(drawn[run.range].characters),
                font: run.swiftUI.font,
                background: run.swiftUI.backgroundColor,
                foreground: run.swiftUI.foregroundColor,
                underlined: run.swiftUI.underlineStyle != nil,
                link: run.link
            )
        }
    }

    /// The runs of the one block of `text`, drawn in `role`.
    private func runs(_ text: String, role: ThemeType = .body, file: StaticString = #filePath, line: UInt = #line) -> [Run] {
        let all = messageBlocks(text)
        XCTAssertEqual(all.count, 1, text, file: file, line: line)
        guard let block = all.first else { return [] }
        return runs(of: styledWords(block, role: role, size: role.size, beads: beads))
    }

    /// The runs of a table's cell, drawn as a block's words are.
    private func cellRuns(_ cell: TableCell) -> [Run] {
        runs(of: styledRuns(text: cell.text, marks: cell.marks, links: cell.links, code: false, role: .body, size: ThemeType.body.size, beads: beads))
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

    // The conversation draws a letter `.equatable()` (footplate-ios-g0jx),
    // so the equality this leans on must hold exactly where the words
    // and the beads are the same, and nowhere else.
    func testALetterIsTheSameDrawnThingOnlyForTheSameWordsAndBeads() {
        XCTAssertEqual(
            MessageText(text: "a **bold** yd-links", beads: beads),
            MessageText(text: "a **bold** yd-links", beads: beads)
        )
        XCTAssertNotEqual(
            MessageText(text: "a **bold** yd-links", beads: beads),
            MessageText(text: "a plain yd-links", beads: beads)
        )
        XCTAssertNotEqual(
            MessageText(text: "a **bold** yd-links", beads: beads),
            MessageText(text: "a **bold** yd-links", beads: [])
        )
    }

    func testACodeBlockHoldsNoChipAndItsWordsAsTheyStand() {
        let found = runs("```sh\nyardr bead show yd-links\n```")
        XCTAssertEqual(found.map(\.words), ["yardr bead show yd-links"])
        XCTAssertNil(found[0].link)
        // Its face is the Text's own: the role's, here the code's.
        XCTAssertNil(found[0].font)
    }

    func testANamedLinkDrawsItsWordsWithItsHost() {
        let found = runs("See the [release page](https://yardr.dev/releases) first.")
        XCTAssertEqual(found.map(\.words), ["See the ", "release page", " · yardr.dev", " first."])
        // The words open the address, underlined in the text accent.
        XCTAssertEqual(found[1].link?.absoluteString, "https://yardr.dev/releases")
        XCTAssertTrue(found[1].underlined)
        XCTAssertEqual(found[1].foreground, ThemeColor.textAccent.color)
        // The host stands beside them in the secondary colour: no link,
        // no underline. The screen reader announces the words, that it is
        // a link, and the host.
        XCTAssertNil(found[2].link)
        XCTAssertFalse(found[2].underlined)
        XCTAssertEqual(found[2].foreground, ThemeColor.textSecondary.color)
        XCTAssertNil(found[0].link)
        // Bold inside the words keeps its face under the link's dress.
        let held = runs("**[held](https://example.org)**")
        XCTAssertEqual(held.map(\.words), ["held", " · example.org"])
        XCTAssertEqual(held[0].link?.absoluteString, "https://example.org")
        XCTAssertEqual(held[0].font, Font.custom("IBMPlexSans-SemiBold", size: 16, relativeTo: .body))
        XCTAssertTrue(held[0].underlined)
        XCTAssertNil(held[1].link)
    }

    func testANamedLinkAndABareAddressOpenEachItsOwn() {
        let found = runs("See [named](https://a.example/x) and https://b.example/y.")
        XCTAssertEqual(found.map(\.words), ["See ", "named", " · a.example", " and ", "https://b.example/y", "."])
        XCTAssertEqual(found[1].link?.absoluteString, "https://a.example/x")
        XCTAssertEqual(found[4].link?.absoluteString, "https://b.example/y")
    }

    func testAKnownBeadInsideANamedLinksWordsIsNoChip() {
        let found = runs("See [yd-links here](https://example.org/a) and yd-links.")
        XCTAssertEqual(found.map(\.words), ["See ", "yd-links here", " · example.org", " and ", "yd-links", "."])
        // The words open the address, not the bead.
        XCTAssertEqual(found[1].link?.absoluteString, "https://example.org/a")
        XCTAssertNil(found[1].link.flatMap(chippedBead))
        // The id outside the words still chips.
        XCTAssertEqual(found[4].link.flatMap(chippedBead), "yd-links")
    }

    func testABareAddressInCodeStillOpensWhileANamedShapeStaysCode() {
        let fenced = runs("```\n[release page](https://yardr.dev/releases) and https://yardr.dev/releases\n```")
        XCTAssertEqual(fenced.compactMap(\.link).map(\.absoluteString), ["https://yardr.dev/releases", "https://yardr.dev/releases"])
        XCTAssertFalse(fenced.map(\.words).joined().contains(" · "), "no named link is carried")
        let spanned = runs("`[release page](https://yardr.dev/releases)`")
        XCTAssertEqual(spanned.compactMap(\.link).map(\.absoluteString), ["https://yardr.dev/releases"])
    }

    func testAQuoteAndATableCellDrawTheirMarksAndLinks() {
        let quoted = runs("> **bold** and [words](https://example.org/a)")
        XCTAssertEqual(quoted.map(\.words), ["bold", " and ", "words", " · example.org"])
        XCTAssertNotNil(quoted[0].font)
        XCTAssertEqual(quoted[2].link?.absoluteString, "https://example.org/a")
        // A cell's words draw as a block's do, in the cell's coordinates.
        let all = messageBlocks("| **b** | [w](https://h.example/x) |\n|---|---|\n| `c` | d |")
        guard case .table(let head, let rows, _) = all.first?.kind else { return XCTFail("no table read") }
        let bold = cellRuns(head[0])
        XCTAssertEqual(bold.map(\.words), ["b"])
        XCTAssertEqual(bold[0].font, Font.custom("IBMPlexSans-SemiBold", size: 16, relativeTo: .body))
        let linked = cellRuns(head[1])
        XCTAssertEqual(linked.map(\.words), ["w", " · h.example"])
        XCTAssertEqual(linked[0].link?.absoluteString, "https://h.example/x")
        let code = cellRuns(rows[0][0])
        XCTAssertEqual(code.map(\.words), ["c"])
        XCTAssertEqual(code[0].font, codeFont())
        XCTAssertEqual(code[0].background, ThemeColor.surfaceSunken.color)
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
            ("| Yard | Waiting |\n| --- | --- |\n| home | none |", "| Yard | Waiting |\n| --- | --- |\n| home | none |"),
            ("> Hold the timetable.\n> It is printed.", "> Hold the timetable.\n> It is printed."),
            ("See the [release page](https://yardr.dev/releases) first.", "See the [release page](https://yardr.dev/releases) first."),
            ("one\n\n---\n\ntwo", "one\n\n---\n\ntwo"),
            (MarkdownFixture.forms, MarkdownFixture.forms),
            ("", nil),
        ]
        for (text, copy) in rows {
            XCTAssertEqual(copyableProse(text), copy, text)
        }
    }
}
