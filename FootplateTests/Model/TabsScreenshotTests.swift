@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The tabs rendered in the simulator against fake-followed state
// (design 3.5, the bead's screenshots): the Crew, Decide and Lines
// tabs and one pushed conversation, at phone and pad size. Hand-run
// for the bead note; the gate runs it too, and it only asserts that
// each tab renders non-empty at each size. PNGs land in
// `NAV_SHOTS_DIR`, or the temporary directory's `nav-shots` where
// that names none.
@MainActor
final class TabsScreenshotTests: XCTestCase {
    private let phone = CGSize(width: 402, height: 874)
    private let pad = CGSize(width: 834, height: 1194)

    func testTabsRender() async throws {
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
        let nav = Nav()
        let home = FakeFollowed()
        let laptop = FakeFollowed()
        let mailroom = Mailroom()
        mailroom.setFollowers(["": home, "laptop": laptop])
        let now = parseInstant("2026-10-08T12:00:00Z")!
        let zone = TimeZone(secondsFromGMT: 0)!
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let inbox = InboxModel(
            pairer: pairer, records: records,
            followers: { ["": home, "laptop": laptop] },
            mailroom: mailroom, nav: nav,
            now: { now }, zone: { zone }
        )
        let conversation = ConversationModel(mailroom: mailroom, now: { now }, zone: { zone })
        let decisions = DecisionsModel(records: records, mailroom: mailroom, nav: nav, now: { now }, zone: { zone })
        let decision = DecisionModel(mailroom: mailroom, records: records, nav: nav, unlock: FakeUnlock(), now: { now }, zone: { zone })
        let line = LineModel(followers: { ["": home, "laptop": laptop] })
        let pair = PairModel(pairer: pairer, records: records, nav: nav)
        let signIn = SignInModel(pairer: pairer, records: records, nav: nav)
        let notifier = Notifier(mailroom: mailroom, records: records, allowed: { true }, tell: { _ in })
        await notifier.refresh()
        func tabs() -> TabsView {
            TabsView(nav: nav, inbox: inbox, records: records, conversation: conversation, decisions: decisions, decision: decision, line: line, pair: pair, signIn: signIn, notifier: notifier)
        }

        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [
            Letter(seq: 13, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "The shed is painted. Shall I land it?"),
            Letter(seq: 14, at: "2026-10-08T09:31:00Z", from: "yardmaster", to: "jo", text: "Or after Friday?"),
            Letter(seq: 36, at: "2026-10-08T09:32:00Z", from: "jo", to: "yardmaster", text: "On the train. Land the shed when it is green."),
        ], more: false)
        home.board = try cannedBoard()
        laptop.state.status = .down(words: "The yard is away: the edge cannot reach it.", short: "yard away")
        line.open(yard: "")

        let deadline = ContinuousClock.now + .seconds(10)
        while inbox.state.rows.isEmpty || decisions.state.open.isEmpty || !line.state.read,
            ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(inbox.state.rows.isEmpty)
        XCTAssertFalse(decisions.state.open.isEmpty)
        XCTAssertTrue(line.state.read)

        let dir = ProcessInfo.processInfo.environment["NAV_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("nav-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        nav.place = .crew
        try await render(tabs(), scene: scene, size: phone, to: dir.appendingPathComponent("crew-iphone.png"))
        try await render(tabs(), scene: scene, size: pad, to: dir.appendingPathComponent("crew-ipad.png"))
        nav.place = .decide
        try await render(tabs(), scene: scene, size: phone, to: dir.appendingPathComponent("decide-iphone.png"))
        try await render(tabs(), scene: scene, size: pad, to: dir.appendingPathComponent("decide-ipad.png"))
        nav.place = .lines
        try await render(tabs(), scene: scene, size: phone, to: dir.appendingPathComponent("lines-iphone.png"))
        try await render(tabs(), scene: scene, size: pad, to: dir.appendingPathComponent("lines-ipad.png"))

        nav.place = .crew
        nav.openConversation(yard: "", with: "yardmaster")
        conversation.open(yard: "", with: "yardmaster")
        let convDeadline = ContinuousClock.now + .seconds(10)
        while conversation.state.letters.count < 3, ContinuousClock.now <= convDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.state.letters.count, 3)
        try await render(tabs(), scene: scene, size: phone, to: dir.appendingPathComponent("pushed-iphone.png"))
        try await render(tabs(), scene: scene, size: pad, to: dir.appendingPathComponent("pushed-ipad.png"))
        conversation.leave()
        line.leave()
    }

    private func render(_ view: some View, scene: UIWindowScene, size: CGSize, to file: URL) async throws {
        let hosting = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
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
        XCTAssertEqual(image.size, size)
        try png.write(to: file)
        XCTAssertGreaterThan(png.count, 10000, "the rendered screen looks blank")
        window.isHidden = true
    }

    /// The fake yard's board, as Canned serves it: two depots.
    private func cannedBoard() throws -> Flows {
        struct Result: Decodable {
            var result: Flows
        }
        let canned = try XCTUnwrap(Canned.replies["Flows"])
        return try JSONDecoder().decode(Result.self, from: Data(canned.utf8)).result
    }

    private func loaded() -> Loaded {
        Loaded(
            me: Me(user: "jo", saidBy: "phone", yard: "south"),
            head: 151,
            settings: Settings(),
            user: User(name: "jo", cursor: 12, notificationCursor: 10),
            crew: [
                CrewMember(name: "signalman", enabled: true, state: "running", status: "idle", loginScreen: true),
                CrewMember(name: "yardmaster", enabled: true, state: "running", status: "working", loginScreen: false),
                CrewMember(name: "relief", enabled: true, state: "running", status: "idle", loginScreen: false),
            ],
            users: [User(name: "jo")],
            inbox: Inbox(mail: [
                Letter(seq: 13, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "The shed is painted. Shall I land it?"),
                Letter(seq: 14, at: "2026-10-08T09:31:00Z", from: "yardmaster", to: "jo", text: "Or after Friday?\nEither."),
                Letter(seq: 40, at: "2026-10-08T09:32:00Z", from: "signalman", to: "jo", text: "Read the diff when you can.", read: true),
            ], unread: 2, last: 14, from: []),
            notifications: Notifications(notifications: [
                Notification(seq: 10, at: "2026-10-08T09:30:00Z", kind: "created", bead: "yd-shed", text: "yd-shed created (all) by yardmaster", read: true),
                Notification(seq: 11, at: "2026-10-08T09:31:00Z", kind: "noted", bead: "yd-shed", text: "yd-shed noted (all) by yardmaster note=1", read: false),
            ], unread: 1, last: 11),
            asks: Asks(open: [
                OpenAsk(bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster"),
                OpenAsk(bead: "yd-map", ask: 7, question: "Who is U024BE7LH?", asker: "yardmaster"),
            ], decided: [])
        )
    }
}
