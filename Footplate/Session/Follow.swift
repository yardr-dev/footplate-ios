import Foundation

// Following the yards, as footplate's session does, one follower per
// paired yard: while the app is in front it follows every yard, each with
// its own state, stream and retries (design 3.3, after Android's
// session/Follow.kt). The app says what in front is, from its scene phase;
// the tests drive it directly.

/// How long until the yard is tried again.
let followRetry: Duration = .seconds(3)

/// How long until a yard the edge calls not ready is tried again.
let followNotReadyRetry: Duration = .seconds(30)

/// A stream that ended after bringing events is opened again at once, when
/// the server only replaces itself with a newer build; this is the moment
/// between the two.
let followReplacingPause: Duration = .milliseconds(100)

/// How one yard stands: what footplate's session tells its window, in
/// 3.1's sentences.
enum FollowStatus: Equatable, Sendable {
    /// Nothing answered yet.
    case starting
    /// The state is read and the stream is followed.
    case up
    /// The yard is not reached, and is tried again: `words` the telling,
    /// `short` a word or two for where there is no room for them.
    case down(words: String, short: String)
    /// The yard refuses the device token: not asked again until `retry`.
    case pairAgain(words: String)
    /// The edge refuses the session: every yard stops, until the person
    /// signs in and the yards are followed with new clients.
    case signInAgain(words: String)
}

/// One yard's state, as the models read it: the last state read, whether
/// it is followed, the last seq read (the stream opens after it), the
/// newest event, and the events since the state was read (a model applies
/// each one it has not seen: state keeps only its newest value, and a
/// stream opened again brings many events at once).
struct YardState: Equatable, Sendable {
    var status: FollowStatus = .starting
    var loaded: Loaded? = nil
    var lastSeq: Int64 = 0
    var lastEvent: Event? = nil
    /// Oldest first, the newest `keptEvents` of them; emptied by a load.
    var events: [Event] = []
}

/// How many events since the last load a `YardState` keeps.
let keptEvents = 500

/// How a follower waits between tries: the app sleeps, and the tests drive
/// a clock of their own.
protocol Clock: Sendable {
    func sleep(_ duration: Duration) async throws
}

/// The app's clock.
struct SystemClock: Clock {
    func sleep(_ duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Every paired yard followed, each with its own state, stream and
/// retries, while the app is in front (design 3.3).
@MainActor
final class Yards {
    private let clock: any Clock
    private var followers: [Follower] = []
    private var closed = false

    /// Whether the app is in front: the streams are open only then. The
    /// app sets it from its scene phase; the tests set it directly.
    var foreground: Bool {
        didSet {
            if foreground != oldValue {
                if !foreground {
                    backgrounded += 1
                }
                pokeAll()
            }
        }
    }

    /// Whether the edge refused the session: every yard is stopped with
    /// `signInAgain`.
    private(set) var signedOut = false

    /// How often the app went to the back: a follower reads the state again
    /// when this moved since its last load, however briefly the app was in
    /// the back.
    private(set) var backgrounded: Int64 = 0

    init(clock: any Clock = SystemClock(), foreground: Bool = true) {
        self.clock = clock
        self.foreground = foreground
    }

    /// Follows one yard: its state is read (`load`), and then its stream
    /// from the head, opened again after the last seq read after any end.
    /// The follower runs until `close`, or until the yards close.
    func follow(_ client: YardClient) -> Follower {
        precondition(!closed, "Yards is closed")
        let follower = Follower(client: client, yards: self, clock: clock)
        followers.append(follower)
        return follower
    }

    /// The default network changed: every stream closes, and opens again
    /// on the new one after the last seq read.
    func noteNetworkChanged() {
        pokeAll()
    }

    /// The edge refused the session: every yard stops.
    func noteSignedOut() {
        signedOut = true
        pokeAll()
    }

    /// Stops every follower.
    func close() {
        closed = true
        let all = followers
        followers.removeAll()
        for follower in all {
            follower.close()
        }
    }

    func remove(_ follower: Follower) {
        followers.removeAll { $0 === follower }
    }

    private func pokeAll() {
        for follower in followers {
            follower.poke()
        }
    }
}

/// One yard followed: its state out as `@Observable` state the models
/// read. Made by `Yards.follow`.
@Observable
@MainActor
final class Follower {
    private(set) var state = YardState()

    private var observers: [UUID: @MainActor (YardState) -> Void] = [:]

    private let client: YardClient
    private let yards: Yards
    private let clock: any Clock
    /// Wakes the loop: a stop poke, a stream's end, or a pause slept out.
    /// The gate carries no meaning; what woke the loop is read from state.
    private let gate = Gate()
    /// Stop pokes so far: a retry, a network change, the app going to the
    /// back or coming to the front, or the session refused. A stream's own
    /// end and opening poke the gate without moving this, so the wait for
    /// a stream tells a stop apart from its end.
    private var stopPokes = 0
    /// Retries so far, moved by `retry` alone.
    private var retries = 0
    /// The stream open now, or that would be: a collector whose id is past
    /// drops its events and its end, so a stopped stream cannot write to a
    /// state read since.
    private var streamId = 0
    /// The open stream's end, where it ended and no stop came first.
    private var streamEnd: StreamEnd?
    /// The `backgrounded` the state was last read at. Only the loop reads
    /// and writes it.
    private var reloadedThrough: Int64 = -1
    private var task: Task<Void, Never>?

    init(client: YardClient, yards: Yards, clock: any Clock) {
        self.client = client
        self.yards = yards
        self.clock = clock
        self.task = Task { @MainActor in
            await run()
        }
    }

    /// Tries now a yard that stopped: one its device is refused is read
    /// again at once. While the yards are signed out this changes nothing:
    /// the person signs in, and the yards are followed with new clients.
    func retry() {
        retries += 1
        poke()
    }

    /// Stops the follower.
    func close() {
        streamId += 1
        streamEnd = nil
        task?.cancel()
        task = nil
        yards.remove(self)
    }

    func poke() {
        stopPokes += 1
        gate.poke()
    }

    private func update(_ apply: (inout YardState) -> Void) {
        apply(&state)
        for observer in observers.values { observer(state) }
    }

    func observe(_ observer: @escaping @MainActor (YardState) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func run() async {
        defer { yards.remove(self) }
        var pairStopped = false
        var retryAtPairStop = 0
        outer: while !Task.isCancelled {
            while !yards.foreground {
                if Task.isCancelled {
                    return
                }
                let generation = gate.current
                if !yards.foreground {
                    await gate.wait(since: generation)
                }
            }
            if Task.isCancelled {
                return
            }
            if yards.signedOut {
                update { $0.status = .signInAgain(words: signedOutWords) }
                let generation = gate.current
                if yards.signedOut {
                    await gate.wait(since: generation)
                }
                continue outer
            }
            if pairStopped {
                while retries == retryAtPairStop {
                    if Task.isCancelled {
                        return
                    }
                    let generation = gate.current
                    if retries == retryAtPairStop {
                        await gate.wait(since: generation)
                    }
                }
                pairStopped = false
                continue outer
            }
            let backgroundedAtLoad = yards.backgrounded
            let loaded: Loaded
            do {
                loaded = try await client.load()
            } catch is CancellationError {
                return
            } catch let error as ApiError {
                if Task.isCancelled {
                    return
                }
                switch error {
                case .notSignedIn:
                    yards.noteSignedOut()
                case .notLetIn:
                    retryAtPairStop = retries
                    pairStopped = true
                    update { $0.status = .pairAgain(words: notLetInWords) }
                case .noDevice:
                    retryAtPairStop = retries
                    pairStopped = true
                    update { $0.status = .pairAgain(words: noDeviceWords) }
                default:
                    down(error)
                    await pause(backoff(error), interruptible: !isBusy(error))
                }
                continue outer
            } catch {
                if Task.isCancelled {
                    return
                }
                let unexpected = ApiError.down(why: "an unexpected error")
                down(unexpected)
                await pause(backoff(unexpected), interruptible: true)
                continue outer
            }
            if Task.isCancelled {
                return
            }
            if !yards.foreground || yards.backgrounded != backgroundedAtLoad {
                continue outer
            }
            reloadedThrough = backgroundedAtLoad
            update {
                $0.status = .up
                $0.loaded = loaded
                $0.lastSeq = loaded.head
                $0.events = []
            }
            while !Task.isCancelled {
                // The app went to the back meanwhile: the state is read
                // again, however briefly it was in the back.
                if yards.backgrounded != reloadedThrough {
                    break
                }
                guard let end = await followStream() else {
                    return
                }
                switch end {
                case .closed(let heard):
                    update { $0.status = .up }
                    await pause(heard ? followReplacingPause : followRetry, interruptible: true)
                case .failed(let error):
                    if Task.isCancelled {
                        return
                    }
                    switch error {
                    case .notSignedIn:
                        yards.noteSignedOut()
                        continue outer
                    case .notLetIn:
                        retryAtPairStop = retries
                        pairStopped = true
                        update { $0.status = .pairAgain(words: notLetInWords) }
                        continue outer
                    case .noDevice:
                        retryAtPairStop = retries
                        pairStopped = true
                        update { $0.status = .pairAgain(words: noDeviceWords) }
                        continue outer
                    default:
                        down(error)
                        await pause(backoff(error), interruptible: !isBusy(error))
                    }
                case .stopped(let reason):
                    switch reason {
                    // The stream opens again below, after the last seen.
                    case .restart:
                        continue
                    case .background, .signedOut:
                        continue outer
                    }
                }
            }
        }
    }

    /// Follows the stream after the last seq read, until it ends, fails, or
    /// is stopped. Nil when the follower is cancelled. A load or stream
    /// error is the caller's; anything else is unexpected and is followed
    /// as `down`.
    private func followStream() async -> StreamEnd? {
        streamId += 1
        let id = streamId
        streamEnd = nil
        let opened = FlagBox()
        let openStops = stopPokes
        if yards.signedOut {
            return .stopped(.signedOut)
        }
        if !yards.foreground || yards.backgrounded != reloadedThrough {
            return .stopped(.background)
        }
        let client = self.client
        let after = state.lastSeq
        let gate = self.gate
        // The collector applies each event as it arrives and reports how
        // the stream ended. It is cancelled on every exit, so a background
        // scene or a network change closes the request without waiting for
        // the watchdog.
        let collector = Task { @MainActor in
            var heard = false
            do {
                for try await event in client.events(after: after, onOpen: {
                    opened.mark()
                    gate.poke()
                }) {
                    guard id == self.streamId, !Task.isCancelled else {
                        return
                    }
                    heard = true
                    guard event.seq > self.state.lastSeq else {
                        continue
                    }
                    self.update {
                        $0.status = .up
                        $0.lastSeq = event.seq
                        $0.lastEvent = event
                        $0.events = Array(($0.events + [event]).suffix(keptEvents))
                    }
                }
                guard id == self.streamId, !Task.isCancelled else {
                    return
                }
                self.streamEnd = .closed(heard: heard)
                gate.poke()
            } catch is CancellationError {
                return
            } catch let error as ApiError {
                guard id == self.streamId, !Task.isCancelled else {
                    return
                }
                self.streamEnd = .failed(error)
                gate.poke()
            } catch {
                guard id == self.streamId, !Task.isCancelled else {
                    return
                }
                self.streamEnd = .failed(ApiError.down(why: "an unexpected error"))
                gate.poke()
            }
        }
        defer {
            // Ignore any late callback before asking the stream to cancel.
            if streamId == id {
                streamId += 1
            }
            collector.cancel()
        }
        while !Task.isCancelled {
            let generation = gate.current
            if let end = streamEnd {
                streamEnd = nil
                return end
            }
            if opened.take() {
                update { $0.status = .up }
            }
            if yards.signedOut {
                return .stopped(.signedOut)
            }
            if !yards.foreground || yards.backgrounded != reloadedThrough {
                return .stopped(.background)
            }
            if stopPokes != openStops {
                return .stopped(.restart)
            }
            await gate.wait(since: generation)
        }
        return nil
    }

    /// Waits `duration` out, unless the wait ends early: the app going to
    /// the back or coming to the front, the session refused, or `retry` (a
    /// yard the edge calls not ready is tried again at once on coming to
    /// the front). A busy yard's wait (`interruptible` false) is ended
    /// early by nothing but the session refused, so its stream is not
    /// opened again sooner.
    private func pause(_ duration: Duration, interruptible: Bool) async {
        let done = FlagBox()
        let clock = self.clock
        let gate = self.gate
        let sleeper = Task.detached {
            try? await clock.sleep(duration)
            if !Task.isCancelled {
                done.mark()
                gate.poke()
            }
        }
        defer { sleeper.cancel() }
        // No stream is open while a pause sleeps, so any poke but the
        // sleeper's own is a stop. An interruptible pause ends on the
        // first poke since it began, so its cookie never moves; a busy
        // yard's pause sleeps through every poke but the session refused,
        // so its own waits start fresh.
        let entered = gate.current
        while !Task.isCancelled {
            let generation = gate.current
            if done.isSet {
                return
            }
            if interruptible {
                if generation != entered {
                    return
                }
            } else {
                if yards.signedOut {
                    return
                }
            }
            await gate.wait(since: generation)
        }
    }

    private func down(_ error: ApiError) {
        update { $0.status = .down(words: words(error), short: short(error)) }
    }
}

extension Follower: Followed {
    /// The user every call is made as: what `/user/me` answered.
    private func me() throws -> String {
        guard let user = state.loaded?.me.user else {
            throw ApiError.down(why: "the yard is not read yet")
        }
        return user
    }

    func conversation(with: String, limit: Int64, before: Int64) async throws -> Page {
        try await client.conversation(a: me(), b: with, limit: limit, before: before)
    }

    func mail(to: String, text: String, files: [MailFile]) async throws {
        try await client.mail(to: to, text: text, actor: me(), files: files)
    }

    func putBlob(_ bytes: Data) async throws -> BlobRef {
        try await client.putBlob(bytes)
    }

    func blob(hash: String) async throws -> Data? {
        try await client.blob(hash: hash)
    }

    func ackInbox(through: Int64) async throws {
        try await client.ackUserInbox(name: me(), through: through)
    }

    func notifications() async throws -> Notifications {
        try await client.userNotifications(name: me(), limit: 0)
    }

    func ackNotifications(through: Int64) async throws {
        try await client.ackUserNotifications(name: me(), through: through)
    }

    func crew() async throws -> [CrewMember] {
        try await client.crew()
    }

    func asks() async throws -> Asks {
        try await client.userAsks(name: me())
    }

    func bead(_ bead: String) async throws -> Bead {
        try await client.bead(bead)
    }

    func flows() async throws -> Flows {
        try await client.flows(viewer: me())
    }

    func answer(bead: String, ask: Int64, option: Int64, words: String, weighed: Bool) async throws {
        try await client.answerAsk(bead: bead, ask: ask, option: option, words: words, actor: me(), weighed: weighed)
    }

    func approve(bead: String, ask: Int64, weighed: Bool) async throws {
        try await client.approveAsk(bead: bead, ask: ask, actor: me(), weighed: weighed)
    }

    func approveSetup(bead: String, ask: Int64, option: Int64, weighed: Bool) async throws {
        try await client.approveSetup(bead: bead, ask: ask, option: option, actor: me(), weighed: weighed)
    }

    func give(bead: String, ask: Int64, values: [String: String], weighed: Bool) async throws {
        try await client.giveSecret(bead: bead, ask: ask, values: values, actor: me(), weighed: weighed)
    }

    func later(bead: String, ask: Int64) async throws {
        try await client.deferAsk(bead: bead, ask: ask, actor: me())
    }

    func decline(bead: String, ask: Int64, words: String) async throws {
        try await client.declineAsk(bead: bead, ask: ask, words: words, actor: me())
    }
}

/// How a stream ended.
private enum StreamEnd {
    /// The far end closed it; `heard` whether it brought any event.
    case closed(heard: Bool)
    /// It failed with an answer's error.
    case failed(ApiError)
    /// It was stopped, for `reason`.
    case stopped(StopReason)
}

private enum StopReason {
    case background
    case signedOut
    case restart
}

/// A flag set from any task and read on the follower: one stream's opened
/// signal, one pause's slept signal.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    func mark() {
        lock.withLock { flagged = true }
    }

    /// True once, the first time after a mark.
    func take() -> Bool {
        lock.withLock {
            if flagged {
                flagged = false
                return true
            }
            return false
        }
    }

    /// Whether marked, left marked.
    var isSet: Bool {
        lock.withLock { flagged }
    }
}

private func backoff(_ error: ApiError) -> Duration {
    switch error {
    case .busy(let retryAfter):
        return retryAfter
    case .notReady:
        return followNotReadyRetry
    default:
        return followRetry
    }
}

private func isBusy(_ error: ApiError) -> Bool {
    if case .busy = error {
        return true
    }
    return false
}

/// Why the yard is not reached, in words. The pairing and sign-in
/// models say a refusal the same way.
func words(_ error: ApiError) -> String {
    switch error {
    case .away:
        return "The yard is away: the edge cannot reach it."
    case .busy(let retryAfter):
        return "The yard is busy: trying again in \(retryAfter.components.seconds) seconds."
    case .notReady(let why):
        return "The yard is not ready: \(why)."
    case .edgeDown(let why):
        return "The edge is down: \(why)."
    case .slow:
        return "The yard took too long to answer."
    case .down(let why):
        return "Nothing answers: \(why)."
    case .refused, .protocol, .notSignedIn, .notLetIn, .noDevice:
        return error.message
    }
}

/// Why the yard is not reached, in a word or two, for a row that has no
/// room for the telling: what the person does about it where that is one
/// thing, else what is wrong.
private func short(_ error: ApiError) -> String {
    switch error {
    case .away:
        return "yard away"
    case .busy:
        return "yard busy"
    case .notReady:
        return "yard not ready"
    case .edgeDown:
        return "edge down"
    case .slow, .down:
        return "nothing answers"
    case .refused, .protocol, .notSignedIn, .notLetIn, .noDevice:
        return "cannot be read"
    }
}

/// What a refused device and a refused session say: the tests pin the
/// sentences the screens will show.
let notLetInWords = "This device is no longer let in: the yard refuses its token. Pair it again."
let noDeviceWords = "The yard has no device any more. Pair it again."
let signedOutWords = "The session ran out or was revoked. Sign in again."
