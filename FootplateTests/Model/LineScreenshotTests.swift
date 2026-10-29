@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The lines place rendered in the simulator against a fake-followed
// board (design 3.5, the bead's screenshot): the overview unfiltered
// and with one stat filtering it, a bead's card with its details,
// while they are read and when the read is refused, and a route map
// with its landings under the landed station. Hand-run for the
// bead note; the gate runs it too, and it only asserts that the screens
// render non-empty at phone size. The PNGs land in `LINE_SHOTS_DIR`, or
// the temporary directory's `line-shots` where that names none.
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

        let conversation = ConversationModel(mailroom: mailroom, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        let line = LineModel(
            followers: { ["": home, "laptop": laptop] }, records: records, pairer: pairer, nav: nav,
            conversation: conversation, origins: { _ in fake.origin }, now: { now },
            zone: { TimeZone(secondsFromGMT: 0)! }
        )
        home.beads["yd-train"] = trainBead()
        line.open(yard: "")
        let deadline = ContinuousClock.now + .seconds(10)
        while !line.state.read, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(line.state.read)
        XCTAssertEqual(line.state.depots.map(\.name), ["yard", "drafts"])
        XCTAssertEqual(line.state.lines.map(\.title), ["yard · default"])

        let dir = ProcessInfo.processInfo.environment["LINE_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("line-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await render(LinesScreen(inbox: inbox, records: records, model: line, nav: nav), scene: scene, to: dir.appendingPathComponent("line.png"))
        // One stat filtering: the yard's card with its moving bead alone.
        line.filter(.moving)
        XCTAssertEqual(line.state.lines.map(\.title), ["yard · default"])
        XCTAssertEqual(line.state.lines[0].beads, ["yd-train"])
        try await render(LinesScreen(inbox: inbox, records: records, model: line, nav: nav), scene: scene, to: dir.appendingPathComponent("line-filtered.png"))
        // A bead's card: the board's facts, then what the Bead call gave.
        // The screens above left the place as they went; it is shown again.
        line.filter(.all)
        line.open(yard: "")
        let route = BeadRoute(yard: "", bead: "yd-train")
        line.openBead("yd-train")
        let detailsDeadline = ContinuousClock.now + .seconds(10)
        while line.card(for: route)?.details.read != true, ContinuousClock.now <= detailsDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let card = try XCTUnwrap(line.card(for: route))
        XCTAssertTrue(card.details.read)
        XCTAssertEqual(card.details.notes.map(\.author), ["mckean", "yardmaster", "train-new"])
        try await render(NavigationStack { BeadCardScreen(model: line, route: route) }, scene: scene, to: dir.appendingPathComponent("bead-card.png"))
        // The card of a bead still being read keeps the board's facts and
        // says it is reading; one whose read is refused says so, whole.
        let shed = BeadRoute(yard: "", bead: "yd-shed")
        home.holdBeadReads("yd-shed", count: 1)
        line.openBead("yd-shed")
        while home.pendingBeadReadCount("yd-shed") == 0, ContinuousClock.now <= detailsDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(line.card(for: shed)?.details.loading, true)
        try await render(NavigationStack { BeadCardScreen(model: line, route: shed) }, scene: scene, to: dir.appendingPathComponent("bead-card-reading.png"))
        home.releaseBeadRead("yd-shed")
        let seal = BeadRoute(yard: "", bead: "yd-seal")
        home.beadRefuse = .away
        line.openBead("yd-seal")
        while line.card(for: seal)?.details.error == nil, ContinuousClock.now <= detailsDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(line.card(for: seal)?.details.error, "Details not read: The yard is away: the edge cannot reach it.")
        try await render(NavigationStack { BeadCardScreen(model: line, route: seal) }, scene: scene, to: dir.appendingPathComponent("bead-card-refused.png"))
        // A route map with its landings under the landed station. The
        // canned drafts line already ends in one; it is served two
        // landings here, newest first.
        var landed = try cannedBoard()
        landed.depots[1].flows[0].landings = [
            FlowLanding(bead: "yd-points", title: "Oil the points", landedAt: "2026-10-08T11:41:00Z"),
            FlowLanding(bead: "yd-ballast", title: "Lay the ballast", landedAt: "2026-10-08T09:30:00Z"),
        ]
        home.board = landed
        await line.refresh()
        let landedRoute = LineRoute(yard: "", depot: "drafts", flow: "default")
        let landedMap = try XCTUnwrap(line.routeMap(for: landedRoute))
        XCTAssertEqual(landedMap.stations.map(\.name), ["new", "shipped"])
        XCTAssertEqual(landedMap.stations[1].landings.map(\.ago), ["19m ago", "2h ago"])
        line.openLine(depot: "drafts", flow: "default")
        try await render(NavigationStack { RouteMapScreen(model: line, route: landedRoute) }, scene: scene, to: dir.appendingPathComponent("route-map-landings.png"))
        line.leave()
    }

    /// What the fake yard answers for the train: labels, a body with a
    /// link, and three notes.
    private func trainBead() -> Bead {
        Bead(
            id: "yd-train", title: "Release train",
            body: "The release train leaves nightly with what is green.\nSee https://example.com/train for the timetable.",
            stage: "new",
            labels: ["topic:trains", "kind:feat", "size:medium"],
            notes: [
                BeadNote(seq: 2, kind: "note", author: "mckean", text: "Keep the night run; the day run can wait.", at: "2026-10-07T16:20:00Z"),
                BeadNote(seq: 5, kind: "note", author: "yardmaster", text: "Plan: read the timetable, then move the departure to 02:00.", at: "2026-10-08T09:45:00Z"),
                BeadNote(seq: 6, kind: "note", author: "train-new", text: "Moved. test: sh .yardr/test @ a1b2c3d: pass, 226 ok, 0 failed", at: "2026-10-08T11:20:00Z"),
            ]
        )
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
        // The screen's onDisappear lands before the next step reads the
        // model it left.
        try await Task.sleep(for: .milliseconds(200))
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
