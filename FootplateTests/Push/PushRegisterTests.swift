@testable import Footplate
import XCTest

// Registering for wakes (design 8787 section 3.2) against the fake
// edge: the token through the edge for each edge yard, on rotation
// and on launch, never for a yard of its own, and undone as a yard
// is forgotten — with no pairing anywhere in it. A row once made
// stands: a publish of the records that pairs no yard sends nothing.
@MainActor
final class PushRegisterTests: XCTestCase {
    private let fake = FakeYard()
    private var records: Records!
    private var registrar: PushRegistrar!
    private var secret: MemoryShelf!
    /// What the app does with each publish of the records (the
    /// observer in FootplateApp): the registrar is told the yards
    /// changed, on a task of its own. The tasks are kept, to be waited on.
    private var told: [Task<Void, Never>] = []

    override func setUp() async throws {
        try await super.setUp()
        records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
        secret = MemoryShelf()
        registrar = PushRegistrar(edge: try fake.edge(), records: records, secret: secret)
    }

    private func pairLaptop() {
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: fake.token(yardName: "laptop")))
    }

    private func pairHome() {
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: fake.token(yardName: "")))
    }

    /// A pairing of alice's yard, with a device token of its own.
    private func lab() -> PairedYard {
        PairedYard(name: "alice/lab", yard: "lab", user: "joe", device: "phone", token: fake.token(yardName: "alice/lab"))
    }

    private func registerRequests() -> [RecordedRequest] {
        fake.allRequests.filter { $0.path == "/user/push/register" }
    }

    /// The yard each register call was for, in order: its name at the
    /// edge, empty for the account's own.
    private func registeredYards() -> [String] {
        registerRequests().map { $0.header("X-Edge-Yard") ?? "" }
    }

    private func wireTheObserver() {
        let registrar = self.registrar!
        _ = records.observe { [weak self] _ in
            self?.told.append(Task { await registrar.yardsChanged() })
        }
    }

    /// Waits for the registrar to be through with what the publishes told it.
    private func settle() async {
        for task in told { await task.value }
        told.removeAll()
    }

    func testATokenRegistersEveryEdgeYardThroughTheEdge() async throws {
        pairLaptop()
        pairHome()
        await registrar.tokenReceived("apns-token-1")
        XCTAssertEqual("apns-token-1", fake.pushToken(yardName: "laptop"))
        XCTAssertEqual("apns-token-1", fake.pushToken(yardName: ""))
        // Each call went through the edge as a device call, with the
        // platform and token in its body alone.
        let registers = registerRequests()
        XCTAssertEqual(2, registers.count)
        for request in registers {
            XCTAssertEqual("POST", request.method)
            XCTAssertEqual(fake.allRequests.first { $0.path == "/user/push/register" }?.header("X-Edge-Token"), request.header("X-Edge-Token"))
            assertBody(request, #"{"platform":"apns","token":"apns-token-1"}"#)
            XCTAssertNotNil(request.header("Authorization"))
        }
        // The token is kept on the secret shelf, beside no other.
        XCTAssertEqual("apns-token-1", secret.map["push-token"])
    }

    func testTheSameTokenAgainRegistersNothingAndARotationRegistersWithoutPairing() async throws {
        pairLaptop()
        pairHome()
        await registrar.tokenReceived("apns-token-1")
        let afterFirst = fake.requestCount
        await registrar.tokenReceived("apns-token-1")
        XCTAssertEqual(afterFirst, fake.requestCount, "the row stands")
        // A rotation is no row's token: every yard is told it.
        await registrar.tokenReceived("apns-token-2")
        XCTAssertEqual("apns-token-2", fake.pushToken(yardName: "laptop"))
        XCTAssertEqual("apns-token-2", fake.pushToken(yardName: ""))
        XCTAssertEqual(["laptop", "", "laptop", ""], registeredYards())
        // Nothing paired: no /user/pair was sent for the rotation.
        XCTAssertTrue(fake.allRequests.allSatisfy { $0.path != "/user/pair" }, "\(fake.allRequests.map(\.path))")
    }

    func testEveryLaunchRegistersAgain() async throws {
        pairLaptop()
        pairHome()
        await registrar.tokenReceived("apns-token-1")
        // The relay's store is the router's alone; a launch tells it
        // again, as a restored relay holds no row: every yard's, though
        // the rows this run made stand in its memory.
        let before = registerRequests().count
        await registrar.launch()
        XCTAssertEqual(before + 2, registerRequests().count)
        XCTAssertEqual(["laptop", "", "laptop", ""], registeredYards())
    }

    func testPickingAYardSendsNoRegistrationAndPairingAYardSendsOneForIt() async throws {
        wireTheObserver()
        pairLaptop()
        pairHome()
        // Paired before any token: the publishes find nothing to send.
        await settle()
        await registrar.tokenReceived("apns-token-1")
        XCTAssertEqual(["laptop", ""], registeredYards())

        // A pick publishes the records, and so does keeping a session
        // again: the rows stand, and nothing goes to the relay.
        records.select("laptop")
        records.select("")
        records.keepSession(account: fake.email, session: fake.session())
        await settle()
        XCTAssertEqual(["laptop", ""], registeredYards())

        // A third yard is kept as the pairing keeps it, twice, the
        // second while the first call may be in flight: one call, for it.
        let lab = lab()
        records.keepYard(lab)
        records.keepYard(lab)
        await settle()
        XCTAssertEqual(["laptop", "", "alice/lab"], registeredYards())
        XCTAssertEqual("apns-token-1", fake.pushToken(yardName: "alice/lab"))

        // And a pick among three still sends nothing.
        records.select("alice/lab")
        await settle()
        XCTAssertEqual(["laptop", "", "alice/lab"], registeredYards())
    }

    func testAYardForgottenAndPairedAgainIsRegisteredAnew() async throws {
        wireTheObserver()
        let laptop = PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: fake.token(yardName: "laptop"))
        records.keepYard(laptop)
        await settle()
        await registrar.tokenReceived("apns-token-1")
        XCTAssertEqual(["laptop"], registeredYards())

        // Forgotten as the pairer forgets it: the row undone while the
        // credentials stand, then the record deleted. Nothing is
        // registered by that, and nothing of the row is remembered:
        // the very same record kept again is told the token.
        await registrar.unregister(yard: laptop)
        records.forgetYard("laptop")
        await settle()
        XCTAssertNil(fake.pushToken(yardName: "laptop"))
        XCTAssertEqual(["laptop"], registeredYards())
        records.keepYard(laptop)
        await settle()
        XCTAssertEqual(["laptop", "laptop"], registeredYards())
        XCTAssertEqual("apns-token-1", fake.pushToken(yardName: "laptop"))

        // Paired again with no forgetting between, as the pairer lets a
        // yard be: a new device, which has no row of its own yet.
        pairLaptop()
        await settle()
        XCTAssertEqual(["laptop", "laptop", "laptop"], registeredYards())
        XCTAssertEqual("Bearer \(records.kept.yards[0].token)", registerRequests().last?.header("Authorization"))
    }

    func testARefusedRegistrationIsTriedAgainAtTheNextChange() async throws {
        wireTheObserver()
        fake.nextFor(yard: "laptop", path: "/user/push/register", FakeResponse(status: 500, text: "try again\n"))
        pairLaptop()
        pairHome()
        await settle()
        await registrar.tokenReceived("apns-token-1")
        // The laptop's call was refused and left no row; the other
        // landed.
        XCTAssertNil(fake.pushToken(yardName: "laptop"))
        XCTAssertEqual("apns-token-1", fake.pushToken(yardName: ""))
        XCTAssertEqual(["laptop", ""], registeredYards())

        // The next change that is no pairing tries the laptop again,
        // and only it.
        records.select("laptop")
        await settle()
        XCTAssertEqual("apns-token-1", fake.pushToken(yardName: "laptop"))
        XCTAssertEqual(["laptop", "", "laptop"], registeredYards())
    }

    func testAYardOfItsOwnIsNeverRegistered() async throws {
        records.keepYard(PairedYard(
            name: "yard.example.net", yard: "south", user: "jo", device: "phone",
            token: "yardr-dev-south-9", origin: "https://yard.example.net"
        ))
        await registrar.tokenReceived("apns-token-1")
        XCTAssertTrue(fake.allRequests.isEmpty, "no router stands in front of it")
    }

    func testForgettingAYardUndoesItsRowWhileItsCredentialsStand() async throws {
        pairLaptop()
        await registrar.tokenReceived("apns-token-1")
        XCTAssertEqual("apns-token-1", fake.pushToken(yardName: "laptop"))
        let laptop = records.kept.yards[0]
        await registrar.unregister(yard: laptop)
        XCTAssertNil(fake.pushToken(yardName: "laptop"))
        let last = fake.allRequests.last
        XCTAssertEqual("/user/push/unregister", last?.path)
        XCTAssertEqual("POST", last?.method)
    }

    func testTheTokenIsHexAsTheSystemGivesIt() {
        XCTAssertEqual("00ff10", apnsTokenHex(Data([0x00, 0xff, 0x10])))
        XCTAssertEqual("", apnsTokenHex(Data()))
    }
}
