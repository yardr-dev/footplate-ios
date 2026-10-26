import Foundation

// The decisions list (design 3.5, after Android's
// model/DecisionsModel.kt): the selected yard's open asks as cards,
// the weighty lines first on each, and the decided under them, each as
// the yard last listed them. The list moves when the `noted` event's
// re-read says so, never before: a pick, a Later or a Decline is the
// yard's to record.

/// One open ask as the Decisions list draws it, a card.
struct Card: Equatable, Sendable {
    var bead: String
    var ask: Int64
    /// The bead's title, in meta.
    var title: String
    var question: String
    /// Who asks and how long it has waited: `yardmaster · 2 h`.
    var meta: String
    /// The `WEIGHTY · <class>: <line>` lines, first on the card.
    var weighty: [String] = []
}

/// One ask open no more, one line under `Decided`.
struct DecidedLine: Equatable, Sendable {
    var bead: String
    var ask: Int64
    var question: String
    /// What became of it: `answered: Land it`, `declined`, …
    var what: String
}

struct DecisionsState: Equatable, Sendable {
    /// The open asks, oldest first.
    var open: [Card] = []
    /// The decided, newest first, as the yard lists them.
    var decided: [DecidedLine] = []
}

@MainActor
@Observable
final class DecisionsModel {
    private let records: Records
    private let mailroom: Mailroom
    private let nav: Nav
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone

    init(
        records: Records,
        mailroom: Mailroom,
        nav: Nav,
        now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.records = records
        self.mailroom = mailroom
        self.nav = nav
        self.now = now
        self.zone = zone
    }

    var state: DecisionsState {
        decisions(board: records.kept.selected.flatMap { mailroom.boards[$0] })
    }

    /// Opens one decision's card, pushed onto the decide stack.
    func open(_ card: Card) {
        guard let yard = records.kept.selected else { return }
        nav.openDecision(yard: yard, bead: card.bead, ask: card.ask)
    }

    private func decisions(board: Board?) -> DecisionsState {
        guard let board else { return DecisionsState() }
        let now = now()
        let zone = zone()
        return DecisionsState(
            open: board.open.map { card($0, now: now) },
            decided: board.decided.map {
                DecidedLine(bead: $0.bead, ask: $0.ask, question: $0.question, what: became($0, now: now, zone: zone))
            }
        )
    }
}

/// An open ask as its card on the list.
func card(_ ask: OpenAsk, now: Date) -> Card {
    Card(
        bead: ask.bead,
        ask: ask.ask,
        title: ask.beadTitle.isEmpty ? ask.bead : ask.beadTitle,
        question: ask.question,
        meta: [ask.asker.isEmpty ? nil : ask.asker, waited(ask.since, now: now)].compactMap { $0 }.joined(separator: " · "),
        weighty: ask.weight.map(weightLine)
    )
}

/// One class of a weighty card's weight, as `yardr bead ask` prints it.
func weightLine(_ weight: AskWeight) -> String {
    "WEIGHTY · \(weight.kind): \(weight.line)"
}

/// How long an ask has waited, from its `since` to now: `5 min`, `2 h`,
/// `1 day`, `3 days`. A wait under a minute reads a minute; a time the
/// yard wrote that cannot be read says nothing.
func waited(_ since: String, now: Date) -> String? {
    guard let then = parseInstant(since) else { return nil }
    let minutes = max(1, Int(now.timeIntervalSince(then)) / 60)
    switch minutes {
    case ..<60: return "\(minutes) min"
    case ..<(24 * 60): return "\(minutes / 60) h"
    case ..<(48 * 60): return "1 day"
    default: return "\(minutes / (24 * 60)) days"
    }
}

/// What became of an ask open no more, in one line.
func became(_ ask: DecidedAsk, now: Date, zone: TimeZone) -> String {
    switch ask.state {
    case "answered":
        if ask.option == 0, !ask.words.isEmpty { return "answered: \(ask.words)" }
        if !ask.optionLabel.isEmpty { return "answered: \(ask.optionLabel)" }
        return "answered"
    case "put aside":
        let until = stamp(ask.returnAt, now: now, zone: zone)
        return until.isEmpty ? "put aside" : "put aside until \(until)"
    case "declined":
        return "declined"
    case "taken back":
        return ask.by.isEmpty ? "taken back" : "taken back by \(ask.by)"
    default:
        return ask.state
    }
}

/// The one name a login's input is asked for (`loginInputName` in yardr).
let loginInputName = "INPUT"

/// Whether the card is the daemon's ask for the one-time code a harness's
/// sign-in page gave: the one secret the yard takes down the edge link
/// (`AskSecret.OperatorLoginInput` in yardr), a `login` asked for the one
/// name `INPUT` with no source, hook, harness, user, crew member or `as`
/// beside it. An API key (`harness`), a source's credential, a hook's
/// secret, a user's own address or credential and the code of a user's
/// own login (`as`) are not it: the yard refuses each of them down the
/// link, after the edge has seen the value, so the phone asks for none.
func givesLoginCode(_ secret: Secret?) -> Bool {
    guard let secret else { return false }
    return !secret.login.isEmpty
        && secret.env == [loginInputName]
        && secret.source.isEmpty
        && secret.hook.isEmpty
        && secret.harness.isEmpty
        && secret.user.isEmpty
        && secret.crew.isEmpty
        && secret.as.isEmpty
}

/// Whether the card is one the edge cannot answer: a secret ask is
/// answered on the yard's machine alone, but for a harness login's
/// one-time code, which is given on the phone behind the unlock. A run or
/// setup ask is approved on the phone, behind the unlock.
func answeredElsewhere(_ secret: Secret?) -> Bool {
    secret != nil && !givesLoginCode(secret)
}

/// The command that answers a secret card on the yard's machine: a
/// secret never crosses the edge but a login's one-time code, and is
/// never typed on the phone otherwise.
func secretCommand(bead: String, ask: Int64) -> String {
    "yardr bead answer \(bead) \(ask) --secret"
}

/// The command that approves a run card on the yard's machine, with a
/// `--value` for each value the card asks for in the clear.
func approveCommand(bead: String, ask: Int64, run: Run?) -> String {
    var command = "yardr bead answer \(bead) \(ask) --approve"
    for name in run?.ask ?? [] {
        command += " --value \(name)=<value>"
    }
    return command
}

/// The command that approves a setup card on the yard's machine with
/// preset `option`: the account typed unseen, or a candidate the card
/// lists taken by its source.
func setupCommand(bead: String, ask: Int64, option: Int64, setup: Setup?) -> String {
    if let setup, setup.given == true, setup.missing.isEmpty {
        return "yardr bead answer \(bead) \(ask) \(option)"
    }
    if let source = setup?.candidates.first?.source, !source.isEmpty {
        return "yardr bead answer \(bead) \(ask) \(option) --account \(source)"
    }
    return "yardr bead answer \(bead) \(ask) \(option) --secret"
}

/// The command that picks `option` on the yard's machine, with the
/// words beside it where the person wrote any.
func pickCommand(bead: String, ask: Int64, option: Int64) -> String {
    "yardr bead answer \(bead) \(ask) \(option) [words]"
}

/// The command that answers a card on the yard's machine, in place of
/// Pick, Approve or Give: a secret ask's, or one the yard refused — a
/// run approval's, a setup approval's with its preset, a pick's with
/// its option, or a login code's giving. Nil on a card the phone answers
/// on. The bare `yardr bead answer <bead> <ask>` is never shown: the CLI
/// refuses it without a mode.
func elsewhereCommand(bead: String, ask: BeadAsk, chosen: Int64, refused: Bool) -> String? {
    if answeredElsewhere(ask.secret) {
        return secretCommand(bead: bead, ask: ask.ask)
    }
    guard refused else { return nil }
    if ask.secret != nil {
        return secretCommand(bead: bead, ask: ask.ask)
    }
    if ask.run != nil {
        return approveCommand(bead: bead, ask: ask.ask, run: ask.run)
    }
    if ask.setup != nil {
        return setupCommand(bead: bead, ask: ask.ask, option: chosen, setup: ask.setup)
    }
    if chosen > 0 {
        return pickCommand(bead: bead, ask: ask.ask, option: chosen)
    }
    return nil
}
