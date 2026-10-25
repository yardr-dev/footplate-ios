import Foundation

// A wakeup counter waiters sleep on. The follower's pauses and its waits
// for the foreground, a retry or a stream's end are all waits on its own
// gate, and every poke wakes every waiter. A waiter that arrives after the
// poke it waits for returns at once, and a cancelled waiter returns too,
// so no wait outlives its task and none misses its poke. The gate itself
// decides nothing: what woke the waiter is read from state after it
// returns.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    var current: Int {
        lock.withLock { generation }
    }

    /// Wakes every waiter. What the poke means is the caller's to say, in
    /// state the waiter reads after it returns.
    func poke() {
        let pending = lock.withLock { () -> [AsyncStream<Void>.Continuation] in
            generation += 1
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.finish()
        }
    }

    /// Suspends until poked after `since`, or the task is cancelled, which
    /// the caller tells apart by reading its state. A poke that landed
    /// between `since` and this call returns at once.
    func wait(since: Int) async {
        if Task.isCancelled {
            return
        }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let moved = lock.withLock { () -> Bool in
            if generation != since {
                return true
            }
            waiters[id] = continuation
            return false
        }
        if moved {
            continuation.finish()
            return
        }
        await withTaskCancellationHandler {
            if Task.isCancelled {
                let waiter = lock.withLock { waiters.removeValue(forKey: id) }
                waiter?.finish()
                return
            }
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            _ = lock.withLock { waiters.removeValue(forKey: id) }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.finish()
        }
    }
}
