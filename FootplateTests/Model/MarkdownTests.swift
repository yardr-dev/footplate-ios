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

    private func quote(_ words: String) -> Drawn {
        Drawn(kind: .quote, text: words)
    }

    private func rule() -> Drawn {
        Drawn(kind: .rule, text: "")
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
        XCTAssertTrue(block.links.isEmpty, "\(text): \(block.links)", file: file, line: line)
        XCTAssertFalse(block.apart, text, file: file, line: line)
    }

    /// One named link of the one block of a text: the words, where a tap
    /// opens, and the host shown beside them.
    private struct Linked: Equatable {
        var words: String
        var url: String
        var host: String
    }

    /// The one block of `text`: what is drawn, the stretches that are not
    /// plain, and the named links it carries.
    private func named(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (text: String, runs: [Run], links: [Linked]) {
        let all = messageBlocks(text)
        XCTAssertEqual(all.count, 1, text, file: file, line: line)
        guard let block = all.first else { return ("", [], []) }
        let scalars = Array(block.text.unicodeScalars)
        let runs = block.marks.map { stretch in
            Run(words: String(String.UnicodeScalarView(scalars[stretch.range])), marks: stretch.marks)
        }
        let links = block.links.map { link in
            Linked(words: String(String.UnicodeScalarView(scalars[link.range])), url: link.url.absoluteString, host: link.host)
        }
        return (block.text, runs, links)
    }

    /// The one table of `text`: its head, its rows and its alignments.
    private func table(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (head: [TableCell], rows: [[TableCell]], align: [ColumnAlign])? {
        let all = messageBlocks(text)
        XCTAssertEqual(all.count, 1, text, file: file, line: line)
        guard let block = all.first else { return nil }
        guard case .table(let head, let rows, let align) = block.kind else {
            XCTFail("\(text): no table read", file: file, line: line)
            return nil
        }
        return (head, rows, align)
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
        untouched("--")
        untouched("2026. That was the year.")
        // Not on the list: an image, HTML, a footnote.
        untouched("![fence](fence.png) and <b>bold</b>[^1]")
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

    func testTablesAreAHeadRowsAndAlignments() throws {
        let found = try XCTUnwrap(table("| Yard | Waiting |\n| :--- | ------: |\n| home | none |\n| airy | 2 |"))
        XCTAssertEqual(found.head.map(\.text), ["Yard", "Waiting"])
        XCTAssertEqual(found.rows.map { $0.map(\.text) }, [["home", "none"], ["airy", "2"]])
        XCTAssertEqual(found.align, [.left, .right])
        XCTAssertTrue(found.head.allSatisfy { $0.marks.isEmpty && $0.links.isEmpty })
        // Bold, code and a named link stand in cells.
        let marked = try XCTUnwrap(table("| **bold** | `code` | [words](https://example.org/a) |\n|---|---|---|\n| x | y | z |"))
        XCTAssertEqual(marked.head.map(\.text), ["bold", "code", "words"])
        XCTAssertEqual(marked.head[0].marks, [Stretch(range: 0..<4, marks: bold)])
        XCTAssertEqual(marked.head[1].marks, [Stretch(range: 0..<4, marks: code)])
        XCTAssertEqual(marked.head[2].links.map(\.host), ["example.org"])
        XCTAssertEqual(marked.head[2].links.map { $0.url.absoluteString }, ["https://example.org/a"])
        XCTAssertEqual(marked.rows.map { $0.map(\.text) }, [["x", "y", "z"]])
        // A pipe in code and an escaped pipe are the cell's own.
        let pipes = try XCTUnwrap(table("| `a|b` | c\\|d |\n|---|---|\n| 1 | 2 |"))
        XCTAssertEqual(pipes.head.map(\.text), ["a|b", "c|d"])
        XCTAssertEqual(pipes.head[0].marks, [Stretch(range: 0..<3, marks: code)])
        XCTAssertTrue(pipes.head[1].marks.isEmpty)
        // A short row is filled, a long one cut.
        let ragged = try XCTUnwrap(table("| a | b |\n|---|---|\n| 1 |\n| 2 | 3 | 4 |"))
        XCTAssertEqual(ragged.rows.map { $0.map(\.text) }, [["1", ""], ["2", "3"]])
        // A header and a delimiter with no body is a table with no rows.
        let bare = try XCTUnwrap(table("| a | b |\n|---|---|"))
        XCTAssertEqual(bare.head.map(\.text), ["a", "b"])
        XCTAssertTrue(bare.rows.isEmpty)
        XCTAssertEqual(bare.align, [.left, .left])
    }

    func testWhatIsNoTableStaysText() {
        // No delimiter under the header.
        untouched("| a | b |\n| 1 | 2 |")
        // A delimiter of another cell count is no delimiter.
        untouched("| a | b |\n|---|---|---|")
        // A body line with no `|` ends the table; what follows is text.
        let all = messageBlocks("| a | b |\n|---|---|\n| 1 | 2 |\nno pipes\n| 3 | 4 |")
        XCTAssertEqual(all.count, 2)
        guard case .table(_, let rows, _) = all[0].kind else { return XCTFail("no table read") }
        XCTAssertEqual(rows.map { $0.map(\.text) }, [["1", "2"]])
        XCTAssertEqual(all[1].kind, .text)
        XCTAssertEqual(all[1].text, "no pipes\n| 3 | 4 |")
    }

    func testQuotesAreTheirLinesWithoutTheirMarkers() {
        XCTAssertEqual(drawn("> Hold the timetable.\n> It is printed."), [
            quote("Hold the timetable.\nIt is printed."),
        ])
        // Bold, code and a named link stand inside.
        let all = messageBlocks("> **bold** and `code` and [words](https://example.org/a)")
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.kind, .quote)
        XCTAssertEqual(all.first?.text, "bold and code and words")
        XCTAssertEqual(all.first?.marks.map(\.marks), [Marks(bold: true), Marks(code: true)])
        XCTAssertEqual(all.first?.links.map(\.host), ["example.org"])
        // A quoted blank line is a blank line inside.
        XCTAssertEqual(drawn("> one\n>\n> two"), [quote("one\n\ntwo")])
        // One level is stripped: the second `>` is the words'.
        XCTAssertEqual(drawn(">> nested"), [quote("> nested")])
        // No lazy continuation: the unmarked line stands outside.
        XCTAssertEqual(drawn("> Held.\nStanding outside."), [quote("Held."), text("Standing outside.")])
    }

    func testAMarkerRunGoverningNoWordsIsNoQuote() {
        untouched(">")
        untouched("> \n>")
    }

    func testAQuotesApartIsTheBlankLineBeforeIt() {
        XCTAssertEqual(messageBlocks("# Head\n> quoted").map(\.apart), [false, false])
        XCTAssertEqual(messageBlocks("# Head\n\n> quoted").map(\.apart), [false, true])
        XCTAssertEqual(messageBlocks("> quoted").map(\.apart), [false])
    }

    func testRulesStandAloneAcrossTheColumn() {
        for line in ["---", "***", "___", "- - -"] {
            XCTAssertEqual(drawn(line), [rule()], line)
        }
        // Two is not three, and an item's words are the item's.
        untouched("--")
        XCTAssertEqual(drawn("- -"), [bullet(0, "-")])
        // A rule under text makes no heading of it.
        XCTAssertEqual(drawn("Title\n---"), [text("Title"), rule()])
        // A rule between paragraphs takes the wide room, above and below.
        let all = messageBlocks("one\n\n---\n\ntwo")
        XCTAssertEqual(all.map(\.kind), [.text, .rule, .text])
        XCTAssertEqual(all.map(\.apart), [false, true, true])
    }

    func testANamedLinkKeepsItsWordsAndCarriesItsAddress() {
        let link = named("See the [release page](https://yardr.dev/releases) first.")
        XCTAssertEqual(link.text, "See the release page first.")
        XCTAssertTrue(link.runs.isEmpty)
        XCTAssertEqual(link.links, [Linked(words: "release page", url: "https://yardr.dev/releases", host: "yardr.dev")])
        // A port, a query and a fragment are a link, opened whole.
        let ported = named("[yard](https://example.org:8443/a?b=c#d)")
        XCTAssertEqual(ported.text, "yard")
        XCTAssertEqual(ported.links, [Linked(words: "yard", url: "https://example.org:8443/a?b=c#d", host: "example.org")])
        // Bold and code stand inside the words.
        let marked = named("[a **bold** and `code`](https://example.org/a)")
        XCTAssertEqual(marked.text, "a bold and code")
        XCTAssertEqual(marked.runs, [Run(words: "bold", marks: bold), Run(words: "code", marks: code)])
        XCTAssertEqual(marked.links, [Linked(words: "a bold and code", url: "https://example.org/a", host: "example.org")])
        // Emphasis around a link bolds its words and keeps it a link.
        let held = named("**[held](https://example.org)**")
        XCTAssertEqual(held.text, "held")
        XCTAssertEqual(held.runs, [Run(words: "held", marks: bold)])
        XCTAssertEqual(held.links, [Linked(words: "held", url: "https://example.org", host: "example.org")])
    }

    func testWhatIsNoNamedLinkStaysWritten() {
        untouched("[mail](mailto:a@example.org)")
        untouched("[page](/releases)")
        untouched("[broken](https://example.org")
        untouched("[empty]()")
        untouched("![alt](https://example.org/x.png)")
        // The authority's host is evil.example; a user name with a
        // password; a host that is not ASCII.
        untouched("[yardr](https://yardr.dev@evil.example/login)")
        untouched("[yardr](https://user:pass@yardr.dev/login)")
        untouched("[yardr](https://münchen.example/login)")
        // A malformed port is no link; an empty port and an IPv6
        // authority are, as the bare addresses read.
        untouched("[yardr](https://yardr.dev:abc/)")
        let empty = named("[yardr](https://yardr.dev:/x)")
        XCTAssertEqual(empty.links, [Linked(words: "yardr", url: "https://yardr.dev:/x", host: "yardr.dev")])
        let six = named("[yardr](https://[::1]/x)")
        XCTAssertEqual(six.links, [Linked(words: "yardr", url: "https://[::1]/x", host: "[::1]")])
        // A well-formed address whose host the words do not describe is
        // still a link: the check reads the address, not the words.
        let evil = named("[release page](https://evil.example/login)")
        XCTAssertEqual(evil.links, [Linked(words: "release page", url: "https://evil.example/login", host: "evil.example")])
    }

    func testANamedLinkStandsBesideABareAddressAndInsideAQuoteAndACell() throws {
        let both = named("See [named](https://a.example/x) and https://b.example/y.")
        XCTAssertEqual(both.text, "See named and https://b.example/y.")
        XCTAssertEqual(both.links, [Linked(words: "named", url: "https://a.example/x", host: "a.example")])
        let quoted = messageBlocks("> see [named](https://a.example/x)")
        XCTAssertEqual(quoted.first?.links.map(\.host), ["a.example"])
        let celled = try XCTUnwrap(table("| [named](https://a.example/x) | b |\n|---|---|\n| 1 | 2 |"))
        XCTAssertEqual(celled.head[0].text, "named")
        XCTAssertEqual(celled.head[0].links.map(\.host), ["a.example"])
    }

    func testANamedShapeInCodeIsCodeWhileItsAddressStillOpens() {
        // In a fence the brackets are the code's own, and no link is carried.
        let fenced = messageBlocks("```\n[release page](https://yardr.dev/releases) and https://yardr.dev/releases\n```")
        XCTAssertEqual(fenced.count, 1)
        XCTAssertEqual(fenced.first?.kind, .code)
        XCTAssertEqual(fenced.first?.text, "[release page](https://yardr.dev/releases) and https://yardr.dev/releases")
        XCTAssertTrue(fenced.first?.links.isEmpty ?? false)
        // In a span the shape is written characters, and no link is carried.
        let spanned = named("`[release page](https://yardr.dev/releases)`")
        XCTAssertEqual(spanned.text, "[release page](https://yardr.dev/releases)")
        XCTAssertEqual(spanned.runs, [Run(words: "[release page](https://yardr.dev/releases)", marks: code)])
        XCTAssertTrue(spanned.links.isEmpty)
        // That the two bare addresses still open is drawn, and asserted
        // where links are cut, in MessageTextTests.
    }

    func testTheFourFormsTogetherAreATextATableAQuoteATextAndARule() {
        let all = messageBlocks(MarkdownFixture.forms)
        XCTAssertEqual(all.count, 5)
        XCTAssertEqual(all[0].kind, .text)
        XCTAssertEqual(all[0].text, "Two yards answer tonight:")
        guard case .table(let head, let rows, let align) = all[1].kind else { return XCTFail("no table read") }
        XCTAssertEqual(head.map(\.text), ["Yard", "Waiting", "Working"])
        XCTAssertEqual(rows.map { $0.map(\.text) }, [["home", "none", "3"], ["airy", "2", "none"]])
        XCTAssertEqual(align, [.left, .right, .right])
        XCTAssertEqual(all[2].kind, .quote)
        XCTAssertEqual(all[2].text, "Hold the autumn timetable until the folded\ncarriers are printed.")
        XCTAssertEqual(all[3].kind, .text)
        XCTAssertEqual(all[3].text, "See the release page before you start.")
        XCTAssertEqual(all[3].links.map(\.host), ["yardr.dev"])
        XCTAssertEqual(all[4].kind, .rule)
        XCTAssertEqual(all.map(\.apart), [false, true, true, true, true])
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
            "|", "> ", ">", "[", "]", "](https://x.org/a)", "---", ":", "@", "\\",
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
                // The marks and the named links stand inside the words, in
                // order, and a table's cells hold the same of their own.
                let count = block.text.unicodeScalars.count
                var end = 0
                for stretch in block.marks {
                    XCTAssertTrue(end <= stretch.range.lowerBound && stretch.range.lowerBound < stretch.range.upperBound && stretch.range.upperBound <= count, "\(text.debugDescription): \(block.marks)")
                    end = stretch.range.upperBound
                }
                var addressed = 0
                for link in block.links {
                    XCTAssertTrue(addressed <= link.range.lowerBound && link.range.lowerBound < link.range.upperBound && link.range.upperBound <= count, "\(text.debugDescription): \(block.links)")
                    addressed = link.range.upperBound
                }
                switch block.kind {
                case .code: XCTAssertTrue(block.marks.isEmpty, text.debugDescription)
                case .heading(let level): XCTAssertTrue((1...3).contains(level), text.debugDescription)
                case .item(_, let depth): XCTAssertTrue((0...1).contains(depth), text.debugDescription)
                case .table(let head, let rows, let align):
                    XCTAssertGreaterThanOrEqual(head.count, 2, text.debugDescription)
                    XCTAssertEqual(align.count, head.count, text.debugDescription)
                    for row in rows {
                        XCTAssertEqual(row.count, head.count, text.debugDescription)
                    }
                    for cell in head + rows.flatMap({ $0 }) {
                        let cells = cell.text.unicodeScalars.count
                        var cellEnd = 0
                        for stretch in cell.marks {
                            XCTAssertTrue(cellEnd <= stretch.range.lowerBound && stretch.range.lowerBound < stretch.range.upperBound && stretch.range.upperBound <= cells, "\(text.debugDescription): \(cell.marks)")
                            cellEnd = stretch.range.upperBound
                        }
                        var cellAddressed = 0
                        for link in cell.links {
                            XCTAssertTrue(cellAddressed <= link.range.lowerBound && link.range.lowerBound < link.range.upperBound && link.range.upperBound <= cells, "\(text.debugDescription): \(cell.links)")
                            cellAddressed = link.range.upperBound
                        }
                    }
                case .quote: break
                case .rule: XCTAssertEqual(block.text, "", text.debugDescription)
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
    /// The four forms together, the design's section 3 example verbatim:
    /// a text, a table, a quote, a text with a named link, and a rule.
    static let forms = """
    Two yards answer tonight:

    | Yard | Waiting | Working |
    | :--- | ------: | ------: |
    | home | none | 3 |
    | airy | 2 | none |

    > Hold the autumn timetable until the folded
    > carriers are printed.

    See the [release page](https://yardr.dev/releases) before you start.

    ---
    """

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
