@testable import Footplate
import Observation
import XCTest

// Following the yards against the fake yard: the state read, the events
// reaching it, every refusal retried as 3.1 says, two yards at once, the
// foreground alone, and a network change.
final class FollowTests: XCTestCase {
    private let fake = FakeYard()
    private let clock = TestClock()
    private var session: String!
    private var laptopToken: String!
    private var homeToken: String!
    private var yards: Yards?
    private var followers: [Follower] = []

    override func setUp() {
        super.setUp()
        session = fake.session()
        laptopToken = fake.token(yardName: "laptop")
        homeToken = fake.token(yardName: "")
    }

    override func tearDown() async throws {
        let followers = self.followers
        let yards = self.yards
        await MainActor.run {
            for follower in followers {
                follower.close()
            }
            yards?.close()
        }
        fake.closeStreams()
        self.followers = []
        self.yards = nil
        try await super.tearDown()
    }

    /// The yards, with the app in front unless told otherwise.
    private func makeYards(foreground: Bool = true) async -> Yards {
        let clock = clock
        let yards = await MainActor.run { Yards(clock: clock, foreground: foreground) }
        self.yards = yards
        return yards
    }

    private func follow(_ yards: Yards, yardName: String) async throws -> Follower {
        let token = yardName.isEmpty ? homeToken! : laptopToken!
        let client = try fake.edge().yard(device: token, session: session, name: yardName)
        let follower = await MainActor.run { yards.follow(client) }
        followers.append(follower)
        return follower
    }

    private func close(_ follower: Follower) async {
        await MainActor.run { follower.close() }
    }

    private func status(of follower: Follower) async -> FollowStatus {
        await follower.currentState.status
    }

    func testTheStateIsLoadedAndTheStreamOpensAfterTheHead() async throws {
        let yards = await makeYards()
        let laptop = try await follow(yards, yardName: "laptop")
        let up = try await laptop.waitFor("up") { $0.status == .up }
        let loaded = try XCTUnwrap(up.loaded)
        XCTAssertEqual(loaded.me.user, "jo")
        XCTAssertEqual(loaded.head, 151)
        XCTAssertEqual(up.lastSeq, 151)
        XCTAssertNil(up.lastEvent)
        XCTAssertEqual(loaded.crew.map(\.name), ["signalman", "yardmaster"])
        XCTAssertEqual(loaded.inbox.unread, 2)
        XCTAssertEqual(loaded.asks.open.count, 3)
        try await waitForRequests(fake, 11)
        for _ in 1...10 {
            _ = fake.taken() // the load's calls
        }
        XCTAssertEqual(fake.taken().path, "/user/events?after=151")
    }

    func testStateChangesAreObserved() async throws {
        let yards = await makeYards()
        let laptop = try await follow(yards, yardName: "laptop")
        let notified = NotifiedBox()
        await MainActor.run {
            withObservationTracking {
                _ = laptop.state.status
            } onChange: {
                notified.set()
            }
        }
        _ = try await laptop.waitFor("up") { $0.status == .up }
        XCTAssertTrue(notified.isSet)
    }

    func testNothingIsAskedUntilTheAppIsInFront() async throws {
        let yards = await makeYards(foreground: false)
        let laptop = try await follow(yards, yardName: "laptop")
        clock.advance(.seconds(60))
        try await settle()
        XCTAssertEqual(fake.requestCount, 0)
        let laptopStatus = await status(of: laptop)
        XCTAssertEqual(laptopStatus, .starting)
        await setForeground(yards, true)
        _ = try await laptop.waitFor("up") { $0.status == .up }
    }

    func testAnEventAfterTheHeadReachesTheStateAndTheEndedStreamOpensAgainWithTheLastSeq() async throws {
        fake.stream(lines: [
            #"{"seq": 152, "kind": "mail", "actor": "yardmaster", "at": "2026-10-08T09:30:00Z", "data": {"to": "jo", "text": "The shed is painted."}}"#,
            "",
            #"{"seq": 153, "kind": "noted", "actor": "yardmaster", "bead": "yd-shed", "data": {"note": 1}}"#,
            #"{"seq": 152, "kind": "mail", "actor": "yardmaster", "at": "2026-10-08T09:30:00Z", "data": {"to": "jo", "text": "The shed is painted."}}"#,
            #"{"seq": 153, "kind": "noted", "actor": "yardmaster", "bead": "yd-shed", "data": {"note": 1}}"#,
        ])
        let yards = await makeYards()
        let laptop = try await follow(yards, yardName: "laptop")
        let heard = try await laptop.waitFor("the events") { $0.lastSeq == 153 }
        XCTAssertEqual(heard.lastEvent?.seq, 153)
        XCTAssertEqual(heard.lastEvent?.kind, "noted")
        XCTAssertEqual(heard.lastEvent?.number("note"), 1)
        // Every event since the load is kept, not the newest alone, so a
        // model that looks after a burst misses none of it.
        XCTAssertEqual(heard.events.map(\.seq), [152, 153])
        try await waitForRequests(fake, 11)
        for _ in 1...11 {
            _ = fake.taken() // the load's calls and the stream
        }
        // The ended stream is opened again after 100 ms, and not before.
        let pending = try await waitPending(clock)
        XCTAssertEqual(pending, [.milliseconds(100)])
        let count = fake.requestCount
        clock.advance(.milliseconds(99))
        try await settle()
        XCTAssertEqual(fake.requestCount, count)
        clock.advance(.milliseconds(1))
        try await waitForRequests(fake, count + 1)
        XCTAssertEqual(fake.taken().path, "/user/events?after=153")
    }

    func testEveryRetryableRefusalIsTriedAgainAfter3SecondsAndThenFollowed() async throws {
        let yards = await makeYards()
        let rows: [(FakeResponse, String)] = [
            (.away(), "yard away"),
            (.badGateway(), "yard away"),
            (.slow(), "nothing answers"),
            (.edgeDown(), "edge down"),
        ]
        var takenCount = 0
        for (refused, short) in rows {
            fake.next("/user/events", refused)
            let laptop = try await follow(yards, yardName: "laptop")
            let down = try await laptop.waitFor(short) { $0.status.isDown }
            XCTAssertEqual(downWords(down).short, short)
            let pending = try await waitPending(clock)
            XCTAssertEqual(pending, [.seconds(3)])
            clock.advance(.seconds(3))
            _ = try await laptop.waitFor("followed") { $0.status == .up }
            try await waitForRequests(fake, takenCount + 12)
            let paths = (1...12).map { _ in fake.taken().path }
            takenCount += 12
            XCTAssertEqual(paths[10], "/user/events?after=151")
            XCTAssertEqual(paths[11], "/user/events?after=151")
            await close(laptop)
        }
    }

    func testAnUnreadableYardIsTriedAgainAfter3Seconds() async throws {
        let yards = await makeYards()
        fake.next("/user/call/Head", FakeResponse.json(200, #"{"error": {"code": "broken", "message": "The yard is broken."}}"#))
        let laptop = try await follow(yards, yardName: "laptop")
        let refused = try await laptop.waitFor("refused") { $0.status.isDown }
        XCTAssertEqual(downWords(refused).short, "cannot be read")
        XCTAssertEqual(downWords(refused).words, "The yard is broken.")
        let firstPending = try await waitPending(clock)
        XCTAssertEqual(firstPending, [.seconds(3)])
        clock.advance(.seconds(3))
        _ = try await laptop.waitFor("followed") { $0.status == .up }
        // And an answer that is not what the calls say.
        fake.next("/user/call/Head", FakeResponse.json(200, "not json"))
        await setForeground(yards, false)
        await setForeground(yards, true)
        let protocol_ = try await laptop.waitFor("protocol") { $0.status.isDown }
        XCTAssertEqual(downWords(protocol_).short, "cannot be read")
        XCTAssertTrue(downWords(protocol_).words.contains("cannot read"))
        let secondPending = try await waitPending(clock)
        XCTAssertEqual(secondPending, [.seconds(3)])
        clock.advance(.seconds(3))
        _ = try await laptop.waitFor("followed again") { $0.status == .up }
    }

    func testABusyStreamWaitsOutRetryAfterAndIsFollowedOnceTheYardTakesIt() async throws {
        fake.next("/user/events", .streamsFull(retryAfter: "5"))
        fake.stream(lines: [], hang: true)
        let yards = await makeYards()
        let laptop = try await follow(yards, yardName: "laptop")
        let down = try await laptop.waitFor("busy") { $0.status.isDown }
        let status = downWords(down)
        XCTAssertEqual(status.short, "yard busy")
        XCTAssertTrue(status.words.contains("5 seconds"), status.words)
        let pending = try await waitPending(clock)
        XCTAssertEqual(pending, [.seconds(5)])
        let count = fake.requestCount
        clock.advance(.milliseconds(4999))
        try await settle()
        XCTAssertEqual(fake.requestCount, count, "opened again before its Retry-After")
        clock.advance(.milliseconds(1))
        // The quiet stream opens with no event yet: Up from the opening
        // alone, after the last seq still.
        let open = try await laptop.waitFor("quiet stream followed") { $0.status == .up }
        XCTAssertEqual(open.lastSeq, 151)
        try await waitForRequests(fake, 12)
        let paths = (1...12).map { _ in fake.taken().path }
        XCTAssertEqual(paths.last, "/user/events?after=151")
    }

    func testAYardTheEdgeCallsNotReadyIsTriedAgainAfter30Seconds() async throws {
        fake.next("/user/call/Head", .notReady())
        let yards = await makeYards()
        let laptop = try await follow(yards, yardName: "laptop")
        let down = try await laptop.waitFor("not ready") { $0.status.isDown }
        XCTAssertEqual(downWords(down).short, "yard not ready")
        try await waitForRequests(fake, 2)
        _ = fake.taken() // /user/me
        _ = fake.taken() // the refused Head
        let pending = try await waitPending(clock)
        XCTAssertEqual(pending, [.seconds(30)])
        let count = fake.requestCount
        clock.advance(.seconds(29))
        try await settle()
        XCTAssertEqual(fake.requestCount, count)
        clock.advance(.seconds(1))
        _ = try await laptop.waitFor("followed") { $0.status == .up }
        // The load runs again from /user/me.
        try await waitForRequests(fake, count + 1)
        XCTAssertEqual(fake.taken().path, "/user/me")
    }

    func testAYardTheEdgeCallsNotReadyIsTriedAgainAtOnceOnComingToTheFront() async throws {
        fake.next("/user/call/Head", .notReady())
        let yards = await makeYards()
        let laptop = try await follow(yards, yardName: "laptop")
        _ = try await laptop.waitFor("not ready") { $0.status.isDown }
        try await waitForRequests(fake, 2)
        _ = fake.taken()
        _ = fake.taken()
        _ = try await waitPending(clock)
        await setForeground(yards, false)
        await setForeground(yards, true)
        // The clock does not move: the load runs again at once.
        _ = try await laptop.waitFor("followed") { $0.status == .up }
        try await waitForRequests(fake, 3)
        XCTAssertEqual(fake.taken().path, "/user/me")
    }

    func testTwoYardsAreFollowedAtOnce() async throws {
        fake.nextFor(yard: "laptop", path: "/user/call/Head", .away())
        fake.stream(lines: [#"{"seq": 152, "kind": "mail", "actor": "yardmaster", "data": {"to": "jo", "text": "Home first."}}"#])
        let yards = await makeYards()
        let home = try await follow(yards, yardName: "")
        let laptop = try await follow(yards, yardName: "laptop")
        let down = try await laptop.waitFor("laptop away") { $0.status.isDown }
        XCTAssertEqual(downWords(down).short, "yard away")
        let heard = try await home.waitFor("home's event") { $0.lastSeq == 152 }
        XCTAssertEqual(heard.status, .up)
        _ = try await waitPending(clock, count: 2)
        clock.advance(.seconds(3))
        _ = try await laptop.waitFor("laptop followed") { $0.status == .up }
        let homeState = await home.currentState
        XCTAssertEqual(homeState.status, .up)
        XCTAssertEqual(homeState.lastSeq, 152)
    }

    func testARefusedSessionStopsBothYards() async throws {
        // Home is busy first, so it has no request of its own to fail on:
        // it stops because the session is refused, not because it asked.
        fake.next("/user/events", .streamsFull(retryAfter: "60"))
        let yards = await makeYards()
        let home = try await follow(yards, yardName: "")
        _ = try await home.waitFor("home busy") { $0.status.isDown }
        let laptop = try await follow(yards, yardName: "laptop")
        _ = try await laptop.waitFor("laptop up") { $0.status == .up }
        _ = try await waitPending(clock, count: 2)
        let count = fake.requestCount
        try await fake.edge().logout(session: session)
        clock.advance(.seconds(3))
        let laptopState = try await laptop.waitFor("laptop signed out") { $0.status.isSignInAgain }
        XCTAssertEqual(laptopState.status, .signInAgain(words: signedOutWords))
        let homeState = try await home.waitFor("home signed out") { $0.status.isSignInAgain }
        XCTAssertEqual(homeState.status, .signInAgain(words: signedOutWords))
        let signedOut = await MainActor.run { yards.signedOut }
        XCTAssertTrue(signedOut)
        // The logout and laptop's stream again: home asked nothing after
        // the session was refused.
        try await waitForRequests(fake, count + 2)
        try await settle()
        XCTAssertEqual(fake.requestCount, count + 2)
    }

    func testARefusedDeviceStopsItsOwnYardAlone() async throws {
        let yards = await makeYards()
        let home = try await follow(yards, yardName: "")
        let laptop = try await follow(yards, yardName: "laptop")
        _ = try await home.waitFor("home up") { $0.status == .up }
        _ = try await laptop.waitFor("laptop up") { $0.status == .up }
        _ = try await waitPending(clock, count: 2)
        fake.revokeToken(yardName: "laptop", token: laptopToken)
        clock.advance(.seconds(3))
        let pairAgain = try await laptop.waitFor("pair again") { $0.status.isPairAgain }
        XCTAssertEqual(pairAgain.status, .pairAgain(words: notLetInWords))
        let homeStatus = await status(of: home)
        XCTAssertEqual(homeStatus, .up)
        // Not again until told: the token is back, time passes, and the
        // yard is still stopped.
        fake.restoreToken(yardName: "laptop", token: laptopToken)
        clock.advance(.seconds(60))
        try await settle(300)
        let stillStopped = await status(of: laptop)
        XCTAssertEqual(stillStopped, .pairAgain(words: notLetInWords))
        let homeStillUp = await status(of: home)
        XCTAssertEqual(homeStillUp, .up)
        await laptop.retryFromTest()
        _ = try await laptop.waitFor("paired again") { $0.status == .up }
        // A yard with no device at all stops its own yard the same way.
        _ = try await waitPending(clock, count: 2)
        fake.nextFor(yard: "laptop", path: "/user/events", .noDevice())
        clock.advance(.seconds(3))
        _ = try await laptop.waitFor("no device") { $0.status.isPairAgain }
        let homeUnaffected = await status(of: home)
        XCTAssertEqual(homeUnaffected, .up)
        await laptop.retryFromTest()
        _ = try await laptop.waitFor("no-device retry") { $0.status == .up }
    }

    func testTheStreamsCloseInTheBackgroundAndTheStateIsReadAgainInFront() async throws {
        fake.delay("/user/call/GetUser", .milliseconds(250))
        fake.stream(lines: [], hang: true)
        let yards = await makeYards()
        let home = try await follow(yards, yardName: "")
        try await waitForRequests(fake, 4)
        _ = fake.taken()
        _ = fake.taken()
        _ = fake.taken()
        XCTAssertEqual(fake.taken().path, "/user/call/GetUser")
        await setForeground(yards, false)
        await setForeground(yards, true)
        try await waitForRequests(fake, 10)
        for _ in 1...6 {
            _ = fake.taken() // the rest of the load in progress
        }
        XCTAssertEqual(fake.taken().path, "/user/me") // return reads it again
        try await waitForRequests(fake, 20)
        for _ in 1...9 {
            _ = fake.taken() // the rest of the new load
        }
        _ = try await home.waitFor("up after loading again") { $0.status == .up }
        try await waitForRequests(fake, 21)
        XCTAssertEqual(fake.taken().path, "/user/events?after=151")

        await setForeground(yards, false)
        try await waitForOpenStreams(fake, 0)
        let count = fake.requestCount
        clock.advance(.seconds(75))
        try await settle()
        XCTAssertEqual(fake.requestCount, count, "asked while in the background")
        let homeStatus = await status(of: home)
        XCTAssertEqual(homeStatus, .up)
        await setForeground(yards, true)
        // Coming back reads the state again, then opens the stream
        // after the new head.
        try await waitForRequests(fake, count + 11)
        XCTAssertEqual(
            (1...11).map { _ in fake.taken().path },
            [
                "/user/me",
                "/user/call/Head",
                "/user/call/Settings",
                "/user/call/GetUser",
                "/user/call/Crew",
                "/user/call/Users",
                "/user/call/UserInbox",
                "/user/call/UserInbox",
                "/user/call/UserNotifications",
                "/user/call/UserAsks",
                "/user/events?after=151",
            ]
        )
    }

    func testANetworkChangeClosesTheStreamsAndOpensThemAgain() async throws {
        fake.stream(lines: [#"{"seq": 152, "kind": "mail", "actor": "yardmaster", "data": {"to": "jo", "text": "Home first."}}"#], hang: true)
        fake.stream(lines: [], hang: true)
        let yards = await makeYards()
        let home = try await follow(yards, yardName: "")
        _ = try await home.waitFor("152 applied") { $0.lastSeq == 152 }
        try await waitForRequests(fake, 11)
        for _ in 1...10 {
            _ = fake.taken() // the load's calls
        }
        XCTAssertEqual(fake.taken().path, "/user/events?after=151")
        await MainActor.run { yards.noteNetworkChanged() }
        // The stream opens again after the last seen, with no load
        // between.
        try await waitForRequests(fake, 12)
        XCTAssertEqual(fake.taken().path, "/user/events?after=152")
        try await waitForOpenStreams(fake, 1)
        let homeStatus = await status(of: home)
        XCTAssertEqual(homeStatus, .up)
        // Closing the active stream ends it and starts the normal 3-second
        // reconnect pause; the stream from before the network change is gone.
        fake.closeStreams()
        try await waitForOpenStreams(fake, 0)
        _ = try await waitPending(clock, count: 1)
        try await settle()
        XCTAssertEqual(clock.pending(), [.seconds(3)])
    }
}

/// Whether observation's change hook ran, from whatever thread it runs on.
private final class NotifiedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}
