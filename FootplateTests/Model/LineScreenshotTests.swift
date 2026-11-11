@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The lines place rendered in the simulator against a fake-followed
// board (design 3.5, the bead's screenshot): the overview unfiltered
// and with one stat filtering it, a bead's card with its details,
// the card while the details are read and when the read is refused,
// a route map with its landings under the landed station, the
// Ask naming a renamed coordinator, the card of a bead whose note
// carries a picture and a page, and that of a bead with three pictures
// over two notes: its Media row, the Media grid and a picture opened full
// size. Hand-run for the
// bead note; the gate runs it too, and it only asserts that the screens
// render non-empty at phone size. The PNGs land in
// `TEST_RUNNER_LINE_SHOTS_DIR`, or the temporary directory's `line-shots`
// where that names none.
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
        // The pictures of the notes lie in a folder of their own, taken
        // away with the test.
        let picturesDir = FileManager.default.temporaryDirectory.appendingPathComponent("note-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: picturesDir) }
        let line = LineModel(
            followers: { ["": home, "laptop": laptop] }, records: records, pairer: pairer, nav: nav,
            conversation: conversation, notePictures: NotePictures(pictures: Pictures(directory: picturesDir)),
            origins: { _ in fake.origin }, now: { now },
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
        XCTAssertEqual(messageBlocks(card.details.body).map(\.kind), [
            .heading(2), .text,
            .item(marker: "•", depth: 0), .item(marker: "•", depth: 0),
            .text, .code, .text,
        ])
        XCTAssertTrue(card.knownBeads.contains("yd-greet"))
        XCTAssertEqual(copyableProse(card.details.body), card.details.body)
        XCTAssertEqual(copyableProse(card.details.notes[0].text), card.details.notes[0].text)
        try await render(NavigationStack { BeadCardScreen(model: line, route: route) }, scene: scene, to: dir.appendingPathComponent("bead-card.png"))
        let markdownWindow = try await renderWindow(
            NavigationStack { BeadCardScreen(model: line, route: route) },
            scene: scene, to: dir.appendingPathComponent("bead-card-markdown.png"), height: 1800
        )
        let code = try XCTUnwrap(horizontalScrolls(in: markdownWindow).first)
        XCTAssertEqual(horizontalScrolls(in: markdownWindow).count, 1, "the one fenced block scrolls")
        XCTAssertEqual(code.convert(code.bounds, to: markdownWindow).minX, 20, accuracy: 2)
        XCTAssertEqual(code.convert(code.bounds, to: markdownWindow).maxX, 402 - 20, accuracy: 2)
        markdownWindow.isHidden = true
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
        // Last: a yard whose coordinator has another name renders the
        // card's Ask with that name. The `up` reads the board again,
        // and with it every standing card, so nothing held or refused
        // may follow it, and the refused card's refusal is disarmed
        // first, or it lands on this card too.
        home.beadRefuse = nil
        var renamed = loaded()
        renamed.me.yardmaster = "mayor"
        home.up(renamed)
        XCTAssertEqual(line.coordinatorName(for: ""), "mayor")
        try await render(NavigationStack { BeadCardScreen(model: line, route: route) }, scene: scene, to: dir.appendingPathComponent("bead-card-ask-mayor.png"))
        // A note that carries a picture the yard holds and a page: the
        // card draws the picture under the note's words, a thumbnail, and
        // the page as a line with its name. Read again with the board, as
        // a note written meanwhile is.
        let png = timetablePNG()
        home.blobs[sha256Hex(png)] = png
        home.beads["yd-train"] = pictureBead(png)
        await line.refresh()
        let picturesDeadline = ContinuousClock.now + .seconds(10)
        while line.card(for: route)?.details.notes.last?.images.first?.bytes == nil, ContinuousClock.now <= picturesDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pictured = try XCTUnwrap(line.card(for: route)?.details.notes.last)
        XCTAssertEqual(pictured.images, [ShownImage(hash: sha256Hex(png), name: "timetable.png", bytes: png)])
        XCTAssertEqual(pictured.files, ["report.html"])
        try await render(NavigationStack { BeadCardScreen(model: line, route: route) }, scene: scene, to: dir.appendingPathComponent("bead-card-note-picture.png"))
        // Three pictures over two notes: the card says Media · 3 under its
        // labels, the grid has the newest note's two first and then the
        // older note's one, and a picture opens full size with who attached
        // it and when. A card whose notes carry none, as the shots above,
        // has no such row.
        let shots = [
            labelledPNG("first pass"),
            labelledPNG("platform 2", size: CGSize(width: 450, height: 720)),
            labelledPNG("ballast", size: CGSize(width: 600, height: 600)),
        ]
        for shot in shots { home.blobs[sha256Hex(shot)] = shot }
        home.beads["yd-train"] = mediaBead(shots)
        await line.refresh()
        func pictures() -> [CardMedia] { line.card(for: route)?.details.media ?? [] }
        let mediaDeadline = ContinuousClock.now + .seconds(10)
        while !(pictures().count == 3 && pictures().allSatisfy { $0.image.bytes != nil }), ContinuousClock.now <= mediaDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pictures().map(\.image.name), ["platform.png", "ballast.png", "first-pass.png"])
        XCTAssertEqual(pictures().map(\.caption), ["yardmaster · 11:05", "yardmaster · 11:05", "train-new · 10:20"])
        XCTAssertTrue(pictures().allSatisfy { $0.image.bytes != nil })
        try await render(NavigationStack { BeadCardScreen(model: line, route: route) }, scene: scene, to: dir.appendingPathComponent("bead-card-media.png"))
        try await render(NavigationStack { MediaGridScreen(model: line, route: route) }, scene: scene, to: dir.appendingPathComponent("media-grid.png"))
        try await render(MediaViewer(media: pictures(), start: pictures()[1].id) {}, scene: scene, to: dir.appendingPathComponent("media-viewer.png"))
        line.leave()
    }

    /// The train once more, its last two notes carrying `pictures`: the
    /// first pass in one note, the platform and the ballast in the next.
    private func mediaBead(_ pictures: [Data]) -> Bead {
        func file(_ bytes: Data, _ name: String) -> BlobRef {
            BlobRef(hash: sha256Hex(bytes), kind: "image/png", bytes: Int64(bytes.count), name: name)
        }
        return Bead(
            id: "yd-train", title: "Release train",
            body: "The release train leaves nightly with what is green.",
            stage: "new",
            labels: ["topic:trains", "kind:feat"],
            notes: [
                BeadNote(seq: 5, kind: "note", author: "yardmaster", text: "Plan: move the departure to 02:00.", at: "2026-10-08T09:45:00Z"),
                BeadNote(
                    seq: 6, kind: "note", author: "train-new", text: "Moved. The first pass:", at: "2026-10-08T10:20:00Z",
                    files: [file(pictures[0], "first-pass.png")]
                ),
                BeadNote(
                    seq: 7, kind: "note", author: "yardmaster", text: "And the platform and the ballast.", at: "2026-10-08T11:05:00Z",
                    files: [file(pictures[1], "platform.png"), file(pictures[2], "ballast.png")]
                ),
            ]
        )
    }

    /// What the fake yard answers for the train: labels, a body with a
    /// link, and three notes.
    private func trainBead() -> Bead {
        Bead(
            id: "yd-train", title: "Release train",
            body: """
            ## What moved

            Two beads **landed**: yd-greet is in, and `yd-shed` waits in review.

            - Land the shed
            - Tell the signalman

            Look at it with:

            ```
            yardr bead show yd-greet
            ```

            The list is at https://example.org/docs.
            """,
            stage: "new",
            labels: ["topic:trains", "kind:feat", "size:medium"],
            notes: [
                BeadNote(seq: 2, kind: "note", author: "mckean", text: "**Keep** the night run; the day run can wait.", at: "2026-10-07T16:20:00Z"),
                BeadNote(seq: 5, kind: "note", author: "yardmaster", text: "Plan: read `timetable.md`, then move the departure to 02:00.", at: "2026-10-08T09:45:00Z"),
                BeadNote(seq: 6, kind: "note", author: "train-new", text: "Moved. Checked https://example.org/timetable; yd-greet moved next.", at: "2026-10-08T11:20:00Z"),
            ]
        )
    }

    /// The train again, shorter, its last note carrying `png` and a page.
    private func pictureBead(_ png: Data) -> Bead {
        Bead(
            id: "yd-train", title: "Release train",
            body: "The release train leaves nightly with what is green.",
            stage: "new",
            labels: ["topic:trains", "kind:feat"],
            notes: [
                BeadNote(seq: 5, kind: "note", author: "yardmaster", text: "Plan: move the departure to 02:00.", at: "2026-10-08T09:45:00Z"),
                BeadNote(
                    seq: 6, kind: "note", author: "train-new", text: "Moved. The timetable now reads:", at: "2026-10-08T11:20:00Z",
                    files: [
                        BlobRef(hash: sha256Hex(png), kind: "image/png", bytes: Int64(png.count), name: "timetable.png"),
                        BlobRef(hash: String(repeating: "dd", count: 32), kind: "text/html; charset=utf-8", bytes: 900, name: "report.html"),
                    ]
                ),
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

    /// As `render`, but drawing the window whole at `height` and leaving
    /// it up for measuring: the caller hides it.
    private func renderWindow(
        _ view: some View, scene: UIWindowScene, to file: URL, height: CGFloat
    ) async throws -> UIWindow {
        let hosting = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(700))
        try snapshot(window, to: file, height: height)
        return window
    }

    /// The window as it stands, written as a PNG.
    private func snapshot(_ window: UIWindow, to file: URL, height: CGFloat) throws {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData(), "the rendered screen has no PNG")
        XCTAssertEqual(image.size, CGSize(width: 402, height: height))
        try png.write(to: file)
        XCTAssertGreaterThan(png.count, 10000, "the rendered screen looks blank")
    }

    /// The scroll views that scroll sideways: the code blocks, which are
    /// short, beside the card's own, which fills the window.
    private func horizontalScrolls(in view: UIView) -> [UIScrollView] {
        var found = view.subviews.flatMap { horizontalScrolls(in: $0) }
        if let scroll = view as? UIScrollView, !(scroll is UITextView), scroll.bounds.height < 400 { found.append(scroll) }
        return found
    }

    /// The window drawn light and then dark, as `<name>-light.png` and
    /// `<name>-dark.png`, whatever the simulator is set to.
    private func shootAppearances(of window: UIWindow, named name: String, in dir: URL) async throws {
        for (style, word) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(400))
            try snapshot(window, to: dir.appendingPathComponent("\(name)-\(word).png"), height: window.bounds.height)
        }
        window.overrideUserInterfaceStyle = .unspecified
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
