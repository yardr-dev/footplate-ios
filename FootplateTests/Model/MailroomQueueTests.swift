@testable import Footplate
import XCTest

// The Mailroom's reads of a yard's queue, against followers of our own over
// a state the test writes: the open asks alone wherever the queue is read
// again, the whole queue, the decided history with it, where a screen asks
// for it; what each answer moves of a board (the open asks always, the
// history only where the answer carries it); an older answer never putting
// an older queue back; and the history a reload keeps. The calls a real
// yard sees of them are counted in `DecisionModelTests`.
@MainActor
final class MailroomQueueTests: XCTestCase {
    private var mailroom: Mailroom!
    private var home: FakeFollowed!

    private let fixedNow = parseInstant("2026-10-08T11:30:00Z")!

    private static let links = OpenAsk(bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster")
    private static let map = OpenAsk(bead: "yd-map", ask: 7, question: "Who is U024BE7LH?", asker: "yardmaster")
    private static let token = OpenAsk(bead: "yd-token", ask: 18, question: "What is the token?", asker: "yardmaster")
    private static let greet = DecidedAsk(bead: "yd-greet", ask: 5, question: "What tone?", asker: "yardmaster", state: "declined")
    private static let linksAside = DecidedAsk(
        bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster",
        state: "put aside", returnAt: "2026-10-08T12:00:00Z"
    )

    override func setUp() async throws {
        try await super.setUp()
        let now = fixedNow
        mailroom = Mailroom(now: { now })
        home = FakeFollowed()
        mailroom.setFollowers(["": home])
    }

    private var board: Board? { mailroom.boards[""] }

    private func loaded(head: Int64 = 151, user: String = "jo", asks: OpenQueue) -> Loaded {
        Loaded(
            me: Me(user: user, saidBy: "phone", yard: "laptop"), head: head, settings: Settings(),
            user: User(name: user), crew: [], users: [], inbox: Inbox(), notifications: Notifications(),
            asks: asks
        )
    }

    private func noted(_ seq: Int64) {
        home.event(Event(seq: seq, kind: "noted", actor: "yardmaster", at: "2026-10-08T11:00:00Z", bead: "yd-links"))
    }

    private func waitFor(_ what: String, _ ready: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !ready() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testANotedEventReadsTheOpenAsksAloneAndAnAnswerMovesWhatItCarries() async {
        home.up(loaded(asks: OpenQueue(open: [Self.links, Self.map])))
        XCTAssertEqual(board?.open, [Self.links, Self.map])
        XCTAssertEqual(board?.decided, [])

        // The whole read: both halves, applied whole.
        home.asksAgain = Asks(open: [Self.links, Self.map], decided: [Self.greet])
        await mailroom.fetchWhole("")
        XCTAssertEqual(home.wholeAskReads, 1)
        XCTAssertEqual(board?.decided, [Self.greet])

        // A noted event: the open asks are read, the whole queue is not,
        // and an answer with no history leaves the history held.
        home.openAsksAgain = OpenQueue(open: [Self.map])
        noted(152)
        await waitFor("the open asks") { self.board?.open == [Self.map] }
        XCTAssertEqual(home.openAskReads, 1)
        XCTAssertEqual(home.wholeAskReads, 1)
        XCTAssertEqual(board?.decided, [Self.greet], "an open-only answer never wipes the history")

        // A yard from before UserOpenAsks answers the whole queue in its
        // place: what it sent is applied, the history with it.
        home.openAsksAgain = OpenQueue(open: [Self.map, Self.token], decided: [Self.linksAside])
        noted(153)
        await waitFor("the whole answer") { self.board?.decided == [Self.linksAside] }
        XCTAssertEqual(board?.open, [Self.map, Self.token])
        XCTAssertEqual(home.wholeAskReads, 1, "the fallback is the client's: the mailroom made no whole read")

        // An ask the yard lists open is not held decided: the put-aside
        // ask that came back leaves the history with no whole read.
        home.openAsksAgain = OpenQueue(open: [Self.links, Self.map, Self.token])
        noted(154)
        await waitFor("the return") { self.board?.open.contains(Self.links) == true }
        XCTAssertEqual(board?.decided, [])

        // A noted-event read already in flight when the follower reloads
        // retries after the load instead of restoring its older open queue.
        home.holdNextOpenAsksRead = true
        home.openAsksAgain = OpenQueue(open: [Self.links, Self.map, Self.token])
        noted(155)
        await waitFor("the open read to be under way") { self.home.openAsksReadHeld }
        home.up(loaded(head: 160, asks: OpenQueue(open: [Self.map, Self.token])))
        home.openAsksAgain = OpenQueue(open: [Self.map, Self.token])
        home.releaseOpenAsksRead()
        await waitFor("the retried open read") { self.home.openAskReads == 5 }
        XCTAssertEqual(board?.open, [Self.map, Self.token])
    }

    func testASlowWholeReadNeverPutsAnOlderOpenQueueBack() async {
        home.up(loaded(asks: OpenQueue(open: [Self.links, Self.map])))
        // The whole read answers what the yard held when it was made, and
        // is slow, as on a yard with a long history.
        home.asksAgain = Asks(open: [Self.links, Self.map], decided: [Self.greet])
        home.holdNextAsksRead = true
        let whole = Task { @MainActor in await self.mailroom.fetchWhole("") }
        await waitFor("the whole read to be under way") { self.home.asksReadHeld }

        // A noted event meanwhile: the open asks, read after it, answer
        // first, with a card more.
        home.openAsksAgain = OpenQueue(open: [Self.links, Self.map, Self.token])
        noted(152)
        await waitFor("the open asks") { self.board?.open.count == 3 }

        home.releaseAsksRead()
        await whole.value
        XCTAssertEqual(board?.open, [Self.links, Self.map, Self.token], "the older open asks of the whole read are not put back")
        XCTAssertEqual(board?.decided, [Self.greet], "its history, which nothing newer has, is applied")

        // A follower load can finish while another whole read is waiting.
        // The old response must not put its open asks back, and Decide's
        // history is read whole again after the load.
        home.up(loaded(asks: OpenQueue(open: [Self.links, Self.map])))
        home.asksAgain = Asks(open: [Self.links, Self.map], decided: [Self.greet])
        home.holdNextAsksRead = true
        let wholeAfterReload = Task { @MainActor in await self.mailroom.fetchWhole("") }
        await waitFor("the whole read to be under way") { self.home.asksReadHeld }
        home.up(loaded(head: 160, asks: OpenQueue(open: [Self.map, Self.token])))
        home.asksAgain = Asks(open: [Self.map, Self.token], decided: [Self.greet])
        home.releaseAsksRead()
        await wholeAfterReload.value

        XCTAssertEqual(home.wholeAskReads, 3)
        XCTAssertEqual(board?.open, [Self.map, Self.token])
        XCTAssertEqual(board?.decided, [Self.greet])
    }

    func testAReloadKeepsTheHistoryWhereTheLoadCarriesNoneAndTakesWhatItCarries() async {
        home.up(loaded(asks: OpenQueue(open: [Self.links, Self.map])))
        home.asksAgain = Asks(open: [Self.map], decided: [Self.linksAside, Self.greet])
        await mailroom.fetchWhole("")
        XCTAssertEqual(board?.decided, [Self.linksAside, Self.greet])

        // A load of the open asks alone: the board is made again from it,
        // and holds what it held of the history.
        home.up(loaded(head: 160, asks: OpenQueue(open: [Self.map, Self.token])))
        XCTAssertEqual(board?.head, 160)
        XCTAssertEqual(board?.open, [Self.map, Self.token])
        XCTAssertEqual(board?.decided, [Self.linksAside, Self.greet])

        // One that lists the put-aside ask open again drops its held line.
        home.up(loaded(head: 170, asks: OpenQueue(open: [Self.links, Self.map])))
        XCTAssertEqual(board?.decided, [Self.greet])

        // A load that carries the history, from a yard that cannot read the
        // open asks alone, takes it in place of what was held.
        home.up(loaded(head: 180, asks: OpenQueue(open: [Self.map], decided: [Self.linksAside])))
        XCTAssertEqual(board?.decided, [Self.linksAside])

        // Another person's yard under the same name holds none of it.
        home.up(loaded(head: 190, user: "hal", asks: OpenQueue(open: [Self.map])))
        XCTAssertEqual(board?.me, "hal")
        XCTAssertEqual(board?.decided, [])
    }

    func testTheDecidePlaceReadsTheYardSelectedWhileItIsInFrontAndOnceItHasABoard() async throws {
        let edge = FakeYard()
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: edge.origin)
        records.keepSession(account: edge.email, session: edge.session())
        for name in ["north", "south", "late"] {
            records.keepYard(PairedYard(name: name, yard: name, user: "jo", device: "phone", token: "yardr-dev-\(name)-1"))
        }
        let north = FakeFollowed()
        let south = FakeFollowed()
        let late = FakeFollowed()
        let room = Mailroom()
        room.setFollowers(["north": north, "south": south, "late": late])
        north.up(loaded(asks: OpenQueue(open: [Self.links])))
        south.up(loaded(asks: OpenQueue(open: [Self.map])))
        let nav = Nav(place: .crew)
        let list = DecisionsModel(records: records, mailroom: room, nav: nav)

        // Not while another place is in front.
        records.select("north")
        XCTAssertNil(list.reading)
        await list.read()
        XCTAssertEqual(north.wholeAskReads, 0)

        // The place appears: the selected yard's whole queue is read, and
        // another's is not.
        nav.place = .decide
        XCTAssertEqual(list.reading, "north")
        await list.read()
        XCTAssertEqual([north.wholeAskReads, south.wholeAskReads], [1, 0])

        // The yard selected changing under it is a new key: the new yard's.
        records.select("south")
        XCTAssertEqual(list.reading, "south")
        await list.read()
        XCTAssertEqual([north.wholeAskReads, south.wholeAskReads], [1, 1])

        // A yard with no board has nothing to put the history on; its first
        // board arriving, with the place in front, is a new key too.
        records.select("late")
        XCTAssertNil(list.reading)
        await list.read()
        XCTAssertEqual(late.wholeAskReads, 0)
        late.up(loaded(asks: OpenQueue(open: [Self.token])))
        XCTAssertEqual(list.reading, "late")
    }
}
