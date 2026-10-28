import Darwin
import Foundation

/// A notification service extension may hit its deadline while its
/// fetch task is returning. Only the first result may reach Apple's
/// content handler.
final class WakeCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

// Filling a wake in (design 8787 section 4): every paired yard's
// board is fetched over its relay-paired credentials, `arrived` and
// `wanted` run against the saved checkpoints and the screen shown,
// and a `Burst` of each kind across the yards becomes the one
// telling the running app would show. The engine is the whole of
// it, driven by the extension for a closed phone and by the app for
// a wake it takes itself; the fetch is the caller's, so a test
// stands a yard in. What becomes of the wake is decided here alone:
// show the telling, end it where the filtering entitlement stands,
// or leave the generic line standing.

/// One yard as a wake reads it: its name at the edge, which its
/// credentials and its checkpoint are kept by, and the title a
/// telling names it by where several yards are paired.
struct WakeYard: Equatable, Sendable {
    var name: String
    var title: String
}

/// Where a wake's tap lands, as the phone saved it beside the wake
/// id: the yard and the row the telling leads to, the sign-in-again
/// shape where the door has closed, or the yard list where nothing
/// stands to open. The link carries none of this (Push.swift).
enum WakeLanding: Equatable, Sendable {
    case target(yard: String, Target)
    case signInAgain
    case yardList
}

/// Where the wake landings lie, by wake id. The extension writes
/// what its wake resolved to; the app reads it on the tap, in
/// whichever process the tap launches.
protocol WakeTargetStore: Sendable {
    func save(wakeId: String, _ landing: WakeLanding)
    func landing(wakeId: String) -> WakeLanding?
}

/// What a tap on a wake opens: the target where its yard still
/// stands paired, and the yard list where it does not, as a tap on a
/// telling of a yard paired no more leaves the app where it opens.
func resolveWake(_ landing: WakeLanding?, yards: [String]) -> WakeLanding {
    guard let landing else { return .yardList }
    if case .target(let yard, _) = landing, !yards.contains(yard) {
        return .yardList
    }
    return landing
}

/// One landing as it lies in the store's file: a row's kind, its
/// yard, and its conversation partner or its bead and ask. Written
/// by the phone alone and read by the phone alone.
private struct SavedLanding: Codable, Equatable {
    var shape: String
    var yard: String = ""
    var with: String = ""
    var bead: String = ""
    var ask: Int64 = 0

    init(_ landing: WakeLanding) {
        switch landing {
        case .target(let yard, .conversation(let with)):
            shape = "conversation"
            self.yard = yard
            self.with = with
        case .target(let yard, .decision(let bead, let ask)):
            shape = "decision"
            self.yard = yard
            self.bead = bead
            self.ask = ask
        case .signInAgain:
            shape = "signInAgain"
        case .yardList:
            shape = "yardList"
        }
    }

    var landing: WakeLanding {
        switch shape {
        case "conversation": return .target(yard: yard, .conversation(with: with))
        case "decision": return .target(yard: yard, .decision(bead: bead, ask: ask))
        case "signInAgain": return .signInAgain
        default: return .yardList
        }
    }
}

/// The wake landings in memory: the tests'.
final class MemoryWakeTargetStore: WakeTargetStore, @unchecked Sendable {
    private let lock = NSLock()
    private var landings: [String: WakeLanding] = [:]

    func save(wakeId: String, _ landing: WakeLanding) {
        lock.withLock { landings[wakeId] = landing }
    }

    func landing(wakeId: String) -> WakeLanding? {
        lock.withLock { landings[wakeId] }
    }
}

/// The wake landings as one file in a directory — the app group's,
/// in the app and the extension — written whole at each save, since
/// a wake is saved once and read on its tap. One small entry a wake;
/// a tap whose id stands in no entry finds the yard list.
final class FileWakeTargetStore: WakeTargetStore, @unchecked Sendable {
    private let file: URL
    private let lockFile: URL
    private let local = NSLock()

    init(directory: URL) {
        file = directory.appendingPathComponent("wake-targets.json")
        lockFile = directory.appendingPathComponent("wake-targets.lock")
    }

    /// The store of the app group both processes share, where the
    /// container stands.
    static func shared() -> FileWakeTargetStore? {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: pushAppGroup) else {
            return nil
        }
        return FileWakeTargetStore(directory: directory)
    }

    func save(wakeId: String, _ landing: WakeLanding) {
        withStoreLock(fallback: ()) {
            var saved = read()
            saved[wakeId] = SavedLanding(landing)
            write(saved)
        }
    }

    func landing(wakeId: String) -> WakeLanding? {
        withStoreLock(fallback: nil) { read()[wakeId]?.landing }
    }

    /// App and notification service extension are separate processes:
    /// serialize the read-modify-write across both, or simultaneous
    /// wakes can replace one another's tap landing in the shared file.
    private func withStoreLock<T>(fallback: T, _ body: () -> T) -> T {
        local.lock()
        defer { local.unlock() }
        let handle = FileHandle(forWritingAtPath: lockFile.path) ?? {
            FileManager.default.createFile(atPath: lockFile.path, contents: nil)
            return FileHandle(forWritingAtPath: lockFile.path)
        }()
        guard let handle else { return fallback }
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX) == 0 else { return fallback }
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        return body()
    }

    private func read() -> [String: SavedLanding] {
        guard let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([String: SavedLanding].self, from: data)
        else { return [:] }
        return saved
    }

    private func write(_ saved: [String: SavedLanding]) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: file, options: [.atomic])
    }
}

/// What becomes of one wake, once its yards are read.
enum WakeOutcome: Equatable, Sendable {
    /// Show this telling: the wake is rewritten with it.
    case show(Telling)
    /// End the wake with no banner: only where the filtering
    /// entitlement stands (Push.swift), for a fetch that found
    /// nothing new or a door that has closed.
    case suppress
    /// Leave the generic line standing: nothing-new and door-closed
    /// wakes without the entitlement, and every fetch that failed
    /// outright, so a yard away is rung about with no wording.
    case generic(kind: Kind)
}

/// Why one yard's fetch did not answer, for the outcome: the door
/// has closed (the device refused, the membership ended, the session
/// dead) or it failed for now (away, busy, slow, nothing answers).
enum FetchRefusal: Equatable, Sendable {
    case doorClosed, transient
}

func refusalOf(_ error: Error) -> FetchRefusal {
    guard let error = error as? ApiError else { return .transient }
    switch error {
    case .notSignedIn, .notLetIn, .noDevice:
        return .doorClosed
    default:
        return .transient
    }
}

/// Fills wakes in over the yards it is given. `fetch` reads one
/// yard's board whole, as `load` stands it on a `Board`; it is the
/// extension's through the relay-paired credentials, and a test's
/// standing in. The checkpoints and the landings are the shared
/// stores, so a foreground read and a wake over one board are
/// serialized by the checkpoint store and neither loses nor doubles
/// an arrival.
struct WakeEngine: Sendable {
    var yards: [WakeYard]
    var fetch: @Sendable (String) async throws -> Board
    var checkpoints: any CheckpointStore
    var targets: any WakeTargetStore
    /// Whether the no-banner path stands (Push.swift).
    var canSuppress: Bool

    /// Handles one wake: fetches every yard, runs the Notify rules
    /// against the freshest checkpoints, and commits each fetched
    /// yard's checkpoint after the decision, so the next read —
    /// foreground or wake — starts from this board. A yard with no
    /// checkpoint is baselined by its fetch and tells of nothing.
    func handle(wakeId: String, kind: Kind, shown: ScreenShown) async -> WakeOutcome {
        // Fetched apart, then judged together: the lock is not held
        // over the network, and the judging transaction re-reads the
        // checkpoints before it compares, so a board the foreground
        // moved meanwhile is the one arrivals are read against.
        var boards: [String: Board] = [:]
        var refusals: [String: FetchRefusal] = [:]
        await withTaskGroup(of: (String, Result<Board, Error>).self) { group in
            for yard in yards {
                group.addTask {
                    do {
                        return (yard.name, .success(try await fetch(yard.name)))
                    } catch {
                        return (yard.name, .failure(error))
                    }
                }
            }
            for await (name, result) in group {
                switch result {
                case .success(let board): boards[name] = board
                case .failure(let error): refusals[name] = refusalOf(error)
                }
            }
        }

        // An extension that has run out of its system budget is
        // cancelled before its generic fallback is delivered. Do not
        // advance the shared checkpoint for work no one will see.
        guard !Task.isCancelled else { return .generic(kind: kind) }

        let titles = Dictionary(uniqueKeysWithValues: yards.map { ($0.name, $0.title) })
        let news: [News] = checkpoints.transaction { access in
            var news: [News] = []
            for yard in yards {
                guard let board = boards[yard.name] else { continue }
                guard let checkpoint = access.checkpoint(yard: yard.name) else {
                    // No saved baseline: this read is the baseline,
                    // and what it holds was there before the wake.
                    access.save(yard: yard.name, YardCheckpoint(board))
                    continue
                }
                guard checkpoint.me == board.me else {
                    // A paired yard can be replaced under the same
                    // edge name. Its new person's board is a fresh
                    // baseline, not arrivals from the prior person.
                    access.save(yard: yard.name, YardCheckpoint(board))
                    continue
                }
                news += arrived(yard: yard.name, before: checkpoint.board(), after: board)
                    .filter { $0.kind == kind && wanted($0, shown: shown) }

                // A wake carries one kind. Keep the other kind's
                // checkpoint behind so this fetch cannot consume its
                // arrivals before their own wake or the foreground
                // notifier gets to tell them.
                var next = YardCheckpoint(board)
                if kind == .mail {
                    next.open = checkpoint.open
                    next.decided = checkpoint.decided
                } else {
                    next.cursor = checkpoint.cursor
                    next.letters = checkpoint.letters
                }
                access.save(yard: yard.name, next)
            }
            return news
        }

        if !news.isEmpty {
            // The relay coalesces one kind per wake; this telling
            // folds that kind across every paired yard, as the
            // running app's per-kind Burst does.
            var burst = Burst()
            for item in news { _ = burst.add(item) }
            if let telling = burst.take(named: yards.count > 1, titles: titles) {
                targets.save(wakeId: wakeId, .target(yard: telling.yard, telling.target))
                return .show(telling)
            }
        }

        // Nothing to tell of: a fetch that failed outright leaves the
        // generic line either way; nothing-new and door-closed wakes
        // end with no banner only where suppression stands.
        if refusals.values.contains(.transient) {
            targets.save(wakeId: wakeId, .yardList)
            return .generic(kind: kind)
        }
        let doorClosed = refusals.values.contains(.doorClosed)
        if canSuppress {
            targets.save(wakeId: wakeId, doorClosed ? .signInAgain : .yardList)
            return .suppress
        }
        targets.save(wakeId: wakeId, doorClosed ? .signInAgain : .yardList)
        return .generic(kind: kind)
    }
}
