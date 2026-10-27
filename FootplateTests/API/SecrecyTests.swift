@testable import Footplate
import XCTest

// Nothing of the API group that holds a token prints it, and no
// error's message or description holds a token or the password
// (design 3.2).

final class SecrecyTests: XCTestCase {
    private let fake = FakeYard()

    func testNoErrorAndNoDescriptionHoldsATokenOrThePassword() async throws {
        let edge = try fake.edge()
        let signedIn = try await edge.signIn(email: fake.email, password: fake.password)
        let session = signedIn.session
        let paired = try await edge.pair(code: "M4TR-9KWE", session: session, yard: "laptop")
        let yard = try edge.yard(device: paired.token, session: session, name: "laptop")
        let secrets = [session, paired.token, fake.password]

        var said: [String] = [
            String(describing: signedIn),
            String(describing: paired),
            String(describing: yard),
            String(describing: try edge.yardDirect(device: paired.token)),
        ]
        // Every error, as the fake makes it with the tokens in the
        // request.
        let refusals: [FakeResponse] = [
            .signedOut(), .notLetIn(), .noDevice(), .away(), .busy(), .notReady(),
            .badGateway(), .edgeDown(), .slow(),
            .json(200, #"{"error": {"code": "error", "message": "no"}}"#),
            .json(200, "not json"),
        ]
        for response in refusals {
            fake.next("/user/call/Head", response)
            let error = await raisedApiError { _ = try await yard.head() }
            said.append(String(describing: error))
            said.append(error.message)
        }
        fake.next("/user/events", .streamsFull())
        let streamError = await raisedApiError {
            for try await _ in yard.events(after: 0) {}
        }
        said.append(String(describing: streamError))
        said.append(streamError.message)
        let signInError = await raisedApiError {
            _ = try await edge.signIn(email: self.fake.email, password: self.fake.password + "x")
        }
        said.append(String(describing: signInError))
        said.append(signInError.message)
        let pairError = await raisedApiError {
            _ = try await edge.pair(code: "AAAA-BBBB", session: session, yard: "laptop")
        }
        said.append(String(describing: pairError))
        said.append(pairError.message)
        // A token refused before any request names no value either.
        let yardError = await raised(InvalidValueError.self) {
            _ = try await edge.yard(device: paired.token + "\n", session: session).head()
        }
        said.append(String(describing: yardError))
        let logoutError = await raised(InvalidValueError.self) {
            try await edge.logout(session: session + " x")
        }
        said.append(String(describing: logoutError))
        // And the errors made without a request.
        let made: [ApiError] = [
            .notSignedIn, .notLetIn, .noDevice, .nameKept(title: "x"), .away,
            .busy(retryAfter: .seconds(5)), .notReady(why: "x"), .edgeDown(why: "x"), .slow,
            .refused(code: "c", message: "m"), .down(why: "x"), .protocol(what: "x"),
        ]
        for error in made {
            said.append(String(describing: error))
            said.append(error.message)
        }
        try await edge.logout(session: session)
        let afterLogout = await raisedApiError { _ = try await yard.head() }
        said.append(String(describing: afterLogout))
        said.append(afterLogout.message)
        let secondLogout = await raisedApiError { try await edge.logout(session: session) }
        said.append(String(describing: secondLogout))
        said.append(secondLogout.message)

        for text in said {
            for secret in secrets {
                XCTAssertFalse(text.contains(secret), "\(text) holds a secret")
            }
        }
    }

    func testTheAppsTransportKeepsNoCacheAndNoCookies() {
        let configuration = URLSessionTransport.configuration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
    }
}
