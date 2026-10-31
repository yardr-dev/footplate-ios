@testable import Footplate
import XCTest

// The demo yard's transport (Try a demo) through the app's own client, as
// the follower uses it: a load, the calls a screen makes, the stream with
// its events and heartbeat, and what a yard does not answer. No socket is
// opened anywhere here: the transport is the seam, and the test reads what
// reached it.
final class DemoTransportTests: XCTestCase {
    private func client(_ transport: DemoTransport) throws -> YardClient {
        try Edge(origin: DemoTransport.origin, transport: transport).yardDirect(device: "demo")
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: DemoTransport.origin + path)!)
        request.httpMethod = method
        return request
    }

    /// Runs `read`, and fails the test where it has not finished in
    /// `timeout`: a stream that tells nothing is waited on for ever else.
    private func within(
        _ what: String, _ timeout: Duration = .seconds(10), _ read: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await read() }
            group.addTask {
                try await Task.sleep(for: timeout)
                XCTFail("timed out waiting for \(what)")
                throw TestTimeout(what: what)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    func testTheClientLoadsTheDemoYardAndAsksNothingElse() async throws {
        let transport = DemoTransport()
        let loaded = try await client(transport).load()
        XCTAssertEqual(loaded.me, Me(user: "guest", saidBy: "phone", yard: "demo", yardmaster: "yardmaster"))
        XCTAssertEqual(loaded.head, 5)
        XCTAssertEqual(loaded.settings.operator, "guest")
        XCTAssertEqual(loaded.user, User(name: "guest", cursor: 3, notificationCursor: 2))
        XCTAssertEqual(loaded.crew.map(\.name), ["yardmaster", "signalman", "shunter"])
        XCTAssertEqual(loaded.inbox.unread, 2)
        XCTAssertEqual(loaded.notifications.unread, 1)
        XCTAssertEqual(loaded.asks.open.map(\.bead), ["yd-4k2m"])
        // A load is /user/me and the calls of design 3.3, to a yard.
        let asked = transport.requests
        XCTAssertEqual(asked.first, "GET /user/me")
        XCTAssertTrue(asked.dropFirst().allSatisfy { $0.hasPrefix("POST /user/call/") }, "\(asked)")
        XCTAssertEqual(asked.count, 10)
    }

    func testTheCallsAScreenMakesAreAnswered() async throws {
        let client = try client(DemoTransport())
        let page = try await client.conversation(a: "guest", b: "yardmaster", limit: 30)
        XCTAssertEqual(page.letters.map(\.seq), [1, 2, 4, 5])
        XCTAssertFalse(page.more)
        let older = try await client.conversation(a: "guest", b: "yardmaster", limit: 1, before: 5)
        XCTAssertEqual(older.letters.map(\.seq), [4])
        XCTAssertTrue(older.more)
        let bead = try await client.bead("yd-4k2m")
        XCTAssertEqual(bead.title, "Cache the departures board")
        XCTAssertEqual(bead.asks.first?.options.count, 3)
        let flows = try await client.flows(viewer: "guest")
        XCTAssertEqual(flows.depots.map(\.name), ["timetable"])
        XCTAssertEqual(flows.travelling, 2)
        try await client.ackUserInbox(name: "guest", through: 5)
        try await client.ackUserNotifications(name: "guest", through: 3)
        let inbox = try await client.userInbox(name: "guest", limit: 0)
        XCTAssertEqual(inbox.unread, 0)
    }

    func testAWriteIsToldToTheStreamOpenBeforeItAndToOneOpenedAfterIt() async throws {
        let client = try client(DemoTransport())
        try await within("the events of two writes") {
            var open = client.events(after: 5).makeAsyncIterator()
            try await client.mail(to: "yardmaster", text: "Land it today", actor: "guest")
            let told = try await open.next()
            XCTAssertEqual(told?.seq, 6)
            XCTAssertEqual(told?.kind, "mail")
            XCTAssertEqual(told?.text("text"), "Land it today")
            // A stream opened after it is told what it missed first.
            var late = client.events(after: 5).makeAsyncIterator()
            let replay = try await late.next()
            XCTAssertEqual(replay?.seq, 6)
            // And one opened after the head is told nothing before the next.
            var after = client.events(after: 6).makeAsyncIterator()
            try await client.answerAsk(bead: "yd-4k2m", ask: 3, option: 1, words: "", actor: "guest")
            let next = try await after.next()
            XCTAssertEqual(next?.seq, 7)
            XCTAssertEqual(next?.kind, "noted")
            XCTAssertEqual(next?.bead, "yd-4k2m")
        }
    }

    func testAnAnswerIsInTheQueueTheClientReadsAgain() async throws {
        let client = try client(DemoTransport())
        try await client.answerAsk(bead: "yd-4k2m", ask: 3, option: 2, words: "after the release", actor: "guest")
        let asks = try await client.userAsks(name: "guest")
        XCTAssertEqual(asks.open, [])
        XCTAssertEqual(asks.decided.first?.optionLabel, "After Friday")
        XCTAssertEqual(asks.decided.first?.words, "after the release")
    }

    func testTheStreamKeepsItsLinesWholeThroughItsHeartbeats() async throws {
        // A heartbeat every millisecond between forty letters: one that fell
        // inside a line would split an event, and the client would fail
        // to read it.
        let client = try client(DemoTransport(heartbeat: .milliseconds(1)))
        try await within("forty events") {
            var events = client.events(after: 5).makeAsyncIterator()
            for number in 1...40 {
                try await client.mail(to: "yardmaster", text: "Letter \(number)", actor: "guest")
            }
            for number in 1...40 {
                let event = try await events.next()
                XCTAssertEqual(event?.seq, Int64(5 + number))
                XCTAssertEqual(event?.text("text"), "Letter \(number)")
            }
        }
    }

    func testAnIdleStreamIsToldItIsAliveBeforeTheFollowersWatchdog() async throws {
        let transport = DemoTransport(heartbeat: .milliseconds(5))
        let (bytes, head) = try await transport.bytes(for: request("/user/events?after=5"))
        XCTAssertEqual(head.status, 200)
        XCTAssertEqual(head.header("Content-Type"), "application/x-ndjson")
        try await within("a heartbeat") {
            var iterator = bytes.makeAsyncIterator()
            let first = try await iterator.next()
            XCTAssertEqual(first, 0x0A)
        }
        // The default beat comes well inside the 75 seconds the client waits.
        XCTAssertLessThan(DemoTransport.heartbeat * 2, YardClient.streamQuiet)
    }

    func testAPictureIsKeptAndReadBack() async throws {
        let client = try client(DemoTransport())
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        let ref = try await client.putBlob(png)
        XCTAssertEqual(ref.kind, "image/png")
        let back = try await client.blob(hash: ref.hash)
        XCTAssertEqual(back, png)
        let none = try await client.blob(hash: String(repeating: "a", count: 64))
        XCTAssertNil(none)
    }

    func testWhatTheYardRefusesIsTheYardsOwnSentence() async throws {
        let client = try client(DemoTransport())
        let noBead = await raisedApiError { _ = try await client.bead("yd-nothing") }
        XCTAssertEqual(noBead, .refused(code: "no_bead", message: "The demo yard holds no bead yd-nothing."))
        try await client.answerAsk(bead: "yd-4k2m", ask: 3, option: 1, words: "", actor: "guest")
        let twice = await raisedApiError {
            try await client.answerAsk(bead: "yd-4k2m", ask: 3, option: 2, words: "", actor: "guest")
        }
        XCTAssertEqual(twice, .refused(code: "not_open", message: "That question is not open any more."))
        // The cards a demo does not hold are not taken.
        let approve = await raisedApiError { try await client.approveAsk(bead: "yd-4k2m", ask: 3, actor: "guest") }
        XCTAssertEqual(approve, .refused(code: "not_in_demo", message: "The demo yard does not take that call."))
    }

    func testNothingButAYardsPathsIsAnswered() async throws {
        // No pairing, no sign-in, no push registration: a demo is none of
        // them, and the transport has nothing behind these.
        let transport = DemoTransport()
        for path in ["/user/pair", "/user/push/register", "/user/push/unregister", "/kratos/self-service/login/api", "/beads/yd-4k2m"] {
            for method in ["GET", "POST"] {
                let (_, head) = try await transport.data(for: request(path, method: method))
                XCTAssertEqual(head.status, 404, "\(method) \(path)")
            }
        }
        let (_, absent) = try await transport.data(for: request("/user/blobs/" + String(repeating: "b", count: 64)))
        XCTAssertEqual(absent.status, 404)
    }
}
