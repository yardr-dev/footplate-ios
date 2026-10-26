import XCTest

// Run by hand, outside .yardr/test; attachments record the simulator's appearance.
// Pair the simulator's app with a yard whose lines contain beads that a stat
// separates, open Lines, then run these tests: the filter removes bead ids from
// the cards, and the transit count clears the filter; a line card pushes its
// route map, whose backlog station opens and shuts, and the back returns. The
// gate never runs them.
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

    // The yard's first line needs a backlog station with beads in it: the
    // route map shows the backlog shut as its count and opens it on a tap.
    @MainActor
    func testALineOpensAsARouteMap() {
        let app = XCUIApplication()
        app.launch()
        let lines = app.tabBars.buttons["Lines"]
        XCTAssertTrue(lines.waitForExistence(timeout: 10), "pair the simulator with a yard first")
        lines.tap()
        let transit = app.buttons["filter-all"]
        XCTAssertTrue(transit.waitForExistence(timeout: 30))
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'line/'")).firstMatch
        XCTAssertTrue(card.exists, "pair a yard with a line that has something moving")
        let line = card.identifier.dropFirst("line/".count).split(separator: "/", maxSplits: 1).map(String.init)
        XCTAssertEqual(line.count, 2)
        let title = "\(line[0]) · \(line[1])"
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "Lines overview"
        overview.lifetime = .keepAlways
        add(overview)

        // A tap on the card pushes the line: its stations on the rail
        // under the system's back, the tab bar gone.
        card.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        let stations = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'station/'"))
        XCTAssertGreaterThan(stations.count, 0)
        XCTAssertFalse(app.tabBars.buttons["Lines"].isHittable)
        XCTAssertFalse(transit.exists)
        let shut = XCTAttachment(screenshot: app.screenshot())
        shut.name = "Route map"
        shut.lifetime = .keepAlways
        add(shut)

        // The backlog stands shut as its count; a tap opens its bead cards
        // and the next tap shuts them again.
        let backlog = app.buttons["station/backlog"]
        XCTAssertTrue(backlog.waitForExistence(timeout: 5), "pair a yard whose line has a backlog")
        let words = backlog.label
        let counted = words.range(of: #"\d+ in backlog"#, options: .regularExpression)
            .flatMap { Int(words[$0].split(separator: " ")[0]) }
        XCTAssertNotNil(counted, "the shut backlog says how many it holds")
        let before = routeBeads(app)
        backlog.tap()
        XCTAssertTrue(waitFor { !backlog.label.contains("in backlog") })
        let held = routeBeads(app).subtracting(before)
        XCTAssertEqual(held.count, counted ?? -1)
        let open = XCTAttachment(screenshot: app.screenshot())
        open.name = "Route map, backlog open"
        open.lifetime = .keepAlways
        add(open)
        backlog.tap()
        XCTAssertTrue(waitFor { backlog.label.contains("in backlog") })
        XCTAssertTrue(routeBeads(app).isDisjoint(with: held))

        // The system's back returns to the overview, the tabs with it.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(transit.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Lines"].isHittable)
        XCTAssertFalse(app.navigationBars[title].exists)

        // A quiet line's chip opens its route map too.
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quiet/'")).firstMatch
        if chip.exists {
            let quiet = chip.label
            chip.tap()
            XCTAssertTrue(app.navigationBars[quiet].waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(transit.waitForExistence(timeout: 5))
        }
    }

    /// The beads on the route map's bead cards.
    @MainActor
    private func routeBeads(_ app: XCUIApplication) -> Set<String> {
        let cards = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'bead/'"))
        return Set(cards.allElementsBoundByIndex.map { $0.identifier })
    }

    /// Where the screen answers the tap a moment later.
    @MainActor
    private func waitFor(_ match: @MainActor () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !match() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    /// The beads named on line cards, each card's value.
    @MainActor
    private func cardBeadIDs(_ app: XCUIApplication) -> Set<String> {
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'line/'"))
        return Set(cards.allElementsBoundByIndex.flatMap {
            (($0.value as? String) ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        })
    }
}
