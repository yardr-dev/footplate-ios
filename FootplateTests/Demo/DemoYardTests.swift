@testable import Footplate
import XCTest

// The made-up yard of Try a demo as plain state: what a load reads of it,
// what each write leaves in it and the event it tells, in the shapes the
// board, the decisions and the line read.
final class DemoYardTests: XCTestCase {
    private let fixed = parseInstant("2026-10-31T12:00:00Z")!

    private func demoYard() -> DemoYard {
        let now = fixed
        return DemoYard(now: { now })
    }

    /// What a follower loads of the yard, as `YardClient.load` reads it.
    private func loaded(_ yard: DemoYard) -> Loaded {
        Loaded(
            me: yard.me, head: yard.head, settings: yard.settings, user: yard.user(DemoYard.user),
            crew: yard.crew, users: yard.users, inbox: yard.inbox(limit: 0),
            notifications: yard.notifications, asks: yard.asks
        )
    }

    func testTheYardOpensWithTwoUnreadLettersAndOneQuestion() {
        let yard = demoYard()
        XCTAssertEqual(yard.me, Me(user: "guest", saidBy: "phone", yard: "demo", yardmaster: "yardmaster"))
        XCTAssertEqual(yard.crew.map(\.name), ["yardmaster", "signalman", "shunter"])
        // The unread first, oldest first; then the read, newest first:
        // the long thread is all read, so the two unread stand before
        // it and the read run newest first under them.
        let inbox = yard.inbox(limit: 0)
        XCTAssertEqual(Array(inbox.mail.map(\.seq).prefix(4)), [294, 295, 293, 292])
        XCTAssertEqual(inbox.mail.count, 198)
        XCTAssertEqual(inbox.unread, 2)
        XCTAssertEqual(inbox.last, 295)
        XCTAssertEqual(inbox.from, ["yardmaster"])
        XCTAssertEqual(yard.inbox(limit: 1).mail.map(\.seq), [294])
        XCTAssertEqual(yard.user("guest"), User(name: "guest", cursor: 293, notificationCursor: 2))
        // One question to answer, a routine one: no weight, so no unlock,
        // and nothing a phone cannot give.
        let open = yard.asks.open
        XCTAssertEqual(open.map(\.bead), ["yd-4k2m"])
        XCTAssertEqual(open.first?.weight, [])
        XCTAssertNil(open.first?.secret)
        XCTAssertNil(open.first?.run)
        XCTAssertNil(open.first?.setup)
        XCTAssertNil(open.first?.identity)
        XCTAssertEqual(yard.asks.decided.map(\.state), ["answered"])
        // The bead says the same question with the options a card shows.
        let card = yard.bead("yd-4k2m")?.asks.first
        XCTAssertEqual(card?.options.map(\.label), ["Land it today", "After Friday", "You decide"])
        XCTAssertEqual(card?.recommend, 1)
        XCTAssertNil(yard.bead("yd-nothing"))
    }

    func testTheYardHoldsNoWebAddress() throws {
        // A tap on a link would hand the system an address to open; the
        // demo has none to give.
        let yard = demoYard()
        let encoder = JSONEncoder()
        var texts = [
            try encoder.encode(yard.me), try encoder.encode(yard.crew), try encoder.encode(yard.inbox(limit: 0)),
            try encoder.encode(yard.notifications), try encoder.encode(yard.asks), try encoder.encode(yard.flows),
        ]
        for id in ["yd-4k2m", "yd-7h9q", "yd-2c5d", "yd-9w1x"] {
            texts.append(try encoder.encode(try XCTUnwrap(yard.bead(id))))
        }
        for text in texts.map({ String(decoding: $0, as: UTF8.self) }) {
            XCTAssertFalse(text.contains("://"), text)
            XCTAssertFalse(text.lowercased().contains("www."), text)
        }
    }

    func testTheLineHoldsTheBeadsTheMailNames() throws {
        let yard = demoYard()
        let depot = try XCTUnwrap(yard.flows.depots.first)
        let flow = try XCTUnwrap(depot.flows.first)
        XCTAssertEqual(flow.stages.map(\.stage), ["backlog", "new", "review", "decide", "merged"])
        XCTAssertEqual(flow.stages.last?.terminal, true)
        let waiting = flow.stages.flatMap(\.beads).first { $0.bead == "yd-4k2m" }
        XCTAssertEqual(waiting?.remark, "waits for guest")
        XCTAssertEqual(flow.stages.flatMap(\.beads).filter(\.working).map(\.bead), ["yd-7h9q"])
        XCTAssertEqual(flow.landings.map(\.bead), ["yd-9w1x"])
        // Every bead the mail names is one the yard holds, so each chips.
        for letter in yard.inbox(limit: 0).mail {
            for id in beadIds(letter.text) {
                XCTAssertNotNil(yard.bead(id), "\(id) in \(letter.text)")
            }
        }
    }

    func testAConversationPagesBackwardsOldestFirst() {
        let yard = demoYard()
        let newest = yard.conversation(a: "guest", b: "yardmaster", limit: 2, before: 0)
        XCTAssertEqual(newest.letters.map(\.seq), [294, 295])
        XCTAssertTrue(newest.more)
        let older = yard.conversation(a: "guest", b: "yardmaster", limit: 2, before: 294)
        XCTAssertEqual(older.letters.map(\.seq), [291, 292])
        XCTAssertTrue(older.more)
        // The long thread behind them (footplate-ios-g0jx): a page of
        // thirty from its middle, pictures among its letters, and the
        // whole of it read with no limit.
        let middle = yard.conversation(a: "guest", b: "yardmaster", limit: 30, before: 291)
        XCTAssertEqual(middle.letters.map(\.seq), (261...290).map(Int64.init))
        XCTAssertTrue(middle.more)
        XCTAssertEqual(middle.letters.filter { !$0.files.isEmpty }.count, 2)
        let whole = yard.conversation(a: "guest", b: "yardmaster", limit: 0, before: 0)
        XCTAssertEqual(whole.letters.count, 294)
        XCTAssertFalse(whole.more)
        XCTAssertEqual(whole.letters.filter { !$0.files.isEmpty }.count, 10)
        // What the person sent is in it; what another wrote is not.
        XCTAssertEqual(yard.conversation(a: "guest", b: "signalman", limit: 30, before: 0).letters.map(\.seq), [293])
    }

    func testMailIsAnEventTheBoardReads() throws {
        var yard = demoYard()
        yard.mail(to: "yardmaster", text: "Land it today", files: [])
        XCTAssertEqual(yard.head, 296)
        let event = try XCTUnwrap(yard.events.last)
        XCTAssertEqual(event.seq, 296)
        XCTAssertEqual(event.kind, "mail")
        XCTAssertEqual(event.actor, "guest")
        XCTAssertEqual(event.text("to"), "yardmaster")
        XCTAssertEqual(event.text("text"), "Land it today")
        // The letter's seq is the event's, as on a yard, and the
        // conversation holds it newest.
        XCTAssertEqual(yard.conversation(a: "guest", b: "yardmaster", limit: 1, before: 0).letters.last?.text, "Land it today")
        // A board made before the mail moves on by the event alone.
        let before = loaded(demoYard())
        let board = Board.of(before).apply(event).board
        XCTAssertEqual(board.lettersWith("yardmaster").last?.text, "Land it today")
        XCTAssertEqual(board.lettersWith("yardmaster").last?.from, "guest")
    }

    func testReadingTheMailAndTheNoticesIsToldOnce() throws {
        var yard = demoYard()
        yard.ackInbox(through: 295)
        XCTAssertEqual(yard.inbox(limit: 0).unread, 0)
        XCTAssertEqual(yard.user("guest").cursor, 295)
        yard.ackNotifications(through: 3)
        XCTAssertEqual(yard.notifications.unread, 0)
        XCTAssertEqual(yard.events.map(\.kind), ["mail_read", "notifications_read"])
        XCTAssertEqual(yard.events.first?.text("reader"), "guest")
        XCTAssertEqual(yard.events.first?.number("through"), 295)
        // Behind the cursor: nothing is read, so nothing is told.
        yard.ackInbox(through: 3)
        yard.ackNotifications(through: 1)
        XCTAssertEqual(yard.events.count, 2)
    }

    func testAnAnswerMovesTheQuestionToTheDecidedAndFreesTheBead() throws {
        var yard = demoYard()
        XCTAssertTrue(yard.answer(bead: "yd-4k2m", ask: 3, option: 1, words: ""))
        XCTAssertEqual(yard.asks.open, [])
        let decided = try XCTUnwrap(yard.asks.decided.first)
        XCTAssertEqual(decided.bead, "yd-4k2m")
        XCTAssertEqual(decided.state, "answered")
        XCTAssertEqual(decided.optionLabel, "Land it today")
        XCTAssertEqual(decided.by, "guest")
        XCTAssertEqual(yard.asks.decided.count, 2)
        // The bead's card and the line say it too.
        XCTAssertEqual(yard.bead("yd-4k2m")?.asks.first?.state, "answered")
        XCTAssertEqual(yard.bead("yd-4k2m")?.asks.first?.option, 1)
        let waiting = yard.flows.depots.flatMap(\.flows).flatMap(\.stages).flatMap(\.beads).first { $0.bead == "yd-4k2m" }
        XCTAssertEqual(waiting?.remark, "")
        // The yard tells it as a `noted` on the bead, which the board
        // reads the asks again on.
        let event = try XCTUnwrap(yard.events.last)
        XCTAssertEqual(event.kind, "noted")
        XCTAssertEqual(event.bead, "yd-4k2m")
        XCTAssertTrue(Board.of(loaded(demoYard())).apply(event).rereads.contains(.asks))
        // It is answered once.
        XCTAssertFalse(yard.answer(bead: "yd-4k2m", ask: 3, option: 2, words: ""))
        XCTAssertEqual(yard.events.count, 1)
    }

    func testLaterAndDeclineTakeTheQuestionOffTheListToo() throws {
        var later = demoYard()
        XCTAssertTrue(later.putAside(bead: "yd-4k2m", ask: 3))
        let aside = try XCTUnwrap(later.asks.decided.first)
        XCTAssertEqual(aside.state, "put aside")
        XCTAssertEqual(parseInstant(aside.returnAt), fixed.addingTimeInterval(24 * 3600))
        XCTAssertEqual(later.asks.open, [])

        var declined = demoYard()
        XCTAssertTrue(declined.decline(bead: "yd-4k2m", ask: 3, words: "not this week"))
        let ended = try XCTUnwrap(declined.asks.decided.first)
        XCTAssertEqual(ended.state, "declined")
        XCTAssertEqual(ended.words, "not this week")
        XCTAssertEqual(declined.asks.open, [])

        // Words with no option are an answer of their own.
        var words = demoYard()
        XCTAssertTrue(words.answer(bead: "yd-4k2m", ask: 3, option: 0, words: "Friday morning"))
        XCTAssertEqual(words.asks.decided.first.map { became($0, now: fixed, zone: .gmt) }, "answered: Friday morning")
    }

    func testAFileIsKeptByItsHashAndCarriedByTheLetter() throws {
        var yard = demoYard()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        let ref = yard.putBlob(png)
        XCTAssertEqual(ref.hash, sha256Hex(png))
        XCTAssertEqual(ref.kind, "image/png")
        XCTAssertEqual(ref.bytes, Int64(png.count))
        XCTAssertEqual(yard.blob(hash: ref.hash), png)
        XCTAssertNil(yard.blob(hash: String(repeating: "0", count: 64)))
        yard.mail(to: "yardmaster", text: "", files: [MailFile(hash: ref.hash, name: "shed.png")])
        let letter = try XCTUnwrap(yard.conversation(a: "guest", b: "yardmaster", limit: 1, before: 0).letters.last)
        XCTAssertEqual(letter.files, [BlobRef(hash: ref.hash, kind: "image/png", bytes: Int64(png.count), name: "shed.png")])
        // And the event names it, as the board reads a file.
        let told = blobRefs(yard.events.last?.data["files"])
        XCTAssertEqual(told.map(\.hash), [ref.hash])
        XCTAssertEqual(told.map(\.name), ["shed.png"])
    }
}
