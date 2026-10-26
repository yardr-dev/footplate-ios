@testable import Footplate
import XCTest

// The Notifier against plain boards (design 3.5): a real Mailroom over
// followers of our own, and the clock driven by the test. What the
// followed yards bring is told of one burst a kind, 3 seconds after
// the first of it, where the system lets any; nothing on the screen
// shown, nothing of a yard followed no more, and nothing without the
// permission.
@MainActor
final class NotifierTests: XCTestCase {
    private var records: Records!
    private var mailroom: Mailroom!
    private var home: FakeFollowed!
    private var laptop: FakeFollowed!
    private var clock: TestClock!
    private var notifier: Notifier!
    private var allowed = true
    private var allowedCalls = 0
    private var told: [Telling] = []

    override func setUp() async throws {
        try await super.setUp()
        records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: "https://my.yardr.dev")
        records.keepSession(account: "jo@example.com", session: "session")
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: "yardr-dev-laptop-1"))
        mailroom = Mailroom()
        home = FakeFollowed()
        laptop = FakeFollowed()
        mailroom.setFollowers(["laptop": laptop])
        clock = TestClock()
        allowed = true
        allowedCalls = 0
        told = []
        notifier = Notifier(
            mailroom: mailroom, records: records,
            allowed: { self.allowedCalls += 1; return self.allowed },
            tell: { self.told.append($0) },
            clock: clock
        )
    }

    private func loaded(head: Int64 = 10, letters: [Letter] = [], open: [OpenAsk] = []) -> Loaded {
        Loaded(
            me: Me(user: "jo"), head: head, settings: Settings(), user: User(name: "jo"),
            crew: [], users: [], inbox: Inbox(mail: letters),
            notifications: Notifications(), asks: Asks(open: open, decided: [])
        )
    }

    private func letter(_ seq: Int64, from: String = "yardmaster", text: String? = nil) -> Letter {
        Letter(seq: seq, from: from, to: "jo", text: text ?? "Letter \(seq).")
    }

    private func ask(bead: String = "footplate-1", ask: Int64 = 2, asker: String = "yardmaster") -> OpenAsk {
        OpenAsk(bead: bead, ask: ask, question: "Shall I land it?", asker: asker)
    }

    /// The timers the arrivals started, waiting for `count` of them:
    /// a timer's task runs after the board that started it.
    private func waitPending(_ what: String, count: Int) async -> [Duration] {
        let deadline = ContinuousClock.now + .seconds(10)
        while clock.pending().count < count {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what); pending=\(clock.pending())")
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return clock.pending()
    }

    /// Waits for no timer: a cancelled sleep leaves the clock after
    /// its task answers the cancel.
    private func waitNoPending(_ what: String) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !clock.pending().isEmpty {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what); pending=\(clock.pending())")
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// What was told, waiting for `count` of them: the timers fire on
    /// the test's clock, and the telling follows.
    private func waitTold(_ what: String, count: Int = 1) async -> [Telling] {
        let deadline = ContinuousClock.now + .seconds(10)
        while told.count < count {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what); told=\(told)")
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return told
    }

    func testThreeLettersWithinThreeSecondsBecomeOne() async {
        laptop.up(loaded())
        laptop.up(loaded(letters: [letter(11, text: "First.")]))
        laptop.up(loaded(letters: [letter(11, text: "First."), letter(12, text: "Second.")]))
        laptop.up(loaded(letters: [letter(11, text: "First."), letter(12, text: "Second."), letter(13, text: "Third.")]))
        // One timer for the burst, 3 seconds after the first.
        let pending = await waitPending("the burst", count: 1)
        XCTAssertEqual([.seconds(3)], pending)
        clock.advance(.milliseconds(2999))
        XCTAssertTrue(told.isEmpty, "not before 3 seconds")
        clock.advance(.milliseconds(1))
        let told = await waitTold("the burst")
        guard told.count == 1 else { return }
        XCTAssertEqual("3 from yardmaster", told[0].title)
        XCTAssertEqual("Third.", told[0].body)
        XCTAssertEqual("laptop", told[0].yard)
        XCTAssertEqual(.conversation(with: "yardmaster"), told[0].target)
        XCTAssertTrue(clock.pending().isEmpty, "told once")
        XCTAssertEqual(1, told.count)
    }

    func testMailOnTheOpenConversationIsNotTold() async {
        notifier.show(.conversation(yard: "laptop", with: "yardmaster"))
        laptop.up(loaded())
        laptop.up(loaded(letters: [letter(11), letter(12, from: "signalman")]))
        let pending = await waitPending("the burst", count: 1)
        XCTAssertEqual([.seconds(3)], pending)
        clock.advance(.seconds(3))
        // yardmaster's is read where it stands; signalman's is told of.
        let told = await waitTold("the burst")
        guard told.count == 1 else { return }
        XCTAssertEqual("signalman", told[0].title)
        XCTAssertEqual(1, told.count)
    }

    func testADecisionWithItsListInFrontIsNotTold() async {
        notifier.show(.decisions(yard: "laptop"))
        laptop.up(loaded())
        laptop.up(loaded(letters: [letter(11)], open: [ask()]))
        let pending = await waitPending("the burst", count: 1)
        XCTAssertEqual([.seconds(3)], pending)
        clock.advance(.seconds(3))
        let told = await waitTold("the burst")
        guard told.count == 1 else { return }
        XCTAssertEqual("yardmaster", told[0].title)
        XCTAssertEqual(1, told.count)
    }

    func testMailAndDecisionsTellSeparately() async {
        laptop.up(loaded())
        laptop.up(loaded(letters: [letter(11)], open: [ask()]))
        let pending = await waitPending("the bursts", count: 2)
        XCTAssertEqual([.seconds(3), .seconds(3)], pending)
        clock.advance(.seconds(3))
        let told = await waitTold("the bursts", count: 2)
        guard told.count == 2 else { return }
        XCTAssertEqual(["yardmaster", "A decision from yardmaster"], Set(told.map(\.title)))
    }

    func testADecisionInAYardNotShownIsToldWithTheYardsTitle() async {
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        mailroom.setFollowers(["laptop": laptop, "": home])
        laptop.up(loaded())
        home.up(loaded())
        notifier.show(.decisions(yard: "laptop"))
        home.up(loaded(open: [ask()]))
        let pending = await waitPending("the burst", count: 1)
        XCTAssertEqual([.seconds(3)], pending)
        clock.advance(.seconds(3))
        let told = await waitTold("the decision")
        guard told.count == 1 else { return }
        XCTAssertEqual("south · A decision from yardmaster", told[0].title)
        XCTAssertEqual("", told[0].yard)
        XCTAssertEqual(.decision(bead: "footplate-1", ask: 2), told[0].target)
    }

    func testNothingIsToldWithoutThePermissionAndNothingWaitsForIt() async {
        allowed = false
        await notifier.refresh()
        XCTAssertTrue(notifier.muted, "muted without it")
        laptop.up(loaded())
        laptop.up(loaded(letters: [letter(11, text: "While muted.")]))
        let pending = await waitPending("the burst", count: 1)
        XCTAssertEqual([.seconds(3)], pending)
        clock.advance(.seconds(3))
        // The burst fired and asked; nothing was told of.
        let gated = ContinuousClock.now + .seconds(10)
        while allowedCalls < 1, ContinuousClock.now <= gated {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(1, allowedCalls)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(told.isEmpty, "nothing told")
        // Allowed again: what arrived muted is not told late.
        allowed = true
        await notifier.refresh()
        XCTAssertFalse(notifier.muted, "unmuted")
        laptop.up(loaded(letters: [letter(11, text: "While muted."), letter(12, text: "After.")]))
        let again = await waitPending("the burst", count: 1)
        XCTAssertEqual([.seconds(3)], again)
        clock.advance(.seconds(3))
        let told = await waitTold("the later letter")
        guard told.count == 1 else { return }
        XCTAssertEqual("yardmaster", told[0].title)
        XCTAssertEqual("After.", told[0].body)
        XCTAssertEqual(1, told.count)
    }

    func testWhatWaitsOfAYardFollowedNoMoreIsDropped() async {
        laptop.up(loaded())
        laptop.up(loaded(letters: [letter(11)]))
        let pending = await waitPending("the burst", count: 1)
        XCTAssertEqual([.seconds(3)], pending)
        mailroom.setFollowers([:])
        await waitNoPending("the emptied burst has no timer")

        // A new yard's burst starts its own full three-second window
        // after the only arrival in the first burst was forgotten.
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        mailroom.setFollowers(["": home])
        home.up(loaded())
        home.up(loaded(letters: [letter(11)]))
        let fresh = await waitPending("the new yard's burst", count: 1)
        XCTAssertEqual([.seconds(3)], fresh)
        clock.advance(.milliseconds(2999))
        XCTAssertTrue(told.isEmpty, "nothing told")
        clock.advance(.milliseconds(1))
        let told = await waitTold("the new yard's letter")
        guard told.count == 1 else { return }
        // Two yards are paired, so the yard is named by its title.
        XCTAssertEqual("south · yardmaster", told[0].title)
        XCTAssertEqual(1, told.count)
        XCTAssertTrue(clock.pending().isEmpty, "no timer left")
    }

    func testMutedUntilTheFirstRefreshReadsIt() async {
        XCTAssertTrue(notifier.muted)
        await notifier.refresh()
        XCTAssertFalse(notifier.muted)
    }
}
