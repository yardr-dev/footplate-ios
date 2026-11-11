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
// tab alone.
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
            notices: [Notification(seq: 11, at: "2026-10-08T09:31:00Z", kind: "noted", bead: "yd-shed", text: "yd-shed noted; see yd-links")]
        ))
        try await waitFor("the board") { [mailroom] in mailroom?.boards[""] != nil }
        model.open(yard: "", with: yardRow)
        try await waitFor("the notices") { [model] in model?.state.letters.count == 1 }
        try await waitFor("the confirmation") { [model] in model?.state.knownBeads == ["yd-links", "yd-shed"] }
        XCTAssertEqual(home.beadAsked, ["yd-shed"])
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
                text: "All quiet through the night watch.", read: true
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
            asks: Asks()
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

    private func loaded(open: [OpenAsk] = [], notices: [Footplate.Notification] = []) -> Loaded {
        Loaded(
            me: Me(user: "jo", saidBy: "phone", yard: "south"),
            head: 10,
            settings: Settings(),
            user: User(name: "jo"),
            crew: [],
            users: [],
            inbox: Inbox(),
            notifications: Notifications(notifications: notices),
            asks: Asks(open: open, decided: [])
        )
    }
}
