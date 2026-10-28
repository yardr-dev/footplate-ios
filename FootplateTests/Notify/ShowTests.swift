@testable import Footplate
import UserNotifications
import XCTest

// How a telling is shown (design 3.5): the request's two lines, its
// thread per yard and row, and the tap that opens the app on that
// yard and there. The banner itself, and the tap on a device, are
// checked by hand.
@MainActor
final class ShowTests: XCTestCase {
    func testARequestCarriesTheTwoLinesThreadAndTap() {
        let telling = Telling(
            title: "yardmaster", body: "The shed is painted.",
            yard: "laptop", target: .conversation(with: "yardmaster")
        )
        let request = notificationRequest(telling)
        XCTAssertEqual("yardmaster", request.content.title)
        XCTAssertEqual("The shed is painted.", request.content.body)
        XCTAssertEqual("mail/laptop/yardmaster", request.content.threadIdentifier)
        XCTAssertEqual(UNNotificationSound.default, request.content.sound)
        XCTAssertNil(request.trigger, "told now")
        let tap = targetOf(request.content.userInfo)
        XCTAssertEqual("laptop", tap?.0)
        XCTAssertEqual(.conversation(with: "yardmaster"), tap?.1)
    }

    func testADecisionThreadsPerYardAndCard() {
        let telling = Telling(
            title: "A decision from yardmaster", body: "Shall I land it?",
            yard: "", target: .decision(bead: "footplate-1", ask: 2)
        )
        let request = notificationRequest(telling)
        XCTAssertEqual("decision//footplate-1/2", request.content.threadIdentifier)
        let tap = targetOf(request.content.userInfo)
        XCTAssertEqual("", tap?.0)
        XCTAssertEqual(.decision(bead: "footplate-1", ask: 2), tap?.1)
    }

    func testTheDelegateAnswersTheSystemsCalls() {
        // The names the system calls: a near-miss compiles but is
        // never called, and neither the banner nor the tap happens.
        let delegate = NotifyDelegate(onTap: { _, _ in })
        XCTAssertTrue(delegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))))
        XCTAssertTrue(delegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))))
    }

    func testATapCarryingNoneOfOursLeadsNowhere() {
        XCTAssertNil(targetOf([:]))
        XCTAssertNil(targetOf(["yard": "laptop"]), "no row")
        XCTAssertNil(targetOf(["yard": 1, "with": "yardmaster"]), "no yard")
        XCTAssertNil(targetOf(["yard": "laptop", "bead": "footplate-1"]), "no ask")
        XCTAssertNil(targetOf(["yard": "laptop", "bead": "footplate-1", "ask": -1]), "no ask")
    }

    private func records() -> Records {
        let records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: "https://my.yardr.dev")
        records.keepSession(account: "jo@example.com", session: "session")
        records.keepYard(PairedYard(name: "laptop", yard: "laptop", user: "jo", device: "pixel", token: "yardr-dev-laptop-1"))
        records.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1"))
        records.select("")
        return records
    }

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

    /// A wake engine over stand-in boards, with the checkpoints and
    /// landings the tap reads. A yard with no board answers nothing
    /// answers: where the tap must not refetch, that fetch would
    /// overwrite the saved landing the test asserts on.
    private func engine(
        yards: [WakeYard] = [WakeYard(name: "laptop", title: "laptop"), WakeYard(name: "", title: "south")],
        boards: [String: Board] = [:],
        checkpoints: MemoryCheckpointStore = MemoryCheckpointStore(),
        targets: MemoryWakeTargetStore
    ) -> WakeEngine {
        WakeEngine(
            yards: yards,
            fetch: { name in
                guard let board = boards[name] else { throw ApiError.down(why: "no yard of that name") }
                return board
            },
            checkpoints: checkpoints,
            targets: targets,
            canSuppress: false
        )
    }

    /// Saves the pre-event checkpoint of `before` for `yard`, as the
    /// foreground's last read of it left it.
    private func save(_ store: MemoryCheckpointStore, yard: String = "laptop", _ before: Board) {
        store.transaction { $0.save(yard: yard, YardCheckpoint(before)) }
    }

    func testATapOpensTheConversationOnItsYard() {
        let records = records()
        let nav = Nav()
        nav.place = .lines
        applyNotifyTap(yard: "laptop", target: .conversation(with: "yardmaster"), records: records, nav: nav)
        XCTAssertEqual("laptop", records.kept.selected)
        XCTAssertEqual(.crew, nav.place)
        XCTAssertEqual([ConversationRoute(yard: "laptop", with: "yardmaster")], nav.crewPath)
    }

    func testATapOpensTheDecisionOnItsYard() {
        let records = records()
        let nav = Nav()
        nav.place = .lines
        applyNotifyTap(yard: "", target: .decision(bead: "footplate-1", ask: 2), records: records, nav: nav)
        XCTAssertEqual("", records.kept.selected)
        XCTAssertEqual(.decide, nav.place)
        XCTAssertEqual([DecisionRoute(yard: "", bead: "footplate-1", ask: 2)], nav.decidePath)

        // A yard of its own, migrated from "" to its address's name,
        // opens under that name.
        let secret = MemoryShelf()
        let plain = MemoryShelf()
        Records(secret: secret, plain: plain, origin: "https://my.yardr.dev").keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1", origin: "https://yard.example.net"))
        let migrated = Records(secret: secret, plain: plain, origin: "https://my.yardr.dev")
        XCTAssertEqual(["yard.example.net"], migrated.kept.yards.map(\.name))
        let movedNav = Nav()
        applyNotifyTap(yard: "yard.example.net", target: .decision(bead: "footplate-1", ask: 2), records: migrated, nav: movedNav)
        XCTAssertEqual("yard.example.net", migrated.kept.selected)
        XCTAssertEqual(.decide, movedNav.place)
        XCTAssertEqual([DecisionRoute(yard: "yard.example.net", bead: "footplate-1", ask: 2)], movedNav.decidePath)
    }

    func testTheMigrationSelectsOnlyEmptyYardNotificationIDsForRemoval() {
        let staleMail = notificationRequest(Telling(title: "yardmaster", body: "The shed is painted.", yard: "", target: .conversation(with: "yardmaster")))
        let staleAsk = notificationRequest(Telling(title: "A decision waits", body: "Shall I land it?", yard: "", target: .decision(bead: "footplate-1", ask: 2)))
        // Another yard's notification stays, and so does a payload
        // carrying none of ours, even under "".
        let other = notificationRequest(Telling(title: "yardmaster", body: "The shed is painted.", yard: "laptop", target: .conversation(with: "yardmaster")))
        let foreignContent = UNMutableNotificationContent()
        foreignContent.userInfo = ["yard": ""]
        let foreign = UNNotificationRequest(identifier: "foreign", content: foreignContent, trigger: nil)

        XCTAssertEqual(
            [staleMail.identifier, staleAsk.identifier],
            staleMigratedNotificationIDs([staleMail, staleAsk, other, foreign])
        )
    }

    func testAWakeTapOpensItsSavedRow() async {
        let records = records()
        let nav = Nav()
        nav.place = .lines
        let targets = MemoryWakeTargetStore()
        targets.save(wakeId: "w-1", .target(yard: "laptop", .conversation(with: "yardmaster")))
        await applyWakeTap(wakeId: "w-1", kind: .mail, engine: engine(targets: targets), records: records, nav: nav)
        XCTAssertEqual("laptop", records.kept.selected)
        XCTAssertEqual(.crew, nav.place)
        XCTAssertEqual([ConversationRoute(yard: "laptop", with: "yardmaster")], nav.crewPath)
    }

    func testAWakeTapOnARemovedYardOpensTheYardList() async {
        let records = records()
        let nav = Nav()
        nav.place = .lines
        nav.crewPath = [ConversationRoute(yard: "laptop", with: "yardmaster")]
        let targets = MemoryWakeTargetStore()
        targets.save(wakeId: "w-1", .target(yard: "north", .conversation(with: "yardmaster")))
        await applyWakeTap(wakeId: "w-1", kind: .mail, engine: engine(targets: targets), records: records, nav: nav)
        // The yard list: no selection moved, no row pushed.
        XCTAssertEqual("", records.kept.selected)
        XCTAssertEqual(.crew, nav.place)
        XCTAssertTrue(nav.yardListShown)
        XCTAssertTrue(nav.crewPath.isEmpty)
        XCTAssertTrue(nav.decidePath.isEmpty)
        // And one with nothing saved at all: the boards are fetched
        // again, and with nothing still-new the yard list opens.
        let checkpoints = MemoryCheckpointStore()
        save(checkpoints, yard: "laptop", board(letters: [letter(11)]))
        save(checkpoints, yard: "", board(letters: [letter(11)]))
        let refetch = engine(
            boards: ["laptop": board(letters: [letter(11)]), "": board(letters: [letter(11)])],
            checkpoints: checkpoints, targets: targets
        )
        nav.yardListShown = false
        await applyWakeTap(wakeId: "w-unknown", kind: .mail, engine: refetch, records: records, nav: nav)
        XCTAssertEqual(.crew, nav.place)
        XCTAssertTrue(nav.yardListShown)
        XCTAssertEqual(.yardList, targets.landing(wakeId: "w-unknown"))
        nav.yardListShown = false
        nav.place = .lines
        await applyWakeLink(URL(string: "yardr-footplate://open/wake/")!, engine: engine(targets: targets), records: records, nav: nav)
        XCTAssertEqual(.crew, nav.place)
        XCTAssertTrue(nav.yardListShown)

        nav.yardListShown = false
        nav.place = .lines
        await applyWakeLink(URL(string: "https://example.org/open/wake/w-1")!, engine: engine(targets: targets), records: records, nav: nav)
        XCTAssertEqual(.lines, nav.place)
        XCTAssertFalse(nav.yardListShown)
    }

    func testAWakeTapWhereTheDoorClosedAsksForTheSignInAgain() async {
        let records = records()
        let nav = Nav()
        let targets = MemoryWakeTargetStore()
        targets.save(wakeId: "w-1", .signInAgain)
        await applyWakeTap(wakeId: "w-1", kind: .decision, engine: engine(targets: targets), records: records, nav: nav)
        XCTAssertEqual(SignInRequest(again: true), nav.signIn)
    }

    func testAWakeTapWithNoSavedLandingOpensTheFirstStillNewConversation() async {
        let records = records()
        let nav = Nav()
        nav.place = .lines
        let targets = MemoryWakeTargetStore()
        let checkpoints = MemoryCheckpointStore()
        save(checkpoints, yard: "laptop", board())
        save(checkpoints, yard: "", board())
        let refetch = engine(
            boards: [
                "laptop": board(letters: [letter(11, text: "First.")]),
                "": board(letters: [letter(11, from: "signalman", text: "Second.")]),
            ],
            checkpoints: checkpoints, targets: targets
        )
        await applyWakeTap(wakeId: "w-tap", kind: .mail, engine: refetch, records: records, nav: nav)
        // Led by the first arrival across yards.
        XCTAssertEqual("laptop", records.kept.selected)
        XCTAssertEqual(.crew, nav.place)
        XCTAssertEqual([ConversationRoute(yard: "laptop", with: "yardmaster")], nav.crewPath)
        XCTAssertEqual(.target(yard: "laptop", .conversation(with: "yardmaster")), targets.landing(wakeId: "w-tap"))
    }

    func testAWakeTapWithNoSavedLandingAndADoorClosedAsksForTheSignInAgain() async {
        let records = records()
        let nav = Nav()
        nav.place = .lines
        let targets = MemoryWakeTargetStore()
        let refused = WakeEngine(
            yards: [WakeYard(name: "laptop", title: "laptop"), WakeYard(name: "", title: "south")],
            fetch: { _ in throw ApiError.notSignedIn },
            checkpoints: MemoryCheckpointStore(), targets: targets, canSuppress: false
        )
        await applyWakeTap(wakeId: "w-tap", kind: .mail, engine: refused, records: records, nav: nav)
        XCTAssertEqual(SignInRequest(again: true), nav.signIn)
        XCTAssertEqual(.signInAgain, targets.landing(wakeId: "w-tap"))
    }

    func testAWakeLinkWithNoSavedLandingOpensTheFirstStillNewItem() async {
        let records = records()
        let nav = Nav()
        nav.place = .lines
        let targets = MemoryWakeTargetStore()
        let checkpoints = MemoryCheckpointStore()
        save(checkpoints, yard: "laptop", board())
        save(checkpoints, yard: "", board())
        let ask = OpenAsk(bead: "footplate-1", ask: 2, question: "Move this yard's links?", asker: "yardmaster")
        let refetch = engine(
            boards: ["laptop": board(letters: [letter(11)], open: [ask]), "": board()],
            checkpoints: checkpoints, targets: targets
        )
        // A link names no kind: mail first.
        await applyWakeLink(URL(string: "yardr-footplate://open/wake/w-link")!, engine: refetch, records: records, nav: nav)
        XCTAssertEqual("laptop", records.kept.selected)
        XCTAssertEqual(.crew, nav.place)
        XCTAssertEqual([ConversationRoute(yard: "laptop", with: "yardmaster")], nav.crewPath)
        XCTAssertEqual(.target(yard: "laptop", .conversation(with: "yardmaster")), targets.landing(wakeId: "w-link"))

        // And where mail holds nothing, the decision.
        let held = MemoryCheckpointStore()
        save(held, yard: "laptop", board())
        save(held, yard: "", board())
        let asks = engine(
            boards: ["laptop": board(open: [ask]), "": board()],
            checkpoints: held, targets: targets
        )
        nav.place = .lines
        nav.crewPath = []
        await applyWakeLink(URL(string: "yardr-footplate://open/wake/w-ask")!, engine: asks, records: records, nav: nav)
        XCTAssertEqual("laptop", records.kept.selected)
        XCTAssertEqual(.decide, nav.place)
        XCTAssertEqual([DecisionRoute(yard: "laptop", bead: "footplate-1", ask: 2)], nav.decidePath)
        XCTAssertEqual(.target(yard: "laptop", .decision(bead: "footplate-1", ask: 2)), targets.landing(wakeId: "w-ask"))
    }

    func testATapOnAYardPairedNoMoreLeavesTheAppWhereItOpens() {
        let records = records()
        let nav = Nav()
        nav.place = .lines
        applyNotifyTap(yard: "north", target: .conversation(with: "yardmaster"), records: records, nav: nav)
        XCTAssertEqual("", records.kept.selected)
        XCTAssertEqual(.lines, nav.place)
        XCTAssertTrue(nav.crewPath.isEmpty)
        XCTAssertTrue(nav.decidePath.isEmpty)
    }
}
