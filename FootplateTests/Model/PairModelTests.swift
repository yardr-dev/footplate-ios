@testable import Footplate
import XCTest

// The Pair and Sign in models against the fake yard (design 3.2):
// a pairing end to end, a second yard on the session the first
// left, the pairing's and the sign-in's refusals, a QR of another
// origin that sends nothing, and forgetting one yard and then the
// last.
@MainActor
final class PairModelTests: XCTestCase {
    private struct World {
        var fake: FakeYard
        var secret: MemoryShelf
        var plain: MemoryShelf
        var records: Records
        var edge: Edge
        var pairer: Pairer
        var nav: Nav
        var pair: PairModel
        var signIn: SignInModel
    }

    private func makeWorld() throws -> World {
        let fake = FakeYard()
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        let records = Records(secret: secret, plain: plain, origin: fake.origin)
        let edge = try fake.edge()
        let pairer = Pairer(edge: edge, records: records)
        let nav = Nav()
        return World(
            fake: fake, secret: secret, plain: plain, records: records, edge: edge,
            pairer: pairer, nav: nav,
            pair: PairModel(pairer: pairer, records: records, nav: nav),
            signIn: SignInModel(pairer: pairer, records: records, nav: nav)
        )
    }

    /// The pairing goes on by itself once a session is kept: its end
    /// is the yards paired and the Pair screen back at its start.
    private func waitForYards(_ world: World, _ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while world.records.kept.yards.count < count || world.pair.state.step != .choose {
            if ContinuousClock.now > deadline {
                XCTFail("the pairing did not finish; yards=\(world.records.kept.yards.map(\.name)), step=\(world.pair.state.step)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Signs in through the cover the pairing asked for.
    private func signInAs(_ world: World, password: String? = nil) async {
        guard let request = world.nav.signIn else {
            XCTFail("expected the Sign in cover, got \(String(describing: world.nav.signIn))")
            return
        }
        world.signIn.opened(again: request.again)
        if !request.again { world.signIn.email(world.fake.email) }
        world.signIn.password(password ?? world.fake.password)
        await world.signIn.signIn()
    }

    /// The laptop yard paired from its QR, signing in on the way.
    private func pairLaptop(_ world: World) async throws {
        world.pair.scanned("\(world.fake.origin)#\(world.fake.laptop.code ?? "")#laptop")
        await world.pair.pair()
        try await signInAs(world)
        await waitForYards(world, 1)
    }

    func testAPairingEndToEnd() async throws {
        let world = try makeWorld()
        world.pair.scanned("\(world.fake.origin)#m4tr9kwe#laptop")
        XCTAssertEqual(world.pair.state.step, .read(PairingCode(code: "M4TR-9KWE", yard: "laptop")))
        // Reading the code sent nothing.
        XCTAssertEqual(world.fake.requestCount, 0)

        // No session yet: Pair asks for the sign-in first, and goes
        // on by itself once it is kept.
        await world.pair.pair()
        XCTAssertEqual(world.nav.signIn, SignInRequest(again: false))
        try await signInAs(world)
        await waitForYards(world, 1)
        XCTAssertEqual(world.pair.state, PairState())
        // The password is held nowhere once sent.
        XCTAssertEqual(world.signIn.state.password, "")

        let requests = world.fake.allRequests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].path, "/kratos/self-service/login/api")
        XCTAssertTrue(requests[1].path.hasPrefix("/kratos/self-service/login?flow="), requests[1].path)
        let session = try XCTUnwrap(world.records.kept.account?.session)
        XCTAssertEqual(requests[2].path, "/user/pair")
        XCTAssertEqual(requests[2].header("X-Edge-Token"), session)
        XCTAssertEqual(requests[2].header("X-Edge-Yard"), "laptop")
        XCTAssertNil(requests[2].header("Authorization"))
        XCTAssertEqual(requests[2].bodyObject()["code"] as? String, "M4TR-9KWE")
        XCTAssertEqual(requests[3].path, "/user/me")
        let token = try XCTUnwrap(world.records.kept.yards.first?.token)
        XCTAssertEqual(requests[3].header("Authorization"), "Bearer \(token)")
        XCTAssertEqual(requests[3].header("X-Edge-Yard"), "laptop")

        // Both tokens kept, the yard selected, and the head line says it.
        let kept = world.records.kept
        XCTAssertEqual(kept.account?.account, "jo@example.com")
        XCTAssertEqual(kept.yards.map(\.name), ["laptop"])
        XCTAssertEqual(kept.selected, "laptop")
        XCTAssertEqual(kept.selectedYard.map { "\($0.title) · \($0.user)" }, "laptop · jo")
    }

    func testASecondYardIsPairedOnTheSessionTheFirstLeft() async throws {
        let world = try makeWorld()
        try await pairLaptop(world)
        let session = try XCTUnwrap(world.records.kept.account?.session)
        let baseline = world.fake.requestCount

        // Pair another yard: the account's own, typed, no sign-in.
        world.nav.showPair()
        world.pair.typeCode()
        world.pair.typed(yard: "", code: "k7qm2xpd")
        world.pair.readTyped()
        XCTAssertEqual(world.pair.state.step, .read(PairingCode(code: "K7QM-2XPD", yard: "")))
        await world.pair.pair()
        XCTAssertFalse(world.nav.pairing)
        XCTAssertEqual(world.nav.place, .crew)

        let sent = Array(world.fake.allRequests[baseline...])
        XCTAssertEqual(sent.map(\.path), ["/user/pair", "/user/me"])
        XCTAssertTrue(sent.allSatisfy { $0.header("X-Edge-Token") == session })
        XCTAssertTrue(sent.allSatisfy { $0.header("X-Edge-Yard") == nil })
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["laptop", ""])
        XCTAssertEqual(world.records.kept.selected, "")
        XCTAssertEqual(world.records.kept.selectedYard?.yard, "south")
    }

    func testAWrongCodeAndAnEndedPairingAreSaid() async throws {
        let world = try makeWorld()
        world.records.keepSession(account: world.fake.email, session: world.fake.session())
        world.pair.typeCode()
        world.pair.typed(yard: "laptop", code: "AAAA-BBBB")
        world.pair.readTyped()
        await world.pair.pair()
        XCTAssertEqual(
            world.pair.state.error,
            "That is not the code. The yard counts a wrong one, and the fifth ends the pairing."
        )
        XCTAssertNil(world.nav.signIn)
        XCTAssertFalse(world.nav.pairing)

        // The pairing ran out: the yard has none open.
        world.fake.laptop.code = nil
        world.pair.typed(yard: "laptop", code: "M4TR-9KWE")
        world.pair.readTyped()
        await world.pair.pair()
        XCTAssertTrue(world.pair.state.error?.hasPrefix("No pairing is open at this yard") == true, world.pair.state.error ?? "")
        XCTAssertTrue(world.records.kept.yards.isEmpty)
        XCTAssertNil(world.nav.signIn)
        XCTAssertFalse(world.nav.pairing)
    }

    func testARefusedSignInIsSaidAndKeepsNothing() async throws {
        let world = try makeWorld()
        world.pair.scanned("\(world.fake.origin)#\(world.fake.laptop.code ?? "")#laptop")
        await world.pair.pair()
        try await signInAs(world, password: "wrong")
        let state = world.signIn.state
        XCTAssertTrue(state.error?.hasPrefix("The sign-in failed: The provided credentials are invalid") == true, state.error ?? "")
        XCTAssertFalse(state.error?.contains("wrong") == true, state.error ?? "")
        XCTAssertEqual(state.password, "")
        XCTAssertNil(world.records.kept.account)
        XCTAssertEqual(world.nav.signIn, SignInRequest(again: false))
        XCTAssertEqual(
            world.fake.allRequests.map { $0.path.split(separator: "?").first.map(String.init) ?? $0.path },
            ["/kratos/self-service/login/api", "/kratos/self-service/login"]
        )
    }

    func testASessionThatRanOutCanResumeOrAbandonPairing() async throws {
        let world = try makeWorld()
        world.records.keepSession(account: world.fake.email, session: "ory_st_revoked")
        world.pair.scanned("\(world.fake.origin)#\(world.fake.laptop.code ?? "")#laptop")
        await world.pair.pair()
        XCTAssertEqual(world.nav.signIn, SignInRequest(again: true))
        world.signIn.opened(again: true)
        XCTAssertEqual(world.signIn.state, SignInState(email: world.fake.email, password: "", again: true, busy: false, error: nil))
        // The email is the account's: not typed over.
        world.signIn.email("someone@else.example")
        XCTAssertEqual(world.signIn.state.email, world.fake.email)
        try await signInAs(world)
        await waitForYards(world, 1)
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["laptop"])
        XCTAssertNotEqual(world.records.kept.account?.session, "ory_st_revoked")

        // A pairing cover dismissed after the renewed session was
        // requested drops its pending code. Signing in later cannot
        // pair that abandoned yard in the background.
        let renewed = try XCTUnwrap(world.records.kept.account?.session)
        try await world.edge.logout(session: renewed)
        let pairCalls = world.fake.allRequests.filter { $0.path == "/user/pair" }.count
        world.nav.showPair()
        world.pair.typeCode()
        world.pair.typed(yard: "", code: world.fake.home.code ?? "")
        world.pair.readTyped()
        await world.pair.pair()
        XCTAssertEqual(world.nav.signIn, SignInRequest(again: true))
        world.pair.close()
        XCTAssertEqual(world.pair.state, PairState())
        world.nav.pairing = false
        world.nav.signIn = nil
        world.nav.showSignIn(again: true)
        try await signInAs(world)
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["laptop"])
        XCTAssertFalse(world.nav.pairing)
        XCTAssertEqual(world.fake.allRequests.filter { $0.path == "/user/pair" }.count, pairCalls + 1)

        // A restart with the session item missing still knows which
        // account must sign in, without keeping its session token.
        world.secret.write(remove: ["account"])
        let restartedRecords = Records(secret: world.secret, plain: world.plain, origin: world.fake.origin)
        XCTAssertNil(restartedRecords.kept.account)
        XCTAssertEqual(restartedRecords.accountNameForSignIn, world.fake.email)
        let restartedSignIn = SignInModel(
            pairer: Pairer(edge: world.edge, records: restartedRecords),
            records: restartedRecords,
            nav: Nav()
        )
        restartedSignIn.opened(again: true)
        XCTAssertEqual(restartedSignIn.state.email, world.fake.email)
        XCTAssertTrue(restartedSignIn.state.again)
    }

    func testAQRNamingAnotherOriginSendsNothingAnywhere() async throws {
        let world = try makeWorld()
        world.pair.scanned("https://other.example#\(world.fake.laptop.code ?? "")#laptop")
        XCTAssertEqual(
            world.pair.state.error,
            "This code is for https://other.example. footplate speaks to \(world.fake.origin) alone."
        )
        XCTAssertEqual(world.pair.state.step, .choose)
        await world.pair.pair()
        XCTAssertNil(world.nav.signIn)
        XCTAssertFalse(world.nav.pairing)
        XCTAssertEqual(world.fake.requestCount, 0)
    }

    func testForgettingOneOfTwoYardsAndThenTheLast() async throws {
        let world = try makeWorld()
        try await pairLaptop(world)
        let session = try XCTUnwrap(world.records.kept.account?.session)
        world.records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: world.fake.token(yardName: "")))
        world.records.select("laptop")
        let baseline = world.fake.requestCount

        try await world.pairer.forget(name: "laptop")
        XCTAssertEqual(world.records.kept.yards.map(\.name), [""])
        XCTAssertEqual(world.records.kept.account?.session, session)
        let afterFirst = Array(world.fake.allRequests[baseline...])
        XCTAssertTrue(afterFirst.allSatisfy { !$0.path.hasPrefix("/kratos") }, "\(afterFirst.map(\.path))")

        // The last: Kratos's logout, and every record gone.
        try await world.pairer.forget(name: "")
        let afterLast = Array(world.fake.allRequests[(baseline + afterFirst.count)...])
        XCTAssertEqual(afterLast.count, 1)
        XCTAssertEqual(afterLast[0].method, "DELETE")
        XCTAssertEqual(afterLast[0].path, "/kratos/self-service/logout/api")
        XCTAssertEqual(afterLast[0].bodyObject()["session_token"] as? String, session)
        XCTAssertEqual(world.records.kept, Kept())
        XCTAssertTrue(world.secret.map.isEmpty, "\(world.secret.map)")
        let recordKeys = world.plain.map.keys.filter {
            $0 == "origin" || $0 == "account" || $0 == "selected" || $0.hasPrefix("yard-meta:")
        }
        XCTAssertTrue(recordKeys.isEmpty, "\(world.plain.map)")
        // The edge forgot the session: a call with it is refused.
        let yard = try world.edge.yard(device: world.fake.token(yardName: ""), session: session)
        var thrown: ApiError?
        do { _ = try await yard.head() } catch let caught as ApiError { thrown = caught }
        XCTAssertEqual(thrown, .notSignedIn)
    }
}
