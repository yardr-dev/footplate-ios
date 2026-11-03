import XCTest

// Run by hand, outside .yardr/test; attachments record the simulator's appearance.
// After AAPairForHand against scripts/fake-edge (or a real yard paired): the
// yard switch opens on the first tap in a place visited for the first time,
// tapped straight after the tab change, in Decide and in Lines; Rename this
// yard asks for a name after the sheet shuts, and the name stands in the
// switch until an empty one clears it; and Forget this yard still asks its
// confirmation after the sheet shuts, kept here so the pairing stands for
// what runs next. The gate never runs them.
final class SwitchSheetTests: XCTestCase {
    @MainActor
    func testSwitchOpensAcrossPlacesAndForgetAsksAfterTheSheetShuts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Crew"].waitForExistence(timeout: 10), "pair the simulator with a yard first")

        // First visit Decide and tap as soon as its switch button appears.
        app.tabBars.buttons["Decide"].tap()
        XCTAssertTrue(app.buttons["Switch yard"].waitForExistence(timeout: 10))
        app.buttons["Switch yard"].tap()
        XCTAssertTrue(app.buttons["Pair another yard"].waitForExistence(timeout: 5))
        let decide = XCTAttachment(screenshot: app.screenshot())
        decide.name = "Switch open in first-visited Decide"
        decide.lifetime = .keepAlways
        add(decide)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitFor { !app.buttons["Pair another yard"].exists })

        // Then visit Lines for the first time and repeat straight after
        // the tab change.
        app.tabBars.buttons["Lines"].tap()
        XCTAssertTrue(app.buttons["Switch yard"].waitForExistence(timeout: 10))
        app.buttons["Switch yard"].tap()
        XCTAssertTrue(app.buttons["Pair another yard"].waitForExistence(timeout: 5))
        let lines = XCTAttachment(screenshot: app.screenshot())
        lines.name = "Switch open in first-visited Lines"
        lines.lifetime = .keepAlways
        add(lines)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitFor { !app.buttons["Pair another yard"].exists })

        // Rename asks for a name after the sheet shuts, as Forget does; the
        // name it takes stands in the switch's row, and an empty one brings
        // the old name back.
        let rename = app.alerts["Rename this yard"]
        let renamed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Back shed'")).firstMatch
        app.buttons["Switch yard"].tap()
        XCTAssertTrue(app.buttons["Rename this yard"].waitForExistence(timeout: 5))
        app.buttons["Rename this yard"].tap()
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { !app.buttons["Pair another yard"].exists })
        rename.textFields.firstMatch.typeText("Back shed")
        let naming = XCTAttachment(screenshot: app.screenshot())
        naming.name = "Rename asks"
        naming.lifetime = .keepAlways
        add(naming)
        rename.buttons["Rename"].tap()
        XCTAssertTrue(waitFor { !rename.exists })
        app.buttons["Switch yard"].tap()
        XCTAssertTrue(app.buttons["Pair another yard"].waitForExistence(timeout: 5))
        XCTAssertTrue(renamed.exists)
        let switched = XCTAttachment(screenshot: app.screenshot())
        switched.name = "Switch with a renamed yard"
        switched.lifetime = .keepAlways
        add(switched)
        app.buttons["Rename this yard"].tap()
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.textFields.firstMatch.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Back shed".count))
        rename.buttons["Rename"].tap()
        XCTAssertTrue(waitFor { !rename.exists })
        app.buttons["Switch yard"].tap()
        XCTAssertTrue(app.buttons["Pair another yard"].waitForExistence(timeout: 5))
        XCTAssertFalse(renamed.exists)
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitFor { !app.buttons["Pair another yard"].exists })

        // Forget still asks after the switch sheet closes.
        app.buttons["Switch yard"].tap()
        XCTAssertTrue(app.buttons["Pair another yard"].waitForExistence(timeout: 5))
        app.buttons["Forget this yard"].tap()
        let alert = app.alerts["Forget this yard"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["Keep"].exists)
        XCTAssertTrue(alert.buttons["Forget"].exists)
        let asking = XCTAttachment(screenshot: app.screenshot())
        asking.name = "Forget asks"
        asking.lifetime = .keepAlways
        add(asking)
        alert.buttons["Keep"].tap()
        XCTAssertTrue(waitFor { !alert.exists })
        XCTAssertTrue(app.tabBars.buttons["Crew"].exists)
    }

    /// Whether `condition` holds within a few seconds.
    @MainActor
    private func waitFor(_ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
