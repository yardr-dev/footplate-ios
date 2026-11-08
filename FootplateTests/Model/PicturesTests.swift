@testable import Footplate
import XCTest

// The pictures cache: which files are images, what bytes are
// pictures, and the bytes fetched once and kept in memory and on
// disk by hash (after Android's PicturesTest).
@MainActor
final class PicturesTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pictures-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    private var pngData: Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]) }
    private var hashA: String { sha256Hex(pngData) }
    /// Another picture, under its own digest.
    private var jpegData: Data { Data([0xFF, 0xD8, 0xFF, 0xE0, 4, 5, 6]) }

    func testFetchedOnceKeptInMemoryAndOnDisk() async throws {
        let pictures = Pictures(directory: dir)
        var calls = 0
        let first = try await pictures.bytes(hash: hashA) { calls += 1; return self.pngData }
        XCTAssertEqual(first, pngData)
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(hashA).path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(fileMode.intValue, 0o600)
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(directoryMode.intValue, 0o700)
        let second = try await pictures.bytes(hash: hashA) { calls += 1; return self.pngData }
        XCTAssertEqual(second, pngData)
        XCTAssertEqual(calls, 1)
        // A new cache over the same directory reads the disk,
        // not the fetch.
        let again = Pictures(directory: dir)
        let third = try await again.bytes(hash: hashA) { calls += 1; return self.pngData }
        XCTAssertEqual(third, pngData)
        XCTAssertEqual(calls, 1)
    }

    func testFetchAnsweredWithNoneIsNone() async throws {
        let pictures = Pictures(directory: dir)
        let got = try await pictures.bytes(hash: hashA) { nil }
        XCTAssertNil(got)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testWhatIsKeptIsAnsweredWithoutAFetch() async {
        let pictures = Pictures(directory: dir)
        await pictures.keep(hash: hashA, bytes: pngData)
        var calls = 0
        let got = try? await pictures.bytes(hash: hashA) { calls += 1; return self.pngData }
        XCTAssertEqual(got, pngData)
        XCTAssertEqual(calls, 0)
        // What is no hash or no picture is kept as nothing.
        await pictures.keep(hash: "shed", bytes: pngData)
        await pictures.keep(hash: hashA, bytes: Data("words".utf8))
        let again = try? await pictures.bytes(hash: hashA) { calls += 1; return self.pngData }
        XCTAssertEqual(again, pngData)
        XCTAssertEqual(calls, 0)
    }

    func testWhatIsNoHexIsNoneAndNeverFetched() async throws {
        let pictures = Pictures(directory: dir)
        var calls = 0
        for bad in ["", "../shed", "zz", String(repeating: "a", count: 63),
                    String(repeating: "a", count: 65), String(repeating: "١", count: 64)] {
            let got = try await pictures.bytes(hash: bad) { calls += 1; return self.pngData }
            XCTAssertNil(got, bad)
        }
        XCTAssertEqual(calls, 0)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testWhatIsNoPictureIsNoneAndKeptAsNothing() async throws {
        let pictures = Pictures(directory: dir)
        var calls = 0
        let first = try await pictures.bytes(hash: hashA) { calls += 1; return Data("words".utf8) }
        XCTAssertNil(first)
        let second = try await pictures.bytes(hash: hashA) { calls += 1; return Data("words".utf8) }
        XCTAssertNil(second)
        XCTAssertEqual(calls, 2)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.isEmpty)
    }

    func testBytesThatAreNotWhatTheHashNamesAreNoneAndKeptAsNothing() async throws {
        // A yard answers another picture than the one the hash
        // names: it is not drawn, and not kept for any yard's letter.
        let pictures = Pictures(directory: dir)
        var calls = 0
        let got = try await pictures.bytes(hash: hashA) { calls += 1; return self.jpegData }
        XCTAssertNil(got)
        await pictures.keep(hash: hashA, bytes: jpegData)
        let again = try await pictures.bytes(hash: hashA) { calls += 1; return nil }
        XCTAssertNil(again)
        XCTAssertEqual(calls, 2)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(files.isEmpty)
        // Nor are such bytes on disk answered.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jpegData.write(to: dir.appendingPathComponent(hashA))
        let disk = try await Pictures(directory: dir).bytes(hash: hashA) { calls += 1; return nil }
        XCTAssertNil(disk)
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(hashA).path))
    }

    func testBytesOnDiskThatAreNoPictureAreNoneAndRemoved() async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("words".utf8).write(to: dir.appendingPathComponent(hashA))
        var calls = 0
        let got = try await Pictures(directory: dir).bytes(hash: hashA) { calls += 1; return self.pngData }
        XCTAssertNil(got)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(hashA).path))
    }

    // A bead's notes keep their pictures as the conversation's are kept:
    // each asked for once with the yard's blob call, drawn once it has
    // come, found on disk by a later launch; a page is never asked for, and
    // a miss is asked for again with the next read, which heals it.
    func testANotesPicturesAreAskedForOnceKeptOnDiskAndAMissIsAskedAgain() async throws {
        let yard = FakeFollowed()
        yard.blobs[hashA] = pngData
        let hashB = sha256Hex(jpegData)
        let files = [
            BlobRef(hash: hashA, kind: "image/png", bytes: 11, name: "a.png"),
            BlobRef(hash: hashB, kind: "image/jpeg", bytes: 7, name: "b.jpg"),
            BlobRef(hash: String(repeating: "dd", count: 32), kind: "text/html; charset=utf-8", bytes: 9, name: "page.html"),
        ]
        let notes = [BeadNote(seq: 1, author: "builder", text: "Shots.", files: files)]
        let note = cardDetails(Bead(id: "yd-a", notes: notes), error: nil, now: parseInstant("2026-10-08T10:11:00Z")!, zone: TimeZone(secondsFromGMT: 0)!).notes[0]
        let pictures = NotePictures(pictures: Pictures(directory: dir))
        // Nothing asked yet: the pictures are boxes, the page a line.
        XCTAssertEqual(pictures.shown(note).images, [ShownImage(hash: hashA, name: "a.png"), ShownImage(hash: hashB, name: "b.jpg")])
        XCTAssertEqual(note.files, ["page.html"])

        // Asked again while the first is out, it is asked for once; the
        // yard holds the first and not the second.
        pictures.fetch(notes, from: yard)
        pictures.fetch(notes, from: yard)
        try await waitFor("both answers") { pictures.shown(note).images.allSatisfy { $0.bytes != nil || $0.missed } }
        XCTAssertEqual(pictures.shown(note).images, [
            ShownImage(hash: hashA, name: "a.png", bytes: pngData),
            ShownImage(hash: hashB, name: "b.jpg", missed: true),
        ])
        XCTAssertEqual(yard.blobAsked.sorted(), [hashA, hashB].sorted())

        // The next read asks again for the miss alone; the yard holds it
        // now, and it is drawn.
        yard.blobs[hashB] = jpegData
        pictures.fetch(notes, from: yard)
        try await waitFor("the miss healed") { pictures.shown(note).images.last?.bytes != nil }
        XCTAssertEqual(pictures.shown(note).images.last, ShownImage(hash: hashB, name: "b.jpg", bytes: jpegData))
        XCTAssertEqual(yard.blobAsked.sorted(), [hashA, hashB, hashB].sorted())

        // A later launch finds both on disk and asks the yard for none.
        let later = NotePictures(pictures: Pictures(directory: dir))
        later.fetch(notes, from: yard)
        try await waitFor("both from disk") { later.shown(note).images.allSatisfy { $0.bytes != nil } }
        XCTAssertEqual(yard.blobAsked.count, 3)
    }

    func testAnImageIsAPngOrAJpegByItsKindAPictureByItsMagic() {
        XCTAssertTrue(isImage(BlobRef(hash: "a", kind: "image/png", bytes: 1, name: "a.png")))
        XCTAssertTrue(isImage(BlobRef(hash: "a", kind: "image/jpeg", bytes: 1, name: "a.jpg")))
        XCTAssertFalse(isImage(BlobRef(hash: "a", kind: "text/html; charset=utf-8", bytes: 1, name: "a.html")))
        XCTAssertFalse(isImage(BlobRef(hash: "a", kind: "text/plain", bytes: 1, name: "a.txt")))
        XCTAssertFalse(isImage(BlobRef(hash: "a", kind: "", bytes: 1, name: "a")))
        XCTAssertTrue(isPicture(pngData))
        XCTAssertTrue(isPicture(Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertFalse(isPicture(Data("words".utf8)))
        XCTAssertFalse(isPicture(Data([0x89, 0x50])))
        XCTAssertFalse(isPicture(Data()))
    }

    private func waitFor(_ what: String, _ match: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !match() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what)")
                throw TestTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
