@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The lines place rendered in the simulator against a fake-followed
// board (design 3.5, the bead's screenshot): the line with two depots.
// Hand-run for the bead note; the gate runs it too, and it only asserts
// that the screen renders non-empty at phone size. The PNG lands in
// `LINE_SHOTS_DIR`, or the temporary directory's `line-shots` where that
// names none.
@MainActor
final class LineScreenshotTests: XCTestCase {
    func testLineScreenRenders() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let fake = FakeYard()
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let records = Records(secret: secret, plain: plain, origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: "yardr-dev-laptop-1"))
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        records.noteNotificationsAsked()
        records.select("")
        let nav = Nav(place: .lines)
        let home = FakeFollowed()
        let laptop = FakeFollowed()
        let mailroom = Mailroom()
        mailroom.setFollowers(["": home, "laptop": laptop])
        let now = parseInstant("2026-10-08T12:00:00Z")!
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let inbox = InboxModel(
            pairer: pairer, records: records,
            followers: { ["": home, "laptop": laptop] },
            mailroom: mailroom, nav: nav,
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        home.up(loaded())
        laptop.state.status = .down(words: "The yard is away: the edge cannot reach it.", short: "yard away")
        home.board = try cannedBoard()

        let line = LineModel(followers: { ["": home, "laptop": laptop] })
        line.open(yard: "")
        let deadline = ContinuousClock.now + .seconds(10)
        while !line.state.read, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(line.state.read)
        XCTAssertEqual(line.state.depots.map(\.name), ["yard", "drafts"])

        let dir = ProcessInfo.processInfo.environment["LINE_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("line-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await render(LinesScreen(inbox: inbox, records: records, model: line), scene: scene, to: dir.appendingPathComponent("line.png"))
        line.leave()
    }

    /// The fake yard's board, as Canned serves it: two depots.
    private func cannedBoard() throws -> Flows {
        struct Result: Decodable {
            var result: Flows
        }
        let canned = try XCTUnwrap(Canned.replies["Flows"])
        return try JSONDecoder().decode(Result.self, from: Data(canned.utf8)).result
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

    private func loaded() -> Loaded {
        Loaded(
            me: Me(user: "jo", saidBy: "phone", yard: "south"),
            head: 151,
            settings: Settings(),
            user: User(name: "jo", cursor: 12, notificationCursor: 10),
            crew: [
                CrewMember(name: "yardmaster", enabled: true, state: "running", status: "working", loginScreen: false),
            ],
            users: [User(name: "jo")],
            inbox: Inbox(),
            notifications: Notifications(),
            asks: Asks(open: [
                OpenAsk(bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster"),
                OpenAsk(bead: "yd-map", ask: 7, question: "Who is U024BE7LH?", asker: "yardmaster"),
            ], decided: [])
        )
    }
}
