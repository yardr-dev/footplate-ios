@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The pair screen rendered in the simulator (the bead's screenshot):
// Type the code with Use your own address open. Hand-run for the bead
// note; the gate runs it too, and it only asserts that the screen
// renders non-empty at phone size. The PNG lands in
// `TEST_RUNNER_PAIR_SHOTS_DIR`, or the temporary directory's `pair-shots`
// where that names none.
@MainActor
final class PairScreenshotTests: XCTestCase {
    func testPairOwnAddressRenders() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        let nav = Nav()
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let pair = PairModel(pairer: pairer, records: records, nav: nav)
        pair.typeCode()
        pair.addressed("https://yard.example.net")
        pair.typed(yard: "", code: "K7QM-2XPD")
        XCTAssertEqual(pair.state.step, .typing(yard: "", code: "K7QM-2XPD", address: "https://yard.example.net"))

        let dir = ProcessInfo.processInfo.environment["PAIR_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pair-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await render(PairScreen(model: pair), scene: scene, to: dir.appendingPathComponent("pair-own-address.png"))
    }

    // The Pair screen as a phone with a camera shows it: Scan and Type the
    // code; what a scan of the QR a held phone draws reads as (the camera's
    // own view cannot run in a simulator, so the scan is handed the text
    // the camera would read); and a code the yard refuses, in its words,
    // first a wrong one and then one whose pairing is no more.
    func testPairScanAndRefusedCodeRender() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        let nav = Nav()
        let pair = PairModel(pairer: Pairer(edge: try fake.edge(), records: records), records: records, nav: nav)
        let dir = ProcessInfo.processInfo.environment["PAIR_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pair-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try await render(PairScreen(model: pair, scannerAvailable: true), scene: scene, to: dir.appendingPathComponent("pair-scan.png"))

        // What a scan of a held phone's QR reads: the edge's address, the
        // code and the yard, with the yard's channel key as its fourth field.
        let key = fake.channelPublic(yardName: "laptop")
        pair.scanned("\(fake.origin)#M4TR-9KWE#laptop#\(key)")
        XCTAssertEqual(pair.state.step, .read(PairingCode(code: "M4TR-9KWE", yard: "laptop", channel: key)))
        try await render(PairScreen(model: pair, scannerAvailable: true), scene: scene, to: dir.appendingPathComponent("pair-scan-read.png"))

        // A wrong code is refused in the yard's words.
        pair.scanned("\(fake.origin)#AAAA-BBBB#laptop#\(key)")
        await pair.pair()
        XCTAssertEqual(pair.state.error, pairingRefused("wrong_code").message)
        try await render(PairScreen(model: pair, scannerAvailable: true), scene: scene, to: dir.appendingPathComponent("pair-refused.png"))

        // And so is the right one once the pairing is gone: used, ended or
        // the fifth wrong code.
        fake.openPairing(yardName: "laptop", code: "M4TR-9KWE")
        for _ in 1...5 {
            pair.scanned("\(fake.origin)#AAAA-BBBB#laptop#\(key)")
            await pair.pair()
        }
        pair.scanned("\(fake.origin)#M4TR-9KWE#laptop#\(key)")
        await pair.pair()
        XCTAssertEqual(pair.state.error, pairingRefused("no_pairing").message)
        try await render(PairScreen(model: pair, scannerAvailable: true), scene: scene, to: dir.appendingPathComponent("pair-refused-ended.png"))
    }

    private func render(_ view: some View, scene: UIWindowScene, to file: URL) async throws {
        let hosting = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(700))
        hosting.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            hosting.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData(), "the rendered screen has no PNG")
        XCTAssertEqual(image.size, CGSize(width: 402, height: 874))
        try png.write(to: file)
        XCTAssertGreaterThan(png.count, 10000, "the rendered screen looks blank")
        window.isHidden = true
    }
}
