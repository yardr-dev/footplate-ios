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
        // Until the yard takes the key its calls go plain, and its
        // row says nothing of a channel.
        XCTAssertNil(try XCTUnwrap(records.kept.yards.first).channelNote())
        let refused = await migrateInPlace(records: records, edge: try fake.edge(), session: session)
        XCTAssertTrue(refused.isEmpty)
        // One registration, under the token, plainly, carrying the
        // public half of the key the phone made.
        XCTAssertEqual(registrations().count, 1)
        let yard = try XCTUnwrap(records.kept.yards.first)
        XCTAssertEqual(yard.sealedHow, "in place")
        XCTAssertNotNil(yard.channel)
        // Taken, the yard reads sealed, with the line that lasts.
        XCTAssertEqual(yard.channelNote(), "sealed (in place)")
        XCTAssertEqual(
            yard.channelCaveat,
            "An edge that cheated when this phone registered its key could read its calls. Pairing again by QR gives full protection."
        )
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
        // yard refuses the phone's key, and nothing is pinned. A
        // second yard refuses too: the app's notice names the
        // first, and each yard's row says its own.
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: fake.token(yardName: "laptop")))
        records.makeMigrationKeys()
        let session = records.kept.account!.session
        let yardBefore = try XCTUnwrap(records.kept.yards.first)
        XCTAssertNil(yardBefore.channelNote(refused: records.keyRefused(yardBefore)))
        var plain: YardClient?
        for yard in records.kept.yards {
            let client = try fake.edge().yard(device: yard.token, session: session, name: yard.name)
            _ = try await client.registerChannelKey(devicePublic: try makeDeviceKey().devicePublic)
            plain = plain ?? client
        }
        let refused = await migrateInPlace(records: records, edge: try fake.edge(), session: session)
        XCTAssertEqual(refused.map(\.name), ["", "laptop"])
        for yard in records.kept.yards {
            XCTAssertNil(yard.yardChannelPublic, yard.name)
            XCTAssertNil(yard.channel, yard.name)
            XCTAssertEqual(yard.sealedHow, "in place", yard.name)
            // The refusal is noted for the row, which says so: the yard's
            // key stands unregistered, and its calls stay plain.
            XCTAssertTrue(records.keyRefused(yard), yard.name)
            XCTAssertEqual(yard.channelNote(refused: records.keyRefused(yard)), "could not be sealed", yard.name)
            XCTAssertNil(yard.channelCaveat, yard.name)
        }
        // And its plain calls stand as they did.
        let me = try await XCTUnwrap(plain).me()
        XCTAssertEqual(me.user, "jo")
    }

    func testARefusedYardIsNotAskedAgainInTheSession() async throws {
        // The key registered for the device already refuses the phone's.
        let yard = try XCTUnwrap(records.kept.yards.first)
        let session = records.kept.account!.session
        _ = try await fake.edge().yard(device: yard.token, session: session, name: "")
            .registerChannelKey(devicePublic: try makeDeviceKey().devicePublic)
        XCTAssertEqual(registrations().count, 1)

        let services = AppServices(edge: try fake.edge(), records: records, secret: MemoryShelf())
        let previousDelegate = UNUserNotificationCenter.current().delegate
        addTeardownBlock { @MainActor in
            services.setForeground(false)
            self.fake.closeStreams()
            UNUserNotificationCenter.current().delegate = previousDelegate
        }
        // The launch asks once and is refused; the yard, held out of the
        // followers meanwhile, is followed plainly after, and its row says so.
        let deadline = ContinuousClock.now + .seconds(10)
        while services.followers[""] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(services.followers[""], "the refused yard is followed again")
        XCTAssertEqual(registrations().count, 2)
        XCTAssertTrue(records.keyRefused(yard))
        XCTAssertEqual(services.nav.notice, "south could not be sealed: the yard refused its channel key. Pair again by QR to seal it.")

        // A change of the records follows the yards again, and asks again
        // of whatever waits for a registration: a retry would hold the
        // yard out of the followers in this very call, and send its
        // registration a second time. The refused yard is neither.
        records.select("")
        XCTAssertNotNil(services.followers[""], "no retry holds the refused yard out again")
        XCTAssertEqual(registrations().count, 2)
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
