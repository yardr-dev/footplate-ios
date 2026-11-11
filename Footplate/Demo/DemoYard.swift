import CryptoKit
import Foundation

// The demo yard (Try a demo): a made-up yard that lives in the app, so a
// person with no yard to pair can go through every screen. It is plain
// state, as `Board` is: `DemoTransport` serves it as a yard's calls and
// stream, and the app's own follower, models and screens read it as they
// read any yard. Its crew, mail, beads and its one question are invented.
// They hold no web address, and the question is a routine one, so nothing
// on a card asks for the unlock or for a secret.
//
// A write changes this value alone and leaves its event, so the board, the
// decisions and the line move as they do on a real yard. Nothing here is
// kept past the value: a demo left is a demo gone.

struct DemoYard: Sendable {
    /// The user every call is made as.
    static let user = "guest"
    /// The yard's name, in the head line and in `/user/me`.
    static let yard = "demo"
    /// Whom the bead card's Ask writes to.
    static let coordinator = "yardmaster"

    /// The seq of the newest event.
    private(set) var head: Int64 = 295
    /// The events since the demo opened, oldest first. What happened
    /// before it is in the state the follower reads.
    private(set) var events: [Event] = []

    private let clock: @Sendable () -> Date
    private(set) var crew: [CrewMember]
    private var letters: [Letter]
    private var cursor: Int64 = 293
    private var notices: [Notification]
    private var noticeCursor: Int64 = 2
    private var open: [OpenAsk]
    private var decided: [DecidedAsk]
    private var beads: [String: Bead]
    private var board: Flows
    private var blobs: [String: Data] = [:]
    private var refs: [String: BlobRef] = [:]

    /// The yard as it stands when the person opens it: the times of its
    /// mail, notices and cards run back from `now`.
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        clock = now
        let start = now()
        let minute: TimeInterval = 60
        let hour = 60 * minute
        func ago(_ seconds: TimeInterval) -> String {
            stamped(start.addingTimeInterval(-seconds))
        }

        crew = [
            CrewMember(name: "yardmaster", enabled: true, state: "running", status: "working"),
            CrewMember(name: "signalman", enabled: true, state: "running", status: "idle"),
            CrewMember(name: "shunter", enabled: true, state: "stopped"),
        ]
        // The long thread with the yardmaster (footplate-ios-g0jx): a
        // few hundred older letters before the five above, long ones
        // with code blocks, lists and pictures among them, so opening
        // the conversation, scrolling through it and a letter arriving
        // in it can be felt and measured as they are on a real yard.
        // They are all read. Their words name no bead but ones this
        // yard holds and no web address, as the rest of the demo does
        // not.
        let boardPicture = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEklEQVR4nGP4z8CAFWEXHbQSACj/P8Fu7N9hAAAAAElFTkSuQmCC")!
        let boardRef = BlobRef(
            hash: sha256Hex(boardPicture), kind: "image/png", bytes: Int64(boardPicture.count), name: "board.png"
        )
        let longWords = """
        ## Overnight notes

        The run finished **clean** and the board held through the night watch.

        - first watch item with `prime` in code
        - second watch item with **bold** words inside
          the same item goes on here
        1. open the shed
        2. read the board
        3. sign the sheet

        ```sh
        yardr bead show yd-9w1x
        yardr prime --bead yd-9w1x
        ```

        Words at the end with *italic* and `code` mixed in.
        """
        let listWords = """
        Watch report for the yard

        - gates shut
        - lamps lit
        - sheet signed

        All quiet on the west road and the north gate.
        """
        var history: [Letter] = []
        for seq in 1...290 {
            let mine = seq % 3 == 0
            let words = switch seq % 4 {
            case 0: longWords
            case 1: listWords
            case 2: "All quiet through the night watch. The board is read and the sheet is signed."
            default: "The night run went through each road in turn and left word at every gate. Nothing waited at the shed and nothing was left unsigned on the sheet by the door."
            }
            history.append(Letter(
                seq: Int64(seq),
                at: stamped(start.addingTimeInterval(-30 * 24 * 3600 + TimeInterval(seq) * 3600)),
                from: mine ? Self.user : "yardmaster",
                to: mine ? "yardmaster" : Self.user,
                text: words,
                read: true,
                files: seq % 29 == 0 ? [boardRef] : []
            ))
        }
        letters = history + [
            Letter(seq: 291, at: ago(7 * hour), from: Self.user, to: "yardmaster", text: "How did the overnight run go?"),
            Letter(
                seq: 292, at: ago(7 * hour - 2 * minute), from: "yardmaster", to: Self.user,
                text: "Clean. yd-9w1x landed and nothing is blocked.", read: true
            ),
            Letter(
                seq: 293, at: ago(4 * hour), from: "signalman", to: Self.user,
                text: "The nightly checks passed on every line.", read: true
            ),
            Letter(
                seq: 294, at: ago(90 * minute), from: "yardmaster", to: Self.user,
                text: "yd-4k2m passed review. It is ready to land, and I need your word first: it is waiting under Decide."
            ),
            Letter(
                seq: 295, at: ago(85 * minute), from: "yardmaster", to: Self.user,
                text: "yd-7h9q is with a builder now and should be done within the hour."
            ),
        ]
        notices = [
            Notification(
                seq: 1, at: ago(5 * hour), kind: "created", bead: "yd-2c5d",
                text: "yd-2c5d created by yardmaster stage=backlog title=\"Add the night service to the timetable\" type=task",
                read: true
            ),
            Notification(
                seq: 2, at: ago(3 * hour), kind: "noted", bead: "yd-7h9q",
                text: "yd-7h9q noted by builder-1 note=1 on \"Fix the platform number on printed timetables\"",
                read: true
            ),
            Notification(
                seq: 3, at: ago(2 * hour), kind: "noted", bead: "yd-4k2m",
                text: "yd-4k2m noted by yardmaster note=3 on \"Cache the departures board\""
            ),
        ]

        let question = "Land the departures cache today, or after Friday's release?"
        open = [
            OpenAsk(
                bead: "yd-4k2m", beadTitle: "Cache the departures board", ask: 3,
                question: question, asker: "yardmaster", since: ago(2 * hour)
            ),
        ]
        decided = [
            DecidedAsk(
                bead: "yd-9w1x", beadTitle: "Show delays on the departures board", ask: 2,
                question: "Show delays in minutes or in words?", asker: "yardmaster", since: ago(26 * hour),
                state: "answered", option: 1, optionLabel: "In minutes", by: Self.user
            ),
        ]
        beads = [
            "yd-4k2m": Bead(
                id: "yd-4k2m", title: "Cache the departures board",
                body: "Keep the last departures answer for ten seconds, so the board stops asking the timetable on every screen.",
                stage: "decide", labels: ["performance"],
                notes: [
                    BeadNote(seq: 1, kind: "note", author: "builder-1", text: "The cache holds for ten seconds. The tests pass on a copy of the board.", at: ago(5 * hour)),
                    BeadNote(seq: 2, kind: "note", author: "reviewer-1", text: "Reviewed. Nothing to change.", at: ago(3 * hour)),
                ],
                asks: [
                    BeadAsk(
                        ask: 3, to: Self.user, asker: "yardmaster", since: ago(2 * hour), question: question,
                        context: [
                            "The cache passed review and its tests.",
                            "The bead behind it on the line waits for it to land.",
                        ],
                        options: [
                            AskOption(label: "Land it today", consequence: "the cache reaches main tonight"),
                            AskOption(label: "After Friday", consequence: "it waits in the yard until the release is out"),
                            AskOption(label: "You decide", consequence: "leave it to yardmaster"),
                        ],
                        recommend: 1, why: "review found nothing to change",
                        about: [AboutBead(id: "yd-7h9q", title: "Fix the platform number on printed timetables", stage: "new")],
                        state: "open"
                    ),
                ]
            ),
            "yd-7h9q": Bead(
                id: "yd-7h9q", title: "Fix the platform number on printed timetables",
                body: "The printed page shows platform 1 for every service. Read the number from the service instead.",
                stage: "new", labels: [],
                notes: [BeadNote(seq: 1, kind: "note", author: "builder-1", text: "Started. The fix is in the print template.", at: ago(40 * minute))]
            ),
            "yd-2c5d": Bead(
                id: "yd-2c5d", title: "Add the night service to the timetable",
                body: "Add the 23:40 and 00:25 services to the Friday and Saturday timetables.",
                stage: "backlog"
            ),
            "yd-9w1x": Bead(
                id: "yd-9w1x", title: "Show delays on the departures board",
                body: "Show how late a service is beside its time.",
                stage: "merged", labels: ["departures"],
                notes: [BeadNote(seq: 3, kind: "note", author: "yardmaster", text: "Landed.", at: ago(5 * hour))],
                asks: [
                    BeadAsk(
                        ask: 2, to: Self.user, asker: "yardmaster", since: ago(26 * hour),
                        question: "Show delays in minutes or in words?",
                        options: [
                            AskOption(label: "In minutes", consequence: "a late service reads +4 min"),
                            AskOption(label: "In words", consequence: "a late service reads four minutes late"),
                            AskOption(label: "You decide", consequence: "leave it to yardmaster"),
                        ],
                        recommend: 1, state: "answered", option: 1
                    ),
                ]
            ),
        ]
        board = Flows(
            travelling: 2,
            depots: [
                FlowDepot(
                    name: "timetable", kind: "git", travelling: 2,
                    flows: [
                        DepotFlow(
                            name: "default", source: "store",
                            stages: [
                                FlowStage(
                                    stage: "backlog",
                                    beads: [FlowBead(bead: "yd-2c5d", title: "Add the night service to the timetable")]
                                ),
                                FlowStage(
                                    stage: "new", group: "builders", limit: 2, taken: 1,
                                    beads: [
                                        FlowBead(
                                            bead: "yd-7h9q", title: "Fix the platform number on printed timetables",
                                            expected: "10–25m", working: true, worker: "builder-1",
                                            group: "builders", kind: "claude", model: "sonnet",
                                            enteredStageAt: ago(40 * minute)
                                        ),
                                    ]
                                ),
                                FlowStage(stage: "review", group: "reviewers", limit: 1, taken: 0),
                                FlowStage(
                                    stage: "decide", group: Self.user, human: true, lamp: "turn", limit: 1, taken: 0,
                                    beads: [
                                        FlowBead(
                                            bead: "yd-4k2m", title: "Cache the departures board",
                                            remark: "waits for \(Self.user)", tone: "amber",
                                            enteredStageAt: ago(2 * hour)
                                        ),
                                    ]
                                ),
                                FlowStage(stage: "merged", terminal: true),
                            ],
                            landings: [
                                FlowLanding(bead: "yd-9w1x", title: "Show delays on the departures board", landedAt: ago(5 * hour)),
                            ]
                        ),
                    ]
                ),
            ]
        )
        blobs[boardRef.hash] = boardPicture
        refs[boardRef.hash] = boardRef
    }

    // MARK: - What a yard answers

    var me: Me {
        Me(user: Self.user, saidBy: "phone", yard: Self.yard, yardmaster: Self.coordinator)
    }

    var settings: Settings {
        Settings(operator: Self.user, blobMaxBytes: "8388608", filesMax: "64")
    }

    var users: [User] {
        [user(Self.user)]
    }

    /// The user and where their mail and notices are read through.
    func user(_ name: String) -> User {
        User(name: name, cursor: cursor, notificationCursor: noticeCursor)
    }

    /// The mail to the user, the unread first, then the read ones newest
    /// first; `limit` 0 is all.
    func inbox(limit: Int64) -> Inbox {
        let mine = letters.filter { $0.to == Self.user }
        let unread = mine.filter { !$0.read }.sorted { $0.seq < $1.seq }
        let read = mine.filter(\.read).sorted { $0.seq > $1.seq }
        let all = unread + read
        var from: [String] = []
        for letter in unread where !from.contains(letter.from) {
            from.append(letter.from)
        }
        return Inbox(
            mail: limit > 0 ? Array(all.prefix(Int(limit))) : all,
            unread: Int64(unread.count),
            last: unread.map(\.seq).max() ?? 0,
            from: from
        )
    }

    /// The newest `limit` letters between `a` and `b` older than the seq
    /// `before` (0: the newest of all), oldest first, and whether older
    /// ones remain.
    func conversation(a: String, b: String, limit: Int64, before: Int64) -> Page {
        let between = letters
            .filter { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }
            .sorted { $0.seq < $1.seq }
        let older = before > 0 ? between.filter { $0.seq < before } : between
        let page = limit > 0 ? Array(older.suffix(Int(limit))) : older
        return Page(letters: page, more: older.count > page.count)
    }

    var notifications: Notifications {
        Notifications(
            notifications: notices,
            unread: Int64(notices.filter { !$0.read }.count),
            last: notices.filter { !$0.read }.map(\.seq).max() ?? 0
        )
    }

    var asks: Asks {
        Asks(open: open, decided: decided)
    }

    /// The bead whole, or nil where the demo yard holds none by that id.
    func bead(_ id: String) -> Bead? {
        beads[id]
    }

    var flows: Flows { board }

    /// The bytes a letter's file names, where this demo was given them.
    func blob(hash: String) -> Data? {
        blobs[hash]
    }

    // MARK: - What a yard does

    /// Mail from the user. The letter is the event: its seq is the
    /// event's, as on a real yard.
    mutating func mail(to: String, text: String, files: [MailFile]) {
        let carried = files.map { file in
            var ref = refs[file.hash] ?? BlobRef(hash: file.hash)
            ref.name = file.name
            return ref
        }
        var data: [String: JSONValue] = [
            "to": .string(to),
            "text": .string(text),
            "to_user": .bool(false),
        ]
        if !carried.isEmpty {
            data["files"] = .array(carried.map { ref in
                .object([
                    "hash": .string(ref.hash),
                    "type": .string(ref.kind),
                    "bytes": .int(ref.bytes),
                    "name": .string(ref.name),
                ])
            })
        }
        let event = emit(kind: "mail", data: data)
        letters.append(Letter(seq: event.seq, at: event.at, from: Self.user, to: to, text: text, files: carried))
    }

    /// The user's mail is read through `through`.
    mutating func ackInbox(through: Int64) {
        guard through > cursor else { return }
        cursor = through
        letters = letters.map { letter in
            var read = letter
            if read.to == Self.user, read.seq <= through { read.read = true }
            return read
        }
        emit(kind: "mail_read", data: ["reader": .string(Self.user), "through": .int(through)])
    }

    /// The user's notices are read through `through`.
    mutating func ackNotifications(through: Int64) {
        guard through > noticeCursor else { return }
        noticeCursor = through
        notices = notices.map { notice in
            var read = notice
            if read.seq <= through { read.read = true }
            return read
        }
        emit(kind: "notifications_read", data: ["reader": .string(Self.user), "through": .int(through)])
    }

    /// Keeps a file for a letter to carry; the name comes with the mail.
    mutating func putBlob(_ bytes: Data) -> BlobRef {
        let hash = sha256Hex(bytes)
        let ref = BlobRef(hash: hash, kind: kind(of: bytes), bytes: Int64(bytes.count))
        blobs[hash] = bytes
        refs[hash] = ref
        return ref
    }

    /// Picks `option` (0: none), with `words` beside it. False where the
    /// ask is not open.
    mutating func answer(bead: String, ask: Int64, option: Int64, words: String) -> Bool {
        decide(bead: bead, ask: ask, state: "answered", option: option, words: words)
    }

    /// Puts the ask aside until tomorrow. False where it is not open.
    mutating func putAside(bead: String, ask: Int64) -> Bool {
        decide(bead: bead, ask: ask, state: "put aside", returnAt: stamped(clock().addingTimeInterval(24 * 3600)))
    }

    /// Ends the ask with no option picked. False where it is not open.
    mutating func decline(bead: String, ask: Int64, words: String) -> Bool {
        decide(bead: bead, ask: ask, state: "declined", words: words)
    }

    // MARK: - Inside

    @discardableResult
    private mutating func emit(kind: String, bead: String = "", data: [String: JSONValue]) -> Event {
        head += 1
        let event = Event(seq: head, kind: kind, actor: Self.user, at: stamped(clock()), bead: bead, data: data)
        events.append(event)
        return event
    }

    /// Moves an open ask to the decided, as the yard lists it, on the
    /// card and on the line: the bead waits for nobody then.
    private mutating func decide(
        bead id: String, ask: Int64, state: String, option: Int64 = 0, words: String = "", returnAt: String = ""
    ) -> Bool {
        guard let index = open.firstIndex(where: { $0.bead == id && $0.ask == ask }) else { return false }
        let asked = open.remove(at: index)
        let card = beads[id]?.asks.first { $0.ask == ask }
        let label = card.flatMap { card in
            card.options.indices.contains(Int(option) - 1) ? card.options[Int(option) - 1].label : nil
        } ?? ""
        decided.insert(
            DecidedAsk(
                bead: id, beadTitle: asked.beadTitle, topic: asked.topic, ask: ask, question: asked.question,
                asker: asked.asker, since: asked.since, state: state, option: option, optionLabel: label,
                words: words, by: Self.user, returnAt: returnAt
            ),
            at: 0
        )
        if var bead = beads[id], let at = bead.asks.firstIndex(where: { $0.ask == ask }) {
            bead.asks[at].state = state
            bead.asks[at].option = option
            bead.asks[at].words = words
            beads[id] = bead
        }
        board.depots = board.depots.map { depot in
            var depot = depot
            depot.flows = depot.flows.map { flow in
                var flow = flow
                flow.stages = flow.stages.map { stage in
                    var stage = stage
                    stage.beads = stage.beads.map { bead in
                        var bead = bead
                        if bead.bead == id {
                            bead.remark = ""
                            bead.tone = "none"
                        }
                        return bead
                    }
                    return stage
                }
                return flow
            }
            return depot
        }
        emit(kind: "noted", bead: id, data: ["ask": .int(ask)])
        return true
    }
}

/// A time as the yard writes it, in RFC 3339.
private func stamped(_ date: Date) -> String {
    date.formatted(.iso8601)
}

/// What kind of file the bytes are, by their magic, as the yard reads it:
/// the pictures the phone sends are PNG or JPEG.
private func kind(of bytes: Data) -> String {
    guard isPicture(bytes) else { return "application/octet-stream" }
    return bytes.first == 0x89 ? "image/png" : "image/jpeg"
}
