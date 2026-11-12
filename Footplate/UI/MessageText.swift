import SwiftUI
import UIKit

// A letter's words, drawn as the desktop footplate draws them, by the
// blocks of `messageBlocks`: paragraphs, headings and list items in Plex
// Sans with bold, italic and code where they were marked, a quote behind
// its hairline bar, a rule as a hairline, a table as ruled rows, and a
// fenced block in Plex Mono on the sunken surface. A code block does not
// wrap: it scrolls sideways, and its Copy puts the code alone, without its
// fences, on the pasteboard; a wide table scrolls sideways whole the same
// way. Web addresses and known bead ids stay links and chips as `linked`
// has them, except in code, where a bead id is plain code, and a named
// link's words stay a link with its host beside them.

/// The room above a block a blank line stood before, and above a heading;
/// and above a code block or the block under one. The desktop's 0.6 and 0.3
/// of a line of text, on the spacing scale.
private let apartGap: CGFloat = 12
private let nearGap: CGFloat = 6

// Equatable on its words and beads alone (footplate-ios-g0jx): the
// conversation draws it `.equatable()`, so a letter already drawn is
// not read into blocks again when the screen redraws for another
// letter or for the draft. The faces below still follow the person's
// text size through `BlockView`'s scaled metric, which SwiftUI keeps
// current without this body running again.
struct MessageText: View, Equatable {
    let text: String
    var beads: Set<String> = []

    var body: some View {
        let blocks = messageBlocks(text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { at, block in
                BlockView(block: block, beads: beads)
                    .padding(.top, at == 0 ? 0 : room(above: block, under: blocks[at - 1]))
            }
        }
    }

    private func room(above block: MessageBlock, under before: MessageBlock) -> CGFloat {
        if block.apart { return apartGap }
        if case .heading = block.kind { return apartGap }
        if case .table = block.kind { return apartGap }
        if case .rule = block.kind { return apartGap }
        if case .rule = before.kind { return apartGap }
        if block.kind == .code || before.kind == .code { return nearGap }
        return 0
    }
}

private extension BlockKind {
    /// The type role the block's words are set in: a first level heading
    /// is the title, the others the section, as the phone's scale has no
    /// third size of the semibold face.
    var role: ThemeType {
        switch self {
        case .heading(1): .title
        case .heading: .section
        case .text, .item, .code, .table, .quote, .rule: .body
        }
    }
}

private struct BlockView: View {
    let block: MessageBlock
    let beads: Set<String>
    private let role: ThemeType
    /// The size of the role's words at the text size the person has set.
    @ScaledMetric private var size: CGFloat
    /// The space an item's marker has, and between it and the words.
    @ScaledMetric(relativeTo: .body) private var markerWidth: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var markerGap: CGFloat = 6

    init(block: MessageBlock, beads: Set<String>) {
        self.block = block
        self.beads = beads
        let role = block.kind.role
        self.role = role
        _size = ScaledMetric(wrappedValue: role.size, relativeTo: role.textStyle)
    }

    var body: some View {
        switch block.kind {
        case .text:
            words
        case .heading:
            words
                .accessibilityAddTraits(.isHeader)
        case .item(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: markerGap) {
                Text(marker)
                    .themeType(.body)
                    .foregroundStyle(ThemeColor.textSecondary.color)
                    .fixedSize()
                    .frame(width: markerWidth, alignment: .trailing)
                words
            }
            .padding(.leading, CGFloat(depth) * (markerWidth + markerGap))
        case .code:
            CodeBlock(block: block)
        case .quote:
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(ThemeColor.borderStrong.color)
                    .frame(width: 3)
                words
            }
        case .rule:
            Rectangle()
                .fill(ThemeColor.borderSubtle.color)
                .frame(height: 1)
        case .table(let head, let rows, let align):
            TableView(head: head, rows: rows, align: align, beads: beads)
        }
    }

    private var words: some View {
        Text(styledWords(block, role: role, size: size, beads: beads))
            .themeType(role)
            .foregroundStyle(ThemeColor.textPrimary.color)
    }
}

/// A fenced block: a bar with Copy above the code, which stands on one
/// line to a line however long, and scrolls sideways.
private struct CodeBlock: View {
    let block: MessageBlock
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                copyButton
            }
            ScrollView(.horizontal) {
                Text(styledWords(block, role: .code, size: ThemeType.code.size, beads: []))
                    .themeType(.code)
                    .foregroundStyle(ThemeColor.textPrimary.color)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .background(ThemeColor.surfaceSunken.color, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ThemeColor.borderSubtle.color, lineWidth: 1) }
    }

    /// A bordered button of 32 points in a target of 48, which reads
    /// Copied for two seconds, as the desktop's reads "copied".
    private var copyButton: some View {
        Button {
            if let code = block.copyText {
                UIPasteboard.general.string = code
                copied = true
            }
        } label: {
            Text(copied ? "Copied" : "Copy")
                .themeType(.label)
                .foregroundStyle(copied ? ThemeColor.textPrimary.color : ThemeColor.textSecondary.color)
                .padding(.horizontal, 12)
                .frame(minWidth: 48, minHeight: 32)
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(ThemeColor.borderStrong.color, lineWidth: 1) }
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy code")
        .accessibilityIdentifier("code-copy")
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// A table: its head set apart, its rows divided by hairlines, no box
/// and no ground. The columns stand at their words' own width; where they
/// run past the screen the whole table scrolls sideways as one piece, as
/// a code block does, never shrunk and never restacked.
private struct TableView: View {
    let head: [TableCell]
    let rows: [[TableCell]]
    let align: [ColumnAlign]
    let beads: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(head.enumerated()), id: \.offset) { at, cell in
                        cellWords(cell, role: .section, column: at)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                hairline
                ForEach(Array(rows.enumerated()), id: \.offset) { row, cells in
                    GridRow {
                        ForEach(Array(cells.enumerated()), id: \.offset) { at, cell in
                            cellWords(cell, role: .body, column: at)
                        }
                    }
                    if row + 1 < rows.count { hairline }
                }
            }
        }
    }

    private func cellWords(_ cell: TableCell, role: ThemeType, column: Int) -> some View {
        let column = align[column]
        return Text(styledRuns(text: cell.text, marks: cell.marks, links: cell.links, code: false, role: role, size: role.size, beads: beads))
            .themeType(role)
            .foregroundStyle(ThemeColor.textPrimary.color)
            .multilineTextAlignment(column.text)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: column.frame)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .gridColumnAlignment(column.grid)
    }

    private var hairline: some View {
        GridRow {
            Rectangle()
                .fill(ThemeColor.borderSubtle.color)
                .frame(height: 1)
                .gridCellColumns(head.count)
        }
    }
}

private extension ColumnAlign {
    var grid: HorizontalAlignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .left: .topLeading
        case .center: .top
        case .right: .topTrailing
        }
    }

    var text: TextAlignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}

/// The whole text a long-press on prose drawn through `MessageText`
/// offers to copy, or nil where it has none. The copy is the words
/// entire, as they were written, never one link of them; a code block's
/// own Copy gives the code alone, without its fences.
func copyableProse(_ text: String) -> String? {
    text.isEmpty ? nil : text
}

/// `block`'s words as a Text draws them in the face of `role`, which is
/// `size` points at the person's text size: the web addresses and the
/// known bead ids of `beads` links and chips, but no chip in code, and the
/// bold, italic and code stretches in their faces.
func styledWords(_ block: MessageBlock, role: ThemeType, size: CGFloat, beads: Set<String>) -> AttributedString {
    styledRuns(text: block.text, marks: block.marks, links: block.links, code: block.kind == .code, role: role, size: size, beads: beads)
}

/// Words with their marks and their links as a Text draws them: the bare
/// addresses links to themselves and the known bead ids chips, but no
/// chip in code and neither inside a named link's words; the marks in
/// their faces; and each named link's words underlined in the text accent
/// with its host after them in the secondary colour, opening its address.
func styledRuns(text: String, marks: [Stretch], links: [NamedLink], code: Bool, role: ThemeType, size: CGFloat, beads: Set<String>) -> AttributedString {
    let scalars = text.unicodeScalars
    let place = { (offset: Int) in scalars.index(scalars.startIndex, offsetBy: offset) }
    let codeRanges = code
        ? [text.startIndex..<text.endIndex]
        : marks.filter(\.marks.code).map { place($0.range.lowerBound)..<place($0.range.upperBound) }
    let named = links.map { place($0.range.lowerBound)..<place($0.range.upperBound) }
    var words = linked(text, beads: beads, code: codeRanges, named: named)
    let drawn = words.unicodeScalars
    let stretches = marks.map { stretch in
        (
            drawn.index(drawn.startIndex, offsetBy: stretch.range.lowerBound)..<drawn.index(drawn.startIndex, offsetBy: stretch.range.upperBound),
            stretch.marks
        )
    }
    for (range, marks) in stretches {
        words[range].swiftUI.font = markedFont(marks, role: role, size: size)
        if marks.code {
            words[range].swiftUI.backgroundColor = ThemeColor.surfaceSunken.color
        }
    }
    styleLinks(&words)
    // Last words first: each host stands after its words, so what stands
    // already placed moves nothing still to place.
    for link in links.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
        let drawn = words.unicodeScalars
        let start = drawn.index(drawn.startIndex, offsetBy: link.range.lowerBound)
        let end = drawn.index(drawn.startIndex, offsetBy: link.range.upperBound)
        words[start..<end].link = link.url
        words[start..<end].swiftUI.underlineStyle = .single
        words[start..<end].swiftUI.foregroundColor = ThemeColor.textAccent.color
        var host = AttributedString(" · \(link.host)")
        host.swiftUI.foregroundColor = ThemeColor.textSecondary.color
        words.insert(host, at: end)
    }
    return words
}

/// How far a face with no italic is slanted for one: twelve degrees.
private let slant = tan(12 * CGFloat.pi / 180)

/// The face of a marked stretch in words of `role`. Code is in mono and
/// bold is the semibold face, the bundled ones. The app has no italic face,
/// so an italic stretch is its face slanted, as a platform slants one that
/// has none; made at `size`, as a slanted face is not scaled with the
/// text size by itself.
private func markedFont(_ marks: Marks, role: ThemeType, size: CGFloat) -> Font {
    if marks.code { return codeFont(in: role) }
    let face = marks.bold ? ThemeType.section.face : role.face
    guard marks.italic else { return Font.custom(face, size: role.size, relativeTo: role.textStyle) }
    var slanted = CGAffineTransform(a: 1, b: 0, c: slant, d: 1, tx: 0, ty: 0)
    return Font(CTFontCreateWithName(face as CFString, size, &slanted))
}
