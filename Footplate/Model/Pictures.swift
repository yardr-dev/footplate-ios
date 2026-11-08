import CryptoKit
import Foundation

// The pictures a conversation shows: which files are images, and the
// bytes fetched for them, kept by hash so a scroll back does not ask
// the edge again (after Android's model/Pictures.kt). A bead's notes
// carry files too: their pictures are fetched and kept the same way.

/// Whether the file is an image the phone draws: a PNG or a JPEG,
/// what its kind says, as the yard told it apart. Anything else is a
/// page or a file, which the phone never asks the yard for.
func isImage(_ file: BlobRef) -> Bool {
    file.kind == "image/png" || file.kind == "image/jpeg"
}

/// The line a note says a file that is no image by: its name, or what
/// it is where the sender gave none (a paste has no name).
func fileLine(_ file: BlobRef) -> String {
    if !file.name.isEmpty { return file.name }
    return file.kind.hasPrefix("text/html") ? "Page" : "File"
}

/// Whether the bytes are a PNG or a JPEG, by their magic: what the
/// yard read the kind from.
func isPicture(_ bytes: Data) -> Bool {
    let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    if bytes.count >= png.count, bytes.prefix(png.count).elementsEqual(png) { return true }
    return bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
}

/// The SHA-256 of `bytes`, in lowercase hex: the name the yard
/// keeps them under.
func sha256Hex(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

/// Whether `bytes` are what `hash` names. Every paired yard shares
/// the one cache, so bytes a yard answers are kept, and answered,
/// only under their own digest: no yard can put its picture under
/// a hash another yard's letter names.
func holds(_ hash: String, _ bytes: Data) -> Bool {
    sha256Hex(bytes) == hash.lowercased()
}

/// The pictures fetched, by hash: in memory for the session, and on
/// disk in `directory` past it, so a scroll back does not ask the
/// edge again. What is neither a PNG nor a JPEG is none, and is kept
/// as nothing: it is asked for again with the next conversation
/// opened. A disk that will not read or write is read past and
/// written past: the fetch still answers.
final class Pictures: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var memory: [String: Data] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    /// The app's pictures: the caches' `blobs`, beside nothing else.
    static func live() -> Pictures {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return Pictures(directory: caches.appendingPathComponent("blobs"))
    }

    private func held(_ hash: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return memory[hash]
    }

    private func store(_ hash: String, _ bytes: Data) {
        lock.lock()
        memory[hash] = bytes
        lock.unlock()
    }

    /// Keeps `bytes` under `hash`: what the phone itself sent, so
    /// its letter draws the picture at once, not after a fetch over
    /// the edge.
    func keep(hash: String, bytes: Data) async {
        guard isSHA256Hash(hash), isPicture(bytes), holds(hash, bytes) else { return }
        store(hash, bytes)
        let file = directory.appendingPathComponent(hash)
        let dir = directory
        await Task.detached {
            Self.write(bytes, to: file, in: dir)
        }.value
    }

    /// The bytes of `hash`: from memory, the disk, or `fetch`, in
    /// that order; what is fetched is kept. Nil where `fetch`
    /// answers none, and its errors are the caller's.
    func bytes(hash: String, fetch: @MainActor () async throws -> Data?) async throws -> Data? {
        // The hash came from a letter and names a file: anything
        // other than a 64-character ASCII SHA-256 hex digest is
        // refused first, so no letter can leave the cache or make
        // an overlong filename.
        guard isSHA256Hash(hash) else { return nil }
        if let held = held(hash) { return held }
        let file = directory.appendingPathComponent(hash)
        let kept = await Task.detached { () -> Data?? in
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try? Data(contentsOf: file)
        }.value
        // Distinguish no file (ask the yard) from a file read.
        if let kept {
            guard let data = kept else {
                // A read that failed is read past: ask the yard.
                return try await fetchAndKeep(hash: hash, fetch: fetch)
            }
            if !isPicture(data) || !holds(hash, data) {
                await Task.detached { try? FileManager.default.removeItem(at: file) }.value
                return nil
            }
            store(hash, data)
            return data
        }
        return try await fetchAndKeep(hash: hash, fetch: fetch)
    }

    private func fetchAndKeep(hash: String, fetch: @MainActor () async throws -> Data?) async throws -> Data? {
        guard let bytes = try await fetch() else { return nil }
        guard isPicture(bytes), holds(hash, bytes) else { return nil }
        store(hash, bytes)
        let file = directory.appendingPathComponent(hash)
        let dir = directory
        await Task.detached {
            Self.write(bytes, to: file, in: dir)
        }.value
        return bytes
    }

    private static func write(_ bytes: Data, to file: URL, in directory: URL) {
        let privateDirectory: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: privateDirectory
        )
        try? FileManager.default.setAttributes(privateDirectory, ofItemAtPath: directory.path)
        try? bytes.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// The pictures the notes of beads show, on the bead card and in a
/// decision's details: asked for with the yard's blob call through the
/// same cache the conversation's lie in, once each, and kept by hash so
/// a card opened again draws them at once. The two screens' models share
/// one. A note's page or file is said by its name and never asked for.
@MainActor
@Observable
final class NotePictures {
    private let pictures: Pictures
    private var fetched: [String: Picture] = [:]
    /// The hashes with a request out: one is asked for once at a time.
    private var fetching: Set<String> = []

    init(pictures: Pictures? = nil) {
        self.pictures = pictures ?? Pictures.live()
    }

    /// Asks `followed` for every image of `notes` it has not answered,
    /// and for those it missed again: a miss is a placeholder, not an
    /// error, and the next read of the details tries once more.
    func fetch(_ notes: [BeadNote], from followed: any Followed) {
        let images = notes.flatMap(\.files).filter(isImage)
            .map { ShownImage(hash: $0.hash, name: $0.name) }
        fetch(images, from: followed)
    }

    /// Retries any missed images in notes already read into a details
    /// row. A row keeps its text while open, but reopening it reads its
    /// pictures again.
    func fetch(_ images: [ShownImage], from followed: any Followed) {
        for image in images {
            fetch(hash: image.hash, from: followed)
        }
    }

    /// `note` with its pictures as asked for so far: the bytes where they
    /// have come, a miss where the yard held none, and as they were where
    /// a request is still out.
    func shown(_ note: CardNote) -> CardNote {
        var note = note
        note.images = note.images.map { image in
            switch fetched[image.hash] {
            case .got(let bytes): return ShownImage(hash: image.hash, name: image.name, bytes: bytes)
            case .missed: return ShownImage(hash: image.hash, name: image.name, missed: true)
            case nil: return image
            }
        }
        return note
    }

    private func fetch(hash: String, from followed: any Followed) {
        if case .got = fetched[hash] { return }
        guard fetching.insert(hash).inserted else { return }
        let pictures = self.pictures
        Task { @MainActor in
            let bytes: Data?
            do {
                bytes = try await pictures.bytes(hash: hash) { try await followed.blob(hash: hash) }
            } catch {
                bytes = nil
            }
            fetching.remove(hash)
            fetched[hash] = bytes.map { .got($0) } ?? .missed
        }
    }
}
