import Foundation

// The decisions list (design 3.5, after Android's
// model/DecisionsModel.kt): the selected yard's open asks as cards,
// the weighty lines first on each, and the decided under them, each as
// the yard last listed them. The open cards move when the `noted` event's
// open-only re-read says so, never before: a pick, a Later or a Decline is
// the yard's to record. The decided are read whole (`UserAsks`) when the
// place appears or reloads in front, after the person's own decision, and
// when an open card's ask leaves the open list. A noted event alone never
// reads the whole history again.

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

/// What the Decide place reads whole: the yard it is in front of, and
/// how many of its loads have applied. A change of either is the reason
/// to read, so a yard change and a reload share the one trigger path and
/// its dedupe.
struct DecisionsReading: Equatable, Sendable {
    var yard: String
    var generation: Int
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

    /// The yard whose whole queue the place reads, and how many of its
    /// loads have applied: the selected one, while Decide is the place in
    /// front and the yard has a board to put the history on. A change of
    /// it is the reason to read: the place appearing, the selected yard
    /// changing under it, the yard's first board arriving while it is in
    /// front, or the yard reloading under it (one whole read per
    /// foreground with Decide in front, the same order as the appear
    /// trigger). A card pushed over the list changes none, so coming back
    /// from it reads nothing.
    var reading: DecisionsReading? {
        guard nav.place == .decide, let yard = records.kept.selected, mailroom.boards[yard] != nil else { return nil }
        return DecisionsReading(yard: yard, generation: mailroom.loadGeneration(of: yard))
    }

    /// Reads the whole queue of the yard the place is in front of, the
    /// decided history with the open asks.
    func read() async {
        guard let yard = reading?.yard else { return }
        await mailroom.fetchWhole(yard)
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

/// How long an ask has waited as the preview under a letter says it, in
/// the desktop's words (`waits`): `now`, `5m`, `2h`, `3d`. A time the yard
/// wrote that cannot be read says nothing. The cards keep `waited`'s.
func waits(_ since: String, now: Date) -> String {
    guard let then = parseInstant(since) else { return "" }
    // In whole seconds each, as the desktop's timestamps are.
    let seconds = Int(now.timeIntervalSince1970.rounded(.down)) - Int(then.timeIntervalSince1970.rounded(.down))
    let minutes = seconds / 60
    switch minutes {
    case ..<1: return "now"
    case ..<60: return "\(minutes)m"
    case ..<(24 * 60): return "\(minutes / 60)h"
    default: return "\(minutes / (24 * 60))d"
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
/// sign-in page gave (`AskSecret.OperatorLoginInput` in yardr), a `login`
/// asked for the one name `INPUT` with no source, hook, harness, user,
/// crew member or `as` beside it: the one secret the phone gives on a
/// plain channel. An API key (`harness`), a source's credential, a hook's
/// secret, a user's own address or credential and the code of a user's
/// own login (`as`) are not it: on a plain channel the yard refuses each
/// of them down the link, after the edge has seen the value, so the phone
/// asks for none; on a sealed one the phone offers every secret.
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

/// Whether the card offers its secret's fields on the phone, one per name
/// of `env`, behind the weighed gate. The login's code is offered wherever
/// the yard is reached; every other secret only where it is reached sealed,
/// so the edge carries the typed values unread. A secret that names nothing
/// has no field to offer.
func offersSecrets(_ secret: Secret?, sealed: Bool) -> Bool {
    guard let secret, !secret.env.isEmpty else { return false }
    return givesLoginCode(secret) || sealed
}

/// Whether the card is one the phone cannot answer: a secret ask is
/// answered on the yard's machine alone, but for what `offersSecrets`
/// offers on the phone. A run or setup ask is approved on the phone,
/// behind the unlock.
func answeredElsewhere(_ secret: Secret?, sealed: Bool) -> Bool {
    secret != nil && !offersSecrets(secret, sealed: sealed)
}

/// The command that answers a secret card the phone does not offer on
/// the yard's machine: on a plain channel a secret never crosses the
/// edge but a login's one-time code, and is never typed on the phone
/// otherwise.
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
/// Pick, Approve or Give: a secret ask the phone does not offer, or one
/// the yard refused — a run approval's, a setup approval's with its
/// preset, a pick's with its option, or a secrets giving. Nil on a card
/// the phone answers on. `sealed` is whether the yard is reached sealed:
/// a sealed secret is given on the phone until the yard refuses it. The
/// bare `yardr bead answer <bead> <ask>` is never shown: the CLI refuses
/// it without a mode.
func elsewhereCommand(bead: String, ask: BeadAsk, chosen: Int64, refused: Bool, sealed: Bool) -> String? {
    if answeredElsewhere(ask.secret, sealed: sealed) {
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
