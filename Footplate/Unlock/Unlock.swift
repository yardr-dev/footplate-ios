import Foundation

// The phone's unlock in front of a weighty pick (design 3.4), as
// footplate-android's unlock/Unlock.kt has it: one prompt per approval,
// no reuse window, and the reasons as plain functions, tested without
// the prompt. Over the edge a phone approves run and setup asks, always
// behind the gate, and picks on mapping asks that write a user's
// identity; any pick on a card whose weight is not empty, a class the
// phone does not know among them, passes the gate too. Where the phone
// has no screen lock the card asks the ask's number typed back instead,
// and `weighed` goes on a match.

/// How the gate stands in front of a weighty pick on this phone.
enum UnlockGate: Equatable, Sendable {
    /// The system's prompt: Face ID, Touch ID or the device passcode.
    case prompt
    /// No screen lock: the ask's number typed back.
    case typeBack
}

/// The label of the pick on a mapping ask that ignores its sender: it
/// writes no identity (`MappingNobody` in yardr's internal/store).
let mappingNobody = "Nobody — ignore this sender"

/// The label of the last option of every ask, which leaves the question
/// to its asker (`YouDecide` in yardr's internal/store).
let youDecide = "You decide"

/// What the prompt shows for a pick: what is picked, and in which yard.
/// Never empty, since the prompt refuses an empty reason.
func pickReason(option: String, yard: String) -> String {
    switch (option.isEmpty, yard.isEmpty) {
    case (true, true): return "pick"
    case (true, false): return "pick in \(yard)"
    case (false, true): return "pick \(option)"
    case (false, false): return "pick \(option) in \(yard)"
    }
}

/// What the prompt shows for an approval: what is approved (a run's
/// command, a setup's pack), and in which yard. Never empty.
func approveReason(what: String, yard: String) -> String {
    switch (what.isEmpty, yard.isEmpty) {
    case (true, true): return "approve"
    case (true, false): return "approve in \(yard)"
    case (false, true): return "approve \(what)"
    case (false, false): return "approve \(what) in \(yard)"
    }
}

/// Whether a pick of `option` (numbered from 1, as the yard numbers it)
/// passes the gate first, and so goes with `weighed`. A card with no
/// weight never does. On a mapping ask (one with `identity`) the picks
/// of nobody and of you decide write no identity, and go without the
/// gate; any other pick on a weighty card passes it, whatever its class.
/// An option the card does not have is gated: in doubt, the gate.
func needsGate(weight: [AskWeight], identity: Identity?, options: [AskOption], option: Int64) -> Bool {
    if weight.isEmpty { return false }
    guard identity != nil else { return true }
    let index = Int(option - 1)
    guard options.indices.contains(index) else { return true }
    let label = options[index].label
    let last = index == options.count - 1
    return !(label == mappingNobody || (last && label == youDecide))
}

/// The gate this phone offers, from whether its owner authentication
/// can be evaluated: the prompt where it can be passed, the number
/// typed back anywhere else (no passcode set, above all).
func gateOf(canEvaluate: Bool) -> UnlockGate {
    canEvaluate ? .prompt : .typeBack
}

/// Whether `typed` is the ask's number: what is pasted often ends in a
/// line break, which is trimmed; anything else is no number typed back.
func typedBack(_ typed: String, _ ask: Int64) -> Bool {
    typed.trimmingCharacters(in: .whitespacesAndNewlines) == String(ask)
}
