@testable import Footplate
import Foundation
import XCTest

// The line over fake-followed boards (design 3.5, after Android's
// LineModelTest): the board drawn with its head words, a failed read
// said and cleared, an unreadable depot in the yard's own words, the
// place following a yard switch, and the backlog opening and shutting.
@MainActor
final class LineModelTests: XCTestCase {
    private var home: FakeFollowed!
    private var laptop: FakeFollowed!
    private var model: LineModel!

    override func setUp() {
        super.setUp()
        home = FakeFollowed()
        laptop = FakeFollowed()
        model = LineModel(followers: { [home, laptop] in
            ["": home!, "laptop": laptop!]
        })
    }

    override func tearDown() {
        model.leave()
        model = nil
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

        model.toggleBacklog(depot: "yard", flow: "default", stage: "backlog")
        XCTAssertTrue(model.state.depots[0].flows[0].stages[3].open)
        model.toggleBacklog(depot: "yard", flow: "default", stage: "backlog")
        XCTAssertFalse(model.state.depots[0].flows[0].stages[3].open)
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
}
