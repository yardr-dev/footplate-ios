@testable import Footplate
import Foundation
import XCTest

// Shared helpers for the session tests: waiting on the follower's state,
// the clock's sleepers and the fake's requests, as Android's FollowTest
// waits on its flows.

/// Thrown when a wait outlasts its timeout, after failing the test.
struct TestTimeout: Error {
    let what: String
}

extension FollowStatus {
    var isDown: Bool {
        if case .down = self {
            return true
        }
        return false
    }

    var isPairAgain: Bool {
        if case .pairAgain = self {
            return true
        }
        return false
    }

    var isSignInAgain: Bool {
        if case .signInAgain = self {
            return true
        }
        return false
    }
}

extension Follower {
    /// The state once `match` holds of it, polling the effect and failing
    /// past `timeout`.
    func waitFor(
        _ what: String,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        match: @escaping @Sendable (YardState) -> Bool
    ) async throws -> YardState {
        let deadline = ContinuousClock.now + timeout
        while true {
            let state = await MainActor.run { self.state }
            if match(state) {
                return state
            }
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what); last state=\(state)", file: file, line: line)
                throw TestTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The state as it stands, from wherever the test runs.
    var currentState: YardState {
        get async {
            await MainActor.run { self.state }
        }
    }

    /// Tries now a yard that stopped, from wherever the test runs.
    func retryFromTest() async {
        await MainActor.run { self.retry() }
    }
}

/// The telling and the short of a `down` status, failing otherwise.
func downWords(_ state: YardState, file: StaticString = #filePath, line: UInt = #line) -> (words: String, short: String) {
    guard case .down(let words, let short) = state.status else {
        XCTFail("expected down, got \(state.status)", file: file, line: line)
        fatalError("unreachable")
    }
    return (words, short)
}

/// Until `count` followers wait on the clock, and what they wait for: a
/// status is set before its pause is slept, so the sleeps are waited for
/// before the clock moves.
func waitPending(
    _ clock: TestClock,
    count: Int = 1,
    timeout: Duration = .seconds(10),
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> [Duration] {
    let deadline = ContinuousClock.now + timeout
    while true {
        let pending = clock.pending()
        if pending.count >= count {
            return pending
        }
        if ContinuousClock.now > deadline {
            XCTFail("timed out waiting for \(count) sleepers; saw \(pending.count)", file: file, line: line)
            throw TestTimeout(what: "\(count) sleepers")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Until the fake has recorded `count` requests.
func waitForRequests(
    _ fake: FakeYard,
    _ count: Int,
    timeout: Duration = .seconds(10),
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let deadline = ContinuousClock.now + timeout
    while true {
        if fake.allRequests.count >= count {
            return
        }
        if ContinuousClock.now > deadline {
            XCTFail("timed out waiting for \(count) requests; saw \(fake.allRequests.count)", file: file, line: line)
            throw TestTimeout(what: "\(count) requests")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Until the fake has the requested number of open event streams.
func waitForOpenStreams(
    _ fake: FakeYard,
    _ count: Int,
    timeout: Duration = .seconds(10),
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    let deadline = ContinuousClock.now + timeout
    while true {
        if fake.openStreamCount == count {
            return
        }
        if ContinuousClock.now > deadline {
            XCTFail("timed out waiting for \(count) open streams; saw \(fake.openStreamCount)", file: file, line: line)
            throw TestTimeout(what: "\(count) open streams")
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Lets a forbidden request land, so that a count asserted after it means
/// the follower asked nothing. Only for assertions that nothing happened,
/// which no effect can end.
func settle(_ milliseconds: Int = 200) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds))
}

/// Sets what in front is, from wherever the test runs.
func setForeground(_ yards: Yards, _ foreground: Bool) async {
    await MainActor.run {
        yards.foreground = foreground
    }
}
