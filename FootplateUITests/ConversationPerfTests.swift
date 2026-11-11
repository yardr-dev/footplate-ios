import XCTest

// Run by hand, outside .yardr/test, like every FootplateUITests suite.
//
// How a long conversation feels on the screen (footplate-ios-g0jx): the
// demo yard's thread with the yardmaster holds a few hundred letters, so
// opening it, flinging through it and a letter arriving while the reader
// is away from the foot can be measured as the person meets them, not
// summed from the model's parts. The measures below print their averages
// in the test log (`measured [Clock, seconds] average: …`); they carry no
// bound, because a simulator's numbers move with the Mac it runs on and
// are not a phone's. The steady bound on the cost these measures found
// lives in FootplateTests' `testReadingALongConversationStateStaysCheap`.
// Run on the booted simulator the gate uses:
//   xcodebuild test -project Footplate.xcodeproj -scheme Footplate \
//     -destination 'platform=iOS Simulator,id=7EC91353-EDF5-4E93-B644-46A44BA6CFCB' \
//     -only-testing:FootplateUITests/ConversationPerfTests
final class ConversationPerfTests: XCTestCase {

    /// Opening the long conversation: from the crew row's tap until the
    /// foot of the thread stands in the window, as the screen draws it.
    @MainActor
    func testOpeningTheLongConversation() {
        continueAfterFailure = false
        let app = openDemo(app: XCUIApplication())
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            row(app, "yardmaster").tap()
            // The field stands under the letters from the first draw;
            // waiting for it lets the page land before the foot is read.
            XCTAssertTrue(app.descendants(matching: .any)["conversation-field"].waitForExistence(timeout: 10))
            let landed = waitFor { self.footShown(app) }
            if !landed {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.lifetime = .keepAlways
                add(shot)
            }
            XCTAssertTrue(landed, "the conversation opens at its foot")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(row(app, "yardmaster").waitForExistence(timeout: 10))
        }
    }

    /// A fling through the long conversation: drags from the foot up
    /// through the older pages, as the scroll signposts and the clock
    /// see them. The older-page path is exercised, not just the first
    /// page: drags continue past the top of the first page, and the
    /// foot must be found again below every page the fling loaded
    /// (the older page's arrival itself is asserted in
    /// `testScrollingLoadsAnOlderPage`). The letters stand in an
    /// eager stack over the pages loaded (a lazy stack's placement
    /// cost more than it saved on these rows; see the bead's notes),
    /// and the rounds of this measure print their clock per round in
    /// the test log as the pages accumulate.
    /// Traversal of all 290 older letters by drags alone would take
    /// hundreds of drags; the model's `older()` loop to all 300
    /// letters is driven steadily in FootplateTests instead.
    @MainActor
    func testFlingThroughTheLongConversation() {
        continueAfterFailure = false
        let app = openDemo(app: XCUIApplication())
        openConversation(app)
        XCTAssertTrue(footShown(app), "the conversation opens at its foot")
        let options = XCTMeasureOptions()
        options.iterationCount = 2
        measure(metrics: [XCTClockMetric(), XCTOSSignpostMetric.scrollDecelerationMetric], options: options) {
            // Back at the foot before each fling, then up past the
            // first page so each round loads an older page too. The
            // drags inside the measure are blind: a foot query per
            // drag costs seconds of harness time and measures the
            // harness, not the scroll.
            for _ in 0..<14 { dragToFoot(app) }
            for _ in 0..<12 { dragToOlder(app) }
        }
        XCTAssertTrue(waitFor { !self.footShown(app) }, "the fling leaves the foot behind")
        // Back over every page the fling loaded, to the foot again.
        for _ in 0..<20 { dragToFoot(app) }
        XCTAssertTrue(waitFor { self.footShown(app) }, "the foot is found again below the older pages")
    }

    /// Scrolling to the top of the first page reads the page before
    /// it: past where the first page ended, more drags still bring
    /// new letters into the window, and the foot is found again below
    /// the loaded pages. At the top of the first page alone the extra
    /// drags would only bounce on the same letters.
    @MainActor
    func testScrollingLoadsAnOlderPage() {
        continueAfterFailure = false
        let app = openDemo(app: XCUIApplication())
        openConversation(app)
        XCTAssertTrue(footShown(app), "the conversation opens at its foot")
        // Every loaded letter stands in the tree, so the tree grows
        // by a page when an older page loads: that growth, not the
        // reader's place alone, is the older-page path's sign.
        let firstPage = app.staticTexts.count
        for _ in 0..<16 { dragToOlder(app) }
        XCTAssertTrue(waitFor { !self.footShown(app) }, "the reader is above the first page")
        XCTAssertTrue(waitFor { app.staticTexts.count > firstPage }, "an older page loads above the first page")
        for _ in 0..<30 { dragToFoot(app) }
        XCTAssertTrue(waitFor { self.footShown(app) }, "the foot is found again below the older pages")
    }

    /// A letter arriving while the reader is away from the foot: the
    /// reader is scrolled up the thread, a letter is sent, and the time
    /// until it stands at the foot is the arrival's cost on the screen.
    /// One's own letter is followed to the foot, as it must be.
    @MainActor
    func testArrivalWhileReadingAwayFromTheFoot() {
        continueAfterFailure = false
        let app = openDemo(app: XCUIApplication())
        openConversation(app)
        for _ in 0..<5 { dragToOlder(app) }
        XCTAssertTrue(waitFor { !self.footShown(app) }, "the reader is away from the foot")
        let field = app.descendants(matching: .any)["conversation-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        // Timed by hand, three times: the send's own typing is not the
        // arrival, so the clock starts at Send and stops when the letter
        // stands at the foot. The times print in the test log.
        for sent in 1...3 {
            let words = "Arrival probe \(sent) on the long thread"
            field.tap()
            field.typeText(words)
            let start = ContinuousClock.now
            app.buttons["Send"].tap()
            let arrived = app.staticTexts.matching(NSPredicate(format: "label == %@", words)).firstMatch
            XCTAssertTrue(arrived.waitForExistence(timeout: 10))
            XCTAssertTrue(arrived.isHittable, "one's own letter is followed to the foot")
            print("arrival \(sent): \(start.duration(to: .now))")
            // Away from the foot again for the next arrival.
            for _ in 0..<5 { dragToOlder(app) }
            XCTAssertTrue(waitFor { !self.footShown(app) }, "the reader is away from the foot")
        }
    }

    /// One drag toward the older letters: from the foot, a drag down
    /// the screen. (A swipe on the app or on the first scroll view
    /// lands on a code block's own sideways scroll and never moves
    /// the conversation.)
    @MainActor
    private func dragToOlder(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// One drag back toward the foot.
    @MainActor
    private func dragToFoot(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Whether the foot letter stands in the window: it is in the
    /// tree only near where the reader is, and an element laid out
    /// outside the window has no hittable point to ask for.
    @MainActor
    private func footShown(_ app: XCUIApplication) -> Bool {
        let letter = foot(app)
        guard letter.exists else { return false }
        return letter.frame.intersects(app.frame)
    }

    /// Whether `condition` holds within a few seconds.
    @MainActor
    private func waitFor(_ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return condition()
    }

    /// The demo yard open on its crew, from a fresh launch.
    @MainActor
    private func openDemo(app: XCUIApplication) -> XCUIApplication {
        // A launch that finds the last test's demo still open in the
        // app's memory starts there, not at the first screen.
        app.terminate()
        app.launch()
        let demo = app.buttons["Try a demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10), "run on a simulator with no yard paired")
        demo.tap()
        XCTAssertTrue(row(app, "yardmaster").waitForExistence(timeout: 10))
        return app
    }

    /// The yardmaster's conversation open at its foot.
    @MainActor
    private func openConversation(_ app: XCUIApplication) {
        row(app, "yardmaster").tap()
        XCTAssertTrue(app.descendants(matching: .any)["conversation-field"].waitForExistence(timeout: 20))
        XCTAssertTrue(waitFor { self.footShown(app) }, "the conversation opens at its foot")
    }

    /// Every element carrying the foot letter's words: the crew row's
    /// preview behind the conversation, and the conversation's own
    /// letter while it stands in the tree.
    @MainActor
    private func footWords(_ app: XCUIApplication) -> XCUIElementQuery {
        // The letter's words carry yd-7h9q as a chip, so they stand as
        // more than one element; the words after the chip serve.
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'is with a builder now'"))
    }

    /// The newest letter of the demo thread, at the conversation's foot.
    @MainActor
    private func foot(_ app: XCUIApplication) -> XCUIElement {
        // The crew row's preview carries the same words and stays in
        // the tree behind the conversation, so the last match serves:
        // the conversation's own letter stands after it in the tree.
        let words = footWords(app)
        return words.element(boundBy: words.count - 1)
    }

    /// The crew row whose words begin with `name`.
    @MainActor
    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }
}
