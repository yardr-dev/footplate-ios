@testable import Footplate
import XCTest

// The QR's text read as design 3.2 says, before anything is sent:
// yardr's pairQR, <address>#<code> or <address>#<code>#<yard>, the
// edge's address checked against the build's edge and never used, and
// a yard's own address where the code goes, with no edge.
final class CodeTests: XCTestCase {
    private let edge = "https://my.yardr.dev"

    private func code(_ code: String, _ yard: String = "", _ address: String = "", typed: Bool = false) -> CodeRead {
        .code(PairingCode(code: code, yard: yard, address: address, typed: typed))
    }

    private let noAddress = "That is no address: https://yard.example.net, the scheme, the host and the port alone."
    private let plainHttp = "That address is plain http: anyone on the way could read the code and the token. Give the yard's https address."
    private let noMemberYard = "That is no yard's name: another account's yard is its owner's handle, a slash and the yard's name."

    func testAQRReadsAsTheCodeAndTheYard() {
        let rows: [(String, CodeRead)] = [
            // Two parts: the account's own yard.
            ("https://my.yardr.dev#K7QM-2XPD", code("K7QM-2XPD")),
            // Three parts: the yard's name at the edge.
            ("https://my.yardr.dev#K7QM-2XPD#laptop", code("K7QM-2XPD", "laptop")),
            // The code without its dash, in small letters, I L O as digits.
            ("https://my.yardr.dev#k7qm2xpd#laptop", code("K7QM-2XPD", "laptop")),
            ("https://my.yardr.dev#1L0O-2XPD", code("1100-2XPD")),
            // The address as yardr prints it, with or without its slash.
            ("https://my.yardr.dev/#K7QM-2XPD", code("K7QM-2XPD")),
            ("  https://MY.yardr.dev:443#K7QM-2XPD#laptop \n", code("K7QM-2XPD", "laptop")),
            // A yard of another account the account is a member of: its
            // owner's handle and its name, as the edge names it.
            ("https://my.yardr.dev#R2VH-6NQD#alice/lab", code("R2VH-6NQD", "alice/lab")),
            // A yard's own address, as `yardr user device pair --url`
            // shows it: the code goes there, with no edge.
            ("https://yard.example.net#K7QM-2XPD", code("K7QM-2XPD", "", "https://yard.example.net")),
            ("https://yard.example.net/#k7qm2xpd", code("K7QM-2XPD", "", "https://yard.example.net")),
            ("https://YARD.EXAMPLE.NET:443#K7QM-2XPD", code("K7QM-2XPD", "", "https://yard.example.net")),
            ("https://yard.example.net:8443#K7QM-2XPD", code("K7QM-2XPD", "", "https://yard.example.net:8443")),
            ("https://my.yardr.dev:8443#K7QM-2XPD", code("K7QM-2XPD", "", "https://my.yardr.dev:8443")),
        ]
        for (text, want) in rows {
            XCTAssertEqual(readQr(text, edge: edge), want, text)
        }
    }

    func testAnOwnAddressReadsAsAnHttpsOrigin() {
        let rows: [(String, AddressRead)] = [
            ("https://yard.example.net", .address(origin: "https://yard.example.net")),
            ("  https://yard.example.net/ \n", .address(origin: "https://yard.example.net")),
            ("https://YARD.EXAMPLE.NET:443/", .address(origin: "https://yard.example.net")),
            ("https://yard.example.net:8443", .address(origin: "https://yard.example.net:8443")),
            ("http://yard.example.net", .refused(why: plainHttp)),
            ("HTTP://yard.example.net/", .refused(why: plainHttp)),
            ("", .refused(why: noAddress)),
            ("yard.example.net", .refused(why: noAddress)),
            ("https://yard.example.net/kratos", .refused(why: noAddress)),
            ("https://yard.example.net/?x=1", .refused(why: noAddress)),
            ("https://yard.example.net#frag", .refused(why: noAddress)),
            ("https://me@yard.example.net", .refused(why: noAddress)),
            ("ftp://yard.example.net", .refused(why: noAddress)),
        ]
        for (text, want) in rows {
            XCTAssertEqual(readOwnAddress(text), want, text)
        }
    }

    func testAYardOfItsOwnIsNamedByItsAddress() {
        // Made of the origin `readOwnAddress` makes, so every spelling
        // of one address is one name: the host, and the port where it
        // is not 443.
        let rows: [(String, String)] = [
            ("https://yard.example.net", "yard.example.net"),
            ("  https://yard.example.net/ \n", "yard.example.net"),
            ("https://YARD.EXAMPLE.NET:443/", "yard.example.net"),
            ("https://yard.example.net:8446", "yard.example.net:8446"),
            ("https://workshop-mini.tail1a2b3c.ts.net:8446", "workshop-mini.tail1a2b3c.ts.net:8446"),
            // A host's colons would read as a port without its brackets.
            ("https://[::1]:8446", "[::1]:8446"),
            ("https://[FE80::1]", "[fe80::1]"),
        ]
        for (text, want) in rows {
            guard case .address(let origin) = readOwnAddress(text) else {
                XCTFail("\(text) is no address")
                continue
            }
            XCTAssertEqual(ownName(origin), want, text)
        }
        // Two ports, two yards; the name of none is the account's own.
        XCTAssertNotEqual(ownName("https://yard.example.net:8446"), ownName("https://yard.example.net:8447"))
        XCTAssertEqual(ownName(""), "")
        XCTAssertEqual(ownName("not an origin"), "")
    }

    func testWhatIsNotThisEdgesCodeIsRefusedWithItsReason() {
        let rows: [(String, String)] = [
            // Four parts, and one part alone.
            // A fourth field that is no channel key: the shape is
            // a pairing's now, and the key is what is wrong.
            ("https://my.yardr.dev#K7QM-2XPD#laptop#more", "That is not a pairing's code: its channel key cannot be read."),
            ("https://my.yardr.dev#K7QM-2XPD#laptop#more#even-more", "That is not a pairing's code: yardr user device pair --qr draws one."),
            // Another account's yard has its owner's handle and its name,
            // no part missing and no third.
            ("https://my.yardr.dev#R2VH-6NQD#alice/", noMemberYard),
            ("https://my.yardr.dev#R2VH-6NQD#/lab", noMemberYard),
            ("https://my.yardr.dev#R2VH-6NQD#alice/lab/more", noMemberYard),
            ("K7QM-2XPD", "That is not a pairing's code: yardr user device pair --qr draws one."),
            // A yard's own address with a yard's name: a direct pairing
            // takes none.
            ("https://other.example#K7QM-2XPD#laptop", "This code is for https://other.example and names a yard: a yard's own address pairs with no yard's name."),
            // An address that is neither the edge's nor a yard's own.
            ("http://my.yardr.dev#K7QM-2XPD", plainHttp),
            ("https://my.yardr.dev/kratos#K7QM-2XPD", noAddress),
            ("https://me@my.yardr.dev#K7QM-2XPD", noAddress),
            // Not eight of the code's letters and digits, at either
            // address.
            ("https://my.yardr.dev#K7QM-2XP", "That is no code: a code is eight letters and digits, as the yard printed them."),
            ("https://my.yardr.dev#K7QM-2XPU", "That is no code: a code is eight letters and digits, as the yard printed them."),
            ("https://yard.example.net#K7QM-2XP", "That is no code: a code is eight letters and digits, as the yard printed them."),
        ]
        for (text, why) in rows {
            XCTAssertEqual(readQr(text, edge: edge), .refused(why: why), text)
        }
    }

    func testATypedCodeIsReadWithOrWithoutItsDash() {
        XCTAssertEqual(typedCode(yard: "", code: "K7QM-2XPD"), code("K7QM-2XPD", typed: true))
        XCTAssertEqual(typedCode(yard: " laptop ", code: "k7qm2xpd"), code("K7QM-2XPD", "laptop", typed: true))
        XCTAssertEqual(typedCode(yard: "", code: "K7QM 2XPD"), code("K7QM-2XPD", typed: true))
        XCTAssertEqual(typedCode(yard: " alice/lab ", code: "r2vh6nqd"), code("R2VH-6NQD", "alice/lab", typed: true))
        XCTAssertEqual(typedCode(yard: "alice/", code: "R2VH-6NQD"), .refused(why: noMemberYard))
        XCTAssertEqual(memberYard("alice/lab")?.owner, "alice")
        XCTAssertEqual(memberYard("alice/lab")?.yard, "lab")
        XCTAssertNil(memberYard("lab"))
        XCTAssertNil(memberYard("yard.example.net:8446"))
        XCTAssertEqual(
            typedCode(yard: "", code: "https://other.example#K7QM-2XPD"),
            .refused(why: "That is no code: a code is eight letters and digits, as the yard printed them.")
        )
        XCTAssertEqual(
            typedCode(yard: "lap top", code: "K7QM-2XPD"),
            .refused(why: "That is no yard's name: the name is one word, as the yard printed it.")
        )
    }
}

extension CodeTests {
    /// A channel public key as a QR's fourth field carries it:
    /// 32 bytes, base64url, no padding.
    private var channelKey: String {
        channelPublicString(Data(repeating: 0x2A, count: 32))
    }

    func testAQRWithAChannelKeyReadsItAndOneWithoutReadsNone() {
        XCTAssertEqual(
            readQr("https://my.yardr.dev#K7QM-2XPD#laptop#\(channelKey)", edge: edge),
            .code(PairingCode(code: "K7QM-2XPD", yard: "laptop", channel: channelKey))
        )
        // The account's own yard: the name's place stands empty.
        XCTAssertEqual(
            readQr("https://my.yardr.dev#K7QM-2XPD##\(channelKey)", edge: edge),
            .code(PairingCode(code: "K7QM-2XPD", yard: "", channel: channelKey))
        )
        // A yard of its own: the key follows the code the same way.
        XCTAssertEqual(
            readQr("https://yard.example.net#K7QM-2XPD##\(channelKey)", edge: edge),
            .code(PairingCode(code: "K7QM-2XPD", yard: "", address: "https://yard.example.net", channel: channelKey))
        )
        // No fourth field: no channel, exactly as before.
        XCTAssertEqual(
            readQr("https://my.yardr.dev#K7QM-2XPD#laptop", edge: edge),
            .code(PairingCode(code: "K7QM-2XPD", yard: "laptop"))
        )
    }

    func testAQRWithAChannelKeyThatIsNoneIsRefused() {
        XCTAssertEqual(
            readQr("https://my.yardr.dev#K7QM-2XPD#laptop#not-a-key", edge: edge),
            .refused(why: "That is not a pairing's code: its channel key cannot be read.")
        )
        XCTAssertEqual(
            readQr("https://my.yardr.dev#K7QM-2XPD#laptop#\(channelKey)#extra", edge: edge),
            .refused(why: "That is not a pairing's code: yardr user device pair --qr draws one.")
        )
    }
}
