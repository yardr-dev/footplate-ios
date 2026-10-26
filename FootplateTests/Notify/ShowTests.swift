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
