import XCTest

// Pairs the simulator with the stand-in edge before the class under
// test runs: XCTest runs classes alphabetically, so this one goes
// first. Run by hand, outside .yardr/test, against an app built with
// EDGE_URL=http://localhost:<stand-in's port> (README: the by-hand
// UI tests). It leaves the app paired on the Crew tab; where the
// simulator is paired already it asserts that and pairs nothing.
// Either way it answers the notifications prompt when it is up, so
// the class under test finds the tabs clear.
final class AAPairForHand: XCTestCase {
    @MainActor
    func testPairForHand() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        if !app.tabBars.buttons["Crew"].waitForExistence(timeout: 10) {
            pair(app)
        }
        answerNotificationsPrompt(app)
        XCTAssertTrue(app.tabBars.buttons["Crew"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Paired crew"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Through Type the code and Sign in, as a person pairs: the
    /// yard is empty for the account's own, and the stand-in signs
    /// any credentials in, so the password is obviously not real.
    @MainActor
    private func pair(_ app: XCUIApplication) {
        let typeCode = app.buttons["Type the code"]
        XCTAssertTrue(typeCode.waitForExistence(timeout: 10))
        typeCode.tap()
        XCTAssertTrue(app.textFields["yard"].waitForExistence(timeout: 5))
        let code = app.textFields["code"]
        code.tap()
        code.typeText("K7QM-2XPD")
        app.buttons["Read"].tap()
        XCTAssertTrue(app.staticTexts["K7QM-2XPD"].waitForExistence(timeout: 5))
        app.buttons["Pair"].tap()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("jo@example.com")
        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText("stand-in")
        app.buttons["Sign in"].tap()
        // The pairing goes on by itself once the session is kept.
        XCTAssertTrue(app.tabBars.buttons["Crew"].waitForExistence(timeout: 30))
    }

    /// The in-app prompt first, then the system's where the simulator
    /// has not answered it: the app is declined, so no banner lands
    /// on the class under test.
    @MainActor
    private func answerNotificationsPrompt(_ app: XCUIApplication) {
        guard app.alerts.buttons["Continue"].waitForExistence(timeout: 5) else { return }
        app.alerts.buttons["Continue"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        guard springboard.alerts.firstMatch.waitForExistence(timeout: 5) else { return }
        for name in ["Don’t Allow", "Don't Allow"] {
            if springboard.alerts.buttons[name].exists {
                springboard.alerts.buttons[name].tap()
                return
            }
        }
        if springboard.alerts.buttons["Allow"].exists {
            springboard.alerts.buttons["Allow"].tap()
        }
    }
}
