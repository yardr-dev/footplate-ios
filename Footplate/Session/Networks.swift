import Foundation
import Network

// A change of network ends the stream at once (design 3.1): the app starts
// one of these on its path monitor, and every follower opens its stream
// again on the new path. Only the path's identity is judged — which
// interfaces carry it — never whether it reaches anywhere.
final class NetworkWatch: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let onChanged: @Sendable () -> Void
    private let lock = NSLock()
    private var started = false
    /// Whether the monitor's initial path has arrived, touched on `queue`.
    private var updates = NetworkPathUpdates()

    init(onChanged: @escaping @Sendable () -> Void, queue: DispatchQueue = DispatchQueue(label: "dev.yardr.footplate.network")) {
        self.monitor = NWPathMonitor()
        self.queue = queue
        self.onChanged = onChanged
    }

    deinit {
        monitor.cancel()
    }

    /// Starts watching the default path. The first update is the baseline;
    /// every later path update calls `onChanged` on the watch's queue.
    func start() {
        let startIt = lock.withLock {
            if started {
                return false
            }
            started = true
            return true
        }
        guard startIt else {
            return
        }
        monitor.pathUpdateHandler = { _ in
            if self.updates.received() {
                self.onChanged()
            }
        }
        monitor.start(queue: queue)
    }

    /// Stops watching. Starts again with `start`.
    func cancel() {
        _ = lock.withLock { started = false }
        monitor.cancel()
        monitor.pathUpdateHandler = nil
    }
}

/// The initial monitor update establishes the current path. Every later
/// update is a path change, even when the interface names stay the same.
struct NetworkPathUpdates {
    private var hasBaseline = false

    mutating func received() -> Bool {
        guard hasBaseline else {
            hasBaseline = true
            return false
        }
        return true
    }
}
