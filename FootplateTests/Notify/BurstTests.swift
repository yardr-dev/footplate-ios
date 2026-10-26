@testable import Footplate
import XCTest

// That a burst is one notification (design 3.5, footplate's Burst):
// what arrives within 3 seconds is told of together, led to the
// first arrival's row.
final class BurstTests: XCTestCase {
    private func mail(yard: String = "laptop", from: String = "yardmaster", text: String = "The shed is painted.") -> News {
        News(yard: yard, from: from, text: text, target: .conversation(with: from))
    }

    private func decision(
        yard: String = "laptop",
        asker: String = "yardmaster",
        bead: String = "footplate-1",
        ask: Int64 = 2
    ) -> News {
        News(yard: yard, from: asker, text: "Shall I land it?", target: .decision(bead: bead, ask: ask))
    }

    private let titles = ["laptop": "laptop", "": "south"]

    func testNothingWaitsNothingIsTold() {
        var burst = Burst()
        XCTAssertNil(burst.take(named: false))
    }

    func testOneLetterIsToldAloneAndLeadsToItsConversation() {
        var burst = Burst()
        XCTAssertTrue(burst.add(mail()), "the first")
        XCTAssertEqual(
            Telling(title: "yardmaster", body: "The shed is painted.", yard: "laptop", target: .conversation(with: "yardmaster")),
            burst.take(named: false)
        )
        XCTAssertNil(burst.take(named: false), "told once")
    }

    func testOneDecisionIsToldAloneAndLeadsToItsCard() {
        var burst = Burst()
        burst.add(decision())
        XCTAssertEqual(
            Telling(
                title: "A decision from yardmaster", body: "Shall I land it?",
                yard: "laptop", target: .decision(bead: "footplate-1", ask: 2)
            ),
            burst.take(named: false)
        )
    }

    func testThreeLettersBecomeOneLedByTheYardWhereSeveralArePaired() {
        var burst = Burst()
        XCTAssertTrue(burst.add(mail(text: "First.")), "the first")
        XCTAssertFalse(burst.add(mail(text: "Second.")), "the second")
        XCTAssertFalse(burst.add(mail(text: "Third.")), "the third")
        let telling = burst.take(named: true, titles: titles)!
        // The newest says most of where the sender stands.
        XCTAssertEqual("laptop · 3 from yardmaster", telling.title)
        XCTAssertEqual("Third.", telling.body)
        XCTAssertEqual("laptop", telling.yard)
        XCTAssertEqual(.conversation(with: "yardmaster"), telling.target)
    }

    func testTheYardIsNamedByItsTitleNotItsName() {
        var burst = Burst()
        burst.add(mail(yard: ""))
        XCTAssertEqual("south · yardmaster", burst.take(named: true, titles: titles)!.title)
    }

    func testTwoDecisionsBecomeOne() {
        var burst = Burst()
        burst.add(decision(bead: "footplate-1", ask: 2))
        burst.add(decision(bead: "footplate-9", ask: 7))
        let telling = burst.take(named: false)!
        XCTAssertEqual("2 new in the yard", telling.title)
        XCTAssertEqual("2 decisions", telling.body)
    }

    func testABurstOfTwoYardsNamesEachAndLeadsToTheFirst() {
        var burst = Burst()
        burst.add(mail(yard: "laptop", from: "yardmaster"))
        burst.add(mail(yard: "", from: "signalman"))
        burst.add(mail(yard: "", from: "signalman"))
        let telling = burst.take(named: false, titles: titles)!
        XCTAssertEqual("3 new in 2 yards", telling.title)
        XCTAssertEqual("laptop: 1 from yardmaster; south: 2 from signalman", telling.body)
        XCTAssertEqual("laptop", telling.yard)
        XCTAssertEqual(.conversation(with: "yardmaster"), telling.target)
    }

    func testWhatWaitsOfAYardFollowedNoMoreIsDropped() {
        var burst = Burst()
        burst.add(mail(yard: "laptop"))
        burst.add(mail(yard: ""))
        burst.forget(yard: "laptop")
        let telling = burst.take(named: true, titles: titles)!
        XCTAssertEqual("south · yardmaster", telling.title)
        XCTAssertEqual("", telling.yard)
        burst.forget(yard: "")
        XCTAssertNil(burst.take(named: true, titles: titles), "nothing left")
    }
}
