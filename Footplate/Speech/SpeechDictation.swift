import AVFoundation
import Foundation
import Speech

// The phone's recognizer behind `Dictation` (footplate-ios-tedd):
// SFSpeechRecognizer for what dictation hears with, asked to hear on the
// device alone, fed by an AVAudioEngine whose microphone is open only while
// a recording stands. What it hears with is the system's current locale
// where that hears on the device, else the same language under another
// region (footplate-ios-sz3n). Nothing here is made before a tap: no
// recognizer is kept, no engine is prepared, and the audio session is taken
// at `begin()` and given back where the recording ends, whatever ended it.

/// The one request the recognizer is ever given: heard on the device
/// alone, with the words as they come, tuned for dictation. Every request
/// is made here, so that the unit test that holds `requiresOnDeviceRecognition`
/// holds them all. The SDK says a request honours the flag only where the
/// recognizer supports hearing on the device, which is why `begin()` checks
/// that on the recognizer it hands this request to, and fails where it does
/// not.
func dictationRequest() -> SFSpeechAudioBufferRecognitionRequest {
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    // A letter is written, so the full stops and commas come with the words.
    request.addsPunctuation = true
    return request
}

func consent(_ status: SFSpeechRecognizerAuthorizationStatus) -> Consent {
    switch status {
    case .notDetermined: return .undecided
    case .denied: return .denied
    case .restricted: return .restricted
    case .authorized: return .granted
    // A status this build does not know gives no leave to record.
    @unknown default: return .denied
    }
}

func consent(_ permission: AVAudioApplication.recordPermission) -> Consent {
    switch permission {
    case .undetermined: return .undecided
    case .denied: return .denied
    case .granted: return .granted
    @unknown default: return .denied
    }
}

/// What an error of a recognition task means, nil where it is no failure:
/// the task was cancelled by the app. Silence is the recognizer's 1110, and
/// any error that answers the person's own stop leaves the words that
/// stand as they are. Any other says it stopped, naming the domain and
/// code it stopped with, or that the recognizer is not available where it
/// no longer is (a limit of the phone, the SDK's header says, shows as a
/// request that fails within a second or two of starting).
func dictationFailure(domain: String, code: Int, stopping: Bool, available: Bool) -> DictationFailure? {
    if domain == "kLSRErrorDomain", code == 301 { return nil }
    if domain == "kAFAssistantErrorDomain", code == 1110 { return .notHeard }
    if stopping { return .notHeard }
    return available ? .stopped(domain: domain, code: code) : .unavailable
}

/// What one recording has heard, told by the stretches the recognizer divides
/// it into (footplate-ios-wg9q). On the iOS 26.3 simulator, a non-final result
/// with speech metadata marked a closed stretch; subsequent results, including
/// the final, then carried only the new stretch. A pause near two seconds did
/// not close every time, so the recording is the stretches put together when
/// the recognizer closes them, with a guard for a reset that has no sign.
struct Transcript: Equatable, Sendable {
    /// The stretches that are over, in the order they were said, with one
    /// space between.
    var settled = ""
    /// The stretch that stands: the text of its last result, which the next
    /// result of the stretch revises.
    var partial = ""

    /// Everything heard, whole.
    var text: String { joined(settled, partial) }

    fileprivate mutating func settle() {
        settled = joined(settled, partial)
        partial = ""
    }
}

/// `transcript` with the next result's `text` taken in. A result revises the
/// stretch that stands and replaces its partial. `closes` says the recognizer
/// ended the stretch with it (a result that is not final and carries the
/// speech's metadata, or a final): its text is then settled, and the next
/// result begins a stretch behind it.
///
/// Where the recognizer begins a stretch with no such sign, the result is not
/// a revision (`startsAfresh`) and the partial is settled before it is taken.
/// Words with nothing in them revise nothing: the partial stands, and is
/// settled if the result closes the stretch, as a final of silence after words
/// were shown must leave them. Stretches are trimmed, so that one space joins
/// them and an empty one adds nothing.
func fold(_ transcript: Transcript, text: String, closes: Bool) -> Transcript {
    var next = transcript
    let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !said.isEmpty {
        if startsAfresh(said, after: transcript.partial) { next.settle() }
        next.partial = said
    }
    if closes { next.settle() }
    return next
}

/// Whether `text` begins a stretch afresh instead of revising `partial`, for
/// a recognizer that went back to the start at a pause and sent no sign. Both
/// must hold. It is much shorter, under half the characters: the recognizer
/// revises the last words of a partial, not most of it, and the first result
/// of a new stretch is a word or two. And it starts with another word, so a
/// partial cut back to its own first words is still a revision. A partial
/// under `resetFloor` is never settled here. A start missed costs the words
/// before it, as before the fold; one found by mistake would put a stretch
/// into the letter twice, so the guard errs toward missing. A script written
/// without spaces has the whole text for its first word, so for it the length
/// alone decides.
private func startsAfresh(_ text: String, after partial: String) -> Bool {
    guard partial.count >= resetFloor, text.count * 2 < partial.count else { return false }
    return leadingWord(text) != leadingWord(partial)
}

/// The first word of `text`, lowercased and without its punctuation, so that
/// "Hello," and "hello" are the same word. Empty where no word has a letter
/// or a digit.
private func leadingWord(_ text: String) -> String {
    for token in text.split(whereSeparator: \.isWhitespace) {
        let word = token.filter { $0.isLetter || $0.isNumber }.lowercased()
        if !word.isEmpty { return word }
    }
    return ""
}

/// `head` and `tail` with one space between, where neither is empty.
private func joined(_ head: String, _ tail: String) -> String {
    if head.isEmpty { return tail }
    if tail.isEmpty { return head }
    return head + " " + tail
}

/// The shortest partial `startsAfresh` can settle. Under it a partial is a
/// word or two, which the recognizer may still rewrite whole ("forty two" to
/// "42"), and settling that would double it.
private let resetFloor = 12

/// The locales that hear on the device now among `current`'s language: the
/// framework's supported ones of that language that do, with `current`
/// itself where it does (it may hear under the framework's remap, as en_CH
/// hears as en-US). Read at each call, never kept: a model download changes
/// the answer. The current locale is asked first, so the common case costs
/// one recognizer, as before; the supported ones are read only where it does
/// not hear.
func hearingLocales(current: Locale) -> [Locale] {
    if SFSpeechRecognizer(locale: current)?.supportsOnDeviceRecognition == true {
        return [current]
    }
    let language = current.language.languageCode?.identifier
    return SFSpeechRecognizer.supportedLocales().filter {
        $0.language.languageCode?.identifier == language
            && SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true
    }
}

/// `locale`'s language in words for the person ("English"), for the line
/// where none of it hears: its localized name, else its code, else the
/// locale itself, so that there is always a word to name.
func displayLanguage(_ locale: Locale) -> String {
    let code = locale.language.languageCode?.identifier
    if let code, let name = locale.localizedString(forLanguageCode: code) { return name }
    return code ?? locale.identifier
}

@MainActor
final class SpeechDictation: Dictation {
    private let locale: @Sendable () -> Locale
    private let hearing: @Sendable (Locale) -> [Locale]

    /// `locale` is read at each call, never kept: the system's current one.
    /// `hearing` names the locales that hear on the device for it, read at
    /// each call too: the framework's supported ones, in the tests a stub.
    init(
        locale: @escaping @Sendable () -> Locale = { Locale.current },
        hearing: (@Sendable (Locale) -> [Locale])? = nil
    ) {
        self.locale = locale
        self.hearing = hearing ?? { @Sendable (current: Locale) in hearingLocales(current: current) }
    }

    /// What dictation hears with now, chosen from the locale as it is then:
    /// the current one where it hears on the device, else the same language
    /// under another region.
    private func chosen(current: Locale) -> Locale? {
        dictationLocale(current: current, hearing: hearing(current))
    }

    /// The recognizer of what dictation hears with now. The gate reads it
    /// and `begin()` hands its request to one, each made from the locale as
    /// it is then.
    private func recognizer() -> SFSpeechRecognizer? {
        recognizer(current: locale())
    }

    private func recognizer(current: Locale) -> SFSpeechRecognizer? {
        chosen(current: current).flatMap { SFSpeechRecognizer(locale: $0) }
    }

    func standing() -> DictationStanding {
        let current = locale()
        return DictationStanding(
            onDevice: recognizer(current: current)?.supportsOnDeviceRecognition ?? false,
            speech: consent(SFSpeechRecognizer.authorizationStatus()),
            microphone: consent(AVAudioApplication.shared.recordPermission),
            language: displayLanguage(current)
        )
    }

    func authorize() async -> DictationStanding {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await askSpeech()
        }
        // The microphone is asked only where speech was not refused: one
        // refusal is the answer, and the second prompt would ask for
        // nothing the person has left to use.
        if consent(SFSpeechRecognizer.authorizationStatus()) == .granted,
           AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        return standing()
    }

    func begin() throws -> any DictationRun {
        // Hearing on the device, on this very recognizer: the chosen one,
        // for which the request is made below and never for another.
        guard let recognizer = recognizer(), recognizer.supportsOnDeviceRecognition else {
            throw DictationFailure.unavailable
        }
        guard recognizer.isAvailable else { throw DictationFailure.unavailable }
        let request = dictationRequest()
        guard request.requiresOnDeviceRecognition else { throw DictationFailure.unavailable }
        let run = SpeechRun(recognizer: recognizer, request: request)
        try run.start()
        return run
    }
}

/// The speech prompt, away from the main actor: the system answers it on
/// a queue of its own, which a closure made here would be isolated against.
private func askSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
}

/// What reaches a run from the recognizer, the microphone and the audio
/// session, in one stream so that it is handled in the order it happened.
private enum Heard: Sendable {
    /// `closes`: the recognizer closed a stretch with this result, at a pause.
    case words(String, closes: Bool, final: Bool)
    case sound(Float)
    case failure(domain: String, code: Int)
    case interrupted
}

/// One recording. The microphone feeds the request; the recognizer's
/// results come back through `heard`, and are told to the model as
/// `DictationEvent`s. The words are told whole, as `DictationEvent.words`
/// says, though the recognizer's own text is only the stretch since its last
/// pause: the run puts the stretches together (`Transcript`). The run ends
/// at its first final, failure or interruption, at `cancel()`, and the
/// microphone is shut and the audio session given back before its stream
/// finishes.
@MainActor
final class SpeechRun: DictationRun {
    let events: AsyncStream<DictationEvent>
    private let out: AsyncStream<DictationEvent>.Continuation
    private let heard: AsyncStream<Heard>
    private let heardIn: AsyncStream<Heard>.Continuation
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let capture = Capture()
    private var task: SFSpeechRecognitionTask?
    private var pump: Task<Void, Never>?
    private var interruption: NSObjectProtocol?
    private var stopping = false
    private var over = false
    private var sessionHeld = false
    private var window = LevelWindow()
    private var transcript = Transcript()

    init(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest) {
        self.recognizer = recognizer
        self.request = request
        (events, out) = AsyncStream<DictationEvent>.makeStream()
        (heard, heardIn) = AsyncStream<Heard>.makeStream()
    }

    /// Opens the microphone. A run that throws here is over: its microphone
    /// shut, its session given back.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            end()
            throw DictationFailure.couldNotStart
        }
        sessionHeld = true
        let heardIn = self.heardIn
        // The task before the engine: the request takes what the microphone
        // gives from its first buffer.
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results(heardIn))
        do {
            try capture.start(
                feeding: request,
                sound: { heardIn.yield(.sound($0)) },
                configurationChanged: { heardIn.yield(.interrupted) }
            )
        } catch {
            end()
            throw DictationFailure.couldNotStart
        }
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began {
                heardIn.yield(.interrupted)
            }
        }
        let heard = self.heard
        pump = Task { @MainActor [weak self] in
            for await one in heard { self?.receive(one) }
        }
    }

    /// The recognizer's handler, made away from the main actor: it is
    /// called on a queue of the framework's, and what it holds is only the
    /// stream it tells.
    nonisolated private static func results(
        _ heardIn: AsyncStream<Heard>.Continuation
    ) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let result {
                // The sign of a stretch closed at a pause: a result that is
                // not final and carries the speech's metadata. On an iOS 26.3
                // simulator hearing en-US on the device it came once for each
                // closed stretch, with that stretch's words, ahead of the
                // first result of the next, and no other partial carried it
                // (footplate-ios-wg9q).
                let closes = !result.isFinal && result.speechRecognitionMetadata != nil
                heardIn.yield(.words(
                    result.bestTranscription.formattedString, closes: closes, final: result.isFinal
                ))
            }
            if result?.isFinal != true, let error = error as NSError? {
                heardIn.yield(.failure(domain: error.domain, code: error.code))
            }
        }
    }

    private func receive(_ one: Heard) {
        guard !over else { return }
        switch one {
        case .sound(let rms):
            if !stopping {
                let (window, level) = fit(window, rms: rms)
                self.window = window
                out.yield(.level(level))
            }
        case .words(let text, let closes, let final):
            // A final settles its stretch too: it is the last, and goes
            // through the same fold as the rest.
            transcript = fold(transcript, text: text, closes: closes || final)
            // A partial with no words is not told: the words that stand,
            // told again, would start the model's quiet timer over, which an
            // empty result did not.
            if final || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.yield(.words(transcript.text, final: final))
            }
            if final { end() }
        case .failure(let domain, let code):
            if let failure = dictationFailure(
                domain: domain, code: code, stopping: stopping, available: recognizer.isAvailable
            ) {
                out.yield(.failed(failure))
            }
            end()
        case .interrupted:
            out.yield(.interrupted)
            end()
        }
    }

    func finish() {
        guard !over, !stopping else { return }
        stopping = true
        capture.stop()
        request.endAudio()
    }

    func cancel() {
        end()
    }

    private func end() {
        guard !over else { return }
        over = true
        capture.stop()
        if !stopping { request.endAudio() }
        task?.cancel()
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        if sessionHeld {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionHeld = false
        }
        pump?.cancel()
        heardIn.finish()
        out.finish()
    }
}

/// The microphone: an audio engine whose input feeds the recognition
/// request and the strip's bars. Made and used away from the main actor, as
/// the tap runs on the audio thread, which a closure isolated to the main
/// actor would trap on.
private final class Capture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var running = false
    private var configuration: NSObjectProtocol?

    func start(
        feeding request: SFSpeechAudioBufferRecognitionRequest,
        sound: @escaping @Sendable (Float) -> Void,
        configurationChanged: @escaping @Sendable () -> Void
    ) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // No input to record from (a simulator with no microphone, a route
        // that is gone) is a format the tap would trap on.
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationFailure.couldNotStart }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            request.append(buffer)
            sound(Self.rms(buffer))
        }
        configuration = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in configurationChanged() }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            removeObserver()
            throw DictationFailure.couldNotStart
        }
        lock.withLock { running = true }
    }

    /// The microphone is shut. Safe to call again.
    func stop() {
        let was = lock.withLock { () -> Bool in
            defer { running = false }
            return running
        }
        guard was else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        removeObserver()
    }

    private func removeObserver() {
        if let configuration { NotificationCenter.default.removeObserver(configuration) }
        configuration = nil
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count { sum += channel[index] * channel[index] }
        return (sum / Float(count)).squareRoot()
    }
}
