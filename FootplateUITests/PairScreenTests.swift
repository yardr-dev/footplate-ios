import XCTest

// Run by hand, outside .yardr/test; attachments record the simulator's appearance.
final class PairScreenTests: XCTestCase {
    @MainActor
    func testPairScreen() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["footplate"].exists)
        XCTAssertTrue(app.buttons["Scan"].isHittable)
        XCTAssertTrue(app.buttons["Type the code"].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Pair screen"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
