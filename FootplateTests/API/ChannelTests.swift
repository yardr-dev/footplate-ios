@testable import Footplate
import XCTest

// The channel against the fake yard (design 2026-11-05, sections
// 3.1 and 3.2): a QR's fourth field pairs sealed, every call of a
// sealed yard rides the one outer path with no device token on
// it, the events stream opens sealed and marked, and a yard the
// handshake cannot reach is refused sealed, never plain.
@MainActor
final class ChannelTests: XCTestCase {
    private let fake = FakeYard()
    private var records: Records!

    override func setUp() async throws {
        try await super.setUp()
        records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: fake.session())
    }

    /// Pairs the home yard sealed through the pairer, from a QR
    /// holding the fake's channel key, and answers the yard kept.
    private func pairSealed() async throws -> PairedYard {
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let code = PairingCode(code: "K7QM-2XPD", yard: "", channel: fake.channelPublic(yardName: ""))
        return try await pairer.pair(code: code)
    }

    func testASealedPairingKeepsTheChannelAndCallsSealed() async throws {
        let yard = try await pairSealed()
        XCTAssertEqual("paired", yard.sealedHow)
        XCTAssertNotNil(yard.channel)
        XCTAssertEqual("not yet sealed", yard.channelNote)
        // No request carried the pairing code or the token in the
        // clear: the pair call's body is the sealed handshake, and
        // the calls that followed ride /user/e2e alone.
        let requests = fake.allRequests
        let pair = requests.first { $0.path == "/user/pair" }
        XCTAssertNotNil(pair)
        XCTAssertTrue(pair?.bodyObject()["sealed"] != nil)
        XCTAssertNil(pair?.bodyObject()["code"])
        XCTAssertTrue(requests.filter { $0.path.hasPrefix("/user/call/") }.isEmpty, "\(requests.map(\.path))")
        XCTAssertTrue(requests.contains { $0.path == "/user/e2e" })
        // The device token crosses on no sealed call.
        for request in requests where request.path == "/user/e2e" {
            XCTAssertNil(request.header("Authorization"), "a sealed call carried the token")
        }
        // And the state loads as it always did.
        let client = try fake.edge().yard(device: yard.token, session: records.kept.account!.session, name: yard.name, channel: yard.channel)
        let loaded = try await client.load()
        XCTAssertEqual("jo", loaded.me.user)
    }
}


// The bound library held across its boundary against bytes it
// did not make: the Noise specification's IK first messages, as
// vectors_test.go in ChannelBinding holds the same bytes. The
// yard halves here open the vector's first messages and prove
// the device key they seal, at the boundary the simulator runs.
extension ChannelTests {
    private func hexData(_ text: String) -> Data {
        var data = Data()
        data.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    func testTheBoundYardOpensTheSpecificationVector() throws {
        // Noise_IK_25519_ChaChaPoly_SHA256 (revision 34): the
        // responder's private key and the initiator's, whose
        // public half the first messages seal.
        let yardPrivate = hexData("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
        let devicePublic = try channelPublicOf(hexData("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        let deviceKey = channelPublicString(devicePublic)
        // A pairing first message, its payload the code.
        let pairingFirst = hexData("358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd1662544f8445e5dc2467b1e32653192d05dee85c4781bf0dd8d33ceebb5905a7a069f09e0d3f2cad1c842930a762eb75e528270337527f958f92050deefa1892482d74328fee90d08201bba3cc")
        let pairing = try YardPairingHandshake(yardPrivate: yardPrivate, first: pairingFirst)
        XCTAssertEqual("test_msg_0", pairing.code)
        XCTAssertEqual(deviceKey, pairing.deviceKey)
        // A channel first message, no payload.
        let channelFirst = hexData("358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd1662544f8445e5dc2467b1e32653192d05dee85c4781bf0dd8d33ceebb5905a7a069f09e0d3f2cad1c842930a762eb75e52827f01d2c85189d527644b3221b4c3fc5cc")
        let channel = try YardChannelHandshake(yardPrivate: yardPrivate, first: channelFirst)
        XCTAssertEqual(deviceKey, channel.deviceKey)
        let answer = try channel.sealAnswer(tag: Data(repeating: 0x33, count: 16))
        XCTAssertFalse(answer.isEmpty)
        XCTAssertNotNil(channel.session)
    }
}

// The bound library held across its boundary, both ends in this
// process: the agreement the Go tests hold against the yard's
// transcription, at the boundary the simulator runs.
extension ChannelTests {
    func testBindingLoopBothEnds() throws {
        let device = try makeDeviceKey()
        let yard = try makeDeviceKey()
        let opening = try PairingOpening(devicePrivate: device.devicePrivate, yardPublic: yard.devicePublic, code: "K7QM-2XPD")
        let handshake = try YardPairingHandshake(yardPrivate: yard.devicePrivate, first: opening.first)
        XCTAssertEqual("K7QM-2XPD", handshake.code)
        XCTAssertEqual(channelPublicString(device.devicePublic), handshake.deviceKey)
        let reply = try handshake.sealAnswer(Data("the token answer".utf8))
        XCTAssertEqual("the token answer", String(decoding: try opening.openAnswer(reply), as: UTF8.self))

        let channelOpening = try ChannelOpening(devicePrivate: device.devicePrivate, yardPublic: yard.devicePublic)
        let channelHandshake = try YardChannelHandshake(yardPrivate: yard.devicePrivate, first: channelOpening.first)
        let tag = Data(repeating: 0x33, count: 16)
        let answer = try channelHandshake.sealAnswer(tag: tag)
        let deviceSession = try channelOpening.openAnswer(answer)
        let yardSession = try XCTUnwrap(channelHandshake.session)
        let call = Data(repeating: 0x44, count: 16)
        let run = try deviceSession.sealWhole(call: call, marker: "", present: false, plaintext: Data("sealed".utf8))
        XCTAssertEqual("sealed", String(decoding: try yardSession.openWhole(run: run, call: call, marker: "", present: false), as: UTF8.self))
    }
}

extension ChannelTests {
    /// A sealed yard for the client tests: paired here, with its
    /// key pinned at the fake yard as the pairing pinned it.
    private func sealedClient() async throws -> YardClient {
        let yard = try await pairSealed()
        return try fake.edge().yard(
            device: yard.token, session: records.kept.account!.session,
            name: yard.name, channel: yard.channel
        )
    }

    func testTheEventsStreamOpensSealedAndMarked() async throws {
        fake.stream(lines: [
            #"{"seq": 152, "kind": "mail", "actor": "yardmaster", "at": "2026-10-08T09:30:00Z", "data": {"to": "jo", "text": "The shed is painted."}}"#,
            #"{"seq": 153, "kind": "noted", "actor": "yardmaster", "bead": "yd-shed", "data": {"note": 1}}"#,
        ])
        let client = try await sealedClient()
        var seqs: [Int64] = []
        for try await event in client.events(after: 151) {
            seqs.append(event.seq)
            if seqs.count == 2 { break }
        }
        XCTAssertEqual([152, 153], seqs)
        // The stream rode the one outer path, marked long-lived,
        // and no plain events request was made.
        let streams = fake.allRequests.filter { $0.path == "/user/e2e" && $0.header("X-Edge-E2E-Stream") == "long-lived" }
        XCTAssertFalse(streams.isEmpty)
        XCTAssertTrue(fake.allRequests.filter { $0.path.hasPrefix("/user/events") }.isEmpty)

        // A yard restart (or its idle expiry) drops the server half of
        // the session. The next stream must found a new one before it is
        // treated as a removed device.
        let beforeRenewal = fake.allRequests.count
        fake.expireChannelSessions(yardName: "")
        fake.stream(lines: [
            #"{"seq": 154, "kind": "mail", "actor": "yardmaster", "data": {"to": "jo", "text": "The gate is open."}}"#,
        ])
        var renewed: [Int64] = []
        for try await event in client.events(after: 153) {
            renewed.append(event.seq)
            break
        }
        XCTAssertEqual([154], renewed)
        let renewal = Array(fake.allRequests.dropFirst(beforeRenewal))
        XCTAssertEqual(3, renewal.count)
        XCTAssertNotNil(renewal[0].header("X-Edge-E2E-Call"))
        XCTAssertNil(renewal[1].header("X-Edge-E2E-Call"), "a stale session needs a fresh handshake")
        XCTAssertNotNil(renewal[2].header("X-Edge-E2E-Call"))
    }

    func testABlobIsFetchedSealed() async throws {
        let hash = "497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581"
        var bytes = Data([0x89, 0x50, 0x4E, 0x47])
        bytes.append(contentsOf: (0...255).map { UInt8($0) })
        fake.setBlob(yardName: "", hash: hash, bytes: bytes)
        let client = try await sealedClient()
        let fetched = try await client.blob(hash: hash)
        XCTAssertEqual(fetched, bytes)
        let missing = try await client.blob(hash: String(repeating: "ab", count: 32))
        XCTAssertNil(missing)
    }

    func testAnOversizedSealedStreamRecordIsRefusedBeforeBuffering() async throws {
        let client = try await sealedClient()
        _ = try await client.me()

        // A length above flynn/noise's message bound must fail as soon
        // as the four-byte prefix arrives, without buffering its body.
        fake.next("/user/e2e", FakeResponse(status: 200, body: Data([0, 1, 0, 0])))
        var raised: ApiError?
        do {
            for try await _ in client.events(after: 0) {}
        } catch let error as ApiError {
            raised = error
        }
        guard case .down(let why) = raised else {
            XCTFail("expected the oversized record to stop the stream, got \(String(describing: raised))")
            return
        }
        XCTAssertTrue(why.contains("exceeds the Noise message limit"), why)
    }

    func testADeviceTheYardHasNotPinnedIsLetInNoMore() async throws {
        // A channel whose device key the yard never pinned: the
        // handshake is refused, and the client says the device is
        // let in no more — and sends no plain call under the token.
        let yard = try await pairSealed()
        let stranger = try makeDeviceKey()
        let client = try fake.edge().yard(
            device: yard.token, session: records.kept.account!.session, name: yard.name,
            channel: ChannelKeys(devicePrivate: stranger.devicePrivate, yardPublic: yard.yardChannelPublic!)
        )
        let before = fake.requestCount
        var raised: ApiError?
        do {
            _ = try await client.me()
        } catch let error as ApiError {
            raised = error
        }
        XCTAssertEqual(raised, .notLetIn)
        let sent = fake.allRequests.dropFirst(before)
        XCTAssertTrue(sent.allSatisfy { $0.path == "/user/e2e" }, "\(sent.map(\.path))")
    }

    func testAPairingToAWrongKeyIsRefusedAndKeepsNothing() async throws {
        // The QR's key is not the fake yard's: the sealed answer
        // cannot be opened, and no yard is kept.
        let other = try makeDeviceKey()
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let code = PairingCode(code: "K7QM-2XPD", yard: "", channel: channelPublicString(other.devicePublic))
        do {
            _ = try await pairer.pair(code: code)
            XCTFail("paired to a wrong key")
        } catch is ApiError {
            // The refusal is the pairing's, said as the client words it.
        }
        XCTAssertTrue(records.kept.yards.isEmpty)
    }
}

extension ChannelTests {
    func testASealedPairingWithAWrongCodeIsRefusedAsAPlainOneIs() async throws {
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let code = PairingCode(code: "ZZZZ-ZZZZ", yard: "", channel: fake.channelPublic(yardName: ""))
        do {
            _ = try await pairer.pair(code: code)
            XCTFail("paired with a wrong code")
        } catch let error as ApiError {
            XCTAssertEqual(error, .refused(code: "wrong_code", message: "That is not the code. The yard counts a wrong one, and the fifth ends the pairing."))
        }
        XCTAssertTrue(records.kept.yards.isEmpty)
    }
}
