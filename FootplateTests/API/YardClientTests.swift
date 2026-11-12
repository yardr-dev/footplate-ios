@testable import Footplate
import XCTest

// The calls of design 3.1 against the fake yard: what each sends (its
// path, its arguments by name and the headers of 3.1), what it reads
// of the answer, and each refusal of the table as its error.

final class YardClientTests: XCTestCase {
    private let fake = FakeYard()

    private struct Fixtures {
        let session: String
        let laptopToken: String
        let homeToken: String
        let laptop: YardClient
        let home: YardClient
    }

    private func fixtures() throws -> Fixtures {
        let session = fake.session()
        let laptopToken = fake.token(yardName: "laptop")
        let homeToken = fake.token(yardName: "")
        let edge = try fake.edge()
        return Fixtures(
            session: session,
            laptopToken: laptopToken,
            homeToken: homeToken,
            laptop: try edge.yard(device: laptopToken, session: session, name: "laptop"),
            home: try edge.yard(device: homeToken, session: session)
        )
    }

    func testEachCallSendsItsPathArgumentsAndHeaders() async throws {
        let f = try fixtures()
        let laptop = f.laptop
        // Each call, the arguments it sends, and a check of its answer.
        let calls: [(String, String, () async throws -> Void)] = [
            ("Head", "{}", { let head = try await laptop.head(); XCTAssertEqual(head, 151) }),
            ("Settings", "{}", {
                let settings = try await laptop.settings()
                XCTAssertEqual(settings.operator, "jo")
            }),
            ("GetUser", #"{"name":"jo"}"#, {
                let user = try await laptop.getUser(name: "jo")
                XCTAssertEqual(user.cursor, 12)
                XCTAssertEqual(user.notificationCursor, 10)
            }),
            ("Crew", "{}", {
                let crew = try await laptop.crew()
                XCTAssertEqual(crew.map(\.name), ["signalman", "yardmaster"])
                XCTAssertTrue(crew[0].loginScreen)
                XCTAssertEqual(crew[1].status, "working")
            }),
            ("Users", "{}", {
                let users = try await laptop.users()
                XCTAssertEqual(users.map(\.name), ["jo"])
            }),
            ("UserInbox", #"{"name":"jo","limit":20}"#, {
                let inbox = try await laptop.userInbox(name: "jo", limit: 20)
                XCTAssertEqual(inbox.mail.map(\.seq), [13, 51])
                XCTAssertEqual(inbox.unread, 2)
                XCTAssertEqual(inbox.last, 51)
                XCTAssertEqual(inbox.mail[0].files.count, 1)
                // Null where a list is promised is the empty list.
                XCTAssertEqual(inbox.mail[1].files.count, 0)
            }),
            ("Conversation", #"{"a":"jo","b":"yardmaster","limit":30,"before":152}"#, {
                let page = try await laptop.conversation(a: "jo", b: "yardmaster", limit: 30, before: 152)
                XCTAssertEqual(page.letters.map(\.seq), [13, 36])
                XCTAssertTrue(page.more)
            }),
            ("Conversation", #"{"a":"jo","b":"yardmaster","limit":30}"#, {
                let page = try await laptop.conversation(a: "jo", b: "yardmaster", limit: 30)
                XCTAssertEqual(page.letters.count, 2)
            }),
            ("PutBlob", #"{"data":"aGk="}"#, {
                let blob = try await laptop.putBlob(Data("hi".utf8))
                XCTAssertEqual(blob.hash, "497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581")
                XCTAssertEqual(blob.kind, "image/jpeg")
                XCTAssertEqual(blob.bytes, 11)
            }),
            ("Mail", #"{"to":"yardmaster","text":"Thanks. Land it.","actor":"jo"}"#, {
                try await laptop.mail(to: "yardmaster", text: "Thanks. Land it.", actor: "jo")
            }),
            ("Mail", #"{"to":"yardmaster","text":"The yard, painted.","actor":"jo","files":[{"hash":"497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581","name":"yard.jpg"}]}"#, {
                try await laptop.mail(
                    to: "yardmaster", text: "The yard, painted.", actor: "jo",
                    files: [MailFile(hash: "497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581", name: "yard.jpg")]
                )
            }),
            ("MailPeer", #"{"to":"clerk","peer":"north","text":"Is the ledger closed?","actor":"jo"}"#, {
                try await laptop.mailPeer(to: "clerk", peer: "north", text: "Is the ledger closed?", actor: "jo")
            }),
            ("MailPeer", #"{"to":"clerk","peer":"north","text":"The ledger, closed.","actor":"jo","files":[{"hash":"497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581","name":"ledger.jpg"}]}"#, {
                try await laptop.mailPeer(
                    to: "clerk", peer: "north", text: "The ledger, closed.", actor: "jo",
                    files: [MailFile(hash: "497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581", name: "ledger.jpg")]
                )
            }),
            ("AckUserInbox", #"{"name":"jo","through":51}"#, {
                try await laptop.ackUserInbox(name: "jo", through: 51)
            }),
            ("UserNotifications", #"{"name":"jo","limit":0}"#, {
                let notes = try await laptop.userNotifications(name: "jo", limit: 0)
                XCTAssertEqual(notes.notifications.map(\.seq), [10, 11])
                XCTAssertEqual(notes.last, 11)
            }),
            ("AckUserNotifications", #"{"name":"jo","through":11}"#, {
                try await laptop.ackUserNotifications(name: "jo", through: 11)
            }),
            ("UserAsks", #"{"name":"jo"}"#, {
                let asks = try await laptop.userAsks(name: "jo")
                XCTAssertEqual(asks.open.map(\.ask), [3, 7, 9])
                XCTAssertTrue(asks.open[0].weight.isEmpty)
                XCTAssertEqual(asks.open[1].weight.map(\.kind), ["as-user"])
                XCTAssertEqual(asks.open[1].identity?.sender, "U024BE7LH")
                XCTAssertEqual(asks.open[2].run?.command, "yardr depot tidy --merged")
                XCTAssertEqual(asks.decided.map(\.state), ["declined"])
            }),
            // No viewer is sent: the yard reads a device's viewer from its
            // token.
            ("Flows", "{}", {
                let flows = try await laptop.flows()
                XCTAssertEqual(flows.travelling, 7)
                XCTAssertEqual(flows.depots.map(\.name), ["yard", "drafts"])
                let stages = flows.depots[0].flows[0].stages
                let new = stages.first { $0.stage == "new" }!
                XCTAssertEqual(new.lamp, "fault")
                XCTAssertEqual(new.limit, 4)
                XCTAssertEqual(new.taken, 2)
                let train = new.beads.first { $0.working }!
                XCTAssertEqual(train.worker, "herdr train-new")
                XCTAssertEqual(train.group, "muse-builders")
                XCTAssertEqual(train.kind, "claude")
                XCTAssertEqual(train.model, "opus")
                XCTAssertEqual(new.beads.first { !$0.working }?.remark, "blocked by yd-train")
                // The backlog serves no group and no seats.
                let backlog = stages.first { $0.stage == "backlog" }!
                XCTAssertEqual(backlog.beads.count, 12)
                XCTAssertEqual(backlog.group, "")
                XCTAssertNil(backlog.limit)
                XCTAssertNil(backlog.taken)
                XCTAssertEqual(flows.depots[0].elsewhere.map(\.bead), ["yd-fence"])
                XCTAssertEqual(flows.unassigned.map(\.bead), ["yd-crm"])
            }),
            ("Bead", #"{"bead":"yd-links"}"#, {
                let bead = try await laptop.bead("yd-links")
                let ask = bead.asks[0]
                XCTAssertEqual(ask.options.map(\.label), ["Move them now", "After Friday", "You decide"])
                XCTAssertEqual(ask.recommend, 1)
                XCTAssertEqual(ask.why, "the test passed")
                XCTAssertEqual(ask.state, "open")
                XCTAssertEqual(ask.about.map(\.id), ["yd-train"])
                XCTAssertEqual(ask.about.map(\.title), ["Release train"])
                XCTAssertEqual(ask.about.map(\.stage), ["new"])
            }),
            // A note's files are read as a letter's are: a note without any
            // reads as ever, another keeps each file's hash, kind, size and
            // name, and the name a file has none of reads empty.
            ("Bead", #"{"bead":"yd-shots"}"#, {
                let notes = try await laptop.bead("yd-shots").notes
                XCTAssertEqual(notes.map(\.author), ["builder", "builder"])
                XCTAssertEqual(notes[0].files, [])
                XCTAssertEqual(notes[1].text, "The shot.")
                XCTAssertEqual(notes[1].files, [
                    BlobRef(hash: Canned.shotHash, kind: "image/png", bytes: 4160, name: "shot.png"),
                    BlobRef(hash: Canned.pageHash, kind: "text/html; charset=utf-8", bytes: 900, name: "page.html"),
                    BlobRef(hash: Canned.bareHash, kind: "application/octet-stream", bytes: 12, name: ""),
                ])
            }),
            // A depot pack's card: starter's summary, whose files are tied
            // to the sentences that name them and whose texts stand behind
            // them; a summary that folds a file into the closing count and
            // adds a source; and the same pack as a whole card.
            ("Bead", #"{"bead":"yd-pack"}"#, {
                let run = try await laptop.bead("yd-pack").asks[0].run
                let pack = run?.pack
                XCTAssertEqual(pack?.summary, true)
                XCTAssertEqual(pack?.digest, PackCards.digest)
                XCTAssertEqual(pack?.files.map(\.name), PackCards.files.map(\.name))
                for file in pack?.files ?? [] {
                    XCTAssertTrue(run?.does[file.line].hasPrefix("file \(file.name): create, sha256 (none) -> sha256 ") == true, file.name)
                }
                let builder = pack?.plan?.objects.first { $0.name == "roles/builder.md" }
                XCTAssertEqual(builder?.kind, "file")
                XCTAssertEqual(builder?.action, "create")
                XCTAssertEqual(builder?.oldSHA256, "")
                XCTAssertEqual(builder?.newSHA256, PackCards.files[0].newSHA)
                XCTAssertEqual(builder?.text, PackCards.files[0].text)
                // What the phone reads none of is passed over.
                XCTAssertEqual(pack?.plan?.objects.filter { $0.kind == "group" }.map(\.name), ["yard-builders", "yard-reviewers", "yard-assembly"])
                XCTAssertEqual(run?.carried.count, 0)
            }),
            ("Bead", #"{"bead":"yd-pack-moved"}"#, {
                let run = try await laptop.bead("yd-pack-moved").asks[0].run
                // A folded file has no line: -1, never the first sentence's 0,
                // and so is a line the yard left out.
                XCTAssertEqual(run?.pack?.files.map(\.line).last, -1)
                XCTAssertEqual(try JSONDecoder().decode(PackFile.self, from: Data(#"{"name":"x"}"#.utf8)).line, -1)
                XCTAssertEqual(run?.pack?.plan?.objects.first?.oldSHA256, PackCards.sha256("# Builder\n\nYou implement a bead.\n"))
                XCTAssertEqual(run?.carried.map(\.name), ["wired"])
                XCTAssertEqual(run?.carried.first?.files.map(\.program), ["wired/limits"])
                XCTAssertEqual(run?.carried.first?.files.first?.sha256, PackCards.sha256("#!/bin/sh\nexit 0\n"))
            }),
            ("Bead", #"{"bead":"yd-pack-whole"}"#, {
                let pack = try await laptop.bead("yd-pack-whole").asks[0].run?.pack
                XCTAssertEqual(pack?.summary, false)
                XCTAssertEqual(pack?.files.count, 0)
                XCTAssertEqual(pack?.plan?.objects.count, 8)
            }),
            // The marks of a secret ask: the login a code goes to, the
            // harness an API key is for, the user whose own login it is.
            ("Bead", #"{"bead":"yd-login"}"#, {
                let secret = try await laptop.bead("yd-login").asks[0].secret
                XCTAssertEqual(secret?.env, ["INPUT"])
                XCTAssertEqual(secret?.login, "claude-ab12")
                XCTAssertEqual(secret?.harness, "")
                XCTAssertEqual(secret?.as, "")
            }),
            ("Bead", #"{"bead":"yd-key"}"#, {
                let secret = try await laptop.bead("yd-key").asks[0].secret
                XCTAssertEqual(secret?.harness, "claude")
                XCTAssertEqual(secret?.crew, "yardmaster")
                XCTAssertEqual(secret?.login, "")
            }),
            ("Bead", #"{"bead":"yd-own"}"#, {
                let secret = try await laptop.bead("yd-own").asks[0].secret
                XCTAssertEqual(secret?.login, "claude-ab13")
                XCTAssertEqual(secret?.as, "hal")
            }),
            ("AnswerAsk", #"{"bead":"yd-links","ask":3,"option":1,"words":"move them tonight","actor":"jo"}"#, {
                try await laptop.answerAsk(bead: "yd-links", ask: 3, option: 1, words: "move them tonight", actor: "jo")
            }),
            // Weighed goes only where it is true, and words only
            // where said.
            ("AnswerAsk", #"{"bead":"yd-map","ask":7,"option":2,"actor":"jo","weighed":true}"#, {
                try await laptop.answerAsk(bead: "yd-map", ask: 7, option: 2, words: "", actor: "jo", weighed: true)
            }),
            // No run.ask values and no setup account are sent: the
            // approvals carry the pick and weighed alone.
            ("ApproveAsk", #"{"bead":"yd-tidy","ask":9,"actor":"jo","weighed":true}"#, {
                // No other approval answers a pairing.
                let pairing = try await laptop.approveAsk(bead: "yd-tidy", ask: 9, actor: "jo", weighed: true)
                XCTAssertNil(pairing)
            }),
            ("ApproveAsk", #"{"bead":"yd-tidy","ask":9,"actor":"jo"}"#, {
                try await laptop.approveAsk(bead: "yd-tidy", ask: 9, actor: "jo")
            }),
            // A pairing card's approval answers the pairing it opened, once,
            // as the call's return: the QR string as the yard made it, whole.
            ("ApproveAsk", #"{"bead":"yd-pair","ask":65,"actor":"jo","weighed":true}"#, {
                let key = channelPublicString(Data(repeating: 0x2A, count: 32))
                let qr = "https://my.yardr.dev#K7QM-2XPD#laptop#\(key)"
                self.fake.nextFor(yard: "laptop", path: "/user/call/ApproveAsk", .json(200, Canned.pairingApproved(
                    address: "https://my.yardr.dev", expires: "2026-10-08T09:30:00Z", qr: qr, yard: "laptop", channelKey: key
                )))
                let pairing = try await laptop.approveAsk(bead: "yd-pair", ask: 65, actor: "jo", weighed: true)
                XCTAssertEqual(pairing, Pairing(
                    user: "jo", device: "watch", code: "K7QM-2XPD", address: "https://my.yardr.dev", yard: "laptop",
                    expires: parseInstant("2026-10-08T09:30:00Z")!, channelKey: key, qr: qr
                ))
            }),
            // End names the user and nothing else: the device's own.
            ("DevicePairCloseSelf", #"{"user":"jo"}"#, {
                try await laptop.devicePairCloseSelf(user: "jo")
            }),
            ("ApproveSetup", #"{"bead":"yd-courier","ask":44,"option":1,"actor":"jo","weighed":true}"#, {
                try await laptop.approveSetup(bead: "yd-courier", ask: 44, option: 1, actor: "jo", weighed: true)
            }),
            // The one value the phone sends: a login's one-time code under
            // the name the ask asks for, with weighed where it is true.
            ("GiveSecret", #"{"bead":"yd-login","ask":34,"values":{"INPUT":"the-code"},"actor":"jo","weighed":true}"#, {
                try await laptop.giveSecret(bead: "yd-login", ask: 34, values: ["INPUT": "the-code"], actor: "jo", weighed: true)
            }),
            ("GiveSecret", #"{"bead":"yd-login","ask":34,"values":{"INPUT":"the-code"},"actor":"jo"}"#, {
                try await laptop.giveSecret(bead: "yd-login", ask: 34, values: ["INPUT": "the-code"], actor: "jo")
            }),
            ("DeferAsk", #"{"bead":"yd-links","ask":4,"actor":"jo"}"#, {
                try await laptop.deferAsk(bead: "yd-links", ask: 4, actor: "jo")
            }),
            ("DeclineAsk", #"{"bead":"yd-greet","ask":5,"words":"the greeting can wait","actor":"jo"}"#, {
                try await laptop.declineAsk(bead: "yd-greet", ask: 5, words: "the greeting can wait", actor: "jo")
            }),
        ]
        for (method, args, run) in calls {
            try await run()
            let request = fake.taken()
            XCTAssertEqual(request.method, "POST", method)
            XCTAssertEqual(request.path, "/user/call/\(method)", method)
            assertBody(request, args)
            assertHeaders(request, token: f.laptopToken, yard: "laptop", session: f.session)
        }
        // A yard from before yardr v0.15.0 takes no argument on Flows and
        // refuses a name it does not know (`argument "viewer": Flows has
        // none of that name (it takes none)`): the board is still read.
        fake.setTakes(yardName: "laptop", method: "Flows", [])
        let older = try await laptop.flows()
        XCTAssertEqual(older.depots.map(\.name), ["yard", "drafts"])
        assertBody(fake.taken(), "{}")
    }

    // An answer whose pairing cannot be shown (no code, no QR or no time it
    // ends) is no pairing: the approval stands, since the yard ran it, and
    // nothing is drawn for a code with no end.
    func testAnApprovalsPairingThatCannotBeShownIsNone() async throws {
        let f = try fixtures()
        for pairing in [
            #""code": "K7QM-2XPD", "qr": "https://x#K7QM-2XPD", "expires": "soon""#,
            #""code": "K7QM-2XPD", "expires": "2026-10-08T09:30:00Z""#,
            #""qr": "https://x#K7QM-2XPD", "expires": "2026-10-08T09:30:00Z""#,
            #""code": 7, "qr": "https://x", "expires": "2026-10-08T09:30:00Z""#,
            #""code": "K7QM-2XPD", "address": "https://x", "expires": "2026-10-08T09:30:00Z", "qr": "https://y#K7QM-2XPD""#,
            #""code": "AAAA-BBBB", "address": "https://x", "expires": "2026-10-08T09:30:00Z", "qr": "https://x#K7QM-2XPD""#,
            #""code": "K7QM-2XPD", "address": "https://x", "yard": "jo", "expires": "2026-10-08T09:30:00Z", "qr": "https://x#K7QM-2XPD#hal""#,
            #""code": "K7QM-2XPD", "address": "https://x", "channel_key": "abc", "expires": "2026-10-08T09:30:00Z", "qr": "https://x#K7QM-2XPD""#,
        ] {
            fake.nextFor(yard: "laptop", path: "/user/call/ApproveAsk", .json(200, #"{"result": {"pairing": {\#(pairing)}}}"#))
            let none = try await f.laptop.approveAsk(bead: "yd-pair", ask: 65, actor: "jo", weighed: true)
            XCTAssertNil(none, pairing)
        }
        // Nor does a pairing a yard names with the user or the device left
        // out stop it being shown: the card names them, and the screen
        // takes the card's.
        fake.nextFor(yard: "laptop", path: "/user/call/ApproveAsk", .json(200, #"{"result": {"pairing": {"code": "K7QM-2XPD", "address": "https://x", "qr": "https://x#K7QM-2XPD", "expires": "2026-10-08T09:30:00.250Z"}}}"#))
        let bare = try await f.laptop.approveAsk(bead: "yd-pair", ask: 65, actor: "jo", weighed: true)
        XCTAssertEqual(bare?.code, "K7QM-2XPD")
        XCTAssertEqual(bare?.user, "")
        XCTAssertEqual(bare?.expires, parseInstant("2026-10-08T09:30:00.250Z"))
    }

    func testAYardOfItsOwnCarriesTheDeviceTokenAlone() async throws {
        let f = try fixtures()
        let edge = try fake.edge()
        let direct = try edge.yardDirect(device: f.homeToken)
        let head = try await direct.head()
        XCTAssertEqual(head, 151)
        let call = fake.taken()
        XCTAssertEqual(call.path, "/user/call/Head")
        XCTAssertEqual(call.header("Authorization"), "Bearer \(f.homeToken)")
        XCTAssertNil(call.header("X-Edge-Token"))
        XCTAssertNil(call.header("X-Edge-Yard"))
        XCTAssertTrue((call.header("X-Yardr-Client") ?? "").hasPrefix("footplate-ios/"))
        // A yard of its own has no name at the edge.
        let named = await raised(InvalidValueError.self) {
            _ = try edge.yard(device: f.homeToken, session: "", name: "laptop")
        }
        XCTAssertTrue(String(describing: named).contains("no name at the edge"), String(describing: named))
        // The stream too, and a token the yard refuses is pair again,
        // with no edge in it.
        fake.stream(lines: [#"{"seq": 152, "kind": "mail"}"#])
        var seqs: [Int64] = []
        for try await event in direct.events(after: 151) {
            seqs.append(event.seq)
        }
        XCTAssertEqual(seqs, [152])
        let stream = fake.taken()
        XCTAssertEqual(stream.path, "/user/events?after=151")
        XCTAssertEqual(stream.header("Authorization"), "Bearer \(f.homeToken)")
        XCTAssertNil(stream.header("X-Edge-Token"))
        XCTAssertNil(stream.header("X-Edge-Yard"))
        let refused = await raisedApiError {
            _ = try await edge.yardDirect(device: "yardr-dev-unknown").head()
        }
        XCTAssertEqual(refused, .notLetIn)
    }

    func testTheAccountsOwnYardIsCalledWithoutXEdgeYard() async throws {
        let f = try fixtures()
        let head = try await f.home.head()
        XCTAssertEqual(head, 151)
        assertHeaders(fake.taken(), token: f.homeToken, yard: nil, session: f.session)
        let me = try await f.home.me()
        XCTAssertEqual(me, Me(user: "jo", saidBy: "phone", yard: "south"))
        let meRequest = fake.taken()
        XCTAssertEqual(meRequest.method, "GET")
        XCTAssertEqual(meRequest.path, "/user/me")
        assertHeaders(meRequest, token: f.homeToken, yard: nil, session: f.session)
        let laptopMe = try await f.laptop.me()
        XCTAssertEqual(laptopMe.yard, "laptop")
        assertHeaders(fake.taken(), token: f.laptopToken, yard: "laptop", session: f.session)
        // The yard names its coordinator, whose conversation the Ask
        // opens; a yard older than the field answers none, and the Ask
        // goes to the yardmaster.
        fake.setCoordinator(yardName: "laptop", coordinator: "mayor")
        let renamed = try await f.laptop.me()
        XCTAssertEqual(renamed.yardmaster, "mayor")
        _ = fake.taken()
        fake.setCoordinator(yardName: "", coordinator: nil)
        let older = try await f.home.me()
        XCTAssertEqual(older, Me(user: "jo", saidBy: "phone", yard: "south"))
        _ = fake.taken()
    }

    func testABlobIsFetchedByHashAndAnsweredWhole() async throws {
        let f = try fixtures()
        let hash = "497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581"
        // Bytes no text: the magic and every byte value, read as
        // none.
        var bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        bytes.append(contentsOf: (0...255).map { UInt8($0) })
        fake.setBlob(yardName: "laptop", hash: hash, bytes: bytes)
        let fetched = try await f.laptop.blob(hash: hash)
        XCTAssertEqual(fetched, bytes)
        let request = fake.taken()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/user/blobs/\(hash)")
        assertHeaders(request, token: f.laptopToken, yard: "laptop", session: f.session)
        let missing = try await f.home.blob(hash: hash)
        XCTAssertNil(missing)
        assertHeaders(fake.taken(), token: f.homeToken, yard: nil, session: f.session)
    }

    func testAHashTheYardHoldsNoMoreIsNoneAndOneThatIsNotSha256HexIsNeverSent() async throws {
        let f = try fixtures()
        let missing = try await f.laptop.blob(hash: String(repeating: "00", count: 32))
        XCTAssertNil(missing)
        _ = fake.taken()
        let sent = fake.requestCount
        for bad in ["", "../tokens", "zz", String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "١", count: 64)] {
            let refused = try await f.laptop.blob(hash: bad)
            XCTAssertNil(refused, bad)
        }
        XCTAssertEqual(fake.requestCount, sent)
    }

    func testABlobRefusedIsItsError() async throws {
        let f = try fixtures()
        let hash = String(repeating: "ab", count: 32)
        fake.next("/user/blobs/\(hash)", .signedOut())
        var error = await raisedApiError { _ = try await f.laptop.blob(hash: hash) }
        XCTAssertEqual(error, .notSignedIn)
        fake.next("/user/blobs/\(hash)", .away())
        error = await raisedApiError { _ = try await f.laptop.blob(hash: hash) }
        XCTAssertEqual(error, .away)
        fake.next("/user/blobs/\(hash)", .notLetIn())
        error = await raisedApiError { _ = try await f.laptop.blob(hash: hash) }
        XCTAssertEqual(error, .notLetIn)
    }

    func testEachRefusalBecomesItsError() async throws {
        let f = try fixtures()
        let rows: [(FakeResponse, (ApiError) -> Bool, String)] = [
            (.signedOut(), { $0 == .notSignedIn }, "signedOut"),
            (.notLetIn(), { $0 == .notLetIn }, "notLetIn"),
            (.noDevice(), { $0 == .noDevice }, "noDevice"),
            (.away(), { $0 == .away }, "away"),
            (.busy(), { $0 == .busy(retryAfter: .seconds(5)) }, "busy"),
            (.notReady(), { $0 == .notReady(why: "the yard is building") }, "notReady"),
            (.badGateway(), { $0 == .away }, "badGateway"),
            (.edgeDown(), {
                if case .edgeDown = $0 { return true }
                return false
            }, "edgeDown"),
            (.slow(), { $0 == .slow }, "slow"),
        ]
        for (response, expect, what) in rows {
            fake.next("/user/call/Head", response)
            let error = await raisedApiError { _ = try await f.laptop.head() }
            XCTAssertTrue(expect(error), "\(what): \(error)")
            _ = fake.taken()
        }
        // And on /user/me.
        fake.next("/user/me", .signedOut())
        let meError = await raisedApiError { _ = try await f.laptop.me() }
        XCTAssertEqual(meError, .notSignedIn)
    }

    func testADeviceTheYardDoesNotKnowIsNotLetIn() async throws {
        let f = try fixtures()
        let edge = try fake.edge()
        // The fake's own gate, as the yard's: a token of the other
        // yard.
        let wrongYard = try edge.yard(device: f.homeToken, session: f.session, name: "laptop")
        var error = await raisedApiError { _ = try await wrongYard.head() }
        XCTAssertEqual(error, .notLetIn)
        let nowhere = try edge.yard(device: f.homeToken, session: f.session, name: "nowhere")
        error = await raisedApiError { _ = try await nowhere.head() }
        guard case .notReady = error else {
            return XCTFail("expected notReady, got \(error)")
        }
    }

    func testReplacingIsMadeAgainAndThenAnswered() async throws {
        let f = try fixtures()
        fake.next("/user/call/Head", .replacing(), .replacing())
        let head = try await f.laptop.head()
        XCTAssertEqual(head, 151)
        XCTAssertEqual(fake.requestCount, 3)
    }

    // A yard from before yardr v0.15.0 takes no `weighed` and refuses it in
    // yardr's words (v0.14.0's lists of what each call takes). The call is
    // made once more without it and answered; that client sends none from
    // then on, on any call; and a client that has not met the refusal sends
    // it first, as one does after a restart. A current yard is the table of
    // the first test: weighed, once, on every call.
    func testAYardThatTakesNoWeighedIsAnsweredWithoutItAndToldNoMoreOfIt() async throws {
        let f = try fixtures()
        let edge = try fake.edge()
        func client() throws -> YardClient {
            try edge.yard(device: f.laptopToken, session: f.session, name: "laptop")
        }
        let calls: [(method: String, takes: [String], call: (YardClient) async throws -> Void)] = [
            ("AnswerAsk", ["bead", "ask", "option", "words", "actor"], {
                try await $0.answerAsk(bead: "yd-map", ask: 7, option: 2, words: "", actor: "jo", weighed: true)
            }),
            ("ApproveAsk", ["bead", "ask", "actor"], {
                try await $0.approveAsk(bead: "yd-tidy", ask: 9, actor: "jo", weighed: true)
            }),
            ("ApproveSetup", ["bead", "ask", "option", "values", "account", "actor"], {
                try await $0.approveSetup(bead: "yd-courier", ask: 44, option: 1, actor: "jo", weighed: true)
            }),
            ("GiveSecret", ["bead", "ask", "values", "actor"], {
                try await $0.giveSecret(bead: "yd-login", ask: 34, values: ["INPUT": "the-code"], actor: "jo", weighed: true)
            }),
        ]
        for (method, takes, _) in calls {
            fake.setTakes(yardName: "laptop", method: method, takes)
        }
        func made(_ method: String) -> [[String: Any]] {
            fake.allRequests.filter { $0.path == "/user/call/\(method)" }.map { $0.bodyObject() }
        }
        for (method, _, call) in calls {
            // A new client for each, so that none has heard of it already.
            let fresh = try client()
            try await call(fresh)
            var bodies = made(method)
            XCTAssertEqual(bodies.map { $0["weighed"] as? Bool }, [true, nil], "\(method): tried, refused, tried again")
            if bodies.count == 2 {
                var asked = bodies[0]
                asked["weighed"] = nil
                XCTAssertEqual(NSDictionary(dictionary: asked), NSDictionary(dictionary: bodies[1]), "\(method): the same call less weighed")
            }
            try await call(fresh)
            bodies = made(method)
            XCTAssertEqual(bodies.map { $0["weighed"] as? Bool }, [true, nil, nil], "\(method): told no more of it")
        }
        // What one call taught the client holds for the others, a pick too.
        let taught = try client()
        try await calls[1].call(taught)
        let sent = fake.requestCount
        for (method, _, call) in calls where method != "ApproveAsk" {
            try await call(taught)
            XCTAssertNil(made(method).last?["weighed"], method)
        }
        XCTAssertEqual(fake.requestCount - sent, 3, "one request each, with nothing left to learn")
    }

    // Only a yard saying it takes no `weighed` has the call made again
    // without it. Any other refusal is the caller's, once, and teaches the
    // client nothing; and so is a second one, the yard's sentence about
    // `weighed` included: there is no third call.
    func testAnyOtherRefusalOfAWeighedCallIsTheCallersAndNotMadeAgain() async throws {
        let f = try fixtures()
        let edge = try fake.edge()
        func made() -> [[String: Any]] {
            fake.allRequests.filter { $0.path == "/user/call/ApproveAsk" }.map { $0.bodyObject() }
        }
        func approve(_ client: YardClient) async throws {
            try await client.approveAsk(bead: "yd-tidy", ask: 9, actor: "jo", weighed: true)
        }
        // A current yard refusing a weighty card, in words that name weighed.
        let weighty = #"ask 9 is weighty (trust): approve it where its weight is shown; a client sends "weighed": true once its person has passed its gate"#
        fake.nextFor(yard: "laptop", path: "/user/call/ApproveAsk", .refused(weighty))
        let refused = await raisedApiError { try await approve(f.laptop) }
        XCTAssertEqual(refused, .refused(code: "error", message: weighty))
        XCTAssertEqual(made().map { $0["weighed"] as? Bool }, [true], "not made again")
        try await approve(f.laptop)
        XCTAssertEqual(made().map { $0["weighed"] as? Bool }, [true, true], "and nothing learned from it")

        // Refused again once it is left out, in whatever words. A client
        // for each, since one that has heard of it leaves weighed out first.
        let old = "an argument: ApproveAsk has none of that name (it takes bead, ask, actor)"
        let other = "this approval is the yard's own to make"
        for second in [old, other] {
            let fresh = try edge.yard(device: f.laptopToken, session: f.session, name: "laptop")
            let before = made().count
            fake.nextFor(yard: "laptop", path: "/user/call/ApproveAsk", .refused(old), .refused(second))
            let error = await raisedApiError { try await approve(fresh) }
            XCTAssertEqual(error, .refused(code: "error", message: second))
            XCTAssertEqual(made().count - before, 2, "tried, refused, tried again, refused: \(second)")
            XCTAssertNil(made().last?["weighed"], second)
        }
    }

    func testTheYardsBusyStreamIsBusyNotEdgeDown() async throws {
        let f = try fixtures()
        for header in ["5", nil, "soon"] as [String?] {
            fake.next("/user/events", .streamsFull(retryAfter: header))
            let error = await raisedApiError {
                for try await _ in f.laptop.events(after: 0) {}
            }
            XCTAssertEqual(error, .busy(retryAfter: .seconds(5)), "Retry-After \(String(describing: header))")
        }
        fake.next("/user/events", .streamsFull(retryAfter: "8"))
        let eight = await raisedApiError {
            for try await _ in f.laptop.events(after: 0) {}
        }
        XCTAssertEqual(eight, .busy(retryAfter: .seconds(8)))
        // The edge's own 503 is the edge down, on the stream as on a
        // call.
        fake.next("/user/events", .edgeDown())
        let down = await raisedApiError {
            for try await _ in f.laptop.events(after: 0) {}
        }
        guard case .edgeDown = down else {
            return XCTFail("expected edgeDown, got \(down)")
        }
        // And the yard replacing itself is not the edge down either.
        fake.next("/user/events", .replacing())
        let replacing = await raisedApiError {
            for try await _ in f.laptop.events(after: 0) {}
        }
        guard case .down = replacing else {
            return XCTFail("expected down, got \(replacing)")
        }
    }

    func testHeartbeatsBetweenTwoEventsGiveTheTwoEvents() async throws {
        let f = try fixtures()
        fake.stream(lines: [
            #"{"seq": 152, "kind": "mail", "actor": "yardmaster", "data": {"text": "The shed is painted.", "to": "jo", "to_user": true, "files": null}, "at": "2026-10-08T09:30:00Z"}"#,
            "",
            "   ",
            "",
            #"{"seq": 153, "kind": "noted", "actor": "yardmaster", "bead": "yd-shed", "data": {"note": 1}, "new_field": 1}"#,
        ])
        var events: [Event] = []
        for try await event in f.laptop.events(after: 151) {
            events.append(event)
        }
        XCTAssertEqual(events.map(\.seq), [152, 153])
        XCTAssertEqual(events[0].text("text"), "The shed is painted.")
        XCTAssertEqual(events[1].number("note"), 1)
        let request = fake.taken()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/user/events?after=151")
        XCTAssertEqual(request.header("Accept"), "application/x-ndjson")
        assertHeaders(request, token: f.laptopToken, yard: "laptop", session: f.session)
    }

    func testAStreamSilentPastItsTimeoutEndsWithDown() async throws {
        let f = try fixtures()
        fake.stream(lines: [#"{"seq": 152, "kind": "mail"}"#], hang: true)
        var seen: [Int64] = []
        let error = await raisedApiError {
            for try await event in f.laptop.events(after: 151, quiet: .milliseconds(200)) {
                seen.append(event.seq)
            }
        }
        XCTAssertEqual(seen, [152])
        guard case .down(let why) = error else {
            return XCTFail("expected down, got \(error)")
        }
        XCTAssertTrue(why.contains("said nothing"), why)
    }

    func testCancellingTheCollectorClosesTheStream() async throws {
        let f = try fixtures()
        fake.stream(lines: [#"{"seq": 152, "kind": "mail"}"#], hang: true)
        let seen = SeenBox()
        let collecting = Task {
            do {
                for try await event in f.laptop.events(after: 151) {
                    seen.append(event.seq)
                }
            } catch {
                // The cancel lands here; what matters is that it lands.
            }
        }
        // Wait on the effect: the first event read.
        var waited: Duration = .zero
        while seen.values.isEmpty && waited < .seconds(2) {
            try await Task.sleep(for: .milliseconds(20))
            waited += .milliseconds(20)
        }
        XCTAssertEqual(seen.values, [152])
        collecting.cancel()
        // The read blocks on a stream silent with 75 s to wait; the
        // cancel ends it at once.
        let finished = await withTimeout(.seconds(2)) {
            await collecting.value
            return true
        }
        XCTAssertTrue(finished, "cancelling the collector did not close the stream")
    }

    func testAStreamTheFarEndClosesCompletes() async throws {
        let f = try fixtures()
        var events: [Event] = []
        for try await event in f.laptop.events(after: 151) {
            events.append(event)
        }
        XCTAssertEqual(events, [])
        XCTAssertEqual(fake.taken().path, "/user/events?after=151")
    }
}

/// Events read by a collecting task, for the cancellation test.
private final class SeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []

    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ seq: Int64) {
        lock.lock()
        storage.append(seq)
        lock.unlock()
    }
}

/// Runs `operation` on a task and reports whether it finished
/// within `limit`; a hung operation is abandoned, not waited out.
private func withTimeout(_ limit: Duration, operation: @escaping @Sendable () async -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: limit)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
