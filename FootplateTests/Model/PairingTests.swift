@testable import Footplate
import CoreImage
import UIKit
import XCTest

// What an approved pairing shows and what scanning it does (yardr-6maq
// 3.4): the QR is drawn from the yard's string as it stands, and reads
// back as that string; a phone that scans it pairs sealed, and the code
// crosses no request in the clear; and the words of the screen are the
// design's.

/// The text a QR picture holds, read back as a camera would read it.
func readQRPicture(_ picture: UIImage) -> String? {
    guard let image = CIImage(image: picture) else { return nil }
    let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    return (detector?.features(in: image).first as? CIQRCodeFeature)?.messageString
}

@MainActor
final class PairingTests: XCTestCase {
    private var channelKey: String {
        channelPublicString(Data(repeating: 0x2A, count: 32))
    }

    // The four shapes of the yard's PairingQR: the edge's address with the
    // yard, with and without its channel key, and a yard of its own's,
    // with its key after the empty yard's place.
    func testTheQRIsDrawnFromTheYardsStringAndReadsBackAsItStands() throws {
        let strings = [
            "https://my.yardr.dev#K7QM-2XPD#jo/south",
            "https://my.yardr.dev#K7QM-2XPD#jo/south#\(channelKey)",
            "https://mac.example.net#K7QM-2XPD",
            "https://mac.example.net#K7QM-2XPD##\(channelKey)",
        ]
        for text in strings {
            let picture = try XCTUnwrap(qrPicture(text), text)
            XCTAssertEqual(picture.size.width, picture.size.height, "a QR is square")
            XCTAssertEqual(readQRPicture(picture), text)
            // Black on white with its quiet zone: the corner is paper in
            // either theme, since the picture carries its own.
            let corner = try XCTUnwrap(pixel(of: picture, x: 1, y: 1))
            XCTAssertEqual(corner, [255, 255, 255], "a quiet zone of white: \(text)")
            // The screen scales it by whole steps or not at all, never
            // smoothing a module's edge: one that is shown at half size reads.
            let half = UIGraphicsImageRenderer(size: CGSize(width: picture.size.width / 2, height: picture.size.height / 2)).image { _ in
                picture.draw(in: CGRect(origin: .zero, size: CGSize(width: picture.size.width / 2, height: picture.size.height / 2)))
            }
            XCTAssertEqual(readQRPicture(half), text, "read at half size")
        }
        XCTAssertNil(qrPicture(""))
    }

    private func pixel(of picture: UIImage, x: Int, y: Int) -> [UInt8]? {
        guard let cg = picture.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let offset = y * cg.bytesPerRow + x * (cg.bitsPerPixel / 8)
        return [bytes[offset], bytes[offset + 1], bytes[offset + 2]]
    }

    // The loop the bead asks for, with no camera: a held phone approves the
    // pairing card and the yard answers the pairing it opened; the QR the
    // held phone would draw reads back as that string; the new phone reads
    // it as a scan does and pairs sealed, pinning the yard's channel key
    // from its fourth field. The code crosses no request in the clear, the
    // pairing is spent, and the same code is no pairing the second time.
    func testAPhoneThatScansWhatAnApprovalDrewPairsSealed() async throws {
        let fake = FakeYard()
        let key = fake.channelPublic(yardName: "laptop")
        let qr = "\(fake.origin)#M4TR-9KWE#laptop#\(key)"
        fake.nextFor(yard: "laptop", path: "/user/call/ApproveAsk", .json(200, Canned.pairingApproved(
            code: "M4TR-9KWE", address: fake.origin, expires: "2099-10-08T09:30:00Z", qr: qr, yard: "laptop", channelKey: key
        )))
        let held = try fake.edge().yard(device: fake.token(yardName: "laptop"), session: fake.session(), name: "laptop")
        let answered = try await held.approveAsk(bead: "yd-pair", ask: 65, actor: "jo", weighed: true)
        let pairing = try XCTUnwrap(answered)
        XCTAssertEqual(pairing.qr, qr)
        let drawn = try XCTUnwrap(qrPicture(pairing.qr))
        let scanned = try XCTUnwrap(readQRPicture(drawn))
        XCTAssertEqual(scanned, qr, "what is scanned is what the yard made")

        // The new phone, signed in at the edge.
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let nav = Nav()
        let pair = PairModel(pairer: pairer, records: records, nav: nav)
        pair.scanned(scanned)
        XCTAssertEqual(pair.state.step, .read(PairingCode(code: "M4TR-9KWE", yard: "laptop", channel: key)))
        await pair.pair()
        XCTAssertNil(pair.state.error)
        XCTAssertEqual(pair.state.step, .choose)
        let kept = try XCTUnwrap(records.kept.yards.first)
        XCTAssertEqual(kept.name, "laptop")
        XCTAssertEqual(kept.sealedHow, "paired")
        XCTAssertEqual(kept.yardChannelPublic.map(channelPublicString), key, "the yard's key is the one the QR held")
        XCTAssertNotNil(kept.channel)
        XCTAssertTrue(fake.requests(carrying: "M4TR").isEmpty, "the code crossed no request in the clear")
        XCTAssertTrue(fake.requests(carrying: "9KWE").isEmpty)
        XCTAssertFalse(fake.hasPairingOpen(yardName: "laptop"), "the code is spent")

        // A second phone with the same picture finds no pairing, in the
        // yard's words, and so does a held phone's End.
        let second = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        second.keepSession(account: fake.email, session: fake.session())
        let again = PairModel(pairer: Pairer(edge: try fake.edge(), records: second), records: second, nav: Nav())
        again.scanned(scanned)
        await again.pair()
        XCTAssertTrue(again.state.error?.hasPrefix("No pairing is open at this yard") == true, again.state.error ?? "")
        XCTAssertTrue(second.kept.yards.isEmpty)
        do {
            try await held.devicePairCloseSelf(user: "jo")
            XCTFail("End found a pairing to end after the code was spent")
        } catch {
            XCTAssertEqual(error as? ApiError, .refused(
                code: "not-found",
                message: "an open device pairing: not found (one lives in the server's memory, and ends with it)"
            ))
        }
    }

    // What the screen says, as the design and footplate have it: the door,
    // sealed or plain; the minutes, counted down by whole ones; what a
    // pairing card is, as the yard's own reading of it has it; and a screen
    // with no code.
    func testThePairingScreensWordsAreTheDesigns() {
        XCTAssertEqual(pairDoor(sealed: true), "Approving answers the pairing's code sealed to this phone: the edge carries it unread")
        XCTAssertEqual(
            pairDoor(sealed: false),
            "Approving shows the pairing's code on this screen: show it to the device and to nobody else, since whoever has it within its minutes, the carrier of this approval included, could spend it first"
        )

        let ends = parseInstant("2026-10-08T11:40:00Z")!
        let words: [(seconds: Double, said: String)] = [
            (600, "10 minutes left"), (599, "9 minutes left"), (120, "2 minutes left"), (119, "1 minute left"),
            (60, "1 minute left"), (59, "Less than a minute left"), (1, "Less than a minute left"),
            (0, "The code ran out"), (-30, "The code ran out"),
        ]
        for (seconds, said) in words {
            XCTAssertEqual(pairingLeft(expires: ends, now: ends.addingTimeInterval(-seconds)), said, "\(seconds) s left")
        }

        // As the yard's IsDevicePairRun reads a command: the first three
        // words, the user and the device; anything shorter or else is not.
        func run(_ argv: [String]) -> Run { Run(argv: argv) }
        XCTAssertTrue(isDevicePairRun(run(["user", "device", "pair", "jo", "watch"])))
        XCTAssertTrue(isDevicePairRun(run(["user", "device", "pair", "jo", "watch", "--url", "https://mac.example.net"])))
        XCTAssertFalse(isDevicePairRun(run(["user", "device", "pair", "jo"])))
        XCTAssertFalse(isDevicePairRun(run(["user", "device", "rm", "jo", "watch"])))
        XCTAssertFalse(isDevicePairRun(run(["user", "device", "pair", "--end"])))
        XCTAssertFalse(isDevicePairRun(run([])))

        XCTAssertEqual(pairingOverWords(.ended), "The pairing ended")
        XCTAssertEqual(pairingOverWords(.ranOut), "The code ran out")
        XCTAssertTrue(pairingOverWords(.unshown).hasPrefix("The yard opened the pairing, but its answer held no code"))
    }
}
