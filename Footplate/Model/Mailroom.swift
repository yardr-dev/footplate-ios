import Foundation

// Every followed yard's `Board`, made once for the app and read by
// the inbox and conversation models (after Android's
// model/Mailroom.kt): each board is made from the state its follower
// read and moved on by the events after it; what an event says too
// little of is read again; and what is on the screen is acknowledged
// (`AckUserInbox`, `AckUserNotifications`) as it is shown. The person's
// queue is read open-only wherever it is read again, and whole, the
// decided history with it, only where the Decide place shows the history
// (`fetchWhole`): a long-lived yard's history is nearly all of the whole
// answer, so the board holds the history as the last whole read left it.

/// What is on the screen: the conversation with `party` in the yard
/// `yard`, or that yard's notices where `party` is `yardRow`.
struct OnScreen: Equatable, Sendable {
    var yard: String
    var party: String
    var visible: Set<Int64> = []
}

/// A yard's queue reads, numbered as they begin, and the newest read each
/// half of its board's queue has been moved by. An answer comes when it
/// comes: a whole read takes seconds on a yard with a long history, and an
/// open-only read begun after it, on a noted event, answers first. Each
/// half applies only where no later-begun read applied it already, or the
/// slow answer would put an older queue back over a newer one.
private struct QueueReads {
    var begun = 0
    var open = 0
    var decided = 0
}

@MainActor
@Observable
final class Mailroom {
    /// Each followed yard's board, by its name at the edge: none for
    /// a yard not read since its follower was made.
    private(set) var boards: [String: Board] = [:]

    private let clock: any Clock
    private let now: @Sendable () -> Date
    private var watched: [String: (followed: any Followed, observer: UUID)] = [:]
    private var lastLoaded: [String: Loaded] = [:]
    /// How many loads of each yard have applied, first board onward: the
    /// load identity the Decide place watches for a reload under it.
    private var loadGenerations: [String: Int] = [:]
    private var onScreen: OnScreen? = nil
    private var boardObservers: [UUID: @MainActor () -> Void] = [:]
    private var revisitTasks: [String: Task<Void, Never>] = [:]
    private var revisitAt: [String: Date] = [:]
    private var queueReads: [String: QueueReads] = [:]

    init(clock: any Clock = SystemClock(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
        self.now = now
    }

    /// Follows these yards' states from now on, in place of the set
    /// watched before: boards of yards followed no more are dropped.
    func setFollowers(_ followers: [String: any Followed]) {
        for (name, entry) in watched where followers[name] == nil || (followers[name]! as AnyObject) !== (entry.followed as AnyObject) {
            entry.followed.removeObserver(entry.observer)
            watched.removeValue(forKey: name)
            boards.removeValue(forKey: name)
            lastLoaded.removeValue(forKey: name)
            loadGenerations.removeValue(forKey: name)
            revisitTasks[name]?.cancel()
            revisitTasks.removeValue(forKey: name)
            revisitAt.removeValue(forKey: name)
            queueReads.removeValue(forKey: name)
        }
        for (name, followed) in followers where watched[name] == nil {
            let id = followed.observe { [weak self] _ in
                self?.sync(name)
            }
            watched[name] = (followed, id)
            sync(name)
        }
        publish()
    }

    /// The follower of the yard named `name`, for a screen's calls.
    func followed(_ name: String) -> (any Followed)? {
        watched[name]?.followed
    }

    /// How many loads of the yard `name` have applied, 0 where none has:
    /// the load identity a screen watches for a reload under it. The
    /// event head is not it: the head advances on events, and a reload is
    /// a load.
    func loadGeneration(of name: String) -> Int {
        loadGenerations[name] ?? 0
    }

    func observeBoards(_ observer: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        boardObservers[id] = observer
        return id
    }

    func removeBoardsObserver(_ id: UUID) {
        boardObservers.removeValue(forKey: id)
    }

    /// `shown` is on the screen now, nil when no conversation is: it
    /// is acknowledged now, and as more of it comes.
    func show(_ shown: OnScreen?) {
        onScreen = shown
        if let shown {
            acknowledge(shown.yard)
        }
    }

    private func publish() {
        for observer in boardObservers.values { observer() }
    }

    private func sync(_ name: String) {
        guard let followed = watched[name]?.followed, let loaded = followed.state.loaded else { return }
        var rereads: Set<Reread> = []
        var changed = false
        if lastLoaded[name] != loaded {
            var fresh = Board.of(loaded)
            // A load that read the open asks alone says nothing of the
            // history: what the board held of it stays, as long as it is
            // the same person's.
            if loaded.asks.decided == nil, let held = boards[name], held.me == fresh.me {
                fresh.decided = held.decided
                fresh.dropStaleDecided()
            }
            boards[name] = fresh
            lastLoaded[name] = loaded
            loadGenerations[name, default: 0] += 1
            changed = true
        }
        guard var board = boards[name] else { return }
        for event in followed.state.events {
            let (moved, asked) = board.apply(event)
            board = moved
            rereads.formUnion(asked)
        }
        if boards[name] != board {
            boards[name] = board
            changed = true
        }
        if changed {
            publish()
        }
        for reread in rereads {
            Task { @MainActor in await self.reread(name, reread) }
        }
        acknowledge(name)
        scheduleRevisit(name)
    }

    private func reread(_ name: String, _ what: Reread) async {
        guard let followed = watched[name]?.followed else { return }
        do {
            switch what {
            case .crew:
                let crew = try await followed.crew()
                guard isCurrent(name, followed) else { return }
                update(name) { $0?.crew = crew }
            case .notices:
                let fresh = try await followed.notifications()
                guard isCurrent(name, followed) else { return }
                update(name) { $0 = $0?.notices(fresh.notifications) }
            case .asks:
                let loaded = followed.state.loaded
                let read = beginQueueRead(name)
                let queue = try await followed.openAsks()
                guard isCurrent(name, followed) else { return }
                // A follower can reload while this read is in flight. Its
                // load is the newer open queue, so retry after it rather
                // than letting this answer put the old queue back.
                guard followed.state.loaded == loaded else {
                    await reread(name, what)
                    return
                }
                apply(queue, read: read, to: name)
            }
        } catch {
            // The follower says why the yard is not reached; the next
            // event of the kind, or the next load, reads it again.
        }
        guard isCurrent(name, followed) else { return }
        acknowledge(name)
        scheduleRevisit(name)
    }

    /// Reads the whole queue of the yard `name`, the decided history with
    /// the open asks, and applies it. The reads that want the history are
    /// the Decide place appearing, the selected yard changing under it, a
    /// reload of the front yard while it shows, and the person's own
    /// decision (so the list moves the ask to Decided at once); every
    /// other read of the queue is open-only (`reread`), since a noted
    /// event is no reason to read the whole history again. An answer that
    /// does not come leaves the board as it was: the next of those reads
    /// reads again.
    func fetchWhole(_ name: String) async {
        guard let followed = watched[name]?.followed else { return }
        let loaded = followed.state.loaded
        let read = beginQueueRead(name)
        do {
            let asks = try await followed.asks()
            guard isCurrent(name, followed) else { return }
            // A load that finished during this read has a newer open half.
            // Retry whole so the Decide place still gets current history.
            guard followed.state.loaded == loaded else {
                await fetchWhole(name)
                return
            }
            apply(OpenQueue(open: asks.open, decided: asks.decided), read: read, to: name)
        } catch {
            // The follower says why the yard is not reached.
        }
        guard isCurrent(name, followed) else { return }
        scheduleRevisit(name)
    }

    private func beginQueueRead(_ name: String) -> Int {
        var reads = queueReads[name] ?? QueueReads()
        reads.begun += 1
        queueReads[name] = reads
        return reads.begun
    }

    /// Applies an answer of queue read number `read`: the open asks where
    /// no later read applied its own, and likewise the decided, which only
    /// an answer that carries them moves (an open-only answer leaves the
    /// history held). An ask the board has open is not held decided any
    /// more (`Board.dropStaleDecided`).
    private func apply(_ queue: OpenQueue, read: Int, to name: String) {
        var reads = queueReads[name] ?? QueueReads()
        let opens = read > reads.open
        let decides = queue.decided != nil && read > reads.decided
        if opens { reads.open = read }
        if decides { reads.decided = read }
        queueReads[name] = reads
        update(name) { board in
            guard var next = board else { return }
            if opens { next.open = queue.open }
            if decides, let decided = queue.decided { next.decided = decided }
            next.dropStaleDecided()
            board = next
        }
    }

    private func isCurrent(_ name: String, _ followed: any Followed) -> Bool {
        guard let current = watched[name]?.followed else { return false }
        return (current as AnyObject) === (followed as AnyObject)
    }

    /// Reads the queue's open asks again at a put-aside ask's return time:
    /// that is the one change to the queue the stream does not announce
    /// with an event, and a returned ask is open, so the history is not
    /// needed to show it. The time is read from the held history, so it is
    /// armed once the history was read whole.
    private func scheduleRevisit(_ name: String) {
        let next = boards[name]?.decided
            .filter { $0.state == "put aside" }
            .compactMap { parseInstant($0.returnAt) }
            .min()
        if revisitAt[name] == next {
            if next == nil {
                revisitTasks[name]?.cancel()
                revisitTasks.removeValue(forKey: name)
            }
            return
        }
        revisitTasks[name]?.cancel()
        revisitTasks.removeValue(forKey: name)
        revisitAt.removeValue(forKey: name)
        guard let next, watched[name] != nil else { return }
        revisitAt[name] = next
        let clock = self.clock
        let wait = max(0, next.timeIntervalSince(now()))
        revisitTasks[name] = Task { @MainActor in
            do {
                try await clock.sleep(.seconds(wait))
            } catch {
                return
            }
            await reread(name, .asks)
        }
    }

    /// Acknowledges what the screen shows of the yard `name`: the
    /// conversation's unread are shown, and the mail is acknowledged
    /// as far as `Board.ackThrough` lets it; the notices through the
    /// newest. The board counts it read at once, and the yard's
    /// `mail_read` event confirms it.
    private func acknowledge(_ name: String) {
        guard let shown = onScreen, shown.yard == name, let followed = watched[name]?.followed else { return }
        var mail: Int64 = 0
        var notices: Int64 = 0
        update(name) { board in
            guard let current = board else { return }
            if shown.party == yardRow {
                let newest = current.newestNotice
                if newest > current.noticeCursor { notices = newest }
                board = current.noticesRead(newest)
            } else {
                let seen = current.shown(shown.visible)
                let through = seen.ackThrough()
                if through > seen.cursor { mail = through }
                board = seen.read(through)
            }
        }
        if mail > 0 {
            let through = mail
            Task { try? await followed.ackInbox(through: through) }
        }
        if notices > 0 {
            let through = notices
            Task { try? await followed.ackNotifications(through: through) }
        }
    }

    private func update(_ name: String, _ change: (inout Board?) -> Void) {
        var board = boards[name]
        change(&board)
        if board == boards[name] { return }
        if let board {
            boards[name] = board
        } else {
            boards.removeValue(forKey: name)
        }
        publish()
    }
}
