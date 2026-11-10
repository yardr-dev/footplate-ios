@testable import Footplate
import XCTest

// The channel against the fake yard (design 2026-11-05, sections
// 3.1 and 3.2): a QR's fourth field pairs sealed, a typed code pairs
// through a PAKE, every call of a sealed yard rides the one outer
// path with no device token on it, the events stream opens sealed
// and marked, and a yard the handshake cannot reach is refused
// sealed, never plain.
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

// A typed code redeemed through the PAKE (design 2026-11-05, section
// 3.1 candidate 1A, and docs/users.md, "By a typed code, through a
// PAKE"), against the fake yard whose half is the bound library's: the
// run's three posts, the keys it exchanges, what the edge between reads
// of it, and what an edge that rewrites it gets.
extension ChannelTests {
    private func pairTyped(code: String = "K7QM-2XPD", through transport: (any HTTPTransport)? = nil) async throws -> PairedYard {
        let edge = try Edge(origin: fake.origin, transport: transport ?? fake)
        return try await Pairer(edge: edge, records: records).pair(code: PairingCode(code: code, yard: "", typed: true))
    }

    /// The step each pairing post of the run named, in order.
    private func steps(_ requests: [RecordedRequest]) -> [String] {
        requests.filter { $0.path == "/user/pair" }
            .map { (($0.bodyObject()["pake"] as? [String: Any])?["step"] as? String) ?? "no step" }
    }

    func testATypedCodePairsThroughThePAKEAndTheEdgeReadsNothingOfIt() async throws {
        let session = try XCTUnwrap(records.kept.account?.session)
        let yard = try await pairTyped()
        // The device is recorded paired, with the yard's key learned from
        // the run's sealed answer in place of a QR's, and its own pinned
        // at the yard.
        XCTAssertEqual("paired", yard.sealedHow)
        XCTAssertEqual("not yet sealed", yard.channelNote)
        XCTAssertEqual(channelPublicString(try XCTUnwrap(yard.yardChannelPublic)), fake.channelPublic(yardName: ""))
        let devicePublic = channelPublicString(try channelPublicOf(try XCTUnwrap(yard.channelPrivate)))
        XCTAssertEqual(fake.pinnedKey(yardName: "", token: yard.token), devicePublic)
        XCTAssertNil(fake.home.code, "the code is used by the finish")

        // Three posts of one run, each with the session beside it, none
        // a plain redemption or a handshake of the QR's kind.
        let requests = fake.allRequests
        XCTAssertEqual(["start", "confirm", "finish"], steps(requests))
        for post in requests where post.path == "/user/pair" {
            XCTAssertEqual(session, post.header("X-Edge-Token"))
            XCTAssertNil(post.header("Authorization"))
            XCTAssertNil(post.bodyObject()["code"])
            XCTAssertNil(post.bodyObject()["sealed"])
        }
        // The edge read neither the code nor the token nor either key,
        // in any join of the code, in a request or an answer; the calls
        // after the pairing ride the channel and carry no token.
        let said = requests.map { "\($0.path) \($0.headers) \($0.bodyText)" } + fake.pairingAnswers.map { String(decoding: $0, as: UTF8.self) }
        for secret in ["K7QM-2XPD", "K7QM2XPD", "k7qm-2xpd", "k7qm2xpd", yard.token, devicePublic, fake.channelPublic(yardName: "")] {
            XCTAssertTrue(said.allSatisfy { !$0.contains(secret) }, "the edge read \(secret)")
        }
        XCTAssertTrue(requests.filter { $0.path.hasPrefix("/user/call/") }.isEmpty, "\(requests.map(\.path))")
        XCTAssertTrue(requests.contains { $0.path == "/user/e2e" })
        // And the channel the run pinned calls the yard.
        let client = try fake.edge().yard(device: yard.token, session: session, name: yard.name, channel: yard.channel)
        let loaded = try await client.load()
        XCTAssertEqual("jo", loaded.me.user)
    }

    func testATypedWrongCodeIsRefusedAtTheConfirmationAndTheCodeStaysGood() async throws {
        do {
            _ = try await pairTyped(code: "ZZZZ-ZZZZ")
            XCTFail("paired with a wrong code")
        } catch let error as ApiError {
            XCTAssertEqual(error, pairingRefused("wrong_code"))
        }
        // The run went as far as the confirmation, which is the one
        // online guess, and no key left the phone.
        XCTAssertEqual(["start", "confirm"], steps(fake.allRequests))
        XCTAssertTrue(records.kept.yards.isEmpty)
        XCTAssertNotNil(fake.home.code)
        // The right code pairs after it, in a run of its own.
        let yard = try await pairTyped()
        XCTAssertEqual("paired", yard.sealedHow)
        XCTAssertEqual(["start", "confirm", "start", "confirm", "finish"], steps(fake.allRequests))
    }

    func testAYardThatTakesNoRunIsSaidSoAndNoPlainRedemptionFollows() async throws {
        // A yard with no channel key, or older than the PAKE, answers the
        // start 400. The code is not redeemed plain after it: an edge that
        // could turn a refusal into a plain code would have the code and
        // the token.
        fake.next("/user/pair", FakeResponse(status: 400, text: "Bad Request\n"))
        do {
            _ = try await pairTyped()
            XCTFail("paired with a yard that takes no run")
        } catch let error as ApiError {
            XCTAssertEqual(error, pairingRefused("no_pake"))
            XCTAssertTrue(error.message.hasSuffix("Nothing was spent, and the code is still good."))
        }
        XCTAssertEqual(["start"], steps(fake.allRequests))
        XCTAssertEqual(1, fake.allRequests.filter { $0.path == "/user/pair" }.count)
        XCTAssertTrue(fake.requests(carrying: "K7QM").isEmpty)
        XCTAssertTrue(records.kept.yards.isEmpty)
        XCTAssertNotNil(fake.home.code)

        // A scanned QR with no fourth field keeps the plain redemption it
        // always had: its own screen told the phone the yard holds no
        // channel, which the edge cannot rewrite.
        let pairer = Pairer(edge: try fake.edge(), records: records)
        let yard = try await pairer.pair(code: PairingCode(code: "K7QM-2XPD", yard: ""))
        XCTAssertNil(yard.channel)
        XCTAssertEqual("K7QM-2XPD", fake.allRequests.last { $0.path == "/user/pair" }?.bodyObject()["code"] as? String)
    }

    func testARelayThatRewritesARunEndsItAtTheNextCheck() async throws {
        // Each row is an edge that relays the run and turns one thing in
        // it: what the phone is told of it, and the posts that went.
        let rows: [(name: String, relay: PairingRelay, error: ApiError?, prefix: String?, sent: [String])] = [
            // The yard's second message is no point of the suite: the phone
            // refuses it before it sends a confirmation.
            ("a turned second message", PairingRelay(yard: fake, onAnswer: { step, body, head in
                step == "start" ? (PairingRelay.turned(body, field: "msg"), head) : (body, head)
            }), nil, "the pairing: a pairing PAKE message of 65 bytes is no point of SPAKE2-P256-SHA256-HKDF-HMAC", ["start"]),
            // The device's confirmation turned on its way: the yard
            // refuses it as a wrong code, and no key is sent.
            ("a turned device confirmation", PairingRelay(yard: fake, onRequest: { step, body in
                step == "confirm" ? PairingRelay.turned(body, field: "confirm") : body
            }), pairingRefused("wrong_code"), nil, ["start", "confirm"]),
            // The yard's confirmation turned: the phone does not trust the
            // answer and sends nothing that holds its key.
            ("a turned yard confirmation", PairingRelay(yard: fake, onAnswer: { step, body, head in
                step == "confirm" ? (PairingRelay.turned(body, field: "confirm"), head) : (body, head)
            }), pairingRefused("unconfirmed"), nil, ["start", "confirm"]),
            // The run is gone when the confirmation arrives.
            ("a run that ran out", PairingRelay(yard: fake, onAnswer: { step, body, head in
                step == "confirm" ? (Data("Bad Request\n".utf8), HTTPHead(status: 400, headers: [:])) : (body, head)
            }), pairingRefused("pake_over"), nil, ["start", "confirm"]),
            // The sealed answer turned: it does not open, and no yard is
            // kept for a token the phone never saw.
            ("a turned sealed answer", PairingRelay(yard: fake, onAnswer: { step, body, head in
                step == "finish" ? (PairingRelay.turned(body, field: "answer"), head) : (body, head)
            }), nil, "the pairing: a pairing PAKE answer that does not open", ["start", "confirm", "finish"]),
        ]
        for row in rows {
            let before = fake.requestCount
            fake.home.code = "K7QM-2XPD"
            do {
                _ = try await pairTyped(through: row.relay)
                XCTFail("\(row.name) paired")
            } catch let error as ApiError {
                if let want = row.error {
                    XCTAssertEqual(error, want, row.name)
                } else if case .protocol(let what) = error {
                    XCTAssertTrue(what.hasPrefix(row.prefix ?? ""), "\(row.name): \(what)")
                } else {
                    XCTFail("\(row.name): \(error)")
                }
            }
            XCTAssertEqual(row.sent, steps(Array(fake.allRequests.dropFirst(before))), row.name)
            XCTAssertTrue(records.kept.yards.isEmpty, row.name)
        }
    }

    func testARecordedRunIsNoOracleForTheCode() async throws {
        // What an observer holds of one run: the two points, the two
        // confirmations and the sealed answer. None of them lets a
        // candidate code be tried afterwards, the right one included: a
        // fresh run on it makes another confirmation and refuses the
        // yard's recorded one. (That the run leaks nothing to test offline
        // is RFC 9382's and the library's; this holds the use of it.)
        _ = try await pairTyped()
        let posts = fake.allRequests.filter { $0.path == "/user/pair" }
        let answers = fake.pairingAnswers.map { (jsonObject(String(decoding: $0, as: UTF8.self))?["pake"] as? [String: Any]) ?? [:] }
        func sent(_ post: Int, _ field: String) throws -> Data {
            let text = try XCTUnwrap((posts[post].bodyObject()["pake"] as? [String: Any])?[field] as? String)
            return try XCTUnwrap(dataFromBase64URL(text))
        }
        func answered(_ answer: Int, _ field: String) throws -> Data {
            try XCTUnwrap(dataFromBase64URL(try XCTUnwrap(answers[answer][field] as? String)))
        }
        let second = try answered(0, "msg")
        let deviceConfirmation = try sent(1, "confirm")
        let yardConfirmation = try answered(1, "confirm")
        let sealedAnswer = try answered(2, "answer")
        let device = try makeDeviceKey()
        for candidate in ["K7QM-2XPD", "K7QM-2XPE", "0000-0000", "AAAA-AAAA"] {
            let guess = try PairingPAKEOpening(devicePrivate: device.devicePrivate, code: candidate)
            XCTAssertNotEqual(deviceConfirmation, try guess.finish(second), candidate)
            XCTAssertTrue((raisedChannelFailure { try guess.verify(yardConfirmation) }).unconfirmed, candidate)
            _ = raisedChannelFailure { _ = try guess.openAnswer(sealedAnswer) }
        }
        // What is no code starts no run.
        XCTAssertThrowsError(try PairingPAKEOpening(devicePrivate: device.devicePrivate, code: "K7QM"))
    }

    private func raisedChannelFailure(_ step: () throws -> Void) -> ChannelFailure {
        do {
            try step()
        } catch let failure as ChannelFailure {
            return failure
        } catch {
            XCTFail("expected a ChannelFailure, got \(error)")
        }
        XCTFail("nothing was thrown")
        return ChannelFailure(description: "")
    }

    // The bound library's halves held across its boundary on a typed
    // code, as the Go tests hold them: both ends in this process, the
    // device's key sealed only after the yard's confirmation holds.
    func testTheBoundPAKELoopBothEnds() throws {
        let device = try makeDeviceKey()
        let opening = try PairingPAKEOpening(devicePrivate: device.devicePrivate, code: "k7qm-2xpd")
        XCTAssertEqual(65, opening.first.count)
        let yard = try YardPAKEHandshake(code: "K7QM-2XPD", first: opening.first)
        XCTAssertEqual(65, yard.second.count)
        // Nothing is sealed before the yard's confirmation holds.
        XCTAssertThrowsError(try opening.sealKey())
        let confirmation = try opening.finish(yard.second)
        XCTAssertThrowsError(try opening.sealKey())
        let yardConfirmation = try yard.confirm(confirmation)
        try opening.verify(yardConfirmation)
        XCTAssertEqual(try yard.openKey(try opening.sealKey()), channelPublicString(device.devicePublic))
        let answer = Data("the token answer".utf8)
        XCTAssertEqual(answer, try opening.openAnswer(try yard.sealAnswer(answer)))

        // A wrong code fails at the yard's check, with the sentence the
        // app reads, and a message that is no point is refused at once.
        let wrong = try PairingPAKEOpening(devicePrivate: device.devicePrivate, code: "AAAA-AAAA")
        let other = try YardPAKEHandshake(code: "K7QM-2XPD", first: wrong.first)
        XCTAssertTrue(raisedChannelFailure { _ = try other.confirm(try wrong.finish(other.second)) }.unconfirmed)
        XCTAssertThrowsError(try opening.finish(Data(repeating: 0, count: 65)))
        XCTAssertThrowsError(try YardPAKEHandshake(code: "K7QM-2XPD", first: Data()))
    }
}

/// An edge between the phone and the yard that relays each post of a
/// pairing's run and may rewrite it: `onRequest` sees the step and the
/// body the phone sent, `onAnswer` the step and what the yard answered,
/// and each answers what goes on. Any other request is relayed as it
/// stands.
struct PairingRelay: HTTPTransport {
    let yard: FakeYard
    var onRequest: @Sendable (String, Data) -> Data = { _, body in body }
    var onAnswer: @Sendable (String, Data, HTTPHead) -> (Data, HTTPHead) = { _, body, head in (body, head) }

    /// The step a pairing post names, or none.
    private static func step(of body: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            .flatMap { $0["pake"] as? [String: Any] }
            .flatMap { $0["step"] as? String }
    }

    /// A post's or an answer's body with the middle byte of `field` turned.
    static func turned(_ body: Data, field: String) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              var run = object["pake"] as? [String: Any],
              let text = run[field] as? String,
              var bytes = dataFromBase64URL(text)
        else { return body }
        bytes[bytes.count / 2] ^= 0xff
        run[field] = base64URL(bytes)
        object["pake"] = run
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? body
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPHead) {
        var forwarded = request
        var named: String?
        if request.url?.path == "/user/pair", let body = request.httpBody, let step = Self.step(of: body) {
            named = step
            forwarded.httpBody = onRequest(step, body)
        }
        let (data, head) = try await yard.data(for: forwarded)
        guard let named else { return (data, head) }
        return onAnswer(named, data, head)
    }

    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPHead) {
        try await yard.bytes(for: request)
    }
}
