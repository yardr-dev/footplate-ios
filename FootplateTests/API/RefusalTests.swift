@testable import Footplate
import XCTest

// Design 3.1's refusal table against the reading alone: each row's
// answer, and what it becomes. The first row that matches decides, so
// several rows here carry what a later row reads too.

final class RefusalTests: XCTestCase {
    private struct Row {
        let what: String
        let status: Int
        let body: String
        let edgeRefusal: String?
        let retryAfter: String?
        let stream: Bool
        let expect: (ApiError?) -> Bool
    }

    private func row(
        _ what: String,
        _ status: Int,
        body: String = "",
        edgeRefusal: String? = nil,
        retryAfter: String? = nil,
        stream: Bool = false,
        expect: @escaping (ApiError?) -> Bool
    ) -> Row {
        Row(what: what, status: status, body: body, edgeRefusal: edgeRefusal, retryAfter: retryAfter, stream: stream, expect: expect)
    }

    func testEachAnswerIsReadAsItsRow() {
        let rows: [Row] = [
            row("401 session", 401, body: #"{"error": "edge: sign in"}"#, edgeRefusal: "session") { $0 == .notSignedIn },
            // The header decides before the body: a 503 away carrying
            // the edge's string is away, not the edge down.
            row("503 away", 503, body: #"{"error": "edge: the link is down"}"#, edgeRefusal: "away") { $0 == .away },
            row("429 busy", 429, edgeRefusal: "busy") { $0 == .busy(retryAfter: .seconds(5)) },
            row("429 busy, Retry-After 9", 429, edgeRefusal: "busy", retryAfter: "9") { $0 == .busy(retryAfter: .seconds(9)) },
            row("replacing", 503, body: #"{"error": {"code": "replacing", "message": "m"}}"#) {
                $0 == .refused(code: replacingCode, message: "m")
            },
            row("the yard's refusal on 200", 200, body: #"{"error": {"code": "not-found", "message": "user nobody: not found"}}"#) {
                $0 == .refused(code: "not-found", message: "user nobody: not found")
            },
            row("the edge's 403", 403, body: #"{"error": "edge: the yard is building"}"#) {
                $0 == .notReady(why: "the yard is building")
            },
            row("the edge's 502", 502, body: #"{"error": "edge: the yard did not answer"}"#) { $0 == .away },
            row("the edge's 503", 503, body: #"{"error": "edge: the map did not answer"}"#) {
                $0 == .edgeDown(why: "the map did not answer")
            },
            row("the edge's 504", 504, body: #"{"error": "edge: 30s"}"#) { $0 == .slow },
            row("the yard's 503 on the stream", 503, body: "too many streams\n", retryAfter: "5", stream: true) {
                $0 == .busy(retryAfter: .seconds(5))
            },
            row("the yard's 503 on the stream, Retry-After missing", 503, body: "too many streams\n", stream: true) {
                $0 == .busy(retryAfter: .seconds(5))
            },
            row("the yard's 503 on the stream, Retry-After unreadable", 503, body: "x", retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT", stream: true) {
                $0 == .busy(retryAfter: .seconds(5))
            },
            row("401 without the edge's word", 401, body: "Unauthorized\n") { $0 == .notLetIn },
            // An error string without `edge: ` is no edge's: the
            // status reads.
            row("401 with a string error of the yard's", 401, body: #"{"error": "unauthorized"}"#) { $0 == .notLetIn },
            row("404", 404, body: "404 page not found\n") { $0 == .noDevice },
            row("a bare 503 on a call", 503) {
                if case .down = $0 ?? .slow { return true }
                return false
            },
            row("a 503 with Retry-After on a call", 503, body: "too busy\n", retryAfter: "5") {
                if case .down = $0 ?? .slow { return true }
                return false
            },
            row("500", 500, body: "Internal Server Error\n") { $0 == .down(why: "status 500") },
            row("200", 200, body: #"{"result": 1}"#) { $0 == nil },
            row("an X-Edge-Refusal the phone does not know", 401, edgeRefusal: "other") { $0 == .notLetIn },
        ]
        for row in rows {
            let read = refusal(status: row.status, edgeRefusal: row.edgeRefusal, retryAfterHeader: row.retryAfter, body: row.body, stream: row.stream)
            XCTAssertTrue(row.expect(read), "\(row.what): read as \(String(describing: read))")
        }
    }

    // The sentences a yard from before yardr v0.15.0 refuses `weighed` with,
    // for each call that sends it: what yardr's `named` (internal/rpc/api.go)
    // says of a name a call does not take, as v0.14.0's own `named` says it
    // of the phone's bodies. A call of yardr's `Calls` names the stray; one of
    // its `OperatorCalls` (an approval, a secret's giving) never does. A yardr
    // that rewords either is a row to change here, and the matcher to read
    // again by.
    func testAYardThatTakesNoWeighedIsKnownByItsSentenceForEachCall() {
        let sentences: [(method: String, sentence: String)] = [
            ("AnswerAsk", #"argument "weighed": AnswerAsk has none of that name (it takes bead, ask, option, words, actor)"#),
            ("ApproveAsk", "an argument: ApproveAsk has none of that name (it takes bead, ask, actor)"),
            ("ApproveSetup", "an argument: ApproveSetup has none of that name (it takes bead, ask, option, values, account, actor)"),
            ("GiveSecret", "an argument: GiveSecret has none of that name (it takes bead, ask, values, actor)"),
        ]
        for (method, sentence) in sentences {
            XCTAssertTrue(refusesWeighed(sentence, method: method), method)
            // The call is pinned: the same words said of another are not its.
            for other in sentences.map(\.method) where other != method {
                XCTAssertFalse(refusesWeighed(sentence, method: other), "\(method)'s sentence read for \(other)")
            }
        }
        let others: [(what: String, method: String, sentence: String)] = [
            // A current yard lists `weighed` among what it takes, so what it
            // refuses is some other name.
            ("a current yard's", "ApproveAsk", "an argument: ApproveAsk has none of that name (it takes bead, ask, actor, weighed, values)"),
            ("another name than weighed", "AnswerAsk", #"argument "words": AnswerAsk has none of that name (it takes bead, ask, option, actor)"#),
            ("weighed of the wrong type", "ApproveAsk", #"argument "weighed": json: cannot unmarshal string into Go value of type bool"#),
            // A current yard refusing a weighty card, in words that name it.
            ("a weighty card's", "ApproveAsk", #"ask 9 is weighty (trust): approve it where its weight is shown; a client sends "weighed": true once its person has passed its gate"#),
            ("a rewording", "AnswerAsk", #"argument "weighed": AnswerAsk is not an argument"#),
            ("no words", "GiveSecret", ""),
        ]
        for (what, method, sentence) in others {
            XCTAssertFalse(refusesWeighed(sentence, method: method), what)
        }
    }

    func testRetryAfterIsFiveWhenMissingOrUnreadable() {
        XCTAssertEqual(retryAfterDuration(nil), .seconds(5))
        XCTAssertEqual(retryAfterDuration(""), .seconds(5))
        XCTAssertEqual(retryAfterDuration("soon"), .seconds(5))
        XCTAssertEqual(retryAfterDuration("0"), .seconds(5))
        XCTAssertEqual(retryAfterDuration("-3"), .seconds(5))
        XCTAssertEqual(retryAfterDuration(" 12 "), .seconds(12))
    }

    func testTheOriginIsHttpsOrLoopback() throws {
        XCTAssertEqual(try originURL("https://my.yardr.dev").host, "my.yardr.dev")
        XCTAssertEqual(try originURL("http://127.0.0.1:8080").port, 8080)
        _ = try originURL("http://localhost:1")
        for refused in [
            "http://my.yardr.dev", "http://192.168.1.2:8790", "https://my.yardr.dev/kratos",
            "https://my.yardr.dev/?x=1", "https://:secret@my.yardr.dev", "ftp://my.yardr.dev",
            "my.yardr.dev",
        ] {
            XCTAssertThrowsError(try originURL(refused), refused) { error in
                XCTAssertFalse(String(describing: error).contains("secret"), refused)
            }
        }
    }

    func testATokenStandsInAHeaderOrIsRefused() {
        XCTAssertTrue(isToken("yardr-dev-abc"))
        for bad in ["", "a b", "a\r\nX-Evil: 1", "é"] {
            XCTAssertFalse(isToken(bad), bad)
        }
        XCTAssertNil(refusal(status: 204, edgeRefusal: nil, retryAfterHeader: nil, body: ""))
    }
}
