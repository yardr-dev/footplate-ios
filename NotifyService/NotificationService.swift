import Foundation
import UserNotifications

// The notification service extension (design 8787 section 4): a
// mutable-content wake arrives with the generic line standing, and
// this fills it in — fetching every paired yard's board over the
// relay-paired credentials and running the Notify rules through the
// wake engine — or ends it where the filtering entitlement stands,
// or leaves the generic line where the fetch cannot be done. Its
// whole of the work is the shared core; this class is the system's
// door onto it, and the budget the system gives it is the wake's.
/// The system's completion, called once with what stands: the
/// system takes it from any thread, so holding it across the fetch
/// races with nothing.
private final class WakeCompletion: @unchecked Sendable {
    let handler: (UNNotificationContent) -> Void
    private let gate = WakeCompletionGate()

    init(handler: @escaping (UNNotificationContent) -> Void) {
        self.handler = handler
    }

    func call(_ content: UNNotificationContent) {
        guard gate.claim() else { return }
        handler(content)
    }
}

/// The original content is immutable while the fetch runs; this box
/// is the handoff from the extension callback to its async task.
private final class OriginalContent: @unchecked Sendable {
    let value: UNNotificationContent

    init(_ value: UNNotificationContent) {
        self.value = value
    }
}

final class NotificationService: UNNotificationServiceExtension {
    private var completion: WakeCompletion?
    private var work: Task<Void, Never>?
    private var originalContent: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let completion = WakeCompletion(handler: contentHandler)
        self.completion = completion
        originalContent = request.content
        guard let wake = wakePayloadOf(request.content.userInfo) else {
            completion.call(request.content)
            return
        }
        work = Self.begin(wake: wake, original: OriginalContent(request.content), completion: completion)
    }

    /// The fetch set going, off the system's call: the wake filled
    /// in and delivered, within the budget the system allows it.
    private static func begin(
        wake: WakePayload, original: OriginalContent, completion: WakeCompletion
    ) -> Task<Void, Never> {
        Task {
            let outcome = await fill(wake: wake)
            deliver(outcome, wake: wake, original: original.value, completion: completion)
        }
    }

    /// What the filled wake becomes: the telling written over the
    /// generic line, an empty attempt where suppression stands, or
    /// the generic line itself, untouched.
    private static func deliver(
        _ outcome: WakeOutcome, wake: WakePayload,
        original: UNNotificationContent, completion: WakeCompletion
    ) {
        switch outcome {
        case .show(let telling):
            guard let attempt = original.mutableCopy() as? UNMutableNotificationContent else {
                completion.call(original)
                return
            }
            attempt.title = telling.title
            attempt.body = telling.body
            attempt.threadIdentifier = threadOf(telling)
            // The saved target rides the tap from here: the ids
            // stand in this notification and the wake landing
            // alone, never in what the relay sent.
            var info = userInfoOf(telling)
            info["id"] = wake.id
            attempt.userInfo = info
            completion.call(attempt)
        case .suppress:
            // No banner at all: an empty attempt, which the
            // filtering entitlement is what lets stand.
            completion.call(UNMutableNotificationContent())
        case .generic:
            completion.call(original)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // The budget is spent: the generic line stands, as a fetch
        // that could not finish leaves it.
        work?.cancel()
        if let completion, let originalContent {
            completion.call(originalContent)
        }
        completion = nil
        work = nil
    }

    /// One wake filled in: the yards the records hold for the edge,
    /// each read whole as a `Board`, against the checkpoints and
    /// wake landings both processes share. The credentials are the
    /// records' own — the shared Keychain group, read here as in
    /// the app — and a yard of its own is no wake's yard.
    private static func fill(wake: WakePayload) async -> WakeOutcome {
        guard let checkpoints = FileCheckpointStore.shared(),
              let targets = FileWakeTargetStore.shared(),
              let edge = try? Edge.live()
        else {
            return .generic(kind: wake.kind)
        }
        let engine = await MainActor.run {
            wakeEngine(
                edge: edge, records: Records.live(origin: edge.origin),
                checkpoints: checkpoints, targets: targets,
                canSuppress: filteringGranted()
            )
        }
        return await engine.handle(wakeId: wake.id, kind: wake.kind, shown: .elsewhere)
    }
}
