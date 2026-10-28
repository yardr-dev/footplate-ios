import Darwin
import Foundation

// The durable per-yard checkpoint a wake is filled against (design
// 8787 section 4): the state `arrived` needs of the board as it was
// last read — how far the mail is read, which letters are known, and
// which asks stand open or decided — and nothing else of the yard.
// The app group holds them, so the notification service extension
// reads the same checkpoint the foreground last wrote; a yard with
// no checkpoint has not been read since it was paired, and its first
// read is a baseline that tells of nothing, as `arrived` holds.
// Credentials are never written here: they stay in the shared
// Keychain group (Records), and a test holds these files to that.

/// One ask of a checkpoint, as `arrived` tells asks apart.
struct AskMark: Codable, Equatable, Hashable, Sendable {
    var bead: String
    var ask: Int64
}

/// One decided ask of a checkpoint: an ask open again after being
/// put aside is news, and after anything else is not.
struct DecidedMark: Codable, Equatable, Hashable, Sendable {
    var bead: String
    var ask: Int64
    var state: String
}

/// What one yard's last read board held, for `arrived` alone.
struct YardCheckpoint: Codable, Equatable, Sendable {
    var me: String
    /// How far the person's mail was acknowledged.
    var cursor: Int64
    /// The seq of every letter the board held, oldest first.
    var letters: [Int64]
    var open: [AskMark]
    var decided: [DecidedMark]

    /// The checkpoint of a board just read.
    init(_ board: Board) {
        me = board.me
        cursor = board.cursor
        letters = board.letters.keys.sorted()
        open = board.open.map { AskMark(bead: $0.bead, ask: $0.ask) }
        decided = board.decided.map { DecidedMark(bead: $0.bead, ask: $0.ask, state: $0.state) }
    }

    /// The board `arrived` reads this checkpoint as: only what it
    /// looks at is filled — the cursor, which letters stand, and the
    /// asks — so a letter's words are never kept here.
    func board() -> Board {
        var board = Board(me: me, head: 0)
        board.cursor = cursor
        board.letters = Dictionary(uniqueKeysWithValues: letters.map {
            ($0, Letter(seq: $0, from: "", to: me, text: ""))
        })
        board.open = open.map { OpenAsk(bead: $0.bead, ask: $0.ask) }
        board.decided = decided.map { DecidedAsk(bead: $0.bead, ask: $0.ask, state: $0.state) }
        return board
    }
}

/// Where the checkpoints lie, by yard name at the edge. Every read
/// and write of the set goes through `transaction`, so the
/// foreground and an extension wake over one board are serialized:
/// neither reads a checkpoint the other is halfway through moving,
/// and a board is compared against the freshest checkpoint there is.
protocol CheckpointStore: Sendable {
    func transaction<T>(_ body: (CheckpointAccess) throws -> T) rethrows -> T
}

/// The checkpoints as a transaction sees them: the set as it stood
/// when the transaction opened, with the caller's writes kept back
/// until it closes.
final class CheckpointAccess {
    var yards: [String: YardCheckpoint]

    init(_ yards: [String: YardCheckpoint]) {
        self.yards = yards
    }

    func checkpoint(yard: String) -> YardCheckpoint? { yards[yard] }

    func save(yard: String, _ checkpoint: YardCheckpoint) { yards[yard] = checkpoint }

    func forget(yard: String) { yards.removeValue(forKey: yard) }
}

/// The checkpoints in memory: the tests'.
final class MemoryCheckpointStore: CheckpointStore, @unchecked Sendable {
    private let lock = NSLock()
    private var yards: [String: YardCheckpoint] = [:]

    func transaction<T>(_ body: (CheckpointAccess) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        let access = CheckpointAccess(yards)
        defer { yards = access.yards }
        return try body(access)
    }
}

/// The checkpoints as one file in a directory — the app group's, in
/// the app and the extension — written whole under a lock file, so a
/// write by one process is never half-read by the other. The file is
/// small: one mark a letter and an ask, and no words of either.
final class FileCheckpointStore: CheckpointStore, @unchecked Sendable {
    private let file: URL
    private let lockFile: URL
    private let local = NSLock()

    init(directory: URL) {
        file = directory.appendingPathComponent("checkpoints.json")
        lockFile = directory.appendingPathComponent("checkpoints.lock")
    }

    /// The store of the app group both processes share, where the
    /// container stands; nil on a build with no group to share.
    static func shared() -> FileCheckpointStore? {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: pushAppGroup) else {
            return nil
        }
        return FileCheckpointStore(directory: directory)
    }

    func transaction<T>(_ body: (CheckpointAccess) throws -> T) rethrows -> T {
        local.lock()
        defer { local.unlock() }
        // The lock file is held for the whole transaction: the read,
        // the caller's fetch made between transactions apart, and the
        // write back. A crashed holder leaves no lock behind, since
        // the lock is the open file, not its standing.
        let handle = FileHandle(forWritingAtPath: lockFile.path) ?? {
            FileManager.default.createFile(atPath: lockFile.path, contents: nil)
            return FileHandle(forWritingAtPath: lockFile.path)
        }()
        guard let handle else {
            let access = CheckpointAccess(readLocked())
            defer { writeLocked(access.yards) }
            return try body(access)
        }
        defer { try? handle.close() }
        flock(handle.fileDescriptor, LOCK_EX)
        defer { flock(handle.fileDescriptor, LOCK_UN) }
        let access = CheckpointAccess(readLocked())
        defer {
            // The caller's writes land even where it threw: what it
            // saved before the throw was decided on this checkpoint.
            writeLocked(access.yards)
        }
        return try body(access)
    }

    private func readLocked() -> [String: YardCheckpoint] {
        guard let data = try? Data(contentsOf: file),
              let yards = try? JSONDecoder().decode([String: YardCheckpoint].self, from: data)
        else { return [:] }
        return yards
    }

    private func writeLocked(_ yards: [String: YardCheckpoint]) {
        guard let data = try? JSONEncoder().encode(yards) else { return }
        try? data.write(to: file, options: [.atomic])
    }
}
