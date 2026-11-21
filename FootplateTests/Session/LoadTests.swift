@testable import Footplate
import Foundation
import XCTest

// load's reads against the fake yard: what the state starts from, and the
// calls that read it, in order.
final class LoadTests: XCTestCase {
    func testLoadReadsWhatTheScreensStartFrom() async throws {
        let fake = FakeYard()
        let session = fake.session()
        let laptopToken = fake.token(yardName: "laptop")
        let client = try fake.edge().yard(device: laptopToken, session: session, name: "laptop")
        let loaded = try await client.load()
        XCTAssertEqual(loaded.me.user, "jo")
        XCTAssertEqual(loaded.me.saidBy, "pixel")
        XCTAssertEqual(loaded.me.yard, "laptop")
        XCTAssertEqual(loaded.head, 151)
        XCTAssertEqual(loaded.settings.operator, "jo")
        XCTAssertEqual(loaded.user.cursor, 12)
        XCTAssertEqual(loaded.user.notificationCursor, 10)
        XCTAssertEqual(loaded.crew.map(\.name), ["signalman", "yardmaster"])
        XCTAssertEqual(loaded.users.map(\.name), ["jo"])
        XCTAssertEqual(loaded.inbox.unread, 2)
        XCTAssertEqual(loaded.inbox.mail.map(\.seq), [13, 51])
        XCTAssertEqual(loaded.notifications.notifications.count, 2)
        XCTAssertEqual(loaded.notifications.last, 11)
        XCTAssertEqual(loaded.asks.open.map(\.ask), [3, 7, 9])
        XCTAssertNil(loaded.asks.decided, "the load reads the open asks alone, and says nothing of the history")
        let calls = (1...10).map { _ in fake.taken() }
        XCTAssertEqual(
            calls.map(\.path),
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
                "/user/call/UserOpenAsks",
            ]
        )
        // Never the whole queue, on a yard that answers the open one; and
        // the open cards are the ones a whole read lists.
        let whole = try await client.userAsks(name: "jo")
        XCTAssertEqual(loaded.asks.open, whole.open)
        XCTAssertEqual(fake.allRequests.filter { $0.path == "/user/call/UserAsks" }.count, 1, "the one read made just now")
        // The inbox is counted first, then read with the unread and the
        // newest read, for the rows' first lines.
        XCTAssertEqual(limit(calls[6]), 1)
        XCTAssertEqual(limit(calls[7]), 2 + readLetters)
        XCTAssertEqual(limit(calls[8]), 0)
    }

    // A yard from before UserOpenAsks refuses it as a call it does not
    // have: the load reads the whole queue instead, once, and holds the
    // history it sent. Any other refusal is the load's, with no second read.
    func testLoadReadsTheWholeQueueFromAYardWithNoUserOpenAsks() async throws {
        let fake = FakeYard()
        let session = fake.session()
        let laptopToken = fake.token(yardName: "laptop")
        let client = try fake.edge().yard(device: laptopToken, session: session, name: "laptop")
        fake.nextFor(yard: "laptop", path: "/user/call/UserOpenAsks", .refused("no such method UserOpenAsks"))
        let loaded = try await client.load()
        XCTAssertEqual(loaded.asks.open.map(\.ask), [3, 7, 9])
        XCTAssertEqual(loaded.asks.decided?.map(\.state), ["declined"])
        XCTAssertEqual(Array(fake.allRequests.map(\.path).suffix(2)), ["/user/call/UserOpenAsks", "/user/call/UserAsks"])

        // Any other refusal: the load fails as a refused UserAsks failed it,
        // and no whole queue is read in its place.
        fake.nextFor(yard: "laptop", path: "/user/call/UserOpenAsks", .refused("the queue is not readable"))
        let before = fake.allRequests.count
        let error = await raisedApiError { _ = try await client.load() }
        XCTAssertEqual(error, .refused(code: "error", message: "the queue is not readable"))
        XCTAssertEqual(fake.allRequests.dropFirst(before).filter { $0.path.hasSuffix("Asks") }.map(\.path), ["/user/call/UserOpenAsks"])
    }

    func testAWildUnreadCountNeitherTrapsNorReadsAll() async throws {
        let fake = FakeYard()
        let session = fake.session()
        let laptopToken = fake.token(yardName: "laptop")
        func load() async throws -> Loaded {
            try await fake.edge().yard(device: laptopToken, session: session, name: "laptop").load()
        }
        // The yard counts more unread than the addition holds: the load
        // lives, and the second read is clamped, not wrapped.
        fake.next("/user/call/UserInbox", .json(200, #"{"result": {"mail": [{"seq": 13}], "unread": 9223372036854775807}}"#))
        _ = try await load()
        let huge = (1...10).map { _ in fake.taken() }
        XCTAssertEqual(limit(huge[6]), 1)
        XCTAssertEqual(limit(huge[7]), Int64.max)
        // A count that would land the limit on 0 reads the newest read
        // instead: 0 is the whole archive.
        fake.next("/user/call/UserInbox", .json(200, #"{"result": {"mail": [{"seq": 13}], "unread": -50}}"#))
        _ = try await load()
        let negative = (1...10).map { _ in fake.taken() }
        XCTAssertEqual(limit(negative[7]), readLetters)
    }

    private func limit(_ request: RecordedRequest) -> Int64 {
        (request.bodyObject()["limit"] as? NSNumber)?.int64Value ?? -1
    }
}
