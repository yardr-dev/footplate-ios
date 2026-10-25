@testable import Footplate
import XCTest

// The QR's text read as design 3.2 says, before anything is sent:
// yardr's pairQR, <address>#<code> or <address>#<code>#<yard>, the
// address checked against the build's edge and never used.
final class CodeTests: XCTestCase {
    private let edge = "https://my.yardr.dev"

    private func code(_ code: String, _ yard: String = "") -> CodeRead {
        .code(PairingCode(code: code, yard: yard))
    }

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
        ]
        for (text, want) in rows {
            XCTAssertEqual(readQr(text, edge: edge), want, text)
        }
    }

    func testWhatIsNotThisEdgesCodeIsRefusedWithItsReason() {
        let other = "This code is for https://other.example. footplate speaks to https://my.yardr.dev alone."
        let rows: [(String, String)] = [
            // Four parts, and one part alone.
            ("https://my.yardr.dev#K7QM-2XPD#laptop#more", "That is not a pairing's code: yardr user device pair --qr draws one."),
            ("K7QM-2XPD", "That is not a pairing's code: yardr user device pair --qr draws one."),
            // Another address: http, another host, another port, a path, a user.
            ("http://my.yardr.dev#K7QM-2XPD", "This code is for http://my.yardr.dev. footplate speaks to https://my.yardr.dev alone."),
            ("https://other.example#K7QM-2XPD#laptop", other),
            ("https://other.example/#K7QM-2XPD", other),
            ("https://my.yardr.dev:8443#K7QM-2XPD", "This code is for https://my.yardr.dev:8443. footplate speaks to https://my.yardr.dev alone."),
            ("https://my.yardr.dev/kratos#K7QM-2XPD", "This code is for https://my.yardr.dev/kratos. footplate speaks to https://my.yardr.dev alone."),
            ("https://me@my.yardr.dev#K7QM-2XPD", "This code is for https://me@my.yardr.dev. footplate speaks to https://my.yardr.dev alone."),
            // Not eight of the code's letters and digits.
            ("https://my.yardr.dev#K7QM-2XP", "That is no code: a code is eight letters and digits, as the yard printed them."),
            ("https://my.yardr.dev#K7QM-2XPU", "That is no code: a code is eight letters and digits, as the yard printed them."),
        ]
        for (text, why) in rows {
            XCTAssertEqual(readQr(text, edge: edge), .refused(why: why), text)
        }
    }

    func testATypedCodeIsReadWithOrWithoutItsDash() {
        XCTAssertEqual(typedCode(yard: "", code: "K7QM-2XPD"), code("K7QM-2XPD"))
        XCTAssertEqual(typedCode(yard: " laptop ", code: "k7qm2xpd"), code("K7QM-2XPD", "laptop"))
        XCTAssertEqual(typedCode(yard: "", code: "K7QM 2XPD"), code("K7QM-2XPD"))
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
