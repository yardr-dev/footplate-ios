@testable import Footplate
import Foundation

// The phone's recognizer and microphone as a test drives them
// (footplate-ios-tedd): what the phone offers is a value the test sets, the
// prompts answer as the test says and can be held where they stand, and a
// recording says what the test makes it say. A simulator's microphone is
// the Mac's, which may have none, and it may hold no on-device model, so the
// gate, the words and the state machine are driven through here; the real
// recognizer is walked by hand (FootplateUITests/DictationScreenTests) and
// checked on an iPhone (footplate-ios-txgy). The fake
// counts what the engine would do: `begun` microphones opened, `stopped`
// microphones shut, and a recording that is never begun is never counted.
@MainActor
final class FakeDictation: Dictation {
    /// What the phone offers now; a test changes it between reads.
    var current = DictationStanding(onDevice: true, speech: .granted, microphone: .granted)
    /// What a prompt becomes where the person answers it.
    var speechAnswer: Consent = .granted
    var microphoneAnswer: Consent = .granted
    /// Holds the prompts where they stand until `answerPrompts()`.
    var holdPrompts = false
    /// What `begin()` throws, where it should.
    var beginFails: DictationFailure? = nil
    /// Runs as `begin()` is called, before it answers: the phone changing
    /// its mind between a tap's read and its recording.
    var whenBegun: (@MainActor () -> Void)? = nil

    /// The prompts shown, in the order shown.
    private(set) var asked: [String] = []
    private(set) var standingReads = 0
    private(set) var begun = 0
    fileprivate(set) var stopped = 0
    private(set) var runs: [FakeRun] = []
    private var held: CheckedContinuation<Void, Never>?

    func standing() -> DictationStanding {
        standingReads += 1
        return current
    }

    func authorize() async -> DictationStanding {
        if holdPrompts { await withCheckedContinuation { held = $0 } }
        if current.speech == .undecided {
            asked.append("speech")
            current.speech = speechAnswer
        }
        if current.speech == .granted, current.microphone == .undecided {
            asked.append("microphone")
            current.microphone = microphoneAnswer
        }
        return current
    }

    func begin() throws -> any DictationRun {
        whenBegun?()
        if let beginFails { throw beginFails }
        begun += 1
        let run = FakeRun(owner: self)
        runs.append(run)
        return run
    }

    /// The person answers the prompts that stand.
    func answerPrompts() {
        held?.resume()
        held = nil
    }

    /// The recording last begun.
    var run: FakeRun { runs[runs.count - 1] }
}

/// One recording. The test is the recognizer: it says words, the sound's
/// level, an interruption or a failure, and the run shuts its microphone
/// where the real one does: at a stop, a cancel, a final, a failure or an
/// interruption, once.
@MainActor
final class FakeRun: DictationRun {
    let events: AsyncStream<DictationEvent>
    private let continuation: AsyncStream<DictationEvent>.Continuation
    private unowned let owner: FakeDictation
    private(set) var finishes = 0
    private(set) var cancels = 0
    private(set) var microphoneOpen = true

    fileprivate init(owner: FakeDictation) {
        self.owner = owner
        (events, continuation) = AsyncStream<DictationEvent>.makeStream()
    }

    func finish() {
        finishes += 1
        shut()
    }

    func cancel() {
        cancels += 1
        shut()
        continuation.finish()
    }

    /// The recognizer's words so far, whole; `final` settles them.
    func say(_ words: String, final: Bool = false) {
        continuation.yield(.words(words, final: final))
        if final { end() }
    }

    func level(_ level: Float) {
        continuation.yield(.level(level))
    }

    func interrupt() {
        continuation.yield(.interrupted)
        end()
    }

    func fail(_ failure: DictationFailure) {
        continuation.yield(.failed(failure))
        end()
    }

    private func end() {
        shut()
        continuation.finish()
    }

    private func shut() {
        guard microphoneOpen else { return }
        microphoneOpen = false
        owner.stopped += 1
    }
}

/// The model's timers, held until a test lets one go: a wait that returned
/// by itself would race the test, and one that really slept would make the
/// test wait on the clock. A wait that is cancelled leaves, as a real
/// one's would.
final class FakeTimers: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [UUID: (duration: Duration, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var begun: [Duration] = []

    func wait(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    begun.append(duration)
                    if Task.isCancelled { return true }
                    held[id] = (duration, continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock { held.removeValue(forKey: id)?.continuation }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// The durations being waited for now.
    var waiting: [Duration] { lock.withLock { held.values.map(\.duration) } }

    /// Every wait that was started, in order, cancelled or not.
    var started: [Duration] { lock.withLock { begun } }

    /// Lets the waits for `duration` go.
    func fire(_ duration: Duration) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            let ids = held.filter { $0.value.duration == duration }.map(\.key)
            return ids.compactMap { held.removeValue(forKey: $0)?.continuation }
        }
        for continuation in ready { continuation.resume() }
    }
}
