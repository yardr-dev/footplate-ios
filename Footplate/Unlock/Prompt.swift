import Foundation
import LocalAuthentication

// The system's prompt behind a protocol the models call (design 3.4),
// so the gate's plain functions and the sending rule are unit tests on
// the simulator, and the prompt itself is checked by hand on a device.
// A fresh `LAContext` is made for each approval and invalidated when
// it answers; its allowable reuse duration is never set, so a second
// approval always prompts again. The gate is friction against
// approving on reflex, not a key anything is encrypted with.

/// The unlock a model asks for: which gate this phone offers, asked as
/// the card is drawn, and the prompt itself.
protocol UnlockPrompt: Sendable {
    /// The gate this phone offers now: asked where a weighty card is
    /// drawn, since a passcode may be set or removed while the app runs.
    func gate() -> UnlockGate

    /// Shows the system's prompt with `reason`, and says whether the
    /// person passed it. A cancel, a dismissal and too many failed
    /// tries all answer false.
    func prompt(reason: String) async -> Bool
}

/// The prompt of the phone: LocalAuthentication's device owner
/// authentication, Face ID or Touch ID with the device passcode as its
/// own fallback.
struct LAUnlockPrompt: UnlockPrompt {
    func gate() -> UnlockGate {
        gateOf(canEvaluate: LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil))
    }

    func prompt(reason: String) async -> Bool {
        let context = LAContext()
        defer { context.invalidate() }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason.isEmpty ? "pick" : reason
            )
        } catch {
            return false
        }
    }
}
