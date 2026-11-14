import XCTest

// Run by hand, outside .yardr/test; attachments record the simulator's appearance.
// On a fresh install with no yard paired, as PairScreenTests wants, and with no
// stand-in edge: the demo answers in the app. From the first screen a person
// with no yard sees, Try a demo opens the demo yard under its banner with no
// permission asked; the yard switch offers the way out in place of pairing
// another yard, on the first tap in a place visited for the first time too;
// the crew's mail, the composer's box (its arrow dim while the field is
// empty, its plus's menu, three pictures picked at once from the library,
// each with its own cross, enabling the arrow on their own, taken back
// one by one, and a letter of three sent),
// a letter sent, a fenced one whose Copy puts its code
// alone on the pasteboard, the one question answered and
// the line are walked; and Pair a real yard leaves for the first screen with
// no place of the tabs left, to enter a demo as new, its question open again,
// and leave by the yard switch. The gate never runs it.
final class DemoScreenTests: XCTestCase {
    @MainActor
    func testTheDemoFromTheFirstScreenAndBack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let demo = app.buttons["Try a demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10), "run on a simulator with no yard paired")
        XCTAssertTrue(app.buttons["Scan"].isHittable)
        XCTAssertTrue(app.buttons["Type the code"].isHittable)
        XCTAssertTrue(demo.isHittable)
        attach(app, "First screen")

        demo.tap()
        let banner = app.staticTexts["Demo yard: the crew, mail and beads are made up, and nothing leaves this phone"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Pair a real yard"].isHittable)
        XCTAssertTrue(app.tabBars.buttons["Crew"].exists)
        XCTAssertFalse(app.buttons["Try a demo"].exists)
        // A demo is no pairing: no permission is asked in it.
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2))
        let master = row(app, "yardmaster")
        XCTAssertTrue(master.waitForExistence(timeout: 10))
        XCTAssertTrue(row(app, "signalman").exists)
        XCTAssertTrue(row(app, "shunter").exists)
        attach(app, "Demo crew")

        // The yard switch: the demo yard and the way out, and nothing to
        // pair another yard with, to rename or to forget.
        app.buttons["Switch yard"].tap()
        XCTAssertTrue(yardSwitchLeave(app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Pair another yard"].exists)
        XCTAssertFalse(app.buttons["Rename this yard"].exists)
        XCTAssertFalse(app.buttons["Forget this yard"].exists)
        attach(app, "Demo yard switch")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitFor { !self.yardSwitchLeave(app).exists })

        // The switch opens on the first tap in a place visited for the
        // first time too, tapped straight after the tab change.
        app.tabBars.buttons["Decide"].tap()
        XCTAssertTrue(app.buttons["Switch yard"].waitForExistence(timeout: 10))
        app.buttons["Switch yard"].tap()
        XCTAssertTrue(yardSwitchLeave(app).waitForExistence(timeout: 5))
        attach(app, "Demo switch in first-visited Decide")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(waitFor { !self.yardSwitchLeave(app).exists })
        app.tabBars.buttons["Crew"].tap()
        XCTAssertTrue(master.waitForExistence(timeout: 10))

        // A letter to the yardmaster appears in the conversation once sent.
        master.tap()
        let field = app.descendants(matching: .any)["conversation-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The composer is one box: its arrow is dim while the field is
        // empty, and its plus opens the menu that adds a picture (a
        // simulator has no camera, so Photos alone).
        let send = app.buttons["Send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled)
        attach(app, "Demo composer empty")
        app.buttons["Attach a picture"].tap()
        let photos = app.descendants(matching: .any)["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        attach(app, "Demo composer menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(waitFor { !photos.exists })
        // The plus's Photos entry picks pictures through the system's
        // picker, several at once (a tap on a photo selects it, Add returns
        // the selection): the field still empty, a thumbnail with its own
        // cross stands for each, and the arrow stands enabled on the
        // pictures alone. Each is taken back by its cross, the last one
        // dims the arrow again, and the flow below stands as before. Run on
        // a simulator whose library holds three photos (`xcrun simctl
        // addmedia` seeds them).
        let removes = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove photo'"))
        pickThreePhotos(app, shot: "Demo photo picker with three selected")
        XCTAssertTrue(removes.firstMatch.waitForExistence(timeout: 10), "run on a simulator whose library holds three photos")
        XCTAssertTrue(waitFor { removes.count == 3 })
        XCTAssertTrue(send.isEnabled)
        attach(app, "Demo composer with three pictures")
        removes.element(boundBy: 1).tap()
        XCTAssertTrue(waitFor { removes.count == 2 })
        XCTAssertTrue(send.isEnabled)
        attach(app, "Demo composer with two pictures")
        removes.element(boundBy: 0).tap()
        XCTAssertTrue(waitFor { removes.count == 1 })
        removes.element(boundBy: 0).tap()
        XCTAssertTrue(waitFor { removes.count == 0 })
        XCTAssertFalse(send.isEnabled)
        // Three again, sent with words: one letter, its pictures drawn under
        // its words, the composer emptied.
        pickThreePhotos(app)
        XCTAssertTrue(waitFor { removes.count == 3 })
        field.tap()
        field.typeText("Three from the library")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Three from the library"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor { removes.count == 0 })
        attach(app, "Demo conversation with a letter of three pictures")
        field.tap()
        field.typeText("Land it today if it is green")
        XCTAssertTrue(send.isEnabled)
        attach(app, "Demo composer with words")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Land it today if it is green"].waitForExistence(timeout: 10))
        attach(app, "Demo conversation")
        // A fenced letter draws its code in a block of its own, and the
        // block's Copy puts the code alone on the pasteboard: pasted into
        // the field it stands without its fences.
        field.tap()
        field.typeText("Run this:\n```\nselect 1;\nselect 2;\n```")
        app.buttons["Send"].tap()
        // Every letter of the thread stands in the tree now, each
        // fenced one with its Copy: the one on the screen serves.
        let copy = app.buttons.matching(NSPredicate(format: "identifier == 'code-copy'"))
            .allElementsBoundByIndex.last { $0.frame.intersects(app.frame) } ?? app.buttons["code-copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        XCTAssertEqual(copy.label, "Copy code")
        attach(app, "Demo conversation with a code block")
        copy.tap()
        XCTAssertEqual(copy.label, "Copied")
        field.press(forDuration: 1.2)
        app.menuItems["Paste"].tap()
        XCTAssertEqual(field.value as? String, "select 1;\nselect 2;")
        attach(app, "Demo code pasted")
        // A long-press on the letter still offers the whole of it, fences
        // and all, over its code block as over its words.
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "select 1;\nselect 2;".count))
        let code = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'select 1;'")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Copy message"].waitForExistence(timeout: 5))
        attach(app, "Demo copy message over a code block")
        app.buttons["Copy message"].tap()
        field.press(forDuration: 1.2)
        app.menuItems["Paste"].tap()
        XCTAssertEqual(field.value as? String, "Run this:\n```\nselect 1;\nselect 2;\n```")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // The one question: opened, a pick made, answered and gone from
        // the waiting, written under Decided.
        app.tabBars.buttons["Decide"].tap()
        let question = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Land the departures cache'")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        attach(app, "Demo decide")
        question.tap()
        let option = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Land it today'")).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        attach(app, "Demo decision")
        option.tap()
        app.buttons["Pick"].tap()
        XCTAssertTrue(app.staticTexts["answered: Land it today"].waitForExistence(timeout: 10))
        XCTAssertFalse(question.exists)

        // The line, and a bead's card with no page to open in a browser.
        app.tabBars.buttons["Lines"].tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'line/'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        attach(app, "Demo lines")
        card.tap()
        let bead = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'bead/'")).firstMatch
        XCTAssertTrue(bead.waitForExistence(timeout: 5))
        attach(app, "Demo route map")
        bead.tap()
        XCTAssertTrue(app.buttons["bead-ask"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bead-open-web"].exists)
        attach(app, "Demo bead")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Out by the banner: the first screen, with no place of the tabs left.
        app.buttons["demo-leave"].tap()
        XCTAssertTrue(app.buttons["Try a demo"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Crew"].exists)
        XCTAssertFalse(banner.exists)
        attach(app, "First screen again")

        // The yard switch's way out leaves as well.
        app.buttons["Try a demo"].tap()
        XCTAssertTrue(app.buttons["Switch yard"].waitForExistence(timeout: 10))
        app.buttons["Switch yard"].tap()
        XCTAssertTrue(yardSwitchLeave(app).waitForExistence(timeout: 5))
        yardSwitchLeave(app).tap()
        XCTAssertTrue(app.buttons["Try a demo"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.tabBars.buttons["Crew"].exists)

        // A demo entered again is new: its question is open again.
        app.buttons["Try a demo"].tap()
        XCTAssertTrue(app.tabBars.buttons["Decide"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Decide"].tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS 'Land the departures cache'")).firstMatch
                .waitForExistence(timeout: 10)
        )
        app.buttons["demo-leave"].tap()
        XCTAssertTrue(app.buttons["Try a demo"].waitForExistence(timeout: 10))
    }

    /// The yard switch's way out, apart from the banner's.
    @MainActor
    private func yardSwitchLeave(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == 'Pair a real yard' AND identifier != 'demo-leave'")).firstMatch
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

    /// The crew row whose words begin with `name`.
    @MainActor
    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// The plus's Photos entry, three photos of the library tapped in the
    /// picker (it numbers them in the order picked: the third cell first, so
    /// the row can be read against the library's own order) and Add. `shot`
    /// names a capture of the picker with its numbers.
    @MainActor
    private func pickThreePhotos(_ app: XCUIApplication, shot: String? = nil) {
        app.buttons["Attach a picture"].tap()
        let photos = app.descendants(matching: .any)["Photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 5))
        photos.tap()
        let grid = app.scrollViews["photosView_content_scroll_view"]
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        let cells = grid.images.matching(identifier: "PXGGridLayout-Info")
        XCTAssertGreaterThanOrEqual(cells.count, 3, "run on a simulator whose library holds three photos")
        for index in [2, 0, 1] {
            cells.element(boundBy: index).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        if let shot { attach(app, shot) }
        app.buttons["Add"].tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
