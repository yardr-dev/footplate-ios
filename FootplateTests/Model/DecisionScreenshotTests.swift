@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The decision screens rendered in the simulator against
// fake-followed state (design 3.5, the bead's screenshots): the
// decisions list, a routine card, a routine card with a bead's details
// expanded, a weighty card, a harness login's
// code card with its sign-in link, and an API key's card. Hand-run for
// the bead note; the gate runs it too, and it only asserts that each
// screen renders non-empty at phone size. PNGs land in
// `DECISION_SHOTS_DIR`, or the temporary directory's `decision-shots`
// where that names none.
@MainActor
final class DecisionScreenshotTests: XCTestCase {
    func testDecisionScreensRender() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: "yardr-dev-laptop-1"))
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        records.noteNotificationsAsked()
        let nav = Nav(place: .decide)
        let home = FakeFollowed()
        let laptop = FakeFollowed()
        let mailroom = Mailroom()
        mailroom.setFollowers(["": home, "laptop": laptop])
        let now = parseInstant("2026-10-08T11:30:00Z")!
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let inbox = InboxModel(
            pairer: pairer, records: records,
            followers: { ["": home, "laptop": laptop] },
            mailroom: mailroom, nav: nav,
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        home.beads = beads()
        home.up(loaded())
        let decisions = DecisionsModel(records: records, mailroom: mailroom, nav: nav, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        let decision = DecisionModel(mailroom: mailroom, records: records, nav: nav, unlock: FakeUnlock(), now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })

        let dir = ProcessInfo.processInfo.environment["DECISION_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("decision-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let deadline = ContinuousClock.now + .seconds(10)
        while decisions.state.open.count < 3, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(decisions.state.open.count, 3)
        XCTAssertEqual(decisions.state.decided.map(\.what), ["declined"])

        try await render(DecisionsScreen(inbox: inbox, model: decisions, decision: decision, nav: nav), scene: scene, to: dir.appendingPathComponent("decisions.png"))
        try await render(
            DecisionScreen(model: decision, yard: "", bead: "yd-links", ask: 3),
            scene: scene, to: dir.appendingPathComponent("routine.png")
        )
        await decision.toggleDetails("yd-train")
        XCTAssertTrue(decision.state.details.first?.expanded == true)
        try await render(
            DecisionScreen(model: decision, yard: "", bead: "yd-links", ask: 3),
            scene: scene, to: dir.appendingPathComponent("details.png")
        )
        decision.leave()
        try await render(
            DecisionScreen(model: decision, yard: "", bead: "yd-map", ask: 7),
            scene: scene, to: dir.appendingPathComponent("weighty.png")
        )
        decision.leave()
        try await render(
            DecisionScreen(model: decision, yard: "", bead: "yd-login", ask: 34),
            scene: scene, to: dir.appendingPathComponent("login.png")
        )
        XCTAssertTrue(decision.state.givesCode)
        decision.leave()
        try await render(
            DecisionScreen(model: decision, yard: "", bead: "yd-key", ask: 22),
            scene: scene, to: dir.appendingPathComponent("key.png")
        )
        XCTAssertFalse(decision.state.givesCode)
        decision.leave()
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
            crew: [CrewMember(name: "yardmaster", enabled: true, state: "running", status: "working", loginScreen: false)],
            users: [User(name: "jo")],
            inbox: Inbox(),
            notifications: Notifications(),
            asks: Asks(open: [
                OpenAsk(bead: "yd-links", beadTitle: "Move the links", ask: 3, question: "Move this yard's links to the declared source now?", asker: "yardmaster", since: "2026-10-08T09:30:00Z"),
                OpenAsk(bead: "yd-map", beadTitle: "Who wrote in", ask: 7, question: "Who is U024BE7LH on slack?", asker: "yardmaster", since: "2026-10-08T09:30:00Z", identity: Identity(source: "slack", sender: "U024BE7LH", channel: "C1"), weight: [AskWeight(kind: "as-user", line: "writes who a sender is: U024BE7LH on slack becomes a user of the yard")]),
                OpenAsk(bead: "yd-tidy", beadTitle: "Tidy the sidings", ask: 9, question: "Remove the merged worktrees now?", asker: "yardmaster", since: "2026-10-08T09:30:00Z"),
            ], decided: [
                DecidedAsk(bead: "yd-greet", beadTitle: "The greeting", ask: 5, question: "What should the tone of the greeting be?", state: "declined"),
            ])
        )
    }

    private func beads() -> [String: Bead] {
        [
            "yd-links": Bead(id: "yd-links", asks: [
                BeadAsk(
                    ask: 3, question: "Move this yard's links to the declared source now?",
                    context: ["The links file declares the new source; 64 links still point at the old one."],
                    options: [
                        AskOption(label: "Move them now", consequence: "all 64 links point at the new source tonight"),
                        AskOption(label: "After Friday", consequence: "keep the old source until the release is out"),
                        AskOption(label: "You decide", consequence: "leave it to yardmaster"),
                    ],
                    recommend: 1, why: "the test passed", about: [AboutBead(id: "yd-train", title: "Release train", stage: "new")]
                ),
            ]),
            "yd-train": Bead(
                id: "yd-train", title: "Release train",
                body: "The release train leaves nightly with what is green. See https://example.com/train for the timetable.",
                stage: "new", asks: []
            ),
            "yd-login": Bead(id: "yd-login", asks: [
                BeadAsk(
                    ask: 34, question: "Paste what Claude Code's sign-in page gave you",
                    context: [
                        "Sign in on this page: https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&scope=user%3Ainference&state=Xk3v",
                        "Claude Code's login waits for what the page gives you (Paste code here if prompted >).",
                        "What you type goes to the login in the yard's memory and is kept nowhere.",
                    ],
                    secret: Secret(env: ["INPUT"], line: "a secret: INPUT, for the waiting login claude-ab12", login: "claude-ab12"),
                    weight: [AskWeight(kind: "credential", line: "INPUT, for the waiting login claude-ab12")]
                ),
            ]),
            "yd-key": Bead(id: "yd-key", asks: [
                BeadAsk(
                    ask: 22, question: "What is the API key Claude Code runs with?",
                    context: ["yardmaster is at Claude Code's login screen."],
                    secret: Secret(
                        env: ["ANTHROPIC_API_KEY"],
                        line: "a secret: ANTHROPIC_API_KEY, the API key Claude Code runs with, asked for crew member yardmaster; it is read by every Claude Code session that burns the operator's login, from its next start",
                        harness: "claude", crew: "yardmaster"
                    ),
                    weight: [AskWeight(kind: "credential", line: "ANTHROPIC_API_KEY, the API key Claude Code runs with, asked for crew member yardmaster")]
                ),
            ]),
            "yd-map": Bead(id: "yd-map", asks: [
                BeadAsk(
                    ask: 7, question: "Who is U024BE7LH on slack?",
                    context: ["a delivery arrived from U024BE7LH in C1, who maps to nobody."],
                    options: [
                        AskOption(label: "jo", consequence: "messages from U024BE7LH count as jo's"),
                        AskOption(label: "Someone new", consequence: "pick this and write the new user's name with your answer"),
                        AskOption(label: mappingNobody, consequence: "ignores U024BE7LH in slack"),
                        AskOption(label: youDecide, consequence: "leave it to yardmaster"),
                    ],
                    recommend: 1, why: "jo wrote from this workspace before",
                    identity: Identity(source: "slack", sender: "U024BE7LH", channel: "C1"),
                    weight: [AskWeight(kind: "as-user", line: "writes who a sender is: U024BE7LH on slack becomes a user of the yard")]
                ),
            ]),
        ]
    }
}
