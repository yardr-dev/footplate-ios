import Foundation

// The screen of a pairing an approval opened (design yardr-6maq 3.4,
// after footplate's own): what the approval of a `user device pair` card
// answers, shown in that sitting alone — the QR for the new device to
// scan, the code for one with no camera, the minutes it is good for, and
// End — and the words the card says of the door its approval crosses,
// before the approval is sent. The decision model holds the sitting;
// these are what it hands the screen, and the plain functions that make
// the screen's words.

/// Why an approved pairing's screen shows no code.
enum PairingOver: Equatable, Sendable {
    /// End was sent and the yard ended it.
    case ended
    /// The time ran out.
    case ranOut
    /// The yard approved the card and opened the pairing, but its
    /// answer held no code that could be shown.
    case unshown
}

/// The QR screen, in place of the card it came from.
struct PairingScreen: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// The pairing to draw: its QR, its code and its end.
        case showing(Pairing)
        /// No code and no QR stand any more.
        case over(PairingOver)
    }

    /// Whose pairing it is and which device it is for, as the card names
    /// them.
    var user: String
    var device: String
    var phase: Phase
    /// Whether End can take the pairing back from this phone: the yard
    /// serves it to a device for its own user's pairing alone, so an
    /// operator's approval of a member's pairing has no End here.
    var canEnd: Bool = true
    /// End was sent and the yard has not answered.
    var ending: Bool = false
    /// The yard's words where it refused End: the pairing stands, and
    /// End is there to press again.
    var refusal: String? = nil
}

/// Whether `run` pairs a device: `user device pair <user> <device>`, with
/// `--url <address>` where it names one. As the yard's `IsDevicePairRun`
/// reads it: the user and the device stand, and the first three words are
/// the row's.
func isDevicePairRun(_ run: Run) -> Bool {
    let argv = run.argv
    return argv.count >= 5 && argv[0] == "user" && argv[1] == "device" && argv[2] == "pair"
}

/// What a pairing card says of the door its approval crosses, under the
/// card's weight and before the approval goes (3.4, under the decided
/// answer to its fifth question). Sealed to this phone — where the yard's
/// channel was pinned at its pairing — the answer comes back sealed and
/// the edge carries it unread. Otherwise the token crosses in the clear,
/// and whoever carries the approval could spend the code first.
func pairDoor(sealed: Bool) -> String {
    sealed
        ? "Approving answers the pairing's code sealed to this phone: the edge carries it unread"
        : "Approving shows the pairing's code on this screen: show it to the device and to nobody else, since whoever has it within its minutes, the carrier of this approval included, could spend it first"
}

/// How long a pairing's code is good for, as the screen counts it down:
/// the whole minutes between `now` and `expires`. Under a minute is less
/// than a minute, and once the time ran out the code ran out.
func pairingLeft(expires: Date, now: Date) -> String {
    let left = Int(expires.timeIntervalSince(now).rounded(.down))
    switch left {
    case ...0: return "The code ran out"
    case 1..<60: return "Less than a minute left"
    case 60..<120: return "1 minute left"
    default: return "\(left / 60) minutes left"
    }
}

/// What the screen says where no code stands.
func pairingOverWords(_ over: PairingOver) -> String {
    switch over {
    case .ended: return "The pairing ended"
    case .ranOut: return "The code ran out"
    case .unshown: return "The yard opened the pairing, but its answer held no code that could be shown. It ends by itself in ten minutes: ask for a new pairing then"
    }
}
