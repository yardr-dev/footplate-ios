import Foundation

// One yard's line: the flows view, read-only (design 3.5, after
// Android's model/LineModel.kt): the overview with its stats as
// filters, a card per moving line and the quiet lines' chips, the
// Elsewhere rows and the beads with no line. Read when the place
// opens, read again on pull-to-refresh and on every stream event
// that moves it, the way footplate reads Flows again; no polling.
// A line tap does nothing yet: the route map opens it.

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

/// A quiet line's chip.
struct QuietLine: Equatable, Sendable {
    var depot: String
    var flow: String
    var title: String
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
private struct BacklogKey: Hashable {
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

    /// The followed yards by name at the edge; set by the app once
    /// its services stand, since the followers are rebuilt with them.
    var followers: @MainActor () -> [String: any Followed]
    private var active = false
    private var generation = 0
    private var readGeneration = 0
    private var readTask: Task<Void, Never>? = nil

    init(followers: @escaping @MainActor () -> [String: any Followed]) {
        self.followers = followers
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

    /// An older request or the previous yard's late reply cannot replace
    /// the board a newer screen read is drawing.
    private func current(yard: String, followed: any Followed, gen: Int, read: Int) -> Bool {
        guard active, openedYard == yard, generation == gen, readGeneration == read,
              let current = followers()[yard]
        else { return false }
        return (current as AnyObject) === (followed as AnyObject)
    }
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
            // The backlog first; every other stage keeps travel order.
            let stages = flow.stages.filter { $0.stage == backlogStage }
                + flow.stages.filter { $0.stage != backlogStage }
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
