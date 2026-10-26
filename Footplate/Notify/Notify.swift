import Foundation

// Telling a person of what arrives while the screen does not show it: a
// notification for mail to them and for a new decision, while the app is
// open (design 3.5), as footplate's notify has it. The rules are plain
// functions, tested on the simulator: what arrived (`arrived`), what of
// it is told of (`wanted`), and that a burst is one notification
// (`Burst`). How one is shown is the system's (Show.swift).

/// What a notification tells of: mail to the person, or a new decision.
/// A notice of the yard is not told of: it shows on the yard's row.
enum Kind: Equatable, Sendable {
    case mail, decision
}

/// Where a notification leads, in its yard.
enum Target: Equatable, Sendable {
    /// The conversation with `with`.
    case conversation(with: String)
    /// The ask `ask` on `bead`.
    case decision(bead: String, ask: Int64)
}

/// One arrival: mail to the person, or a new open ask. `yard` is the
/// yard's name at the edge, empty for the account's own; the title it
/// is shown under is resolved where the notification is made, so a tap
/// still finds the yard by its name.
struct News: Equatable, Sendable {
    var yard: String
    /// A mail's sender, an ask's asker.
    var from: String
    /// The mail's text, the ask's question.
    var text: String
    /// The row it belongs to, which says its kind.
    var target: Target

    var kind: Kind {
        switch target {
        case .conversation: return .mail
        case .decision: return .decision
        }
    }
}

/// What the screen shows, as far as a notification cares: the open
/// conversation, the decisions list of one yard, or anything else.
enum ScreenShown: Equatable, Sendable {
    case conversation(yard: String, with: String)
    case decisions(yard: String)
    case decision(yard: String, bead: String, ask: Int64)
    case elsewhere
}

/// What the tabs show over the yard named `selected`: a pushed
/// conversation or decision, the decide place's list of the selected
/// yard's asks, or anything else. The pushed route names its own yard,
/// since a tap may have opened another yard's row.
func shownOf(place: Place, crewPath: [ConversationRoute], decidePath: [DecisionRoute], selected: String?) -> ScreenShown {
    if place == .crew, let route = crewPath.last {
        return .conversation(yard: route.yard, with: route.with)
    }
    if place == .decide, let route = decidePath.last {
        return .decision(yard: route.yard, bead: route.bead, ask: route.ask)
    }
    if place == .decide, let selected {
        return .decisions(yard: selected)
    }
    return .elsewhere
}

/// Whether `news` is told of with `shown` on the screen: mail to the
/// person and a new open ask are, but neither when it arrives on the
/// screen being shown: the open conversation, or the decisions list
/// for an ask. A letter or a decision in a yard that is not shown is
/// never on the screen shown, and is told of.
func wanted(_ news: News, shown: ScreenShown) -> Bool {
    switch news.target {
    case .conversation(let with):
        return shown != .conversation(yard: news.yard, with: with)
    case .decision(let bead, let ask):
        return shown != .decisions(yard: news.yard)
            && shown != .decision(yard: news.yard, bead: bead, ask: ask)
    }
}

/// What `after` brings that `before` had not: the mail to the person
/// oldest first, then the newly open asks in the order the queue lists
/// them. A yard read for the first time (`before` nil) brings nothing:
/// what it holds was there before the app opened, and footplate's load
/// tells of nothing either. The person's own letters, letters read
/// already, and an ask open again after anything but being put aside
/// (an answer the yard did not take) are none of them news.
func arrived(yard: String, before: Board?, after: Board) -> [News] {
    guard let before else { return [] }
    let mail = after.letters.values
        .filter { $0.seq > before.cursor && before.letters[$0.seq] == nil && $0.to == after.me && $0.from != after.me }
        .sorted { $0.seq < $1.seq }
        .map { News(yard: yard, from: $0.from, text: $0.text, target: .conversation(with: after.partyOf($0))) }
    let asks = after.open
        .filter { ask in !before.open.contains { $0.bead == ask.bead && $0.ask == ask.ask } }
        .filter { ask in !before.decided.contains { $0.bead == ask.bead && $0.ask == ask.ask && $0.state != "put aside" } }
        .map { News(yard: yard, from: $0.asker, text: $0.question, target: .decision(bead: $0.bead, ask: $0.ask)) }
    return mail + asks
}

/// As much of a first line as a notification says (footplate's `LINE`):
/// the system cuts what its banner does not hold, and the list shows
/// more.
let lineLength = 140

/// The first line of `text` that says something, as a notification has
/// it: no control character, and cut with an ellipsis where it is long,
/// as a row of the list cuts a name. Cut by grapheme, so a mark never
/// loses its letter.
func line(_ text: String) -> String {
    let first = plain(text).split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces) }
        .first { !$0.isEmpty } ?? ""
    if first.count <= lineLength { return first }
    return String(first.prefix(lineLength)).trimmingCharacters(in: .whitespaces) + "…"
}

/// `text` with nothing a notification must not carry: no control
/// character but a newline or a tab, and no Unicode line separator.
func plain(_ text: String) -> String {
    let kept = text.unicodeScalars.filter { scalar in
        scalar.value == 0x0a || scalar.value == 0x09
            || (!CharacterSet.controlCharacters.contains(scalar) && scalar != "\u{2028}" && scalar != "\u{2029}")
    }
    return String(String.UnicodeScalarView(kept))
}
