@testable import Footplate
import XCTest

// The notify rules as plain functions (design 3.5): what arrived
// since the board was last read, what of it is told of with the
// screen shown, and the first line a notification says.
final class NotifyTests: XCTestCase {
    private func mail(yard: String = "laptop", from: String = "yardmaster") -> News {
        News(yard: yard, from: from, text: "The shed is painted.", target: .conversation(with: from))
    }

    private func decision(yard: String = "laptop", asker: String = "yardmaster") -> News {
        News(yard: yard, from: asker, text: "Shall I land it?", target: .decision(bead: "footplate-1", ask: 2))
    }

    func testMailOnTheOpenConversationIsNotToldAndAnyOtherMailIs() {
        let news = mail()
        // On the open conversation it is read where it stands.
        XCTAssertFalse(wanted(news, shown: .conversation(yard: "laptop", with: "yardmaster")), "the open conversation")
        // On another conversation, in a yard not selected, with the
        // decisions list in front, or anywhere else, it is told of.
        XCTAssertTrue(wanted(news, shown: .conversation(yard: "laptop", with: "signalman")), "another conversation")
        XCTAssertTrue(wanted(news, shown: .conversation(yard: "south", with: "yardmaster")), "a yard not shown")
        XCTAssertTrue(wanted(news, shown: .decisions(yard: "laptop")), "the decisions list")
        XCTAssertTrue(wanted(news, shown: .elsewhere), "elsewhere")
    }

    func testADecisionWithItsListsInFrontIsNotToldAndAnyOtherIs() {
        let news = decision()
        XCTAssertFalse(wanted(news, shown: .decisions(yard: "laptop")), "the list in front")
        XCTAssertFalse(wanted(news, shown: .decision(yard: "laptop", bead: "footplate-1", ask: 2)), "the decision on screen")
        XCTAssertTrue(wanted(news, shown: .decisions(yard: "south")), "another yard's list")
        XCTAssertTrue(wanted(news, shown: .decision(yard: "laptop", bead: "footplate-1", ask: 1)), "another decision")
        XCTAssertTrue(wanted(news, shown: .conversation(yard: "laptop", with: "yardmaster")), "a conversation")
        XCTAssertTrue(wanted(news, shown: .elsewhere), "elsewhere")
    }

    func testTheScreenShownIsTheOpenConversationTheDecisionsListOrElsewhere() {
        XCTAssertEqual(
            .conversation(yard: "laptop", with: "yardmaster"),
            shownOf(place: .crew, crewPath: [ConversationRoute(yard: "laptop", with: "yardmaster")], decidePath: [], selected: "laptop")
        )
        // A tap may have opened another yard's row: the route names
        // its own yard.
        XCTAssertEqual(
            .conversation(yard: "south", with: "yardmaster"),
            shownOf(place: .crew, crewPath: [ConversationRoute(yard: "south", with: "yardmaster")], decidePath: [], selected: "laptop")
        )
        XCTAssertEqual(
            .decisions(yard: "laptop"),
            shownOf(place: .decide, crewPath: [], decidePath: [], selected: "laptop")
        )
        XCTAssertEqual(
            .elsewhere,
            shownOf(place: .lines, crewPath: [], decidePath: [], selected: "laptop")
        )
        // The rows, not the list; no yard selected; one decision open.
        XCTAssertEqual(
            .elsewhere,
            shownOf(place: .crew, crewPath: [], decidePath: [], selected: "laptop")
        )
        XCTAssertEqual(
            .elsewhere,
            shownOf(place: .decide, crewPath: [], decidePath: [], selected: nil)
        )
        XCTAssertEqual(
            .decision(yard: "laptop", bead: "footplate-1", ask: 2),
            shownOf(place: .decide, crewPath: [], decidePath: [DecisionRoute(yard: "laptop", bead: "footplate-1", ask: 2)], selected: "laptop")
        )
    }

    private func before() -> Board {
        var board = Board(me: "jo", head: 10)
        board.cursor = 10
        board.letters = [10: Letter(seq: 10, from: "yardmaster", to: "jo", text: "First.", read: true)]
        board.open = [OpenAsk(bead: "footplate-1", ask: 1, question: "Old?", asker: "yardmaster")]
        board.decided = [
            DecidedAsk(bead: "footplate-2", ask: 3, question: "Answered?", asker: "yardmaster", state: "answered"),
            DecidedAsk(bead: "footplate-3", ask: 4, question: "Later?", asker: "yardmaster", state: "put aside"),
        ]
        return board
    }

    func testAYardReadForTheFirstTimeBringsNoNews() {
        XCTAssertTrue(arrived(yard: "laptop", before: nil, after: before()).isEmpty)
    }

    func testNewMailToThePersonIsNewsAndNothingElseOfTheLettersIs() {
        var after = before()
        after.letters[11] = Letter(seq: 11, from: "yardmaster", to: "jo", text: "Second.")
        after.letters[12] = Letter(seq: 12, from: "signalman", to: "jo", text: "Third.")
        // The person's own and a letter to someone else.
        after.letters[13] = Letter(seq: 13, from: "jo", to: "yardmaster", text: "Mine.")
        after.letters[15] = Letter(seq: 15, from: "yardmaster", to: "relief", text: "Not mine.")
        XCTAssertEqual(
            [
                News(yard: "laptop", from: "yardmaster", text: "Second.", target: .conversation(with: "yardmaster")),
                News(yard: "laptop", from: "signalman", text: "Third.", target: .conversation(with: "signalman")),
            ],
            arrived(yard: "laptop", before: before(), after: after)
        )

        // The stream may deliver a letter and the acknowledgement from
        // another client together. It arrived after the previous
        // cursor, so it is still news even though this board now marks
        // it read.
        var readAfterArrival = before()
        readAfterArrival.cursor = 11
        readAfterArrival.letters[11] = Letter(seq: 11, from: "yardmaster", to: "jo", text: "Second.", read: true)
        XCTAssertEqual(
            [News(yard: "laptop", from: "yardmaster", text: "Second.", target: .conversation(with: "yardmaster"))],
            arrived(yard: "laptop", before: before(), after: readAfterArrival)
        )
    }

    func testANewlyOpenAskIsNewsAndADealtWithOneOpenAgainIsNot() {
        var after = before()
        after.open += [
            OpenAsk(bead: "footplate-4", ask: 5, question: "New?", asker: "signalman"),
            // An answer the yard did not take: open again, no news.
            OpenAsk(bead: "footplate-2", ask: 3, question: "Answered?", asker: "yardmaster"),
            // Put aside, and come back: news again.
            OpenAsk(bead: "footplate-3", ask: 4, question: "Later?", asker: "yardmaster"),
        ]
        XCTAssertEqual(
            [
                News(yard: "laptop", from: "signalman", text: "New?", target: .decision(bead: "footplate-4", ask: 5)),
                News(yard: "laptop", from: "yardmaster", text: "Later?", target: .decision(bead: "footplate-3", ask: 4)),
            ],
            arrived(yard: "laptop", before: before(), after: after)
        )
    }

    func testANotificationSaysTheFirstLineThatSaysSomething() {
        XCTAssertEqual("Hello.", line("\n  \nHello.\nSecond."))
        XCTAssertEqual("with tabs", line("with\ttabs"))
        // No control character reaches the system.
        XCTAssertEqual("bell", line("be\u{07}ll"))
        XCTAssertEqual("twolines", line("two\u{2028}lines"))
        XCTAssertEqual("", line("  \n\t "))
    }

    func testALongFirstLineIsCutAt140WithAnEllipsis() {
        let cut = String(repeating: "w", count: lineLength)
        XCTAssertEqual(cut, line(cut))
        XCTAssertEqual(cut + "…", line(cut + "w"))
        // A mark never loses its letter: e with a combining acute is
        // one grapheme, two scalars.
        let marked = String(repeating: "e\u{301}", count: lineLength + 1)
        XCTAssertEqual(String(repeating: "e\u{301}", count: lineLength) + "…", line(marked))
        // No space before the ellipsis.
        XCTAssertEqual(String(repeating: "w", count: 139) + "…", line(String(repeating: "w", count: 139) + " more"))
    }
}
