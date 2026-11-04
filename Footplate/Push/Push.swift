import Foundation

// Waking a closed phone (design yardr-hosted-8787 sections 4 and 6):
// the relay's wake is content-free — a kind, a random wake id and a
// count, with the wake link beside them — and the phone fills it in
// from its paired yards. Nothing of a yard, a sender or a row rides
// in the payload or the link; the target a tap opens is saved on the
// phone alone, beside the wake id. These are the words both the app
// and its notification service extension read the wake by.

/// The app group the app and the extension share: the checkpoints and
/// the wake targets live there. Credentials never do (Records keeps
/// them in the shared Keychain group).
let pushAppGroup = Bundle.main.object(forInfoDictionaryKey: "PUSH_APP_GROUP") as? String
    ?? "group.dev.yardr.footplate"

/// The Keychain access group the app and the extension share, as the
/// entitlement names it without its App ID prefix: the device and
/// session tokens are read there with
/// `AfterFirstUnlockThisDeviceOnly`, so the extension can fetch while
/// the screen is locked after the first unlock.
let pushKeychainGroup = Bundle.main.object(forInfoDictionaryKey: "PUSH_KEYCHAIN_GROUP") as? String
    ?? "dev.yardr.footplate"

/// The key the secret shelf keeps the push token the system last gave
/// under: the registrar writes and reads it, and `Records.forgetAll`
/// leaves it, since it is a delivery address and no credential.
let pushTokenKey = "push-token"

/// The one URL scheme a tap may open, and its one shape:
/// `yardr-footplate://open/wake/<id>`, the id the relay's alone.
let wakeScheme = "yardr-footplate"

extension Kind {
    /// The payload's word for the kind, as the relay writes it.
    var wakeWord: String {
        switch self {
        case .mail: return "mail"
        case .decision: return "decision"
        }
    }

    init?(wakeWord: String) {
        switch wakeWord {
        case "mail": self = .mail
        case "decision": self = .decision
        default: return nil
        }
    }
}

/// What Apple carried of one wake: its kind, its random id and how
/// many arrivals the relay folded into it. All the phone is told
/// before it fetches; a payload with none of ours is no wake of ours.
struct WakePayload: Equatable, Sendable {
    var id: String
    var kind: Kind
    var count: Int
}

/// The wake a remote notification's tap carries, read from the words
/// the relay put in it. The link is read the same way, and holds the
/// same id and nothing else: no yard, no row, no token stands in
/// either, so a forwarded wake opens nothing by itself.
func wakePayloadOf(_ userInfo: [AnyHashable: Any]) -> WakePayload? {
    guard let id = userInfo["id"] as? String, !id.isEmpty,
          let word = userInfo["kind"] as? String, let kind = Kind(wakeWord: word)
    else { return nil }
    let count: Int
    if let number = userInfo["count"] as? NSNumber {
        count = number.intValue
    } else if let text = userInfo["count"] as? String {
        count = Int(text) ?? 0
    } else {
        count = 0
    }
    return WakePayload(id: id, kind: kind, count: max(0, count))
}

/// The wake id a `yardr-footplate://open/wake/<id>` link names, or
/// nil where the link is none of ours: another scheme, another host,
/// another path, or no id. A malformed link is read as no wake, and
/// its tap opens the yard list (Wake.swift).
func wakeIdOf(_ url: URL) -> String? {
    guard url.scheme == wakeScheme, url.host == "open" else { return nil }
    let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
    guard parts.count == 2, parts[0] == "wake", !parts[1].isEmpty else { return nil }
    return String(parts[1])
}

/// The link of one wake, as the relay writes it and a test reads it.
func wakeLink(_ id: String) -> String {
    "\(wakeScheme)://open/wake/\(id)"
}

/// The generic line that stands where a wake cannot be filled in:
/// the relay's words, a kind and nothing of any yard or row.
func genericLine(_ kind: Kind) -> String {
    switch kind {
    case .mail: return "A letter"
    case .decision: return "A decision waits"
    }
}

/// Whether the no-banner path stands: only where Apple has granted
/// the filtering entitlement and the build carries it, which the
/// operator's step adds beside flipping this key (until then every
/// build answers false, and nothing-new and door-closed wakes leave
/// the generic line). Read from the caller's own bundle, so the app
/// and the extension answer for themselves.
func filteringGranted(bundle: Bundle = .main) -> Bool {
    bundle.object(forInfoDictionaryKey: "PUSH_FILTERING") as? Bool ?? false
}
