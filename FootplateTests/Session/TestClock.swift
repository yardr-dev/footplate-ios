@testable import Footplate
import Foundation

// The clock the follower tests drive: a sleep waits until the test moves
// time past it.
final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var nowMs: Int64 = 0

    private struct Sleeper {
        let atMs: Int64
        let continuation: AsyncStream<Void>.Continuation
    }

    private var sleepers: [UUID: Sleeper] = [:]

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let ms = durationMs(duration)
        if ms <= 0 {
            return
        }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        lock.withLock {
            sleepers[id] = Sleeper(atMs: nowMs + ms, continuation: continuation)
        }
        await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            _ = lock.withLock { sleepers.removeValue(forKey: id) }
        } onCancel: {
            let sleeper = lock.withLock { sleepers.removeValue(forKey: id) }
            sleeper?.continuation.finish()
        }
        try Task.checkCancellation()
    }

    /// Moves time by `duration`, waking every sleep it passes.
    func advance(_ duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            nowMs += durationMs(duration)
            var due: [Sleeper] = []
            var rest: [UUID: Sleeper] = [:]
            for (id, sleeper) in sleepers {
                if sleeper.atMs <= nowMs {
                    due.append(sleeper)
                } else {
                    rest[id] = sleeper
                }
            }
            sleepers = rest
            return due
        }
        for sleeper in due {
            sleeper.continuation.finish()
        }
    }

    /// What each waiting sleep still asks for, soonest first.
    func pending() -> [Duration] {
        lock.withLock {
            sleepers.values.map { .milliseconds(max(Int64(0), $0.atMs - nowMs)) }.sorted()
        }
    }
}

private func durationMs(_ duration: Duration) -> Int64 {
    let components = duration.components
    return components.seconds * 1000 + Int64(components.attoseconds / 1_000_000_000_000_000)
}
