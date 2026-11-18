import Foundation

// Dictation in the composer (footplate-ios-tedd), as footplate-android's
// voice/Voice.kt has it for the phone's own recognizer: a tap on the
// microphone writes what the person says into the field, heard on this
// device and nowhere else, so that nothing goes to the yard until the
// letter is sent. The recognizer and the microphone stand behind
// `Dictation`, as the unlock prompt stands behind `UnlockPrompt`: the gate,
// the words and the recording's state machine are unit tests on the
// simulator, whose microphone is the Mac's, which may have none, and which
// may hold no on-device model; the recognizer's prompts and engine are
// walked by hand in a simulator (FootplateUITests/DictationScreenTests) and
// its words checked by hand on an iPhone (footplate-ios-txgy). What dictation
// hears with is the current locale where it hears on the device, else the
// same language under another region (footplate-ios-sz3n): a language heard
// under another region is still that language on this device. Where none of
// the language hears there is no microphone, never a server in its place,
// and the composer says so once, naming the language, instead of showing
// nothing.

/// Where one of the two consents dictation needs stands: speech
/// recognition and the microphone. Only speech reports a restriction; a
/// microphone the device does not allow is reported as denied.
enum Consent: Equatable, Sendable {
    /// Never asked: the microphone's tap asks.
    case undecided
    case granted
    case denied
    /// The device does not allow it (a profile, parental controls).
    case restricted
}

/// What the phone offers dictation, read at one moment: nothing of it is
/// kept across a tap, a launch or a model download, for any of it can
/// change between two reads.
struct DictationStanding: Equatable, Sendable {
    /// What dictation hears with hears on the device: the current locale
    /// where it does, else the same language under another region.
    var onDevice: Bool
    var speech: Consent
    var microphone: Consent
    /// The current locale's language in words for the person ("English"),
    /// for the line where none of it hears. Nil where it is not known, and
    /// the gate then says nothing, as before.
    var language: String? = nil
}

/// Which consent a refusal names.
enum Refusal: Equatable, Sendable {
    case speechDenied
    case speechRestricted
    case microphoneDenied
}

/// What the composer draws for dictation: the gate.
enum DictationGate: Equatable, Sendable {
    /// Nothing: the phone does not hear on the device (no model for the
    /// language, or none installed yet), and the language to name is not
    /// known, so it says nothing about it.
    case absent
    /// No microphone: none of the phone's language hears on the device, and
    /// one quiet line says so, naming the language. The model tells it once
    /// per conversation open; the gate only names it.
    case unheard(language: String)
    /// The microphone: a tap records, asking first for any consent that is
    /// not decided.
    case offered
    /// No microphone: a line says which consent is refused, with a link to
    /// Settings.
    case refused(Refusal)
}

/// The gate for `standing`. Hearing on the device comes first: where the
/// phone cannot, a refusal would name a consent that makes no difference.
/// Speech is named before the microphone, as it is asked before it.
func dictationGate(_ standing: DictationStanding) -> DictationGate {
    guard standing.onDevice else {
        if let language = standing.language { return .unheard(language: language) }
        return .absent
    }
    switch standing.speech {
    case .denied: return .refused(.speechDenied)
    case .restricted: return .refused(.speechRestricted)
    case .undecided, .granted: break
    }
    switch standing.microphone {
    case .denied, .restricted: return .refused(.microphoneDenied)
    case .undecided, .granted: return .offered
    }
}

/// Whether a tap has a prompt to show: a consent that was never asked.
func dictationAsks(_ standing: DictationStanding) -> Bool {
    standing.speech == .undecided || standing.microphone == .undecided
}

/// What dictation hears with: the current locale where it hears on the
/// device, else the first of `hearing` with the same language that does.
/// `hearing` holds the locales that hear on the device now, in whatever
/// order the framework's set comes in; the choice is fixed all the same:
/// the language's likely region first (de_DE, ja_JP), then the US one,
/// then the rest by identifier. A language heard under another region is
/// still that language on this device. Nil where none of the language
/// hears, and the composer says so instead of offering the microphone.
/// Locales compare by BCP 47 (`en_US` is `en-US`): the framework spells its
/// own with a hyphen.
func dictationLocale(current: Locale, hearing: [Locale]) -> Locale? {
    func tag(_ locale: Locale) -> String { locale.identifier(.bcp47) }
    if hearing.contains(where: { tag($0) == tag(current) }) { return current }
    guard let language = current.language.languageCode?.identifier else { return nil }
    let tags = Set(hearing.filter { $0.language.languageCode?.identifier == language }.map(tag))
    let likelyRegion = Locale(identifier: Locale.Language(identifier: language).maximalIdentifier)
        .region?.identifier
    func rank(_ tag: String) -> Int {
        let region = Locale(identifier: tag).region?.identifier ?? ""
        if let likelyRegion, region.compare(likelyRegion, options: .caseInsensitive) == .orderedSame { return 0 }
        if region.compare("US", options: .caseInsensitive) == .orderedSame { return 1 }
        return 2
    }
    let ranked = tags.map { ($0, rank($0)) }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
    return ranked.first.map { Locale(identifier: $0.0) }
}

/// The line beside the composer at a tap that asks for a consent: what is
/// heard, where it goes, and when the microphone is open. Written for the
/// iPad as for the iPhone, and pinned by the bead. It stands behind the
/// system's speech prompt, whose own paragraph says the speech data is sent
/// to Apple (shown for on-device requests too, and not ours to change), so
/// it says that nothing goes to Apple, as the prompt's usage string does.
let dictationLine = "What you say is heard on this device, and the words are written into the field. Nothing goes to the yard until you send it, and nothing goes to Apple — the hearing happens on this device. footplate opens the microphone only while you record."

/// The line for a refused consent, naming which one it is.
func refusalWords(_ refusal: Refusal) -> String {
    switch refusal {
    case .speechDenied:
        return "Speech recognition is off for footplate: allow it in Settings to dictate."
    case .speechRestricted:
        return "This device does not allow speech recognition, so dictation stays off."
    case .microphoneDenied:
        return "The microphone is off for footplate: allow it in Settings to dictate."
    }
}

/// The line where none of the language hears on the device, naming it and
/// that the device cannot hear it without a server. No microphone stands
/// with it, and no link to Settings: no consent would help.
func unheardWords(_ language: String) -> String {
    "This device cannot hear \(language) without a server, so dictation stays off."
}

/// Where a recording stands.
enum Recording: Equatable, Sendable {
    /// The tap is asking for a consent, or the microphone is opening: the
    /// strip stands and its stop waits.
    case starting
    /// The microphone is open and the words arrive in the field.
    case listening
    /// The stop, or a send, was tapped: the microphone is shut and the
    /// recognizer settles the words it heard.
    case finishing
}

/// Why a recording did not go on, in the few cases that differ for the
/// person: nothing is said of silence.
enum DictationFailure: Error, Equatable, Sendable {
    /// Nothing was heard that the recognizer took for speech.
    case notHeard
    /// The microphone would not open (another sound holds it, or there is
    /// no input to record from).
    case couldNotStart
    /// The recognizer cannot hear just now: its model is gone, its service
    /// is down, or the phone's limit for it is used.
    case unavailable
    /// The recognizer stopped for a reason this app has no words for: the
    /// error's domain and code ride along, so that the line under the field
    /// can name them and a person on a real device can tell us what the
    /// recognizer said (footplate-ios-p2py: a stop at once on an iPad whose
    /// cause nobody could name, the domain and code dropped). The line also
    /// tells what primes a device that has never dictated: one dictation
    /// from the keyboard's microphone (footplate-ios-f8bt: the iPad's stop
    /// went away after that first keyboard dictation, and the SDK offers no
    /// call that asks for the on-device model or says it is missing).
    case stopped(domain: String, code: Int)

    /// What is said under the field, none for silence.
    var words: String? {
        switch self {
        case .notHeard: return nil
        case .couldNotStart: return "The microphone could not start; tap it to try again."
        case .unavailable: return "Speech recognition is not available just now; try again in a little while."
        case .stopped(let domain, let code): return "Speech recognition stopped (\(domain) \(code)); tap the microphone to try again. If this device has never dictated from the keyboard, dictate once from the keyboard's microphone first."
        }
    }
}

/// What a recording says, in the order it happens; the stream ends where
/// the recording does.
enum DictationEvent: Equatable, Sendable {
    /// Everything heard since the recording began, whole: each says the
    /// whole again, with the earlier words revised where the recognizer
    /// has changed its mind. `final` where the recognizer has settled them
    /// and will say no more.
    case words(String, final: Bool)
    /// How loud the microphone hears, 0 to 1, for the strip's bars.
    case level(Float)
    /// The microphone was taken from the recording: a call, another app, a
    /// route that is gone. What was heard stands.
    case interrupted
    /// The recognizer stopped.
    case failed(DictationFailure)
}

/// The recognizer and the microphone of the phone.
@MainActor
protocol Dictation {
    /// The phone's standing now, read from the system each time it is
    /// asked: the locale is the system's current one at this moment, and
    /// nothing is kept for the next read.
    func standing() -> DictationStanding

    /// Asks for each consent that is not decided, speech recognition first
    /// and the microphone after it, and stops at the first refusal. The
    /// standing after the prompts.
    func authorize() async -> DictationStanding

    /// Opens the microphone and begins recognising, on a recognizer made
    /// now for the locale now. Throws where it cannot, the microphone left
    /// shut. Called only by a tap: nothing is made ready before it.
    func begin() throws -> any DictationRun
}

/// One recording, from `begin()` to its end.
@MainActor
protocol DictationRun: AnyObject {
    var events: AsyncStream<DictationEvent> { get }

    /// The microphone is shut now, and the recognizer settles what it heard:
    /// its final words come on `events`.
    func finish()

    /// The microphone is shut now and the recognition is dropped, nothing
    /// more said. Safe after the recording has ended in any way.
    func cancel()
}

/// The draft with the words heard after it, a space between the two where
/// the draft does not end in one. Words with nothing in them add nothing.
func dictated(_ base: String, _ words: String) -> String {
    let said = words.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !said.isEmpty else { return base }
    guard let last = base.last, !last.isWhitespace else { return base + said }
    return base + " " + said
}

/// How loud a sound is for the strip's bars, 0 (quiet) to 1: its
/// root-mean-square amplitude in decibels, 50 dB below full scale and
/// under being 0.
func barLevel(rms: Float) -> Float {
    guard rms > 0 else { return 0 }
    return min(1, max(0, (20 * log10(rms) + 50) / 50))
}

/// What one recording has heard lately of the microphone's sound, in
/// decibels below full scale: its last readings, oldest first. The level
/// the tap hears is its own and differs by device, by distance and by
/// voice: a fixed range draws quiet speech at the floor, so the bars are
/// ranged by what the recording itself has heard, as Android's `fit` ranges
/// them (footplate-android's Dictation.kt). Lately, and not over the whole
/// recording: its lowest and highest are the room and the loudest cough,
/// and between them a loud word and a quiet one stand alike. The recording
/// holds this and it goes with the recording.
struct LevelWindow: Equatable, Sendable {
    var readings: [Float] = []
}

/// The level of a sound heard at `rms` against what its recording has heard
/// lately (`heard`), from 0 to 1 for the strip's bars, and what the
/// recording has heard once it is counted in.
///
/// The range is the window's own: its low is the 20th percentile of the
/// readings and its high the 95th, each by nearest rank, and a reading is
/// placed between them. What lies under the low reads 0, so the room and
/// the gaps between words are short bars, and a word stands as tall as it
/// is loud among the rest. The percentiles hold out against a cough: a few
/// readings far over the rest move an end only to the next reading in line,
/// where a highest would follow them and flatten the words after. A quiet
/// word stands under two thirds of a loud one's height, and on a straight
/// line it stands over that, so the place is bent.
///
/// The fixed range of `barLevel` reads where the window has too little to
/// range by: before it holds 10 readings (the first half-second of a
/// recording), and where its low and high are closer than 3 dB, a quiet
/// room's own wander, which ranged would be stretched to the bars' full
/// height.
///
/// A reading that is silence, or no number, reads 0, teaches nothing and
/// takes no place in the window.
func fit(_ heard: LevelWindow, rms: Float) -> (LevelWindow, Float) {
    let db = 20 * log10(rms)
    guard db.isFinite else { return (heard, 0) }
    let window = LevelWindow(readings: Array((heard.readings + [db]).suffix(levelWindowSize)))
    guard window.readings.count >= levelWarmup else { return (window, barLevel(rms: rms)) }
    let sorted = window.readings.sorted()
    let low = sorted[(levelLowPercent * sorted.count + 99) / 100 - 1]
    let high = sorted[(levelHighPercent * sorted.count + 99) / 100 - 1]
    guard high - low >= levelSpan else { return (window, barLevel(rms: rms)) }
    let place = min(1, max(0, (db - low) / (high - low)))
    return (window, pow(place, levelBend))
}

/// "Lately": the readings the window keeps, about three seconds of tap
/// buffers. It counts readings and not time, so a tap that delivers faster
/// fills it sooner.
private let levelWindowSize = 60

/// The readings the window must hold before it ranges anything: the first
/// half-second at the tap's rate.
private let levelWarmup = 10

/// The window's low and high, as percentiles. The low falls among the quiet
/// readings, where the room and the gaps between words are, so they read 0.
/// The high falls under the loudest few, so a cough stands over it and moves
/// it no further than the next reading.
private let levelLowPercent = 20
private let levelHighPercent = 95

/// "A few decibels": the width under which the low and the high are taken for
/// a quiet room's wander and not for speech.
private let levelSpan: Float = 3

/// The exponent of the bend between the low and the high, above 1 so that the
/// curve lies under the straight line: a reading half way up stands at a
/// quarter. DictationTests holds the heights it gives a series of loud words,
/// quiet words and gaps.
private let levelBend: Float = 2

/// How many levels the strip keeps: more than it draws on the widest phone.
let barsKept = 64

/// `levels` with `level` entering at the right, the oldest leaving.
func entering(_ level: Float, in levels: [Float]) -> [Float] {
    Array((levels + [level]).suffix(barsKept))
}
