@testable import Footplate
import UIKit
import XCTest

// A long-press on a letter offers its whole text to copy, the
// person's own and the yard's alike; a letter with no text (an
// image alone) offers nothing. A known full id chips in mail, and an
// unknown one is asked about once: the yard confirming it chips it,
// refusing it leaves it plain, and answering nothing for want of a
// link asks again when mail next comes into view. A chip's tap
// presents the bead as a sheet over the conversation, leaving the
// tab alone. An open ask a letter names stands under it as a preview,
// by footplate's rules: a number alone where one bead carries it, the
// bead's own with `on`, once each, in the order named, and gone with
// the board that decides it.
@MainActor
final class ConversationModelTests: XCTestCase {
    private var home: FakeFollowed!
    private var mailroom: Mailroom!
    private var model: ConversationModel!

    override func setUp() {
        super.setUp()
        home = FakeFollowed()
        mailroom = Mailroom()
        mailroom.setFollowers(["": home])
        let now = parseInstant("2026-10-08T10:11:00Z")!
        model = ConversationModel(mailroom: mailroom, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
    }

    override func tearDown() {
        model.leave()
        model = nil
        mailroom = nil
        home = nil
        super.tearDown()
    }

    func testCopyMessageOffersTheLettersWholeText() {
        let rows: [(text: String, copy: String?)] = [
            ("Meet at the shed.", "Meet at the shed."),
            ("Read https://x.example/a then.", "Read https://x.example/a then."),
            ("", nil),
        ]
        for (text, copy) in rows {
            let theirs = Shown(seq: 1, mine: false, text: text, time: "09:30")
            XCTAssertEqual(copyableMessage(theirs), copy, text)
            let mine = Shown(seq: 2, mine: true, text: text, time: "09:31")
            XCTAssertEqual(copyableMessage(mine), copy, "own: \(text)")
        }
    }

    /// A known full id chips, and a closed bead chips once the yard
    /// confirms it; the yard is asked once per id the mail names, never
    /// for one the app knows or a bare suffix.
    func testKnownIdsChipAndTheYardConfirmsTheRestOnceEach() async throws {
        home.up(loaded(open: [OpenAsk(bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster")]))
        home.pages["yardmaster|0"] = Page(letters: [
            Letter(seq: 1, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "Landed yd-old; yd-links moves next, past bay w311."),
        ], more: false)
        home.holdBeadReads("yd-old", count: 1)
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the letters") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the question") { [home] in home?.beadAsked == ["yd-old"] }
        XCTAssertEqual(model.state.knownBeads, ["yd-links"])
        home.releaseBeadRead("yd-old")
        try await waitFor("the confirmation") { [model] in model?.state.knownBeads == ["yd-links", "yd-old"] }
        XCTAssertEqual(home.beadAsked, ["yd-old"], "the known id and the bare suffix are no question")
    }

    /// An id the yard refuses stays plain, and is asked once: a refusal
    /// answers the question.
    func testAnIdTheYardRefusesStaysPlainAndIsAskedOnce() async throws {
        home.beadRefuse = ApiError.refused(code: "no_bead", message: "no bead yd-old")
        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [
            Letter(seq: 1, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "Landed yd-old."),
        ], more: false)
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the letters") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the question") { [home] in home?.beadAsked == ["yd-old"] }
        XCTAssertTrue(model.state.knownBeads.isEmpty)
        // Mail coming into view again asks nothing more.
        model.leave()
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the letters again") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the second page read") { [home] in home?.completedPageCalls.count == 2 }
        XCTAssertEqual(home.beadAsked, ["yd-old"])
    }

    /// An id the yard did not answer for want of a link is asked again
    /// when mail next comes into view.
    func testAnIdUnansweredForWantOfALinkIsAskedAgain() async throws {
        home.beadRefuse = ApiError.away
        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [
            Letter(seq: 1, at: "2026-10-08T09:30:00Z", from: "yardmaster", to: "jo", text: "Landed yd-old."),
        ], more: false)
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the letters") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the first question") { [home] in home?.beadAsked == ["yd-old"] }
        try await waitFor("the first answer") { [home] in home?.beadCompleted == ["yd-old"] }
        XCTAssertTrue(model.state.knownBeads.isEmpty)
        home.beadRefuse = nil
        model.leave()
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the second question") { [home] in home?.beadAsked == ["yd-old", "yd-old"] }
        try await waitFor("the confirmation") { [model] in model?.state.knownBeads == ["yd-old"] }
    }

    /// The yard's notices name beads too: a known id chips, and an
    /// unknown one is asked once.
    func testTheYardsNoticesNameBeadsToo() async throws {
        home.up(loaded(
            open: [OpenAsk(bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster")],
            notices: [Notification(seq: 11, at: "2026-10-08T09:31:00Z", kind: "noted", bead: "yd-shed", text: "yd-shed noted; see yd-links (ask 3)")]
        ))
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: yardRow)
        try await waitFor("the notices") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the confirmation") { [model] in model?.state.knownBeads == ["yd-links", "yd-shed"] }
        XCTAssertEqual(home.beadAsked, ["yd-shed"])
        XCTAssertEqual(model.state.letters.map(\.asks), [[]], "a notice names an ask, and no preview stands under it: mail alone has them, as the desktop's")
    }

    /// Reading the state of a long conversation stays cheap
    /// (footplate-ios-g0jx): a stamp per letter once made a fresh
    /// formatter per letter, so one reading of three hundred letters
    /// cost about 67 ms on the simulator and the screen paid it once
    /// per bubble. Fifty readings that took about 3.3 s there must
    /// stay well under this bound; it is a simulator bound, not a
    /// phone's, and set loose for a slower Mac.
    func testReadingALongConversationStateStaysCheap() async throws {
        var all: [Letter] = []
        for seq in 1...300 {
            let mine = seq % 2 == 0
            all.append(Letter(
                seq: Int64(seq), at: "2026-10-08T09:30:00Z",
                from: mine ? "jo" : "yardmaster", to: mine ? "yardmaster" : "jo",
                text: seq % 10 == 0 ? "Is ask 3 on yd-links yours?" : "All quiet through the night watch.", read: true
            ))
        }
        home.up(Loaded(
            me: Me(user: "jo", saidBy: "phone", yard: "south"),
            head: 300,
            settings: Settings(),
            user: User(name: "jo"),
            crew: [CrewMember(name: "yardmaster", enabled: true, state: "running", status: "working")],
            users: [User(name: "jo")],
            inbox: Inbox(mail: all, unread: 0, last: 0, from: []),
            notifications: Notifications(),
            // An open ask the letters name: each reading finds and
            // previews it in thirty of them.
            asks: Asks(open: [OpenAsk(bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster", since: "2026-10-08T09:00:00Z")])
        ))
        func page(before: Int64) -> Page {
            let older = before > 0 ? all.filter { $0.seq < before } : all
            let slice = Array(older.suffix(30))
            return Page(letters: slice, more: older.count > slice.count)
        }
        home.pages["yardmaster|0"] = page(before: 0)
        var before: Int64 = 271
        while before > 1 {
            home.pages["yardmaster|\(before)"] = page(before: before)
            before -= 30
        }
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the first page") { [model] in model?.state.letters.count == 30 }
        var loads = 0
        while model.state.more, loads < 20 {
            loads += 1
            await model.older()
        }
        XCTAssertEqual(model.state.letters.count, 300)
        XCTAssertEqual(model.state.letters.filter { !$0.asks.isEmpty }.count, 30)
        // One reading to warm the formatters, then fifty against the clock.
        _ = model.state
        let start = ContinuousClock.now
        for _ in 0..<50 { _ = model.state.letters.count }
        let elapsed = start.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(1500), "fifty readings of a 300 letter state took \(elapsed)")
    }

    /// A chip's tap presents the bead as a sheet over the conversation
    /// and leaves the tab on the crew: nothing is pushed, nowhere
    /// switched. The sheet shuts, and never follows to another
    /// conversation.
    func testAChipsTapPresentsTheSheetAndLeavesTheTabAlone() {
        let nav = Nav()
        model.open(yard: "", with: "yardmaster")
        XCTAssertNil(model.state.sheet)
        model.openBead("yd-old")
        XCTAssertEqual(model.state.sheet, BeadRoute(yard: "", bead: "yd-old"))
        XCTAssertEqual(nav.place, .crew)
        model.closeBeadSheet()
        XCTAssertNil(model.state.sheet)
        model.openBead("yd-old")
        model.open(yard: "", with: "signalman")
        XCTAssertNil(model.state.sheet, "the sheet never follows to another conversation")
    }

    // MARK: - The asks a letter names

    /// An open ask of the queue from the yardmaster, 7 minutes old at the
    /// model's 10:11.
    private func openAsk(_ bead: String, _ ask: Int64, _ question: String = "Move the links?") -> OpenAsk {
        OpenAsk(bead: bead, ask: ask, question: question, asker: "yardmaster", since: "2026-10-08T10:04:00Z")
    }

    private func decidedAsk(_ bead: String, _ ask: Int64) -> DecidedAsk {
        DecidedAsk(bead: bead, ask: ask, question: "Move the links?", asker: "yardmaster", state: "answered")
    }

    private func mail(_ seq: Int64, _ text: String, mine: Bool = false) -> Letter {
        Letter(seq: seq, at: "2026-10-08T09:3\(seq):00Z", from: mine ? "jo" : "yardmaster", to: mine ? "yardmaster" : "jo", text: text)
    }

    /// Opens the conversation with the yardmaster over `letters` and a
    /// board holding `open` and `decided`.
    private func openConversation(_ letters: [Letter], open: [OpenAsk] = [], decided: [DecidedAsk] = []) async throws {
        home.up(loaded(open: open, decided: decided))
        home.pages["yardmaster|0"] = Page(letters: letters, more: false)
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: "yardmaster")
        try await waitFor("the letters") { [model] in model?.state.letters.count == letters.count }
    }

    /// An open ask a letter names, the person's own or another's, stands
    /// under it as the desktop shows it: its kind and number, how long it
    /// waits and the question's first line. A re-ask and a letter that
    /// names none have none.
    func testAnOpenAskALetterNamesStandsUnderIt() async throws {
        try await openConversation([
            mail(1, "I put the grant to you as a card (ask 3)."),
            mail(2, "The turn (yd-zulu) waits, and re-ask 4 stands plain."),
            mail(3, "First.\n\n- See ask 3 again.", mine: true),
        ], open: [openAsk("yardr-n8ta", 3, "Grant yardmaster replace on google-docs?\nIt reads the documents.")])
        let preview = AskPreview(bead: "yardr-n8ta", ask: 3, kind: "ask", question: "Grant yardmaster replace on google-docs?", waits: "7m")
        XCTAssertEqual(model.state.letters.map(\.asks), [[preview], [], [preview]])
        XCTAssertEqual(preview.head, "Waiting on you · ask 3 · asked 7m")
    }

    /// Several asks a letter names stand in the order its words name them,
    /// not the queue's, and one named twice stands once, however it is named.
    func testSeveralAsksStandInTheOrderNamedEachOnce() async throws {
        try await openConversation([
            mail(1, "ask 5 first, ask 3 on yd-b, ask 5 again, ask 3 and ask 2."),
            mail(2, "ask 3, then ask 5 on yd-a."),
        ], open: [openAsk("yd-a", 5), openAsk("yd-b", 3)], decided: [decidedAsk("yd-c", 2)])
        XCTAssertEqual(model.state.letters.map { $0.asks.map(\.id) }, [["yd-a 5", "yd-b 3"], ["yd-b 3", "yd-a 5"]])
    }

    /// A number two beads share, a decided ask and one the yard does not
    /// list stay plain words; with its bead a shared number is one ask
    /// again, and an ask on a bead that does not carry it is none.
    func testASharedDecidedOrUnknownAskStaysPlain() async throws {
        try await openConversation([
            mail(1, "ask 3, ask 99 and ask 2."),
            mail(2, "ask 3 on yardr-n8ta is yours."),
            mail(3, "ask 4 is open on one bead and decided on another."),
            mail(4, "ask 3 on yardr-9zzz and ask 2 on yardr-n8ta."),
        ], open: [openAsk("yardr-n8ta", 3), openAsk("yardr-3msx", 3), openAsk("yardr-4aaa", 4)],
        decided: [decidedAsk("yardr-n8ta", 2), decidedAsk("yardr-4bbb", 4)])
        XCTAssertEqual(model.state.letters.map { $0.asks.map(\.id) }, [[], ["yardr-n8ta 3"], [], []])
    }

    /// A secret ask shows the first line of its question with its kind in
    /// the head, and no value: the queue holds none. A run ask says its
    /// kind. The first line is the first that says something, in plain words.
    func testASecretAndARunAskKeepTheirKindAndTheirFirstLine() async throws {
        let secret = OpenAsk(
            bead: "yd-s", ask: 9, question: "\n  Give yardmaster the GitHub token\r\nand where it goes\u{2028}and more",
            asker: "yardmaster", since: "2026-10-08T10:11:00Z", secret: Secret(source: "github", env: ["TOKEN"], line: "The GitHub token")
        )
        let run = OpenAsk(
            bead: "yd-r", ask: 10, question: "Ring\u{7} the\tbell?",
            asker: "yardmaster", since: "2026-10-06T10:11:00Z", run: Run(command: "yardr doctor")
        )
        try await openConversation([mail(1, "ask 9 and ask 10")], open: [secret, run])
        let asks = model.state.letters[0].asks
        XCTAssertEqual(asks, [
            AskPreview(bead: "yd-s", ask: 9, kind: "secret ask", question: "Give yardmaster the GitHub token", waits: "now"),
            AskPreview(bead: "yd-r", ask: 10, kind: "run ask", question: "Ring the\tbell?", waits: "2d"),
        ])
        XCTAssertEqual(asks.map(\.head), ["Waiting on you · secret ask 9 · asked now", "Waiting on you · run ask 10 · asked 2d"])
        // A part the yard gave no word for leaves the head.
        XCTAssertEqual(AskPreview(bead: "yd-s", ask: 25527, kind: "ask", question: "", waits: "").head, "Waiting on you · ask 25527")
    }

    /// The next board takes the preview of an ask it decides, with nothing
    /// told to the conversation, and gives it back where the ask is open.
    func testThePreviewGoesWithTheNextBoardThatDecidesTheAsk() async throws {
        try await openConversation([mail(1, "Shall I land it (ask 3 on yd-links)?")], open: [openAsk("yd-links", 3)])
        XCTAssertEqual(model.state.letters[0].asks.map(\.id), ["yd-links 3"])
        home.up(loaded(open: [], decided: [decidedAsk("yd-links", 3)]))
        XCTAssertEqual(model.state.letters[0].asks, [])
        home.up(loaded(open: [openAsk("yd-links", 3)]))
        XCTAssertEqual(model.state.letters[0].asks.map(\.id), ["yd-links 3"])
    }

    /// How long an ask waits, as the desktop's `waits` says it: whole
    /// minutes under an hour, hours under a day, then days; none for a time
    /// that is none, and `now` for one still to come.
    func testHowLongAnAskWaitsIsSaidAsTheDesktopSaysIt() {
        let now = parseInstant("2026-10-08T10:11:00Z")!
        let rows: [(since: String, said: String)] = [
            ("2026-10-08T10:11:00Z", "now"),
            ("2026-10-08T10:10:01Z", "now"),
            ("2026-10-08T10:10:00Z", "1m"),
            ("2026-10-08T10:04:00Z", "7m"),
            // The yard's instants carry fractions; the desktop counts whole seconds.
            ("2026-10-08T10:04:00.9Z", "7m"),
            ("2026-10-08T09:12:00Z", "59m"),
            ("2026-10-08T09:11:00Z", "1h"),
            ("2026-10-08T08:11:00Z", "2h"),
            ("2026-10-07T10:12:00Z", "23h"),
            ("2026-10-07T10:11:00Z", "1d"),
            ("2026-10-05T10:11:00Z", "3d"),
            ("2026-10-08T10:12:30Z", "now"),
            ("", ""),
            ("yesterday", ""),
        ]
        for (since, said) in rows {
            XCTAssertEqual(waits(since, now: now), said, since)
        }
    }

    // MARK: - Helpers

    private func waitFor(_ what: String, _ match: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !match() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what)")
                throw TestTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func loaded(open: [OpenAsk] = [], decided: [DecidedAsk] = [], notices: [Footplate.Notification] = []) -> Loaded {
        Loaded(
            me: Me(user: "jo", saidBy: "phone", yard: "south"),
            head: 10,
            settings: Settings(),
            user: User(name: "jo"),
            crew: [],
            users: [],
            inbox: Inbox(),
            notifications: Notifications(notifications: notices),
            asks: Asks(open: open, decided: decided)
        )
    }
}
