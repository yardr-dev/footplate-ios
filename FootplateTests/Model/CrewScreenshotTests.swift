@testable import Footplate
import SwiftUI
import UIKit
import XCTest

// The crew screens rendered in the simulator against fake-followed
// state (design 3.5, the bead's screenshots): the inbox with unread
// rows, one conversation, a conversation naming bead ids, a chip's
// bead as a sheet over the chat, a conversation with a party of a
// linked yard, and the yard switch with two yards,
// one away, at the default text size and at two
// large ones, with a yard of its own beside the edge's, and with a yard
// of another account's the account is a member of. Hand-run for the bead
// note; the gate runs it too, and it only asserts that each screen
// renders non-empty at phone size.
// PNGs land in `TEST_RUNNER_CREW_SHOTS_DIR`, or the temporary
// directory's `crew-shots` where that names none. A letter sent to
// a linked yard's party stands in its bubble with no refusal under
// the field (footplate-ios-s70v).
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
        let line = LineModel(
            followers: { ["": home, "laptop": laptop] }, records: records, pairer: pairer,
            nav: nav, conversation: conversation, origins: { _ in "https://edge.example" },
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        let notifier = Notifier(mailroom: mailroom, records: records, allowed: { true }, tell: { _ in })
        await notifier.refresh()
        try await render(CrewScreen(model: inbox, nav: nav, conversation: conversation, line: line, notifier: notifier), scene: scene, to: dir.appendingPathComponent("inbox.png"))
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
            ConversationScreen(model: conversation, line: line, yard: "", with: "yardmaster"),
            scene: scene, to: dir.appendingPathComponent("conversation.png")
        )
        conversation.leave()
        try await render(YardSwitchView(state: inbox.state), scene: scene, to: dir.appendingPathComponent("switch.png"))
        // The rows at the largest text size and at an accessibility one:
        // each as tall as its two lines, none drawn into the next.
        try await render(
            YardSwitchView(state: inbox.state).environment(\.dynamicTypeSize, .xxxLarge),
            scene: scene, to: dir.appendingPathComponent("switch-xxxl.png")
        )
        try await render(
            YardSwitchView(state: inbox.state).environment(\.dynamicTypeSize, .accessibility3),
            scene: scene, to: dir.appendingPathComponent("switch-ax.png")
        )
    }

    /// A conversation naming bead ids (footplate-ios-ah48): a known
    /// id and a yard-confirmed closed one chip, while a bare suffix, a
    /// code span and a link stand as they are.
    func testConversationWithChipsRenders() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        records.noteNotificationsAsked()
        let home = FakeFollowed()
        let mailroom = Mailroom()
        mailroom.setFollowers(["": home])
        let now = parseInstant("2026-10-08T12:00:00Z")!
        // No inbox mail: the board's letters would stand in for the
        // page's where their seqs meet.
        var quiet = loaded()
        quiet.inbox = Inbox()
        home.up(quiet)
        home.pages["yardmaster|0"] = Page(letters: [
            Letter(seq: 13, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "Landed yd-old this morning; yd-links moves next. The list is at https://yard.example/links, and the old `yd-map` row stands as it was."),
            Letter(seq: 14, at: "2026-10-08T09:31:00Z", from: "jo", to: "yardmaster", text: "Reading it now. The relief arrives at bay w311."),
        ], more: false)

        let conversation = ConversationModel(mailroom: mailroom, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        conversation.open(yard: "", with: "yardmaster")
        let deadline = ContinuousClock.now + .seconds(10)
        while conversation.state.letters.count < 2
            || !conversation.state.knownBeads.isSuperset(of: ["yd-links", "yd-old"]),
            ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.state.letters.count, 2)
        // yd-map is known from the open asks, unnamed and unasked.
        XCTAssertEqual(conversation.state.knownBeads, ["yd-links", "yd-map", "yd-old"])
        XCTAssertEqual(home.beadAsked, ["yd-old"])

        let dir = ProcessInfo.processInfo.environment["CREW_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("crew-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let nav = Nav()
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let line = LineModel(
            followers: { ["": home] }, records: records, pairer: pairer,
            nav: nav, conversation: conversation, origins: { _ in "https://edge.example" },
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        try await render(
            ConversationScreen(model: conversation, line: line, yard: "", with: "yardmaster"),
            scene: scene, to: dir.appendingPathComponent("conversation-chips.png")
        )
        conversation.leave()
    }

    /// A conversation with a party of a linked yard (footplate-ios-8mhz,
    /// footplate-ios-s70v): the party's letter is read from the page, the
    /// person replies through the field, and the yard's `mail` event with
    /// `to_peer` draws the reply in its bubble. The Crew list holds the
    /// conversation's row, and its tap opens the conversation under the
    /// party's address.
    func testAReplyToALinkedYardsPartyIsSentAndShownInTheConversation() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        records.noteNotificationsAsked()
        let nav = Nav()
        let home = FakeFollowed()
        let mailroom = Mailroom()
        mailroom.setFollowers(["": home])
        let now = parseInstant("2026-10-08T12:00:00Z")!
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let inbox = InboxModel(
            pairer: pairer, records: records, followers: { ["": home] },
            mailroom: mailroom, nav: nav, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        let conversation = ConversationModel(mailroom: mailroom, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        let line = LineModel(
            followers: { ["": home] }, records: records, pairer: pairer,
            nav: nav, conversation: conversation, origins: { _ in "https://edge.example" },
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        let notifier = Notifier(mailroom: mailroom, records: records, allowed: { true }, tell: { _ in })
        // The party's letter is in the inbox, as the yard keeps mail
        // from `<name>@<peer>`, and is what the page holds.
        let party = Letter(
            seq: 30, at: "2026-10-08T09:30:00Z", from: "clerk@north", to: "jo",
            text: "The ledger closes at noon. Is yours shut?", read: true
        )
        var read = loaded()
        read.inbox.mail.append(party)
        home.up(read)
        home.pages["clerk@north|0"] = Page(letters: [party], more: false)

        let dir = try shotsDirectory()
        let deadline = ContinuousClock.now + .seconds(10)
        while inbox.state.rows.isEmpty, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        conversation.open(yard: "", with: "clerk@north")
        while conversation.state.letters.isEmpty, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.state.letters.map(\.mine), [false])
        conversation.draft("Ours is shut. Is the ledger closed?")
        await conversation.send()
        XCTAssertEqual(home.sent.map { $0.0 }, ["clerk@north"])
        XCTAssertEqual(home.sent.map { $0.1 }, ["Ours is shut. Is the ledger closed?"])
        XCTAssertNil(conversation.state.error, "the send was not refused")
        XCTAssertEqual(conversation.state.draft, "")
        // The yard tells of the sent letter with the recipient split
        // between `to` and `to_peer`.
        home.event(Event(
            seq: 152, kind: "mail", actor: "jo", at: "2026-10-08T09:33:00Z", bead: "",
            data: [
                "to": .string("clerk"), "to_peer": .string("north"),
                "text": .string("Ours is shut. Is the ledger closed?"), "id": .string("m-1"),
            ]
        ))
        while conversation.state.letters.count < 2, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.state.title, "clerk@north")
        XCTAssertEqual(conversation.state.letters.map(\.mine), [false, true])
        XCTAssertEqual(home.asked.map { "\($0.0)|\($0.1)" }, ["clerk@north|0"], "the letter came by the stream, not by a page read")
        XCTAssertTrue(inbox.state.rows.contains { $0.name == "clerk@north" && $0.line == "Ours is shut. Is the ledger closed?" })

        await notifier.refresh()
        let crew = CrewScreen(model: inbox, nav: nav, conversation: conversation, line: line, notifier: notifier)
        try await render(crew, scene: scene, to: dir.appendingPathComponent("inbox-linked-yard.png"))
        inbox.open("clerk@north")
        XCTAssertEqual(nav.crewPath, [ConversationRoute(yard: "", with: "clerk@north")])
        let light = try await renderWindow(
            crew, scene: scene, style: .light, to: dir.appendingPathComponent("conversation-mailpeer-sent-light.png")
        )
        defer { light.isHidden = true }
        let dark = try await renderWindow(
            crew, scene: scene, style: .dark, to: dir.appendingPathComponent("conversation-mailpeer-sent-dark.png")
        )
        defer { dark.isHidden = true }
        conversation.leave()
    }

    /// Letters drawn by their Markdown (footplate-ios-qzxm): mckean's
    /// Snowflake message, whose code block holds one long line, stands
    /// the width of the conversation, scrolls sideways and does not wrap.
    func testAMessageWithACodeBlockDrawsItScrollingSideways() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let (conversation, line) = try await openConversation([
            Letter(seq: 13, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: MarkdownFixture.snowflake),
        ])
        let dir = try shotsDirectory()
        let window = try await renderWindow(
            ConversationScreen(model: conversation, line: line, yard: "", with: "yardmaster"),
            scene: scene, to: dir.appendingPathComponent("conversation-markdown.png")
        )
        defer { window.isHidden = true }
        let blocks = horizontalScrolls(in: window)
        XCTAssertEqual(blocks.count, 1, "the one code block scrolls")
        let code = try XCTUnwrap(blocks.first)
        // The long line is one line, a screen wide many times over.
        XCTAssertGreaterThan(code.contentSize.width, 4 * code.bounds.width)
        XCTAssertEqual(code.convert(code.bounds, to: window).width, 402 - 2 * 16, accuracy: 1)
        try await shootAppearances(of: window, named: "conversation-markdown", in: dir)
        // Scrolled to the end of the long line.
        code.contentOffset.x = code.contentSize.width - code.bounds.width
        try await Task.sleep(for: .milliseconds(300))
        try await shootAppearances(of: window, named: "conversation-markdown-scrolled", in: dir)
        conversation.leave()
    }

    /// The crew's letter is the width of the conversation on no surface,
    /// and the person's own is a bubble at the right, short of the left
    /// edge (footplate-ios-qzxm); each is drawn by its Markdown, and a
    /// bead's chip still chips in a list and not in code.
    func testTheCrewsLetterIsFullWidthAndThePersonsIsABubble() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let (conversation, line) = try await openConversation([
            Letter(seq: 13, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: """
            ## What moved

            Two beads **landed**, in this order:

            - yd-links is in, and `yd-map` waits in review
            - _Checked_ against https://example.org/docs
              - the second pass reads *clean*
            1. Land the shed
            2. Tell the signalman
            """),
            Letter(seq: 14, at: "2026-10-08T09:31:00Z", from: "yardmaster", to: "jo", text: "Look at it with:\n\n```\nyardr bead show yd-links\n```"),
            Letter(seq: 15, at: "2026-10-08T09:32:00Z", from: "jo", to: "yardmaster", text: "Run this on the **Mac**:\n\n```sh\nyardr bead show yd-links --json | head -20\n```\n\nThen `land` it."),
        ])
        XCTAssertTrue(conversation.state.letters.map(\.mine) == [false, false, true])
        let dir = try shotsDirectory()
        let window = try await renderWindow(
            ConversationScreen(model: conversation, line: line, yard: "", with: "yardmaster"),
            scene: scene, to: dir.appendingPathComponent("conversation-letters.png")
        )
        defer { window.isHidden = true }
        let blocks = horizontalScrolls(in: window).map { $0.convert($0.bounds, to: window) }.sorted { $0.minY < $1.minY }
        XCTAssertEqual(blocks.count, 2, "a code block in the crew's letter and one in the person's")
        guard blocks.count == 2 else { return }
        // The crew's: the width of the conversation, 16 points in from each side.
        XCTAssertEqual(blocks[0].minX, 16, accuracy: 1)
        XCTAssertEqual(blocks[0].maxX, 402 - 16, accuracy: 1)
        // The person's: inside a bubble at the right, 12 points in from its
        // edge, and short of the left by 60 points and the bubble's padding.
        XCTAssertEqual(blocks[1].maxX, 402 - 16 - 12, accuracy: 1)
        XCTAssertGreaterThanOrEqual(blocks[1].minX, 16 + 60 + 12 - 1)
        try await shootAppearances(of: window, named: "conversation-letters", in: dir)
        // At an accessibility text size the markers, the words and the code
        // grow together: the same letters, none standing on another.
        let large = try await renderWindow(
            ConversationScreen(model: conversation, line: line, yard: "", with: "yardmaster")
                .environment(\.dynamicTypeSize, .accessibility2),
            scene: scene, to: dir.appendingPathComponent("conversation-letters-ax.png")
        )
        defer { large.isHidden = true }
        conversation.leave()
    }

    /// A conversation with the yardmaster holding `letters`, open and read.
    private func openConversation(_ letters: [Letter]) async throws -> (ConversationModel, LineModel) {
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        records.noteNotificationsAsked()
        let home = FakeFollowed()
        let mailroom = Mailroom()
        mailroom.setFollowers(["": home])
        let now = parseInstant("2026-10-08T12:00:00Z")!
        // No inbox mail: the board's letters would stand in for the
        // page's where their seqs meet.
        var quiet = loaded()
        quiet.inbox = Inbox()
        home.up(quiet)
        home.pages["yardmaster|0"] = Page(letters: letters, more: false)
        // The yard knows no bead by the id-shaped words of a message
        // (read-only, ORGNAME-ACCOUNTNAME), as a real yard says.
        home.beadRefuse = ApiError.refused(code: "no_bead", message: "no such bead")
        let conversation = ConversationModel(mailroom: mailroom, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        let line = LineModel(
            followers: { ["": home] }, records: records, pairer: Pairer(edge: try fake.edge(), records: records),
            nav: Nav(), conversation: conversation, origins: { _ in "https://edge.example" },
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        conversation.open(yard: "", with: "yardmaster")
        let deadline = ContinuousClock.now + .seconds(10)
        while conversation.state.letters.count < letters.count
            || !conversation.state.knownBeads.isSuperset(of: ["yd-links", "yd-map"]),
            ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.state.letters.count, letters.count)
        return (conversation, line)
    }

    private func shotsDirectory() throws -> URL {
        let dir = ProcessInfo.processInfo.environment["CREW_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("crew-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The scroll views that scroll sideways: the code blocks, which are
    /// short, beside the conversation's own, which fills the window, and
    /// the field's text view.
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
            try snapshot(window, to: dir.appendingPathComponent("\(name)-\(word).png"))
        }
        window.overrideUserInterfaceStyle = .unspecified
    }

    /// The window as it stands, written as a PNG.
    private func snapshot(_ window: UIWindow, to file: URL) throws {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData(), "the rendered screen has no PNG")
        try png.write(to: file)
        XCTAssertGreaterThan(png.count, 10000, "the rendered screen looks blank")
    }

    /// A chip's tap (footplate-ios-f9qs): the bead's card as a sheet
    /// over the chat, with Open on the line under it, the tab left on
    /// the crew and nothing pushed.
    func testConversationBeadSheetRenders() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        records.noteNotificationsAsked()
        let home = FakeFollowed()
        let mailroom = Mailroom()
        mailroom.setFollowers(["": home])
        let now = parseInstant("2026-10-08T12:00:00Z")!
        var quiet = loaded()
        quiet.inbox = Inbox()
        home.up(quiet)
        home.pages["yardmaster|0"] = Page(letters: [
            Letter(seq: 13, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "The release yd-train leaves nightly with what is green."),
            Letter(seq: 14, at: "2026-10-08T09:31:00Z", from: "jo", to: "yardmaster", text: "Reading it now."),
        ], more: false)
        home.board = try cannedBoard()
        home.beads["yd-train"] = trainBead()

        let nav = Nav()
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let conversation = ConversationModel(mailroom: mailroom, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        let line = LineModel(
            followers: { ["": home] }, records: records, pairer: pairer,
            nav: nav, conversation: conversation, origins: { _ in "https://edge.example" },
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        conversation.open(yard: "", with: "yardmaster")
        let observersBeforeLine = home.observerCount
        line.open(yard: "")
        let deadline = ContinuousClock.now + .seconds(10)
        while conversation.state.letters.count < 2
            || !conversation.state.knownBeads.contains("yd-train")
            || !line.state.read,
            ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.state.letters.count, 2)
        XCTAssertTrue(conversation.state.knownBeads.contains("yd-train"))
        XCTAssertTrue(line.state.read)
        // The tap, as the crew screen's chip closure does it.
        let route = BeadRoute(yard: "", bead: "yd-train")
        line.peekBead("yd-train")
        conversation.openBead("yd-train")
        while line.card(for: route)?.details.read != true, ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(conversation.state.sheet, route)
        XCTAssertEqual(nav.place, .crew)
        XCTAssertTrue(nav.linesPath.isEmpty)
        XCTAssertEqual(home.observerCount, observersBeforeLine + 1)

        let dir = ProcessInfo.processInfo.environment["CREW_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("crew-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let window = try await renderWindow(
            ConversationScreen(
                model: conversation, line: line, yard: "", with: "yardmaster",
                beadSheetDismissed: { if nav.place != .lines { line.leave() } }
            ),
            scene: scene, to: dir.appendingPathComponent("conversation-sheet.png")
        )
        defer { window.isHidden = true }
        conversation.closeBeadSheet()
        let dismissDeadline = ContinuousClock.now + .seconds(3)
        while home.observerCount > observersBeforeLine, ContinuousClock.now <= dismissDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(home.observerCount, observersBeforeLine, "dismissing the sheet releases its line observer")
        conversation.leave()
        line.leave()
    }

    /// The yard switch with the edge's own yard and a yard of its own
    /// beside it, the second called by its address (footplate-ios-hj6s).
    func testYardSwitchNamesAYardOfItsOwnByItsAddress() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        let plantime = "workshop-mini.tail1a2b3c.ts.net:8446"
        records.keepYard(PairedYard(
            name: plantime, yard: "plantime", user: "jo", device: "phone", token: "yardr-dev-plantime-1",
            origin: "https://workshop-mini.tail1a2b3c.ts.net:8446"
        ))
        records.select("")
        let home = FakeFollowed()
        let own = FakeFollowed()
        let mailroom = Mailroom()
        mailroom.setFollowers(["": home, plantime: own])
        let inbox = InboxModel(
            pairer: Pairer(edge: try fake.edge(), records: records), records: records,
            followers: { ["": home, plantime: own] },
            mailroom: mailroom, nav: Nav()
        )
        home.up(loaded())
        var ownLoaded = loaded()
        ownLoaded.me = Me(user: "jo", saidBy: "phone", yard: "plantime")
        ownLoaded.asks = Asks(open: [OpenAsk(bead: "pt-shift", ask: 2, question: "Publish the shift?", asker: "yardmaster")], decided: [])
        own.up(ownLoaded)

        let deadline = ContinuousClock.now + .seconds(10)
        while inbox.state.yards.contains(where: { $0.waiting == nil }), ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(inbox.state.yards.map(\.title), ["south", plantime])
        XCTAssertEqual(inbox.state.yards.map(\.waiting), ["2 waiting", "1 waiting"])

        let dir = ProcessInfo.processInfo.environment["CREW_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("crew-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await render(YardSwitchView(state: inbox.state), scene: scene, to: dir.appendingPathComponent("switch-own-address.png"))
        // A host and its port are long: at the largest text size the
        // name loses its middle and keeps the port.
        try await render(
            YardSwitchView(state: inbox.state).environment(\.dynamicTypeSize, .xxxLarge),
            scene: scene, to: dir.appendingPathComponent("switch-own-address-xxxl.png")
        )
    }

    /// The yard switch with the account's own yard and one of another
    /// account's it is a member of, which says so beside its name
    /// (footplate-ios-n0vs).
    func testYardSwitchSaysWhoseYardAMemberYardIs() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        records.keepYard(PairedYard(name: "alice/lab", yard: "lab", user: "joe", device: "phone", token: "yardr-dev-lab-1"))
        records.select("")
        let home = FakeFollowed()
        let lab = FakeFollowed()
        let mailroom = Mailroom()
        mailroom.setFollowers(["": home, "alice/lab": lab])
        let inbox = InboxModel(
            pairer: Pairer(edge: try fake.edge(), records: records), records: records,
            followers: { ["": home, "alice/lab": lab] },
            mailroom: mailroom, nav: Nav()
        )
        home.up(loaded())
        var labLoaded = loaded()
        labLoaded.me = Me(user: "joe", saidBy: "phone", yard: "lab")
        labLoaded.asks = Asks(open: [OpenAsk(bead: "al-shift", ask: 2, question: "Publish the shift?", asker: "yardmaster")], decided: [])
        lab.up(labLoaded)

        let deadline = ContinuousClock.now + .seconds(10)
        while inbox.state.yards.contains(where: { $0.waiting == nil }), ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(inbox.state.yards.map(\.title), ["south", "lab — member of alice's yard"])
        XCTAssertEqual(inbox.state.yards.map(\.waiting), ["2 waiting", "1 waiting"])

        let dir = ProcessInfo.processInfo.environment["CREW_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("crew-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await render(YardSwitchView(state: inbox.state), scene: scene, to: dir.appendingPathComponent("switch-member.png"))
    }

    /// The yard switch with yards the person named themselves: an edge
    /// yard and a yard of its own under the names given them, a yard of
    /// another account with its note beside the name given, and one
    /// never named, called as it was (footplate-ios-jyh8). Rename this
    /// yard stands under the rows beside Forget this yard.
    func testYardSwitchShowsTheNamesAPersonGaveTheirYards() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let fake = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: "yardr-dev-laptop-1"))
        let plantime = "workshop-mini.tail1a2b3c.ts.net:8446"
        records.keepYard(PairedYard(
            name: plantime, yard: "plantime", user: "jo", device: "phone", token: "yardr-dev-plantime-1",
            origin: "https://workshop-mini.tail1a2b3c.ts.net:8446"
        ))
        records.keepYard(PairedYard(name: "alice/lab", yard: "lab", user: "joe", device: "phone", token: "yardr-dev-lab-1"))
        records.renameYard("laptop", to: "Back shed")
        records.renameYard(plantime, to: "Workshop")
        records.renameYard("alice/lab", to: "Bench")
        records.select("laptop")
        let home = FakeFollowed()
        let shed = FakeFollowed()
        let own = FakeFollowed()
        let lab = FakeFollowed()
        let mailroom = Mailroom()
        let followed: [String: FakeFollowed] = ["": home, "laptop": shed, plantime: own, "alice/lab": lab]
        mailroom.setFollowers(followed)
        let inbox = InboxModel(
            pairer: Pairer(edge: try fake.edge(), records: records), records: records,
            followers: { followed }, mailroom: mailroom, nav: Nav()
        )
        home.up(loaded())
        for (name, follow) in [("laptop", shed), (plantime, own), ("alice/lab", lab)] {
            var one = loaded()
            one.me = Me(user: name == "alice/lab" ? "joe" : "jo", saidBy: "phone", yard: name)
            one.asks = Asks(open: [OpenAsk(bead: "yd-\(follow === own ? "shift" : "gate")", ask: 2, question: "Land it?", asker: "yardmaster")], decided: [])
            follow.up(one)
        }

        let deadline = ContinuousClock.now + .seconds(10)
        while inbox.state.yards.contains(where: { $0.waiting == nil }), ContinuousClock.now <= deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(inbox.state.yards.map(\.title), ["south", "Back shed", "Workshop", "Bench — member of alice's yard"])
        XCTAssertEqual(inbox.state.yards.map(\.waiting), ["2 waiting", "1 waiting", "1 waiting", "1 waiting"])
        XCTAssertEqual(inbox.state.head, "Back shed · jo")

        let dir = ProcessInfo.processInfo.environment["CREW_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("crew-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await render(YardSwitchView(state: inbox.state), scene: scene, to: dir.appendingPathComponent("switch-named.png"))
    }

    /// A person with a dozen yards (footplate-ios-jyh8): their rows are
    /// taller than the sheet, so the switch scrolls, and what it holds
    /// takes in the buttons under the rows, Rename this yard among them.
    func testYardSwitchOfThirteenYardsScrollsToItsButtons() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "no window scene to render in"
        )
        let rows = (1...13).map { n in
            YardRow(
                name: "yard\(n)", title: "Yard \(n)", user: "jo", device: "phone",
                selected: n == 4, word: nil, waiting: n % 3 == 0 ? "\(n) waiting" : nil
            )
        }
        let dir = ProcessInfo.processInfo.environment["CREW_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("crew-shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let window = try await renderWindow(
            YardSwitchView(state: InboxState(head: "Yard 4 · jo", yards: rows)),
            scene: scene, to: dir.appendingPathComponent("switch-thirteen.png")
        )
        defer { window.isHidden = true }
        func scrollViews(in view: UIView) -> [UIScrollView] {
            var found = view.subviews.flatMap { scrollViews(in: $0) }
            if let scroll = view as? UIScrollView { found.append(scroll) }
            return found
        }
        let scroll = try XCTUnwrap(scrollViews(in: window).first, "the switch does not scroll")
        // Thirteen rows of 64 and three buttons of 48 are more than the
        // window is tall, and all of it is in what scrolls.
        XCTAssertGreaterThan(scroll.contentSize.height, 13 * 64 + 3 * 48)
        XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
        // Scrolled to its end, the buttons stand in view.
        scroll.contentOffset.y = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData(), "the rendered screen has no PNG")
        try png.write(to: dir.appendingPathComponent("switch-thirteen-end.png"))
        XCTAssertGreaterThan(png.count, 10000, "the rendered screen looks blank")
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

    /// As `render`, but drawing the window whole: a presented sheet
    /// stands outside the hosting view, so the hosting view alone
    /// would shoot the chat without it. `style` is the appearance from
    /// the first draw, where a navigation bar's large title takes it;
    /// the system's where none is given.
    private func renderWindow(
        _ view: some View, scene: UIWindowScene, style: UIUserInterfaceStyle = .unspecified, to file: URL
    ) async throws -> UIWindow {
        let hosting = UIHostingController(rootView: AnyView(view))
        hosting.overrideUserInterfaceStyle = style
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(1500))
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData(), "the rendered screen has no PNG")
        XCTAssertEqual(image.size, CGSize(width: 402, height: 874))
        try png.write(to: file)
        XCTAssertGreaterThan(png.count, 10000, "the rendered screen looks blank")
        return window
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
