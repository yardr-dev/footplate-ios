@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The crew screens rendered in the simulator against fake-followed
// state (design 3.5, the bead's screenshots): the inbox with unread
// rows, one conversation, and the yard switch with two yards, one
// away. Hand-run for the bead note; the gate runs it too, and it
// only asserts that each screen renders non-empty at phone size.
// PNGs land in `CREW_SHOTS_DIR`, or the temporary directory's
// `crew-shots` where that names none.
@MainActor
final class CrewScreenshotTests: XCTestCase {
    func testCrewScreensRender() async throws {
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
        let nav = Nav()
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
        // A picture the conversation draws: a rust shed wall, as
        // PNG bytes the fake yard holds under its hash.
        let shedFormat = UIGraphicsImageRendererFormat()
        shedFormat.scale = 1
        let shed = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320), format: shedFormat).image { context in
            UIColor(red: 0.62, green: 0.28, blue: 0.12, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
            UIColor(red: 0.92, green: 0.85, blue: 0.75, alpha: 1).setFill()
            context.fill(CGRect(x: 60, y: 60, width: 360, height: 200))
        }
        let shedPNG = shed.pngData()!
        let shedHash = sha256Hex(shedPNG)
        home.blobs[shedHash] = shedPNG
        home.pages["yardmaster|0"] = Page(letters: [
            Letter(seq: 13, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "The shed is painted. Shall I land it?"),
            Letter(seq: 14, at: "2026-10-08T09:31:00Z", from: "yardmaster", to: "jo", text: "Or after Friday?"),
            Letter(seq: 15, at: "2026-10-08T09:31:00Z", from: "yardmaster", to: "jo", text: "The shed, painted.", files: [BlobRef(hash: shedHash, kind: "image/png", bytes: 70, name: "shed.png")]),
            Letter(seq: 36, at: "2026-10-08T09:32:00Z", from: "jo", to: "yardmaster", text: "On the train. Land the shed when it is green."),
        ], more: false)
        laptop.state.status = .down(words: "The yard is away: the edge cannot reach it.", short: "yard away")

        let dir = ProcessInfo.processInfo.environment["CREW_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("crew-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let deadline = ContinuousClock.now + .seconds(10)
        while inbox.state.rows.isEmpty, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(inbox.state.rows.isEmpty)

        let conversation = ConversationModel(mailroom: mailroom, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        let notifier = Notifier(mailroom: mailroom, records: records, allowed: { true }, tell: { _ in })
        await notifier.refresh()
        try await render(CrewScreen(model: inbox, nav: nav, conversation: conversation, notifier: notifier), scene: scene, to: dir.appendingPathComponent("inbox.png"))
        conversation.open(yard: "", with: "yardmaster")
        let convDeadline = ContinuousClock.now + .seconds(10)
        while conversation.state.letters.count < 4
            || conversation.state.letters.first { $0.seq == 15 }?.images.first?.bytes == nil,
            ContinuousClock.now <= convDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.state.letters.count, 4)
        XCTAssertNotNil(conversation.state.letters.first { $0.seq == 15 }?.images.first?.bytes)
        try await render(
            ConversationScreen(model: conversation, yard: "", with: "yardmaster"),
            scene: scene, to: dir.appendingPathComponent("conversation.png")
        )
        conversation.leave()
        try await render(YardSwitchView(state: inbox.state), scene: scene, to: dir.appendingPathComponent("switch.png"))
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
