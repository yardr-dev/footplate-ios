import Foundation

// The web addresses in a card's words (design 3.5): the question and
// the context of a decision are the asker's, and the page a harness's
// login waits on is among them, as the line `Sign in on this page:
// <address>`. Each address in them is a link to itself, so what is shown
// is what opens, and tapping one hands it to the system's `openURL`, as
// the recovery link of the sign-in screen does. In mail, the bead ids
// of `beads` chip beside them: a tap opens the bead whole, and any other
// id-shaped word stays plain words, as does an id inside a link or a
// code span.

/// `text` with each web address in it a link to itself, and each id of
/// `beads` it names a chip opening the bead. Only an explicit `http://`
/// or `https://` address with a host is a link: not a bare host name, not
/// another scheme (`mailto:`, `tel:` and `javascript:` never), not an
/// address with a user name or password in it, the old disguise of
/// another host, and not one whose host is not ASCII, which reads as
/// another host than it shows. The punctuation of the sentence it stands
/// in is not part of it: a full stop, a comma, a closing quote, a bracket
/// the address did not open. An id chips only where `beads` holds it, the
/// app knowing it or the yard having confirmed it.
func linked(_ text: String, beads: Set<String> = []) -> AttributedString {
    let links = linkRanges(text)
    let tokens = beads.isEmpty ? [] : chipTokens(text, links: links, code: codeRanges(text), beads: beads)
    let cuts = (links.map { Cut(range: $0.range, url: $0.url) } + tokens.map { Cut(range: $0.range, url: $0.url) })
        .sorted { $0.range.lowerBound < $1.range.lowerBound }
    var out = AttributedString()
    var rest = text.startIndex
    for cut in cuts {
        out += AttributedString(String(text[rest..<cut.range.lowerBound]))
        var run = AttributedString(String(text[cut.range]))
        run.link = cut.url
        out += run
        rest = cut.range.upperBound
    }
    out += AttributedString(String(text[rest...]))
    return out
}

/// The bead ids `text` names, each once, in the order they stand: the
/// id-shaped words outside its links and its code spans. The conversation
/// asks the yard about those the app does not know, once each.
func beadIds(_ text: String) -> [String] {
    let links = linkRanges(text).map(\.range)
    let code = codeRanges(text)
    var seen: [String] = []
    for token in beadTokens(text) {
        if links.contains(where: { overlaps($0, token.range) }) { continue }
        if code.contains(where: { overlaps($0, token.range) }) { continue }
        if !seen.contains(token.id) { seen.append(token.id) }
    }
    return seen
}

/// One accepted link: where it stands and where it goes.
private struct FoundLink {
    var range: Range<String.Index>
    var url: URL
}

/// The links `text` holds, as `linked` cuts them: only http and https
/// addresses with a host, without the sentence's punctuation after them.
private func linkRanges(_ text: String) -> [FoundLink] {
    var out: [FoundLink] = []
    for match in text.matches(of: #/(?i)https?://[^\s<>"]+/#) {
        let address = withoutPunctuation(match.output)
        guard let url = web(String(address)) else { continue }
        out.append(FoundLink(range: address.startIndex..<address.endIndex, url: url))
    }
    return out
}

/// One run of `text` a tap opens: a link or a chip.
private struct Cut {
    var range: Range<String.Index>
    var url: URL
}

/// One id-shaped word chipped: the id, where it stands, and the link its
/// tap opens the bead through.
private struct ChipToken {
    var id: String
    var range: Range<String.Index>
    var url: URL
}

/// The ids of `beads` the tokens of `text` name outside its `links` and
/// its `code`, each where it stands. The links and the tokens never meet,
/// so the cuts stand in one order.
private func chipTokens(
    _ text: String,
    links: [FoundLink],
    code: [Range<String.Index>],
    beads: Set<String>
) -> [ChipToken] {
    var out: [ChipToken] = []
    for token in beadTokens(text) {
        guard beads.contains(token.id) else { continue }
        if links.contains(where: { overlaps($0.range, token.range) }) { continue }
        if code.contains(where: { overlaps($0, token.range) }) { continue }
        guard let url = beadURL(token.id) else { continue }
        out.append(ChipToken(id: token.id, range: token.range, url: url))
    }
    return out
}

/// Whether `range` stands inside `other` at any character.
private func overlaps(_ range: Range<String.Index>, _ other: Range<String.Index>) -> Bool {
    range.lowerBound < other.upperBound && other.lowerBound < range.upperBound
}

/// A chip's link: the bead's id under the app's own scheme, so a tap
/// opens the bead whole. Never opened by the system.
func beadURL(_ id: String) -> URL? {
    URL(string: "\(beadScheme):\(id)")
}

/// The bead id a chip's link names; nil for a link that is none.
func chippedBead(_ url: URL) -> String? {
    guard url.scheme == beadScheme else { return nil }
    let id = url.absoluteString.dropFirst(beadScheme.count + 1)
    return id.isEmpty ? nil : String(id)
}

private let beadScheme = "footplate-bead"

/// One id-shaped word: the id and where it stands.
private struct BeadToken {
    var id: String
    var range: Range<String.Index>
}

/// The id-shaped words standing in `text`, each where it stands, in the
/// order they stand.
private func beadTokens(_ text: String) -> [BeadToken] {
    var out: [BeadToken] = []
    var at = text.startIndex
    while at < text.endIndex {
        let starts = at == text.startIndex || !isBeadByte(text[text.index(before: at)])
        if starts, let token = beadToken(text, at: at) {
            at = token.range.upperBound
            out.append(token)
        } else {
            at = text.index(after: at)
        }
    }
    return out
}

/// A bead id at `at`: its own characters with one `@peer` at most,
/// without what closes the sentence after it. None where no bead id
/// starts here: one has a dash, and neither it nor its peer is empty. As
/// footplate's `bead_token` has it; bare suffixes are no id.
private func beadToken(_ text: String, at: String.Index) -> BeadToken? {
    guard at < text.endIndex, isAsciiIdStart(text[at]) else { return nil }
    var end = at
    while end < text.endIndex, isBeadByte(text[end]) { end = text.index(after: end) }
    var token = text[at..<end]
    while let last = token.last, last == "." || last == "-" || last == "@" { token = token.dropLast() }
    guard !token.isEmpty else { return nil }
    let split = token.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let peer = split.count > 1 ? split[1] : nil
    if let peer, peer.isEmpty || peer.contains("@") { return nil }
    let head = split[0]
    if !head.contains("-") || head.hasPrefix("-") || head.hasPrefix(".") { return nil }
    return BeadToken(id: String(token), range: at..<token.endIndex)
}

/// Whether the character may stand inside a bead id: an id's own
/// characters with the `@` of another yard's.
private func isBeadByte(_ byte: Character) -> Bool {
    byte.isASCII && (byte.isLetter || byte.isNumber || byte == "." || byte == "_" || byte == "-" || byte == "@")
}

private func isAsciiIdStart(_ byte: Character) -> Bool {
    byte.isASCII && (byte.isLetter || byte.isNumber)
}

/// Where the code stands: the fenced blocks and the inline spans. An
/// unclosed fence or backtick opens none.
private func codeRanges(_ text: String) -> [Range<String.Index>] {
    fenceRanges(text) + spanRanges(text)
}

/// The fenced code blocks, each from its opening fence through its
/// closing one: three backticks at a line's start open and shut.
private func fenceRanges(_ text: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var open: String.Index? = nil
    var index = text.startIndex
    while index < text.endIndex {
        let end = text[index...].firstIndex(of: "\n") ?? text.endIndex
        if text[index..<end].hasPrefix("```") {
            if let start = open {
                ranges.append(start..<text.index(index, offsetBy: 3))
                open = nil
            } else {
                open = index
            }
        }
        index = end == text.endIndex ? end : text.index(after: end)
    }
    return ranges
}

/// The inline code spans: one pair of backticks on one line, with
/// something between.
private func spanRanges(_ text: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var index = text.startIndex
    while let open = text[index...].firstIndex(of: "`") {
        let after = text.index(after: open)
        var close = after
        var shut: String.Index? = nil
        while close < text.endIndex, text[close] != "\n" {
            if text[close] == "`" {
                if close > after { shut = close }
                break
            }
            close = text.index(after: close)
        }
        if let shut {
            ranges.append(open..<text.index(after: shut))
            index = text.index(after: shut)
        } else {
            index = after
        }
    }
    return ranges
}

/// `address` without the punctuation that ends the sentence around it.
/// A closing bracket stays where the address opened one before it, as in
/// `/wiki/Foo_(bar)`.
private func withoutPunctuation(_ address: Substring) -> Substring {
    let opening: [Character: Character] = [")": "(", "]": "[", "}": "{"]
    var end = address.endIndex
    while end > address.startIndex {
        let kept = address[..<end]
        let last = kept[kept.index(before: end)]
        if let opener = opening[last] {
            if kept.filter({ $0 == opener }).count >= kept.filter({ $0 == last }).count { break }
        } else if !".,;:!?'".contains(last) {
            break
        }
        end = kept.index(before: end)
    }
    return address[..<end]
}

/// The address as a URL where it is one the person may be sent to.
private func web(_ address: String) -> URL? {
    guard let parts = URLComponents(string: address),
          let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = parts.host, !host.isEmpty, host.allSatisfy(\.isASCII),
          parts.user == nil, parts.password == nil
    else { return nil }
    return parts.url
}
