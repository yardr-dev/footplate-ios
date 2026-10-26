import XCTest

// Run by hand, outside .yardr/test; attachments record the simulator's appearance.
// Pair the simulator's app with a yard whose lines contain beads that a stat
// separates, open Lines, then run this test: the filter removes bead ids from
// the cards, and the transit count clears the filter. The gate never runs it.
final class LineScreenTests: XCTestCase {
    @MainActor
    func testStatsChipsFilterTheCards() {
        let app = XCUIApplication()
        app.launch()
        let lines = app.tabBars.buttons["Lines"]
        XCTAssertTrue(lines.waitForExistence(timeout: 10), "pair the simulator with a yard first")
        lines.tap()
        let transit = app.buttons["filter-all"]
        XCTAssertTrue(transit.waitForExistence(timeout: 30))
        let allBeads = cardBeadIDs(app)
        let quiet = app.descendants(matching: .any)["quiet-head"].exists
        let unfiltered = XCTAttachment(screenshot: app.screenshot())
        unfiltered.name = "Lines overview"
        unfiltered.lifetime = .keepAlways
        add(unfiltered)

        // Find a nonempty filter that actually removes at least one card bead.
        // The test yard needs one line with both matching and other beads.
        let stats = ["filter-moving", "filter-your-turn", "filter-held", "filter-late"]
            .map { app.buttons[$0] }
        var selected: XCUIElement?
        var filteredBeads = Set<String>()
        for candidate in stats where candidate.exists && candidate.isEnabled {
            candidate.tap()
            let filtered = cardBeadIDs(app)
            if filtered.isSubset(of: allBeads), filtered.count < allBeads.count {
                selected = candidate
                filteredBeads = filtered
                break
            }
            transit.tap()
        }
        guard let stat = selected else {
            XCTFail("no stat removed a card bead; pair a yard with matching and nonmatching beads on a line")
            return
        }
        XCTAssertTrue(stat.isSelected)
        XCTAssertTrue(filteredBeads.isSubset(of: allBeads))
        XCTAssertLessThan(filteredBeads.count, allBeads.count)
        XCTAssertFalse(app.descendants(matching: .any)["quiet-head"].exists)
        let filtered = XCTAttachment(screenshot: app.screenshot())
        filtered.name = "Lines filtered"
        filtered.lifetime = .keepAlways
        add(filtered)

        // The transit count clears the filter: the cards and the quiet
        // chips stand as they did.
        transit.tap()
        XCTAssertTrue(transit.isSelected)
        XCTAssertFalse(stat.isSelected)
        XCTAssertEqual(cardBeadIDs(app), allBeads)
        XCTAssertEqual(app.descendants(matching: .any)["quiet-head"].exists, quiet)
        let cleared = XCTAttachment(screenshot: app.screenshot())
        cleared.name = "Lines cleared"
        cleared.lifetime = .keepAlways
        add(cleared)
    }

    /// The beads named on line cards, each line's one text value.
    private func cardBeadIDs(_ app: XCUIApplication) -> Set<String> {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'line-beads/'"))
        return Set(rows.allElementsBoundByIndex.flatMap { $0.label.split(whereSeparator: \.isWhitespace).map(String.init) })
    }
}
