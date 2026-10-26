import Foundation

// The web addresses in a card's words (design 3.5): the question and
// the context of a decision are the asker's, and the page a harness's
// login waits on is among them, as the line `Sign in on this page:
// <address>`. Each address in them is a link to itself, so what is shown
// is what opens, and tapping one hands it to the system's `openURL`, as
// the recovery link of the sign-in screen does.

/// `text` with each web address in it a link to itself. Only an
/// explicit `http://` or `https://` address with a host is one: not a
/// bare host name, not another scheme (`mailto:`, `tel:` and
/// `javascript:` never), not an address with a user name or password in
/// it, the old disguise of another host, and not one whose host is not
/// ASCII, which reads as another host than it shows. The punctuation of
/// the sentence it stands in is not part of it: a full stop, a comma, a
/// closing quote, a bracket the address did not open.
func linked(_ text: String) -> AttributedString {
    var out = AttributedString()
    var rest = text.startIndex
    for match in text.matches(of: #/(?i)https?://[^\s<>"]+/#) {
        let address = withoutPunctuation(match.output)
        guard let url = web(String(address)) else { continue }
        out += AttributedString(String(text[rest..<address.startIndex]))
        var link = AttributedString(String(address))
        link.link = url
        out += link
        rest = address.endIndex
    }
    out += AttributedString(String(text[rest...]))
    return out
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
