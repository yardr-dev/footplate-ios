@testable import Footplate
import XCTest

// The Pair and Sign in models against the fake yard (design 3.2):
// a pairing end to end, a second yard on the session the first
// left, the pairing's and the sign-in's refusals, a yard of its own
// paired with no sign-in from a typed address or its QR, kept under
// the name its address gives it beside the edge's own yard and
// beside another of its own, a second yard under a kept name refused
// before anything is sent, a QR of no usable address that sends
// nothing, a yard of another account the account is a member of paired
// on the session alone and named by its owner, and forgetting one yard
// and then the last.
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
        XCTAssertEqual(kept.account?.handle, "jo")
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
        XCTAssertEqual(world.pair.state.step, .read(PairingCode(code: "K7QM-2XPD", yard: "", typed: true)))
        await world.pair.pair()
        XCTAssertFalse(world.nav.pairing)
        XCTAssertEqual(world.nav.place, .crew)

        // A typed code took no key from a QR, so it is redeemed through
        // the PAKE: three posts of one run, each with the session beside
        // it, and the device's `/user/me` then rides the channel the run
        // pinned (its handshake, then the sealed call) with no token.
        let sent = Array(world.fake.allRequests[baseline...])
        XCTAssertEqual(sent.map(\.path), ["/user/pair", "/user/pair", "/user/pair", "/user/e2e", "/user/e2e"])
        XCTAssertEqual(
            sent.prefix(3).map { ($0.bodyObject()["pake"] as? [String: Any])?["step"] as? String },
            ["start", "confirm", "finish"]
        )
        XCTAssertTrue(sent.allSatisfy { $0.header("X-Edge-Token") == session })
        XCTAssertTrue(sent.allSatisfy { $0.header("X-Edge-Yard") == nil })
        XCTAssertTrue(sent.allSatisfy { $0.header("Authorization") == nil })
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["laptop", ""])
        XCTAssertEqual(world.records.kept.selected, "")
        XCTAssertEqual(world.records.kept.selectedYard?.yard, "south")
        XCTAssertEqual(world.records.kept.selectedYard?.sealedHow, "paired")
        XCTAssertNotNil(world.records.kept.selectedYard?.channel)

        // And a yard of another account the account is a member of, the
        // third: its code names it `owner/yard`, which is how the edge
        // names it and what every call carries, with the member's own
        // session beside the code and no device token on the pairing.
        let beforeMember = world.fake.requestCount
        world.nav.showPair()
        world.pair.scanned("\(world.fake.origin)#\(world.fake.lab.code ?? "")#alice/lab")
        XCTAssertEqual(world.pair.state.step, .read(PairingCode(code: "R2VH-6NQD", yard: "alice/lab")))
        await world.pair.pair()
        XCTAssertFalse(world.nav.pairing)
        let member = Array(world.fake.allRequests[beforeMember...])
        XCTAssertEqual(member.map(\.path), ["/user/pair", "/user/me"])
        XCTAssertTrue(member.allSatisfy { $0.header("X-Edge-Token") == session })
        XCTAssertTrue(member.allSatisfy { $0.header("X-Edge-Yard") == "alice/lab" })
        XCTAssertNil(member[0].header("Authorization"))
        XCTAssertEqual(member[0].bodyObject()["code"] as? String, "R2VH-6NQD")
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["laptop", "", "alice/lab"])
        let kept = try XCTUnwrap(world.records.kept.selectedYard)
        XCTAssertEqual(kept.name, "alice/lab")
        XCTAssertEqual(kept.owner, "alice")
        XCTAssertEqual(kept.yard, "lab")
        XCTAssertEqual("\(kept.title) · \(kept.user)", "lab — member of alice's yard · joe")
        // The yard's calls carry the same name: the client the app
        // follows it with is made from the record.
        let yard = try world.edge.yard(device: kept.token, session: session, name: kept.name)
        _ = try await yard.head()
        XCTAssertEqual(world.fake.allRequests.last?.header("X-Edge-Yard"), "alice/lab")
    }

    func testAYardSpelledWithTheAccountsOwnHandleIsKeptAsItsOwn() async throws {
        let world = try makeWorld()
        // The account `jo` types its own yard the way another account's
        // is named: the edge reads it as its own, and so is it kept, by
        // its bare name, never called a yard of another account's.
        world.pair.typeCode()
        world.pair.typed(yard: "jo/laptop", code: world.fake.laptop.code ?? "")
        world.pair.readTyped()
        XCTAssertEqual(world.pair.state.step, .read(PairingCode(code: "M4TR-9KWE", yard: "jo/laptop", typed: true)))
        await world.pair.pair()
        await signInAs(world)
        await waitForYards(world, 1)
        let pairing = try XCTUnwrap(world.fake.allRequests.first { $0.path == "/user/pair" })
        XCTAssertEqual(pairing.header("X-Edge-Yard"), "laptop")
        let kept = try XCTUnwrap(world.records.kept.selectedYard)
        XCTAssertEqual(kept.name, "laptop")
        XCTAssertEqual(kept.owner, "")
        XCTAssertEqual(kept.title, "laptop")

        // A session kept before the handle was has none to compare: the
        // edge says whose it is, once, and the answer is kept. Its own
        // yard spelled so is its own, and another account's stays so.
        let legacy = try makeWorld()
        legacy.records.keepSession(account: legacy.fake.email, session: legacy.fake.session())
        XCTAssertEqual(legacy.records.kept.account?.handle, "")
        legacy.fake.next("/kratos/sessions/whoami", .json(200, #"{"identity": {"traits": {"email": "jo@example.com", "handle": "jo"}}}"#))
        // The own yard is typed; the other account's is scanned, since a
        // code typed for another account's yard is refused (below).
        legacy.nav.showPair()
        legacy.pair.typeCode()
        legacy.pair.typed(yard: "jo/laptop", code: legacy.fake.laptop.code ?? "")
        legacy.pair.readTyped()
        await legacy.pair.pair()
        legacy.nav.showPair()
        legacy.pair.scanned("\(legacy.fake.origin)#\(legacy.fake.lab.code ?? "")#alice/lab")
        await legacy.pair.pair()
        XCTAssertEqual(
            legacy.fake.allRequests.map(\.path),
            ["/kratos/sessions/whoami", "/user/pair", "/user/pair", "/user/pair", "/user/e2e", "/user/e2e", "/user/pair", "/user/me"]
        )
        XCTAssertEqual(legacy.records.kept.account?.handle, "jo")
        XCTAssertEqual(legacy.records.kept.yards.map(\.name), ["laptop", "alice/lab"])
        XCTAssertEqual(legacy.records.kept.yards.map(\.owner), ["", "alice"])

        // A code typed for another account's yard is refused before
        // anything is sent, and is still good: the edge hands a member's
        // code out, so a PAKE on it would not seal the phone, and only
        // the QR the operator opens on the yard's own screen does.
        let member = try makeWorld()
        member.records.keepSession(account: member.fake.email, handle: "jo", session: member.fake.session())
        member.pair.typeCode()
        member.pair.typed(yard: "alice/lab", code: member.fake.lab.code ?? "")
        member.pair.readTyped()
        await member.pair.pair()
        XCTAssertEqual(member.pair.state.error, pairingRefusedWords("member_code"))
        XCTAssertTrue(member.pair.state.error?.contains("Nothing was sent, and the code is still good.") == true)
        XCTAssertEqual(member.fake.requestCount, 0)
        XCTAssertNotNil(member.fake.lab.code)
        XCTAssertTrue(member.records.kept.yards.isEmpty)
    }

    /// What the pairing says of a refusal `code`, as the sentence a
    /// person reads.
    private func pairingRefusedWords(_ code: String) -> String {
        pairingRefused(code).message
    }

    func testAWrongCodeAnEndedPairingAndTheEdgesRefusalsAreSaid() async throws {
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

        // The edge refuses a code it will not pass on in its own words,
        // which are the code's and no yard's not being ready; any other
        // 403 of the pairing still is a yard not ready.
        world.fake.next("/user/pair", .pairingSpent())
        world.pair.typed(yard: "laptop", code: "M4TR-9KWE")
        world.pair.readTyped()
        await world.pair.pair()
        XCTAssertEqual(
            world.pair.state.error,
            "that pairing code was opened for another account; it is spent — open a new pairing"
        )
        world.fake.next("/user/pair", .pairingNotOpen())
        world.pair.typed(yard: "laptop", code: "M4TR-9KWE")
        world.pair.readTyped()
        await world.pair.pair()
        XCTAssertEqual(world.pair.state.error, "that pairing code is not open for this yard")
        world.fake.next("/user/pair", .notReady())
        world.pair.typed(yard: "laptop", code: "M4TR-9KWE")
        world.pair.readTyped()
        await world.pair.pair()
        XCTAssertEqual(world.pair.state.error, "The yard is not ready: the yard is building.")
        XCTAssertTrue(world.records.kept.yards.isEmpty)
        XCTAssertNil(world.nav.signIn)
        XCTAssertFalse(world.nav.pairing)

        // Five wrong codes end the pairing, a scanned QR's sealed redemption
        // and a typed code's PAKE alike: each is the wrong code's words, and
        // the right code after the fifth finds none open, in the yard's words
        // for a pairing that ended, used or ran out, with nothing kept.
        let key = world.fake.channelPublic(yardName: "laptop")
        for scanned in [true, false] {
            world.fake.openPairing(yardName: "laptop", code: "M4TR-9KWE")
            func offer(_ code: String) async {
                if scanned {
                    world.pair.scanned("\(world.fake.origin)#\(code)#laptop#\(key)")
                } else {
                    world.pair.typeCode()
                    world.pair.typed(yard: "laptop", code: code)
                    world.pair.readTyped()
                }
                await world.pair.pair()
            }
            for tries in 1...5 {
                await offer("AAAA-BBBB")
                XCTAssertEqual(world.pair.state.error, pairingRefusedWords("wrong_code"), "wrong code \(tries), scanned \(scanned)")
            }
            await offer("M4TR-9KWE")
            XCTAssertEqual(world.pair.state.error, pairingRefusedWords("no_pairing"), "the right code after the fifth, scanned \(scanned)")
            XCTAssertTrue(world.records.kept.yards.isEmpty)
            XCTAssertFalse(world.fake.hasPairingOpen(yardName: "laptop"))
        }
        // Four wrong ones and then the right one still pairs.
        world.fake.openPairing(yardName: "laptop", code: "M4TR-9KWE")
        for _ in 1...4 {
            world.pair.scanned("\(world.fake.origin)#AAAA-BBBB#laptop#\(key)")
            await world.pair.pair()
        }
        world.pair.scanned("\(world.fake.origin)#M4TR-9KWE#laptop#\(key)")
        await world.pair.pair()
        XCTAssertNil(world.pair.state.error)
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["laptop"])
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

    func testAYardOfItsOwnPairsWithNoSignInAndReopensOnIt() async throws {
        let world = try makeWorld()
        world.pair.typeCode()
        world.pair.addressed("https://yard.example.net/")
        world.pair.typed(yard: "", code: "k7qm2xpd")
        world.pair.readTyped()
        XCTAssertEqual(
            world.pair.state.step,
            .read(PairingCode(code: "K7QM-2XPD", yard: "", address: "https://yard.example.net"))
        )
        // Reading the address and the code sent nothing.
        XCTAssertEqual(world.fake.requestCount, 0)

        // No session, and none asked for: the code goes to the yard's
        // address with no edge's headers.
        await world.pair.pair()
        XCTAssertNil(world.nav.signIn)
        XCTAssertEqual(world.pair.state, PairState())
        let requests = world.fake.allRequests
        XCTAssertEqual(requests.map(\.path), ["/user/pair", "/user/me"])
        XCTAssertTrue(requests.allSatisfy { $0.header("X-Edge-Token") == nil }, "\(requests)")
        XCTAssertTrue(requests.allSatisfy { $0.header("X-Edge-Yard") == nil }, "\(requests)")
        XCTAssertNil(requests[0].header("Authorization"))
        XCTAssertEqual(requests[0].bodyObject()["code"] as? String, "K7QM-2XPD")
        let token = try XCTUnwrap(world.records.kept.yards.first?.token)
        XCTAssertEqual(requests[1].header("Authorization"), "Bearer \(token)")

        // No account kept, the yard kept under the name its address
        // gives it and selected, and the head line says it.
        let kept = world.records.kept
        XCTAssertNil(kept.account)
        XCTAssertEqual(kept.yards.map(\.name), ["yard.example.net"])
        XCTAssertEqual(kept.yards.map(\.origin), ["https://yard.example.net"])
        XCTAssertEqual(kept.selected, "yard.example.net")
        XCTAssertEqual(kept.selectedYard.map { "\($0.title) · \($0.user)" }, "yard.example.net · jo")

        // The app reopens on the kept address.
        let reopened = Records(secret: world.secret, plain: world.plain, origin: world.fake.origin).kept
        XCTAssertEqual(reopened.yards.map(\.name), ["yard.example.net"])
        XCTAssertEqual(reopened.yards.map(\.origin), ["https://yard.example.net"])
        XCTAssertEqual(reopened.selected, "yard.example.net")
    }

    func testAQROfAYardsOwnAddressPairsDirect() async throws {
        let world = try makeWorld()
        world.pair.scanned("https://yard.example.net#\(world.fake.home.code ?? "")")
        XCTAssertEqual(
            world.pair.state.step,
            .read(PairingCode(code: "K7QM-2XPD", yard: "", address: "https://yard.example.net"))
        )
        await world.pair.pair()
        XCTAssertNil(world.nav.signIn)
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["yard.example.net"])
        XCTAssertEqual(world.records.kept.yards.map(\.origin), ["https://yard.example.net"])
        XCTAssertEqual(world.fake.allRequests.map(\.path), ["/user/pair", "/user/me"])
    }

    func testAYardOfItsOwnPairsBesideTheEdgesOwnAndBesideAnother() async throws {
        let world = try makeWorld()
        // The edge's own yard first, through the sign-in.
        world.pair.typeCode()
        world.pair.typed(yard: "", code: "k7qm2xpd")
        world.pair.readTyped()
        await world.pair.pair()
        try await signInAs(world)
        await waitForYards(world, 1)
        let edgeToken = try XCTUnwrap(world.records.kept.yards.first?.token)

        // The fake's one yard answers the edge's own and every yard of
        // its own, so each pairing is given a code of its own to take.
        func pairOwn(_ address: String, code: String) async {
            world.fake.home.code = code
            world.nav.showPair()
            world.pair.typeCode()
            world.pair.addressed(address)
            world.pair.typed(yard: "", code: code)
            world.pair.readTyped()
            await world.pair.pair()
        }

        // A yard of its own at a port, beside it: kept under the name
        // its address gives it, and the edge's own yard as it was.
        let sent = world.fake.requestCount
        await pairOwn("https://yard.example.net:8446", code: "AAAA-BBBB")
        XCTAssertNil(world.pair.state.error)
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["", "yard.example.net:8446"])
        XCTAssertEqual(world.records.kept.yards.map(\.origin), ["", "https://yard.example.net:8446"])
        XCTAssertEqual(world.records.kept.yards.first?.token, edgeToken)
        XCTAssertEqual(world.records.kept.selected, "yard.example.net:8446")
        XCTAssertEqual(world.records.kept.selectedYard.map { "\($0.title) · \($0.user)" }, "yard.example.net:8446 · jo")
        // Its pairing went to its address alone, with no edge's headers.
        let own = Array(world.fake.allRequests[sent...])
        XCTAssertEqual(own.map(\.path), ["/user/pair", "/user/me"])
        XCTAssertTrue(own.allSatisfy { $0.header("X-Edge-Token") == nil && $0.header("X-Edge-Yard") == nil }, "\(own)")

        // A second at another address: both are kept.
        let firstToken = world.records.kept.yards.last?.token
        await pairOwn("https://other.example.net", code: "CCCC-DDDD")
        XCTAssertNil(world.pair.state.error)
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["", "yard.example.net:8446", "other.example.net"])
        XCTAssertEqual(world.records.kept.yards[1].token, firstToken)
        XCTAssertEqual(world.records.kept.selected, "other.example.net")

        // The same address again, spelled another way, pairs as before:
        // the record of that name is replaced by the new pairing's, and
        // keeps the name the person gave it, which no request carries.
        world.records.renameYard("yard.example.net:8446", to: "Plantroom7")
        let renamed = world.fake.requestCount
        await pairOwn("https://YARD.EXAMPLE.NET:8446/", code: "EEEE-FFFF")
        XCTAssertNil(world.pair.state.error)
        let names = world.records.kept.yards.map(\.name)
        XCTAssertEqual(names.sorted(), ["", "other.example.net", "yard.example.net:8446"])
        let again = try XCTUnwrap(world.records.kept.yards.first { $0.name == "yard.example.net:8446" })
        XCTAssertNotEqual(again.token, firstToken)
        XCTAssertEqual(again.origin, "https://yard.example.net:8446")
        XCTAssertEqual(again.title, "Plantroom7")
        XCTAssertEqual(world.records.kept.selected, "yard.example.net:8446")
        XCTAssertGreaterThan(world.fake.requestCount, renamed)
        XCTAssertTrue(world.fake.requests(carrying: "Plantroom7").isEmpty, "\(world.fake.allRequests.map(\.path))")

        // And the app reopens on all three.
        let reopened = Records(secret: world.secret, plain: world.plain, origin: world.fake.origin).kept
        XCTAssertEqual(reopened.yards.map(\.name), ["", "other.example.net", "yard.example.net:8446"])
        XCTAssertEqual(reopened.yards.map(\.origin), ["", "https://other.example.net", "https://yard.example.net:8446"])
        XCTAssertEqual(reopened.yards.map(\.title), ["south", "other.example.net", "Plantroom7"])
        XCTAssertEqual(reopened.yards.first?.token, edgeToken)
    }

    func testAYardOfItsOwnKeptNamelessBeforeStillFollowsUnderItsAddress() async throws {
        let world = try makeWorld()
        // Paired as a phone paired it before an address named a yard:
        // under "", with its address beside its token.
        let token = world.fake.token(yardName: "")
        world.records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: token, origin: "https://yard.example.net:8446"))

        // The app starts again: renamed, and still selected.
        let reopened = Records(secret: world.secret, plain: world.plain, origin: world.fake.origin).kept
        let yard = try XCTUnwrap(reopened.yards.first)
        XCTAssertEqual(reopened.yards.map(\.name), ["yard.example.net:8446"])
        XCTAssertEqual(reopened.selected, "yard.example.net:8446")

        // It is followed as the app follows a yard of its own: the
        // client at its address, with the device token alone.
        let client = try Edge(origin: yard.origin, transport: world.fake).yardDirect(device: yard.token)
        let yards = Yards()
        let follower = yards.follow(client)
        defer {
            follower.close()
            yards.close()
        }
        let up = try await follower.waitFor("up") { $0.status == .up }
        XCTAssertEqual(up.loaded?.me.yard, "south")
        XCTAssertTrue(
            world.fake.allRequests.allSatisfy { $0.header("X-Edge-Token") == nil && $0.header("X-Edge-Yard") == nil },
            "\(world.fake.allRequests)"
        )
        XCTAssertEqual(world.fake.allRequests.first?.header("Authorization"), "Bearer \(token)")
    }

    func testASecondYardUnderAKeptNameIsRefusedBeforeAnythingIsSent() async throws {
        let kept = "yard.example.net:8446 is paired already. Forget it first to pair another yard of the same name."
        let world = try makeWorld()
        // A yard of its own first, kept under the name its address gives it.
        world.pair.typeCode()
        world.pair.addressed("https://yard.example.net:8446")
        world.pair.typed(yard: "", code: world.fake.home.code ?? "")
        world.pair.readTyped()
        await world.pair.pair()
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["yard.example.net:8446"])
        world.records.keepSession(account: world.fake.email, session: world.fake.session())
        let sent = world.fake.requestCount

        // An edge yard typed with that very name: refused, and nothing
        // sent, so the code is not burned.
        world.nav.showPair()
        world.pair.typeCode()
        world.pair.typed(yard: "yard.example.net:8446", code: "AAAA-BBBB")
        world.pair.readTyped()
        await world.pair.pair()
        XCTAssertEqual(world.pair.state.error, kept)
        XCTAssertEqual(world.fake.requestCount, sent)
        XCTAssertEqual(world.records.kept.yards.map(\.name), ["yard.example.net:8446"])
        XCTAssertEqual(world.records.kept.yards.map(\.origin), ["https://yard.example.net:8446"])

        // The same yard again pairs as before: past the guard, to the
        // yard's answer (its pairing is used up).
        world.pair.typeCode()
        world.pair.addressed("https://yard.example.net:8446")
        world.pair.typed(yard: "", code: "AAAA-BBBB")
        world.pair.readTyped()
        await world.pair.pair()
        XCTAssertTrue(world.pair.state.error?.hasPrefix("No pairing is open at this yard") == true, world.pair.state.error ?? "")
        XCTAssertEqual(world.fake.requestCount, sent + 1)

        // And the other way round: an edge yard kept under that name,
        // the yard of its own at that address refused.
        let other = try makeWorld()
        other.records.keepSession(account: other.fake.email, session: other.fake.session())
        other.records.keepYard(PairedYard(
            name: "yard.example.net:8446", yard: "laptop", user: "jo", device: "pixel",
            token: other.fake.token(yardName: "laptop")
        ))
        let otherSent = other.fake.requestCount
        other.pair.typeCode()
        other.pair.addressed("https://YARD.EXAMPLE.NET:8446/")
        other.pair.typed(yard: "", code: other.fake.home.code ?? "")
        other.pair.readTyped()
        await other.pair.pair()
        XCTAssertEqual(other.pair.state.error, kept)
        XCTAssertEqual(other.fake.requestCount, otherSent)
        XCTAssertEqual(other.records.kept.yards.map(\.origin), [""])
    }

    func testAPlainHttpAddressIsRefusedWithWhy() async throws {
        let world = try makeWorld()
        world.pair.typeCode()
        world.pair.addressed("http://yard.example.net")
        world.pair.typed(yard: "", code: "K7QM-2XPD")
        world.pair.readTyped()
        XCTAssertEqual(
            world.pair.state.error,
            "That address is plain http: anyone on the way could read the code and the token. Give the yard's https address."
        )
        XCTAssertEqual(world.fake.requestCount, 0)
    }

    func testAQRNamingNoUsableAddressSendsNothingAnywhere() async throws {
        let world = try makeWorld()
        world.pair.scanned("https://other.example/kratos#\(world.fake.laptop.code ?? "")")
        XCTAssertEqual(
            world.pair.state.error,
            "That is no address: https://yard.example.net, the scheme, the host and the port alone."
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
