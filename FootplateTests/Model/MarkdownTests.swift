@testable import Footplate
import XCTest

// The small part of Markdown a letter is drawn with, as the desktop
// footplate's markdown.rs has it: its cases, ported. Left out here because
// only the desktop's selection or its link shortening use them: the
// places in a block's source (`a_place_in_a_block_is_a_place_in_the_source`),
// `verbatim` and `short_link`.
final class MarkdownTests: XCTestCase {
    private let bold = Marks(bold: true)
    private let italic = Marks(italic: true)
    private let code = Marks(code: true)

    /// A block as its kind and what is drawn.
    private struct Drawn: Equatable {
        var kind: BlockKind
        var text: String
    }

    /// The blocks of `text` as their kind and what is drawn.
    private func drawn(_ text: String) -> [Drawn] {
        messageBlocks(text).map { Drawn(kind: $0.kind, text: $0.text) }
    }

    private func text(_ words: String) -> Drawn {
        Drawn(kind: .text, text: words)
    }

    private func codeBlock(_ words: String) -> Drawn {
        Drawn(kind: .code, text: words)
    }

    private func bullet(_ depth: Int, _ words: String) -> Drawn {
        Drawn(kind: .item(marker: "•", depth: depth), text: words)
    }

    private func number(_ marker: String, _ words: String) -> Drawn {
        Drawn(kind: .item(marker: marker, depth: 0), text: words)
    }

    private func heading(_ level: Int, _ words: String) -> Drawn {
        Drawn(kind: .heading(level), text: words)
    }

    /// A stretch of the one block of a text: the words, and how they are drawn.
    private struct Run: Equatable {
        var words: String
        var marks: Marks
    }

    /// The one block of `text`: what is drawn, and the stretches that are
    /// not plain.
    private func marked(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (text: String, runs: [Run]) {
        let all = messageBlocks(text)
        XCTAssertEqual(all.count, 1, text, file: file, line: line)
        guard let block = all.first else { return ("", []) }
        let scalars = Array(block.text.unicodeScalars)
        let runs = block.marks.map { stretch in
            Run(words: String(String.UnicodeScalarView(scalars[stretch.range])), marks: stretch.marks)
        }
        return (block.text, runs)
    }

    /// `text` is one block of text, drawn as it was written.
    private func untouched(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let all = messageBlocks(text)
        XCTAssertEqual(all.count, 1, text, file: file, line: line)
        guard let block = all.first else { return }
        XCTAssertEqual(block.kind, .text, text, file: file, line: line)
        XCTAssertEqual(block.text, text, file: file, line: line)
        XCTAssertTrue(block.marks.isEmpty, "\(text): \(block.marks)", file: file, line: line)
        XCTAssertFalse(block.apart, text, file: file, line: line)
    }

    func testATextWithoutAMarkIsOneBlockAsItWasWritten() {
        untouched("")
        untouched("Land it today, José.")
        untouched("one\ntwo\n\nthree\n")
        untouched("\n\n  indented, after two blank lines")
        untouched("see https://example.org/a_b_c/**/x_y now")
    }

    func testWhatOnlyLooksLikeAMarkIsLeftAlone() {
        // A # in the middle of a line, and one without a space after it.
        untouched("issue #12 and a # alone")
        untouched("#12 is the issue")
        untouched("#")
        // Deeper than the third level is no heading here.
        untouched("#### four")
        // Paths and names with underscores.
        untouched("src/my_file_name.rs and snake_case_name")
        untouched("__init__.py and _private.rs")
        // Stars in globs and in sums.
        untouched("*.rs and src/*.rs, **/*.md")
        untouched("*.*")
        untouched("2 * 3 * 4 and a*b*c")
        // A mark that is never closed.
        untouched("a *star, a **pair, a `tick and an _underscore")
        untouched("``` is three backticks")
        // No list without a space after the marker, or with nothing in it.
        untouched("-dash and 1.5 and 3.14")
        untouched("- ")
        untouched("---")
        untouched("2026. That was the year.")
        // Not on the list: a table, an image, HTML, a footnote, a quote.
        untouched("| a | b |\n|---|---|\n| 1 | 2 |")
        untouched("![fence](fence.png) and <b>bold</b>[^1]")
        untouched("> quoted")
        untouched("a \\*star\\*")
    }

    func testAFenceIsCodeAsItWasWritten() {
        let src = "Run:\n```sh\n  cd yard\n1. not an item\n# not a heading\n- *nor* this\n```\nThen wait."
        XCTAssertEqual(drawn(src), [
            text("Run:"),
            codeBlock("  cd yard\n1. not an item\n# not a heading\n- *nor* this"),
            text("Then wait."),
        ])
        XCTAssertTrue(messageBlocks(src)[1].marks.isEmpty)

        // Without a language word, and with more backticks than three.
        XCTAssertEqual(drawn("```\nls\n```"), [codeBlock("ls")])
        XCTAssertEqual(drawn("````\n```\nls\n```\n````"), [codeBlock("```\nls\n```")])
        // Blank lines in it are its own.
        XCTAssertEqual(drawn("```\n\na\n\nb\n\n```"), [codeBlock("\na\n\nb\n")])
        // An empty one is still a block.
        XCTAssertEqual(drawn("```\n```"), [codeBlock("")])
    }

    func testACopyOfACodeBlockIsTheSourceBetweenTheFences() {
        let code = "  indented\n\ttabbed\n\n" + String(repeating: "echo a very long line that scrolls in the block ", count: 20)
        let src = "Run:\n```sh\n\(code)\n```\nThen wait."
        let all = messageBlocks(src)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[1].copyText, code)
        // The fences and the language word are not in it, and no other
        // block has a copy control.
        XCTAssertNil(all[0].copyText)
        XCTAssertNil(all[2].copyText)
        XCTAssertFalse(all[1].copyText?.contains("```") ?? true)
    }

    func testAnUnclosedFenceHasTheRestAsCodeAndHidesNothing() {
        XCTAssertEqual(drawn("Look:\n```\nfirst\n\n- second\n**third**"), [
            text("Look:"),
            codeBlock("first\n\n- second\n**third**"),
        ])
        XCTAssertEqual(drawn("```"), [codeBlock("")])
    }

    func testInlineCodeBoldAndItalicLoseTheirMarks() {
        XCTAssertEqual(marked("run `yardr prime` now").text, "run yardr prime now")
        XCTAssertEqual(marked("run `yardr prime` now").runs, [Run(words: "yardr prime", marks: code)])

        let emphasis = marked("a **bold** and an *italic* and an _other_ and __more__.")
        XCTAssertEqual(emphasis.text, "a bold and an italic and an other and more.")
        XCTAssertEqual(emphasis.runs, [
            Run(words: "bold", marks: bold),
            Run(words: "italic", marks: italic),
            Run(words: "other", marks: italic),
            Run(words: "more", marks: bold),
        ])

        let both = Marks(bold: true, italic: true)
        let nested = marked("***both*** and **bold with _italic_ in it**")
        XCTAssertEqual(nested.text, "both and bold with italic in it")
        XCTAssertEqual(nested.runs, [
            Run(words: "both", marks: both),
            Run(words: "bold with ", marks: bold),
            Run(words: "italic", marks: both),
            Run(words: " in it", marks: bold),
        ])

        // What is in code is code: no mark in it is read.
        let inCode = marked("`**/*.rs` and ``a ` b``")
        XCTAssertEqual(inCode.text, "**/*.rs and a ` b")
        XCTAssertEqual(inCode.runs, [Run(words: "**/*.rs", marks: code), Run(words: "a ` b", marks: code)])

        let boldCode = marked("**`cargo test`**")
        XCTAssertEqual(boldCode.text, "cargo test")
        XCTAssertEqual(boldCode.runs, [Run(words: "cargo test", marks: Marks(bold: true, code: true))])

        // A link keeps its own stars and underscores, and what closes after
        // it closes.
        let link = marked("**https://example.org/a_b_** (_see https://example.org/*x*_)")
        XCTAssertEqual(link.text, "https://example.org/a_b_ (see https://example.org/*x*)")
        XCTAssertEqual(link.runs, [
            Run(words: "https://example.org/a_b_", marks: bold),
            Run(words: "see https://example.org/*x*", marks: italic),
        ])

        // Emphasis does not go over a line break.
        untouched("*one\ntwo*")
    }

    func testBulletsAndNumbersAreItemsOneLevelDeep() {
        let src = "To do:\n- one\n* two\n  - under two\n      - and deeper\n1. first\n10) tenth"
        XCTAssertEqual(drawn(src), [
            text("To do:"),
            bullet(0, "one"),
            bullet(0, "two"),
            bullet(1, "under two"),
            bullet(1, "and deeper"),
            number("1.", "first"),
            number("10)", "tenth"),
        ])
        // An indented line goes on with its item, without its indent; one
        // that is not indented is text again.
        XCTAssertEqual(drawn("- one\n  goes on\nand ends\n\n- two"), [
            bullet(0, "one\ngoes on"),
            text("and ends"),
            bullet(0, "two"),
        ])
        // An item's words are read as a line's are.
        let item = messageBlocks("- **Done**: see `x`")[0]
        XCTAssertEqual(item.text, "Done: see x")
        XCTAssertEqual(item.marks, [Stretch(range: 0..<4, marks: bold), Stretch(range: 10..<11, marks: code)])
        // An indented item under no other is at the first level.
        XCTAssertEqual(drawn("  - alone"), [bullet(0, "alone")])
    }

    func testHeadingsGoToTheThirdLevel() {
        XCTAssertEqual(drawn("# One\n## Two\n### Three ###\ntext"), [
            heading(1, "One"),
            heading(2, "Two"),
            heading(3, "Three ###"),
            text("text"),
        ])
        let head = messageBlocks("## The `new` stage")[0]
        XCTAssertEqual(head.text, "The new stage")
        XCTAssertEqual(head.marks, [Stretch(range: 4..<7, marks: code)])
    }

    func testBlankLinesBetweenBlocksAreSpaceAndNoLines() {
        let all = messageBlocks("# Head\n\nwords\n\n\n- item\n- next\n\n```\ncode\n```\n\n")
        XCTAssertEqual(all.map(\.text), ["Head", "words", "item", "next", "code"])
        XCTAssertEqual(all.map(\.apart), [false, true, true, false, true])
        // Inside text they stay lines.
        XCTAssertEqual(drawn("one\n\ntwo\n# Head"), [text("one\n\ntwo"), heading(1, "Head")])
    }

    // A mark's place is counted in Unicode scalars of the drawn words, so a
    // picture of several scalars before it moves nothing.
    func testAMarksPlaceCountsScalarsNotCharacters() {
        let found = marked("👍🏽 **bold** ❤️‍🔥 `x`")
        XCTAssertEqual(found.text, "👍🏽 bold ❤️‍🔥 x")
        XCTAssertEqual(found.runs, [Run(words: "bold", marks: bold), Run(words: "x", marks: code)])
    }

    // A letter is anything an agent or a person typed: whatever it holds, it
    // reads into blocks whose marks stand inside their words, in order, and
    // that hold nothing the reading does not give a block of its kind.
    func testAnyTextReadsIntoBlocksWhoseMarksStandInsideTheirWords() {
        let pieces = [
            "`", "``", "```", "````", "*", "**", "***", "_", "__", "#", "##", "###", "####", "- ", "* ", "1. ", "10) ",
            "\n", "\n", "\n\n", "  ", " ", "a", "word", "https://x.org/a_b", "http://", ".", ")", "(", "é", "👍🏽", "\r\n", "\t",
        ]
        // A fixed seed, so a failure is the same failure next time.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<3000 {
            let text = (0..<next(30)).map { _ in pieces[next(pieces.count)] }.joined()
            for block in messageBlocks(text) {
                let count = block.text.unicodeScalars.count
                var end = 0
                for stretch in block.marks {
                    XCTAssertTrue(end <= stretch.range.lowerBound && stretch.range.lowerBound < stretch.range.upperBound && stretch.range.upperBound <= count, "\(text.debugDescription): \(block.marks)")
                    end = stretch.range.upperBound
                }
                switch block.kind {
                case .code: XCTAssertTrue(block.marks.isEmpty, text.debugDescription)
                case .heading(let level): XCTAssertTrue((1...3).contains(level), text.debugDescription)
                case .item(_, let depth): XCTAssertTrue((0...1).contains(depth), text.debugDescription)
                case .text: break
                }
                XCTAssertEqual(block.copyText != nil, block.kind == .code, text.debugDescription)
            }
        }
    }

    // The message mckean read on the phone (mail 141176): three steps and a
    // fenced block with one long line. The block copies as the code alone.
    func testTheSnowflakeMessageIsStepsAndOneCodeBlock() throws {
        let all = messageBlocks(MarkdownFixture.snowflake)
        XCTAssertEqual(all.map(\.kind), [
            .text,
            .item(marker: "1.", depth: 0),
            .item(marker: "2.", depth: 0),
            .code,
            .item(marker: "3.", depth: 0),
            .text,
        ])
        XCTAssertEqual(all.map(\.apart), [false, true, true, true, true, true])
        XCTAssertTrue(all.allSatisfy { $0.marks.isEmpty }, "COMPUTE_WH and YARDR_READ are names, not italics")
        XCTAssertEqual(all[0].text, "Trial it is. Three steps tonight, about 10 minutes:")
        XCTAssertTrue(all[1].text.hasPrefix("Sign up at signup.snowflake.com (Standard edition"))
        XCTAssertTrue(all[2].text.hasSuffix("The private half never leaves the Mac."))
        XCTAssertTrue(all[4].text.hasSuffix("(it looks like ORGNAME-ACCOUNTNAME)."))
        XCTAssertEqual(all[5].text, "Shaper shapes the pack tonight and a builder starts in the morning.")

        let sql = try XCTUnwrap(all[3].copyText)
        let lines = sql.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.first, "CREATE ROLE IF NOT EXISTS YARDR_READ;")
        XCTAssertEqual(lines.last, "GRANT ROLE YARDR_READ TO USER YARDR;")
        XCTAssertTrue(lines[3].hasSuffix("AQAB';"))
        XCTAssertGreaterThan(lines[3].count, 400, "the one long line")
        XCTAssertFalse(sql.contains("```"))
        // What the block copies is what stood between the fences, byte for byte.
        let message = MarkdownFixture.snowflake
        let opening = try XCTUnwrap(message.range(of: "```\n")).upperBound
        let closing = try XCTUnwrap(message.range(of: "\n```\n", range: opening..<message.endIndex))
        XCTAssertEqual(sql, String(message[opening..<closing.lowerBound]))
    }
}

/// Messages the tests and the shots draw.
enum MarkdownFixture {
    /// The message in mckean's screenshot (yardmaster's mail 141176),
    /// verbatim. The key in it is a public key.
    static let snowflake = """
    Trial it is. Three steps tonight, about 10 minutes:

    1. Sign up at signup.snowflake.com (Standard edition, any cloud and region). It comes with the sample data and a warehouse named COMPUTE_WH.

    2. In Snowsight, open a new SQL worksheet as ACCOUNTADMIN, paste this, and run all of it. It makes a read-only user for the yard, signed in with a key I made on the Mac. The private half never leaves the Mac.

    ```
    CREATE ROLE IF NOT EXISTS YARDR_READ;
    GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE YARDR_READ;
    GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE_SAMPLE_DATA TO ROLE YARDR_READ;
    CREATE USER IF NOT EXISTS YARDR TYPE = SERVICE DEFAULT_ROLE = YARDR_READ DEFAULT_WAREHOUSE = COMPUTE_WH RSA_PUBLIC_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAtacji76WMEGpQyJM8DzQ34o+jCuZTek1f2mQ25AQAYclPcK5n8GzllO692+bJctOO7Q5HKw2VrnY1BcHhqga67BPoAzrnZ9WujqgZgDhMmLDvFF09m4sP8YFZSjFQblPIiXIXO/53fFPJ/BCbUJYl7DuExfOMKe5z0eh92l4Ygc2nJMXrTKTnFkG39ebOaotlc1fMb1ocQhmDqj2GN8EH536YoXvXELKRvpzwtnovHVsCeh5sa9TbrCvwgPs05fiA4jTDkpa2iVzpmpzya2x5mNa5zDGrMqlIGfTaITpXdqEIkvOEzoNuL6G/818MH/XfKVMm/B8sPNQfemKa//5+wIDAQAB';
    GRANT ROLE YARDR_READ TO USER YARDR;
    ```

    3. Mail me the account identifier: in Snowsight, your name at the bottom left, then Account, then "Copy account identifier" (it looks like ORGNAME-ACCOUNTNAME).

    Shaper shapes the pack tonight and a builder starts in the morning.
    """
}
