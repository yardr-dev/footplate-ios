@testable import Footplate
import AVFoundation
import Speech
import XCTest

// Dictation's plain pieces (footplate-ios-tedd, after Android's
// VoiceTest.kt): which gate the phone's standing gives the composer, the
// words said at each state, the one request every recognition is made with,
// the words the draft takes, the stretches the recognizer closes at a pause
// folded into one recording (footplate-ios-wg9q), the bars' levels, and the
// phone's recognizer read per call for the locale of that call. The
// recording's state machine is in ConversationModelTests, over
// `FakeDictation`; what the recognizer does with a real microphone is
// checked by hand on an iPhone (footplate-ios-txgy), a simulator's being the
// Mac's.
@MainActor
final class DictationTests: XCTestCase {
    private func standing(_ onDevice: Bool, _ speech: Consent, _ microphone: Consent, _ language: String? = nil) -> DictationStanding {
        DictationStanding(onDevice: onDevice, speech: speech, microphone: microphone, language: language)
    }

    /// The microphone is drawn only where the phone hears on the device, and
    /// not where a consent is refused; where it cannot hear there, no word
    /// of a refusal is said, as no consent would help, and the named
    /// language is told instead (footplate-ios-sz3n). Speech is named
    /// before the microphone, as it is asked first.
    func testTheGateOffersTheMicrophoneOnlyWhereThePhoneHearsOnTheDeviceAndNoConsentIsRefused() {
        let rows: [(DictationStanding, DictationGate)] = [
            (standing(false, .granted, .granted), .absent),
            (standing(false, .denied, .denied), .absent),
            (standing(false, .undecided, .undecided), .absent),
            (standing(false, .granted, .granted, "English"), .unheard(language: "English")),
            (standing(false, .denied, .denied, "Deutsch"), .unheard(language: "Deutsch")),
            (standing(false, .undecided, .undecided, "English"), .unheard(language: "English")),
            (standing(true, .undecided, .undecided), .offered),
            (standing(true, .granted, .undecided), .offered),
            (standing(true, .granted, .granted), .offered),
            (standing(true, .undecided, .granted), .offered),
            (standing(true, .denied, .granted), .refused(.speechDenied)),
            (standing(true, .restricted, .granted), .refused(.speechRestricted)),
            (standing(true, .granted, .denied), .refused(.microphoneDenied)),
            (standing(true, .granted, .restricted), .refused(.microphoneDenied)),
            (standing(true, .undecided, .denied), .refused(.microphoneDenied)),
            (standing(true, .denied, .denied), .refused(.speechDenied)),
            (standing(true, .restricted, .denied), .refused(.speechRestricted)),
        ]
        for (phone, gate) in rows {
            XCTAssertEqual(dictationGate(phone), gate, "\(phone)")
        }
    }

    /// The choice of recognizer (footplate-ios-sz3n): the current locale
    /// where it hears on the device; else the same language's likely region
    /// (de_DE, ja_JP), then the US one (en_US), then the rest by identifier;
    /// none where none of the language hears. The hearing locales come in
    /// whatever order the framework's set has, and the choice is fixed all
    /// the same, `en_US` and `en-US` spelling one locale. Another language
    /// is never chosen.
    func testDictationHearsWithTheCurrentLocaleElseTheSameLanguageInAFixedOrder() {
        func choice(_ current: String, _ hearing: [String]) -> String? {
            dictationLocale(
                current: Locale(identifier: current),
                hearing: hearing.map { Locale(identifier: $0) }
            )?.identifier(.bcp47)
        }
        let rows: [(current: String, hearing: [String], chosen: String?)] = [
            ("en_CH", ["en-US"], "en-US"),
            ("de_CH", ["de-DE"], "de-DE"),
            ("en_US", ["en-US", "en-GB"], "en-US"),
            ("en_CH", ["en-GB", "en-AU", "en-US"], "en-US"),
            ("en_CH", ["en-US", "en-GB", "en-AU"], "en-US"),
            ("en_CH", ["en-GB", "en-AU"], "en-AU"),
            ("de_CH", ["de-AT", "de-DE"], "de-DE"),
            ("de_CH", ["de-DE", "de-AT"], "de-DE"),
            ("ja_CA", ["ja-TW", "ja-JP"], "ja-JP"),
            ("ja_CA", ["ja-JP", "ja-TW"], "ja-JP"),
            ("en_CH", ["de-DE"], nil),
            ("rm_CH", ["en-US"], nil),
            ("rm_CH", [], nil),
            ("zz_ZZ", ["zz-ZZ"], "zz-ZZ"),
        ]
        for row in rows {
            XCTAssertEqual(choice(row.current, row.hearing), row.chosen, "\(row)")
        }
        // The current locale is kept as it stands, not rebuilt from the
        // hearing list's spelling.
        XCTAssertEqual(
            dictationLocale(current: Locale(identifier: "en_US"), hearing: [Locale(identifier: "en-US")]),
            Locale(identifier: "en_US")
        )
    }

    /// A tap has prompts to show where a consent was never asked, and only
    /// there: a decided consent is not asked again.
    func testATapAsksOnlyForAConsentThatWasNeverAsked() {
        XCTAssertTrue(dictationAsks(standing(true, .undecided, .undecided)))
        XCTAssertTrue(dictationAsks(standing(true, .granted, .undecided)))
        XCTAssertTrue(dictationAsks(standing(true, .undecided, .granted)))
        XCTAssertFalse(dictationAsks(standing(true, .granted, .granted)))
        XCTAssertFalse(dictationAsks(standing(true, .denied, .granted)))
        XCTAssertFalse(dictationAsks(standing(true, .granted, .denied)))
    }

    /// The first tap's line is the bead's, word for word, with no word of one
    /// device (the app is for the iPhone and the iPad) and with the answer to
    /// the system's speech prompt, whose own paragraph says the speech data
    /// is sent to Apple: ours says that nothing is. Each refusal names which
    /// consent it is, and the unheard line names the language and that the
    /// device cannot hear it without a server (footplate-ios-sz3n); silence
    /// says nothing and every other failure says something.
    func testTheWordsAreThePinnedOnesAndEachRefusalSaysWhichConsent() {
        XCTAssertEqual(
            dictationLine,
            "What you say is heard on this device, and the words are written into the field. Nothing goes to the yard until you send it, and nothing goes to Apple — the hearing happens on this device. footplate opens the microphone only while you record."
        )
        for device in ["iPhone", "iPad", "tablet", " phone"] {
            XCTAssertFalse(dictationLine.contains(device), device)
        }
        XCTAssertEqual(
            unheardWords("English"),
            "This device cannot hear English without a server, so dictation stays off."
        )
        XCTAssertTrue(unheardWords("Deutsch").contains("Deutsch"))
        XCTAssertTrue(unheardWords("English").contains("server"))
        for device in ["iPhone", "iPad", "tablet", " phone"] {
            XCTAssertFalse(unheardWords("English").contains(device), device)
        }
        XCTAssertTrue(refusalWords(.speechDenied).contains("Speech recognition"))
        XCTAssertTrue(refusalWords(.speechDenied).contains("Settings"))
        XCTAssertTrue(refusalWords(.speechRestricted).contains("speech recognition"))
        XCTAssertTrue(refusalWords(.microphoneDenied).contains("microphone"))
        XCTAssertTrue(refusalWords(.microphoneDenied).contains("Settings"))
        XCTAssertEqual(Set([Refusal.speechDenied, .speechRestricted, .microphoneDenied].map(refusalWords) + [unheardWords("English")]).count, 4)
        XCTAssertNil(DictationFailure.notHeard.words)
        for failure in [DictationFailure.couldNotStart, .unavailable, .stopped(domain: "kAFAssistantErrorDomain", code: 203)] {
            XCTAssertFalse(try XCTUnwrap(failure.words).isEmpty, "\(failure)")
        }
        // A stop names the recognizer's domain and code at the end, short
        // and copyable by eye, so that a person on a real device can tell
        // us what the recognizer said (footplate-ios-p2py), and then what
        // primes a device that has never dictated: one dictation from the
        // keyboard's microphone (footplate-ios-f8bt). The other failures
        // keep their words, with no word of the keyboard: the microphone
        // and the service are other causes.
        XCTAssertEqual(
            DictationFailure.stopped(domain: "kAFAssistantErrorDomain", code: 203).words,
            "Speech recognition stopped (kAFAssistantErrorDomain 203); tap the microphone to try again. If this device has never dictated from the keyboard, dictate once from the keyboard's microphone first."
        )
        XCTAssertEqual(
            DictationFailure.couldNotStart.words,
            "The microphone could not start; tap it to try again."
        )
        XCTAssertEqual(
            DictationFailure.unavailable.words,
            "Speech recognition is not available just now; try again in a little while."
        )
        for failure in [DictationFailure.couldNotStart, .unavailable] {
            XCTAssertFalse(try XCTUnwrap(failure.words).contains("keyboard"), "\(failure)")
        }
    }

    /// A missing usage string crashes the app at the prompt: both are in the
    /// built app, in the bead's words. The speech one is set under the
    /// system's own paragraph, which says the speech data is sent to Apple
    /// and is shown for on-device requests too: it answers that paragraph,
    /// and names no device.
    func testTheBuiltAppCarriesTheTwoUsageStrings() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
            "Record what you say so the composer can write it down"
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String,
            "Turn your recorded voice into words on this device; the recording stays here and goes nowhere — not to Apple."
        )
    }

    /// Every recognition request is made by `dictationRequest()`: it must be
    /// heard on the device alone, whatever the phone's recognizer would do
    /// otherwise, with the words as they come, for dictation.
    func testEveryRequestIsHeardOnTheDeviceWithPartialWordsForDictation() {
        let request = dictationRequest()
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertTrue(request.shouldReportPartialResults)
        XCTAssertEqual(request.taskHint, .dictation)
        XCTAssertTrue(request.addsPunctuation)
        // A second one is the same: nothing of the first is carried over.
        XCTAssertTrue(dictationRequest().requiresOnDeviceRecognition)
    }

    /// The words go after the draft with one space between, none where the
    /// draft is empty or already ends in white space; words with nothing in
    /// them add nothing.
    func testTheWordsHeardGoAfterTheDraftWithOneSpace() {
        let rows: [(base: String, words: String, said: String)] = [
            ("", "land it", "land it"),
            ("Land", "it tonight", "Land it tonight"),
            ("Land ", "it tonight", "Land it tonight"),
            ("Land\n", "it tonight", "Land\nit tonight"),
            ("Land", " it tonight ", "Land it tonight"),
            ("Land", "", "Land"),
            ("Land", "  \n", "Land"),
            ("", "", ""),
        ]
        for row in rows {
            XCTAssertEqual(dictated(row.base, row.words), row.said, "\(row)")
        }
    }

    /// What the on-device recognizer gave for one sentence, a pause of 3.5
    /// seconds and a second sentence, fed to a recognition at the pace it was
    /// spoken (an iOS 26.3 simulator, en-US, footplate-ios-wg9q): each result
    /// says the stretch it belongs to, and the one that closed the first
    /// stretch, not final and with the speech's metadata, said its words again
    /// ahead of the second stretch's first. The partials after the pause carry
    /// the words after it alone.
    private let beforeThePause = [
        "Please", "Please land", "Please land the", "Please land the change",
        "Please land the change tonight", "Please land the change tonight after",
        "Please land the change tonight after the", "Please land the change tonight after the review",
    ]
    private let afterThePause = [
        "And", "And tell", "And tell me", "And tell me when", "And tell me when it",
        "And tell me when it is", "And tell me when it is done",
    ]

    /// One result of the recognizer as `SpeechRun` reads it.
    private enum Said {
        case partial(String)
        /// Not final, and with the speech's metadata: the stretch closed.
        case sign(String)
        case final(String)
    }

    /// The recording whole after each result, as the model is told it: a
    /// final settles its stretch as the sign does.
    private func told(_ results: [Said]) -> [String] {
        var transcript = Transcript()
        return results.map { said in
            switch said {
            case .partial(let text): transcript = fold(transcript, text: text, closes: false)
            case .sign(let text), .final(let text): transcript = fold(transcript, text: text, closes: true)
            }
            return transcript.text
        }
    }

    /// Within one stretch each result is the stretch whole and replaces the
    /// one before, as the recognizer revises what it heard: the recording is
    /// the last result, however it revises its words, and the final is the
    /// same text again.
    func testOneStretchRevisedByItsPartialsIsTheRecordingWhole() {
        let results = [
            "Please", "Please land", "Please land the changes", "Please land the change tonight",
            "Please land the change tonight after the stores", "Please land the change tonight after the store",
            "Please, land the change tonight after the review.",
        ]
        var said = results.map(Said.partial)
        XCTAssertEqual(told(said), results)
        said.append(.final(results[6]))
        XCTAssertEqual(told(said), results + [results[6]])
        // The recognizer's own spaces and lines are not words.
        XCTAssertEqual(told([.partial(" Please land "), .partial("Please land it\n")]), ["Please land", "Please land it"])
    }

    /// The recording of the sentence, the pause and the second sentence:
    /// both stretches stand, in the order said, with one space between, from
    /// the first word of the second to the final; the words of the first are
    /// never lost to the second's partials.
    func testTwoStretchesTheRecognizerClosedAtAPauseAreBothHeardInOrder() {
        let first = beforeThePause.last!
        let second = afterThePause.last!
        var results = beforeThePause.map(Said.partial)
        results.append(.sign(first))
        results += afterThePause.map(Said.partial)
        results.append(.final(second))
        let whole = beforeThePause + [first] + afterThePause.map { "\(first) \($0)" } + ["\(first) \(second)"]
        XCTAssertEqual(told(results), whole)
        XCTAssertEqual(whole.count, 17)
        XCTAssertEqual(whole.last, "Please land the change tonight after the review And tell me when it is done")
        // A third stretch goes behind the two, a one-word stretch among them.
        XCTAssertEqual(
            told([.partial("Thanks"), .sign("Thanks"), .partial("Right"), .sign("Right"), .partial("Done"), .final("Done")]),
            ["Thanks", "Thanks", "Thanks Right", "Thanks Right", "Thanks Right Done", "Thanks Right Done"]
        )
        // The sign may say its stretch revised: it replaces the last partial and is what stands.
        XCTAssertEqual(
            told([.partial("Land it tonite"), .sign("Land it tonight."), .partial("Then"), .final("Then tell me.")]),
            ["Land it tonite", "Land it tonight.", "Land it tonight. Then", "Land it tonight. Then tell me."]
        )
    }

    /// A recognizer that begins a stretch with no sign, going back to the
    /// start at a pause, has the last partial settled before the new words,
    /// so the earlier ones stay; and a partial that only revises its last
    /// words is never doubled. The new text is another stretch where it
    /// starts with another word and is under half the characters of a
    /// partial of 12 or more; where it starts alike, is as long, or the
    /// partial is a word or two, it is the same stretch revised.
    func testAStretchBegunAfreshWithNoSignIsSettledBehindTheLastPartial() {
        let first = beforeThePause.last!
        var results = beforeThePause.map(Said.partial)
        results += afterThePause.map(Said.partial)
        results.append(.final("And tell me when it is done."))
        XCTAssertEqual(
            told(results),
            beforeThePause + afterThePause.map { "\(first) \($0)" } + ["\(first) And tell me when it is done."]
        )
        let rows: [(partial: String, text: String, afresh: Bool)] = [
            // Another word, and much shorter: a stretch begun anew.
            ("Please land the change tonight", "And", true),
            ("Please land the change tonight", "Then tell me", true),
            ("Please land the change tonight", "So tell me now", true),
            ("Okay, thanks.", "So", true),
            ("今日は天気がとてもいいですね", "それで", true),
            // The first words stay: a partial cut back, cased or punctuated
            // otherwise, or the last word shortened, is the stretch revised.
            ("Please land the change tonight", "Please", false),
            ("Please land the change tonight", "please, land", false),
            ("Please land the change tonight after the stores", "Please land the change tonight after the store", false),
            ("I want to eat the cake tonight", "I", false),
            ("今日は天気がとてもいいですね", "今日は天気がとてもいいですね。", false),
            // Another word, but not much shorter: half is not under half.
            ("Please land the change tonight", "So then tell me", false),
            ("wreck a nice beach", "recognize speech", false),
            ("Please land the change tonight", "Then land the change", false),
            // A partial of a word or two may be rewritten whole.
            ("forty two", "42", false),
            ("Thank you.", "So", false),
            ("Okay", "OK", false),
        ]
        for row in rows {
            let next = fold(Transcript(partial: row.partial), text: row.text, closes: false)
            if row.afresh {
                XCTAssertEqual(next, Transcript(settled: row.partial, partial: row.text), "\(row)")
            } else {
                XCTAssertEqual(next, Transcript(partial: row.text), "\(row)")
            }
        }
        // Nothing stands before the first words, so there is nothing to settle.
        XCTAssertEqual(fold(Transcript(), text: "And", closes: false), Transcript(partial: "And"))
    }

    /// The final goes through the same fold. After a pause it is the last
    /// stretch's words alone, and goes behind the stretches before it; where
    /// nothing was said after the pause it is empty (a stop in the pause),
    /// and the words that stand are left as they are.
    func testAFinalAfterAPauseGoesBehindTheStretchesBeforeIt() {
        let first = beforeThePause.last!
        XCTAssertEqual(
            told([.partial(first), .sign(first), .partial("And tell me"), .final("And tell me when it is done")]),
            [first, first, "\(first) And tell me", "\(first) And tell me when it is done"]
        )
        // The recognizer's final of a stop in the pause (and of a second pause).
        XCTAssertEqual(told([.partial(first), .sign(first), .final("")]), [first, first, first])
        XCTAssertEqual(
            told([.partial(first), .sign(first), .partial("And tell"), .sign("And tell me"), .final("")]),
            [first, first, "\(first) And tell", "\(first) And tell me", "\(first) And tell me"]
        )
        // A final of silence leaves what was shown, with no pause as with one.
        XCTAssertEqual(told([.partial("Please land"), .final("")]), ["Please land", "Please land"])
        XCTAssertEqual(told([.final("")]), [""])
        // A final that revises its stretch replaces its partial.
        XCTAssertEqual(told([.partial("Please land the change"), .final("Please land the change.")]), ["Please land the change", "Please land the change."])
        // With no result before it, it is the recording.
        XCTAssertEqual(told([.final("Yes")]), ["Yes"])
    }

    /// Words with nothing in them add nothing: not a space, not a stretch,
    /// and they take nothing away. Between two stretches they leave the first
    /// as it stands for the second to go behind; within one they revise
    /// nothing, and do not settle the partial, which the next result of the
    /// stretch must still replace and never double.
    func testAnEmptyResultBetweenStretchesAddsNothing() {
        let first = beforeThePause.last!
        XCTAssertEqual(
            told([.partial(first), .sign(first), .partial(""), .partial("  "), .partial("And"), .final("And tell me")]),
            [first, first, first, first, "\(first) And", "\(first) And tell me"]
        )
        // Within a stretch: the partial stands, and the next result replaces it.
        XCTAssertEqual(
            told([.partial("Please land the change"), .partial(""), .partial("Please land the change tonight")]),
            ["Please land the change", "Please land the change", "Please land the change tonight"]
        )
        // A sign with no words (a stretch that was only noise) closes the
        // partial that stood, and nothing is added.
        XCTAssertEqual(
            told([.partial("Please land"), .sign(""), .partial("And")]),
            ["Please land", "Please land", "Please land And"]
        )
        // Before anything was said.
        XCTAssertEqual(told([.partial(""), .partial("Please")]), ["", "Please"])
    }

    /// The strip moves with a quiet voice: speech far under full scale still
    /// reads as bars that rise and fall, not a flat line (footplate-ios-05vr).
    /// A fixed range draws this series at its floor; ranged by what the
    /// recording has heard, it stands tall.
    func testTheStripShowsQuietSpeechAsMovingBars() {
        // A quiet voice in measurement mode, in dB below full scale, and a
        // loud one: both move once the window ranges them.
        let quiet: [Float] = [-52, -46, -54, -44, -50, -48, -56, -45, -51, -47, -53, -43, -49, -55, -42, -50]
        let loud: [Float] = [-28, -18, -30, -16, -26, -20, -32, -17, -27, -19, -29, -15, -25, -31, -18, -24]
        for heard in [quiet, loud] {
            let levels = fitted(heard)
            let range = levels.max()! - levels.min()!
            XCTAssertGreaterThan(range, 0.5, "\(heard) reads as \(levels)")
            let settled = levels.suffix(6)
            XCTAssertGreaterThan(settled.max()! - settled.min()!, 0.3, "after the warmup \(heard) reads as \(levels)")
        }
    }

    /// The bars are ranged by what the recording has heard lately: the first
    /// readings read by the fixed range, silence reads 0 and teaches nothing,
    /// gaps between words read low and words high, a cough moves the top no
    /// further than the next reading, and half way up stands at a quarter.
    func testTheStripRangesItsBarsByWhatTheRecordingHasHeard() {
        // Before the window holds enough to range by, the fixed range reads.
        let (first, one) = fit(LevelWindow(), rms: 0.1)
        XCTAssertEqual(one, 0.6, accuracy: 0.0001)
        XCTAssertEqual(first.readings.count, 1)
        XCTAssertEqual(first.readings.first!, -20, accuracy: 0.01)
        var warming = LevelWindow()
        for rms in [0.001, 0.01, 0.1, 0.05, 0.002, 0.2, 0.003, 0.15, 0.008] as [Float] {
            let (next, level) = fit(warming, rms: rms)
            warming = next
            XCTAssertEqual(level, barLevel(rms: rms), accuracy: 0.0001, "nine readings are under the warmup")
        }
        // Silence, and no number: 0, and no place in the window.
        for rms in [0, Float.nan] {
            let (kept, level) = fit(LevelWindow(), rms: rms)
            XCTAssertTrue(kept.readings.isEmpty)
            XCTAssertEqual(level, 0)
        }
        var silent = LevelWindow()
        for _ in 0..<5 { (silent, _) = fit(silent, rms: 0) }
        XCTAssertTrue(silent.readings.isEmpty)
        // A quiet room's wander, narrower than speech: the fixed range reads
        // it as 0 throughout, never stretched to full height.
        let room: [Float] = [-70, -69, -71, -70, -69.5, -70.5, -70, -69, -71, -70, -70, -69.5, -70.5, -70, -69, -71, -70, -69.5, -70.5, -70]
        XCTAssertTrue(fitted(room).allSatisfy { $0 == 0 }, "the room reads as \(fitted(room))")
        // Words and the gaps between them: high and low.
        let talking = (0..<30).map { $0 % 2 == 0 ? Float(-20) : Float(-55) }
        for (index, level) in fitted(talking).enumerated() where index >= 9 {
            if index % 2 == 0 {
                XCTAssertGreaterThan(level, 0.8, "a word reads \(level)")
            } else {
                XCTAssertLessThan(level, 0.2, "a gap reads \(level)")
            }
        }
        // Two coughs among a full window of quiet words: the top stays under
        // them, and the quiet words still range the whole height.
        let words = (0..<58).map { $0 % 2 == 0 ? Float(-52) : Float(-46) }
        let after = fitted(words + [-12, -12, -46, -52]).suffix(2)
        XCTAssertGreaterThan(after.first!, 0.8, "a quiet word after two coughs reads \(after)")
        XCTAssertLessThan(after.last!, 0.2, "the room after two coughs reads \(after)")
        // Half way between the low and the high stands at a quarter.
        let ends = Array(repeating: Float(-50), count: 10) + Array(repeating: Float(-30), count: 10)
        XCTAssertEqual(fitted(ends + [-40]).last!, 0.25, accuracy: 0.01)
        // The window keeps the last sixty readings, and no more.
        var window = LevelWindow()
        for _ in 0..<70 { (window, _) = fit(window, rms: 0.01) }
        XCTAssertEqual(window.readings.count, 60)
    }

    /// The bars: nothing is a floor, full scale is the top, the range between
    /// is in decibels; the strip keeps the newest levels and no more.
    func testTheStripsBarsReadTheSoundInDecibelsAndKeepTheNewest() {
        XCTAssertEqual(barLevel(rms: 0), 0)
        XCTAssertEqual(barLevel(rms: 0.000_1), 0)
        XCTAssertEqual(barLevel(rms: 1), 1)
        XCTAssertEqual(barLevel(rms: 2), 1)
        XCTAssertEqual(barLevel(rms: 0.1), 0.6, accuracy: 0.001)
        XCTAssertEqual(entering(0.5, in: [0.1, 0.2]), [0.1, 0.2, 0.5])
        let full = (0..<barsKept).map { Float($0) }
        let next = entering(99, in: full)
        XCTAssertEqual(next.count, barsKept)
        XCTAssertEqual(next.first, 1)
        XCTAssertEqual(next.last, 99)
    }

    /// The system's statuses are read as the consents of this app, and one
    /// the build does not know gives no leave to record.
    func testTheSystemsStatusesAreReadAsConsents() {
        XCTAssertEqual(consent(SFSpeechRecognizerAuthorizationStatus.notDetermined), .undecided)
        XCTAssertEqual(consent(SFSpeechRecognizerAuthorizationStatus.denied), .denied)
        XCTAssertEqual(consent(SFSpeechRecognizerAuthorizationStatus.restricted), .restricted)
        XCTAssertEqual(consent(SFSpeechRecognizerAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(consent(AVAudioApplication.recordPermission.undetermined), .undecided)
        XCTAssertEqual(consent(AVAudioApplication.recordPermission.denied), .denied)
        XCTAssertEqual(consent(AVAudioApplication.recordPermission.granted), .granted)
    }

    /// An error of a recognition task: the app's own cancel is none, silence
    /// is said by nothing, an error that answers the person's stop leaves
    /// their words as they stand, and any other says that the recognizer
    /// stopped, naming the domain and code it stopped with, or that it is
    /// not available where it no longer is.
    func testWhatARecognitionTaskErrorMeans() {
        let rows: [(String, Int, Bool, Bool, DictationFailure?)] = [
            ("kLSRErrorDomain", 301, false, true, nil),
            ("kLSRErrorDomain", 301, true, false, nil),
            ("kAFAssistantErrorDomain", 1110, false, true, .notHeard),
            ("kAFAssistantErrorDomain", 1110, true, true, .notHeard),
            ("kAFAssistantErrorDomain", 216, true, true, .notHeard),
            ("kAFAssistantErrorDomain", 203, false, true, .stopped(domain: "kAFAssistantErrorDomain", code: 203)),
            ("kAFAssistantErrorDomain", 1101, false, false, .unavailable),
            (SFSpeechErrorDomain, 1, false, true, .stopped(domain: SFSpeechErrorDomain, code: 1)),
            (SFSpeechErrorDomain, 1, false, false, .unavailable),
        ]
        for (domain, code, stopping, available, failure) in rows {
            XCTAssertEqual(
                dictationFailure(domain: domain, code: code, stopping: stopping, available: available),
                failure, "\(domain) \(code) stopping=\(stopping) available=\(available)"
            )
        }
    }

    /// The gate and the recording read the locale each at its own call, never
    /// one remembered: no call is answered from an earlier read. Where the
    /// locale has no recognizer there is no microphone, and `begin()` opens
    /// nothing: no server stands in its place. The gate, the standing and
    /// the recording use the one choice (footplate-ios-sz3n): the current
    /// locale where it hears, else the same language under another region,
    /// over a stubbed hearing list, without the framework's supported set.
    func testThePhoneReadsTheLocaleAtEachCallAndWhereItHasNoRecognizerThereIsNoMicrophone() {
        let reads = Reads()
        let unsupported = SpeechDictation(locale: {
            reads.count += 1
            return Locale(identifier: "zz_ZZ")
        })
        XCTAssertFalse(unsupported.standing().onDevice)
        XCTAssertEqual(reads.count, 1)
        XCTAssertFalse(unsupported.standing().onDevice)
        XCTAssertEqual(reads.count, 2)
        XCTAssertThrowsError(try unsupported.begin()) { error in
            XCTAssertEqual(error as? DictationFailure, .unavailable)
        }
        XCTAssertEqual(reads.count, 3)

        // A locale the phone has a recognizer for says what that recognizer
        // says of hearing on the device, whatever this simulator holds.
        let english = Locale(identifier: "en_US")
        let said = SFSpeechRecognizer(locale: english)?.supportsOnDeviceRecognition ?? false
        let phone = SpeechDictation(locale: { english })
        XCTAssertEqual(phone.standing().onDevice, said)

        // A region variant falls back to the same language where that hears:
        // the standing says what the chosen recognizer says, whatever this
        // simulator holds, and names the current locale's language.
        let fellBack = SpeechDictation(
            locale: { Locale(identifier: "en_GB") },
            hearing: { _ in [Locale(identifier: "en-US")] }
        )
        let american = Locale(identifier: "en-US")
        XCTAssertEqual(
            fellBack.standing().onDevice,
            SFSpeechRecognizer(locale: american)?.supportsOnDeviceRecognition ?? false
        )
        XCTAssertEqual(fellBack.standing().language, "English")

        // Nothing heard anywhere: no microphone, and `begin()` opens nothing.
        // The hearing list is read at each call, never kept, as the locale is.
        let lists = Reads()
        let unheard = SpeechDictation(
            locale: { Locale(identifier: "en_US") },
            hearing: { _ in
                lists.count += 1
                return []
            }
        )
        XCTAssertFalse(unheard.standing().onDevice)
        XCTAssertEqual(lists.count, 1)
        XCTAssertFalse(unheard.standing().onDevice)
        XCTAssertEqual(lists.count, 2)
        XCTAssertThrowsError(try unheard.begin()) { error in
            XCTAssertEqual(error as? DictationFailure, .unavailable)
        }
        XCTAssertEqual(lists.count, 3)
    }

    /// The levels a series of dB readings gives through one window.
    private func fitted(_ heard: [Float]) -> [Float] {
        var window = LevelWindow()
        return heard.map { db in
            let (next, level) = fit(window, rms: pow(10, db / 20))
            window = next
            return level
        }
    }
}

/// How often a locale was read, from whatever queue reads it.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var count: Int {
        get { lock.withLock { reads } }
        set { lock.withLock { reads = newValue } }
    }
}
