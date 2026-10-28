@testable import Footplate
import XCTest

private actor FetchGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var started = false

    func begin() {
        started = true
        waiting?.resume()
        waiting = nil
    }

    func wait() async {
        guard !started else { return }
        await withCheckedContinuation { waiting = $0 }
    }
}

// Filling a wake in (design 8787 section 4) over stand-in yards:
// the fetch is a closure, the checkpoints and landings the memory
// stores, and the outcome the whole of what the extension decides.
// The telling is the one `Notifier` would show of the same boards,
// read here through `arrived`, `wanted` and `Burst` themselves.
final class WakeTests: XCTestCase {
    private func board(letters: [Letter] = [], open: [OpenAsk] = []) -> Board {
        var board = Board(me: "jo", head: 10)
        board.cursor = 10
        board.letters = Dictionary(uniqueKeysWithValues: letters.map { ($0.seq, $0) })
        board.open = open
        return board
    }

    private func letter(_ seq: Int64, from: String = "yardmaster", text: String = "The shed is painted.") -> Letter {
        Letter(seq: seq, from: from, to: "jo", text: text)
    }

    private func engine(
        yards: [WakeYard] = [WakeYard(name: "laptop", title: "laptop")],
        boards: [String: Board],
        checkpoints: MemoryCheckpointStore,
        targets: MemoryWakeTargetStore = MemoryWakeTargetStore(),
        canSuppress: Bool = false
    ) -> WakeEngine {
        WakeEngine(
            yards: yards,
            fetch: { name in
                guard let board = boards[name] else { throw ApiError.down(why: "no yard of that name") }
                return board
            },
            checkpoints: checkpoints,
            targets: targets,
            canSuppress: canSuppress
        )
    }

    /// Saves the pre-event checkpoint of `before` for `yard`, as the
    /// foreground's last read of it left it.
    private func save(_ store: MemoryCheckpointStore, yard: String = "laptop", _ before: Board) {
        store.transaction { $0.save(yard: yard, YardCheckpoint(before)) }
    }

    func testASavedCheckpointLetsAWakeShowTheTellingTheNotifierWouldShow() async {
        let checkpoints = MemoryCheckpointStore()
        let targets = MemoryWakeTargetStore()
        save(checkpoints, board())
        let after = board(letters: [letter(11)])
        let outcome = await engine(boards: ["laptop": after], checkpoints: checkpoints, targets: targets)
            .handle(wakeId: "w-1", kind: .mail, shown: .elsewhere)
        // The same telling the rules make of the same two boards.
        var burst = Burst()
        for item in arrived(yard: "laptop", before: board(), after: after) where wanted(item, shown: .elsewhere) {
            burst.add(item)
        }
        XCTAssertEqual(.show(burst.take(named: false)!), outcome)
        guard case .show(let telling) = outcome else { return }
        XCTAssertEqual("yardmaster", telling.title)
        XCTAssertEqual("The shed is painted.", telling.body)
        // The target stands beside the wake id, for its tap.
        XCTAssertEqual(.target(yard: "laptop", .conversation(with: "yardmaster")), targets.landing(wakeId: "w-1"))
        // And the checkpoint moved: the same wake again finds nothing.
        let again = await engine(boards: ["laptop": after], checkpoints: checkpoints)
            .handle(wakeId: "w-2", kind: .mail, shown: .elsewhere)
        XCTAssertEqual(.generic(kind: .mail), again)
    }

    func testAYardWithNoCheckpointIsBaselinedAndTellsOfNothing() async {
        let checkpoints = MemoryCheckpointStore()
        let outcome = await engine(boards: ["laptop": board(letters: [letter(11)])], checkpoints: checkpoints)
            .handle(wakeId: "w-1", kind: .mail, shown: .elsewhere)
        XCTAssertEqual(.generic(kind: .mail), outcome, "the whole inbox is not news")
        let saved = checkpoints.transaction { $0.checkpoint(yard: "laptop") }
        XCTAssertEqual(YardCheckpoint(board(letters: [letter(11)])), saved)
    }

    func testTwoYardsSameKindArrivalsBecomeOneTellingLedByTheFirstAndOtherKindsStayPending() async {
        let checkpoints = MemoryCheckpointStore()
        save(checkpoints, yard: "laptop", board())
        save(checkpoints, yard: "", board())
        let yards = [WakeYard(name: "laptop", title: "laptop"), WakeYard(name: "", title: "south")]
        let boards: [String: Board] = [
            "laptop": board(letters: [letter(11, text: "First.")]),
            "": board(letters: [letter(11, from: "signalman", text: "Second.")]),
        ]
        let outcome = await engine(yards: yards, boards: boards, checkpoints: checkpoints)
            .handle(wakeId: "w-1", kind: .mail, shown: .elsewhere)
        guard case .show(let telling) = outcome else {
            return XCTFail("expected a telling, got \(outcome)")
        }
        XCTAssertEqual("2 new in 2 yards", telling.title)
        XCTAssertEqual("laptop: 1 from yardmaster; south: 1 from signalman", telling.body)
        XCTAssertEqual("laptop", telling.yard, "led by the first arrival")
        XCTAssertEqual(.conversation(with: "yardmaster"), telling.target)

        // A board read for one wake can hold news of both kinds. The
        // mail wake must leave the decision state behind for its own
        // wake instead of advancing it unseen.
        let mixed = MemoryCheckpointStore()
        save(mixed, board())
        let ask = OpenAsk(bead: "footplate-1", ask: 2, question: "Move this yard's links?", asker: "yardmaster")
        let after = board(letters: [letter(11)], open: [ask])
        let targets = MemoryWakeTargetStore()

        let mailWake = await engine(boards: ["laptop": after], checkpoints: mixed, targets: targets)
            .handle(wakeId: "w-mail", kind: .mail, shown: .elsewhere)
        guard case .show(let mail) = mailWake else {
            return XCTFail("expected the mail telling, got \(mailWake)")
        }
        XCTAssertEqual(.conversation(with: "yardmaster"), mail.target)
        XCTAssertEqual([AskMark](), mixed.transaction { $0.checkpoint(yard: "laptop")?.open })

        let decisionWake = await engine(boards: ["laptop": after], checkpoints: mixed, targets: targets)
            .handle(wakeId: "w-decision", kind: .decision, shown: .elsewhere)
        guard case .show(let decision) = decisionWake else {
            return XCTFail("expected the decision telling, got \(decisionWake)")
        }
        XCTAssertEqual(.decision(bead: "footplate-1", ask: 2), decision.target)
    }

    func testMailOnTheOpenConversationIsHeldBack() async {
        let checkpoints = MemoryCheckpointStore()
        save(checkpoints, board())
        let after = board(letters: [letter(11), letter(12, from: "signalman", text: "Other.")])
        let outcome = await engine(boards: ["laptop": after], checkpoints: checkpoints)
            .handle(wakeId: "w-1", kind: .mail, shown: .conversation(yard: "laptop", with: "yardmaster"))
        guard case .show(let telling) = outcome else {
            return XCTFail("expected a telling, got \(outcome)")
        }
        XCTAssertEqual("signalman", telling.title)
        XCTAssertEqual("Other.", telling.body)
    }

    func testNothingNewLeavesTheGenericLineWithoutSuppressionAndEndsItWith() async {
        for canSuppress in [false, true] {
            let checkpoints = MemoryCheckpointStore()
            let targets = MemoryWakeTargetStore()
            save(checkpoints, board(letters: [letter(11)]))
            let outcome = await engine(
                boards: ["laptop": board(letters: [letter(11)])],
                checkpoints: checkpoints, targets: targets, canSuppress: canSuppress
            ).handle(wakeId: "w-1", kind: .mail, shown: .elsewhere)
            XCTAssertEqual(canSuppress ? .suppress : .generic(kind: .mail), outcome, "canSuppress=\(canSuppress)")
            XCTAssertEqual(.yardList, targets.landing(wakeId: "w-1"))
        }
    }

    func testARefusedFetchLeavesTheGenericLineWithoutSuppressionAndEndsItWith() async {
        for canSuppress in [false, true] {
            let checkpoints = MemoryCheckpointStore()
            let targets = MemoryWakeTargetStore()
            save(checkpoints, board())
            let engine = WakeEngine(
                yards: [WakeYard(name: "laptop", title: "laptop")],
                fetch: { _ in throw ApiError.notSignedIn },
                checkpoints: checkpoints, targets: targets, canSuppress: canSuppress
            )
            let outcome = await engine.handle(wakeId: "w-1", kind: .decision, shown: .elsewhere)
            XCTAssertEqual(canSuppress ? .suppress : .generic(kind: .decision), outcome, "canSuppress=\(canSuppress)")
            // Its tap asks for the sign-in again, never the yard's rows.
            XCTAssertEqual(.signInAgain, targets.landing(wakeId: "w-1"))
        }
    }

    func testATransientFailureLeavesTheGenericLineEitherWay() async {
        for canSuppress in [false, true] {
            let checkpoints = MemoryCheckpointStore()
            save(checkpoints, board())
            let engine = WakeEngine(
                yards: [WakeYard(name: "laptop", title: "laptop")],
                fetch: { _ in throw ApiError.down(why: "nothing answers") },
                checkpoints: checkpoints, targets: MemoryWakeTargetStore(), canSuppress: canSuppress
            )
            let outcome = await engine.handle(wakeId: "w-1", kind: .mail, shown: .elsewhere)
            XCTAssertEqual(.generic(kind: .mail), outcome, "canSuppress=\(canSuppress)")
        }
    }

    func testRacingWakesShowOnceAndCancellationKeepsTheCheckpoint() async {
        let raceCheckpoints = MemoryCheckpointStore()
        save(raceCheckpoints, board())
        let racedBoard = board(letters: [letter(11)])
        let racingEngine = engine(boards: ["laptop": racedBoard], checkpoints: raceCheckpoints)
        let outcomes = await withTaskGroup(of: WakeOutcome.self) { group in
            group.addTask { await racingEngine.handle(wakeId: "w-1", kind: .mail, shown: .elsewhere) }
            group.addTask { await racingEngine.handle(wakeId: "w-2", kind: .mail, shown: .elsewhere) }
            var all: [WakeOutcome] = []
            for await outcome in group { all.append(outcome) }
            return all
        }
        XCTAssertEqual(1, outcomes.count { if case .show = $0 { true } else { false } }, "\(outcomes)")

        let completionGate = WakeCompletionGate()
        XCTAssertTrue(completionGate.claim())
        XCTAssertFalse(completionGate.claim())

        let checkpoints = MemoryCheckpointStore()
        let before = board()
        let after = board(letters: [letter(11)])
        save(checkpoints, before)
        let gate = FetchGate()
        let engine = WakeEngine(
            yards: [WakeYard(name: "laptop", title: "laptop")],
            fetch: { _ in
                await gate.begin()
                try await Task.sleep(for: .seconds(600))
                return after
            },
            checkpoints: checkpoints,
            targets: MemoryWakeTargetStore(),
            canSuppress: false
        )

        let work = Task { await engine.handle(wakeId: "w-1", kind: .mail, shown: .elsewhere) }
        await gate.wait()
        work.cancel()

        let outcome = await work.value
        XCTAssertEqual(.generic(kind: .mail), outcome)
        XCTAssertEqual(YardCheckpoint(before), checkpoints.transaction { $0.checkpoint(yard: "laptop") })
    }

    func testTheExtensionFetchOverAStandInYardShowsTheNewLetter() async throws {
        // The extension's own path, with the app process gone: only
        // the saved checkpoint stands, and the board is read whole
        // from the stand-in yard through its paired credentials.
        let fake = FakeYard()
        let edge = try fake.edge()
        let client = try edge.yard(device: fake.token(yardName: "laptop"), session: fake.session(), name: "laptop")
        let checkpoints = MemoryCheckpointStore()
        let engine = WakeEngine(
            yards: [WakeYard(name: "laptop", title: "laptop")],
            fetch: { _ in Board.of(try await client.load()) },
            checkpoints: checkpoints,
            targets: MemoryWakeTargetStore(),
            canSuppress: false
        )
        // The canned board is the baseline: read, and nothing told.
        let first = await engine.handle(wakeId: "w-1", kind: .mail, shown: .elsewhere)
        XCTAssertEqual(.generic(kind: .mail), first)
        // The yard's board moves: one more letter, from signalman.
        let moved = FakeResponse.json(200, #"{"result": {"mail": [{"seq": 13, "at": "2026-10-08T09:30:00Z", "from": "yardmaster", "to": "jo", "text": "The shed is painted. Shall I land it?", "read": false}, {"seq": 51, "at": "2026-10-08T09:30:00Z", "from": "josephine@north", "to": "jo", "text": "I am at the other machine until four.", "read": false}, {"seq": 52, "at": "2026-10-08T09:31:00Z", "from": "signalman", "to": "jo", "text": "The siding is clear.", "read": false}], "unread": 3, "last": 52, "from": ["yardmaster", "josephine@north", "signalman"]}}"#)
        fake.nextFor(yard: "laptop", path: "/user/call/UserInbox", moved, moved)
        let second = await engine.handle(wakeId: "w-2", kind: .mail, shown: .elsewhere)
        guard case .show(let telling) = second else {
            return XCTFail("expected a telling, got \(second)")
        }
        XCTAssertEqual("signalman", telling.title)
        XCTAssertEqual("The siding is clear.", telling.body)
        XCTAssertEqual(.conversation(with: "signalman"), telling.target)
    }

    func testTheCheckpointHoldsNoLetterWordsAndNoToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wake-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileCheckpointStore(directory: dir)
        store.transaction { $0.save(yard: "laptop", YardCheckpoint(board(letters: [letter(11)]))) }
        let targets = FileWakeTargetStore(directory: dir)
        targets.save(wakeId: "w-1", .target(yard: "laptop", .decision(bead: "footplate-1", ask: 2)))
        // Separate instances stand in for concurrent extension
        // processes sharing the app-group file. Each read-modify-write
        // must keep the landings the other wakes already saved.
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            FileWakeTargetStore(directory: dir).save(
                wakeId: "w-concurrent-\(index)",
                .target(yard: "laptop", .decision(bead: "bead-\(index)", ask: Int64(index)))
            )
        }
        for index in 0..<32 {
            XCTAssertEqual(
                .target(yard: "laptop", .decision(bead: "bead-\(index)", ask: Int64(index))),
                targets.landing(wakeId: "w-concurrent-\(index)")
            )
        }
        let checkpointsText = try String(contentsOf: dir.appendingPathComponent("checkpoints.json"), encoding: .utf8)
        let targetsText = try String(contentsOf: dir.appendingPathComponent("wake-targets.json"), encoding: .utf8)
        for text in [checkpointsText, targetsText] {
            XCTAssertFalse(text.contains("The shed is painted"), text)
            XCTAssertFalse(text.contains("yardr-dev-"), text)
            XCTAssertFalse(text.contains("ory_st_"), text)
        }
        // The tap state does hold the row it leads to, on the phone alone.
        XCTAssertTrue(targetsText.contains("footplate-1"), targetsText)
        XCTAssertEqual(.target(yard: "laptop", .decision(bead: "footplate-1", ask: 2)), targets.landing(wakeId: "w-1"))
    }
}
