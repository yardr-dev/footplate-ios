import Foundation

// The small part of Markdown a letter is drawn with, the part an agent's
// mail uses: fenced code and inline code, bullets and numbered lists one
// level deep, headings down to the third, bold and italic, tables, quotes,
// rules and named links. Everything else is text as it was written. As
// the desktop footplate's markdown.rs has it, rule for rule and over
// Unicode scalars as its chars are, not a general Markdown library's
// reading: an image, HTML or a footnote stays the words they were.
//
// A text becomes blocks, one under the other. A block is drawn without
// its marks.

/// What a block is drawn as.
enum BlockKind: Equatable, Sendable {
    /// Lines as they were written, line breaks and blank lines included.
    case text
    /// What stood between two fences, or after one that was never closed.
    case code
    /// A heading of level 1 to 3.
    case heading(Int)
    /// An item of a list: `marker` is drawn before it, a dot for a bullet
    /// and the number as it was written. `depth` is 0, or 1 for an item
    /// under another.
    case item(marker: String, depth: Int)
    /// A table: its head row and its body rows, one alignment per column
    /// from the delimiter. A cell holds inline words alone, never a block.
    case table(head: [TableCell], rows: [[TableCell]], align: [ColumnAlign])
    /// Quoted lines, their markers left out, line breaks kept.
    case quote
    /// A rule: no drawn words, no marks, no links.
    case rule
}

/// How a table's column sets its head and its cells' words.
enum ColumnAlign: Equatable, Sendable {
    case left, center, right
}

/// One cell of a table: its drawn words, their marks and their named
/// links, in the cell's own coordinates.
struct TableCell: Equatable, Sendable {
    var text: String
    var marks: [Stretch]
    var links: [NamedLink]
}

/// A named link: where its words stand, in Unicode scalars of the block's
/// or the cell's text, the URL a tap opens, and the host shown beside the
/// words.
struct NamedLink: Equatable, Sendable {
    var range: Range<Int>
    var url: URL
    /// The checked address's host as written, lower-cased, without port,
    /// path or scheme.
    var host: String
}

/// How a stretch of a block is drawn apart from the rest of it.
struct Marks: Equatable, Sendable {
    var bold = false
    var italic = false
    var code = false
}

/// A stretch of a block's text that is not plain: where it stands, in
/// Unicode scalars of the block's text, and how it is drawn.
struct Stretch: Equatable, Sendable {
    var range: Range<Int>
    var marks: Marks
}

struct MessageBlock: Equatable, Sendable {
    var kind: BlockKind
    /// What is drawn: the source without its marks. A table's words stand
    /// in its cells, and a rule draws none, so both keep none here.
    var text: String
    /// The stretches of `text` that are not plain, in order.
    var marks: [Stretch]
    /// The named links of `text`, in order. A table's stand in its cells.
    var links: [NamedLink] = []
    /// A blank line stood between this block and the one before it.
    var apart: Bool

    /// What a copy of this block puts on the pasteboard: a code block's
    /// is the source between the fences, byte for byte, and no other
    /// block has a copy control.
    var copyText: String? {
        kind == .code ? text : nil
    }
}

/// The blocks `text` is drawn as, from top to bottom. A text without a
/// mark is one block with the text as it is.
func messageBlocks(_ text: String) -> [MessageBlock] {
    let t = Array(text.unicodeScalars)
    var lines: [Range<Int>] = []
    var start = 0
    for (at, scalar) in t.enumerated() where scalar == "\n" {
        lines.append(start..<at)
        start = at + 1
    }
    lines.append(start..<t.count)
    let blank = { [lines] (i: Int) in lines[i].allSatisfy { isSpace(t[$0]) } }

    var blocks: [MessageBlock] = []
    // A blank line was passed since the last block.
    var apart = false
    // The lines since the last block that are text and nothing else.
    var plain: Range<Int>?

    // They become a block. The blank lines between it and its neighbours
    // are the space between blocks, and no lines of it.
    func flush(more: Bool) {
        guard var run = plain else { return }
        plain = nil
        while !blocks.isEmpty, !run.isEmpty, blank(run.lowerBound) {
            run = (run.lowerBound + 1)..<run.upperBound
            apart = true
        }
        var after = false
        while more, !run.isEmpty, blank(run.upperBound - 1) {
            run = run.lowerBound..<(run.upperBound - 1)
            after = true
        }
        if !run.isEmpty {
            var out = Out()
            for i in run {
                if i > run.lowerBound { out.pushLineBreak() }
                inline(&out, t, lines[i], Marks())
            }
            blocks.append(out.block(.text, apart: apart))
            apart = false
        }
        apart = apart || after
    }

    var i = 0
    while i < lines.count {
        let line = lines[i]
        if let n = fence(t, line) {
            flush(more: true)
            // A fence that is never closed has the rest of the text.
            let close = ((i + 1)..<lines.count).first { closes(t, lines[$0], n) }
            let last = close ?? lines.count
            var out = Out()
            if last > i + 1 {
                out.push(t[lines[i + 1].lowerBound..<lines[last - 1].upperBound], Marks())
            }
            blocks.append(out.block(.code, apart: apart))
            apart = false
            i = last + 1
            continue
        }
        if let (level, words) = heading(t, line) {
            flush(more: true)
            var out = Out()
            inline(&out, t, words.lowerBound..<trimmedEnd(t, words), Marks())
            blocks.append(out.block(.heading(level), apart: apart))
            apart = false
            i += 1
            continue
        }
        if rule(t, line) {
            flush(more: true)
            blocks.append(MessageBlock(kind: .rule, text: "", marks: [], apart: apart))
            apart = false
            i += 1
            continue
        }
        if let found = item(t, line) {
            flush(more: true)
            var under = false
            if case .item = blocks.last?.kind { under = true }
            let first = t[found.marker.lowerBound]
            let marker = first == "-" || first == "*" ? "•" : String(String.UnicodeScalarView(t[found.marker]))
            var out = Out()
            inline(&out, t, found.words..<line.upperBound, Marks())
            // An indented line under an item goes on with it.
            var last = i
            while last + 1 < lines.count {
                let next = lines[last + 1]
                let goesOn = !next.isEmpty && t[next.lowerBound] == " "
                    && !blank(last + 1) && fence(t, next) == nil && item(t, next) == nil
                if !goesOn { break }
                out.pushLineBreak()
                var words = next.lowerBound
                while t[words] == " " { words += 1 }
                inline(&out, t, words..<next.upperBound, Marks())
                last += 1
            }
            let kind = BlockKind.item(marker: marker, depth: found.indent >= 2 && under ? 1 : 0)
            blocks.append(out.block(kind, apart: apart))
            apart = false
            i = last + 1
            continue
        }
        if quoteLine(t, line) != nil {
            var last = i
            while last + 1 < lines.count, quoteLine(t, lines[last + 1]) != nil { last += 1 }
            // A run that governs no words is no quote: its lines stay text.
            let carries = (i...last).contains { at in
                let words = quoteLine(t, lines[at])!
                return (words.lowerBound..<words.upperBound).contains { !isSpace(t[$0]) }
            }
            if carries {
                flush(more: true)
                var out = Out()
                for at in i...last {
                    if at > i { out.pushLineBreak() }
                    inline(&out, t, quoteLine(t, lines[at])!, Marks())
                }
                blocks.append(out.block(.quote, apart: apart))
                apart = false
            } else {
                for at in i...last {
                    plain = plain.map { $0.lowerBound..<(at + 1) } ?? at..<(at + 1)
                }
            }
            i = last + 1
            continue
        }
        if i + 1 < lines.count, cells(t, line).count >= 2 {
            let head = cells(t, line)
            if let align = delimiter(t, lines[i + 1], cells: head.count) {
                flush(more: true)
                let cellsOf = head.map { cell(t, $0) }
                var rows: [[TableCell]] = []
                var last = i + 1
                while last + 1 < lines.count {
                    let next = lines[last + 1]
                    let claimed = fence(t, next) != nil || heading(t, next) != nil || rule(t, next)
                        || item(t, next) != nil || quoteLine(t, next) != nil
                    guard !blank(last + 1),
                          (next.lowerBound..<next.upperBound).contains(where: { t[$0] == "|" }),
                          !claimed
                    else { break }
                    var parts = cells(t, next).map { cell(t, $0) }
                    while parts.count < cellsOf.count {
                        parts.append(TableCell(text: "", marks: [], links: []))
                    }
                    rows.append(Array(parts.prefix(cellsOf.count)))
                    last += 1
                }
                blocks.append(MessageBlock(kind: .table(head: cellsOf, rows: rows, align: align), text: "", marks: [], apart: apart))
                apart = false
                i = last + 1
                continue
            }
        }
        plain = plain.map { $0.lowerBound..<(i + 1) } ?? i..<(i + 1)
        i += 1
    }
    flush(more: false)
    return blocks
}

/// A block as it is put together.
private struct Out {
    var text = String.UnicodeScalarView()
    var count = 0
    var marks: [Stretch] = []
    var links: [NamedLink] = []

    /// `scalars` are drawn next, as `how` says.
    mutating func push<S: Collection>(_ scalars: S, _ how: Marks) where S.Element == Unicode.Scalar {
        if scalars.isEmpty { return }
        let shown = count
        text.append(contentsOf: scalars)
        count += scalars.count
        if how == Marks() { return }
        if let last = marks.last, last.range.upperBound == shown, last.marks == how {
            marks[marks.count - 1].range = last.range.lowerBound..<count
        } else {
            marks.append(Stretch(range: shown..<count, marks: how))
        }
    }

    /// The break between two lines of a block.
    mutating func pushLineBreak() {
        text.append("\n")
        count += 1
    }

    func block(_ kind: BlockKind, apart: Bool) -> MessageBlock {
        MessageBlock(kind: kind, text: String(text), marks: marks, links: links, apart: apart)
    }
}

// MARK: - Reading a line

private func isSpace(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace
}

private func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.isAlphabetic { return true }
    switch scalar.properties.generalCategory {
    case .decimalNumber, .letterNumber, .otherNumber: return true
    default: return false
    }
}

private func isOneOf(_ scalar: Unicode.Scalar, _ set: String) -> Bool {
    set.unicodeScalars.contains(scalar)
}

/// Whether the text from `i` on, up to `end`, starts with `prefix`.
private func starts(_ t: [Unicode.Scalar], _ i: Int, _ end: Int, with prefix: String) -> Bool {
    let prefix = Array(prefix.unicodeScalars)
    return i + prefix.count <= end && t[i..<(i + prefix.count)].elementsEqual(prefix)
}

/// How many times `c` stands from `i` on, up to `end`.
private func runOf(_ t: [Unicode.Scalar], _ c: Unicode.Scalar, _ i: Int, _ end: Int) -> Int {
    var n = 0
    while i + n < end, t[i + n] == c { n += 1 }
    return n
}

/// Where `line` ends once the whitespace at its end is left out.
private func trimmedEnd(_ t: [Unicode.Scalar], _ line: Range<Int>) -> Int {
    var end = line.upperBound
    while end > line.lowerBound, isSpace(t[end - 1]) { end -= 1 }
    return end
}

/// What may close a sentence or a bracket after a link: as in the links a
/// text is searched for.
private let afterALink = ".,;:!?)]>\"'"

/// Whether a `*` or `_` with `before` it and `after` it may open emphasis:
/// at the start of a word, and not in the middle of one or before a dot or
/// a slash, which is a glob or a path.
private func opens(before: Unicode.Scalar?, after: Unicode.Scalar?) -> Bool {
    let free = before.map { isSpace($0) || isOneOf($0, "([{\"'") } ?? true
    return free && (after.map { isAlphanumeric($0) || isOneOf($0, "*_`\"'([") } ?? false)
}

/// Where in `from..<end`, which follows an opening run of `n` times `c`,
/// the run that closes it stands: of the same length, at the end of a word.
private func closer(_ t: [Unicode.Scalar], _ c: Unicode.Scalar, _ n: Int, _ from: Int, _ end: Int) -> Int? {
    var at = from
    while let found = (at..<end).first(where: { t[$0] == c }) {
        let run = runOf(t, c, found, end)
        let before = found > from ? t[found - 1] : nil
        let next = found + run
        let ends: Bool
        if next >= end {
            ends = true
        } else if t[next] == "." {
            // A dot closes a sentence, and stands inside a file's name.
            ends = next + 1 >= end || !isAlphanumeric(t[next + 1])
        } else {
            ends = isSpace(t[next]) || isOneOf(t[next], ",;:!?)]}\"'")
        }
        if run == n, let before, !isSpace(before), ends {
            return found
        }
        at = next
    }
    return nil
}

/// Where in `from..<end`, which follows an opening run of `n` backticks, a
/// run of exactly as many stands.
private func codeEnd(_ t: [Unicode.Scalar], _ n: Int, _ from: Int, _ end: Int) -> Int? {
    var at = from
    while let found = (at..<end).first(where: { t[$0] == "`" }) {
        let run = runOf(t, "`", found, end)
        if run == n { return found }
        at = found + run
    }
    return nil
}

/// One line, or what stands inside emphasis: inline code, bold and italic
/// lose their marks, a named link keeps its words and carries its address,
/// and a mark that opens or closes nothing stays as it was written. No
/// link is read inside a link's own words.
private func inline(_ out: inout Out, _ t: [Unicode.Scalar], _ line: Range<Int>, _ marks: Marks, allowLinks: Bool = true) {
    let end = line.upperBound
    // What was read and not yet put out: text without a mark in it.
    var from = line.lowerBound
    var i = line.lowerBound
    while i < end {
        let c = t[i]
        // A link is no place for a mark: its stars and underscores are its
        // own, except those after its end, which may close what is around it.
        if c == "h", starts(t, i, end, with: "http://") || starts(t, i, end, with: "https://") {
            var run = i
            while run < end, !isSpace(t[run]) { run += 1 }
            var link = run
            while link > i, isOneOf(t[link - 1], afterALink + "*_`") { link -= 1 }
            i += max(link - i, "http".count)
            continue
        }
        if c == "`" {
            let n = runOf(t, "`", i, end)
            if let close = codeEnd(t, n, i + n, end) {
                out.push(t[from..<i], marks)
                var code = marks
                code.code = true
                out.push(t[(i + n)..<close], code)
                i = close + n
                from = i
            } else {
                i += n
            }
            continue
        }
        if c == "*" || c == "_" {
            let n = runOf(t, c, i, end)
            let before = i > line.lowerBound ? t[i - 1] : nil
            let after = i + n < end ? t[i + n] : nil
            let close = n <= 3 && opens(before: before, after: after) ? closer(t, c, n, i + n, end) : nil
            if let close {
                out.push(t[from..<i], marks)
                var inner = marks
                inner.bold = marks.bold || n >= 2
                inner.italic = marks.italic || n != 2
                inline(&out, t, (i + n)..<close, inner, allowLinks: allowLinks)
                i = close + n
                from = i
            } else {
                i += n
            }
            continue
        }
        if c == "[", allowLinks, i == line.lowerBound || t[i - 1] != "!" {
            if let shape = namedShape(t, i, end), let found = namedLink(shape.address) {
                out.push(t[from..<i], marks)
                let start = out.count
                var words: [Unicode.Scalar] = []
                words.reserveCapacity(shape.words.count)
                var at = shape.words.lowerBound
                while at < shape.words.upperBound {
                    if t[at] == "\\", at + 1 < shape.words.upperBound, t[at + 1] == "]" {
                        words.append("]")
                        at += 2
                        continue
                    }
                    words.append(t[at])
                    at += 1
                }
                inline(&out, words, 0..<words.count, marks, allowLinks: false)
                out.links.append(NamedLink(range: start..<out.count, url: found.url, host: found.host))
                i = shape.after
                from = i
                continue
            }
        }
        i += 1
    }
    out.push(t[from..<end], marks)
}

/// The named link `[words](address)` opening at `open`, if one stands
/// there: where the words end, the address with its brackets unescaped,
/// and where the shape ends. The words run to the first unescaped `]`; a
/// `!` before the `[` is an image's, and no part of any link here. The
/// address runs to the `)` balancing the opening one, with no space and
/// no control character in it, so a title after it is no link.
private func namedShape(_ t: [Unicode.Scalar], _ open: Int, _ end: Int) -> (words: Range<Int>, address: String, after: Int)? {
    var words = open + 1
    var shut: Int? = nil
    while words < end {
        if t[words] == "\\", words + 1 < end, t[words + 1] == "]" {
            words += 2
            continue
        }
        if t[words] == "]" {
            shut = words
            break
        }
        words += 1
    }
    guard let close = shut, close > open + 1, close + 1 < end, t[close + 1] == "(" else { return nil }
    var address = String.UnicodeScalarView()
    var depth = 1
    var at = close + 2
    while at < end {
        if t[at] == "\\", at + 1 < end, t[at + 1] == "(" || t[at + 1] == ")" {
            address.append(t[at + 1])
            at += 2
            continue
        }
        if t[at] == "(" {
            depth += 1
        } else if t[at] == ")" {
            depth -= 1
            if depth == 0 {
                return address.isEmpty ? nil : (words: (open + 1)..<close, address: String(address), after: at + 1)
            }
        } else if isSpace(t[at]) || t[at].properties.generalCategory == .control {
            return nil
        }
        address.append(t[at])
        at += 1
    }
    return nil
}

// MARK: - Reading the lines of a text

/// The backticks of the fence `line` opens, if it opens one: three or more
/// at its start, and after them at most a word for the language.
private func fence(_ t: [Unicode.Scalar], _ line: Range<Int>) -> Int? {
    var start = line.lowerBound
    while start < line.upperBound, t[start] == " " { start += 1 }
    let n = runOf(t, "`", start, line.upperBound)
    guard n >= 3 else { return nil }
    let language = (start + n)..<trimmedEnd(t, start..<line.upperBound)
    return language.contains { t[$0] == "`" || t[$0] == " " } ? nil : n
}

/// Whether `line` closes a fence of `n` backticks: as many or more, alone.
private func closes(_ t: [Unicode.Scalar], _ line: Range<Int>, _ n: Int) -> Bool {
    var start = line.lowerBound
    var end = line.upperBound
    while start < end, t[start] == " " { start += 1 }
    while end > start, t[end - 1] == " " { end -= 1 }
    return end - start >= n && t[start..<end].allSatisfy { $0 == "`" }
}

/// The level of the heading `line` is and where its words stand, if it is
/// one: one to three `#` at its start and a space.
private func heading(_ t: [Unicode.Scalar], _ line: Range<Int>) -> (Int, Range<Int>)? {
    let n = runOf(t, "#", line.lowerBound, line.upperBound)
    var words = line.lowerBound + n
    guard (1...3).contains(n), words < line.upperBound, t[words] == " " else { return nil }
    while words < line.upperBound, t[words] == " " { words += 1 }
    return words < line.upperBound ? (n, words..<line.upperBound) : nil
}

/// The item `line` is, if it is one: how far it is indented, its marker,
/// and where its words begin. A marker is `-`, `*` or a number of up to
/// three digits with a dot or a bracket, and a space follows it.
private func item(_ t: [Unicode.Scalar], _ line: Range<Int>) -> (indent: Int, marker: Range<Int>, words: Int)? {
    let indent = runOf(t, " ", line.lowerBound, line.upperBound)
    let start = line.lowerBound + indent
    guard start < line.upperBound else { return nil }
    let marker: Int
    if t[start] == "-" || t[start] == "*" {
        marker = start + 1
    } else {
        var digits = 0
        while start + digits < line.upperBound, ("0"..."9").contains(t[start + digits]) { digits += 1 }
        guard (1...3).contains(digits), start + digits < line.upperBound,
              t[start + digits] == "." || t[start + digits] == ")" else { return nil }
        marker = start + digits + 1
    }
    guard marker < line.upperBound, t[marker] == " " else { return nil }
    var words = marker
    while words < line.upperBound, t[words] == " " { words += 1 }
    return words < line.upperBound ? (indent, start..<marker, words) : nil
}

/// Whether `line` is a rule: three or more of one of `-*_`, with a single
/// space allowed between any two, after up to three leading spaces and
/// with nothing else on the line. Tried before the item reading, so
/// `- - -` is a rule and `- item` an item; a line under text makes no
/// heading of it.
private func rule(_ t: [Unicode.Scalar], _ line: Range<Int>) -> Bool {
    guard runOf(t, " ", line.lowerBound, line.upperBound) <= 3 else { return false }
    let end = trimmedEnd(t, line)
    var at = line.lowerBound
    while at < end, t[at] == " " { at += 1 }
    guard at < end, isOneOf(t[at], "-*_") else { return false }
    let mark = t[at]
    var count = 0
    while at < end {
        guard t[at] == mark else { return false }
        count += 1
        at += 1
        if at < end {
            if t[at] == " " {
                at += 1
                guard at < end, t[at] == mark else { return false }
            } else {
                guard t[at] == mark else { return false }
            }
        }
    }
    return count >= 3
}

/// Where the quote's words stand on `line`, if it is a quoted line: `>`
/// after no more than three leading spaces. One `>` and at most one space
/// after it are the marker and are not drawn; a second `>` is the words'.
private func quoteLine(_ t: [Unicode.Scalar], _ line: Range<Int>) -> Range<Int>? {
    let indent = runOf(t, " ", line.lowerBound, line.upperBound)
    guard indent <= 3 else { return nil }
    let start = line.lowerBound + indent
    guard start < line.upperBound, t[start] == ">" else { return nil }
    var words = start + 1
    if words < line.upperBound, t[words] == " " { words += 1 }
    return words..<line.upperBound
}

/// The cells `line` cuts into on its `|`s. One that is escaped (`\|`,
/// drawn as `|`) or inside an inline code span cuts nothing; a `|` at the
/// line's start or end, the spaces at the line's ends left off, frames the
/// row and makes no cell.
private func cells(_ t: [Unicode.Scalar], _ line: Range<Int>) -> [Range<Int>] {
    let end = line.upperBound
    var cuts: [Int] = []
    var at = line.lowerBound
    while at < end {
        if t[at] == "\\", at + 1 < end, t[at + 1] == "|" {
            at += 2
            continue
        }
        if t[at] == "`" {
            let n = runOf(t, "`", at, end)
            if let close = codeEnd(t, n, at + n, end) {
                at = close + n
                continue
            }
            at += n
            continue
        }
        if t[at] == "|" { cuts.append(at) }
        at += 1
    }
    guard !cuts.isEmpty else { return [line] }
    var parts: [Range<Int>] = []
    var from = line.lowerBound
    for cut in cuts {
        parts.append(from..<cut)
        from = cut + 1
    }
    parts.append(from..<end)
    if parts.count > 1, trimmedEnd(t, parts[0]) == parts[0].lowerBound { parts.removeFirst() }
    if parts.count > 1, trimmedEnd(t, parts[parts.count - 1]) == parts[parts.count - 1].lowerBound { parts.removeLast() }
    return parts
}

/// The alignments of a table of `cells` columns where `line` delimits one:
/// the same number of cells, each an optional `:`, at least three `-` and
/// an optional `:`. A trailing colon alone sets words at the right, both
/// in the centre, anything else at the left.
private func delimiter(_ t: [Unicode.Scalar], _ line: Range<Int>, cells count: Int) -> [ColumnAlign]? {
    let parts = cells(t, line)
    guard parts.count == count else { return nil }
    var align: [ColumnAlign] = []
    for part in parts {
        var start = part.lowerBound
        var end = part.upperBound
        while start < end, isSpace(t[start]) { start += 1 }
        while end > start, isSpace(t[end - 1]) { end -= 1 }
        var left = false
        var right = false
        if start < end, t[start] == ":" {
            left = true
            start += 1
        }
        if end > start, t[end - 1] == ":" {
            right = true
            end -= 1
        }
        guard end - start >= 3, t[start..<end].allSatisfy({ $0 == "-" }) else { return nil }
        align.append(right ? (left ? .center : .right) : .left)
    }
    return align
}

/// One cell's words: trimmed of the spaces at their ends, its `\|`s drawn
/// as `|`, and read as a line's are.
private func cell(_ t: [Unicode.Scalar], _ range: Range<Int>) -> TableCell {
    var start = range.lowerBound
    var end = range.upperBound
    while start < end, isSpace(t[start]) { start += 1 }
    while end > start, isSpace(t[end - 1]) { end -= 1 }
    var words: [Unicode.Scalar] = []
    words.reserveCapacity(end - start)
    var at = start
    while at < end {
        if t[at] == "\\", at + 1 < end, t[at + 1] == "|" {
            words.append("|")
            at += 2
            continue
        }
        words.append(t[at])
        at += 1
    }
    var out = Out()
    inline(&out, words, 0..<words.count, Marks())
    return TableCell(text: String(out.text), marks: out.marks, links: out.links)
}
