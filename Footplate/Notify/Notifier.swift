import Foundation

// Telling of what the followed yards bring while the app is open
// (design 3.5): each yard's board is read for what arrived since
// (`arrived`), what is wanted with the screen shown (`wanted`) waits
// in its kind's burst, and `burstWindow` after the first of it one
// notification is told (`tell`) — where the system lets any
// (`allowed`), else nothing, not even later. The Notifier itself draws
// nothing: `tell` shows it the system's way.
@MainActor
@Observable
final class Notifier {
    /// Whether nothing is told, since the system does not let it: the
    /// permission is the only switch. Read again whenever the app
    /// comes to the front, and when `refresh` is called. True until
    /// the first refresh reads it.
    private(set) var muted: Bool = true

    private let mailroom: Mailroom
    private let records: Records
    private let allowed: @MainActor () async -> Bool
    private let tell: @MainActor (Telling) async -> Void
    private let clock: any Clock
    private var shown: ScreenShown = .elsewhere
    private var last: [String: Board] = [:]
    private var bursts: [Kind: Burst] = [:]
    private var timers: [Kind: Task<Void, Never>] = [:]

    init(
        mailroom: Mailroom,
        records: Records,
        allowed: @escaping @MainActor () async -> Bool,
        tell: @escaping @MainActor (Telling) async -> Void,
        clock: any Clock = SystemClock()
    ) {
        self.mailroom = mailroom
        self.records = records
        self.allowed = allowed
        self.tell = tell
        self.clock = clock
        // The observer lives with the mailroom; the closure holds the
        // notifier weakly, so nothing here needs removing.
        _ = mailroom.observeBoards { [weak self] in self?.sync() }
        sync()
    }

    /// `shown` is on the screen now: what arrives on it is read where
    /// it stands, and nothing more tells of it.
    func show(_ shown: ScreenShown) {
        self.shown = shown
    }

    /// Reads again whether anything is told: the permission is asked
    /// once after the first pairing, and changes else only in the
    /// system's settings, while the app is away.
    func refresh() async {
        muted = await !allowed()
    }

    private func sync() {
        let now = mailroom.boards
        for gone in last.keys where now[gone] == nil {
            last.removeValue(forKey: gone)
            for kind in bursts.keys {
                if bursts[kind]?.forget(yard: gone) == true {
                    timers[kind]?.cancel()
                    timers.removeValue(forKey: kind)
                }
            }
        }
        for (yard, board) in now {
            for item in arrived(yard: yard, before: last[yard], after: board) {
                if wanted(item, shown: shown) {
                    var burst = bursts[item.kind] ?? Burst()
                    let first = burst.add(item)
                    bursts[item.kind] = burst
                    if first, timers[item.kind] == nil {
                        let kind = item.kind
                        timers[kind] = Task { [weak self] in await self?.wait(kind) }
                    }
                }
            }
            last[yard] = board
        }
    }

    private func wait(_ kind: Kind) async {
        do {
            try await clock.sleep(burstWindow)
        } catch {
            timers[kind] = nil
            return
        }
        await fire(kind)
    }

    private func fire(_ kind: Kind) async {
        timers[kind] = nil
        let kept = records.kept
        let titles = Dictionary(uniqueKeysWithValues: kept.yards.map { ($0.name, $0.title) })
        guard var burst = bursts[kind], let telling = burst.take(named: kept.yards.count > 1, titles: titles) else { return }
        bursts[kind] = burst
        if await allowed() {
            await tell(telling)
        }
    }
}
