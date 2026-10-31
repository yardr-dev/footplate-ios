import XCTest

// Run by hand, outside .yardr/test; attachments record the simulator's appearance.
final class PairScreenTests: XCTestCase {
    @MainActor
    func testPairScreen() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["footplate"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Scan"].isHittable)
        XCTAssertTrue(app.buttons["Type the code"].isHittable)
        // The first screen of a phone with no yard offers the demo.
        XCTAssertTrue(app.buttons["Try a demo"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Pair screen"
        shot.lifetime = .keepAlways
        add(shot)

        // Continue through the same pairing path for its typed-code and
        // sign-in states, keeping the screenshots with this journey.
        XCTAssertTrue(app.buttons["Type the code"].waitForExistence(timeout: 5))
        app.buttons["Type the code"].tap()
        let yard = app.textFields["yard"]
        XCTAssertTrue(yard.waitForExistence(timeout: 5))
        yard.tap()
        yard.typeText("laptop")
        let code = app.textFields["code"]
        code.tap()
        code.typeText("K7QM-2XPD")
        app.buttons["Read"].tap()
        // The typed-code result: the parsed address, yard and code rows.
        XCTAssertTrue(app.staticTexts["K7QM-2XPD"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["laptop"].exists)
        let typed = XCTAttachment(screenshot: app.screenshot())
        typed.name = "Typed code"
        typed.lifetime = .keepAlways
        add(typed)
        // Pair with no session kept asks to sign in first.
        app.buttons["Pair"].tap()
        XCTAssertTrue(app.staticTexts["Sign in"].waitForExistence(timeout: 5))
        let signIn = XCTAttachment(screenshot: app.screenshot())
        signIn.name = "Sign in screen"
        signIn.lifetime = .keepAlways
        add(signIn)
    }
}
