import XCTest

// Run by hand, outside .yardr/test, after AAPairForHand against
// scripts/fake-edge, whose yd-gate carries three pictures over two notes
// (a builder's one, then a reviewer's two) and whose other beads carry
// none. The gate never runs them. The gate's LineScreenshotTests draws the
// same screens; this drives them with touches: yd-gate's card says
// Media · 3 under its labels and pushes the grid, the reviewer's two
// first; a tap opens one full size, where a swipe goes to the next and the
// previous with the note's author under it, and a pinch in keeps the swipe
// for the picture until it is pinched out again; Close and the back return
// to the card. A bead whose notes carry no picture has no row.
final class MediaScreenTests: XCTestCase {
    @MainActor
    func testTheMediaGridOpensEachPictureToSwipeThrough() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let lines = app.tabBars.buttons["Lines"]
        XCTAssertTrue(lines.waitForExistence(timeout: 10), "pair the simulator with the stand-in first")
        lines.tap()
        let gate = app.buttons["bead-id/yd-gate"]
        XCTAssertTrue(gate.waitForExistence(timeout: 30))
        gate.tap()
        XCTAssertTrue(app.navigationBars["yd-gate"].waitForExistence(timeout: 5))

        // The row stands under the labels once the bead is read.
        let row = app.buttons["bead-media"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertEqual(row.label, "Media · 3")
        shoot(app, "bead-card-media")

        // The grid: three pictures, the newest note's two first, the
        // system's back over it and the tab bar gone.
        row.tap()
        let pictures = app.buttons.matching(identifier: "media-picture")
        XCTAssertTrue(pictures.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { pictures.count == 3 })
        XCTAssertTrue(app.navigationBars["Media"].exists)
        XCTAssertFalse(app.tabBars.buttons["Lines"].isHittable)
        XCTAssertTrue(pictures.element(boundBy: 0).label.hasPrefix("platform.png, reviewer"), pictures.element(boundBy: 0).label)
        XCTAssertTrue(pictures.element(boundBy: 1).label.hasPrefix("ballast.png, reviewer"), pictures.element(boundBy: 1).label)
        XCTAssertTrue(pictures.element(boundBy: 2).label.hasPrefix("first-pass.png, builder"), pictures.element(boundBy: 2).label)
        shoot(app, "media-grid")

        // A tap opens the first full size; a swipe goes to the next and
        // the previous, each saying its place and who attached it.
        pictures.element(boundBy: 0).tap()
        let place = app.staticTexts["media-place"]
        let caption = app.descendants(matching: .any)["media-caption"]
        XCTAssertTrue(place.waitForExistence(timeout: 5))
        XCTAssertEqual(place.label, "1 of 3")
        XCTAssertTrue(caption.label.contains("reviewer"), caption.label)
        shoot(app, "media-viewer-1")
        app.swipeLeft()
        XCTAssertTrue(waitFor { place.label == "2 of 3" }, place.label)
        XCTAssertTrue(caption.label.contains("reviewer"), caption.label)
        shoot(app, "media-viewer-2")
        app.swipeLeft()
        XCTAssertTrue(waitFor { place.label == "3 of 3" }, place.label)
        XCTAssertTrue(caption.label.contains("builder"), caption.label)
        shoot(app, "media-viewer-3")
        // The last has no next: the swipe leaves it where it is.
        app.swipeLeft()
        XCTAssertEqual(place.label, "3 of 3")
        app.swipeRight()
        XCTAssertTrue(waitFor { place.label == "2 of 3" }, place.label)

        // Pinched in, the picture has the swipe; pinched out, the pager.
        let shown = app.images["ballast.png"]
        XCTAssertTrue(shown.waitForExistence(timeout: 5))
        shown.pinch(withScale: 3, velocity: 2)
        shoot(app, "media-viewer-zoomed")
        app.swipeLeft()
        XCTAssertEqual(place.label, "2 of 3", "a zoomed picture is panned, not paged")
        shown.pinch(withScale: 0.3, velocity: -2)
        app.swipeRight()
        XCTAssertTrue(waitFor { place.label == "1 of 3" }, place.label)

        // Close returns to the grid, the back to the card, the back
        // again to the overview.
        app.buttons["media-close"].tap()
        XCTAssertTrue(pictures.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(place.exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["filter-all"].waitForExistence(timeout: 5))
    }

    // The tap on a picture shuts it too, as a conversation's does.
    @MainActor
    func testATapOnTheFullPictureShutsIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let lines = app.tabBars.buttons["Lines"]
        XCTAssertTrue(lines.waitForExistence(timeout: 10), "pair the simulator with the stand-in first")
        lines.tap()
        let gate = app.buttons["bead-id/yd-gate"]
        XCTAssertTrue(gate.waitForExistence(timeout: 30))
        gate.tap()
        let row = app.buttons["bead-media"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let pictures = app.buttons.matching(identifier: "media-picture")
        XCTAssertTrue(pictures.firstMatch.waitForExistence(timeout: 5))
        pictures.element(boundBy: 1).tap()
        let place = app.staticTexts["media-place"]
        XCTAssertTrue(place.waitForExistence(timeout: 5))
        XCTAssertEqual(place.label, "2 of 3")
        app.images["ballast.png"].tap()
        XCTAssertTrue(waitFor { !place.exists })
        XCTAssertTrue(pictures.firstMatch.exists)
    }

    // A bead whose notes carry no picture has no Media row.
    @MainActor
    func testABeadWithNoPicturesHasNoMediaRow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let lines = app.tabBars.buttons["Lines"]
        XCTAssertTrue(lines.waitForExistence(timeout: 10), "pair the simulator with the stand-in first")
        lines.tap()
        let held = app.buttons["bead-row/yd-fence"]
        XCTAssertTrue(held.waitForExistence(timeout: 30))
        held.tap()
        XCTAssertTrue(app.navigationBars["yd-fence"].waitForExistence(timeout: 5))
        // Read: its description is in, and still no row.
        XCTAssertTrue(app.staticTexts["bead-body"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["bead-media"].exists)
        shoot(app, "bead-card-no-media")
    }

    /// Where the screen answers the touch a moment later.
    @MainActor
    private func waitFor(_ match: @MainActor () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !match() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    /// The screen, kept in the result bundle as the other tests keep theirs
    /// and, where `MEDIA_SHOTS_DIR` names a folder (the runner takes it as
    /// `TEST_RUNNER_MEDIA_SHOTS_DIR`), written there as a PNG.
    @MainActor
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["MEDIA_SHOTS_DIR"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
