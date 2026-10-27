@testable import Footplate
import Foundation
import XCTest

// The line over fake-followed boards (design 3.5, after Android's
// LineModelTest): the overview with its stats, cards and quiet chips,
// a stat filtering it, the board drawn with its head words, a failed
// read said and cleared, an unreadable depot in the yard's own words,
// the place following a yard switch, the backlog opening and
// shutting, a line pushed as its route map, and a bead pushed as its
// card with its Ask and its web view.
@MainActor
final class LineModelTests: XCTestCase {
    private var home: FakeFollowed!
    private var laptop: FakeFollowed!
    private var nav: Nav!
    private var records: Records!
    private var fake: FakeYard!
    private var pairer: Pairer!
    private var conversation: ConversationModel!
    private var model: LineModel!

    override func setUp() {
        super.setUp()
        home = FakeFollowed()
        laptop = FakeFollowed()
        nav = Nav(place: .lines)
        records = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: "https://edge.example")
        records.keepSession(account: "jo@example.com", handle: "jo", session: "ory_st_line")
        fake = FakeYard()
        pairer = Pairer(edge: try! fake.edge(), records: records)
        let now = parseInstant("2026-10-08T10:11:00Z")!
        let mailroom = Mailroom()
        mailroom.setFollowers(["": home, "laptop": laptop])
        // The Ask reaches the real conversation model; no picture is
        // ever fetched, so its directory is never made.
        conversation = ConversationModel(
            mailroom: mailroom,
            pictures: Pictures(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pictures-\(UUID().uuidString)")),
            now: { now }, zone: { TimeZone(secondsFromGMT: 0)! }
        )
        model = LineModel(followers: { [home, laptop] in
            ["": home!, "laptop": laptop!]
        }, records: records, pairer: pairer, nav: nav, conversation: conversation, origins: { _ in "https://edge.example" }, now: { now })
    }

    override func tearDown() {
        model.leave()
        conversation.leave()
        model = nil
        conversation = nil
        pairer = nil
        fake = nil
        records = nil
        nav = nil
        home = nil
        laptop = nil
        super.tearDown()
    }

    func testTheLineShowsTheBoardWithItsHeadWords() async throws {
        home.up(loaded())
        home.board = board()
        model.open(yard: "")
        try await waitRead()

        let state = model.state
        XCTAssertEqual(state.head, "7 travelling · 1 working")
        XCTAssertEqual(state.depots.map(\.name), ["yard", "drafts"])
        XCTAssertEqual(state.depots[0].travelling, 5)
        XCTAssertEqual(state.depots[0].flows.map(\.name), ["default"])
        // The backlog is served first and shown last.
        XCTAssertEqual(state.depots[0].flows[0].stages.map(\.name), ["new", "review", "decide", "backlog"])
        let new = state.depots[0].flows[0].stages[0]
        XCTAssertEqual(new.words, "muse-builders · 2 of 4 seats")
        XCTAssertFalse(new.backlog)
        XCTAssertEqual(new.beads.map(\.id), ["yd-gate", "yd-train"])
        XCTAssertEqual(new.beads[0].remark, "blocked by yd-train")
        XCTAssertTrue(new.beads[1].working)
        XCTAssertEqual(new.beads[1].workedBy, "worked by muse-builders · claude/opus")
        XCTAssertEqual(state.depots[0].flows[0].stages[2].words, "mckean · waiting on a person · 0 of 1 seats")
        let backlog = state.depots[0].flows[0].stages[3]
        XCTAssertTrue(backlog.backlog)
        XCTAssertFalse(backlog.open)
        XCTAssertEqual(backlog.waits, 1)
        XCTAssertEqual(state.depots[0].elsewhere.map(\.id), ["yd-fence"])
        XCTAssertEqual(state.depots[0].elsewhere[0].remark, "held by yardmaster")
        XCTAssertEqual(state.unassigned.map(\.id), ["yd-crm"])
        XCTAssertNil(state.error)
        XCTAssertEqual(home.flowCalls, 1)
    }

    func testRefreshReadsTheBoardAgain() async throws {
        home.up(loaded())
        home.board = board()
        model.open(yard: "")
        try await waitRead()

        home.board = Flows(travelling: 1, depots: [], unassigned: [])
        await model.refresh()

        XCTAssertEqual(model.state.head, "1 travelling · 0 working")
        XCTAssertTrue(model.state.empty)
        XCTAssertEqual(home.flowCalls, 2)
    }

    func testTheBoardIsReadAgainOnEveryEventThatMovesItAndOnNoOther() async throws {
        home.up(loaded())
        home.board = board()
        model.open(yard: "")
        try await waitRead()
        XCTAssertEqual(home.flowCalls, 1)

        home.event(Event(seq: 152, kind: "mail", actor: "yardmaster", at: "2026-10-08T11:00:00Z"))
        try await settle()
        XCTAssertEqual(home.flowCalls, 1)

        home.event(Event(seq: 153, kind: "noted", actor: "yardmaster", at: "2026-10-08T11:01:00Z", bead: "yd-shed"))
        try await waitFlowCalls(home, 2)

        home.event(Event(seq: 154, kind: "flow_set", actor: "yard", at: "2026-10-08T11:02:00Z"))
        try await waitFlowCalls(home, 3)
    }

    func testABacklogOpensAndShuts() async throws {
        home.up(loaded())
        home.board = board()
        model.open(yard: "")
        try await waitRead()

        // The route map's backlog station opens and shuts with it.
        let route = LineRoute(yard: "", depot: "yard", flow: "default")
        XCTAssertEqual(model.routeMap(for: route)?.stations.first?.open, false)
        model.toggleBacklog(depot: "yard", flow: "default", stage: "backlog")
        XCTAssertTrue(model.state.depots[0].flows[0].stages[3].open)
        XCTAssertEqual(model.routeMap(for: route)?.stations.first?.open, true)
        model.toggleBacklog(depot: "yard", flow: "default", stage: "backlog")
        XCTAssertFalse(model.state.depots[0].flows[0].stages[3].open)
        XCTAssertEqual(model.routeMap(for: route)?.stations.first?.open, false)
    }

    func testAFailedReadSaysWhyAndTheNextReadClearsIt() async throws {
        home.up(loaded())
        home.refuse = .away
        model.open(yard: "")
        try await waitError()

        XCTAssertFalse(model.state.read)
        XCTAssertEqual(model.state.error, "The yard is away: the edge cannot reach it.")

        home.refuse = nil
        home.board = board()
        await model.refresh()
        XCTAssertTrue(model.state.read)
        XCTAssertNil(model.state.error)
        XCTAssertEqual(home.flowCalls, 2)
    }

    func testADepotWhoseFlowsCouldNotBeReadShowsTheYardsWords() async throws {
        home.up(loaded())
        home.board = Flows(
            travelling: 1,
            depots: [
                FlowDepot(
                    name: "mill",
                    travelling: 1,
                    elsewhere: [FlowBead(bead: "yd-wheel", title: "Mend the wheel")],
                    error: "the flows could not be read; why is an operator's to read"
                )
            ],
            unassigned: []
        )
        model.open(yard: "")
        try await waitRead()

        XCTAssertEqual(model.state.depots.map(\.name), ["mill"])
        XCTAssertEqual(model.state.depots[0].error, "the flows could not be read; why is an operator's to read")
        XCTAssertEqual(model.state.depots[0].elsewhere.map(\.id), ["yd-wheel"])
    }

    func testThePlaceFollowsAYardSwitch() async throws {
        home.up(loaded())
        laptop.up(loaded())
        home.board = board()
        laptop.board = Flows(
            travelling: 2,
            depots: [
                FlowDepot(
                    name: "mill",
                    travelling: 2,
                    flows: [
                        DepotFlow(
                            name: "default",
                            stages: [
                                FlowStage(
                                    stage: "new",
                                    group: "mill-builders",
                                    beads: [
                                        FlowBead(bead: "yd-wheel", title: "Mend the wheel"),
                                        FlowBead(bead: "yd-race", title: "Clear the race"),
                                    ]
                                )
                            ]
                        )
                    ]
                )
            ],
            unassigned: []
        )
        model.open(yard: "")
        try await waitRead()
        XCTAssertEqual(model.state.depots.map(\.name), ["yard", "drafts"])

        model.open(yard: "laptop")
        try await waitFor("the laptop's board") { [model] in
            model?.state.depots.map(\.name) == ["mill"]
        }
        XCTAssertEqual(model.state.head, "2 travelling · 0 working")
        XCTAssertEqual(home.flowCalls, 1)
        XCTAssertEqual(laptop.flowCalls, 1)
    }

    func testTheOverviewShowsStatsCardsAndQuietChips() async throws {
        home.up(loaded())
        home.board = richBoard()
        model.open(yard: "")
        try await waitRead()

        let state = model.state
        XCTAssertEqual(state.stats, LineStats(inTransit: 7, moving: 1, yourTurn: 1, held: 1, late: 1))
        XCTAssertEqual(state.filter, .all)
        XCTAssertEqual(state.lines.map(\.title), ["yard · default", "drafts · default"])
        let yard = state.lines[0]
        XCTAssertEqual(yard.lamp, .broken)
        // The strip holds every stage, the backlog first.
        XCTAssertEqual(
            yard.stages,
            [
                StripStage(name: "backlog", state: .none, human: false),
                StripStage(name: "new", state: .broken, human: false),
                StripStage(name: "review", state: .yourTurn, human: false),
                StripStage(name: "decide", state: .none, human: true),
            ]
        )
        XCTAssertEqual(yard.beads, ["yd-gate", "yd-train", "yd-shed", "yd-seal"])
        XCTAssertEqual(yard.inTransit, 4)
        XCTAssertEqual(yard.backlog, 3)
        XCTAssertFalse(yard.quiet)
        // A late bead alone lights nothing, but the line is no quiet one.
        let drafts = state.lines[1]
        XCTAssertEqual(drafts.lamp, .none)
        XCTAssertEqual(drafts.beads, ["yd-greet", "yd-late"])
        XCTAssertFalse(drafts.quiet)
        // The line with nothing moving folds into a chip.
        XCTAssertEqual(state.quiet.map(\.title), ["signalbox · default"])
        XCTAssertEqual(state.quiet[0].depot, "signalbox")
        XCTAssertEqual(state.quiet[0].flow, "default")
    }

    func testAStatFiltersTheOverview() async throws {
        home.up(loaded())
        home.board = richBoard()
        model.open(yard: "")
        try await waitRead()
        XCTAssertEqual(model.state.lines.count, 2)

        model.filter(.late)
        var state = model.state
        XCTAssertEqual(state.filter, .late)
        XCTAssertEqual(state.lines.map(\.title), ["drafts · default"])
        XCTAssertEqual(state.lines[0].beads, ["yd-late"])
        XCTAssertTrue(state.quiet.isEmpty)
        XCTAssertTrue(state.unassigned.isEmpty)

        model.filter(.yourTurn)
        state = model.state
        XCTAssertEqual(state.lines.map(\.title), ["yard · default"])
        XCTAssertEqual(state.lines[0].beads, ["yd-shed"])

        // The held bead stands in Elsewhere, on no line: the lines go
        // empty and its row is what the filter shows.
        model.filter(.held)
        state = model.state
        XCTAssertTrue(state.lines.isEmpty)
        XCTAssertEqual(state.depots[0].elsewhere.map(\.id), ["yd-fence"])

        model.filter(.all)
        state = model.state
        XCTAssertEqual(state.filter, .all)
        XCTAssertEqual(state.lines.count, 2)
        XCTAssertFalse(state.quiet.isEmpty)
        XCTAssertEqual(state.lines[0].beads, ["yd-gate", "yd-train", "yd-shed", "yd-seal"])

        // A yard switch clears the filter.
        laptop.up(loaded())
        laptop.board = board()
        model.filter(.late)
        model.open(yard: "laptop")
        try await waitFor("the laptop's overview") { [model] in
            model?.state.read == true && model?.state.filter == .all
        }
        XCTAssertEqual(model.state.filter, .all)
    }

    func testALineOpensAsARouteMap() async throws {
        home.up(loaded())
        // The backlog is served last here and drawn first.
        var rich = richBoard()
        let served = rich.depots[0].flows[0].stages.removeFirst()
        rich.depots[0].flows[0].stages.append(served)
        home.board = rich
        model.open(yard: "")
        try await waitRead()

        model.openLine(depot: "yard", flow: "default")
        let route = LineRoute(yard: "", depot: "yard", flow: "default")
        XCTAssertEqual(nav.linesPath, [.line(route)])
        model.openLine(depot: "yard", flow: "default")
        XCTAssertEqual(nav.linesPath, [.line(route)], "opening what is pushed pushes nothing more")

        let map = try XCTUnwrap(model.routeMap(for: route))
        XCTAssertEqual(map.title, "yard · default")
        XCTAssertEqual(map.head, "4 in transit")
        XCTAssertEqual(map.stations.map(\.name), ["backlog", "new", "review", "decide"])
        XCTAssertEqual(map.stations.map(\.state), [.none, .broken, .yourTurn, .none])
        XCTAssertEqual(map.stations.map(\.human), [false, false, false, true])
        XCTAssertEqual(
            map.stations.map(\.words),
            [
                "no route matches", "muse-builders · 2 of 4 seats", "muse-reviewers · 1 of 2 seats",
                "mckean · waiting on a person · 0 of 1 seats",
            ]
        )
        // The backlog stands shut: its count and the waits on the reader
        // are what its row says, its beads what it opens on.
        let backlog = map.stations[0]
        XCTAssertTrue(backlog.backlog)
        XCTAssertFalse(backlog.open)
        XCTAssertEqual(backlog.beads.map(\.id), ["yd-draft-1", "yd-draft-2", "yd-draft-3"])
        XCTAssertEqual(backlog.waits, 2)
        let new = map.stations[1]
        XCTAssertFalse(new.backlog)
        XCTAssertEqual(new.beads.map(\.id), ["yd-gate", "yd-train"])
        XCTAssertEqual(new.beads[0].remark, "blocked by yd-train")
        XCTAssertFalse(new.beads[0].waitsSeat)
        let train = new.beads[1]
        XCTAssertEqual(
            train,
            StationBead(
                id: "yd-train", title: "Release train", working: true, worker: "train-new",
                workedBy: "worked by muse-builders · claude/opus", stay: "41m", expected: "11–25m"
            )
        )
        // The worker words name the session and the stay; the longer
        // words stand in where the yard names no session.
        XCTAssertEqual(workerWords(train), "train-new · 41m")
        XCTAssertEqual(beadMeta(train), "expected 11–25m")
        var unnamed = train
        unnamed.worker = ""
        XCTAssertEqual(workerWords(unnamed), "muse-builders · claude/opus · 41m")
        unnamed.workedBy = nil
        unnamed.stay = ""
        XCTAssertEqual(workerWords(unnamed), "")
        // The wait on the reader reads `you`.
        XCTAssertEqual(map.stations[2].beads.map(\.remark), ["waits for you"])
        XCTAssertEqual(beadMeta(map.stations[2].beads[0]), "waits for you")
        XCTAssertNil(beadMeta(map.stations[3].beads[0]))
        XCTAssertEqual(
            beadMeta(StationBead(id: "yd-late", title: "", remark: "late by 40m", expected: "5h–8h", waitsSeat: true)),
            "late by 40m · waits for a seat · expected 5h–8h"
        )

        // The whole line, whatever filter the overview holds.
        model.filter(.late)
        let filtered = try XCTUnwrap(model.routeMap(for: route))
        XCTAssertEqual(filtered, map)
        model.filter(.all)

        // The backlog opens where it shut and shuts where it opened.
        model.toggleBacklog(depot: "yard", flow: "default", stage: "backlog")
        XCTAssertEqual(model.routeMap(for: route)?.stations.map(\.open), [true, false, false, false])
        model.toggleBacklog(depot: "yard", flow: "default", stage: "backlog")
        XCTAssertEqual(model.routeMap(for: route)?.stations.map(\.open), [false, false, false, false])
    }

    func testAFullStageNamesWaitsForASeatAndNoOtherReason() async throws {
        home.up(loaded())
        home.board = richBoard()
        model.open(yard: "")
        try await waitRead()

        // The plain bead on the full stage waits for a seat; the late
        // mark waits too, but its remark says why instead.
        let map = try XCTUnwrap(model.routeMap(for: LineRoute(yard: "", depot: "drafts", flow: "default")))
        XCTAssertEqual(map.head, "2 in transit")
        XCTAssertEqual(map.stations.map(\.name), ["new", "shipped"])
        XCTAssertEqual(map.stations[0].beads.map(\.waitsSeat), [true, true])
        XCTAssertEqual(map.stations[0].beads[1].remark, "late by 40m")
        XCTAssertEqual(beadMeta(map.stations[0].beads[0]), "waits for a seat")
        // A stage nobody stands in is still a station.
        XCTAssertEqual(map.stations[1].beads, [])
        XCTAssertEqual(map.stations[1].state, .none)
        XCTAssertTrue(map.stations[1].human)

        let full = FlowStage(stage: "new", limit: 1, taken: 1)
        let room = FlowStage(stage: "new", limit: 2, taken: 1)
        let unrouted = FlowStage(stage: "new")
        let plain = FlowBead(bead: "yd-plain")
        XCTAssertTrue(waitsForSeat(plain, in: full))
        XCTAssertTrue(waitsForSeat(FlowBead(bead: "yd-late", remark: "late by 40m", tone: "amber"), in: full))
        XCTAssertFalse(waitsForSeat(FlowBead(bead: "yd-work", working: true), in: full))
        XCTAssertFalse(waitsForSeat(FlowBead(bead: "yd-held", remark: "held by jo", tone: "red"), in: full))
        XCTAssertFalse(waitsForSeat(FlowBead(bead: "yd-stall", remark: "stalled", tone: "red"), in: full))
        XCTAssertFalse(waitsForSeat(FlowBead(bead: "yd-block", remark: "blocked by yd-train", tone: "amber"), in: full))
        XCTAssertFalse(waitsForSeat(FlowBead(bead: "yd-wait", remark: "waits for jo", tone: "amber"), in: full))
        XCTAssertFalse(waitsForSeat(plain, in: room))
        XCTAssertFalse(waitsForSeat(plain, in: unrouted))
        XCTAssertFalse(waitsForSeat(plain, in: FlowStage(stage: "new", limit: 0, taken: 0)))
    }

    func testThePushedLineAndCardLeaveWithTheirYardAndTheirBoard() async throws {
        home.up(loaded())
        laptop.up(loaded())
        home.board = board()
        laptop.board = board()
        // No yard shown yet: a tap has nowhere to push.
        model.openLine(depot: "yard", flow: "default")
        model.openBead("yd-gate")
        XCTAssertEqual(nav.linesPath, [])
        model.open(yard: "")
        try await waitRead()

        // Nothing maps where no depot or flow is, or the yard is another's.
        let now = parseInstant("2026-10-08T10:11:00Z")!
        XCTAssertNil(lineRoute(board: board(), me: "jo", depot: "nope", flow: "default", now: now, expanded: []))
        XCTAssertNil(lineRoute(board: board(), me: "jo", depot: "yard", flow: "nope", now: now, expanded: []))
        XCTAssertNil(model.routeMap(for: LineRoute(yard: "", depot: "nope", flow: "default")))
        XCTAssertNil(model.routeMap(for: LineRoute(yard: "laptop", depot: "yard", flow: "default")))

        // A line the board no longer holds leaves for the overview on
        // the next read; the lines it still holds stay.
        model.openLine(depot: "yard", flow: "default")
        model.openLine(depot: "drafts", flow: "default")
        XCTAssertEqual(pushedDepots, ["yard", "drafts"])
        var without = board()
        without.depots.removeLast()
        home.board = without
        await model.refresh()
        XCTAssertEqual(pushedDepots, ["yard"])

        // The other yard's line is none of the yard switched to.
        model.open(yard: "laptop")
        try await waitFor("the laptop's board") { [model] in model?.state.read == true }
        XCTAssertEqual(nav.linesPath, [])
        model.openLine(depot: "yard", flow: "default")
        XCTAssertEqual(nav.linesPath, [.line(LineRoute(yard: "laptop", depot: "yard", flow: "default"))])
        // The tab left and come back to the same yard keeps the line.
        model.leave()
        model.open(yard: "laptop")
        XCTAssertEqual(nav.linesPath.count, 1)

        // A card leaves the same ways, whether its bead stood in a stage,
        // in Elsewhere or on no line: the board no longer holds the
        // bead, or its yard is switched away from. The line under it
        // stays while the board holds it.
        model.openBead("yd-gate")
        model.openBead("yd-fence")
        model.openBead("yd-crm")
        XCTAssertEqual(pushedBeads, ["yd-gate", "yd-fence", "yd-crm"])
        var landed = board()
        landed.depots[0].flows[0].stages[1].beads.removeFirst()
        landed.depots[0].elsewhere = []
        laptop.board = landed
        await model.refresh()
        XCTAssertEqual(pushedBeads, ["yd-crm"])
        XCTAssertEqual(pushedDepots, ["yard"])
        // Nothing is a card where the board holds no such bead, or the
        // yard is another's.
        XCTAssertNil(model.card(for: BeadRoute(yard: "laptop", bead: "yd-gate")))
        XCTAssertNil(model.card(for: BeadRoute(yard: "", bead: "yd-crm")))
        model.open(yard: "")
        XCTAssertEqual(nav.linesPath, [])
    }

    func testABeadOpensItsCard() async throws {
        home.up(loaded())
        home.board = richBoard()
        model.open(yard: "")
        try await waitRead()

        model.openBead("yd-train")
        let route = BeadRoute(yard: "", bead: "yd-train")
        XCTAssertEqual(nav.linesPath, [.bead(route)])
        model.openBead("yd-train")
        XCTAssertEqual(nav.linesPath, [.bead(route)], "opening what is pushed pushes nothing more")

        let card = try XCTUnwrap(model.card(for: route))
        XCTAssertEqual(card.bead.id, "yd-train")
        XCTAssertEqual(card.bead.title, "Release train")
        XCTAssertEqual(card.line, "yard · default")
        XCTAssertEqual(card.stage, "new")
        // The line's strip, the backlog first, with the bead's stage to
        // mark.
        XCTAssertEqual(
            card.stages,
            [
                StripStage(name: "backlog", state: .none, human: false),
                StripStage(name: "new", state: .broken, human: false),
                StripStage(name: "review", state: .yourTurn, human: false),
                StripStage(name: "decide", state: .none, human: true),
            ]
        )
        XCTAssertEqual(card.head, "yard · default · new for 41m · expected 11–25m")
        XCTAssertTrue(card.bead.working)
        XCTAssertEqual(card.bead.worker, "train-new")
        XCTAssertEqual(card.bead.workedBy, "worked by muse-builders · claude/opus")
        XCTAssertEqual(card.bead.stay, "41m")
        XCTAssertEqual(workerWords(card.bead), "train-new · 41m")
        XCTAssertEqual(beadMeta(card.bead), "expected 11–25m")
        // The account's own yard is named by its handle, so a cookie an
        // earlier named-yard visit left in the browser picks nothing.
        XCTAssertEqual(card.webView, "https://edge.example/beads/yd-train?yard=jo")

        // An account saved before handles were kept resolves its handle
        // with the current session before opening the own-yard page.
        let legacySession = fake.session()
        records.keepSession(account: "jo@example.com", session: legacySession)
        fake.next(
            "/kratos/sessions/whoami",
            .json(200, #"{"identity":{"traits":{"handle":"jo"}}}"#)
        )
        let maybeResolved = await model.webViewURL(for: route)
        let resolved = try XCTUnwrap(maybeResolved)
        XCTAssertEqual(resolved.absoluteString, "https://edge.example/beads/yd-train?yard=jo")
        XCTAssertEqual(records.kept.account?.handle, "jo")
        let whoami = fake.taken()
        XCTAssertEqual(whoami.method, "GET")
        XCTAssertEqual(whoami.path, "/kratos/sessions/whoami")
        XCTAssertEqual(whoami.header("X-Edge-Token"), legacySession)

        // The whole card, whatever filter the overview holds; a bead in
        // the backlog has its card too, on the same strip.
        model.filter(.late)
        XCTAssertEqual(model.card(for: route), card)
        model.filter(.all)
        let draft = try XCTUnwrap(model.card(for: BeadRoute(yard: "", bead: "yd-draft-2")))
        XCTAssertEqual(draft.stage, "backlog")
        XCTAssertEqual(draft.stages, card.stages)
        XCTAssertEqual(draft.head, "yard · default · backlog")
        XCTAssertEqual(draft.bead.remark, "waits for you")
        XCTAssertEqual(beadMeta(draft.bead), "waits for you")
        // A bead standing for a seat says so in its meta.
        let waiting = try XCTUnwrap(model.card(for: BeadRoute(yard: "", bead: "yd-greet")))
        XCTAssertTrue(waiting.bead.waitsSeat)
        XCTAssertEqual(beadMeta(waiting.bead), "waits for a seat")
        XCTAssertEqual(waiting.head, "drafts · default · new")

        // A named yard's card names that yard: the handle is the own
        // yard's alone.
        laptop.up(loaded())
        laptop.board = richBoard()
        model.open(yard: "laptop")
        try await waitRead()
        let named = try XCTUnwrap(model.card(for: BeadRoute(yard: "laptop", bead: "yd-train")))
        XCTAssertEqual(named.webView, "https://edge.example/beads/yd-train?yard=laptop")

        // If an older session cannot identify its handle, do not open an
        // own-yard link that would silently follow a stale browser cookie.
        model.open(yard: "")
        try await waitRead()
        let unresolvedSession = fake.session()
        records.keepSession(account: "jo@example.com", session: unresolvedSession)
        fake.next("/kratos/sessions/whoami", .signedOut())
        let unresolved = await model.webViewURL(for: route)
        XCTAssertNil(unresolved)
        XCTAssertNotNil(model.webViewError)
        _ = fake.taken()
    }

    func testAYardOfItsOwnServesItsCardsPagesItself() async throws {
        let directRecords = Records(secret: MemoryShelf(), plain: MemoryShelf(), origin: "https://edge.example")
        directRecords.keepYard(PairedYard(name: "", yard: "south", user: "jo", device: "phone", token: "yardr-dev-south-1", origin: "https://yard.example.net"))
        let now = parseInstant("2026-10-08T10:11:00Z")!
        model = LineModel(
            followers: { [home] in ["": home!] },
            records: directRecords,
            pairer: Pairer(edge: try fake.edge(), records: directRecords),
            nav: nav, conversation: conversation,
            origins: { name in
                let own = directRecords.kept.yards.first { $0.name == name }?.origin ?? ""
                return own.isEmpty ? "https://edge.example" : own
            },
            now: { now }
        )
        home.up(loaded())
        home.board = richBoard()
        model.open(yard: "")
        try await waitRead()

        let route = BeadRoute(yard: "", bead: "yd-train")
        let card = try XCTUnwrap(model.card(for: route))
        XCTAssertEqual(card.webView, "https://yard.example.net/beads/yd-train")
        // No account, no handle resolved: the link opens as it stands.
        let maybeLink = await model.webViewURL(for: route)
        let link = try XCTUnwrap(maybeLink)
        XCTAssertEqual(link.absoluteString, "https://yard.example.net/beads/yd-train")
        XCTAssertNil(model.webViewError)
        XCTAssertEqual(fake.requestCount, 0)
    }

    func testABeadCardNamesItsLineOrNone() throws {
        let now = parseInstant("2026-10-08T10:11:00Z")!
        // Elsewhere: no strip, no stage, still a card.
        let held = try XCTUnwrap(
            beadCard(board: board(), me: "jo", now: now, origin: "https://edge.example", yard: "north", handle: "jo", id: "yd-fence")
        )
        XCTAssertEqual(held.line, "yard · Elsewhere")
        XCTAssertEqual(held.stage, "")
        XCTAssertEqual(held.stages, [])
        XCTAssertEqual(held.head, "yard · Elsewhere")
        XCTAssertEqual(held.bead.remark, "held by yardmaster")
        XCTAssertFalse(held.bead.waitsSeat)
        // A named yard keeps its name whatever the account's handle.
        XCTAssertEqual(held.webView, "https://edge.example/beads/yd-fence?yard=north")
        // No line: the same, and no depot to name.
        let bare = try XCTUnwrap(
            beadCard(board: board(), me: "jo", now: now, origin: "https://edge.example", yard: "", handle: "jo", id: "yd-crm")
        )
        XCTAssertEqual(bare.line, "No line")
        XCTAssertEqual(bare.stage, "")
        XCTAssertEqual(bare.stages, [])
        XCTAssertEqual(bare.head, "No line")
        // The account's own yard is named by its handle, on a line or off.
        XCTAssertEqual(bare.webView, "https://edge.example/beads/yd-crm?yard=jo")
        let onLine = try XCTUnwrap(
            beadCard(board: board(), me: "jo", now: now, origin: "https://edge.example", yard: "", handle: "jo", id: "yd-train")
        )
        XCTAssertEqual(onLine.webView, "https://edge.example/beads/yd-train?yard=jo")
        // The pure card builder has no network access; the interactive
        // model resolves a missing handle before opening the link above.
        let unnamed = try XCTUnwrap(
            beadCard(board: board(), me: "jo", now: now, origin: "https://edge.example", yard: "", handle: "", id: "yd-crm")
        )
        XCTAssertEqual(unnamed.webView, "https://edge.example/beads/yd-crm")
        // The board holds no such bead.
        XCTAssertNil(beadCard(board: board(), me: "jo", now: now, origin: "https://edge.example", yard: "", handle: "jo", id: "yd-nope"))
        XCTAssertNil(beadCard(board: Flows(), me: "jo", now: now, origin: "https://edge.example", yard: "", handle: "jo", id: "yd-crm"))
    }

    func testACardsHeadSaysItsStayAndItsRange() {
        func bead(stay: String = "", expected: String = "") -> StationBead {
            StationBead(id: "yd-x", title: "", stay: stay, expected: expected)
        }
        XCTAssertEqual(cardHead(line: "yard · default", stage: "new", bead: bead()), "yard · default · new")
        XCTAssertEqual(cardHead(line: "yard · default", stage: "new", bead: bead(stay: "41m")), "yard · default · new for 41m")
        XCTAssertEqual(
            cardHead(line: "yard · default", stage: "new", bead: bead(expected: "11–25m")),
            "yard · default · new · expected 11–25m"
        )
        XCTAssertEqual(
            cardHead(line: "yard · default", stage: "new", bead: bead(stay: "2h", expected: "5h–8h")),
            "yard · default · new for 2h · expected 5h–8h"
        )
    }

    func testABeadIdNeverShapesItsWebViewUrl() throws {
        XCTAssertEqual(
            webViewUrl(origin: "https://edge.example", yard: "a+b", handle: "jo", bead: "yd-gate"),
            "https://edge.example/beads/yd-gate?yard=a%2Bb"
        )
        // The id arrives from the yard: slashes, queries and fragments in
        // it stay one path segment, never the URL's shape, and the one
        // parameter is the own yard's handle.
        let hostile = webViewUrl(origin: "https://edge.example", yard: "", handle: "jo", bead: "yd-../../x?yard=other#frag")
        XCTAssertEqual(hostile, "https://edge.example/beads/yd-..%2F..%2Fx%3Fyard%3Dother%23frag?yard=jo")
        let parts = try XCTUnwrap(URLComponents(string: hostile))
        XCTAssertEqual(parts.host, "edge.example")
        XCTAssertEqual(parts.percentEncodedPath.split(separator: "/").map(String.init), ["beads", "yd-..%2F..%2Fx%3Fyard%3Dother%23frag"])
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "yard", value: "jo")])
        XCTAssertNil(parts.fragment)
        // The pure URL helper adds no yard parameter when no handle is
        // supplied; LineModel resolves it before an interactive open.
        let unnamed = webViewUrl(origin: "https://edge.example", yard: "", handle: "", bead: "yd-../../x?yard=other#frag")
        XCTAssertEqual(unnamed, "https://edge.example/beads/yd-..%2F..%2Fx%3Fyard%3Dother%23frag")
        let unnamedParts = try XCTUnwrap(URLComponents(string: unnamed))
        XCTAssertNil(unnamedParts.query)
        XCTAssertNil(unnamedParts.fragment)
        XCTAssertEqual(
            webViewUrl(origin: "https://edge.example", yard: "north", handle: "jo", bead: "a b"),
            "https://edge.example/beads/a%20b?yard=north"
        )
        // What is not ASCII is percent-encoded as UTF-8, and the yard's
        // name, the handle too, is a value as the id is a segment.
        XCTAssertEqual(
            webViewUrl(origin: "https://edge.example", yard: "café&x=1", handle: "jo", bead: "yd-é"),
            "https://edge.example/beads/yd-%C3%A9?yard=caf%C3%A9%26x%3D1"
        )
        XCTAssertEqual(
            webViewUrl(origin: "https://edge.example", yard: "", handle: "jo&x=1", bead: "yd-é"),
            "https://edge.example/beads/yd-%C3%A9?yard=jo%26x%3D1"
        )
    }

    func testAskingTheYardmasterOpensItsConversationWithTheBeadFirst() async throws {
        home.up(loaded())
        laptop.up(loaded())
        home.board = board()
        laptop.board = board()
        // No yard shown yet: the Ask has nowhere to go.
        model.askYardmaster(about: "yd-train")
        XCTAssertEqual(nav.crewPath, [])
        XCTAssertEqual(nav.place, .lines)

        model.open(yard: "laptop")
        try await waitRead()
        model.openBead("yd-train")
        model.askYardmaster(about: "yd-train")
        // The crew place shows the shown yard's conversation with the
        // yardmaster; the card stays pushed for the way back.
        XCTAssertEqual(nav.place, .crew)
        XCTAssertEqual(nav.crewPath, [ConversationRoute(yard: "laptop", with: "yardmaster")])
        XCTAssertEqual(nav.linesPath, [.bead(BeadRoute(yard: "laptop", bead: "yd-train"))])
        // The screen's open starts the draft, the bead's id its first
        // words.
        conversation.open(yard: "laptop", with: "yardmaster")
        XCTAssertEqual(conversation.state.title, "yardmaster")
        XCTAssertEqual(conversation.state.draft, "yd-train ")
        // Asked again with the conversation pushed already: pushed no
        // more, and the bead is still the first words, once.
        conversation.leave()
        model.askYardmaster(about: "yd-train")
        XCTAssertEqual(nav.crewPath.count, 1)
        conversation.open(yard: "laptop", with: "yardmaster")
        XCTAssertEqual(conversation.state.draft, "yd-train ")
    }

    func testStageStatesReadLampAndWork() {
        let plain = FlowBead(bead: "yd-plain")
        let worked = FlowBead(bead: "yd-worked", working: true)
        func stage(_ lamp: String, _ beads: [FlowBead]) -> FlowStage {
            FlowStage(stage: "new", lamp: lamp, beads: beads)
        }
        // An empty stage stands unlit whatever it serves.
        XCTAssertEqual(stageStateOf(stage("fault", [])), .none)
        XCTAssertEqual(stageStateOf(stage("fault", [plain])), .broken)
        XCTAssertEqual(stageStateOf(stage("turn", [plain])), .yourTurn)
        XCTAssertEqual(stageStateOf(stage("none", [plain, worked])), .moving)
        XCTAssertEqual(stageStateOf(stage("none", [plain])), .none)
        XCTAssertEqual(stageStateOf(stage("wat", [plain])), .none)
        XCTAssertEqual(worstOf([.moving, .broken]), .broken)
        XCTAssertEqual(worstOf([.moving, .yourTurn]), .yourTurn)
        XCTAssertEqual(worstOf([.none, .moving]), .moving)
        XCTAssertEqual(worstOf([.none]), .none)
        XCTAssertEqual(worstOf([]), .none)
    }

    func testRemarksNameHoldsWaitsAndLate() {
        XCTAssertTrue(isHeld(remark: "held"))
        XCTAssertTrue(isHeld(remark: "held by jo"))
        XCTAssertFalse(isHeld(remark: "stalled"))
        XCTAssertFalse(isHeld(remark: ""))
        XCTAssertTrue(isLate(remark: "late"))
        XCTAssertTrue(isLate(remark: "late by 40m"))
        XCTAssertFalse(isLate(remark: "blocked by yd-train"))
        XCTAssertTrue(waitsOnYou(remark: "waits for jo", me: "jo"))
        XCTAssertTrue(waitsOnYou(remark: "waits for yardmaster, jo", me: "jo"))
        XCTAssertFalse(waitsOnYou(remark: "waits for yardmaster", me: "jo"))
        XCTAssertFalse(waitsOnYou(remark: "waits for jo", me: ""))
        XCTAssertFalse(waitsOnYou(remark: "held by jo", me: "jo"))
        XCTAssertEqual(youFirst(remark: "held by jo", me: "jo"), "held by you")
        XCTAssertEqual(youFirst(remark: "held by yardmaster", me: "jo"), "held by yardmaster")
        XCTAssertEqual(youFirst(remark: "waits for jo", me: "jo"), "waits for you")
        XCTAssertEqual(youFirst(remark: "waits for jo, yardmaster", me: "jo"), "waits for you, yardmaster")
        XCTAssertEqual(youFirst(remark: "waits for yardmaster", me: "jo"), "waits for yardmaster")
        XCTAssertEqual(youFirst(remark: "stalled", me: "jo"), "stalled")
        XCTAssertEqual(workerSession("herdr train-new"), "train-new")
        XCTAssertEqual(workerSession("exec 12"), "exec 12")
        XCTAssertEqual(workerSession(""), "")
    }

    func testStaysReadTheYardsClock() {
        let now = parseInstant("2026-10-08T10:11:00Z")!
        XCTAssertEqual(stayWords(enteredAt: "2026-10-08T09:30:00Z", now: now), "41m")
        XCTAssertEqual(stayWords(enteredAt: "2026-10-08T08:00:00Z", now: now), "2h")
        XCTAssertEqual(stayWords(enteredAt: "2026-10-05T09:30:00Z", now: now), "3d")
        XCTAssertEqual(stayWords(enteredAt: "", now: now), "")
        XCTAssertEqual(stayWords(enteredAt: "not a time", now: now), "")
        XCTAssertEqual(stayWords(enteredAt: "2026-10-08T10:11:00Z", now: now), "")
        XCTAssertEqual(stayWords(enteredAt: "2026-10-08T10:12:00Z", now: now), "")
    }

    func testEveryBeadsEventAndTheBoardsOtherInputsMoveTheLine() {
        for kind in ["noted", "mail", "created", "arrived"] {
            XCTAssertTrue(movesLine(Event(seq: 1, kind: kind, bead: "yd-shed")), kind)
        }
        for kind in [
            "group_set", "group_removed", "route_added", "route_set", "route_removed",
            "flow_set", "flow_removed", "flow_pointer_set", "flow_pointer_cleared",
            "depot_updated", "depot_removed",
        ] {
            XCTAssertTrue(movesLine(Event(seq: 1, kind: kind)), kind)
        }
        XCTAssertTrue(movesLine(Event(seq: 1, kind: "setting_changed", data: ["key": .string("max_sessions")])))
        XCTAssertTrue(movesLine(Event(seq: 1, kind: "setting_changed", data: ["key": .string("operator")])))
        XCTAssertFalse(movesLine(Event(seq: 1, kind: "setting_changed", data: ["key": .string("theme")])))
        XCTAssertFalse(movesLine(Event(seq: 1, kind: "mail")))
        XCTAssertFalse(movesLine(Event(seq: 1, kind: "arrived")))
    }

    func testAStagesGroupWordsNameWhoWorksThere() {
        XCTAssertEqual(groupWords(FlowStage(stage: "backlog")), "no route matches")
        XCTAssertEqual(
            groupWords(FlowStage(stage: "new", group: "muse-builders", limit: 4, taken: 2)),
            "muse-builders · 2 of 4 seats"
        )
        XCTAssertEqual(
            groupWords(FlowStage(stage: "decide", group: "mckean", human: true, limit: 1, taken: 0)),
            "mckean · waiting on a person · 0 of 1 seats"
        )
        XCTAssertEqual(
            groupWords(FlowStage(stage: "new", group: "muse-builders", limit: 0, taken: 0)),
            "muse-builders · paused"
        )
        XCTAssertEqual(groupWords(FlowStage(stage: "new", group: "muse-builders")), "muse-builders")
    }

    func testWorkedByAndTheHeadCountWhatTheYardServes() {
        XCTAssertNil(workedBy(FlowBead(bead: "yd-idle", working: false, group: "g")))
        XCTAssertNil(workedBy(FlowBead(bead: "yd-bare", working: true)))
        XCTAssertEqual(workedBy(FlowBead(bead: "yd-g", working: true, group: "mill-builders")), "worked by mill-builders")
        XCTAssertEqual(
            workedBy(FlowBead(bead: "yd-r", working: true, kind: "claude", model: "opus")),
            "worked by claude/opus"
        )
        XCTAssertEqual(
            headWords(Flows(
                travelling: 3,
                depots: [FlowDepot(name: "yard", flows: [
                    DepotFlow(name: "default", stages: [
                        FlowStage(stage: "new", beads: [FlowBead(bead: "yd-a", working: true)])
                    ])
                ], elsewhere: [FlowBead(bead: "yd-b", working: true)])],
                unassigned: [FlowBead(bead: "yd-c")]
            )),
            "3 travelling · 2 working"
        )
    }

    // MARK: - Helpers

    /// The depots of the lines pushed, in order.
    private var pushedDepots: [String] {
        nav.linesPath.compactMap { route -> String? in
            if case .line(let line) = route { return line.depot }
            return nil
        }
    }

    /// The ids of the beads pushed, in order.
    private var pushedBeads: [String] {
        nav.linesPath.compactMap { route -> String? in
            if case .bead(let bead) = route { return bead.bead }
            return nil
        }
    }

    private func waitRead() async throws {
        try await waitFor("the board") { [model] in model?.state.read == true }
    }

    private func waitError() async throws {
        try await waitFor("the error") { [model] in model?.state.error != nil }
    }

    private func waitFlowCalls(_ followed: FakeFollowed, _ count: Int) async throws {
        try await waitFor("\(count) flows reads") { [followed] in followed.flowCalls >= count }
        // The read's landing follows its call; wait for the board too.
        try await waitRead()
    }

    private func waitFor(_ what: String, _ match: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !match() {
            if ContinuousClock.now > deadline {
                XCTFail("timed out waiting for \(what)")
                throw TestTimeout(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func loaded(head: Int64 = 151) -> Loaded {
        Loaded(
            me: Me(user: "jo", saidBy: "phone", yard: "south"),
            head: head,
            settings: Settings(),
            user: User(name: "jo"),
            crew: [],
            users: [],
            inbox: Inbox(),
            notifications: Notifications(),
            asks: Asks()
        )
    }

    /// The fake yard's board, cut down, with the backlog served first to
    /// prove it is shown last.
    private func board() -> Flows {
        Flows(
            travelling: 7,
            depots: [
                FlowDepot(
                    name: "yard",
                    kind: "git",
                    travelling: 5,
                    flows: [
                        DepotFlow(
                            name: "default",
                            stages: [
                                FlowStage(
                                    stage: "backlog",
                                    beads: [
                                        FlowBead(bead: "yd-draft-1", title: "Draft 1"),
                                        FlowBead(bead: "yd-draft-2", title: "Draft 2", remark: "waits for jo"),
                                        FlowBead(bead: "yd-draft-3", title: "Draft 3"),
                                    ]
                                ),
                                FlowStage(
                                    stage: "new",
                                    group: "muse-builders",
                                    limit: 4,
                                    taken: 2,
                                    beads: [
                                        FlowBead(bead: "yd-gate", title: "Mend the gate", remark: "blocked by yd-train", tone: "amber"),
                                        FlowBead(
                                            bead: "yd-train", title: "Release train", working: true,
                                            worker: "herdr train-new", group: "muse-builders",
                                            kind: "claude", model: "opus"
                                        ),
                                    ]
                                ),
                                FlowStage(
                                    stage: "review",
                                    group: "muse-reviewers",
                                    lamp: "turn",
                                    limit: 2,
                                    taken: 1,
                                    beads: [FlowBead(bead: "yd-shed", title: "Paint the shed", remark: "waits for mckean", tone: "amber")]
                                ),
                                FlowStage(
                                    stage: "decide",
                                    group: "mckean",
                                    human: true,
                                    limit: 1,
                                    taken: 0,
                                    beads: [FlowBead(bead: "yd-seal", title: "Seal the tender")]
                                ),
                            ]
                        )
                    ],
                    elsewhere: [FlowBead(bead: "yd-fence", title: "Paint the fence", remark: "held by yardmaster", tone: "red")]
                ),
                FlowDepot(
                    name: "drafts",
                    kind: "dir",
                    travelling: 1,
                    flows: [
                        DepotFlow(
                            name: "default",
                            stages: [
                                FlowStage(
                                    stage: "new",
                                    group: "muse-builders",
                                    limit: 4,
                                    taken: 2,
                                    beads: [FlowBead(bead: "yd-greet", title: "The greeting")]
                                ),
                                FlowStage(stage: "shipped", group: "elders", human: true, terminal: true),
                            ]
                        )
                    ]
                ),
            ],
            unassigned: [FlowBead(bead: "yd-crm", title: "Read the CRM")]
        )
    }

    /// The board with every state the overview and the route map draw:
    /// a fault, waits on the reader, a late bead, and a quiet line.
    private func richBoard() -> Flows {
        var rich = board()
        // The new stage faults; the worked bead carries its range.
        rich.depots[0].flows[0].stages[1].lamp = "fault"
        rich.depots[0].flows[0].stages[1].beads[1].expected = "11–25m"
        rich.depots[0].flows[0].stages[1].beads[1].enteredStageAt = "2026-10-08T09:30:00Z"
        // The review waits on the reader, and so do two of the backlog.
        rich.depots[0].flows[0].stages[2].beads[0].remark = "waits for jo"
        rich.depots[0].flows[0].stages[0].beads[0].remark = "waits for jo"
        // Drafts fills its seats and runs a bead late.
        rich.depots[1].flows[0].stages[0].limit = 1
        rich.depots[1].flows[0].stages[0].taken = 1
        rich.depots[1].flows[0].stages[0].beads.append(
            FlowBead(bead: "yd-late", title: "Late train", remark: "late by 40m", tone: "amber")
        )
        // A quiet line folds into a chip.
        rich.depots.append(
            FlowDepot(
                name: "signalbox",
                kind: "dir",
                travelling: 1,
                flows: [
                    DepotFlow(
                        name: "default",
                        stages: [
                            FlowStage(
                                stage: "new",
                                group: "muse-builders",
                                limit: 4,
                                taken: 0,
                                beads: [FlowBead(bead: "yd-quiet", title: "Quiet bead")]
                            ),
                            FlowStage(stage: "shipped", group: "elders", human: true, terminal: true),
                        ]
                    )
                ]
            )
        )
        return rich
    }
}
