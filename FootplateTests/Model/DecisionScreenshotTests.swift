@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The decision screens rendered in the simulator against
// fake-followed state (design 3.5, the bead's screenshots): the
// decisions list, a routine card with its context, its details rows
// (its own bead's first, then the bead it is about) and its Ask about
// this, the card's own bead expanded to its description and notes, the
// other bead expanded the same, the conversation Ask about this opens,
// a weighty card with its own row shut, a harness login's code card
// with its sign-in link, an API key's card, and starter's summary card
// with the text of one of its files.
// Hand-run for the bead note; the gate runs it too, and it only
// asserts that each
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
        home.beads = beads().merging(["yd-pack": try packBead(), "yd-bars": barsChange()]) { $1 }
        home.up(loaded())
        let decisions = DecisionsModel(records: records, mailroom: mailroom, nav: nav, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        let conversation = ConversationModel(mailroom: mailroom, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        let decision = DecisionModel(mailroom: mailroom, records: records, nav: nav, conversation: conversation, unlock: FakeUnlock(), now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        let line = LineModel(
            followers: { ["": home, "laptop": laptop] }, records: records, pairer: pairer, nav: nav,
            conversation: conversation, origins: { _ in fake.origin }, now: { now }
        )

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
        // The context is on the card with nothing tapped, and Ask about
        // this stands under Later and Decline.
        try await render(
            DecisionScreen(model: decision, yard: "", bead: "yd-links", ask: 3),
            scene: scene, to: dir.appendingPathComponent("routine.png")
        )
        XCTAssertEqual(decision.state.context, ["The links file declares the new source; 64 links still point at the old one."])
        // The card's own bead has its row first, the bead the ask is
        // about the second, both shut.
        XCTAssertEqual(decision.state.details.map(\.id), ["yd-links", "yd-train"])
        XCTAssertEqual(decision.state.details.map(\.expanded), [false, false])
        // The own row opens to the description and notes its card's read
        // brought; the shot is tall enough to show the options under it.
        await decision.toggleDetails("yd-links")
        XCTAssertEqual(decision.state.details.first?.expanded, true)
        XCTAssertEqual(decision.state.details.first?.notes.map(\.author), ["builder", "yardmaster"])
        try await render(
            DecisionScreen(model: decision, yard: "", bead: "yd-links", ask: 3),
            scene: scene, to: dir.appendingPathComponent("own.png"), height: 1300
        )
        await decision.toggleDetails("yd-links")
        await decision.toggleDetails("yd-train")
        let train = try XCTUnwrap(decision.state.details.first { $0.id == "yd-train" })
        XCTAssertTrue(train.expanded)
        XCTAssertEqual(train.notes.map(\.author), ["builder", "reviewer"])
        try await render(
            DecisionScreen(model: decision, yard: "", bead: "yd-links", ask: 3),
            scene: scene, to: dir.appendingPathComponent("details.png")
        )
        // Ask about this: the yardmaster's conversation on the crew
        // place, its draft started with the bead's id.
        decision.askCoordinator()
        XCTAssertEqual(nav.place, .crew)
        XCTAssertEqual(nav.crewPath, [ConversationRoute(yard: "", with: "yardmaster")])
        try await render(
            ConversationScreen(model: conversation, line: line, yard: "", with: "yardmaster"),
            scene: scene, to: dir.appendingPathComponent("ask.png")
        )
        XCTAssertEqual(conversation.state.draft, "yd-links ")
        conversation.leave()
        decision.leave()
        try await render(
            DecisionScreen(model: decision, yard: "", bead: "yd-map", ask: 7),
            scene: scene, to: dir.appendingPathComponent("weighty.png")
        )
        // A weighty card about nothing still has its own bead's row, shut,
        // between its context and its options.
        XCTAssertFalse(decision.state.weighty.isEmpty)
        XCTAssertEqual(decision.state.details.map(\.id), ["yd-map"])
        XCTAssertEqual(decision.state.details.map(\.expanded), [false])
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

        // Starter's summary card on a tall screen, as tall as a window can
        // be at 3x (a view past 8192 px comes out blank), then the sheet its
        // first file's line opens over the card.
        let card = DecisionScreen(model: decision, yard: "", bead: "yd-pack", ask: 61)
        try await render(card, scene: scene, to: dir.appendingPathComponent("pack.png"), height: 2700)
        let opens = try XCTUnwrap(decision.state.pack?.opens)
        XCTAssertEqual(opens.count, PackCards.files.count)
        try await renderSheet(
            card, of: decision, opening: try XCTUnwrap(opens.values.first { $0.name == "roles/builder.md" }),
            scene: scene, to: dir.appendingPathComponent("pack-text.png")
        )
        decision.leave()

        // A text of two parts draws the lines of the second as well as its
        // title: in a sheet, a LazyVStack of ForEachs of ForEachs left the
        // lines of a second part of three unbuilt. Those lines are solid
        // bars, so what is drawn lowest is solid where they are, and thin
        // text where only the title is.
        let solid = try await renderSheet(
            DecisionScreen(model: decision, yard: "", bead: "yd-bars", ask: 63), of: decision,
            opening: PackEntry(kind: .file, name: "roles/builder.md", action: "change"),
            scene: scene, to: dir.appendingPathComponent("pack-bars.png")
        )
        XCTAssertGreaterThan(solid, 0.5, "the second part's lines were not drawn")
        decision.leave()
    }

    /// A summary card whose one file is a change with a diff and a new
    /// text of three bars.
    private func barsChange() -> Bead {
        let text = String(repeating: String(repeating: "\u{2588}", count: 36) + "\n", count: 3)
        let run = Run(
            argv: ["pack", "apply", "starter", "--depot", "yard"], command: "yardr pack apply starter --depot yard",
            does: [
                "pack starter (\(PackCards.label)), of kind git, into depot yard: 0 to create, 1 to change, digest sha256:\(PackCards.digest).",
                "file roles/builder.md: change, sha256 \(PackCards.sha256("old")) -> sha256 \(PackCards.sha256(text)), \(text.utf8.count) bytes (1 insertions, 1 deletions).",
            ],
            pack: RunPack(
                name: "starter", depot: "yard", summary: true, files: [PackFile(name: "roles/builder.md", line: 1)],
                plan: PackPlan(objects: [PlanObject(
                    kind: "file", name: "roles/builder.md", action: "change",
                    oldSHA256: PackCards.sha256("old"), newSHA256: PackCards.sha256(text), text: text,
                    diff: "--- roles/builder.md\n+++ roles/builder.md\n@@ -1 +1 @@\n-old\n+new\n"
                )])
            )
        )
        return Bead(id: "yd-bars", asks: [BeadAsk(ask: 63, question: "Update the starter pack in depot yard?", run: run)])
    }

    /// starter's summary card as the yard sends it, read as the client does.
    private func packBead() throws -> Bead {
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(PackCards.starter.utf8)) as? [String: Any])
        let result = try JSONSerialization.data(withJSONObject: try XCTUnwrap(reply["result"]))
        return try JSONDecoder().decode(Bead.self, from: result)
    }

    private func render(_ view: some View, scene: UIWindowScene, to file: URL, height: CGFloat = 874) async throws {
        let (window, hosting) = host(view, scene: scene, height: height)
        try await Task.sleep(for: .milliseconds(700))
        try snapshot(hosting.view, in: window, to: file, height: height)
        window.isHidden = true
    }

    /// The card with the text a line of it opens, as it is presented: the
    /// sheet is drawn from the window, since a modal is no part of the
    /// hosting view's hierarchy. Presenting it is no leaving the card, so
    /// the model still holds the text; shutting it takes the sheet away.
    @discardableResult
    private func renderSheet(_ view: some View, of decision: DecisionModel, opening entry: PackEntry, scene: UIWindowScene, to file: URL) async throws -> Double {
        let (window, hosting) = host(view, scene: scene, height: 874)
        // The card is up before a line of it is tapped: the screen shown
        // before it has left, and has told the model so.
        try await Task.sleep(for: .milliseconds(700))
        let deadline = ContinuousClock.now + .seconds(10)
        while !decision.state.read, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        decision.openText(entry)
        while hosting.presentedViewController == nil, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(hosting.presentedViewController, "the line did not open its text")
        // The sheet's rise takes its time to settle.
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNotNil(decision.state.pack?.text, "presenting the sheet left the card")
        let drawn = image(of: window, in: window)
        try write(drawn, to: file, height: 874)
        decision.closeText()
        while hosting.presentedViewController != nil, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(hosting.presentedViewController, "shutting the text left its sheet")
        window.isHidden = true
        return lowestSolidity(drawn)
    }

    private func host(_ view: some View, scene: UIWindowScene, height: CGFloat) -> (UIWindow, UIHostingController<AnyView>) {
        let hosting = UIHostingController(rootView: AnyView(view))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: height)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        return (window, hosting)
    }

    private func image(of drawn: UIView, in window: UIWindow) -> UIImage {
        drawn.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drawn.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func snapshot(_ drawn: UIView, in window: UIWindow, to file: URL, height: CGFloat) throws {
        try write(image(of: drawn, in: window), to: file, height: height)
    }

    private func write(_ image: UIImage, to file: URL, height: CGFloat) throws {
        let png = try XCTUnwrap(image.pngData(), "the rendered screen has no PNG")
        XCTAssertEqual(image.size, CGSize(width: 402, height: height))
        try png.write(to: file)
        XCTAssertGreaterThan(png.count, 10000, "the rendered screen looks blank")
    }

    /// How solid the lowest thing drawn is, from 0 to 1: of the rows of its
    /// band of ink (up from the lowest row with a pixel unlike the corner
    /// under the margin), the greatest share of a row that is ink. Text is
    /// thin and a bar of block characters is not.
    private func lowestSolidity(_ image: UIImage) -> Double {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let base = (height - 1) * width * 4
        let ground = Array(pixels[base ..< base + 3])
        func ink(_ row: Int) -> Int {
            (0 ..< width).filter { column in
                let at = (row * width + column) * 4
                return (0 ..< 3).contains { abs(Int(pixels[at + $0]) - Int(ground[$0])) > 24 }
            }.count
        }
        var row = height - 1
        while row >= 0, ink(row) == 0 { row -= 1 }
        var solid = 0.0
        while row >= 0, ink(row) > 0 {
            solid = max(solid, Double(ink(row)) / Double(width))
            row -= 1
        }
        return solid
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
            "yd-links": Bead(
                id: "yd-links", title: "Move the links",
                body: "The links file declares the new source. See https://example.com/links for the old and the new address.",
                stage: "new",
                notes: [
                    BeadNote(seq: 1, kind: "note", author: "builder", text: "The test passed on a copy of the links file.", at: "2026-10-08T09:30:00Z"),
                    BeadNote(seq: 2, kind: "note", author: "yardmaster", text: "64 links still point at the old source.", at: "2026-10-08T10:15:00Z"),
                ],
                asks: [
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
                ]
            ),
            "yd-train": Bead(
                id: "yd-train", title: "Release train",
                body: "The release train leaves nightly with what is green. See https://example.com/train for the timetable.",
                stage: "new",
                notes: [
                    BeadNote(seq: 1, kind: "note", author: "builder", text: "Started. The timetable is kept at https://example.com/timetable.", at: "2026-10-08T09:30:00Z"),
                    BeadNote(seq: 2, kind: "note", author: "reviewer", text: "The nightly run is green.", at: "2026-10-08T10:15:00Z"),
                ],
                asks: []
            ),
            "yd-login": Bead(id: "yd-login", title: "Claude Code sign-in", stage: "new", asks: [
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
            "yd-key": Bead(id: "yd-key", title: "Claude Code API key", stage: "new", asks: [
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
            "yd-map": Bead(id: "yd-map", title: "Who wrote in", stage: "new", asks: [
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
