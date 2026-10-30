import Foundation

// One yard's line: the flows view, read-only (design 3.5, after
// Android's model/LineModel.kt): the overview with its stats as
// filters, a card per moving line and the quiet lines' chips, the
// Elsewhere rows and the beads with no line. Read when the place
// opens, read again on pull-to-refresh and on every stream event
// that moves it, the way footplate reads Flows again; no polling.
// A line tap pushes its route map: the whole line as stations from
// top to bottom, whatever filter the overview holds, with the landings
// of the last 24 hours under its landed station. A bead tap, from a
// card, a row, a station or a landing, pushes its card: the strip with its
// stage marked, what is happening now, Ask yardmaster, the bead's
// details (its labels, body and notes, read with `Bead` when the card
// opens and again with every read of the board), and Open in web view.

/// One open bead on the line, as its row draws it.
struct LineBead: Equatable, Sendable {
    var id: String
    var title: String
    /// The yard's remark, drawn faint where there is one.
    var remark: String = ""
    /// A session works it: the running green dot.
    var working: Bool = false
    /// Who works it (`worked by <group> · <kind>/<model>`), nil where
    /// the yard names nobody.
    var workedBy: String? = nil
}

/// One stage in travel order, as its rows draw it.
struct LineStage: Equatable, Sendable {
    var name: String
    /// Whose group works there (`muse-builders · 2 of 4 seats`).
    var words: String
    var beads: [LineBead] = []
    /// The backlog: collapsed by default, its count word in place of
    /// its beads.
    var backlog: Bool = false
    /// A collapsed backlog tapped open.
    var open: Bool = false
    /// The waits on the reader among a backlog's beads, for its shut row.
    var waits: Int = 0
}

/// One depot's flow; named on the screen only where the depot has more
/// than one.
struct LineFlow: Equatable, Sendable {
    var name: String
    var stages: [LineStage]
}

/// One depot as its section.
struct LineDepot: Equatable, Sendable {
    var name: String
    /// The depot's open beads outside the backlog.
    var travelling: Int64 = 0
    /// Why the depot's flows could not be read, in the yard's own
    /// words; its beads are then all in Elsewhere.
    var error: String = ""
    var flows: [LineFlow] = []
    var elsewhere: [LineBead] = []
}

/// Which beads the overview shows: all of them, or one of the stats.
enum LineFilter: Equatable, Sendable {
    case all, moving, yourTurn, held, late
}

/// The overview's stats: the tappable filters with their counts.
struct LineStats: Equatable, Sendable {
    var inTransit: Int64 = 0
    var moving: Int = 0
    var yourTurn: Int = 0
    var held: Int = 0
    var late: Int = 0
}

/// One stage's state, as a strip segment draws it.
enum StageState: Equatable, Sendable {
    case moving, yourTurn, broken, none
}

/// One stage of a line card's strip, every stage the same width.
struct StripStage: Equatable, Sendable {
    var name: String
    var state: StageState
    var human: Bool
}

/// One line of the overview: a depot's flow as its card.
struct LineCard: Equatable, Sendable {
    var depot: String
    var flow: String
    /// `yardr · default`.
    var title: String
    /// The worst of the strip's states.
    var lamp: StageState
    /// Every stage in travel order, the backlog first.
    var stages: [StripStage]
    /// The matching beads' ids in stage order, the backlog left out.
    var beads: [String]
    /// The beads on the line outside the backlog, unfiltered.
    var inTransit: Int
    var backlog: Int
    /// Nothing moves on it: folded into a chip.
    var quiet: Bool
}

/// A quiet line's chip: it opens the route map too.
struct QuietLine: Equatable, Sendable {
    var depot: String
    var flow: String
    var title: String
}

/// One bead at its station, with who works it and its stay.
struct StationBead: Equatable, Sendable {
    var id: String
    var title: String
    var remark: String = ""
    var working: Bool = false
    /// The claiming session short (`train-new`), empty where none.
    var worker: String = ""
    /// Who works it (`worked by <group> · <kind>/<model>`), nil where
    /// the yard names nobody.
    var workedBy: String? = nil
    /// How long it has stood here (`41m`), empty where it has no clock.
    var stay: String = ""
    /// The yard's printed range (`5h–8h`), empty where it serves none.
    var expected: String = ""
    /// Unclaimed with its group's seats all taken: it stands for a seat.
    var waitsSeat: Bool = false
}

/// One bead landed in the trailing 24 hours, as its row under the
/// landed station draws it.
struct LandedBead: Equatable, Sendable {
    var id: String
    var title: String
    /// How long ago it landed (`41m ago`), empty where the yard serves
    /// no clock for it.
    var ago: String = ""
}

/// One station of the route map, from top to bottom.
struct Station: Equatable, Sendable {
    var name: String
    /// Whose group works there (`muse-builders · 2 of 4 seats`).
    var words: String
    var state: StageState
    var human: Bool
    var beads: [StationBead]
    /// The flow's landings, on the landed (terminal) station alone.
    var landings: [LandedBead] = []
    /// The backlog: collapsed by default, its count word in place of
    /// its beads.
    var backlog: Bool = false
    /// A collapsed backlog tapped open.
    var open: Bool = false
    /// The waits on the reader among a backlog's beads, for its shut row.
    var waits: Int = 0
}

/// One line opened as a vertical route map (Android's `LineRoute`; the
/// nav's `LineRoute` is the pushed line's name).
struct RouteMap: Equatable, Sendable {
    var depot: String
    var flow: String
    /// `yardr · default`.
    var title: String
    /// `4 in transit`.
    var head: String
    /// The stations from top to bottom, the backlog first.
    var stations: [Station]
}

/// One note of a bead, as its card draws it.
struct CardNote: Equatable, Sendable {
    var author: String
    /// When it was written, in the zone of the person reading
    /// (`14:02` on the day it is, else `27 Oct`).
    var at: String
    var text: String
}

/// What the `Bead` call adds to a card: the bead's labels, its body
/// and its notes, the newest last, as footplate's bead view has them.
struct CardDetails: Equatable, Sendable {
    /// The call has answered; what is below is the yard's.
    var read: Bool = false
    var labels: [String] = []
    var body: String = ""
    var notes: [CardNote] = []
    /// Why the last read said something; the card stays whole, with
    /// what an earlier read gave where there was one.
    var error: String? = nil

    /// Nothing read and nothing said yet: the card shows a loading line.
    var loading: Bool { !read && error == nil }
}

/// One bead opened from the line: its card, from the board's row and,
/// once it is read, the `Bead` call's details. A place to check and
/// nudge, not to edit (Android's `BeadCard`).
struct BeadCard: Equatable, Sendable {
    var bead: StationBead
    /// `yard · default`, `yard · Elsewhere`, or `No line`.
    var line: String
    /// The stage it stands in, empty on no line.
    var stage: String
    /// The line's strip with the bead's stage to mark, the backlog
    /// first; empty on no line.
    var stages: [StripStage]
    /// `yard · default · new for 41m · expected 11–25m`.
    var head: String
    /// The yard's web view URL for the bead.
    var webView: String
    /// The bead's labels, body and notes; the board has none of them.
    var details: CardDetails = CardDetails()
}

struct LineState: Equatable, Sendable {
    /// `7 travelling · 1 working`: words, never badges.
    var head: String = ""
    var depots: [LineDepot] = []
    /// The beads travelling with no line.
    var unassigned: [LineBead] = []
    /// The board has been read at least once.
    var read: Bool = false
    /// Why the last read said something.
    var error: String? = nil
    var stats: LineStats = LineStats()
    var filter: LineFilter = .all
    /// The lines with something moving, the filter honoured.
    var lines: [LineCard] = []
    /// The quiet lines' chips, shown only unfiltered.
    var quiet: [QuietLine] = []

    /// The board is read and the overview shows nothing anywhere:
    /// no card, no chip, and no Elsewhere or No line row.
    var empty: Bool {
        read
            && lines.isEmpty
            && quiet.isEmpty
            && depots.allSatisfy { $0.elsewhere.isEmpty }
            && unassigned.isEmpty
    }
}

/// One backlog stage's collapse, by depot, flow and stage.
struct BacklogKey: Hashable {
    var depot: String
    var flow: String
    var stage: String
}

@MainActor
@Observable
final class LineModel {
    private var openedYard: String? = nil
    private var board: Flows? = nil
    private var errorText: String? = nil
    private var expanded: Set<BacklogKey> = []
    private var selectedFilter: LineFilter = .all
    private var lastLoaded: Loaded? = nil
    private var applied: Int64 = 0
    private var observed: (followed: any Followed, id: UUID)? = nil
    /// What the `Bead` call last answered for each bead opened as a
    /// card, and why its last read said something.
    private var cardReads: [String: CardRead] = [:]
    /// The read each card waits on: one that is not its latest lands
    /// nowhere.
    private var cardReading: [String: UUID] = [:]
    /// The pushed beads standing on their `Bead` reads: ids the board
    /// holds none of, opened from mail. Their cards stay across board
    /// reads, which hold no closed bead.
    private var closedCards: Set<String> = []
    private(set) var webViewError: String? = nil
    private(set) var resolvingWebView: BeadRoute? = nil

    /// The followed yards by name at the edge; set by the app once
    /// its services stand, since the followers are rebuilt with them.
    var followers: @MainActor () -> [String: any Followed]
    /// The account, whose handle names its own yard in a web view link.
    private let records: Records
    private let pairer: Pairer
    private let nav: Nav
    private let conversation: ConversationModel
    /// Each yard's origin, the edge's or the yard's own, whose web
    /// view serves a bead's page.
    private let origins: @MainActor (String) -> String
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    private var active = false
    private var generation = 0
    private var readGeneration = 0
    private var readTask: Task<Void, Never>? = nil

    init(
        followers: @escaping @MainActor () -> [String: any Followed],
        records: Records,
        pairer: Pairer,
        nav: Nav,
        conversation: ConversationModel,
        origins: @escaping @MainActor (String) -> String,
        now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.followers = followers
        self.records = records
        self.pairer = pairer
        self.nav = nav
        self.conversation = conversation
        self.origins = origins
        self.now = now
        self.zone = zone
    }

    var state: LineState {
        guard let board else { return LineState(error: errorText, filter: selectedFilter) }
        let me = openedYard.flatMap { followers()[$0]?.state.loaded?.me.user } ?? ""
        let cards = lineCards(board: board, me: me, filter: selectedFilter)
        return LineState(
            head: headWords(board),
            depots: board.depots.map { depot in
                lineDepot(depot, me: me, filter: selectedFilter)
            },
            unassigned: board.unassigned.filter { matches($0, filter: selectedFilter, me: me) }.map(lineBead),
            read: true,
            error: errorText,
            stats: lineStats(board, me: me),
            filter: selectedFilter,
            lines: cards.lines,
            quiet: cards.quiet
        )
    }

    /// The yard's line is shown: read, and read again on every stream
    /// event that moves it and whenever its yard is read again.
    func open(yard: String) {
        let same = openedYard == yard
        if same, active { return }
        generation += 1
        detach()
        readTask?.cancel()
        readTask = nil
        if !same {
            openedYard = yard
            board = nil
            errorText = nil
            expanded = []
            selectedFilter = .all
            lastLoaded = nil
            applied = 0
            cardReads = [:]
            cardReading = [:]
            closedCards = []
            // A line pushed for the yard before is none of this one's.
            nav.closeLines { $0.yard != yard }
        }
        active = true
        attach(yard)
    }

    /// The line is no longer on the screen.
    func leave() {
        generation += 1
        active = false
        detach()
        readTask?.cancel()
        readTask = nil
    }

    /// Pull to refresh: read the board again, ending when it lands.
    func refresh() async {
        guard active, openedYard != nil else { return }
        await readNow()
    }

    /// One of the overview's stats tapped: show its beads alone.
    func filter(_ filter: LineFilter) {
        selectedFilter = filter
    }

    /// A backlog stage tapped: open where shut, shut where open.
    func toggleBacklog(depot: String, flow: String, stage: String) {
        let key = BacklogKey(depot: depot, flow: flow, stage: stage)
        if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
        }
    }

    /// A line tapped: its route map is pushed onto the lines stack.
    func openLine(depot: String, flow: String) {
        guard let yard = openedYard else { return }
        nav.openLine(yard: yard, depot: depot, flow: flow)
    }

    /// The pushed line as its route map, the whole line whatever filter
    /// the overview holds; nil where the board is not read, is another
    /// yard's, or holds no such line.
    func routeMap(for route: LineRoute) -> RouteMap? {
        guard let board, openedYard == route.yard else { return nil }
        let me = followers()[route.yard]?.state.loaded?.me.user ?? ""
        return lineRoute(
            board: board, me: me, depot: route.depot, flow: route.flow, now: now(), expanded: expanded
        )
    }

    /// A bead tapped, on a card, a row, a station or a landing:
    /// its card is read and pushed onto the lines stack.
    func openBead(_ id: String) {
        guard let yard = openedYard else { return }
        peekBead(id)
        nav.openBead(yard: yard, bead: id)
    }

    /// A mail's chip tapped: its card is read for the sheet over the
    /// conversation, standing on the board's facts while the bead is
    /// read for its details, or on the read alone where the board
    /// holds no such bead — but pushed nowhere, and the tab left
    /// alone. The sheet's Open on the line pushes it with `openBead`.
    func peekBead(_ id: String) {
        guard let yard = openedYard else { return }
        webViewError = nil
        if let board, holds(board, .bead(BeadRoute(yard: yard, bead: id))) {
            closedCards.remove(id)
        } else {
            closedCards.insert(id)
        }
        Task { @MainActor in await readDetails(of: id) }
    }

    /// The pushed bead as its card, whatever filter the overview holds;
    /// nil where the board is not read, is another yard's, or holds no
    /// such bead and no chip opened it. Its details are what the last
    /// read of the bead gave.
    func card(for route: BeadRoute) -> BeadCard? {
        guard let board, openedYard == route.yard else { return nil }
        let me = followers()[route.yard]?.state.loaded?.me.user ?? ""
        // A yard of its own serves its pages itself, at its own
        // address, with no yard named: the handle is the edge's own
        // yard's alone.
        let direct = isDirect(route.yard)
        let webYard = direct ? "" : route.yard
        let handle = direct ? "" : (records.kept.account?.handle ?? "")
        var card = beadCard(
            board: board, me: me, now: now(), origin: origins(route.yard),
            yard: webYard, handle: handle, id: route.bead
        )
        if card == nil, closedCards.contains(route.bead) {
            card = closedCard(
                read: cardReads[route.bead]?.bead, id: route.bead,
                origin: origins(route.yard), yard: webYard, handle: handle
            )
        }
        let read = cardReads[route.bead]
        card?.details = cardDetails(read?.bead, error: read?.error, now: now(), zone: zone())
        return card
    }

    /// Whether the yard named `name` is a yard of its own, serving its
    /// pages itself at its own address.
    private func isDirect(_ name: String) -> Bool {
        records.kept.yards.first { $0.name == name }.map { !$0.origin.isEmpty } ?? false
    }

    /// Opens this card in the yard's web view: the edge's, or a yard of
    /// its own's. A pre-upgrade account has no saved handle, so resolve
    /// it before forming the own-yard URL; never fall back to a browser
    /// cookie that may name another yard.
    func webViewURL(for route: BeadRoute) async -> URL? {
        guard resolvingWebView != route, card(for: route) != nil else { return nil }
        webViewError = nil
        let direct = isDirect(route.yard)
        let handle: String
        if route.yard.isEmpty && !direct {
            resolvingWebView = route
            defer {
                if resolvingWebView == route { resolvingWebView = nil }
            }
            do {
                handle = try await pairer.accountHandleForWebView()
            } catch let error as ApiError {
                webViewError = "Could not open the web view: \(words(error))"
                return nil
            } catch {
                webViewError = "Could not open the web view: \(words(ApiError.down(why: "an unexpected error")))"
                return nil
            }
        } else {
            handle = direct ? "" : (records.kept.account?.handle ?? "")
        }
        guard let latest = card(for: route) else { return nil }
        let link = webViewUrl(origin: origins(route.yard), yard: direct ? "" : route.yard, handle: handle, bead: latest.bead.id)
        guard let url = URL(string: link) else {
            webViewError = "Could not open the web view: the address is invalid."
            return nil
        }
        return url
    }

    /// The card's Ask: the yardmaster's conversation is pushed onto the
    /// crew stack, its draft starting with the bead's id.
    func askYardmaster(about bead: String) {
        guard let yard = openedYard else { return }
        conversation.askAbout(yard: yard, bead: bead)
        nav.place = .crew
        nav.openConversation(yard: yard, with: yardmaster)
    }

    private func lineDepot(_ depot: FlowDepot, me: String, filter: LineFilter) -> LineDepot {
        LineDepot(
            name: depot.name,
            travelling: depot.travelling,
            error: depot.error,
            flows: depot.flows.map { flow in
                LineFlow(
                    name: flow.name,
                    stages: lineStages(flow.stages).map { stage in
                        LineStage(
                            name: stage.stage,
                            words: groupWords(stage),
                            beads: stage.beads.filter { matches($0, filter: filter, me: me) }.map(lineBead),
                            backlog: stage.stage == backlogStage,
                            open: expanded.contains(BacklogKey(depot: depot.name, flow: flow.name, stage: stage.stage)),
                            waits: stage.beads.filter { waitsOnYou(remark: $0.remark, me: me) }.count
                        )
                    }
                )
            },
            elsewhere: depot.elsewhere.filter { matches($0, filter: filter, me: me) }.map(lineBead)
        )
    }

    private func attach(_ yard: String) {
        guard let followed = followers()[yard] else { return }
        lastLoaded = followed.state.loaded
        applied = followed.state.lastSeq
        let id = followed.observe { [weak self] _ in
            self?.followedChanged(yard)
        }
        observed = (followed, id)
        if followed.state.loaded != nil {
            reread()
        }
    }

    private func detach() {
        if let watched = observed {
            watched.followed.removeObserver(watched.id)
            observed = nil
        }
    }

    private func followedChanged(_ yard: String) {
        guard active, openedYard == yard, let followed = followers()[yard] else { return }
        if let watched = observed, (watched.followed as AnyObject) !== (followed as AnyObject) {
            detach()
            attach(yard)
            return
        }
        let current = followed.state
        if current.loaded != lastLoaded {
            lastLoaded = current.loaded
            applied = current.lastSeq
            if current.loaded != nil {
                reread()
            }
            return
        }
        // A read covers every event applied before it was served, so
        // what is newer than the last seq seen when it started moves
        // the next one; what arrived meanwhile reads again at once,
        // never missed. Only the events seen move the cursor: the last
        // seq may run ahead of them between calls, and following it
        // would skip an event not yet in the array.
        let fresh = current.events.filter { $0.seq > applied }
        applied = current.events.reduce(applied) { max($0, $1.seq) }
        if fresh.contains(where: movesLine) {
            reread()
        }
    }

    private func reread() {
        readTask?.cancel()
        readTask = Task { @MainActor in await readNow() }
    }

    private func readNow() async {
        guard let yard = openedYard, let followed = followers()[yard] else { return }
        let gen = generation
        readGeneration += 1
        let read = readGeneration
        do {
            let fresh = try await followed.flows()
            guard current(yard: yard, followed: followed, gen: gen, read: read) else { return }
            // Cleared before the board lands, so no frame pairs the new
            // board with the old error.
            errorText = nil
            board = fresh
            // A chip can be opened before this place has read its board.
            // If the board now holds that bead, it is a board card, so
            // let the usual board lifetime close it when it leaves.
            let nowOnBoard = closedCards.filter { id in
                holds(fresh, .bead(BeadRoute(yard: yard, bead: id)))
            }
            closedCards.subtract(nowOnBoard)
            // A line or a bead the board no longer holds leaves for what
            // is under it. A card standing on its `Bead` read stays: the
            // board holds no closed bead.
            nav.closeLines { route in
                guard route.yard == yard, !holds(fresh, route) else { return false }
                if case .bead(let bead) = route { return !closedCards.contains(bead.bead) }
                return true
            }
            // The cards that stand read their beads again with the
            // board, so a note written meanwhile shows on its card.
            for route in nav.linesPath {
                if case .bead(let bead) = route, bead.yard == yard {
                    await readDetails(of: bead.bead)
                }
            }
        } catch is CancellationError {
            return
        } catch let error as ApiError {
            guard current(yard: yard, followed: followed, gen: gen, read: read) else { return }
            errorText = words(error)
        } catch {
            guard current(yard: yard, followed: followed, gen: gen, read: read) else { return }
            errorText = words(ApiError.down(why: "an unexpected error"))
        }
    }

    /// Reads the bead whole for its card. What it answers lands while
    /// this is the card's latest read and the yard is still the one
    /// shown; a failure keeps what an earlier read gave and says why on
    /// the card, which stays whole.
    private func readDetails(of id: String) async {
        guard let yard = openedYard, let followed = followers()[yard] else { return }
        let gen = generation
        let token = UUID()
        cardReading[id] = token
        defer {
            if cardReading[id] == token {
                cardReading.removeValue(forKey: id)
            }
        }
        func landed() -> Bool {
            guard active, openedYard == yard, generation == gen, cardReading[id] == token,
                  let current = followers()[yard]
            else { return false }
            return (current as AnyObject) === (followed as AnyObject)
        }
        do {
            let bead = try await followed.bead(id)
            guard landed() else { return }
            cardReads[id] = CardRead(bead: bead)
        } catch is CancellationError {
            return
        } catch let error as ApiError {
            guard landed() else { return }
            cardReads[id, default: CardRead()].error = "Details not read: \(words(error))"
        } catch {
            guard landed() else { return }
            cardReads[id, default: CardRead()].error = "Details not read: \(words(ApiError.down(why: "an unexpected error")))"
        }
    }

    /// An older request or the previous yard's late reply cannot replace
    /// the board a newer screen read is drawing.
    private func current(yard: String, followed: any Followed, gen: Int, read: Int) -> Bool {
        guard active, openedYard == yard, generation == gen, readGeneration == read,
              let current = followers()[yard]
        else { return false }
        return (current as AnyObject) === (followed as AnyObject)
    }
}

/// What the `Bead` call last answered for a card's bead, and why the
/// last read said something.
private struct CardRead {
    var bead: Bead? = nil
    var error: String? = nil
}

/// A card's details from the bead as the yard last answered it: its
/// labels, its body and its notes, the newest last. The yard serves the
/// notes oldest first; the order by seq stands where it serves them
/// otherwise, and notes of one seq keep the order served. With no bead
/// read yet there is nothing to show but why.
func cardDetails(_ bead: Bead?, error: String?, now: Date, zone: TimeZone) -> CardDetails {
    guard let bead else { return CardDetails(error: error) }
    let notes = bead.notes.enumerated()
        .sorted { ($0.element.seq, $0.offset) < ($1.element.seq, $1.offset) }
        .map { CardNote(author: $0.element.author, at: stamp($0.element.at, now: now, zone: zone), text: $0.element.text) }
    return CardDetails(read: true, labels: bead.labels, body: bead.body, notes: notes, error: error)
}

/// The yard serves stages in travel order; the backlog is the one row
/// the line puts last. Filtering preserves the order of every other stage.
private func lineStages(_ stages: [FlowStage]) -> [FlowStage] {
    stages.filter { $0.stage != backlogStage } + stages.filter { $0.stage == backlogStage }
}

/// The backlog stage, shown last and collapsed: a queue to shape, not
/// work in transit.
let backlogStage = "backlog"

/// The head words: `7 travelling · 1 working`, the working the beads
/// with a session on them.
func headWords(_ board: Flows) -> String {
    var working = board.unassigned.filter { $0.working }.count
    for depot in board.depots {
        working += depot.elsewhere.filter { $0.working }.count
        for flow in depot.flows {
            for stage in flow.stages {
                working += stage.beads.filter { $0.working }.count
            }
        }
    }
    return "\(board.travelling) travelling · \(working) working"
}

/// A stage's group words, as footplate's `stage_group_words` says them:
/// the group's name, `waiting on a person` where it is manual, and its
/// seats where the yard serves them.
func groupWords(_ stage: FlowStage) -> String {
    if stage.group.isEmpty { return "no route matches" }
    var words = [stage.group]
    if stage.human { words.append("waiting on a person") }
    if let limit = stage.limit, let taken = stage.taken {
        words.append(limit == 0 ? "paused" : "\(taken) of \(limit) seats")
    }
    return words.joined(separator: " · ")
}

/// Who works a bead: `worked by <group> · <kind>/<model>`, of what the
/// yard serves; nil where it names nobody.
func workedBy(_ bead: FlowBead) -> String? {
    guard bead.working else { return nil }
    var served: [String] = []
    if !bead.group.isEmpty { served.append(bead.group) }
    let run = [bead.kind, bead.model].filter { !$0.isEmpty }.joined(separator: "/")
    if !run.isEmpty { served.append(run) }
    guard !served.isEmpty else { return nil }
    return "worked by " + served.joined(separator: " · ")
}

func lineBead(_ bead: FlowBead) -> LineBead {
    LineBead(
        id: bead.bead,
        title: bead.title,
        remark: bead.remark,
        working: bead.working,
        workedBy: workedBy(bead)
    )
}

/// Whether the remark waits on the reader, as footplate's
/// `waits_on_you` has it: `waits for` with them among the names.
func waitsOnYou(remark: String, me: String) -> Bool {
    guard !me.isEmpty else { return false }
    return waitsNames(remark)?.contains(me) ?? false
}

private func waitsNames(_ remark: String) -> [String]? {
    guard remark.hasPrefix("waits for ") else { return nil }
    return remark.dropFirst("waits for ".count).split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// Whether the remark is a hold, as footplate's `is_held` has it.
func isHeld(remark: String) -> Bool {
    remark == "held" || remark.hasPrefix("held by ")
}

/// Whether the remark is a late mark: `late`, or `late by 40m`.
func isLate(remark: String) -> Bool {
    remark == "late" || remark.hasPrefix("late by ")
}

/// The remark with `you` where it names the reader, as footplate's
/// `you_first` has it.
func youFirst(remark: String, me: String) -> String {
    if remark.hasPrefix("held by ") {
        let holder = remark.dropFirst("held by ".count).trimmingCharacters(in: .whitespaces)
        return !me.isEmpty && holder == me ? "held by you" : remark
    }
    guard let names = waitsNames(remark), !me.isEmpty, names.contains(me) else { return remark }
    let others = names.filter { $0 != me }
    return others.isEmpty ? "waits for you" : "waits for you, " + others.joined(separator: ", ")
}

/// Whether the bead matches the overview's filter.
func matches(_ bead: FlowBead, filter: LineFilter, me: String) -> Bool {
    switch filter {
    case .all: return true
    case .moving: return bead.working
    case .yourTurn: return waitsOnYou(remark: bead.remark, me: me)
    case .held: return isHeld(remark: bead.remark)
    case .late: return isLate(remark: bead.remark)
    }
}

/// A stage's state: the served fault or turn, moving where a bead is
/// worked, and nothing where no bead stands, as footplate's
/// `stage_lamp` has it.
func stageStateOf(_ stage: FlowStage) -> StageState {
    guard !stage.beads.isEmpty else { return .none }
    switch stage.lamp {
    case "fault": return .broken
    case "turn": return .yourTurn
    default: return stage.beads.contains { $0.working } ? .moving : .none
    }
}

/// How long ago the bead landed (`41m ago`), from the clock the
/// yard serves; empty where it has none.
func landedAgo(landedAt: String, now: Date) -> String {
    guard !landedAt.isEmpty, let then = parseInstant(landedAt) else { return "" }
    let minutes = Int(now.timeIntervalSince(then) / 60)
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes)m ago" }
    if minutes < 60 * 24 { return "\(minutes / 60)h ago" }
    return "\(minutes / (60 * 24))d ago"
}

/// How long the bead has stood in its stage (`41m`), from the clock
/// the yard serves; empty where it has none.
func stayWords(enteredAt: String, now: Date) -> String {
    guard !enteredAt.isEmpty, let then = parseInstant(enteredAt) else { return "" }
    let minutes = Int(now.timeIntervalSince(then) / 60)
    guard minutes >= 1 else { return "" }
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 60 * 24 { return "\(minutes / 60)h" }
    return "\(minutes / (60 * 24))d"
}

/// The worst of the states: broken, your turn, moving, none.
func worstOf(_ states: [StageState]) -> StageState {
    for state in [StageState.broken, .yourTurn, .moving] {
        if states.contains(state) { return state }
    }
    return .none
}

/// The overview's stats over every bead in transit: the stages but
/// the backlogs, the Elsewhere rows and the beads with no line.
func lineStats(_ board: Flows, me: String) -> LineStats {
    let beads = transitBeads(board)
    return LineStats(
        inTransit: board.travelling,
        moving: beads.filter { $0.working }.count,
        yourTurn: beads.filter { waitsOnYou(remark: $0.remark, me: me) }.count,
        held: beads.filter { isHeld(remark: $0.remark) }.count,
        late: beads.filter { isLate(remark: $0.remark) }.count
    )
}

/// Every bead in transit: the stages but the backlogs, the Elsewhere
/// rows and the beads with no line.
func transitBeads(_ board: Flows) -> [FlowBead] {
    var beads: [FlowBead] = []
    for depot in board.depots {
        for flow in depot.flows {
            for stage in flow.stages where stage.stage != backlogStage {
                beads += stage.beads
            }
        }
        beads += depot.elsewhere
    }
    beads += board.unassigned
    return beads
}

/// The overview's lines: one card per depot flow with something
/// moving, and the quiet lines' chips. Lines with no matching bead
/// are hidden while a filter holds; the chips show only unfiltered.
func lineCards(board: Flows, me: String, filter: LineFilter) -> (lines: [LineCard], quiet: [QuietLine]) {
    var lines: [LineCard] = []
    var quiet: [QuietLine] = []
    for depot in board.depots {
        for flow in depot.flows {
            let stages = backlogFirst(flow.stages)
            let travelling = stages.filter { $0.stage != backlogStage }.flatMap { $0.beads }
            let beads = travelling.filter { matches($0, filter: filter, me: me) }.map { $0.bead }
            let states = stages.map(stageStateOf)
            let card = LineCard(
                depot: depot.name,
                flow: flow.name,
                title: "\(depot.name) · \(flow.name)",
                lamp: worstOf(states),
                stages: stages.map { StripStage(name: $0.stage, state: stageStateOf($0), human: $0.human) },
                beads: beads,
                inTransit: travelling.count,
                backlog: stages.filter { $0.stage == backlogStage }.reduce(0) { $0 + $1.beads.count },
                quiet: travelling.allSatisfy { !$0.working && $0.remark.isEmpty }
                    && !states.contains(.broken) && !states.contains(.yourTurn)
            )
            if card.quiet {
                if filter == .all {
                    quiet.append(QuietLine(depot: depot.name, flow: flow.name, title: card.title))
                }
            } else if filter == .all || !beads.isEmpty {
                lines.append(card)
            }
        }
    }
    return (lines, quiet)
}

/// The backlog first; every other stage keeps travel order. The strip
/// and the route map draw it so, where the board's rows put it last.
private func backlogFirst(_ stages: [FlowStage]) -> [FlowStage] {
    stages.filter { $0.stage == backlogStage } + stages.filter { $0.stage != backlogStage }
}

/// One depot's flow; nil where the depot or the flow is none.
private func flowNamed(_ board: Flows, depot: String, flow: String) -> DepotFlow? {
    board.depots.first { $0.name == depot }?.flows.first { $0.name == flow }
}

/// Whether the board still holds what a pushed route shows: the flow of
/// a line, the bead of a card, open or landed.
private func holds(_ board: Flows, _ route: LinesRoute) -> Bool {
    switch route {
    case .line(let line):
        return flowNamed(board, depot: line.depot, flow: line.flow) != nil
    case .bead(let bead):
        return board.unassigned.contains { $0.bead == bead.bead }
            || board.depots.contains { depot in
                depot.elsewhere.contains { $0.bead == bead.bead }
                    || depot.flows.contains { flow in
                        flow.stages.contains { stage in stage.beads.contains { $0.bead == bead.bead } }
                            || flow.landings.contains { $0.bead == bead.bead }
                    }
            }
    }
}

/// One line as its route map: every stage a station from top to
/// bottom, the backlog first and the landed stage last, the flow's
/// landings under the landed station. Nil where the depot or the flow
/// is none. The whole line, whatever filter the overview holds.
func lineRoute(
    board: Flows,
    me: String,
    depot: String,
    flow: String,
    now: Date,
    expanded: Set<BacklogKey>
) -> RouteMap? {
    guard let served = flowNamed(board, depot: depot, flow: flow) else { return nil }
    let ordered = backlogFirst(served.stages)
    let travelling = ordered.filter { $0.stage != backlogStage }.reduce(0) { $0 + $1.beads.count }
    return RouteMap(
        depot: depot,
        flow: flow,
        title: "\(depot) · \(flow)",
        head: "\(travelling) in transit",
        stations: ordered.map { stage in
            Station(
                name: stage.stage,
                words: groupWords(stage),
                state: stageStateOf(stage),
                human: stage.human,
                beads: stage.beads.map {
                    stationBead($0, me: me, now: now, waitsSeat: waitsForSeat($0, in: stage))
                },
                landings: stage.terminal ? served.landings.map { landedBead($0, now: now) } : [],
                backlog: stage.stage == backlogStage,
                open: expanded.contains(BacklogKey(depot: depot, flow: flow, stage: stage.stage)),
                waits: stage.beads.filter { waitsOnYou(remark: $0.remark, me: me) }.count
            )
        }
    )
}

/// One landing as its row, the order served (newest first) kept.
private func landedBead(_ landing: FlowLanding, now: Date) -> LandedBead {
    LandedBead(id: landing.bead, title: landing.title, ago: landedAgo(landedAt: landing.landedAt, now: now))
}

private func stationBead(_ bead: FlowBead, me: String, now: Date, waitsSeat: Bool) -> StationBead {
    StationBead(
        id: bead.bead,
        title: bead.title,
        remark: youFirst(remark: bead.remark, me: me),
        working: bead.working,
        worker: workerSession(bead.worker),
        workedBy: workedBy(bead),
        stay: stayWords(enteredAt: bead.enteredStageAt, now: now),
        // The yard prints a dash where it has no range.
        expected: bead.expected == "—" ? "" : bead.expected,
        waitsSeat: waitsSeat
    )
}

/// One bead's card from the board: on its line with the strip, in a
/// depot's Elsewhere, with no line, or landed under its line's landed
/// station. Nil where the board holds no bead of `id`. The whole
/// card, whatever filter the overview holds.
func beadCard(
    board: Flows,
    me: String,
    now: Date,
    origin: String,
    yard: String,
    handle: String,
    id: String
) -> BeadCard? {
    let webView = webViewUrl(origin: origin, yard: yard, handle: handle, bead: id)
    for depot in board.depots {
        for flow in depot.flows {
            for stage in flow.stages {
                guard let bead = stage.beads.first(where: { $0.bead == id }) else { continue }
                let shown = stationBead(bead, me: me, now: now, waitsSeat: waitsForSeat(bead, in: stage))
                let line = "\(depot.name) · \(flow.name)"
                return BeadCard(
                    bead: shown,
                    line: line,
                    stage: stage.stage,
                    stages: backlogFirst(flow.stages).map {
                        StripStage(name: $0.stage, state: stageStateOf($0), human: $0.human)
                    },
                    head: cardHead(line: line, stage: stage.stage, bead: shown),
                    webView: webView
                )
            }
        }
        if let bead = depot.elsewhere.first(where: { $0.bead == id }) {
            let line = "\(depot.name) · Elsewhere"
            return BeadCard(
                bead: stationBead(bead, me: me, now: now, waitsSeat: false),
                line: line, stage: "", stages: [], head: line, webView: webView
            )
        }
    }
    if let bead = board.unassigned.first(where: { $0.bead == id }) {
        return BeadCard(
            bead: stationBead(bead, me: me, now: now, waitsSeat: false),
            line: "No line", stage: "", stages: [], head: "No line", webView: webView
        )
    }
    // A landed bead stands at the landed station: the strip with it
    // marked, and the head naming it.
    for depot in board.depots {
        for flow in depot.flows {
            guard let landing = flow.landings.first(where: { $0.bead == id }) else { continue }
            let shown = StationBead(id: landing.bead, title: landing.title)
            let line = "\(depot.name) · \(flow.name)"
            let terminal = flow.stages.first { $0.terminal }?.stage ?? ""
            return BeadCard(
                bead: shown,
                line: line,
                stage: terminal,
                stages: backlogFirst(flow.stages).map {
                    StripStage(name: $0.stage, state: stageStateOf($0), human: $0.human)
                },
                head: terminal.isEmpty ? line : cardHead(line: line, stage: terminal, bead: shown),
                webView: webView
            )
        }
    }
    return nil
}

/// One bead's card where the board holds no such bead: a closed bead
/// opened from mail stands on the `Bead` call's read, with no line.
/// The title and the stage are the read's, empty where it has not
/// answered yet.
func closedCard(read: Bead?, id: String, origin: String, yard: String, handle: String) -> BeadCard {
    let stage = read?.stage ?? ""
    return BeadCard(
        bead: StationBead(id: id, title: read?.title ?? ""),
        line: "No line",
        stage: stage,
        stages: [],
        head: stage.isEmpty ? "No line" : "No line · \(stage)",
        webView: webViewUrl(origin: origin, yard: yard, handle: handle, bead: id)
    )
}

/// A card's head: `yard · default · new for 41m · expected 11–25m`.
func cardHead(line: String, stage: String, bead: StationBead) -> String {
    var words = [line, stage + (bead.stay.isEmpty ? "" : " for \(bead.stay)")]
    if !bead.expected.isEmpty { words.append("expected \(bead.expected)") }
    return words.joined(separator: " · ")
}

/// The yard's web view URL for one bead: the edge serves the yard's
/// pages, `?yard=` picking the yard (edge.md), and a bead's page is
/// `/beads/<id>` (web.md). The parameter is always sent: without it the
/// edge serves the yard its browser's `edge_yard` cookie names, which an
/// earlier visit to a named yard left, and only a browser with no cookie
/// gets the account's own. The account's own yard, named `""`, is named
/// by the account's `handle`, as the edge takes it. A session kept
/// before the handle was resolves it before the card opens this link.
/// A yard of its own serves its pages itself, at its own address, with
/// no yard named. The id arrives from the yard: it stays one path
/// segment whatever it holds, never the URL's shape.
func webViewUrl(origin: String, yard: String, handle: String, bead: String) -> String {
    let page = "\(origin)/beads/\(urlEscaped(bead))"
    let name = yard.isEmpty ? handle : yard
    return name.isEmpty ? page : "\(page)?yard=\(urlEscaped(name))"
}

/// Percent-encoded but for the unreserved characters of RFC 3986.
private func urlEscaped(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
}

private let unreservedCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

/// The session a worker names: without its runner word where the
/// runner is herdr, as footplate's `worker_session` has it.
func workerSession(_ worker: String) -> String {
    removing(prefix: "herdr ", from: worker)
}

/// Whether the bead waits for a seat at its stage, as footplate's
/// `waits_for_seat` has it: unclaimed, its remark naming no held,
/// blocked or waiting state, and its group's seats all taken.
func waitsForSeat(_ bead: FlowBead, in stage: FlowStage) -> Bool {
    if bead.working { return false }
    if bead.tone == "red"
        || isHeld(remark: bead.remark)
        || bead.remark.hasPrefix("blocked by ")
        || bead.remark.hasPrefix("waits for ")
    {
        return false
    }
    guard let limit = stage.limit, let taken = stage.taken else { return false }
    return limit > 0 && taken >= limit
}

/// Who works the bead with its stay: `train-new · 41m`, the longer
/// words where the yard names no session.
func workerWords(_ bead: StationBead) -> String {
    let who = bead.worker.isEmpty ? removing(prefix: "worked by ", from: bead.workedBy ?? "") : bead.worker
    return [who, bead.stay].filter { !$0.isEmpty }.joined(separator: " · ")
}

/// A bead card's faint line: its remark, that it waits for a seat,
/// and the yard's expected range; nil where there is none.
func beadMeta(_ bead: StationBead) -> String? {
    var parts: [String] = []
    if !bead.remark.isEmpty { parts.append(bead.remark) }
    if bead.waitsSeat { parts.append("waits for a seat") }
    if !bead.expected.isEmpty { parts.append("expected \(bead.expected)") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// The text without `prefix`, where it starts with it.
private func removing(prefix: String, from text: String) -> String {
    text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
}

/// Whether an event of the stream moves the line: every event about a
/// bead does, and the events that move its other inputs though they name
/// none (docs/api.md with the call), as footplate has it.
func movesLine(_ event: Event) -> Bool {
    if !event.bead.isEmpty { return true }
    if lineInputs.contains(event.kind) { return true }
    if event.kind == "setting_changed" {
        return event.text("key") == "max_sessions" || event.text("key") == "operator"
    }
    return false
}

private let lineInputs: Set<String> = [
    "group_set",
    "group_removed",
    "route_added",
    "route_set",
    "route_removed",
    "flow_set",
    "flow_removed",
    "flow_pointer_set",
    "flow_pointer_cleared",
    "depot_updated",
    "depot_removed",
]
