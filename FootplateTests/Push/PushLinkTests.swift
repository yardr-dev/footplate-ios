@testable import Footplate
import XCTest

// The wake as the relay writes it and the phone reads it (design
// 8787 sections 4 and 6): a kind, a random id and a count, with the
// link carrying the id alone. No yard, sender or row stands in
// either, and a link that is none of ours names no wake.
final class PushLinkTests: XCTestCase {
    /// The payload as the relay sends it (its `wakeData` and the
    /// APNs alert beside it), for one mail wake of two arrivals.
    private let relayUserInfo: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "", "body": "A letter"], "mutable-content": 1, "thread-id": "mail"],
        "id": "w-abc123",
        "kind": "mail",
        "count": 2,
        "url": "yardr-footplate://open/wake/w-abc123",
    ]

    func testAWakeReadsAsItsKindIdAndCount() {
        XCTAssertEqual(WakePayload(id: "w-abc123", kind: .mail, count: 2), wakePayloadOf(relayUserInfo))
        var decision = relayUserInfo
        decision["kind"] = "decision"
        decision["count"] = "3"
        XCTAssertEqual(WakePayload(id: "w-abc123", kind: .decision, count: 3), wakePayloadOf(decision))
        XCTAssertNil(wakePayloadOf(["id": "w-1"]), "no kind")
        XCTAssertNil(wakePayloadOf(["kind": "mail"]), "no id")
        XCTAssertNil(wakePayloadOf(["id": "w-1", "kind": "notice"]), "no kind of ours")
        XCTAssertNil(wakePayloadOf(userInfoOf(Telling(title: "yardmaster", body: "Hi.", yard: "laptop", target: .conversation(with: "yardmaster")))), "a telling's tap is no wake")
    }

    func testTheLinkNamesTheWakeAndNothingElse() {
        XCTAssertEqual("w-abc123", wakeIdOf(URL(string: "yardr-footplate://open/wake/w-abc123")!))
        XCTAssertEqual("yardr-footplate://open/wake/w-abc123", wakeLink("w-abc123"))
        // Nothing of a yard or a row can ride it: those shapes name
        // no wake, and their taps open the yard list.
        for link in [
            "yardr-footplate://open/laptop/decision",
            "yardr-footplate://open/wake/",
            "yardr-footplate://open/wake",
            "yardr-footplate://wake/w-abc123",
            "https://my.yardr.dev/open/wake/w-abc123",
            "yardr-footplate://open/wake/w-abc123/extra",
        ] {
            XCTAssertNil(wakeIdOf(URL(string: link)!), link)
        }
    }

    func testTheGenericLinesAreTheRelaysWords() {
        XCTAssertEqual("A letter", genericLine(.mail))
        XCTAssertEqual("A decision waits", genericLine(.decision))
    }

    func testAWakeLandingFallsBackToTheYardList() {
        let target = WakeLanding.target(yard: "laptop", .conversation(with: "yardmaster"))
        XCTAssertEqual(target, resolveWake(target, yards: ["laptop"]))
        // A yard paired no more opens the yard list, not its row.
        XCTAssertEqual(.yardList, resolveWake(target, yards: [""]))
        XCTAssertEqual(.yardList, resolveWake(nil, yards: ["laptop"]))
        XCTAssertEqual(.signInAgain, resolveWake(.signInAgain, yards: []))
    }
}
