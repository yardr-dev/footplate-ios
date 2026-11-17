import XCTest

// Run by hand, outside .yardr/test; attachments record the simulator's
// appearance. Dictation over the phone's own recognizer (footplate-ios-tedd),
// not the fake the gate's tests drive: the system's prompts, the engine and
// the recognizer's callbacks, which no unit test reaches. Each test starts
// with neither consent decided, so run each alone, on the gate's simulator
// and holding the gate's lock (flock -o on footplate-ios-sim.lock in
// `getconf DARWIN_USER_TEMP_DIR`, as .yardr/test does), after
// `xcrun simctl uninstall <udid> dev.yardr.footplate` and
// `xcrun simctl privacy <udid> reset all dev.yardr.footplate`: the second
// is what clears the consents. A test that fails with a system prompt up
// leaves it standing, and the next run's default handler answers it, so the
// tests refuse any prompt they leave. Run with no yard paired, as
// DemoScreenTests wants: the demo's conversation with the yardmaster. A
// simulator whose recognizer does not hear its locale on the device offers
// no microphone, which the app is meant to do, and the tests skip. A simulator takes its microphone from the Mac, which may have none:
// the recording then says that the microphone could not start, and the test
// accepts that as readily as the strip. Nobody speaks into a simulator, so
// no words are heard here; the words, the stop's final, a send and the
// cancel's restored draft are held by ConversationModelTests over a fake,
// and on a real phone by footplate-ios-txgy. The gate never runs it.
final class DictationScreenTests: XCTestCase {
    private let speechString = "Turn your recorded voice into words on this device; the recording stays here and goes nowhere — not to Apple."
    private let microphoneString = "Record what you say so the composer can write it down"
    private let firstLine = "What you say is heard on this device, and the words are written into the field. Nothing goes to the yard until you send it, and nothing goes to Apple — the hearing happens on this device. footplate opens the microphone only while you record."

    /// Both prompts allowed: the line at the first tap, the speech prompt
    /// and then the microphone prompt, each with the app's own words, and
    /// then the recording's strip, or the words for why the microphone would
    /// not open. What starts is ended by the strip's stop, which settles with
    /// nothing heard and returns the microphone.
    @MainActor
    func testAllowingBothPromptsRecordsOrSaysWhy() throws {
        continueAfterFailure = false
        defer { dismissSystemAlert() }
        let app = openedConversation()
        let dictate = try offered(app)
        attach(app, "Dictation offered")

        dictate.tap()
        let line = app.descendants(matching: .any)["conversation-dictation-line"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertEqual(line.label, firstLine)
        // The speech prompt comes first, with the app's own words.
        let speech = systemAlert()
        XCTAssertTrue(speech.waitForExistence(timeout: 10))
        XCTAssertTrue(says(speech, speechString), "the speech prompt says \(speech.debugDescription)")
        attachScreen("Speech prompt")
        tap(["OK", "Allow"], in: speech)
        // Then the microphone's.
        let microphone = systemAlert()
        XCTAssertTrue(microphone.waitForExistence(timeout: 10))
        XCTAssertTrue(says(microphone, microphoneString), "the microphone prompt says \(microphone.debugDescription)")
        attachScreen("Microphone prompt")
        tap(["Allow", "OK"], in: microphone)

        let stop = app.buttons["conversation-dictate-stop"]
        let couldNot = app.staticTexts["The microphone could not start; tap it to try again."]
        let unavailable = app.staticTexts["Speech recognition is not available just now; try again in a little while."]
        let started = stop.waitForExistence(timeout: 10)
        if started {
            attach(app, "Recording")
            // The line stands while the first recording does.
            XCTAssertTrue(line.exists)
            XCTAssertTrue(stop.isEnabled)
            Thread.sleep(forTimeInterval: 2)
            stop.tap()
            // Nothing was said: the recognizer settles at once or at the
            // bound, and the microphone returns, with nothing written.
            XCTAssertTrue(app.buttons["Dictate"].waitForExistence(timeout: 10), "the recording ended")
            XCTAssertFalse(stop.exists)
            attach(app, "Stopped with nothing heard")
        } else {
            XCTAssertTrue(
                couldNot.waitForExistence(timeout: 5) || unavailable.waitForExistence(timeout: 5),
                "neither a recording nor the words for why not"
            )
            XCTAssertTrue(app.buttons["Dictate"].exists, "the microphone stays for another try")
            attach(app, "The recording would not start")
        }
        // A second tap asks nothing: the consents are decided.
        app.buttons["Dictate"].tap()
        XCTAssertFalse(systemAlert().waitForExistence(timeout: 2))
        if app.buttons["conversation-dictate-cancel"].waitForExistence(timeout: 5) {
            app.buttons["conversation-dictate-cancel"].tap()
            XCTAssertTrue(app.buttons["Dictate"].waitForExistence(timeout: 5))
        }
    }

    /// The speech prompt refused: the microphone is never asked for, the
    /// microphone goes from the composer, and the line names the consent
    /// with the way to Settings.
    @MainActor
    func testRefusingSpeechHidesTheMicrophoneAndNamesTheConsent() throws {
        continueAfterFailure = false
        defer { dismissSystemAlert() }
        let app = openedConversation()
        let dictate = try offered(app)
        dictate.tap()
        let speech = systemAlert()
        XCTAssertTrue(speech.waitForExistence(timeout: 10))
        tap(["Don\u{2019}t Allow", "Don't Allow"], in: speech)
        let refusal = "Speech recognition is off for footplate: allow it in Settings to dictate."
        XCTAssertTrue(app.staticTexts[refusal].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Dictate"].exists)
        XCTAssertTrue(app.links["Open Settings"].exists || app.buttons["Open Settings"].exists)
        XCTAssertFalse(systemAlert().waitForExistence(timeout: 2), "the microphone is not asked after a refusal")
        attach(app, "Speech refused")
    }

    /// The demo's conversation with the yardmaster.
    @MainActor
    private func openedConversation() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let demo = app.buttons["Try a demo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10), "run on a fresh install with no yard paired")
        demo.tap()
        let master = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "yardmaster")).firstMatch
        XCTAssertTrue(master.waitForExistence(timeout: 10))
        master.tap()
        XCTAssertTrue(app.descendants(matching: .any)["conversation-field"].waitForExistence(timeout: 10))
        return app
    }

    /// The microphone, where this simulator's recognizer hears on the device.
    @MainActor
    private func offered(_ app: XCUIApplication) throws -> XCUIElement {
        let dictate = app.buttons["Dictate"]
        if !dictate.waitForExistence(timeout: 5) {
            throw XCTSkip("this simulator's recognizer does not hear its locale on the device: no microphone, as meant")
        }
        return dictate
    }

    /// The system's own alert, drawn by SpringBoard.
    @MainActor
    private func systemAlert() -> XCUIElement {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
    }

    /// Whether the alert's words hold `words`: the system sets the app's
    /// usage string after words of its own, and the speech prompt's say
    /// that the speech data is sent to Apple, whatever the request asks.
    @MainActor
    private func says(_ alert: XCUIElement, _ words: String) -> Bool {
        alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch.exists
    }

    /// A prompt that a failed test leaves standing would stand over the next
    /// run on the simulator the gate shares: it is refused.
    @MainActor
    private func dismissSystemAlert() {
        let alert = systemAlert()
        guard alert.exists else { return }
        for label in ["Don\u{2019}t Allow", "Don't Allow", "Cancel"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
    }

    @MainActor
    private func tap(_ labels: [String], in alert: XCUIElement) {
        for label in labels where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
        XCTFail("none of \(labels) in \(alert.debugDescription)")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The whole screen, with the system's alert over the app.
    @MainActor
    private func attachScreen(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
