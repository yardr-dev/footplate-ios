@testable import Footplate
import XCTest

// The decisions list and one decision (design 3.5, 3.4) against the
// fake yard, over a real follower: a weighty pick sends `weighed` only
// after the unlock passed or the number was typed back, and nothing
// after a cancelled one; nobody and you decide go without the gate; a
// run ask is approved behind the unlock and a setup with its preset
// pick, a secret ask shows its command and sends nothing but a login's
// one-time code, which is given behind the unlock and under no other
// secret, and a refused answer shows the yard's sentence with the
// per-type command;
// Later and Decline move the card to Decided when the yard's `noted`
// event comes, and not before; the ask's context is on the card from
// the read, a details row for the card's own bead stands first on every
// card and one for each bead the ask is about after it, each opening to
// the bead's description and notes, and Ask about this opens the
// coordinator's conversation with the bead's id first in its draft.
@MainActor
final class DecisionModelTests: XCTestCase {
    private var fake: FakeYard!
    private var clock: TestClock!
    private var yards: Yards!
    private var follower: Follower!
    private var records: Records!
    private var nav: Nav!
    private var mailroom: Mailroom!
    private var conversation: ConversationModel!
    private var unlock: FakeUnlock!
    /// Where the pictures of the details rows' notes are kept, apart from
    /// the phone's own.
    private var picturesDir: URL!

    private let fixedNow = parseInstant("2026-10-08T11:30:00Z")!

    override func setUp() async throws {
        try await super.setUp()
        picturesDir = FileManager.default.temporaryDirectory.appendingPathComponent("note-pictures-\(UUID().uuidString)")
        fake = FakeYard()
        clock = TestClock()
        unlock = FakeUnlock()
        let session = fake.session()
        let token = fake.token(yardName: "laptop")
        records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: session)
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: token))
        nav = Nav(place: .decide)
        yards = Yards(clock: clock, foreground: true)
        let client = try fake.edge().yard(device: token, session: session, name: "laptop")
        follower = yards.follow(client)
        let now = fixedNow
        mailroom = Mailroom(clock: clock, now: { now })
        mailroom.setFollowers(["laptop": follower])
        conversation = ConversationModel(mailroom: mailroom, now: { now }, zone: { TimeZone(secondsFromGMT: 0)! })
        _ = try await follower.waitFor("laptop up") { $0.status == .up }
    }

    override func tearDown() async throws {
        conversation?.leave()
        follower?.close()
        yards?.close()
        fake?.closeStreams()
        try? FileManager.default.removeItem(at: picturesDir)
        try await super.tearDown()
    }

    private func decision() -> DecisionModel {
        let now = fixedNow
        return DecisionModel(
            mailroom: mailroom, records: records, nav: nav, conversation: conversation, unlock: unlock,
            notePictures: NotePictures(pictures: Pictures(directory: picturesDir)),
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
    }

    private func decisions() -> DecisionsModel {
        let now = fixedNow
        return DecisionsModel(
            records: records, mailroom: mailroom, nav: nav,
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
    }

    private func opened(_ bead: String, _ ask: Int64) async -> DecisionModel {
        nav.openDecision(yard: "laptop", bead: bead, ask: ask)
        let model = decision()
        model.open(yard: "laptop", bead: bead, ask: ask)
        _ = await waitFor("the card \(bead)", state: { model.state }) { $0.read }
        return model
    }

    private func waitFor<T>(_ what: String, state: @escaping @MainActor () -> T, match: (T) -> Bool) async -> T {
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            let value = state()
            if match(value) { return value }
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what); last=\(value)")
                return value
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func calls(_ method: String) -> [[String: Any]] {
        fake.allRequests
            .filter { $0.path == "/user/call/\(method)" }
            .map { $0.bodyObject() }
    }

    /// The yard notes `bead`, and the queue then reads `asks`: the
    /// ended stream is opened again as the clock moves, and carries
    /// the event.
    private func noted(_ seq: Int64, _ bead: String, _ asks: String) async {
        fake.nextFor(yard: "laptop", path: "/user/call/UserAsks", FakeResponse.json(200, asks))
        fake.stream(lines: [#"{"seq": \#(seq), "kind": "noted", "actor": "jo", "bead": "\#(bead)", "at": "2026-10-08T11:30:00Z", "data": {"note": 4}}"#])
        for _ in 0..<30 {
            clock.advance(.seconds(3))
            try? await Task.sleep(for: .milliseconds(20))
            if mailroom.boards["laptop"]?.beadEvents[bead] == seq { return }
        }
        XCTFail("the noted event for \(bead) never reached the board")
    }

    func testAWeightyPickSendsWeighedOnlyAfterTheUnlockPassed() async {
        let card = await opened("yd-map", 7)
        let state = card.state
        XCTAssertEqual(state.weighty, ["WEIGHTY · as-user: writes who a sender is: U024BE7LH on slack becomes a user of the yard"])
        XCTAssertEqual(state.question, "Who is U024BE7LH on slack?")
        XCTAssertEqual(state.options.map(\.label), ["jo", "Someone new", "Nobody — ignore this sender", "You decide"])
        XCTAssertTrue(state.options[0].recommended)
        XCTAssertEqual(state.why, "jo wrote from this workspace before")
        XCTAssertNil(state.elsewhere)

        // Pick with no option chosen does nothing.
        await card.pick()
        XCTAssertTrue(calls("AnswerAsk").isEmpty)

        // Cancelled: nothing is sent, and the choice stays.
        unlock.promptResults = [false]
        card.choose(1)
        await card.pick()
        XCTAssertEqual(unlock.reasons, ["pick jo in laptop"])
        XCTAssertTrue(calls("AnswerAsk").isEmpty)
        XCTAssertEqual(card.state.chosen, 1)
        XCTAssertNil(card.state.unlocking)
        XCTAssertEqual(nav.decidePath, [DecisionRoute(yard: "laptop", bead: "yd-map", ask: 7)])

        // A choice cannot change and another pick cannot start while the
        // prompt is open. A new bead event also cancels an approval of the
        // old card, which must be read again before a weighed answer.
        unlock.holdNextPrompt = true
        let heldPick = Task { @MainActor in await card.pick() }
        await unlock.waitForPrompt()
        card.choose(2)
        XCTAssertEqual(card.state.chosen, 1)
        XCTAssertNotNil(card.state.unlocking)
        await card.pick()
        XCTAssertEqual(unlock.reasons.count, 2, "a second prompt cannot start")
        await noted(152, "yd-map", Self.asks(open: [Self.links, Self.map, Self.tidy], decided: [Self.greetDeclined]))
        await unlock.resumePrompt(true)
        await heldPick.value
        XCTAssertTrue(calls("AnswerAsk").isEmpty, "a card changed while its unlock was open")
        XCTAssertEqual(card.state.error, "The card changed while the unlock was open. Review it before answering.")

        // After reviewing the current card again, the passed pick goes
        // with weighed, and the card is left.
        card.choose(1)
        unlock.promptResults = [true]
        await card.pick()
        XCTAssertEqual(calls("AnswerAsk").count, 1)
        let body = calls("AnswerAsk")[0]
        XCTAssertEqual(body["bead"] as? String, "yd-map")
        XCTAssertEqual(body["ask"] as? Int, 7)
        XCTAssertEqual(body["option"] as? Int, 1)
        XCTAssertEqual(body["actor"] as? String, "jo")
        XCTAssertEqual(body["weighed"] as? Bool, true)
        XCTAssertEqual(nav.decidePath, [])
    }

    func testWithoutAScreenLockTheNumberTypedBackStandsForTheUnlock() async {
        unlock.gateValue = .typeBack
        let card = await opened("yd-map", 7)
        XCTAssertFalse(card.state.typeBack, "no field before a gated pick is chosen")
        card.choose(2)
        card.words("hal")
        XCTAssertTrue(card.state.typeBack)
        card.typed("8")
        await card.pick()
        XCTAssertEqual(card.state.error, "ask 7's number was not typed back, so nothing was done")
        XCTAssertTrue(calls("AnswerAsk").isEmpty)
        card.typed("7")
        await card.pick()
        XCTAssertEqual(calls("AnswerAsk").count, 1)
        XCTAssertEqual(calls("AnswerAsk")[0]["option"] as? Int, 2)
        XCTAssertEqual(calls("AnswerAsk")[0]["words"] as? String, "hal")
        XCTAssertEqual(calls("AnswerAsk")[0]["weighed"] as? Bool, true)

        // A login's code is always behind the gate, so the number is
        // wanted at once.
        card.leave()
        let login = await opened("yd-login", 34)
        XCTAssertTrue(login.state.typeBack)
        login.typed("35")
        await login.give(code: "the-code")
        XCTAssertEqual(login.state.error, "ask 34's number was not typed back, so nothing was done")
        XCTAssertTrue(calls("GiveSecret").isEmpty)
        login.typed("34")
        await login.give(code: "the-code")
        XCTAssertEqual(calls("GiveSecret").count, 1)
        XCTAssertEqual(calls("GiveSecret")[0]["weighed"] as? Bool, true)
    }

    func testNobodyAndYouDecideGoWithoutTheGate() async {
        let card = await opened("yd-map", 7)
        card.choose(3)
        await card.pick()
        card.leave()
        nav.openDecision(yard: "laptop", bead: "yd-map", ask: 7)
        card.open(yard: "laptop", bead: "yd-map", ask: 7)
        card.choose(4)
        await card.pick()
        XCTAssertTrue(unlock.reasons.isEmpty, "no prompt was asked")
        XCTAssertEqual(calls("AnswerAsk").map { $0["option"] as? Int }, [3, 4])
        XCTAssertTrue(calls("AnswerAsk").allSatisfy { $0["weighed"] == nil }, "weighed is sent only after a passed gate")
    }

    func testARunAskIsApprovedBehindTheUnlock() async {
        let card = await opened("yd-tidy", 9)
        let state = card.state
        XCTAssertTrue(state.approvable)
        XCTAssertNil(state.elsewhere)
        XCTAssertEqual(state.proposes, ["yardr depot tidy --merged", "removes the worktrees of landed beads", "deletes 12 directories under ~/.yardr/worktrees"])
        XCTAssertNil(state.pack, "no other run card opens a text")
        // A run ask is approved, not picked, and wants nothing chosen.
        await card.pick()
        XCTAssertTrue(calls("AnswerAsk").isEmpty)

        unlock.promptResults = [false]
        await card.approve()
        XCTAssertEqual(unlock.reasons, ["approve yardr depot tidy --merged in laptop"])
        XCTAssertTrue(calls("ApproveAsk").isEmpty, "a cancelled unlock sends nothing")
        XCTAssertEqual(nav.decidePath, [DecisionRoute(yard: "laptop", bead: "yd-tidy", ask: 9)])

        unlock.promptResults = [true]
        await card.approve()
        XCTAssertEqual(calls("ApproveAsk").count, 1)
        XCTAssertEqual(calls("ApproveAsk")[0]["weighed"] as? Bool, true)
        XCTAssertEqual(nav.decidePath, [])

        // Without a screen lock the number typed back stands for the
        // unlock, wanted at once since a run wants nothing picked.
        unlock.gateValue = .typeBack
        card.leave()
        let typed = await opened("yd-tidy", 9)
        XCTAssertTrue(typed.state.typeBack)
        typed.typed("8")
        await typed.approve()
        XCTAssertEqual(typed.state.error, "ask 9's number was not typed back, so nothing was done")
        typed.typed("9")
        await typed.approve()
        XCTAssertEqual(calls("ApproveAsk").count, 2)

        // A yard from before yardr v0.15.0 takes no weighed: after the same
        // unlock the call is made again without it and goes through, with
        // no refusal or command in the card's place.
        fake.setTakes(yardName: "laptop", method: "ApproveAsk", ["bead", "ask", "actor"])
        typed.leave()
        let older = await opened("yd-tidy", 9)
        older.typed("9")
        await older.approve()
        // The two before went with weighed; this one with it, refused, and
        // again without.
        XCTAssertEqual(calls("ApproveAsk").map { $0["weighed"] as? Bool }, [true, true, true, nil])
        XCTAssertNil(older.state.error)
        XCTAssertEqual(nav.decidePath, [])
    }

    // A depot pack too large to read whole (yardr design y6gp 3.3): its
    // sentences stay the card's first screen, each file's line opens that
    // file's whole text under the hashes the line gives, and nothing about
    // approving it changes.
    func testASummaryCardReadsItsSummaryFirstAndEachFileOpensItsText() async throws {
        let card = await opened("yd-pack", 61)
        let state = card.state

        // The lines of a whole card: the command, what it is, the yard's
        // sentences, and what takes it back.
        let does = PackCards.sentences(files: PackCards.files).does
        XCTAssertEqual(state.proposes[0], "yardr pack apply starter --depot yard --flow default")
        XCTAssertEqual(state.proposes[1], "Import a pack into a depot: set the yard to what the pack says")
        XCTAssertEqual(Array(state.proposes[2 ..< 2 + does.count]), does)
        XCTAssertTrue(state.proposes[2].contains("digest sha256:\(PackCards.digest)"), "the pack line names the pack by its digest")
        XCTAssertTrue(state.proposes.last?.hasPrefix("back: no one command takes it back") == true)
        XCTAssertEqual(state.weighty.count, 1)
        XCTAssertTrue(state.weighty[0].hasPrefix("WEIGHTY · code: the first install of pack starter into depot yard makes file roles/builder.md, "))
        XCTAssertTrue(state.approvable)

        // Every file opens from its own line, found by the line the yard
        // tied it to; no other line opens anything, and nothing is open.
        let pack = try XCTUnwrap(state.pack)
        XCTAssertEqual(pack.opens.count, PackCards.files.count)
        XCTAssertEqual(pack.more, [])
        XCTAssertNil(pack.text)
        for file in PackCards.files {
            let (index, entry) = try XCTUnwrap(pack.opens.first { $0.value.name == file.name }, file.name)
            XCTAssertEqual(entry, PackEntry(kind: .file, name: file.name, action: "create"))
            XCTAssertTrue(state.proposes[index].hasPrefix("file \(file.name): create, sha256 (none) -> sha256 \(file.newSHA)"), file.name)
        }

        // A create opens as its text, headed by the hashes of its line.
        let builder = PackCards.files[0]
        let (index, entry) = try XCTUnwrap(pack.opens.first { $0.value.name == builder.name })
        card.openText(entry)
        let text = try XCTUnwrap(card.state.pack?.text)
        XCTAssertEqual(text.entry, entry)
        XCTAssertEqual(text.hashes, PackHashes(old: "", new: builder.newSHA))
        XCTAssertEqual(text.parts, [PackPart(title: "Text", body: builder.text)])
        XCTAssertTrue(state.proposes[index].contains(try XCTUnwrap(text.hashes).new), "the hash on the line is the hash over the text")
        let lines = text.parts[0].lines
        XCTAssertEqual(lines.count, builder.lines.count, "the newline that ends the text is no line")
        XCTAssertEqual(lines[1], PackLine(text: ""), "a blank line is kept")
        XCTAssertTrue(lines.allSatisfy { !$0.quiet })
        card.closeText()
        XCTAssertNil(card.state.pack?.text)

        // A text open is shut with the card.
        card.openText(entry)
        card.leave()
        card.open(yard: "laptop", bead: "yd-pack", ask: 61)
        XCTAssertNil(card.state.pack?.text)

        // Approving is the run card's: behind the unlock, always with
        // `weighed`. A strong card the yard refuses from a device shows
        // the yard's sentence and the command, and its texts stay readable.
        let strong = "ask 61 is strong (code): this approval arrived through the device phone, and a strong card is not approved through a device. Approve it at a terminal on the yard's machine. Nothing ran, and the ask stays open"
        fake.nextFor(yard: "laptop", path: "/user/call/ApproveAsk", FakeResponse.json(200, #"{"error": {"code": "error", "message": "\#(strong)"}}"#))
        unlock.promptResults = [true]
        await card.approve()
        let refused = await waitFor("the refusal shown", state: { card.state }) { $0.elsewhere != nil }
        XCTAssertEqual(unlock.reasons, ["approve yardr pack apply starter --depot yard --flow default in laptop"])
        XCTAssertEqual(calls("ApproveAsk").count, 1)
        XCTAssertEqual(calls("ApproveAsk")[0]["weighed"] as? Bool, true)
        XCTAssertEqual(refused.elsewhere, "yardr bead answer yd-pack 61 --approve")
        XCTAssertEqual(refused.refusal, strong)
        XCTAssertEqual(refused.pack?.opens.count, PackCards.files.count)
        card.openText(entry)
        XCTAssertNotNil(card.state.pack?.text)
        card.leave()

        // What the sentences give no line: a file the closing count folded
        // in and a source the import adds, listed after them. A change opens
        // as its diff, header lines quiet, with its new text behind it.
        let moved = await opened("yd-pack-moved", 61)
        let movedPack = try XCTUnwrap(moved.state.pack)
        let folded = try XCTUnwrap(PackCards.files.last)
        XCTAssertEqual(movedPack.more, [PackEntry(kind: .file, name: folded.name, action: "create"), PackEntry(kind: .source, name: "wired", action: "added")])
        XCTAssertEqual(movedPack.opens.count, 4)
        XCTAssertFalse(movedPack.opens.values.contains { $0.name == folded.name })
        let (_, changed) = try XCTUnwrap(movedPack.opens.first { $0.value.action == "change" })
        moved.openText(changed)
        let diff = try XCTUnwrap(moved.state.pack?.text)
        XCTAssertEqual(diff.hashes, PackHashes(old: PackCards.sha256("# Builder\n\nYou implement a bead.\n"), new: PackCards.sha256("# Builder\n\nYou implement one bead.\n")))
        XCTAssertEqual(diff.parts.map(\.title), ["Diff", "New text"])
        XCTAssertEqual(diff.parts[0].lines.map(\.quiet), [true, true, true, false, false, false, false])
        XCTAssertEqual(Array(diff.parts[0].lines.map(\.text).suffix(2)), ["-You implement a bead.", "+You implement one bead."])
        XCTAssertEqual(diff.parts[1].body, "# Builder\n\nYou implement one bead.\n")
        moved.openText(movedPack.more[0])
        XCTAssertEqual(moved.state.pack?.text?.parts, [PackPart(title: "Text", body: folded.text)])
        moved.openText(movedPack.more[1])
        let source = try XCTUnwrap(moved.state.pack?.text)
        XCTAssertNil(source.hashes)
        XCTAssertEqual(source.parts, [
            PackPart(title: "Declaration", body: "name: wired\nbase: https://wired.example.com/v1\n"),
            PackPart(title: "Command file wired/limits", body: "#!/bin/sh\nexit 0\n", sha256: PackCards.sha256("#!/bin/sh\nexit 0\n")),
        ])
        moved.openText(PackEntry(kind: .file, name: "roles/gone.md", action: "create"))
        XCTAssertNil(moved.state.pack?.text, "a text the card does not hold opens nothing")
        moved.leave()

        // A whole card has no summary, and a card cut for a device that is
        // no operator's has neither the sentences nor the texts: both read
        // as they did.
        let whole = await opened("yd-pack-whole", 61)
        XCTAssertNil(whole.state.pack)
        XCTAssertTrue(whole.state.proposes.contains { $0.hasPrefix("file roles/builder.md: create") })
        whole.leave()
        fake.nextFor(yard: "laptop", path: "/user/call/Bead", FakeResponse.json(200, #"{"result": {"id": "yd-pack-cut", "title": "Install starter", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 62, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Install the starter pack into depot yard?", "context": [], "options": [], "state": "open", "run": {"argv": [], "command": "", "does": [], "back": "", "pack": {"name": "starter", "depot": "yard", "label": "embedded in yardr 0.9.4"}}}]}}"#))
        let cut = await opened("yd-pack-cut", 62)
        XCTAssertNil(cut.state.pack)
        XCTAssertEqual(cut.state.proposes, [])
    }

    func testASetupAskIsApprovedWithItsPresetBehindTheUnlock() async {
        let setup = await opened("yd-courier", 44)
        let state = setup.state
        XCTAssertTrue(state.approvable)
        XCTAssertEqual(state.options.map(\.label), ["Read", "Read and write", "You decide"])
        XCTAssertEqual(state.proposes, ["setup of courier", "keeps the courier account", "grants read of the parcels"])
        // A setup is approved, not picked, and wants its preset first.
        await setup.pick()
        await setup.approve()
        XCTAssertTrue(calls("ApproveSetup").isEmpty, "no preset, no approval")
        unlock.promptResults = [true]
        setup.choose(1)
        await setup.approve()
        XCTAssertEqual(unlock.reasons, ["approve setup of courier in laptop"])
        XCTAssertEqual(calls("ApproveSetup").count, 1)
        XCTAssertEqual(calls("ApproveSetup")[0]["option"] as? Int, 1)
        XCTAssertEqual(calls("ApproveSetup")[0]["weighed"] as? Bool, true)

        // A yard from before yardr v0.15.0 takes no weighed: the same preset
        // goes through the second time without it.
        fake.setTakes(yardName: "laptop", method: "ApproveSetup", ["bead", "ask", "option", "values", "account", "actor"])
        setup.leave()
        let older = await opened("yd-courier", 44)
        older.choose(1)
        unlock.promptResults = [true]
        await older.approve()
        let approvals = calls("ApproveSetup")
        XCTAssertEqual(approvals.map { $0["weighed"] as? Bool }, [true, true, nil], "tried with weighed, refused, tried again without")
        XCTAssertEqual(approvals.last?["option"] as? Int, 1)
        XCTAssertNil(older.state.error)
        XCTAssertEqual(nav.decidePath, [])
    }

    func testARefusedRunApprovalShowsTheApproveCommandWithItsValues() async {
        // A run card that asks for values in the clear.
        fake.nextFor(yard: "laptop", path: "/user/call/Bead", FakeResponse.json(200, #"{"result": {"id": "yd-hook", "title": "Add the hook", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 21, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Add the hook?", "context": [], "options": [], "state": "open", "run": {"argv": ["yardr", "hook", "add"], "command": "yardr hook add", "description": "registers the hook", "ask": ["url"]}}]}}"#))
        fake.nextFor(yard: "laptop", path: "/user/call/ApproveAsk", FakeResponse.json(200, #"{"error": {"code": "error", "message": "an approval never crosses the edge"}}"#))
        let card = await opened("yd-hook", 21)
        unlock.promptResults = [true]
        await card.approve()
        let refused = await waitFor("the refusal shown", state: { card.state }) { $0.elsewhere != nil }
        XCTAssertEqual(refused.elsewhere, "yardr bead answer yd-hook 21 --approve --value url=<value>")
        XCTAssertEqual(refused.refusal, "an approval never crosses the edge")
        XCTAssertFalse(refused.secretElsewhere)
        XCTAssertFalse(refused.approvable, "no Approve after a refusal")
        unlock.promptResults = [true]
        await card.approve()
        XCTAssertEqual(calls("ApproveAsk").count, 1, "the refused approval is not made again")
    }

    func testARefusedSetupApprovalShowsItsPresetCommand() async {
        // A first setup: no standing account or candidate listed.
        fake.nextFor(yard: "laptop", path: "/user/call/Bead", FakeResponse.json(200, #"{"result": {"id": "yd-courier-new", "title": "Set up courier", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 52, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Set up courier?", "context": [], "options": [{"label": "Read", "consequence": "reads"}, {"label": "Read and write", "consequence": "reads and writes"}], "state": "open", "setup": {"pack": "courier", "label": "courier", "does": ["creates the account"]}}]}}"#))
        fake.nextFor(yard: "laptop", path: "/user/call/ApproveSetup", FakeResponse.json(200, #"{"error": {"code": "error", "message": "an approval never crosses the edge"}}"#))
        let typed = await opened("yd-courier-new", 52)
        typed.choose(2)
        unlock.promptResults = [true]
        await typed.approve()
        let typedRefused = await waitFor("the typed refusal", state: { typed.state }) { $0.elsewhere != nil }
        XCTAssertEqual(typedRefused.elsewhere, "yardr bead answer yd-courier-new 52 2 --secret")
        typed.leave()

        // A candidate listed: taken by its source.
        fake.nextFor(yard: "laptop", path: "/user/call/Bead", FakeResponse.json(200, #"{"result": {"id": "yd-courier2", "title": "Set up courier", "stage": "new", "labels": [], "notes": [], "asks": [{"ask": 50, "to": "jo", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "question": "Update courier?", "context": [], "options": [{"label": "Read", "consequence": "reads"}], "state": "open", "setup": {"pack": "courier", "label": "courier", "candidates": [{"source": "courier-existing", "file": "/tmp/x"}], "does": ["keeps the account"]}}]}}"#))
        fake.nextFor(yard: "laptop", path: "/user/call/ApproveSetup", FakeResponse.json(200, #"{"error": {"code": "error", "message": "an approval never crosses the edge"}}"#))
        let candidate = await opened("yd-courier2", 50)
        candidate.choose(1)
        unlock.promptResults = [true]
        await candidate.approve()
        let candidateRefused = await waitFor("the candidate refusal", state: { candidate.state }) { $0.elsewhere != nil }
        XCTAssertEqual(candidateRefused.elsewhere, "yardr bead answer yd-courier2 50 1 --account courier-existing")
    }

    func testARefusedMappingPickShowsItsOptionCommand() async {
        fake.nextFor(yard: "laptop", path: "/user/call/AnswerAsk", FakeResponse.json(200, #"{"error": {"code": "error", "message": "ask 7 is weighty: approve it where its weight is shown"}}"#))
        let card = await opened("yd-map", 7)
        card.choose(1)
        unlock.promptResults = [true]
        await card.pick()
        let refused = await waitFor("the pick refusal", state: { card.state }) { $0.elsewhere != nil }
        XCTAssertEqual(refused.elsewhere, "yardr bead answer yd-map 7 1 [words]")
        XCTAssertEqual(calls("AnswerAsk").count, 1)
    }

    func testALoginCodeCardGivesItsCodeBehindTheUnlock() async throws {
        let card = await opened("yd-login", 34)
        let state = card.state
        XCTAssertTrue(state.givesCode)
        XCTAssertTrue(state.secret)
        XCTAssertFalse(state.secretElsewhere)
        XCTAssertNil(state.elsewhere, "the phone gives it: no command in its place")
        XCTAssertFalse(state.approvable)
        XCTAssertFalse(state.typeBack, "the prompt stands for the unlock")
        XCTAssertEqual(state.weighty, ["WEIGHTY · credential: INPUT, for the waiting login claude-ab12"])
        XCTAssertEqual(state.question, "Paste what Claude Code's sign-in page gave you")

        // The sign-in line is a context line of the card, and a link to
        // the page it names: the browser opens on it.
        let page = "https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&scope=user%3Ainference&state=Xk3v"
        XCTAssertEqual(state.context.first, "Sign in on this page: \(page)")
        XCTAssertEqual(linked(try XCTUnwrap(state.context.first)).runs.compactMap { $0.link }, [try XCTUnwrap(URL(string: page))])

        // A secret is given, never picked or answered in words: what is
        // typed in the words field is no code, and Approve is for a run.
        card.words("123456")
        await card.pick()
        await card.approve()
        XCTAssertTrue(calls("AnswerAsk").isEmpty)
        XCTAssertTrue(calls("ApproveAsk").isEmpty)
        XCTAssertTrue(unlock.reasons.isEmpty)

        // No code, no giving, and no prompt.
        await card.give(code: " \n")
        XCTAssertTrue(calls("GiveSecret").isEmpty)
        XCTAssertTrue(unlock.reasons.isEmpty)

        // A cancelled unlock sends nothing, and the card stays.
        unlock.promptResults = [false]
        await card.give(code: "the-code")
        XCTAssertEqual(unlock.reasons, ["give the sign-in code in laptop"])
        XCTAssertTrue(calls("GiveSecret").isEmpty)
        XCTAssertTrue(card.state.givesCode)
        XCTAssertNil(card.state.unlocking)
        XCTAssertEqual(nav.decidePath, [DecisionRoute(yard: "laptop", bead: "yd-login", ask: 34)])

        // A card that changed while the unlock was open is read again
        // before anything goes.
        unlock.holdNextPrompt = true
        let held = Task { @MainActor in await card.give(code: "the-code") }
        await unlock.waitForPrompt()
        XCTAssertNotNil(card.state.unlocking)
        await card.give(code: "the-code")
        XCTAssertEqual(unlock.reasons.count, 2, "a second prompt cannot start")
        await noted(152, "yd-login", Self.asks(open: [Self.links, Self.map, Self.tidy, Self.login], decided: [Self.greetDeclined]))
        await unlock.resumePrompt(true)
        await held.value
        XCTAssertTrue(calls("GiveSecret").isEmpty, "a card changed while its unlock was open")
        XCTAssertEqual(card.state.error, "The card changed while the unlock was open. Review it before answering.")

        // Passed: the code, trimmed, goes under the name the ask asks
        // for, with weighed, and the card is left.
        unlock.promptResults = [true]
        await card.give(code: " the-code\n")
        XCTAssertEqual(calls("GiveSecret").count, 1)
        let body = calls("GiveSecret")[0]
        XCTAssertEqual(body["bead"] as? String, "yd-login")
        XCTAssertEqual(body["ask"] as? Int, 34)
        XCTAssertEqual(body["values"] as? [String: String], ["INPUT": "the-code"])
        XCTAssertEqual(body["actor"] as? String, "jo")
        XCTAssertEqual(body["weighed"] as? Bool, true)
        XCTAssertEqual(nav.decidePath, [])
        // The code is in the call alone: nowhere the card is described.
        XCTAssertFalse(String(describing: card.state).contains("the-code"))

        // A yard from before yardr v0.15.0 takes no weighed: the code is
        // given all the same, the second time without it.
        fake.setTakes(yardName: "laptop", method: "GiveSecret", ["bead", "ask", "values", "actor"])
        card.leave()
        let older = await opened("yd-login", 34)
        unlock.promptResults = [true]
        await older.give(code: "the-code")
        let givings = calls("GiveSecret")
        XCTAssertEqual(givings.map { $0["weighed"] as? Bool }, [true, true, nil], "tried with weighed, refused, tried again without")
        XCTAssertEqual(givings.last?["values"] as? [String: String], ["INPUT": "the-code"])
        XCTAssertNil(older.state.error)
        XCTAssertEqual(nav.decidePath, [])
        XCTAssertFalse(String(describing: older.state).contains("the-code"))
    }

    func testAGivingTheYardRefusesShowsItsSentenceAndTheSecretCommand() async {
        // Not confirmed is not refused: the field stays for another try.
        fake.nextFor(yard: "laptop", path: "/user/call/GiveSecret", FakeResponse.slow())
        let card = await opened("yd-login", 34)
        unlock.promptResults = [true, true]
        await card.give(code: "the-code")
        XCTAssertEqual(card.state.error, "Not confirmed: The yard took too long to answer.")
        XCTAssertTrue(card.state.givesCode)
        XCTAssertNil(card.state.elsewhere)

        // Refused: the yard's sentence, and the command that answers it
        // on the yard's machine, in place of the field, not made again.
        fake.nextFor(yard: "laptop", path: "/user/call/GiveSecret", FakeResponse.json(200, #"{"error": {"code": "error", "message": "a secret never crosses the edge: give it at the yard's own machine"}}"#))
        await card.give(code: "the-code")
        let refused = await waitFor("the giving refused", state: { card.state }) { $0.elsewhere != nil }
        XCTAssertEqual(refused.elsewhere, "yardr bead answer yd-login 34 --secret")
        XCTAssertEqual(refused.refusal, "a secret never crosses the edge: give it at the yard's own machine")
        XCTAssertTrue(refused.secret)
        XCTAssertFalse(refused.givesCode, "no field after a refusal")
        XCTAssertNil(refused.error)
        XCTAssertEqual(calls("GiveSecret").count, 2)
        await card.give(code: "the-code")
        XCTAssertEqual(calls("GiveSecret").count, 2, "the refused giving is not made again")
    }

    func testASecretCardSendsNothingAndShowsItsCommand() async {
        let secret = await opened("yd-token", 18)
        let state = secret.state
        XCTAssertEqual(state.elsewhere, "yardr bead answer yd-token 18 --secret")
        XCTAssertFalse(state.approvable)
        XCTAssertTrue(state.secretElsewhere)
        XCTAssertEqual(state.proposes, ["the token the yard calls back with", "CRM_UPDATE_TOKEN"])
        await secret.pick()
        await secret.approve()
        XCTAssertTrue(calls("AnswerAsk").isEmpty)
        XCTAssertTrue(calls("ApproveAsk").isEmpty)
        XCTAssertTrue(calls("ApproveSetup").isEmpty)
        XCTAssertTrue(unlock.reasons.isEmpty)
        // Later stays, since it is no approval.
        await secret.later()
        XCTAssertEqual(calls("DeferAsk").count, 1)
        secret.leave()

        // An API key asked for at a crew member's login screen: no
        // field, no giving, whatever is sent at it.
        let key = await opened("yd-key", 22)
        XCTAssertFalse(key.state.givesCode)
        XCTAssertTrue(key.state.secret)
        XCTAssertTrue(key.state.secretElsewhere)
        XCTAssertEqual(key.state.elsewhere, "yardr bead answer yd-key 22 --secret")
        await key.give(code: "sk-ant-not-given")
        key.words("sk-ant-not-given")
        await key.pick()
        XCTAssertTrue(calls("GiveSecret").isEmpty)
        XCTAssertTrue(calls("AnswerAsk").isEmpty)
        XCTAssertTrue(unlock.reasons.isEmpty)
        key.leave()

        // The code of a user's own login is refused down the link, so
        // the phone does not take it either.
        let own = await opened("yd-own", 36)
        XCTAssertFalse(own.state.givesCode)
        XCTAssertTrue(own.state.secretElsewhere)
        XCTAssertEqual(own.state.elsewhere, "yardr bead answer yd-own 36 --secret")
        await own.give(code: "the-code")
        XCTAssertTrue(calls("GiveSecret").isEmpty)
        XCTAssertTrue(unlock.reasons.isEmpty)
        own.leave()

        // An ask with no options is answered as option 0 with words.
        let wordsOnly = await opened("yd-words", 12)
        XCTAssertTrue(wordsOnly.state.options.isEmpty)
        await wordsOnly.pick()
        XCTAssertTrue(calls("AnswerAsk").isEmpty, "no words, no answer")
        wordsOnly.words("Tomorrow afternoon")
        fake.nextFor(yard: "laptop", path: "/user/call/AnswerAsk", FakeResponse.json(200, #"{"error": {"code": "error", "message": "this answer needs a note on the yard"}}"#))
        await wordsOnly.pick()
        XCTAssertEqual(wordsOnly.state.error, "Not answered: this answer needs a note on the yard")
        XCTAssertNil(wordsOnly.state.elsewhere, "a words-only answer has no option command")

        // The refusal is visible, and a corrected answer can still be sent.
        wordsOnly.words("Tomorrow afternoon, please")
        await wordsOnly.pick()
        XCTAssertEqual(calls("AnswerAsk").count, 2)
        XCTAssertEqual(calls("AnswerAsk")[1]["option"] as? Int, 0)
        XCTAssertEqual(calls("AnswerAsk")[1]["words"] as? String, "Tomorrow afternoon, please")
        XCTAssertNil(calls("AnswerAsk")[1]["weighed"])
    }

    func testLaterAndDeclineMoveTheCardToDecidedWhenTheirEventComes() async {
        let list = decisions()
        let first = await waitFor("the open asks", state: { list.state }) { $0.open.count == 3 }
        XCTAssertEqual(first.open.map(\.bead), ["yd-links", "yd-map", "yd-tidy"])
        XCTAssertEqual(first.open[1].title, "Who wrote in")
        XCTAssertEqual(first.open[1].meta, "yardmaster · 2 h")
        XCTAssertEqual(first.open[1].weighty.count, 1)
        XCTAssertEqual(first.decided.map(\.what), ["declined"])

        // Later: the call goes, and the card stays open until the event.
        let links = await opened("yd-links", 3)
        await links.later()
        XCTAssertEqual(calls("DeferAsk").count, 1)
        XCTAssertTrue(list.state.open.contains { $0.bead == "yd-links" }, "not moved before its event")
        await noted(152, "yd-links", Self.asks(open: [Self.map, Self.tidy], decided: [Self.linksAside, Self.greetDeclined]))
        let aside = await waitFor("yd-links put aside", state: { list.state }) { s in !s.open.contains { $0.bead == "yd-links" } }
        XCTAssertEqual(aside.decided.first { $0.bead == "yd-links" }?.what, "put aside until 12:00")
        links.leave()

        // Decline: the field for why first, then the call; the card
        // moves when the event comes.
        let map = await opened("yd-map", 7)
        await map.decline()
        XCTAssertTrue(map.state.declining)
        await map.decline()
        XCTAssertTrue(calls("DeclineAsk").isEmpty, "no words, no decline")
        map.declineWords("ask me on Monday")
        await map.decline()
        XCTAssertEqual(calls("DeclineAsk").count, 1)
        XCTAssertEqual(calls("DeclineAsk")[0]["words"] as? String, "ask me on Monday")
        XCTAssertTrue(list.state.open.contains { $0.bead == "yd-map" }, "not moved before its event")
        // The yard asks for a secret meanwhile.
        await noted(153, "yd-map", Self.asks(open: [Self.links, Self.tidy, Self.token], decided: [Self.mapDeclined, Self.greetDeclined]))
        let declined = await waitFor("yd-map declined", state: { list.state }) { s in !s.open.contains { $0.bead == "yd-map" } }
        XCTAssertEqual(declined.decided.first { $0.bead == "yd-map" }?.what, "declined")
        XCTAssertEqual(map.state.done, "declined")
        map.leave()

        // A secret card is declined at the first press, with no words and
        // no field for why: the yard refuses words on a secret ask, since
        // they may be the secret. It moves when the event comes, as the
        // others do.
        XCTAssertTrue(declined.open.contains { $0.bead == "yd-token" })
        let token = await opened("yd-token", 18)
        await token.decline()
        XCTAssertFalse(token.state.declining, "no field for why")
        let declines = calls("DeclineAsk")
        XCTAssertEqual(declines.count, 2)
        XCTAssertEqual(declines.last?["bead"] as? String, "yd-token")
        XCTAssertEqual(declines.last?["ask"] as? Int, 18)
        XCTAssertEqual(declines.last?["words"] as? String, "")
        XCTAssertNil(token.state.error)
        XCTAssertTrue(list.state.open.contains { $0.bead == "yd-token" }, "not moved before its event")
        await noted(154, "yd-token", Self.asks(open: [Self.links, Self.tidy], decided: [Self.tokenDeclined, Self.mapDeclined, Self.greetDeclined]))
        let tokenDeclined = await waitFor("yd-token declined", state: { list.state }) { s in !s.open.contains { $0.bead == "yd-token" } }
        XCTAssertEqual(tokenDeclined.decided.first { $0.bead == "yd-token" }?.what, "declined")
        XCTAssertEqual(token.state.done, "declined")
    }

    func testTheContextIsOnTheCardFromTheReadAndEveryAskHasItsOwn() async {
        // Nothing is tapped to show it: the first state that reads the
        // card has the context, as desktop's card draws it always.
        let card = await opened("yd-links", 3)
        let first = card.state
        XCTAssertEqual(first.context, ["The links file declares the new source; 64 links still point at the old one."])

        // The next ask has its own, as the first had, and so has this
        // one when it is opened again after it.
        card.open(yard: "laptop", bead: "yd-map", ask: 7)
        let next = await waitFor("the next ask", state: { card.state }) { $0.read && $0.ask == 7 }
        XCTAssertEqual(next.context, ["a delivery arrived from U024BE7LH in C1, who maps to nobody."])
        card.open(yard: "laptop", bead: "yd-links", ask: 3)
        let again = await waitFor("the first ask again", state: { card.state }) { $0.read && $0.ask == 3 }
        XCTAssertEqual(again.context, first.context)
    }

    func testADetailsRowExpandsToTheBeadsDescriptionAndNotesAndPickStillWorks() async throws {
        // The card's own bead carries a picture the yard holds and a text
        // file; the bead the ask is about carries a different picture
        // which the yard holds only after a retry.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        let shot = sha256Hex(png)
        let otherPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 4, 5, 6])
        let otherHash = sha256Hex(otherPNG)
        fake.setBlob(yardName: "laptop", hash: shot, bytes: png)
        let canned = try XCTUnwrap(Canned.replies["Bead"])
        let ownFiles = #"[{"hash": "\#(shot)", "type": "image/png", "bytes": 11, "name": "links.png"}, {"hash": "\#(String(repeating: "ab", count: 32))", "type": "text/plain", "bytes": 4, "name": "notes.txt"}]"#
        let own = canned.replacingOccurrences(
            of: #""at": "2026-10-08T09:30:00Z"}], "asks""#,
            with: #""at": "2026-10-08T09:30:00Z", "files": \#(ownFiles)}], "asks""#
        )
        XCTAssertNotEqual(own, canned)
        fake.nextFor(yard: "laptop", path: "/user/call/Bead", FakeResponse.json(200, own))
        let card = await opened("yd-links", 3)
        // The card's own bead is the first row and the bead the ask is
        // about the second, both shut.
        let shut = card.state.details
        XCTAssertEqual(shut.map(\.id), ["yd-links", "yd-train"])
        XCTAssertEqual(shut.map(\.title), ["Move the links", "Release train"])
        XCTAssertEqual(shut.map(\.stage), ["new", "new"])
        XCTAssertEqual(shut.map(\.expanded), [false, false])
        XCTAssertEqual(shut[1].notes, [], "nothing of the bead the ask is about is read before its row is tapped")

        // The own row holds its description and notes from the read that
        // drew the card, so it opens and shuts with no call of its own.
        XCTAssertEqual(shut[0].body, "The links file declares the new source.")
        XCTAssertEqual(shut[0].notes.map(\.author), ["yardmaster"])
        XCTAssertEqual(shut[0].notes.map(\.text), ["the test passed on a copy"])
        // Its note's picture is asked for as the card is read, and drawn
        // once it has come; the text file is a line with its name.
        let pictured = await waitFor("the own row's picture", state: { card.state.details[0].notes }) {
            $0.first?.images.first?.bytes != nil
        }
        XCTAssertEqual(pictured[0].images, [ShownImage(hash: shot, name: "links.png", bytes: png)])
        XCTAssertEqual(pictured[0].files, ["notes.txt"])
        XCTAssertFalse(shut[0].loading)
        XCTAssertNil(shut[0].error)
        let reads = calls("Bead").count
        await card.toggleDetails("yd-links")
        XCTAssertEqual(card.state.details.map(\.expanded), [true, false])
        await card.toggleDetails("yd-links")
        XCTAssertEqual(card.state.details.map(\.expanded), [false, false])
        XCTAssertEqual(calls("Bead").count, reads, "opening and shutting its row calls nothing")

        let body = "The release train leaves nightly. See https://example.com/train for the timetable."
        // The yard serves the notes out of order: the row stands them
        // newest last, as the bead card does.
        let notes = #"[{"seq": 2, "kind": "note", "author": "reviewer", "text": "Checked the timetable at https://example.com/timetable.", "at": "2026-10-08T10:00:00Z", "files": [{"hash": "\#(otherHash)", "type": "image/png", "bytes": 11, "name": "timetable.png"}]}, {"seq": 1, "kind": "note", "author": "builder", "text": "Started on the train.", "at": "2026-10-08T09:30:00Z"}]"#
        fake.nextFor(yard: "laptop", path: "/user/call/Bead", FakeResponse.json(200, #"{"result": {"id": "yd-train", "title": "Release train", "body": "\#(body)", "stage": "new", "labels": [], "notes": \#(notes), "asks": []}}"#))
        await card.toggleDetails("yd-train")
        let open = card.state.details
        XCTAssertTrue(open[1].expanded)
        XCTAssertFalse(open[1].loading)
        XCTAssertNil(open[1].error)
        XCTAssertEqual(open[1].body, body)
        XCTAssertEqual(open[1].notes.map(\.author), ["builder", "reviewer"])
        XCTAssertEqual(open[1].notes.map(\.text), ["Started on the train.", "Checked the timetable at https://example.com/timetable."])
        XCTAssertEqual(calls("Bead").filter { $0["bead"] as? String == "yd-train" }.count, 1)
        // The picture misses on its first read. Closing and reopening the
        // cached row asks again without reading the bead again.
        let missed = await waitFor("the second row's missing picture", state: { card.state.details[1].notes }) {
            $0.last?.images.first?.missed == true
        }
        XCTAssertEqual(missed[1].images, [ShownImage(hash: otherHash, name: "timetable.png", missed: true)])
        await card.toggleDetails("yd-train")
        fake.setBlob(yardName: "laptop", hash: otherHash, bytes: otherPNG)
        await card.toggleDetails("yd-train")
        let drawn = await waitFor("the second row's picture", state: { card.state.details[1].notes }) {
            $0.last?.images.first?.bytes != nil
        }
        XCTAssertEqual(drawn[1].images, [ShownImage(hash: otherHash, name: "timetable.png", bytes: otherPNG)])
        XCTAssertEqual(drawn[0], CardNote(author: "builder", at: "09:30", text: "Started on the train."))
        XCTAssertEqual(fake.allRequests.filter { $0.path == "/user/blobs/\(shot)" }.count, 1)
        XCTAssertEqual(fake.allRequests.filter { $0.path == "/user/blobs/\(otherHash)" }.count, 2)
        // The web address in the description is a link, as the
        // context's are, and so is the one in a note.
        XCTAssertEqual(linked(body).runs.compactMap { $0.link }, [try XCTUnwrap(URL(string: "https://example.com/train"))])
        XCTAssertEqual(linked(open[1].notes[1].text).runs.compactMap { $0.link }, [try XCTUnwrap(URL(string: "https://example.com/timetable"))])

        // A second tap shuts it; opening it again reads nothing more,
        // and the notes come back with the description.
        await card.toggleDetails("yd-train")
        XCTAssertFalse(card.state.details[1].expanded)
        await card.toggleDetails("yd-train")
        XCTAssertTrue(card.state.details[1].expanded)
        XCTAssertEqual(card.state.details[1].body, body)
        XCTAssertEqual(card.state.details[1].notes.map(\.author), ["builder", "reviewer"])
        XCTAssertEqual(calls("Bead").filter { $0["bead"] as? String == "yd-train" }.count, 1, "the description and notes are read once")

        // Pick still works with the row open: the ask carries no
        // weight, so no unlock stands in the way.
        card.choose(1)
        await card.pick()
        XCTAssertEqual(calls("AnswerAsk").count, 1)
        XCTAssertEqual(calls("AnswerAsk")[0]["option"] as? Int, 1)
        XCTAssertEqual(nav.decidePath, [])
    }

    func testADetailsRowWhoseReadFailsShowsItsErrorAndLeavesTheCardUsable() async {
        let card = await opened("yd-links", 3)
        fake.nextFor(yard: "laptop", path: "/user/call/Bead", FakeResponse.json(200, #"{"error": {"code": "error", "message": "the yard is tired"}}"#))
        await card.toggleDetails("yd-train")
        let failed = card.state.details
        XCTAssertTrue(failed[1].expanded)
        XCTAssertFalse(failed[1].loading)
        XCTAssertNil(failed[1].body)
        XCTAssertEqual(failed[1].notes, [])
        XCTAssertEqual(failed[1].error, "the yard is tired")
        XCTAssertNil(card.state.error, "the card itself shows no error")
        // The card's own row is made of the card's read, which did not
        // fail: the other row's failure leaves it whole.
        XCTAssertEqual(failed[0].id, "yd-links")
        XCTAssertNil(failed[0].error)
        XCTAssertEqual(failed[0].body, "The links file declares the new source.")

        // The card still picks with the failed row open.
        card.choose(3)
        await card.pick()
        XCTAssertEqual(calls("AnswerAsk").count, 1)
        XCTAssertEqual(nav.decidePath, [])
    }

    func testAnOldDetailsReadCannotClearTheReopenedCardsLoadingRead() async {
        let followed = FakeFollowed()
        followed.beads["yd-links"] = Bead(id: "yd-links", asks: [
            BeadAsk(
                ask: 3, question: "Move the links?",
                options: [AskOption(label: "Move")],
                about: [AboutBead(id: "yd-train", title: "Release train", stage: "new")]
            ),
        ])
        followed.beads["yd-train"] = Bead(
            id: "yd-train", body: "The train leaves nightly.",
            notes: [BeadNote(seq: 1, kind: "note", author: "builder", text: "Started.", at: "2026-10-08T09:30:00Z")]
        )
        let heldMailroom = Mailroom()
        heldMailroom.setFollowers(["laptop": followed])
        let now = fixedNow
        let heldModel = DecisionModel(
            mailroom: heldMailroom, records: records, nav: Nav(place: .decide), conversation: conversation, unlock: unlock,
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        heldModel.open(yard: "laptop", bead: "yd-links", ask: 3)
        _ = await waitFor("the held card", state: { heldModel.state }) { $0.read }

        followed.holdBeadReads("yd-train", count: 2)
        let oldRead = Task { @MainActor in await heldModel.toggleDetails("yd-train") }
        _ = await waitFor("the first bead read", state: { followed.pendingBeadReadCount("yd-train") }) { $0 == 1 }

        heldModel.leave()
        XCTAssertFalse(heldModel.state.details[1].expanded)
        XCTAssertFalse(heldModel.state.details[1].loading)
        heldModel.open(yard: "laptop", bead: "yd-links", ask: 3)

        let currentRead = Task { @MainActor in await heldModel.toggleDetails("yd-train") }
        _ = await waitFor("the reopened card's bead read", state: { followed.pendingBeadReadCount("yd-train") }) { $0 == 2 }
        XCTAssertTrue(heldModel.state.details[1].loading)

        followed.releaseBeadRead("yd-train")
        await oldRead.value
        XCTAssertTrue(heldModel.state.details[1].loading, "the stale read cannot clear the current read")
        XCTAssertNil(heldModel.state.details[1].body, "the stale read keeps nothing")
        XCTAssertEqual(heldModel.state.details[1].notes, [])

        followed.releaseBeadRead("yd-train")
        await currentRead.value
        XCTAssertFalse(heldModel.state.details[1].loading)
        XCTAssertEqual(heldModel.state.details[1].body, "The train leaves nightly.")
        XCTAssertEqual(heldModel.state.details[1].notes.map(\.author), ["builder"])
    }

    func testEveryCardHasItsOwnBeadsRowShutWhateverItsKind() async {
        // None of these asks names a bead it is about, as most do not,
        // and each is a card whose options a row open by default would
        // push down: a weighty pick, a run, a setup, a login's code and
        // an answer in words. The row is there on each, shut, and opens
        // to the bead the card is on; the next card starts shut again.
        let cards: [(bead: String, ask: Int64, title: String)] = [
            ("yd-map", 7, "Who wrote in"),
            ("yd-tidy", 9, "Tidy the sidings"),
            ("yd-courier", 44, "Set up courier"),
            ("yd-login", 34, "Claude Code sign-in"),
            ("yd-words", 12, "A words answer"),
        ]
        let card = decision()
        for (bead, ask, title) in cards {
            card.open(yard: "laptop", bead: bead, ask: ask)
            let state = await waitFor("the card \(bead)", state: { card.state }) { $0.read && $0.ask == ask }
            XCTAssertEqual(state.details.map(\.id), [bead])
            XCTAssertEqual(state.details.map(\.title), [title])
            XCTAssertEqual(state.details.map(\.stage), ["new"])
            XCTAssertEqual(state.details.map(\.expanded), [false], "\(bead) starts shut")
            await card.toggleDetails(bead)
            XCTAssertEqual(card.state.details.map(\.expanded), [true], "\(bead) opens")
        }
        for (bead, _, _) in cards {
            XCTAssertEqual(calls("Bead").filter { $0["bead"] as? String == bead }.count, 1, "\(bead): the card's read, none for its row")
        }
    }

    func testAnAskAboutItsOwnBeadGetsOneRowThatFollowsTheCardsReads() async {
        let started = BeadNote(seq: 1, kind: "note", author: "builder", text: "Started.", at: "2026-10-08T09:30:00Z")
        let ask = BeadAsk(
            ask: 3, question: "Move the links?", options: [AskOption(label: "Move")],
            about: [
                AboutBead(id: "yd-links", title: "Move the links", stage: "new"),
                AboutBead(id: "yd-train", title: "Release train", stage: "new"),
            ]
        )
        let followed = FakeFollowed()
        followed.beads["yd-links"] = Bead(id: "yd-links", title: "Move the links", body: "Move them.", stage: "new", notes: [started], asks: [ask])
        followed.up(loaded())
        let readMailroom = Mailroom()
        readMailroom.setFollowers(["laptop": followed])
        let now = fixedNow
        let card = DecisionModel(
            mailroom: readMailroom, records: records, nav: Nav(place: .decide), conversation: conversation, unlock: unlock,
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        defer { card.leave() }
        card.open(yard: "laptop", bead: "yd-links", ask: 3)
        _ = await waitFor("the card", state: { card.state }) { $0.read }

        // The ask names the card's own bead and another: the own row once
        // and first, from the read, and the other after it.
        XCTAssertEqual(card.state.details.map(\.id), ["yd-links", "yd-train"])
        XCTAssertEqual(card.state.details[0].notes.map(\.text), ["Started."])
        await card.toggleDetails("yd-links")
        XCTAssertEqual(card.state.details.map(\.expanded), [true, false])

        // The bead moves on and the yard says so: the card reads again,
        // and the open row shows the stage and notes of that read.
        followed.beads["yd-links"] = Bead(
            id: "yd-links", title: "Move the links", body: "Move them.", stage: "review",
            notes: [started, BeadNote(seq: 2, kind: "note", author: "reviewer", text: "Looks right.", at: "2026-10-08T10:00:00Z")],
            asks: [ask]
        )
        followed.event(Event(seq: 152, kind: "stage", bead: "yd-links"))
        let fresh = await waitFor("the card read again", state: { card.state }) { $0.details.first?.notes.count == 2 }
        XCTAssertEqual(fresh.details.map(\.id), ["yd-links", "yd-train"])
        XCTAssertEqual(fresh.details[0].stage, "review")
        XCTAssertEqual(fresh.details[0].notes.map(\.text), ["Started.", "Looks right."])
        XCTAssertEqual(fresh.details.map(\.expanded), [true, false], "an open row stays open across the read")
        XCTAssertEqual(followed.beadAsked, ["yd-links", "yd-links"], "two reads of the card, none for its row or the other bead")
    }

    func testAskingAboutTheCardOpensTheCoordinatorsConversationWithTheBeadFirst() async {
        let followed = FakeFollowed()
        followed.beads["yd-links"] = Bead(id: "yd-links", asks: [
            BeadAsk(ask: 3, question: "Move the links?", options: [AskOption(label: "Move")]),
        ])
        followed.up(loaded())
        let askMailroom = Mailroom()
        askMailroom.setFollowers(["laptop": followed])
        let askNav = Nav(place: .decide)
        let now = fixedNow
        let zone: @Sendable () -> TimeZone = { TimeZone(secondsFromGMT: 0)! }
        let asked = ConversationModel(mailroom: askMailroom, now: { now }, zone: zone)
        let card = DecisionModel(
            mailroom: askMailroom, records: records, nav: askNav, conversation: asked, unlock: unlock,
            now: { now }, zone: zone
        )
        defer {
            card.leave()
            asked.leave()
        }

        // No card open: the Ask has nowhere to go.
        card.askCoordinator()
        XCTAssertEqual(askNav.crewPath, [])
        XCTAssertEqual(askNav.place, .decide)

        askNav.openDecision(yard: "laptop", bead: "yd-links", ask: 3)
        card.open(yard: "laptop", bead: "yd-links", ask: 3)
        _ = await waitFor("the card", state: { card.state }) { $0.read }
        // An answer without the field opens the yardmaster, and the
        // button says that name.
        XCTAssertEqual(card.coordinatorName(for: "laptop"), "yardmaster")
        card.askCoordinator()
        // The crew place shows the yard's conversation with the
        // yardmaster; the decision stays pushed for the way back, still
        // open, and nothing was sent.
        XCTAssertEqual(askNav.place, .crew)
        XCTAssertEqual(askNav.crewPath, [ConversationRoute(yard: "laptop", with: "yardmaster")])
        XCTAssertEqual(askNav.decidePath, [DecisionRoute(yard: "laptop", bead: "yd-links", ask: 3)])
        XCTAssertNil(card.state.done)
        XCTAssertTrue(followed.answers.isEmpty && followed.defers.isEmpty && followed.declines.isEmpty && followed.sent.isEmpty)
        // The screen's open starts the draft, the bead's id its first
        // words.
        asked.open(yard: "laptop", with: "yardmaster")
        XCTAssertEqual(asked.state.title, "yardmaster")
        XCTAssertEqual(asked.state.draft, "yd-links ")

        // A yard whose coordinator has another name: the Ask opens that
        // crew member's conversation, and the button says that name.
        asked.leave()
        followed.up(loaded(coordinator: "mayor"))
        XCTAssertEqual(card.coordinatorName(for: "laptop"), "mayor")
        askNav.crewPath = []
        card.askCoordinator()
        XCTAssertEqual(askNav.place, .crew)
        XCTAssertEqual(askNav.crewPath, [ConversationRoute(yard: "laptop", with: "mayor")])
        asked.open(yard: "laptop", with: "mayor")
        XCTAssertEqual(asked.state.title, "mayor")
        XCTAssertEqual(asked.state.draft, "yd-links ")
    }

    private func loaded(coordinator: String = "yardmaster") -> Loaded {
        Loaded(
            me: Me(user: "jo", saidBy: "pixel", yard: "laptop", yardmaster: coordinator),
            head: 151,
            settings: Settings(),
            user: User(name: "jo"),
            crew: [],
            users: [],
            inbox: Inbox(),
            notifications: Notifications(),
            asks: Asks()
        )
    }

    private static func asks(open: [String], decided: [String]) -> String {
        #"{"result": {"open": [\#(open.joined(separator: ","))], "decided": [\#(decided.joined(separator: ","))]}}"#
    }

    private static let map = #"{"bead": "yd-map", "bead_title": "Who wrote in", "ask": 7, "question": "Who is U024BE7LH on slack?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "identity": {"source": "slack", "sender": "U024BE7LH"}, "weight": [{"class": "as-user", "line": "writes who a sender is"}]}"#
    private static let tidy = #"{"bead": "yd-tidy", "bead_title": "Tidy the sidings", "ask": 9, "question": "Remove the merged worktrees now?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "run": {"command": "yardr depot tidy --merged"}}"#
    private static let links = #"{"bead": "yd-links", "bead_title": "Move the links", "ask": 3, "question": "Move this yard's links to the declared source now?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z"}"#
    private static let login = #"{"bead": "yd-login", "bead_title": "Claude Code sign-in", "ask": 34, "question": "Paste what Claude Code's sign-in page gave you", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "secret": {"source": "", "env": ["INPUT"], "login": "claude-ab12", "line": "a secret: INPUT, for the waiting login claude-ab12"}, "weight": [{"class": "credential", "line": "INPUT, for the waiting login claude-ab12"}]}"#
    private static let token = #"{"bead": "yd-token", "bead_title": "The callback token", "ask": 18, "question": "What is the callback token?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "secret": {"source": "crm", "env": ["CRM_UPDATE_TOKEN"], "line": "the token the yard calls back with"}, "weight": [{"class": "credential", "line": "gives a credential or an address to the yard"}]}"#
    private static let linksAside = #"{"bead": "yd-links", "bead_title": "Move the links", "ask": 3, "question": "Move this yard's links to the declared source now?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "state": "put aside", "return_at": "2026-10-08T12:00:00Z"}"#
    private static let mapDeclined = #"{"bead": "yd-map", "bead_title": "Who wrote in", "ask": 7, "question": "Who is U024BE7LH on slack?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "state": "declined", "words": "ask me on Monday", "identity": {"source": "slack", "sender": "U024BE7LH"}, "weight": [{"class": "as-user", "line": "writes who a sender is"}]}"#
    private static let tokenDeclined = #"{"bead": "yd-token", "bead_title": "The callback token", "ask": 18, "question": "What is the callback token?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "state": "declined", "secret": {"source": "crm", "env": ["CRM_UPDATE_TOKEN"], "line": "the token the yard calls back with"}, "weight": [{"class": "credential", "line": "gives a credential or an address to the yard"}]}"#
    private static let greetDeclined = #"{"bead": "yd-greet", "bead_title": "The greeting", "ask": 5, "question": "What should the tone of the greeting be?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "state": "declined", "words": "the greeting can wait"}"#
}

/// The unlock the tests drive: the gate they set, and the prompt
/// answering as they queued, with its reasons recorded.
final class FakeUnlock: UnlockPrompt, @unchecked Sendable {
    var gateValue: UnlockGate = .prompt
    var promptResults: [Bool] = []
    var reasons: [String] = []
    var holdNextPrompt = false
    private let heldPrompt = HeldPrompt()

    func gate() -> UnlockGate { gateValue }

    func prompt(reason: String) async -> Bool {
        reasons.append(reason)
        if holdNextPrompt {
            holdNextPrompt = false
            return await heldPrompt.wait()
        }
        return promptResults.isEmpty ? true : promptResults.removeFirst()
    }

    func waitForPrompt() async {
        await heldPrompt.waitUntilStarted()
    }

    func resumePrompt(_ passed: Bool) async {
        await heldPrompt.resume(passed)
    }
}

private actor HeldPrompt {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var answer: CheckedContinuation<Bool, Never>?

    func wait() async -> Bool {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
        return await withCheckedContinuation { answer = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func resume(_ passed: Bool) {
        answer?.resume(returning: passed)
        answer = nil
    }
}
