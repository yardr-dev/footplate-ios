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
        let loaded = try await fake.edge().yard(device: laptopToken, session: session, name: "laptop").load()
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
        XCTAssertEqual(loaded.asks.decided.count, 1)
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
                "/user/call/UserAsks",
            ]
        )
        // The inbox is counted first, then read with the unread and the
        // newest read, for the rows' first lines.
        XCTAssertEqual(limit(calls[6]), 1)
        XCTAssertEqual(limit(calls[7]), 2 + readLetters)
        XCTAssertEqual(limit(calls[8]), 0)
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
