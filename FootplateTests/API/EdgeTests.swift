@testable import Footplate
import XCTest

// The edge's own calls against the fake: Kratos's sign-in and logout
// of design 3.2, and the pairing, whose edge's answers are told from
// the yard's by their body.

final class EdgeTests: XCTestCase {
    private let fake = FakeYard()

    private func makeEdge() throws -> Edge {
        try fake.edge()
    }

    func testSignInOpensAFlowAndAnswersItWithThePassword() async throws {
        let edge = try makeEdge()
        let signedIn = try await edge.signIn(email: fake.email, password: fake.password)
        XCTAssertEqual(signedIn.account, "jo@example.com")
        // The handle trait is kept beside the display name: the edge
        // names the account's own yard by it.
        XCTAssertEqual(signedIn.handle, "jo")
        XCTAssertTrue(signedIn.session.hasPrefix("ory_st_"))
        let flow = fake.taken()
        XCTAssertEqual(flow.method, "GET")
        XCTAssertEqual(flow.path, "/kratos/self-service/login/api")
        XCTAssertTrue((flow.header("X-Yardr-Client") ?? "").hasPrefix("footplate-ios/"))
        let submit = fake.taken()
        XCTAssertEqual(submit.method, "POST")
        XCTAssertTrue(submit.path.hasPrefix("/kratos/self-service/login?flow=flow-"), submit.path)
        assertBody(submit, "{\"method\":\"password\",\"identifier\":\"\(fake.email)\",\"password\":\"\(fake.password)\"}")
        // Neither carries a device token or a session.
        XCTAssertNil(submit.header("Authorization"))
        XCTAssertNil(submit.header("X-Edge-Token"))

        // An older kept session can recover its handle from the edge
        // before the own-yard web view is opened.
        fake.next("/kratos/sessions/whoami", .json(200, #"{"identity":{"traits":{"handle":"jo"}}}"#))
        let recoveredHandle = try await edge.accountHandle(session: signedIn.session)
        XCTAssertEqual(recoveredHandle, "jo")
        let whoami = fake.taken()
        XCTAssertEqual(whoami.method, "GET")
        XCTAssertEqual(whoami.path, "/kratos/sessions/whoami")
        XCTAssertEqual(whoami.header("X-Edge-Token"), signedIn.session)
        XCTAssertNil(whoami.header("Authorization"))

        // The session signs the calls in.
        let yard = try edge.yard(device: fake.token(yardName: "laptop"), session: signedIn.session, name: "laptop")
        let head = try await yard.head()
        XCTAssertEqual(head, 151)

        // The account is its email, else its handle, else what was typed;
        // the handle is kept apart, and empty where the answer holds none.
        func answer(traits: String) -> FakeResponse {
            FakeResponse.json(200, #"{"session_token": "ory_st_x", "session": {"identity": {"traits": \#(traits)}}}"#)
        }
        fake.next("/kratos/self-service/login", answer(traits: #"{"handle": " jo \nsecond line"}"#))
        let handleOnly = try await edge.signIn(email: fake.email, password: fake.password)
        XCTAssertEqual(handleOnly.account, "jo")
        XCTAssertEqual(handleOnly.handle, "jo")
        fake.next("/kratos/self-service/login", answer(traits: #"{"email": "jo@example.com"}"#))
        let emailOnly = try await edge.signIn(email: "typed@example.com", password: fake.password)
        XCTAssertEqual(emailOnly.account, "jo@example.com")
        XCTAssertEqual(emailOnly.handle, "")
        fake.next("/kratos/self-service/login", answer(traits: "{}"))
        let neither = try await edge.signIn(email: "typed@example.com", password: fake.password)
        XCTAssertEqual(neither.account, "typed@example.com")
        XCTAssertEqual(neither.handle, "")
    }

    func testAnExpiredFlowOpensOneMoreAndASecondExpiryIsSaid() async throws {
        let edge = try makeEdge()
        fake.setExpiredFlows(1)
        _ = try await edge.signIn(email: fake.email, password: fake.password)
        XCTAssertEqual(fake.requestCount, 4)

        fake.setExpiredFlows(2)
        let error = await raisedApiError {
            _ = try await edge.signIn(email: self.fake.email, password: self.fake.password)
        }
        XCTAssertEqual(error, .refused(code: "bad_sign_in", message: "The sign-in expired before it was sent. Sign in again."))
        // Two more flows opened, two submitted, and no third.
        XCTAssertEqual(fake.requestCount, 8)
    }

    func testARefusedSignInSaysKratosWords() async throws {
        let edge = try makeEdge()
        let error = await raisedApiError {
            _ = try await edge.signIn(email: self.fake.email, password: "wrong")
        }
        guard case .refused(let code, let message) = error else {
            return XCTFail("expected refused, got \(error)")
        }
        XCTAssertEqual(code, "bad_sign_in")
        XCTAssertTrue(message.contains("The provided credentials are invalid"), message)
        // The edge down is the edge's, not a refused sign-in.
        fake.next("/kratos/self-service/login/api", .edgeDown())
        let down = await raisedApiError {
            _ = try await edge.signIn(email: self.fake.email, password: self.fake.password)
        }
        guard case .edgeDown = down else {
            return XCTFail("expected edgeDown, got \(down)")
        }
    }

    func testLogoutEndsTheSessionAndItsCallsAreNotSignedIn() async throws {
        let edge = try makeEdge()
        let session = try await edge.signIn(email: fake.email, password: fake.password).session
        let yard = try edge.yard(device: fake.token(yardName: "laptop"), session: session, name: "laptop")
        let head = try await yard.head()
        XCTAssertEqual(head, 151)
        _ = fake.taken()
        _ = fake.taken()
        _ = fake.taken()

        try await edge.logout(session: session)
        let logout = fake.taken()
        XCTAssertEqual(logout.method, "DELETE")
        XCTAssertEqual(logout.path, "/kratos/self-service/logout/api")
        assertBody(logout, "{\"session_token\":\"\(session)\"}")

        // The fake refuses a revoked session as the edge does.
        let headError = await raisedApiError { _ = try await yard.head() }
        XCTAssertEqual(headError, .notSignedIn)
        let streamError = await raisedApiError {
            for try await _ in yard.events(after: 0) {}
        }
        XCTAssertEqual(streamError, .notSignedIn)
    }

    func testPairingSendsTheCodeWithTheSessionAndNoDeviceToken() async throws {
        let edge = try makeEdge()
        let session = fake.session()
        let paired = try await edge.pair(code: "m4tr-9kwe", session: session, yard: "laptop")
        XCTAssertEqual(paired.user, "jo")
        XCTAssertEqual(paired.device, "pixel")
        XCTAssertEqual(paired.yard, "laptop")
        let request = fake.taken()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/user/pair")
        assertBody(request, #"{"code":"m4tr-9kwe"}"#)
        XCTAssertEqual(request.header("X-Edge-Token"), session)
        XCTAssertEqual(request.header("X-Edge-Yard"), "laptop")
        XCTAssertNil(request.header("Authorization"))
        XCTAssertTrue((request.header("X-Yardr-Client") ?? "").hasPrefix("footplate-ios/"))
        // The token it answered is the device's from then on.
        let me = try await edge.yard(device: paired.token, session: session, name: "laptop").me()
        XCTAssertEqual(me.yard, "laptop")
        _ = fake.taken()

        // The account's own yard: no X-Edge-Yard.
        _ = try await edge.pair(code: "K7QM2XPD", session: session)
        XCTAssertNil(fake.taken().header("X-Edge-Yard"))
    }

    func testPairingDirectSendsTheCodeWithNoEdgeHeaders() async throws {
        let edge = try makeEdge()
        let paired = try await edge.pairDirect(code: "k7qm-2xpd")
        XCTAssertEqual(paired.user, "jo")
        XCTAssertEqual(paired.device, "phone")
        XCTAssertEqual(paired.yard, "south")
        let request = fake.taken()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/user/pair")
        assertBody(request, #"{"code":"k7qm-2xpd"}"#)
        XCTAssertNil(request.header("Authorization"))
        XCTAssertNil(request.header("X-Edge-Token"))
        XCTAssertNil(request.header("X-Edge-Yard"))
        XCTAssertTrue((request.header("X-Yardr-Client") ?? "").hasPrefix("footplate-ios/"))
        // The token it answered is the device's from then on, carried alone.
        let me = try await edge.yardDirect(device: paired.token).me()
        XCTAssertEqual(me.yard, "south")
        let meRequest = fake.taken()
        XCTAssertEqual(meRequest.header("Authorization"), "Bearer \(paired.token)")
        XCTAssertNil(meRequest.header("X-Edge-Token"))
        XCTAssertNil(meRequest.header("X-Edge-Yard"))
    }

    func testPairingDirectSaysTheYardsRefusalsInTheYardsWords() async throws {
        let edge = try makeEdge()
        let wrong = await raisedApiError {
            _ = try await edge.pairDirect(code: "AAAA-BBBB")
        }
        guard case .refused(let wrongCode, let wrongMessage) = wrong else {
            return XCTFail("expected refused, got \(wrong)")
        }
        XCTAssertEqual(wrongCode, "wrong_code")
        XCTAssertTrue(wrongMessage.hasPrefix("That is not the code."), wrongMessage)
        // Once used, no pairing is open: the yard's 401, with no edge in it.
        _ = try await edge.pairDirect(code: "K7QM-2XPD")
        let none = await raisedApiError {
            _ = try await edge.pairDirect(code: "K7QM-2XPD")
        }
        guard case .refused(let noneCode, let noneMessage) = none else {
            return XCTFail("expected refused, got \(none)")
        }
        XCTAssertEqual(noneCode, "no_pairing")
        XCTAssertTrue(noneMessage.hasPrefix("No pairing is open at this yard"), noneMessage)
        // The yard's own error object elsewhere is the yard's, and an
        // edge's shape, were one ever answered here, is not read as
        // the edge's: the `edge: ` prefix does not apply with no edge.
        fake.next("/user/pair", .json(500, #"{"error": {"code": "broken", "message": "the yard is broken"}}"#))
        let broken = await raisedApiError {
            _ = try await edge.pairDirect(code: "K7QM-2XPD")
        }
        guard case .refused(let brokenCode, _) = broken else {
            return XCTFail("expected refused, got \(broken)")
        }
        XCTAssertEqual(brokenCode, "broken")
        fake.next("/user/pair", .notReady())
        let notEdge = await raisedApiError {
            _ = try await edge.pairDirect(code: "K7QM-2XPD")
        }
        XCTAssertEqual(notEdge, .down(why: "status 403"))
    }

    func testPairingTellsTheEdgesRefusalsFromTheYards() async throws {
        let edge = try makeEdge()
        let session = fake.session()
        // The edge's 403 is a yard not ready, never a wrong code.
        fake.next("/user/pair", .notReady())
        let notReady = await raisedApiError {
            _ = try await edge.pair(code: "K7QM-2XPD", session: session)
        }
        XCTAssertEqual(notReady, .notReady(why: "the yard is building"))
        // The yard's 403 is the wrong code.
        let wrong = await raisedApiError {
            _ = try await edge.pair(code: "AAAA-BBBB", session: session)
        }
        guard case .refused(let wrongCode, let wrongMessage) = wrong else {
            return XCTFail("expected refused, got \(wrong)")
        }
        XCTAssertEqual(wrongCode, "wrong_code")
        XCTAssertTrue(wrongMessage.hasPrefix("That is not the code."), wrongMessage)
        fake.next("/user/pair", .json(409, "not added\n"))
        let notAdded = await raisedApiError {
            _ = try await edge.pair(code: "K7QM-2XPD", session: session)
        }
        guard case .refused(let notAddedCode, let notAddedMessage) = notAdded else {
            return XCTFail("expected refused, got \(notAdded)")
        }
        XCTAssertEqual(notAddedCode, "not_added")
        XCTAssertTrue(notAddedMessage.contains("code was right and is used up"), notAddedMessage)
        let signedOut = await raisedApiError {
            _ = try await edge.pair(code: "K7QM-2XPD", session: "ory_st_unknown")
        }
        XCTAssertEqual(signedOut, .notSignedIn)
        fake.next("/user/pair", .away())
        let away = await raisedApiError {
            _ = try await edge.pair(code: "K7QM-2XPD", session: session)
        }
        XCTAssertEqual(away, .away)
        // Once used, no pairing is open.
        _ = try await edge.pair(code: "K7QM-2XPD", session: session)
        let noPairing = await raisedApiError {
            _ = try await edge.pair(code: "K7QM-2XPD", session: session)
        }
        guard case .refused(let code, _) = noPairing else {
            return XCTFail("expected refused, got \(noPairing)")
        }
        XCTAssertEqual(code, "no_pairing")
    }
}
