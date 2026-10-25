@testable import Footplate
import Foundation
import XCTest

// Shared helpers for the API tests: the fake's recorded requests read
// as Android's tests read MockWebServer's.

/// Asserts a recorded request's body is the expected JSON, compared
/// as parsed JSON so key order and spacing do not matter.
func assertBody(_ request: RecordedRequest, _ expectedJSON: String, file: StaticString = #filePath, line: UInt = #line) {
    let expected = canonicalJSON(Data(expectedJSON.utf8))
    let actual = canonicalJSON(request.body)
    XCTAssertEqual(actual, expected, "body of \(request.method) \(request.path)", file: file, line: line)
}

func canonicalJSON(_ data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: canonical, encoding: .utf8) else {
        return String(data: data, encoding: .utf8) ?? "<not utf8>"
    }
    return text
}

/// The headers of 3.1, with X-Edge-Yard for a named yard alone.
func assertHeaders(
    _ request: RecordedRequest,
    token: String,
    yard: String?,
    session: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(request.header("Authorization"), "Bearer \(token)", file: file, line: line)
    XCTAssertEqual(request.header("X-Edge-Token"), session, file: file, line: line)
    XCTAssertEqual(request.header("X-Edge-Yard"), yard, file: file, line: line)
    let client = request.header("X-Yardr-Client") ?? ""
    XCTAssertTrue(client.hasPrefix("footplate-ios/"), "X-Yardr-Client was \(client)", file: file, line: line)
}

/// Runs `operation`, failing the test unless it throws `E`, and
/// returns what it threw.
func raised<E: Error>(
    _ type: E.Type,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
) async -> E {
    do {
        try await operation()
    } catch let error as E {
        return error
    } catch {
        XCTFail("expected \(E.self), got \(error)", file: file, line: line)
        fatalError("unreachable")
    }
    XCTFail("expected \(E.self), but nothing was thrown", file: file, line: line)
    fatalError("unreachable")
}

func raisedApiError(
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> Void
) async -> ApiError {
    await raised(ApiError.self, file: file, line: line, operation)
}
