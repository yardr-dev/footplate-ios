@testable import Footplate
import XCTest

// Registering for wakes (design 8787 section 3.2) against the fake
// edge: the token through the edge for each edge yard, on rotation
// and on launch, never for a yard of its own, and undone as a yard
// is forgotten — with no pairing anywhere in it.
@MainActor
final class PushRegisterTests: XCTestCase {
    private let fake = FakeYard()
    private var records: Records!
    private var registrar: PushRegistrar!
    private var secret: MemoryShelf!

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

    func testATokenRegistersEveryEdgeYardThroughTheEdge() async throws {
        pairLaptop()
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: fake.token(yardName: "")))
        await registrar.tokenReceived("apns-token-1")
        XCTAssertEqual("apns-token-1", fake.pushToken(yardName: "laptop"))
        XCTAssertEqual("apns-token-1", fake.pushToken(yardName: ""))
        // Each call went through the edge as a device call, with the
        // platform and token in its body alone.
        let registers = fake.allRequests.filter { $0.path == "/user/push/register" }
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
        await registrar.tokenReceived("apns-token-1")
        let afterFirst = fake.requestCount
        await registrar.tokenReceived("apns-token-1")
        XCTAssertEqual(afterFirst, fake.requestCount, "the row stands")
        await registrar.tokenReceived("apns-token-2")
        XCTAssertEqual("apns-token-2", fake.pushToken(yardName: "laptop"))
        // Nothing paired: no /user/pair was sent for the rotation.
        XCTAssertTrue(fake.allRequests.allSatisfy { $0.path != "/user/pair" }, "\(fake.allRequests.map(\.path))")
    }

    func testEveryLaunchRegistersAgain() async throws {
        pairLaptop()
        await registrar.tokenReceived("apns-token-1")
        // The relay's store is the router's alone; a launch tells it
        // again, as a restored relay holds no row.
        let before = fake.allRequests.count { $0.path == "/user/push/register" }
        await registrar.launch()
        XCTAssertEqual(before + 1, fake.allRequests.count { $0.path == "/user/push/register" })
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
