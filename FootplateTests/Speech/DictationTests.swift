@testable import Footplate
import AVFoundation
import Speech
import XCTest

// Dictation's plain pieces (footplate-ios-tedd, after Android's
// VoiceTest.kt): which gate the phone's standing gives the composer, the
// words said at each state, the one request every recognition is made with,
// the words the draft takes, the bars' levels, and the phone's recognizer
// read per call for the locale of that call. The recording's state machine
// is in ConversationModelTests, over `FakeDictation`; what the recognizer
// does with a real microphone is checked by hand on an iPhone
// (footplate-ios-txgy), a simulator's being the Mac's.
@MainActor
final class DictationTests: XCTestCase {
    private func standing(_ onDevice: Bool, _ speech: Consent, _ microphone: Consent) -> DictationStanding {
        DictationStanding(onDevice: onDevice, speech: speech, microphone: microphone)
    }

    /// The microphone is drawn only where the phone hears on the device, and
    /// not where a consent is refused; where it cannot hear there, no word
    /// of a refusal is said, as no consent would help. Speech is named
    /// before the microphone, as it is asked first.
    func testTheGateOffersTheMicrophoneOnlyWhereThePhoneHearsOnTheDeviceAndNoConsentIsRefused() {
        let rows: [(DictationStanding, DictationGate)] = [
            (standing(false, .granted, .granted), .absent),
            (standing(false, .denied, .denied), .absent),
            (standing(false, .undecided, .undecided), .absent),
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
    /// consent it is; silence says nothing and every other failure says
    /// something.
    func testTheWordsAreThePinnedOnesAndEachRefusalSaysWhichConsent() {
        XCTAssertEqual(
            dictationLine,
            "What you say is heard on this device, and the words are written into the field. Nothing goes to the yard until you send it, and nothing goes to Apple — the hearing happens on this device. Footplate opens the microphone only while you record."
        )
        for device in ["iPhone", "iPad", "tablet", " phone"] {
            XCTAssertFalse(dictationLine.contains(device), device)
        }
        XCTAssertTrue(refusalWords(.speechDenied).contains("Speech recognition"))
        XCTAssertTrue(refusalWords(.speechDenied).contains("Settings"))
        XCTAssertTrue(refusalWords(.speechRestricted).contains("speech recognition"))
        XCTAssertTrue(refusalWords(.microphoneDenied).contains("microphone"))
        XCTAssertTrue(refusalWords(.microphoneDenied).contains("Settings"))
        XCTAssertEqual(Set([Refusal.speechDenied, .speechRestricted, .microphoneDenied].map(refusalWords)).count, 3)
        XCTAssertNil(DictationFailure.notHeard.words)
        for failure in [DictationFailure.couldNotStart, .unavailable, .stopped] {
            XCTAssertFalse(try XCTUnwrap(failure.words).isEmpty, "\(failure)")
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
    /// stopped, or that it is not available where it no longer is.
    func testWhatARecognitionTaskErrorMeans() {
        let rows: [(String, Int, Bool, Bool, DictationFailure?)] = [
            ("kLSRErrorDomain", 301, false, true, nil),
            ("kLSRErrorDomain", 301, true, false, nil),
            ("kAFAssistantErrorDomain", 1110, false, true, .notHeard),
            ("kAFAssistantErrorDomain", 1110, true, true, .notHeard),
            ("kAFAssistantErrorDomain", 216, true, true, .notHeard),
            ("kAFAssistantErrorDomain", 203, false, true, .stopped),
            ("kAFAssistantErrorDomain", 1101, false, false, .unavailable),
            (SFSpeechErrorDomain, 1, false, true, .stopped),
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
    /// nothing: no server stands in its place.
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
