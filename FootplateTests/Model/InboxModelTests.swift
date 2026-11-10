@testable import Footplate
import XCTest

// The inbox and conversation models against plain state (design
// 3.5): followers of our own over a YardState the test writes, as
// the session would, and the calls a screen makes recorded. The rows
// newest letter first, unread counted and cleared by an
// acknowledgement, the events moving them, a conversation read a
// page at a time and written to, the head row's words, the yard
// switch, and a yard of another account's labelled with its owner and
// forgotten, with one sentence, once the owner removed the account.
@MainActor
final class InboxModelTests: XCTestCase {
    private var fake: FakeYard!
    private var secret: MemoryShelf!
    private var plain: MemoryShelf!
    private var records: Records!
    private var nav: Nav!
    private var home: FakeFollowed!
    private var laptop: FakeFollowed!
    private var mailroom: Mailroom!
    private var pairer: Pairer!
    private var picturesDir: URL!

    private let fixedNow = parseInstant("2026-10-08T12:00:00Z")!

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeYard()
        secret = MemoryShelf()
        plain = MemoryShelf()
        records = makeRecords()
        nav = Nav()
        home = FakeFollowed()
        laptop = FakeFollowed()
        mailroom = Mailroom()
        mailroom.setFollowers(["": home, "laptop": laptop])
        pairer = Pairer(edge: try fake.edge(), records: records)
        picturesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pictures-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let picturesDir {
            try? FileManager.default.removeItem(at: picturesDir)
        }
        try await super.tearDown()
    }

    private func makeRecords() -> Records {
        let made = Records(secret: secret, plain: plain, origin: fake.origin)
        if made.kept.account == nil {
            made.keepSession(account: fake.email, session: fake.session())
            made.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: "yardr-dev-laptop-1"))
            made.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        }
        return made
    }

    private func inbox(records: Records? = nil) -> InboxModel {
        let now = fixedNow
        return InboxModel(
            pairer: pairer, records: records ?? self.records,
            followers: { ["": self.home, "laptop": self.laptop] },
            mailroom: mailroom, nav: nav,
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
    }

    private func conversation(shrink: @escaping @Sendable (Data) -> Data? = { $0 }) -> ConversationModel {
        let now = fixedNow
        return ConversationModel(
            mailroom: mailroom, pictures: Pictures(directory: picturesDir), shrink: shrink,
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
    }

    private func waitFor(_ what: String, match: (InboxState) -> Bool) async -> InboxState {
        let model = inbox()
        return await waitFor(what, state: { model.state }, match: match)
    }

    private func waitFor<T>(_ what: String, state: @escaping @MainActor () -> T, match: (T) -> Bool) async -> T {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let value = state()
            if match(value) { return value }
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what); last=\(value)")
                return value
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitAcks(_ fake: FakeFollowed, _ count: Int) async -> [Int64] {
        let deadline = ContinuousClock.now + .seconds(10)
        while fake.acks.count < count {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(count) acks; saw \(fake.acks)")
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return fake.acks
    }

    func testRowsOrderedByNewestLetterAndUnreadCountedInWords() async {
        home.up(loaded())
        let model = inbox()
        let state = await waitFor("the rows", state: { model.state }) { !$0.rows.isEmpty }
        XCTAssertEqual(state.head, "south · jo")
        // signalman wrote last (40), then yardmaster (14); relief and
        // jo have no letter, and keep the crew's and the users'
        // order; the yard's row is first, with unread notices.
        XCTAssertEqual(state.rows.map(\.name), ["yard", "signalman", "yardmaster", "relief", "jo"])
        let yard = state.rows[0]
        XCTAssertEqual(yard.line, "yd-shed noted (all) by yardmaster note=1")
        XCTAssertEqual(yard.unread, "1 unread")
        let signalman = state.rows[1]
        XCTAssertEqual(signalman.line, "Read the diff when you can.")
        XCTAssertNil(signalman.unread)
        XCTAssertEqual(signalman.state, "not logged in")
        let yardmaster = state.rows[2]
        XCTAssertEqual(yardmaster.line, "Or after Friday?")
        XCTAssertEqual(yardmaster.time, "09:30")
        XCTAssertEqual(yardmaster.unread, "2 unread")
        XCTAssertEqual(yardmaster.state, waitingOnYou)
        XCTAssertTrue(yardmaster.waiting)
        XCTAssertEqual(state.rows[3].state, "idle")
        XCTAssertNil(state.rows[4].state)
    }

    func testUnreadClearedByAnAcknowledgementThroughNewestShown() async {
        home.up(loaded())
        let model = inbox()
        _ = await waitFor("the rows", state: { model.state }) { !$0.rows.isEmpty }
        model.open("yardmaster")
        XCTAssertEqual(nav.crewPath, [ConversationRoute(yard: "", with: "yardmaster")])
        model.open("yardmaster")
        XCTAssertEqual(nav.crewPath.count, 1, "opening what is open pushes nothing more")
        nav.crewPath.removeLast()
        XCTAssertEqual(nav.crewPath, [])
        model.open("yardmaster")
        let conversation = conversation()
        conversation.open(yard: "", with: "yardmaster")
        // Opening the conversation acknowledges what it shows.
        let acks = await waitAcks(home, 1)
        XCTAssertEqual(acks, [14])
        let rows = await waitFor("the unread cleared", state: { model.state }) {
            $0.rows.first { $0.name == "yardmaster" }?.unread == nil
        }
        XCTAssertNil(rows.rows.first { $0.name == "yardmaster" }?.unread)
        // Another client's acknowledgement clears the rest.
        home.event(event(160, "mail", "signalman", ["to": .string("jo"), "to_user": .bool(true), "text": .string("One more.")]))
        _ = await waitFor("signalman unread", state: { model.state }) {
            $0.rows.first { $0.name == "signalman" }?.unread == "1 unread"
        }
        home.event(event(161, "mail_read", "jo", ["reader": .string("jo"), "through": .int(160)]))
        _ = await waitFor("signalman read", state: { model.state }) {
            $0.rows.first { $0.name == "signalman" }?.unread == nil
        }
        conversation.leave()
    }

    func testAcknowledgementStopsShortOfAnUnreadLetterNotShown() async {
        // One position stands for every sender: shown yardmaster's
        // 14, the acknowledgement may not pass signalman's unread 11.
        home.up(loaded(unreadFromSignalman: true))
        let model = inbox()
        _ = await waitFor("the rows", state: { model.state }) { !$0.rows.isEmpty }
        let conversation = conversation()
        conversation.open(yard: "", with: "yardmaster")
        let rows = await waitFor("yardmaster seen", state: { model.state }) {
            $0.rows.first { $0.name == "yardmaster" }?.unread == nil
        }
        XCTAssertEqual(rows.rows.first { $0.name == "signalman" }?.unread, "1 unread")
        XCTAssertEqual(home.acks, [])
        conversation.open(yard: "", with: "signalman")
        let acks = await waitAcks(home, 1)
        XCTAssertEqual(acks, [14])
        conversation.leave()
    }

    func testMailEventMovesItsRowToTheTop() async throws {
        home.up(loaded(notices: false))
        let model = inbox()
        _ = await waitFor("the rows", state: { model.state }) { !$0.rows.isEmpty }
        home.event(event(155, "mail", "relief", ["to": .string("jo"), "to_user": .bool(true), "text": .string("Back at four.\nThe fence after.")]))
        let state = await waitFor("relief on top", state: { model.state }) { $0.rows.first?.name == "relief" }
        XCTAssertEqual(state.rows[0].line, "Back at four.")
        XCTAssertEqual(state.rows[0].unread, "1 unread")
        // A letter the person sent moves its row too, and counts no
        // unread.
        home.event(event(156, "mail", "jo", ["to": .string("yardmaster"), "text": .string("Land it.")]))
        let again = await waitFor("yardmaster on top", state: { model.state }) { $0.rows.first?.name == "yardmaster" }
        XCTAssertEqual(again.rows[0].line, "Land it.")
        XCTAssertEqual(again.rows[0].unread, "2 unread")

        // Mail to a party of a linked yard has `to_peer`. Another's is
        // none of this inbox's: no letter, no row.
        let lettersBefore = mailroom.boards[""]?.letters
        home.event(event(157, "mail", "relief", ["to": .string("yardmaster"), "to_peer": .string("yardr"), "text": .string("Not the person's.")]))
        XCTAssertEqual(mailroom.boards[""]?.applied, 157)
        XCTAssertEqual(mailroom.boards[""]?.letters, lettersBefore)
        XCTAssertEqual(model.state.rows.map(\.name), again.rows.map(\.name))
        // The person's own is a letter of the conversation with
        // <to>@<to_peer>, a row of its own, and not the yardmaster's
        // of this yard nor an unread.
        home.event(event(158, "mail", "jo", ["to": .string("yardmaster"), "to_peer": .string("yardr"), "text": .string("Land it on your side."), "id": .string("m-1")]))
        let peer = await waitFor("the linked yard's party on top", state: { model.state }) { $0.rows.first?.name == "yardmaster@yardr" }
        XCTAssertEqual(peer.rows.map(\.name), ["yardmaster@yardr", "yardmaster", "relief", "signalman", "jo", "yard"])
        XCTAssertEqual(peer.rows[0].line, "Land it on your side.")
        XCTAssertEqual(peer.rows[0].time, "11:00")
        XCTAssertNil(peer.rows[0].unread)
        XCTAssertNil(peer.rows[0].state)
        XCTAssertEqual(peer.rows[1].line, "Land it.")
        XCTAssertEqual(peer.rows[1].unread, "2 unread")
        let board = try XCTUnwrap(mailroom.boards[""])
        XCTAssertEqual(board.lettersWith("yardmaster@yardr").map { "\($0.seq)|\($0.from)|\($0.to)" }, ["158|jo|yardmaster@yardr"])
        XCTAssertEqual(board.lettersWith("yardmaster").map(\.seq), [13, 14, 156])
        XCTAssertEqual(board.unread.keys.sorted(), [13, 14, 155])

        // Open, the conversation with that address shows the person's
        // next letter to it at once, with no page read to bring it.
        let conversation = conversation()
        conversation.open(yard: "", with: "yardmaster@yardr")
        let opened = await waitFor("the conversation with the party", state: { conversation.state }) { !$0.letters.isEmpty }
        XCTAssertEqual(opened.title, "yardmaster@yardr")
        XCTAssertEqual(opened.letters.map(\.seq), [158])
        XCTAssertEqual(opened.letters.map(\.mine), [true])
        home.event(event(159, "mail", "jo", ["to": .string("yardmaster"), "to_peer": .string("yardr"), "text": .string("And the fence.")]))
        let shown = await waitFor("the next letter", state: { conversation.state }) { $0.letters.count == 2 }
        XCTAssertEqual(shown.letters.map(\.seq), [158, 159])
        XCTAssertEqual(shown.letters.map(\.mine), [true, true])
        XCTAssertEqual(home.asked.map { "\($0.0)|\($0.1)" }, ["yardmaster@yardr|0"])
        conversation.leave()
    }

    func testOlderPageReadOnScrollUpWhileYardHasMore() async {
        var scroll = ConversationScrollTracking()
        XCTAssertFalse(scroll.update(ConversationScrollEdges(atTop: true, atFoot: true, hasOlder: true)))
        XCTAssertFalse(scroll.update(ConversationScrollEdges(atTop: false, atFoot: false, hasOlder: true)))
        XCTAssertTrue(scroll.update(ConversationScrollEdges(atTop: true, atFoot: false, hasOlder: true)))
        XCTAssertFalse(scroll.update(ConversationScrollEdges(atTop: true, atFoot: false, hasOlder: true)))
        XCTAssertFalse(scroll.follows(mine: false), "new mail does not pull a person away from older letters")
        XCTAssertTrue(scroll.follows(mine: true), "a letter sent from another position follows the newest end")

        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [letter(40, "yardmaster", "jo", "Forty."), letter(41, "jo", "yardmaster", "Forty-one.")], more: true)
        home.pages["yardmaster|40"] = Page(letters: [letter(13, "yardmaster", "jo", "Thirteen."), letter(14, "yardmaster", "jo", "Fourteen.")], more: false)
        let conversation = conversation()
        conversation.open(yard: "", with: "yardmaster")
        let first = await waitFor("the newest page", state: { conversation.state }) { !$0.letters.isEmpty }
        XCTAssertEqual(first.letters.map(\.seq), [40, 41])
        XCTAssertTrue(first.more)
        XCTAssertEqual(first.letters.map(\.mine), [false, true])
        XCTAssertEqual(first.state, waitingOnYou)
        XCTAssertTrue(first.waiting)
        // The unread mail is on the older page: merely opening the
        // row cannot acknowledge it before that page is shown.
        XCTAssertEqual(home.acks, [])
        await conversation.older()
        let older = await waitFor("the older page", state: { conversation.state }) { $0.letters.count == 4 }
        XCTAssertEqual(older.letters.map(\.seq), [13, 14, 40, 41])
        XCTAssertFalse(older.more)
        XCTAssertEqual(home.asked.map { "\($0.0)|\($0.1)" }, ["yardmaster|0", "yardmaster|40"])
        let acks = await waitAcks(home, 1)
        XCTAssertEqual(acks, [14])
        // Nothing older: scrolling up again asks nothing.
        await conversation.older()
        XCTAssertEqual(home.asked.count, 2)

        // A read from a conversation that left the screen cannot clear
        // the loading state of the same conversation when it comes back.
        // Reopening reads the newest page again even at the same head.
        home.holdPageCalls([3, 4])
        conversation.leave()
        conversation.open(yard: "", with: "yardmaster")
        _ = await waitFor("the third page call", state: { self.home.asked.count }) { $0 >= 3 }
        XCTAssertTrue(conversation.state.reading)
        conversation.leave()
        conversation.open(yard: "", with: "yardmaster")
        _ = await waitFor("the fourth page call", state: { self.home.asked.count }) { $0 >= 4 }
        XCTAssertTrue(conversation.state.reading)
        home.releasePageCall(3)
        _ = await waitFor("the stale page call to finish", state: { self.home.completedPageCalls.count }) { $0 >= 3 }
        for _ in 0..<3 { await Task.yield() }
        XCTAssertTrue(conversation.state.reading)
        home.releasePageCall(4)
        _ = await waitFor("the current page call to finish", state: { conversation.state }) { !$0.reading }
        conversation.leave()
    }

    func testLetterSentAppearsOnceWhenItsEventComes() async {
        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [letter(13, "yardmaster", "jo", "Thirteen."), letter(14, "yardmaster", "jo", "Fourteen.")], more: false)
        let conversation = conversation()
        conversation.open(yard: "", with: "yardmaster")
        _ = await waitFor("the page", state: { conversation.state }) { !$0.letters.isEmpty }
        conversation.draft("Land it.")
        home.holdNextMail = true
        let sending = Task { await conversation.send() }
        _ = await waitFor("the mail call", state: { self.home.mailCalls }) { $0 == 1 }
        conversation.leave()
        conversation.open(yard: "", with: "signalman")
        conversation.draft("Land it.")
        home.releaseMail()
        await sending.value
        XCTAssertEqual(home.sent.map { "\($0.0)|\($0.1)" }, ["yardmaster|Land it."])
        XCTAssertEqual(conversation.state.draft, "Land it.", "a send in another conversation leaves this draft alone")
        XCTAssertFalse(conversation.state.sending)
        XCTAssertNil(conversation.state.error)
        conversation.leave()
        conversation.open(yard: "", with: "yardmaster")
        _ = await waitFor("the reopened page", state: { conversation.state }) { !$0.letters.isEmpty }
        let sent = await waitFor("the field emptied", state: { conversation.state }) { $0.draft.isEmpty && !$0.sending }
        // Not shown before the yard says it is a letter.
        XCTAssertEqual(sent.letters.map(\.seq), [13, 14])
        home.event(event(170, "mail", "jo", ["to": .string("yardmaster"), "text": .string("Land it.")]))
        let shown = await waitFor("the letter", state: { conversation.state }) { $0.letters.count == 3 }
        XCTAssertEqual(shown.letters.map(\.seq), [13, 14, 170])
        XCTAssertTrue(shown.letters[2].mine)
        // The yard read again after the app came back has it in its
        // page too: it is still shown once.
        home.pages["yardmaster|0"] = Page(letters: [letter(14, "yardmaster", "jo", "Fourteen."), letter(170, "jo", "yardmaster", "Land it.")], more: false)
        home.up(loaded(head: 170))
        let deadline = ContinuousClock.now + .seconds(10)
        while home.asked.count < 2, ContinuousClock.now <= deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(home.asked.count, 2)
        let again = await waitFor("read again", state: { conversation.state }) { !$0.reading }
        XCTAssertEqual(again.letters.map(\.seq), [13, 14, 170])
        conversation.leave()
    }

    func testAskingTheYardmasterStartsTheDraftWithTheBead() async {
        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [letter(13, "yardmaster", "jo", "Thirteen.")], more: false)
        let conversation = conversation()
        // The card's Ask is taken before the screen is shown: the open
        // that follows starts the draft with the bead.
        conversation.askAbout(yard: "", bead: "yd-train")
        conversation.open(yard: "", with: "yardmaster")
        XCTAssertEqual(conversation.state.draft, "yd-train ")
        // Written on, left, and asked again about the same bead: the
        // bead stays the first words, once.
        conversation.draft("yd-train when is it green?")
        conversation.leave()
        conversation.askAbout(yard: "", bead: "yd-train")
        conversation.open(yard: "", with: "yardmaster")
        XCTAssertEqual(conversation.state.draft, "yd-train when is it green?")
        // Asked about another bead with words already there: its id goes
        // first, keeping what is there.
        conversation.leave()
        conversation.askAbout(yard: "", bead: "yd-shed")
        conversation.open(yard: "", with: "yardmaster")
        XCTAssertEqual(conversation.state.draft, "yd-shed yd-train when is it green?")
        // An Ask for another conversation is not this one's draft, and
        // the next open takes it: none is held for a later one.
        conversation.leave()
        conversation.askAbout(yard: "", bead: "yd-gate")
        conversation.open(yard: "", with: "signalman")
        XCTAssertEqual(conversation.state.draft, "")
        conversation.leave()
        conversation.open(yard: "", with: "yardmaster")
        XCTAssertEqual(conversation.state.draft, "")
        // Nor is another yard's.
        conversation.leave()
        conversation.askAbout(yard: "laptop", bead: "yd-gate")
        conversation.open(yard: "", with: "yardmaster")
        XCTAssertEqual(conversation.state.draft, "")
        // Asked while the conversation is shown already: the draft takes
        // it at once, for no open comes.
        conversation.askAbout(yard: "", bead: "yd-gate")
        conversation.open(yard: "", with: "yardmaster")
        XCTAssertEqual(conversation.state.draft, "yd-gate ")
        conversation.leave()

        XCTAssertEqual(askDraft("yd-train", bead: "yd-train"), "yd-train ")
        XCTAssertEqual(askDraft("yd-train when?", bead: "yd-train"), "yd-train when?")
        XCTAssertEqual(askDraft("yd-trainer", bead: "yd-train"), "yd-train yd-trainer")
        XCTAssertEqual(askDraft("hello", bead: "yd-shed"), "yd-shed hello")
        XCTAssertEqual(askDraft("", bead: "yd-shed"), "yd-shed ")
    }

    func testYardRowOpensItsNoticesWithNoFieldAndAcknowledgesThem() async {
        home.up(loaded())
        let conversation = conversation()
        conversation.open(yard: "", with: yardRow)
        let state = await waitFor("the notices", state: { conversation.state }) { !$0.letters.isEmpty }
        XCTAssertEqual(state.letters.map(\.seq), [10, 11])
        XCTAssertFalse(state.writable)
        let deadline = ContinuousClock.now + .seconds(10)
        while home.noticeAcks.count < 1, ContinuousClock.now <= deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(home.noticeAcks, [11])
        conversation.leave()
    }

    func testHeadRowSaysTheFollowsStateInWords() async {
        let model = inbox()
        let words: [(FollowStatus, String?, HeadAction?)] = [
            (.starting, nil, nil),
            (.up, nil, nil),
            (.down(words: "The yard is away: the edge cannot reach it.", short: "yard away"), "yard away", nil),
            (.down(words: "The yard is busy.", short: "yard busy"), "yard busy", nil),
            (.down(words: "The yard is not ready.", short: "yard not ready"), "yard not ready", nil),
            (.down(words: "The edge is down.", short: "edge down"), "edge down", nil),
            (.down(words: "Nothing answers.", short: "nothing answers"), "nothing answers", nil),
            (.pairAgain(words: "Pair it again."), "pair again", .pairAgain),
            (.signInAgain(words: "Sign in again."), "sign in again", .signInAgain),
        ]
        for (status, word, action) in words {
            home.state.status = status
            let state = await waitFor("\(status)", state: { model.state }) { $0.word == word }
            XCTAssertEqual(state.action, action, "\(status)")
        }
    }

    func testAYardOfItsOwnIsNeverSignedOut() {
        // No account kept: the edge yard asks to sign in, the direct
        // yard has no session to run out of.
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let direct = Records(secret: secret, plain: plain, origin: fake.origin)
        direct.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: "yardr-dev-laptop-1"))
        direct.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1", origin: "https://yard.example.net"))
        laptop.state.status = .up
        home.state.status = .up
        let model = inbox(records: direct)
        let state = model.state
        XCTAssertEqual(state.head, "south · jo")
        XCTAssertNil(state.word)
        XCTAssertNil(state.action)
        let rows = Dictionary(uniqueKeysWithValues: state.yards.map { ($0.name, $0) })
        XCTAssertEqual(rows["laptop"]?.word, "sign in again")
        XCTAssertNil(rows[""]?.word)
    }

    func testTheDemoYardsSwitchLeavesInPlaceOfPairingAnother() {
        // The demo's model is made with its way out: the switch offers
        // that, and pairing another yard is leaving for the Pair screen.
        var left = 0
        let now = fixedNow
        let demo = InboxModel(
            pairer: pairer, records: records,
            followers: { ["": self.home, "laptop": self.laptop] },
            mailroom: mailroom, nav: nav, leave: { left += 1 },
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        XCTAssertTrue(demo.state.demo)
        demo.pairAnother()
        XCTAssertEqual(left, 1)
        XCTAssertFalse(nav.pairing)
        // The app's own model pairs another yard, as ever.
        let live = inbox()
        XCTAssertFalse(live.state.demo)
        live.pairAnother()
        XCTAssertTrue(nav.pairing)
        XCTAssertEqual(left, 1)
    }

    func testSwitchSaysWhatWaitsAndForgettingClearsOnlyThatYardsRoutes() async {
        // The row offers QR re-pairing only for a pinned in-place
        // migration; a newly paired device remains not yet sealed too,
        // but has no migration to replace.
        let channelRecords = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        channelRecords.keepSession(account: fake.email, session: fake.session())
        channelRecords.keepYard(PairedYard(
            name: "migrated", yard: "migrated", user: "jo", device: "phone", token: "migration-token",
            channelPrivate: Data(repeating: 0x11, count: 32),
            yardChannelPublic: Data(repeating: 0x22, count: 32), sealedHow: "in place"
        ))
        channelRecords.keepYard(PairedYard(
            name: "new-pair", yard: "new-pair", user: "jo", device: "phone", token: "paired-token",
            channelPrivate: Data(repeating: 0x33, count: 32),
            yardChannelPublic: Data(repeating: 0x44, count: 32), sealedHow: "paired"
        ))
        let channelRows = Dictionary(uniqueKeysWithValues: inbox(records: channelRecords).state.yards.map { ($0.name, $0) })
        XCTAssertEqual(channelRows["migrated"]?.channelNote, "not yet sealed")
        XCTAssertTrue(channelRows["migrated"]?.canPairAgainByQR == true)
        XCTAssertEqual(channelRows["new-pair"]?.channelNote, "not yet sealed")
        XCTAssertFalse(channelRows["new-pair"]?.canPairAgainByQR ?? true)

        home.up(loaded())
        laptop.state.status = .down(words: "The yard is away: the edge cannot reach it.", short: "yard away")
        let model = inbox()
        // The switch sheet and Forget's confirmation stand open.
        XCTAssertFalse(nav.yardListShown)
        XCTAssertFalse(nav.confirmingForget)
        nav.yardListShown = true
        nav.confirmingForget = true
        let state = await waitFor("the switch", state: { model.state }) { s in s.yards.contains { $0.waiting != nil } }
        let south = state.yards.first { $0.name == "" }!
        XCTAssertEqual(south.waiting, "2 waiting")
        XCTAssertEqual(state.waiting, 2)
        XCTAssertNil(south.word)
        XCTAssertTrue(south.selected)
        let away = state.yards.first { $0.name == "laptop" }!
        XCTAssertEqual(away.word, "yard away")
        XCTAssertNil(away.waiting)
        model.select("laptop")
        let selected = await waitFor("laptop selected", state: { model.state }) { $0.head == "laptop · jo" }
        XCTAssertEqual(selected.word, "yard away")
        XCTAssertEqual(selected.nothing, "Nothing from laptop yet: yard away")
        XCTAssertEqual(selected.rows, [])
        XCTAssertEqual(selected.waiting, 0)

        nav.crewPath = [ConversationRoute(yard: "laptop", with: "yardmaster")]
        nav.decidePath = [DecisionRoute(yard: "", bead: "yd-map", ask: 7)]
        nav.linesPath = [
            .line(LineRoute(yard: "laptop", depot: "yard", flow: "default")),
            .bead(BeadRoute(yard: "laptop", bead: "yd-train")),
        ]
        await model.forget()
        XCTAssertEqual(nav.crewPath, [])
        XCTAssertEqual(nav.decidePath, [DecisionRoute(yard: "", bead: "yd-map", ask: 7)])
        XCTAssertEqual(nav.linesPath, [])
        XCTAssertEqual(records.kept.yards.map(\.name), [""])
        // Yards stand: the switch and its confirmation are untouched.
        XCTAssertTrue(nav.yardListShown)
        XCTAssertTrue(nav.confirmingForget)

        // The last yard forgotten clears every stack for the Pair root.
        nav.linesPath = [.bead(BeadRoute(yard: "", bead: "yd-train"))]
        await model.forget()
        XCTAssertEqual(nav.decidePath, [])
        XCTAssertEqual(nav.linesPath, [])
        XCTAssertEqual(records.kept.yards.map(\.name), [])
        // The tabs go with it: the switch and its confirmation shut.
        XCTAssertFalse(nav.yardListShown)
        XCTAssertFalse(nav.confirmingForget)
    }

    func testAMemberYardSaysWhoseYardItIsInTheHeadLineAndTheSwitch() {
        // The account's own yards read as they did; a yard of another
        // account's has its owner beside its name, and the user the device
        // calls as after it.
        records.keepYard(PairedYard(name: "alice/lab", yard: "lab", user: "joe", device: "phone", token: "yardr-dev-lab-1"))
        let model = inbox()
        var state = model.state
        XCTAssertEqual(state.head, "lab — member of alice's yard · joe")
        XCTAssertEqual(state.yards.map(\.title), ["laptop", "south", "lab — member of alice's yard"])
        XCTAssertEqual(state.yards.map(\.user), ["jo", "jo", "joe"])
        XCTAssertEqual(state.yards.map(\.selected), [false, false, true])
        // The name the person gives it stands in place of the yard's own,
        // with the note beside it; clearing it brings the yard's own back.
        XCTAssertEqual(model.renaming()?.given, "")
        XCTAssertEqual(model.renaming()?.original, "lab")
        model.rename("Bench")
        state = model.state
        XCTAssertEqual(state.head, "Bench — member of alice's yard · joe")
        XCTAssertEqual(state.yards.map(\.title), ["laptop", "south", "Bench — member of alice's yard"])
        XCTAssertEqual(model.renaming()?.given, "Bench")
        XCTAssertEqual(model.renaming()?.original, "lab")
        model.rename("  ")
        XCTAssertEqual(model.state.head, "lab — member of alice's yard · joe")
        XCTAssertEqual(model.renaming()?.given, "")
        model.select("")
        state = model.state
        XCTAssertEqual(state.head, "south · jo")
        model.select("laptop")
        XCTAssertEqual(model.state.head, "laptop · jo")
    }

    func testAMemberYardTheOwnerRemovedLeavesWithOneSentence() async throws {
        let sentence = removedWords(owner: "alice", yard: "lab")
        XCTAssertEqual(sentence, "alice removed your access to lab.")
        records.keepYard(PairedYard(name: "alice/lab", yard: "lab", user: "joe", device: "phone", token: fake.token(yardName: "alice/lab")))
        nav.crewPath = [ConversationRoute(yard: "alice/lab", with: "yardmaster")]
        nav.decidePath = [DecisionRoute(yard: "", bead: "yd-map", ask: 7)]
        let model = inbox()
        let requests = fake.requestCount

        await model.removed("alice/lab", sentence)
        // The yard has left the switch and its screens, and the other
        // yards stand; the session stays for them, and is not asked about.
        XCTAssertEqual(model.state.yards.map(\.name), ["laptop", ""])
        XCTAssertEqual(records.kept.yards.map(\.name), ["laptop", ""])
        XCTAssertNil(secret.map["yard:alice/lab"])
        XCTAssertEqual(model.state.head, "laptop · jo")
        XCTAssertEqual(nav.crewPath, [])
        XCTAssertEqual(nav.decidePath, [DecisionRoute(yard: "", bead: "yd-map", ask: 7)])
        XCTAssertEqual(fake.requestCount, requests)
        // With the one sentence, which the person puts away.
        XCTAssertEqual(model.state.notice, sentence)
        // A second refusal from a yard that left says nothing more.
        model.dismissNotice()
        await model.removed("alice/lab", sentence)
        XCTAssertNil(model.state.notice)
        // Picking another yard puts it away too, and so does pairing one.
        await model.removed("laptop", "x")
        XCTAssertEqual(model.state.notice, "x")
        model.select("")
        XCTAssertNil(model.state.notice)
        nav.notice = "y"
        nav.didPair()
        XCTAssertNil(nav.notice)

        // Where it was the last yard, the session ends with it, as it
        // does when the last yard is forgotten, and the Pair screen says
        // the sentence where the tabs were.
        let lone = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        let session = fake.session()
        lone.keepSession(account: fake.email, session: session)
        lone.keepYard(PairedYard(name: "alice/lab", yard: "lab", user: "joe", device: "phone", token: fake.token(yardName: "alice/lab")))
        let loneNav = Nav()
        let lonePairer = Pairer(edge: try fake.edge(), records: lone)
        let loneModel = InboxModel(pairer: lonePairer, records: lone, followers: { [:] }, mailroom: Mailroom(), nav: loneNav)
        let pair = PairModel(pairer: lonePairer, records: lone, nav: loneNav)
        let before = fake.requestCount
        await loneModel.removed("alice/lab", sentence)
        XCTAssertEqual(lone.kept, Kept())
        let sent = Array(fake.allRequests[before...])
        XCTAssertEqual(sent.map(\.path), ["/kratos/self-service/logout/api"])
        XCTAssertEqual(sent.first?.bodyObject()["session_token"] as? String, session)
        XCTAssertEqual(pair.notice, sentence)
        pair.dismissNotice()
        XCTAssertNil(pair.notice)
    }

    func testSelectionSurvivesARestartOfTheModel() async {
        inbox().select("laptop")
        // The process again: the records read anew from the same
        // shelves, and a new model.
        let again = inbox(records: makeRecords())
        XCTAssertEqual(again.state.head, "laptop · jo")
        XCTAssertTrue(again.state.yards.first { $0.name == "laptop" }!.selected)

        // So does the name the person gave a yard: the head line, the
        // switch's rows and the sentences that name the yard call it so.
        again.rename("Back shed")
        let renamed = inbox(records: makeRecords())
        let state = renamed.state
        XCTAssertEqual(state.head, "Back shed · jo")
        XCTAssertEqual(state.yards.first { $0.name == "laptop" }?.title, "Back shed")
        XCTAssertEqual(state.yards.first { $0.name == "" }?.title, "south")
        XCTAssertEqual(state.nothing, "Nothing from Back shed yet")
        XCTAssertEqual(
            renamed.forgetting(),
            "footplate forgets Back shed. The device stays at the yard until its operator runs yardr user device rm jo pixel"
        )
    }

    func testCrewEventChangesTheStateWord() async {
        home.up(loaded())
        let model = inbox()
        _ = await waitFor("the rows", state: { model.state }) { !$0.rows.isEmpty }
        home.event(event(158, "crew_status", "", ["crew": .string("relief"), "status": .string("working")]))
        _ = await waitFor("relief working", state: { model.state }) {
            $0.rows.first { $0.name == "relief" }?.state == "working"
        }
        // One that says less than what changed reads the crew again.
        home.crewAgain = [CrewMember(name: "relief", enabled: true, state: "stopped", status: "", loginScreen: false)]
        home.holdNextCrewRead = true
        home.event(event(159, "crew_stopped", "", ["crew": .string("relief")]))
        _ = await waitFor("the crew reread", state: { self.home.crewReadCount }) { $0 == 1 }

        // A read from a follower removed while it was waiting cannot
        // overwrite a replacement yard with the same edge name.
        let replacement = FakeFollowed()
        var replacementLoaded = loaded()
        replacementLoaded.crew = replacementLoaded.crew.map { member in
            member.name == "relief"
                ? CrewMember(name: member.name, enabled: member.enabled, state: member.state, status: "working", loginScreen: member.loginScreen)
                : member
        }
        replacement.up(replacementLoaded)
        mailroom.setFollowers(["": replacement, "laptop": laptop])
        home.releaseCrewRead()
        _ = await waitFor("the removed follower's read", state: { self.home.completedCrewReads }) { $0 == 1 }
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(mailroom.boards[""]?.stateOf("relief"), "working")
    }

    func testFilesInALetterAreSaidByCount() async {
        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [
            letter(70, "yardmaster", "jo", "Seventy.", files: [BlobRef(hash: String(repeating: "bb", count: 32), kind: "text/plain", bytes: 4, name: "notes.txt")]),
            letter(71, "yardmaster", "jo", "Seventy-one.", files: [BlobRef(hash: String(repeating: "cc", count: 32), kind: "image/jpeg", bytes: 70, name: "gone.jpg")]),
        ], more: false)
        let conversation = conversation()
        conversation.open(yard: "", with: "yardmaster")
        let shown = await waitFor("the lines", state: { conversation.state }) {
            $0.letters.count >= 2 && $0.letters.first { $0.seq == 71 }?.images.first?.missed == true
        }
        let text = shown.letters.first { $0.seq == 70 }
        XCTAssertEqual(text?.files, "1 file, open it in footplate")
        XCTAssertTrue(text?.images.isEmpty ?? false)
        // An image is drawn, not lined: the yard holds it no more,
        // so it stands missed with its name.
        let missed = shown.letters.first { $0.seq == 71 }
        XCTAssertNil(missed?.files)
        XCTAssertEqual(missed?.images.first?.name, "gone.jpg")
        XCTAssertEqual(missed?.images.first?.missed, true)
        XCTAssertNil(missed?.images.first?.bytes)
        XCTAssertEqual(home.blobAsked, [String(repeating: "cc", count: 32)])
        // Opened again, what was missed is asked for again.
        conversation.leave()
        conversation.open(yard: "", with: "yardmaster")
        _ = await waitFor("the missed picture asked again", state: { conversation.state }) {
            $0.letters.first { $0.seq == 71 }?.images.first?.missed == true && home.blobAsked.count == 2
        }
        XCTAssertEqual(home.blobAsked, [String(repeating: "cc", count: 32), String(repeating: "cc", count: 32)])
        conversation.leave()
    }

    func testImageFileIsDrawnUnderItsLetterAndOpensFull() async {
        home.up(loaded())
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let hash = sha256Hex(bytes)
        home.blobs[hash] = bytes
        home.pages["yardmaster|0"] = Page(letters: [
            letter(70, "yardmaster", "jo", "Seventy.", files: [BlobRef(hash: hash, kind: "image/png", bytes: Int64(bytes.count), name: "shed.png")]),
        ], more: false)
        let conversation = conversation()
        conversation.open(yard: "", with: "yardmaster")
        let shown = await waitFor("the picture", state: { conversation.state }) {
            $0.letters.first { $0.seq == 70 }?.images.first?.bytes != nil
        }
        let image = shown.letters.first { $0.seq == 70 }?.images.first
        XCTAssertEqual(image?.hash, hash)
        XCTAssertEqual(image?.name, "shed.png")
        XCTAssertEqual(image?.bytes, bytes)
        XCTAssertEqual(image?.missed, false)
        XCTAssertNil(shown.letters.first { $0.seq == 70 }?.files)
        XCTAssertNil(shown.full)
        XCTAssertEqual(home.blobAsked, [hash])
        conversation.openPicture(hash)
        let full = await waitFor("the full picture", state: { conversation.state }) { $0.full != nil }
        XCTAssertEqual(full.full?.hash, hash)
        XCTAssertEqual(full.full?.bytes, bytes)
        conversation.closePicture()
        _ = await waitFor("the picture shut", state: { conversation.state }) { $0.full == nil }
        // One no letter carries opens nothing.
        conversation.openPicture(String(repeating: "bb", count: 32))
        XCTAssertNil(conversation.state.full)
        // Opened again, the picture is here without asking the yard.
        conversation.leave()
        conversation.open(yard: "", with: "yardmaster")
        _ = await waitFor("the picture again", state: { conversation.state }) {
            $0.letters.first { $0.seq == 70 }?.images.first?.bytes != nil
        }
        XCTAssertEqual(home.blobAsked, [hash])
        conversation.leave()
    }

    func testPickedPictureIsSentWithTheLetterAndDrawnAtOnce() async {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [letter(13, "yardmaster", "jo", "Thirteen.")], more: false)
        let conversation = conversation(shrink: { _ in jpeg })
        conversation.open(yard: "", with: "yardmaster")
        _ = await waitFor("the page", state: { conversation.state }) { !$0.letters.isEmpty }
        conversation.attach(bytes: png, name: "yard.png", yard: "", with: "yardmaster")
        let attached = await waitFor("the picture picked", state: { conversation.state }) { $0.attached != nil }
        // Shrunk, and renamed for the JPEG it became.
        XCTAssertEqual(attached.attached?.bytes, jpeg)
        XCTAssertEqual(attached.attached?.name, "yard.jpg")
        conversation.draft("The yard, painted.")
        await conversation.send()
        // The blob put first, then the mail naming its hash.
        XCTAssertEqual(home.put, [jpeg])
        XCTAssertEqual(home.sent.map { "\($0.0)|\($0.1)" }, ["yardmaster|The yard, painted."])
        XCTAssertEqual(home.sentFiles, [[MailFile(hash: sha256Hex(jpeg), name: "yard.jpg")]])
        _ = await waitFor("the field emptied", state: { conversation.state }) {
            $0.attached == nil && $0.draft.isEmpty && !$0.sending
        }
        // The letter arrives with the file: drawn at once, from
        // the kept bytes, with nothing asked of the yard.
        home.pages["yardmaster|0"] = Page(letters: [
            letter(170, "jo", "yardmaster", "The yard, painted.", files: [BlobRef(hash: sha256Hex(jpeg), kind: "image/jpeg", bytes: Int64(jpeg.count), name: "yard.jpg")]),
        ], more: false)
        home.up(loaded(head: 170))
        let shown = await waitFor("the picture drawn", state: { conversation.state }) {
            $0.letters.first { $0.seq == 170 }?.images.first?.bytes != nil
        }
        XCTAssertEqual(shown.letters.first { $0.seq == 170 }?.images.first?.bytes, jpeg)
        XCTAssertTrue(home.blobAsked.isEmpty)
        conversation.leave()

        // A photo picker can finish loading after its conversation has
        // changed. It stays with the conversation that opened the picker.
        conversation.open(yard: "", with: "signalman")
        conversation.attach(bytes: png, name: "yard.png", yard: "", with: "yardmaster")
        XCTAssertNil(conversation.state.attached)
        conversation.leave()
    }

    func testPictureAloneIsSentWithEmptyText() async {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        home.up(loaded())
        home.pages["yardmaster|0"] = Page(letters: [letter(13, "yardmaster", "jo", "Thirteen.")], more: false)
        let conversation = conversation(shrink: { _ in jpeg })
        conversation.open(yard: "", with: "yardmaster")
        _ = await waitFor("the page", state: { conversation.state }) { !$0.letters.isEmpty }
        conversation.attach(bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]), name: "yard.png", yard: "", with: "yardmaster")
        _ = await waitFor("the picture picked", state: { conversation.state }) { $0.attached != nil }
        await conversation.send()
        XCTAssertEqual(home.sent.map { "\($0.0)|\($0.1)" }, ["yardmaster|"])
        XCTAssertEqual(home.sentFiles, [[MailFile(hash: sha256Hex(jpeg), name: "yard.jpg")]])
        conversation.leave()
    }

    func testPictureThePhoneCannotReadSaysSo() async {
        home.up(loaded())
        let conversation = conversation(shrink: { _ in nil })
        conversation.open(yard: "", with: "yardmaster")
        conversation.attach(bytes: Data("not a picture".utf8), name: "yard.png", yard: "", with: "yardmaster")
        let state = await waitFor("the refusal", state: { conversation.state }) { $0.error != nil }
        XCTAssertEqual(state.error, "The phone cannot read that picture.")
        XCTAssertNil(state.attached)
        conversation.leave()
    }

    func testLetterOrPictureThatDoesNotGoSaysWhyAndKeepsItsDraftOrPicture() async {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        home.up(loaded())
        home.refuse = .away
        let conversation = conversation(shrink: { _ in jpeg })
        conversation.open(yard: "", with: "yardmaster")
        conversation.draft("Land it.")
        await conversation.send()
        let state = await waitFor("the refusal", state: { conversation.state }) { $0.error != nil }
        XCTAssertEqual(state.draft, "Land it.")
        XCTAssertEqual(state.error, "The letter did not go: The yard is away: the edge cannot reach it.")
        // The same send refusal keeps the picked JPEG and explains
        // that the picture did not go.
        home.refuse = nil
        conversation.attach(bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]), name: "yard.png", yard: "", with: "yardmaster")
        _ = await waitFor("the picture picked", state: { conversation.state }) { $0.attached != nil }
        home.refuse = .away
        await conversation.send()
        let failed = await waitFor("the picture refusal", state: { conversation.state }) {
            $0.error != nil && $0.attached != nil && !$0.sending
        }
        XCTAssertEqual(failed.error, "The picture did not go: The yard is away: the edge cannot reach it.")
        XCTAssertEqual(failed.attached?.bytes, jpeg)
        conversation.leave()
    }

    // MARK: - Fixtures

    private func letter(_ seq: Int64, _ from: String, _ to: String, _ text: String, read: Bool = false, files: [BlobRef] = []) -> Letter {
        Letter(seq: seq, at: "2026-10-08T09:30:00Z", from: from, to: to, text: text, read: read, reactions: [], files: files)
    }

    /// A yard read at `head`: jo's mail read through 12; two unread
    /// of yardmaster's, a read one of signalman's (or an unread one,
    /// with `unreadFromSignalman`); a notice unread; yardmaster
    /// asking.
    private func loaded(head: Int64 = 151, unreadFromSignalman: Bool = false, notices: Bool = true) -> Loaded {
        var mail = [
            letter(13, "yardmaster", "jo", "The shed is painted. Shall I land it?"),
            letter(14, "yardmaster", "jo", "Or after Friday?\nEither."),
        ]
        if unreadFromSignalman {
            mail.append(letter(11, "signalman", "jo", "An old one."))
        } else {
            mail.append(letter(40, "signalman", "jo", "Read the diff when you can.", read: true))
        }
        return Loaded(
            me: Me(user: "jo", saidBy: "phone", yard: "south"),
            head: head,
            settings: Settings(),
            user: User(name: "jo", cursor: unreadFromSignalman ? 10 : 12, notificationCursor: 10),
            crew: [
                CrewMember(name: "signalman", enabled: true, state: "running", status: "idle", loginScreen: true),
                CrewMember(name: "yardmaster", enabled: true, state: "running", status: "working", loginScreen: false),
                CrewMember(name: "relief", enabled: true, state: "running", status: "idle", loginScreen: false),
            ],
            users: [User(name: "jo")],
            inbox: Inbox(mail: mail, unread: Int64(mail.filter { !$0.read }.count), last: 0, from: []),
            notifications: notices
                ? Notifications(notifications: [
                    Notification(seq: 10, at: "2026-10-08T09:30:00Z", kind: "created", bead: "yd-shed", text: "yd-shed created (all) by yardmaster", read: true),
                    Notification(seq: 11, at: "2026-10-08T09:31:00Z", kind: "noted", bead: "yd-shed", text: "yd-shed noted (all) by yardmaster note=1", read: false),
                ], unread: 1, last: 11)
                : Notifications(),
            asks: Asks(open: [
                OpenAsk(bead: "yd-links", ask: 3, question: "Move the links?", asker: "yardmaster"),
                OpenAsk(bead: "yd-map", ask: 7, question: "Who is U024BE7LH?", asker: "yardmaster"),
            ], decided: [])
        )
    }

    private func event(_ seq: Int64, _ kind: String, _ actor: String, _ data: [String: JSONValue]) -> Event {
        Event(seq: seq, kind: kind, actor: actor, at: "2026-10-08T11:00:00Z", bead: "", data: data)
    }
}

/// What a follower of our own holds: the state the test writes, as
/// the session would, and the calls it was asked.
@MainActor
final class FakeFollowed: Followed {
    var state: YardState = YardState() {
        didSet {
            for observer in observers.values { observer(state) }
        }
    }

    private var observers: [UUID: @MainActor (YardState) -> Void] = [:]
    var observerCount: Int { observers.count }
    var pages: [String: Page] = [:]
    var asked: [(String, Int64)] = []
    var completedPageCalls: [Int] = []
    var sent: [(String, String)] = []
    var sentFiles: [[MailFile]] = []
    var mailCalls = 0
    var holdNextMail = false
    var put: [Data] = []
    var blobs: [String: Data] = [:]
    var blobAsked: [String] = []
    var putAnswers: (Data) -> BlobRef = { bytes in
        BlobRef(hash: sha256Hex(bytes), kind: "image/jpeg", bytes: Int64(bytes.count))
    }
    var acks: [Int64] = []
    var noticeAcks: [Int64] = []
    var crewAgain: [CrewMember] = []
    var crewReadCount = 0
    var completedCrewReads = 0
    var beads: [String: Bead] = [:]
    var beadAsked: [String] = []
    var beadCompleted: [String] = []
    private var heldBeadReads: [String: Int] = [:]
    private var pendingBeadReads: [String: [CheckedContinuation<Bead, Never>]] = [:]
    /// The board its `flows` reads serve.
    var board: Flows = Flows()
    var flowCalls = 0
    var holdNextFlowRead = false
    private var pendingFlowRead: CheckedContinuation<Flows, Never>?
    var answers: [(String, Int64, Int64, String, Bool)] = []
    var approvals: [(String, Int64, Bool)] = []
    var setupApprovals: [(String, Int64, Int64, Bool)] = []
    var gives: [(String, Int64, [String: String], Bool)] = []
    var defers: [(String, Int64)] = []
    var declines: [(String, Int64, String)] = []
    var asksAgain: Asks = Asks()
    /// Refused to the answering calls alone, so a card can be read
    /// and its answer refused.
    var answerRefuse: ApiError? = nil
    var refuse: ApiError? = nil
    /// Refused to the whole-bead call alone, so a board can be read
    /// while a card's details are not.
    var beadRefuse: ApiError? = nil
    var holdNextCrewRead = false
    private var heldPageCalls: Set<Int> = []
    private var pendingPageCalls: [Int: CheckedContinuation<Page, Never>] = [:]
    private var pendingCrewRead: CheckedContinuation<[CrewMember], Never>?
    private var pendingMail: CheckedContinuation<Void, Never>?

    func observe(_ observer: @escaping @MainActor (YardState) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func up(_ loaded: Loaded) {
        state = YardState(status: .up, loaded: loaded, lastSeq: loaded.head, lastEvent: nil, events: [])
    }

    func event(_ event: Event) {
        state.lastSeq = event.seq
        state.lastEvent = event
        state.events = state.events + [event]
    }

    func conversation(with: String, limit: Int64, before: Int64) async throws -> Page {
        let call = asked.count + 1
        asked.append((with, before))
        if let refuse { throw refuse }
        if heldPageCalls.contains(call) {
            let page = await withCheckedContinuation { pendingPageCalls[call] = $0 }
            completedPageCalls.append(call)
            return page
        }
        let page = pages["\(with)|\(before)"] ?? Page(letters: [], more: false)
        completedPageCalls.append(call)
        return page
    }

    func holdPageCalls(_ calls: Set<Int>) {
        heldPageCalls = calls
    }

    func releasePageCall(_ call: Int) {
        guard let continuation = pendingPageCalls.removeValue(forKey: call), asked.indices.contains(call - 1) else { return }
        let request = asked[call - 1]
        let page = pages["\(request.0)|\(request.1)"] ?? Page(letters: [], more: false)
        continuation.resume(returning: page)
    }

    func mail(to: String, text: String, files: [MailFile]) async throws {
        mailCalls += 1
        if let refuse { throw refuse }
        if holdNextMail {
            holdNextMail = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pendingMail = continuation
            }
        }
        sent.append((to, text))
        sentFiles.append(files)
    }

    func releaseMail() {
        pendingMail?.resume()
        pendingMail = nil
    }

    func putBlob(_ bytes: Data) async throws -> BlobRef {
        if let refuse { throw refuse }
        put.append(bytes)
        return putAnswers(bytes)
    }

    func blob(hash: String) async throws -> Data? {
        blobAsked.append(hash)
        return blobs[hash]
    }

    func ackInbox(through: Int64) async throws {
        acks.append(through)
    }

    func notifications() async throws -> Notifications {
        Notifications()
    }

    func ackNotifications(through: Int64) async throws {
        noticeAcks.append(through)
    }

    func crew() async throws -> [CrewMember] {
        crewReadCount += 1
        if holdNextCrewRead {
            holdNextCrewRead = false
            let result = await withCheckedContinuation { pendingCrewRead = $0 }
            completedCrewReads += 1
            return result
        }
        completedCrewReads += 1
        return crewAgain
    }

    func releaseCrewRead() {
        pendingCrewRead?.resume(returning: crewAgain)
        pendingCrewRead = nil
    }

    func asks() async throws -> Asks {
        asksAgain
    }

    func bead(_ bead: String) async throws -> Bead {
        beadAsked.append(bead)
        defer { beadCompleted.append(bead) }
        if let refuse { throw refuse }
        if let beadRefuse { throw beadRefuse }
        if heldBeadReads[bead, default: 0] > 0 {
            heldBeadReads[bead, default: 0] -= 1
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bead, Never>) in
                pendingBeadReads[bead, default: []].append(continuation)
            }
        }
        return beads[bead] ?? Bead(id: bead)
    }

    func holdBeadReads(_ bead: String, count: Int) {
        heldBeadReads[bead] = count
    }

    func pendingBeadReadCount(_ bead: String) -> Int {
        pendingBeadReads[bead]?.count ?? 0
    }

    func releaseBeadRead(_ bead: String) {
        guard var pending = pendingBeadReads[bead], !pending.isEmpty else { return }
        let continuation = pending.removeFirst()
        pendingBeadReads[bead] = pending.isEmpty ? nil : pending
        continuation.resume(returning: beads[bead] ?? Bead(id: bead))
    }

    func flows() async throws -> Flows {
        flowCalls += 1
        if let refuse { throw refuse }
        if holdNextFlowRead {
            holdNextFlowRead = false
            return await withCheckedContinuation { pendingFlowRead = $0 }
        }
        return board
    }

    var pendingFlowReadCount: Int { pendingFlowRead == nil ? 0 : 1 }

    func releaseFlowRead() {
        pendingFlowRead?.resume(returning: board)
        pendingFlowRead = nil
    }

    func answer(bead: String, ask: Int64, option: Int64, words: String, weighed: Bool) async throws {
        if let answerRefuse { throw answerRefuse }
        answers.append((bead, ask, option, words, weighed))
    }

    func approve(bead: String, ask: Int64, weighed: Bool) async throws {
        if let answerRefuse { throw answerRefuse }
        approvals.append((bead, ask, weighed))
    }

    func approveSetup(bead: String, ask: Int64, option: Int64, weighed: Bool) async throws {
        if let answerRefuse { throw answerRefuse }
        setupApprovals.append((bead, ask, option, weighed))
    }

    func give(bead: String, ask: Int64, values: [String: String], weighed: Bool) async throws {
        if let answerRefuse { throw answerRefuse }
        gives.append((bead, ask, values, weighed))
    }

    func later(bead: String, ask: Int64) async throws {
        if let answerRefuse { throw answerRefuse }
        defers.append((bead, ask))
    }

    func decline(bead: String, ask: Int64, words: String) async throws {
        if let answerRefuse { throw answerRefuse }
        declines.append((bead, ask, words))
    }
}
