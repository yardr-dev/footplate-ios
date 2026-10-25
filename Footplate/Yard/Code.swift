import Foundation

// A pairing's code, read from what yardr's QR holds or from what was typed
// (design 3.2). The QR is yardr's, unchanged: <address>#<code>, or
// <address>#<code>#<yard>. The address is checked against the edge the
// app was built for and never used: the phone sends nothing anywhere but
// there.

/// A code to pair with: `code` as yardr shows it (`K7QM-2XPD`), `yard`
/// the yard's name at the edge, empty for the account's own.
struct PairingCode: Equatable, Sendable {
    var code: String
    var yard: String
}

/// What a scan or the typed fields read as.
enum CodeRead: Equatable, Sendable {
    case code(PairingCode)
    /// Not a code to pair with, and nothing is sent: `why` says so.
    case refused(why: String)
}

/// What a pairing's QR holds, read: split at `#` into at most three
/// parts, the address, the code and the yard's name at the edge. More
/// parts, an address that is not `edge` (another scheme, host or port:
/// `http://` is refused as another), or a code that is not eight letters
/// and digits, are refused with the reason.
func readQr(_ text: String, edge: String) -> CodeRead {
    let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: "#", omittingEmptySubsequences: false)
        .map(String.init)
    guard parts.count >= 2, parts.count <= 3 else {
        return .refused(why: "That is not a pairing's code: yardr user device pair --qr draws one.")
    }
    let address = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    guard sameEdge(address, edge: edge) else {
        let shown = address.hasSuffix("/") ? String(address.dropLast()) : address
        let home = edge.hasSuffix("/") ? String(edge.dropLast()) : edge
        return .refused(why: "This code is for \(shown). footplate speaks to \(home) alone.")
    }
    let yard = parts.count == 3 ? parts[2] : ""
    return typedCode(yard: yard, code: parts[1])
}

/// What **Type the code** reads: the yard's name at the edge (empty:
/// the account's own) and the code, with or without its dash.
func typedCode(yard: String, code: String) -> CodeRead {
    guard let clean = cleanCode(code) else {
        return .refused(why: "That is no code: a code is eight letters and digits, as the yard printed them.")
    }
    let name = yard.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty, !name.allSatisfy({ $0 >= "!" && $0 <= "~" && $0 != "#" }) {
        return .refused(why: "That is no yard's name: the name is one word, as the yard printed it.")
    }
    return .code(PairingCode(code: String(clean.prefix(4)) + "-" + String(clean.dropFirst(4)), yard: name))
}

/// The code as yardr's `pairing.CleanCode` reads it: no dash or space,
/// capitals, and I, L and O as the digits they look like; nil where it
/// is not then eight of the code's letters and digits.
func cleanCode(_ code: String) -> String? {
    let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        .uppercased()
        .filter { $0 != "-" && $0 != " " }
        .replacingOccurrences(of: "I", with: "1")
        .replacingOccurrences(of: "L", with: "1")
        .replacingOccurrences(of: "O", with: "0")
    guard clean.count == 8, clean.allSatisfy({ codeAlphabet.contains($0) }) else { return nil }
    return clean
}

/// What a code is written in: digits and capitals without I, L, O and U.
private let codeAlphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

/// Whether `address` names the same edge as `edge`: same scheme, host
/// and port, no user, no query, and no path but the root. Hosts compare
/// without case and a missing port is its scheme's.
private func sameEdge(_ address: String, edge: String) -> Bool {
    guard let url = URLComponents(string: address),
          let home = URLComponents(string: edge),
          let scheme = url.scheme?.lowercased(), scheme == home.scheme?.lowercased(),
          let host = url.host, !host.isEmpty,
          let homeHost = home.host, host.lowercased() == homeHost.lowercased(),
          url.user == nil, url.password == nil, url.query == nil,
          url.path.isEmpty || url.path == "/"
    else { return false }
    func port(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
    return port(url) == port(home)
}
