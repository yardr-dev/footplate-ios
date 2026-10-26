@testable import Footplate
import XCTest

// The decisions list and one decision (design 3.5, 3.4) against the
// fake yard, over a real follower: a weighty pick sends `weighed` only
// after the unlock passed or the number was typed back, and nothing
// after a cancelled one; nobody and you decide go without the gate; a
// run ask is approved behind the unlock and a setup with its preset
// pick, a secret ask shows its command and sends nothing, and a
// refused answer shows the yard's sentence with the per-type command;
// Later and Decline move the card to Decided when the yard's `noted`
// event comes, and not before.
@MainActor
final class DecisionModelTests: XCTestCase {
    private var fake: FakeYard!
    private var clock: TestClock!
    private var yards: Yards!
    private var follower: Follower!
    private var records: Records!
    private var nav: Nav!
    private var mailroom: Mailroom!
    private var unlock: FakeUnlock!

    private let fixedNow = parseInstant("2026-10-08T11:30:00Z")!

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeYard()
        clock = TestClock()
        unlock = FakeUnlock()
        let session = fake.session()
        let token = fake.token(yardName: "laptop")
        records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: fake.origin)
        records.keepSession(account: fake.email, session: session)
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: token))
        nav = Nav(first: .decisions)
        yards = Yards(clock: clock, foreground: true)
        let client = try fake.edge().yard(device: token, session: session, name: "laptop")
        follower = yards.follow(client)
        let now = fixedNow
        mailroom = Mailroom(clock: clock, now: { now })
        mailroom.setFollowers(["laptop": follower])
        _ = try await follower.waitFor("laptop up") { $0.status == .up }
    }

    override func tearDown() async throws {
        follower?.close()
        yards?.close()
        fake?.closeStreams()
        try await super.tearDown()
    }

    private func decision() -> DecisionModel {
        let now = fixedNow
        return DecisionModel(
            mailroom: mailroom, records: records, nav: nav, unlock: unlock,
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
        nav.show(.decision(yard: "laptop", bead: bead, ask: ask))
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
        XCTAssertEqual(nav.screen, .decision(yard: "laptop", bead: "yd-map", ask: 7))

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
        XCTAssertEqual(nav.screen, .decisions)
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
    }

    func testNobodyAndYouDecideGoWithoutTheGate() async {
        let card = await opened("yd-map", 7)
        card.choose(3)
        await card.pick()
        card.leave()
        nav.show(.decision(yard: "laptop", bead: "yd-map", ask: 7))
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
        // A run ask is approved, not picked, and wants nothing chosen.
        await card.pick()
        XCTAssertTrue(calls("AnswerAsk").isEmpty)

        unlock.promptResults = [false]
        await card.approve()
        XCTAssertEqual(unlock.reasons, ["approve yardr depot tidy --merged in laptop"])
        XCTAssertTrue(calls("ApproveAsk").isEmpty, "a cancelled unlock sends nothing")
        XCTAssertEqual(nav.screen, .decision(yard: "laptop", bead: "yd-tidy", ask: 9))

        unlock.promptResults = [true]
        await card.approve()
        XCTAssertEqual(calls("ApproveAsk").count, 1)
        XCTAssertEqual(calls("ApproveAsk")[0]["weighed"] as? Bool, true)
        XCTAssertEqual(nav.screen, .decisions)

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
        await noted(153, "yd-map", Self.asks(open: [Self.links, Self.tidy], decided: [Self.mapDeclined, Self.greetDeclined]))
        let declined = await waitFor("yd-map declined", state: { list.state }) { s in !s.open.contains { $0.bead == "yd-map" } }
        XCTAssertEqual(declined.decided.first { $0.bead == "yd-map" }?.what, "declined")
        XCTAssertEqual(map.state.done, "declined")
    }

    private static func asks(open: [String], decided: [String]) -> String {
        #"{"result": {"open": [\#(open.joined(separator: ","))], "decided": [\#(decided.joined(separator: ","))]}}"#
    }

    private static let map = #"{"bead": "yd-map", "bead_title": "Who wrote in", "ask": 7, "question": "Who is U024BE7LH on slack?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "identity": {"source": "slack", "sender": "U024BE7LH"}, "weight": [{"class": "as-user", "line": "writes who a sender is"}]}"#
    private static let tidy = #"{"bead": "yd-tidy", "bead_title": "Tidy the sidings", "ask": 9, "question": "Remove the merged worktrees now?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "run": {"command": "yardr depot tidy --merged"}}"#
    private static let links = #"{"bead": "yd-links", "bead_title": "Move the links", "ask": 3, "question": "Move this yard's links to the declared source now?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z"}"#
    private static let linksAside = #"{"bead": "yd-links", "bead_title": "Move the links", "ask": 3, "question": "Move this yard's links to the declared source now?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "state": "put aside", "return_at": "2026-10-08T12:00:00Z"}"#
    private static let mapDeclined = #"{"bead": "yd-map", "bead_title": "Who wrote in", "ask": 7, "question": "Who is U024BE7LH on slack?", "asker": "yardmaster", "since": "2026-10-08T09:30:00Z", "state": "declined", "words": "ask me on Monday", "identity": {"source": "slack", "sender": "U024BE7LH"}, "weight": [{"class": "as-user", "line": "writes who a sender is"}]}"#
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
