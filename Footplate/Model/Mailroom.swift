import Foundation

// Every followed yard's `Board`, made once for the app and read by
// the inbox and conversation models (after Android's
// model/Mailroom.kt): each board is made from the state its follower
// read and moved on by the events after it; what an event says too
// little of is read again; and what is on the screen is acknowledged
// (`AckUserInbox`, `AckUserNotifications`) as it is shown.

/// What is on the screen: the conversation with `party` in the yard
/// `yard`, or that yard's notices where `party` is `yardRow`.
struct OnScreen: Equatable, Sendable {
    var yard: String
    var party: String
    var visible: Set<Int64> = []
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
    private var onScreen: OnScreen? = nil
    private var boardObservers: [UUID: @MainActor () -> Void] = [:]
    private var revisitTasks: [String: Task<Void, Never>] = [:]
    private var revisitAt: [String: Date] = [:]

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
            revisitTasks[name]?.cancel()
            revisitTasks.removeValue(forKey: name)
            revisitAt.removeValue(forKey: name)
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
        if lastLoaded[name] != loaded {
            boards[name] = Board.of(loaded)
            lastLoaded[name] = loaded
        }
        guard var board = boards[name] else { return }
        for event in followed.state.events {
            let (moved, asked) = board.apply(event)
            board = moved
            rereads.formUnion(asked)
        }
        if boards[name] != board {
            boards[name] = board
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
                let asks = try await followed.asks()
                guard isCurrent(name, followed) else { return }
                update(name) {
                    $0?.open = asks.open
                    $0?.decided = asks.decided
                }
            }
        } catch {
            // The follower says why the yard is not reached; the next
            // event of the kind, or the next load, reads it again.
        }
        guard isCurrent(name, followed) else { return }
        acknowledge(name)
        scheduleRevisit(name)
    }

    private func isCurrent(_ name: String, _ followed: any Followed) -> Bool {
        guard let current = watched[name]?.followed else { return false }
        return (current as AnyObject) === (followed as AnyObject)
    }

    /// Reads the queue again at a put-aside ask's return time: that is
    /// the one change to `UserAsks` the stream does not announce with
    /// an event.
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
