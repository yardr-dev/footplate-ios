@testable import Footplate
import UserNotifications
import XCTest

// Migration in place (design 3.4 (b), yardr-n9d2): a phone
// paired before the channel makes its key, registers it under
// its token on first launch, pins the yard's key from the
// answer, and calls sealed from then on. A second launch makes
// no second registration; a refusal pins nothing.
@MainActor
final class MigrationTests: XCTestCase {
    private let fake = FakeYard()
    private var records: Records!

    override func setUp() async throws {
        try await super.setUp()
        records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        // A yard paired before the channel: a token, and no key.
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: fake.token(yardName: "")))
        records.makeMigrationKeys()
    }

    private func registrations() -> [RecordedRequest] {
        fake.allRequests.filter { $0.path == "/user/call/RegisterChannelKey" }
    }

    func testFirstLaunchRegistersInPlaceAndCallsSealedFromThenOn() async throws {
        let session = records.kept.account!.session
        let refused = await migrateInPlace(records: records, edge: try fake.edge(), session: session)
        XCTAssertTrue(refused.isEmpty)
        // One registration, under the token, plainly, carrying the
        // public half of the key the phone made.
        XCTAssertEqual(registrations().count, 1)
        let yard = try XCTUnwrap(records.kept.yards.first)
        XCTAssertEqual(yard.sealedHow, "in place")
        XCTAssertNotNil(yard.channel)
        XCTAssertEqual(yard.channelNote, "not yet sealed")
        let body = registrations().first?.bodyObject()
        XCTAssertEqual(body?["channel_key"] as? String, channelPublicString(yard.channel!.devicePublic))
        // From then on the yard is called sealed, as a paired one.
        let client = try fake.edge().yard(device: yard.token, session: session, name: yard.name, channel: yard.channel)
        let me = try await client.me()
        XCTAssertEqual(me.user, "jo")
        XCTAssertTrue(fake.allRequests.filter { $0.path == "/user/me" }.isEmpty)
        // A second launch makes no second registration.
        let again = await migrateInPlace(records: records, edge: try fake.edge(), session: session)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(registrations().count, 1)
    }

    func testARefusedRegistrationPinsNothingAndLeavesTheYardAsItWas() async throws {
        // Another key stands registered for this device already
        // (registered by a stranger call under its token): the
        // yard refuses the phone's key, and nothing is pinned.
        let yardBefore = try XCTUnwrap(records.kept.yards.first)
        let stranger = try makeDeviceKey()
        let plain = try fake.edge().yard(device: yardBefore.token, session: records.kept.account!.session, name: "")
        _ = try await plain.registerChannelKey(devicePublic: stranger.devicePublic)
        let refused = await migrateInPlace(records: records, edge: try fake.edge(), session: records.kept.account!.session)
        XCTAssertEqual(refused.map(\.name), [""])
        let yard = try XCTUnwrap(records.kept.yards.first)
        XCTAssertNil(yard.yardChannelPublic)
        XCTAssertNil(yard.channel)
        XCTAssertEqual(yard.sealedHow, "in place")
        // And its plain calls stand as they did.
        let me = try await plain.me()
        XCTAssertEqual(me.user, "jo")
    }

    func testMigrationAfterSignInPrecedesFollowingAndRebuildsASealedClient() async throws {
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepYard(PairedYard(
            name: "", yard: "south", user: "jo", device: "phone", token: fake.token(yardName: "")
        ))
        let edge = try fake.edge()
        let services = AppServices(edge: edge, records: records, secret: MemoryShelf())
        let previousDelegate = UNUserNotificationCenter.current().delegate
        addTeardownBlock { @MainActor in
            services.setForeground(false)
            self.fake.closeStreams()
            UNUserNotificationCenter.current().delegate = previousDelegate
        }
        services.setForeground(true)

        let pinned = expectation(description: "the in-place key is pinned")
        let observer = records.observe { kept in
            if kept.yards.first?.channel != nil {
                pinned.fulfill()
            }
        }
        defer { records.removeObserver(observer) }

        // This phone had lost its edge session before the update. Sign-in
        // later in this launch must still trigger the one-time migration.
        try await services.pairer.signIn(email: fake.email, password: fake.password)
        try await waitForRequests(fake, 4)
        await fulfillment(of: [pinned], timeout: 10)
        try await waitForRequests(fake, 5)

        let userRequests = fake.allRequests.filter { $0.path.hasPrefix("/user/") }
        XCTAssertEqual("/user/call/RegisterChannelKey", userRequests.first?.path)
        XCTAssertTrue(userRequests.dropFirst().allSatisfy { $0.path == "/user/e2e" }, "\(userRequests.map(\.path))")
    }
}
