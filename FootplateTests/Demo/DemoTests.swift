@testable import Footplate
import UIKit
import UserNotifications
import XCTest

// Try a demo, end to end in the simulator: the demo's own models over the
// demo yard, each place with its data, the writes a person makes, and the
// app's entering and leaving it. The app is made with a recording stand-in
// where `URLSession` stands and recording shelves where the Keychain
// stands, so what a demo sends out or keeps is read off them.

/// Stands where `URLSession` stands: a demo that reaches it has sent a
/// request out of the phone. It records the request and fails it.
private final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    var requests: [String] {
        lock.withLock { seen }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPHead) {
        note(request)
        throw ApiError.down(why: "this test has no network")
    }

    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPHead) {
        note(request)
        throw ApiError.down(why: "this test has no network")
    }

    private func note(_ request: URLRequest) {
        lock.withLock { seen.append("\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")") }
    }
}

/// Stands where the Keychain stands: a shelf in memory that counts what
/// is written to it.
private final class RecordingShelf: Shelf, @unchecked Sendable {
    private let shelf = MemoryShelf()
    private let lock = NSLock()
    private var written = 0

    var writes: Int {
        lock.withLock { written }
    }

    var map: [String: String] { shelf.map }

    func get(_ key: String) -> String? { shelf.get(key) }
    func keys() -> Set<String> { shelf.keys() }

    func write(put: [String: String], remove: [String]) {
        lock.withLock { written += 1 }
        shelf.write(put: put, remove: remove)
    }
}

@MainActor
final class DemoTests: XCTestCase {
    private func until(
        _ what: String,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ match: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !match() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what)", file: file, line: line)
                throw TestTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The demo as opened, read, with its Crew place.
    private func openedDemo() async throws -> Demo {
        let demo = Demo()
        try await until("the demo yard is read") { demo.inbox.state.rows.contains { $0.name == "yardmaster" } }
        return demo
    }

    func testEachPlaceHasDemoData() async throws {
        let demo = try await openedDemo()
        defer { demo.close() }

        // Crew: the head line, the rows and what waits.
        let crew = demo.inbox.state
        XCTAssertEqual(crew.head, "demo · guest")
        XCTAssertTrue(crew.demo)
        XCTAssertNil(crew.word)
        XCTAssertNil(crew.nothing)
        XCTAssertEqual(crew.yards.map(\.name), ["demo"])
        XCTAssertEqual(crew.rows.map(\.name), ["yard", "yardmaster", "signalman", "shunter", "guest"])
        let master = crew.rows.first { $0.name == "yardmaster" }
        XCTAssertEqual(master?.unread, "2 unread")
        XCTAssertEqual(master?.state, "waiting on you")
        XCTAssertEqual(crew.rows.first { $0.name == "signalman" }?.state, "idle")
        XCTAssertEqual(crew.rows.first { $0.name == "shunter" }?.state, "not running")
        XCTAssertEqual(crew.rows.first { $0.name == "yard" }?.unread, "1 unread")
        XCTAssertEqual(crew.waiting, 1)
        // No permission is asked for a yard that is not paired, and the
        // Crew place says nothing of notifications being off.
        XCTAssertTrue(demo.records.notificationsAsked)
        try await until("the notifier is allowed") { !demo.notifier.muted }

        // Decide: the one question, and what was decided before it.
        XCTAssertEqual(demo.decisions.state.open.map(\.bead), ["yd-4k2m"])
        XCTAssertEqual(demo.decisions.state.open.first?.weighty, [])
        XCTAssertEqual(demo.decisions.state.decided.map(\.what), ["answered: In minutes"])

        // Lines: the line with its beads, and no page for any of them.
        demo.line.open(yard: "demo")
        try await until("the line is read") { demo.line.state.read }
        defer { demo.line.leave() }
        let line = demo.line.state
        XCTAssertEqual(line.lines.map(\.title), ["timetable · default"])
        XCTAssertEqual(line.stats.inTransit, 2)
        XCTAssertEqual(line.stats.moving, 1)
        XCTAssertEqual(line.stats.yourTurn, 1)
        XCTAssertNil(line.error)
        let card = try XCTUnwrap(demo.line.card(for: BeadRoute(yard: "demo", bead: "yd-4k2m")))
        XCTAssertEqual(card.stage, "decide")
        XCTAssertEqual(card.webView, "")
        let route = try XCTUnwrap(demo.line.routeMap(for: LineRoute(yard: "demo", depot: "timetable", flow: "default")))
        XCTAssertEqual(route.stations.map(\.name), ["backlog", "new", "review", "decide", "merged"])
        XCTAssertEqual(route.stations.last?.landings.map(\.id), ["yd-9w1x"])
    }

    func testALetterIsSentAndAQuestionAnsweredInMemory() async throws {
        let demo = try await openedDemo()
        defer { demo.close() }
        demo.line.open(yard: "demo")
        defer { demo.line.leave() }
        try await until("the line is read") { demo.line.state.read }

        demo.conversation.open(yard: "demo", with: "yardmaster")
        defer { demo.conversation.leave() }
        try await until("the conversation is read") { demo.conversation.state.letters.count == 30 }
        demo.conversation.draft("Land it today")
        await demo.conversation.send()
        try await until("the letter comes back as its event") { demo.conversation.state.letters.count == 31 }
        let sent = try XCTUnwrap(demo.conversation.state.letters.last)
        XCTAssertTrue(sent.mine)
        XCTAssertEqual(sent.text, "Land it today")
        XCTAssertEqual(demo.conversation.state.draft, "")
        // Reading it acknowledged the yardmaster's two letters.
        try await until("the mail is read") { demo.inbox.state.rows.first { $0.name == "yardmaster" }?.unread == nil }

        demo.decision.open(yard: "demo", bead: "yd-4k2m", ask: 3)
        defer { demo.decision.leave() }
        demo.nav.openDecision(yard: "demo", bead: "yd-4k2m", ask: 3)
        try await until("the card is read") { demo.decision.state.read }
        XCTAssertEqual(demo.decision.state.options.map(\.label), ["Land it today", "After Friday", "You decide"])
        XCTAssertFalse(demo.decision.state.typeBack)
        demo.decision.choose(1)
        await demo.decision.pick()
        try await until("the question is answered") { demo.decisions.state.open.isEmpty }
        XCTAssertEqual(demo.decisions.state.decided.first?.what, "answered: Land it today")
        XCTAssertEqual(demo.decisions.state.decided.count, 2)
        // The card leaves for the list, the count clears, and the line
        // moves with the bead no longer waiting.
        XCTAssertEqual(demo.nav.decidePath, [])
        XCTAssertEqual(demo.inbox.state.waiting, 0)
        XCTAssertEqual(demo.inbox.state.rows.first { $0.name == "yardmaster" }?.state, "working")
        try await until("the line is read again") { demo.line.state.stats.yourTurn == 0 }
    }

    func testAPictureSentInTheDemoIsTakenAwayWithIt() async throws {
        let demo = try await openedDemo()
        defer { demo.close() }
        demo.conversation.open(yard: "demo", with: "yardmaster")
        defer { demo.conversation.leave() }
        try await until("the conversation is read") { demo.conversation.state.letters.count == 30 }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        demo.conversation.attach(bytes: png, name: "shed.png", yard: "demo", with: "yardmaster")
        try await until("the picture is shrunk") { demo.conversation.state.attached != nil }
        await demo.conversation.send()
        try await until("the picture's letter comes back") { demo.conversation.state.letters.count == 31 }
        XCTAssertEqual(demo.conversation.state.letters.last?.mine, true)
        XCTAssertEqual(demo.conversation.state.letters.last?.images.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: demo.folder.path))
        demo.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: demo.folder.path))
    }

    // MARK: - The app entering and leaving it

    /// An app made on stand-ins for `URLSession` and the Keychain, and the
    /// notification delegate the host app set put back after it.
    private struct World {
        let services: AppServices
        let live: RecordingTransport
        let secret: RecordingShelf
        let plain: RecordingShelf
        let records: Records
    }

    private func makeWorld() throws -> World {
        let live = RecordingTransport()
        let secret = RecordingShelf()
        let plain = RecordingShelf()
        let edge = try Edge(origin: "https://my.yardr.dev", transport: live)
        let records = Records(secret: secret, plain: plain, origin: edge.origin)
        let services = AppServices(edge: edge, records: records, secret: secret)
        // The app set itself the notification centre's delegate; the
        // host app's own goes back at the end of the test.
        let host = UNUserNotificationCenter.current().delegate
        addTeardownBlock { @MainActor in
            UNUserNotificationCenter.current().delegate = host
        }
        services.setForeground(true)
        return World(services: services, live: live, secret: secret, plain: plain, records: records)
    }

    func testTheDemoOpensNoSocketAndKeepsNoToken() async throws {
        let world = try makeWorld()
        let services = world.services
        XCTAssertNil(services.demo)

        services.enterDemo()
        let demo = try XCTUnwrap(services.demo)
        let transport = demo.transport
        try await until("the demo yard is read") { demo.inbox.state.rows.contains { $0.name == "yardmaster" } }
        // Followed as any yard is: one stream open on it.
        try await until("its stream is open") { transport.streams == 1 }
        // Used as a person uses it: a letter sent, the question answered,
        // a bead and the line read.
        demo.conversation.open(yard: "demo", with: "yardmaster")
        demo.conversation.draft("Land it today")
        await demo.conversation.send()
        try await until("the letter is in") { demo.conversation.state.letters.contains { $0.mine } }
        demo.conversation.leave()
        demo.decision.open(yard: "demo", bead: "yd-4k2m", ask: 3)
        try await until("the card is read") { demo.decision.state.read }
        demo.decision.choose(1)
        await demo.decision.pick()
        try await until("the question is answered") { demo.decisions.state.open.isEmpty }
        demo.decision.leave()
        demo.line.open(yard: "demo")
        try await until("the line is read") { demo.line.state.read }
        demo.line.openBead("yd-7h9q")
        demo.line.leave()

        // The demo was served, and by the demo's own transport alone: what
        // it asked of a yard, and nothing of the edge, a pairing or the relay.
        let asked = transport.requests
        XCTAssertTrue(asked.contains("POST /user/call/Mail"))
        XCTAssertTrue(asked.contains("POST /user/call/AnswerAsk"))
        XCTAssertTrue(asked.contains("POST /user/call/Flows"))
        XCTAssertTrue(asked.contains("GET /user/events"))
        let yardPaths = asked.filter {
            $0 == "GET /user/me" || $0 == "GET /user/events" || $0.hasPrefix("POST /user/call/") || $0.hasPrefix("GET /user/blobs/")
        }
        XCTAssertEqual(asked, yardPaths)

        services.leaveDemo()
        XCTAssertNil(services.demo)
        // The stream is shut with it, and nothing runs for a demo left.
        try await until("its stream is shut") { transport.streams == 0 }
        // Nothing reached where `URLSession` stands, and nothing was
        // written where the Keychain stands: no token, no yard, no push.
        XCTAssertEqual(world.live.requests, [])
        XCTAssertEqual(world.secret.writes, 0)
        XCTAssertEqual(world.plain.writes, 0)
        XCTAssertEqual(world.secret.map, [:])
        XCTAssertEqual(world.plain.map, [:])
        XCTAssertEqual(world.records.kept, Kept())
        XCTAssertNil(services.registrar.token)
        XCTAssertEqual(services.followers.count, 0)
    }

    func testEnteringAndLeavingTheDemo() async throws {
        let world = try makeWorld()
        let services = world.services
        XCTAssertNil(services.demo)
        // The first screen of a phone with no yard: nothing is paired.
        XCTAssertEqual(services.records.kept.yards, [])

        services.enterDemo()
        let first = try XCTUnwrap(services.demo)
        // Entered once: asking again keeps the demo that is open.
        services.enterDemo()
        XCTAssertTrue(services.demo === first)
        try await until("the demo yard is read") { first.inbox.state.rows.contains { $0.name == "yardmaster" } }
        // The app's own places are as they were.
        XCTAssertEqual(services.records.kept, Kept())
        XCTAssertEqual(services.nav.place, .crew)
        XCTAssertFalse(services.nav.pairing)
        XCTAssertEqual(first.inbox.state.yards.map(\.title), ["demo"])

        // A write is the demo's alone, and goes with it.
        first.decision.open(yard: "demo", bead: "yd-4k2m", ask: 3)
        try await until("the card is read") { first.decision.state.read }
        first.decision.choose(2)
        await first.decision.pick()
        try await until("the question is answered") { first.decisions.state.open.isEmpty }
        first.decision.leave()

        // The yard switch's way out and the banner's are one: leave for
        // the Pair screen.
        first.inbox.pairAnother()
        XCTAssertNil(services.demo)
        XCTAssertFalse(services.nav.pairing)

        // Entered again, the demo is as new: the question is open.
        services.enterDemo()
        let second = try XCTUnwrap(services.demo)
        XCTAssertFalse(second === first)
        try await until("the demo yard is read again") { second.decisions.state.open.count == 1 }
        XCTAssertEqual(second.decisions.state.decided.count, 1)
        services.leaveDemo()
        XCTAssertNil(services.demo)
        // Leaving where no demo is open is nothing.
        services.leaveDemo()
        XCTAssertEqual(world.live.requests, [])
    }

    func testTheDemoFollowsTheAppToTheBackAndFront() async throws {
        let world = try makeWorld()
        let services = world.services
        services.enterDemo()
        let demo = try XCTUnwrap(services.demo)
        try await until("the demo yard is read") { demo.inbox.state.rows.contains { $0.name == "yardmaster" } }
        // The app to the back and the front again reads the yard again, as
        // for any yard: the demo follows the scene as the app's yards do.
        let transport = demo.transport
        let loads = transport.requests.filter { $0 == "GET /user/me" }.count
        services.setForeground(false)
        services.setForeground(true)
        try await until("the demo yard is read again") { transport.requests.filter { $0 == "GET /user/me" }.count > loads }
        services.leaveDemo()
        XCTAssertEqual(world.live.requests, [])
    }
}
