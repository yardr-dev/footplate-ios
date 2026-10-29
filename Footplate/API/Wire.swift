import Foundation

// The answers of design 3.1's calls, as docs/api.md in yardr has them
// and footplate-android's Wire.kt reads them. A field the yard adds is
// passed over, a field it leaves out is its default, and null where a
// list is promised is the empty list.

extension KeyedDecodingContainer {
    func string(_ key: Key, _ fallback: String = "") -> String {
        do { return try decodeIfPresent(String.self, forKey: key) ?? fallback } catch { return fallback }
    }

    func int64(_ key: Key, _ fallback: Int64 = 0) -> Int64 {
        do { return try decodeIfPresent(Int64.self, forKey: key) ?? fallback } catch { return fallback }
    }

    func bool(_ key: Key, _ fallback: Bool = false) -> Bool {
        do { return try decodeIfPresent(Bool.self, forKey: key) ?? fallback } catch { return fallback }
    }

    func list<T: Decodable>(_ key: Key, of type: T.Type) -> [T] {
        do { return try decodeIfPresent([T].self, forKey: key) ?? [] } catch { return [] }
    }

    func optional<T: Decodable>(_ key: Key, of type: T.Type) -> T? {
        do { return try decodeIfPresent(T.self, forKey: key) ?? nil } catch { return nil }
    }
}

/// A JSON value of an event's `data`, whose fields depend on its kind and
/// which a client passes over when it does not know them.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var text: String {
        if case .string(let value) = self { return value }
        return ""
    }

    var number: Int64 {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int64(exactly: value) ?? 0
        default: return 0
        }
    }
}

/// Who a device's token is, as `GET /user/me` answers.
struct Me: Equatable, Sendable {
    /// The user every call is made as: `actor` and `name` of the calls.
    var user: String
    /// The device's name.
    var saidBy: String = ""
    /// The yard's name.
    var yard: String = ""
}

/// What a yard answers a pairing code with: the device token, the one
/// time it is anywhere, and what `/user/me` says of it from then on.
struct Paired: Equatable, Sendable {
    var token: String
    var user: String = ""
    var device: String = ""
    var yard: String = ""
}

extension Paired: CustomStringConvertible {
    var description: String {
        "Paired(token=<token>, user=\(user), device=\(device), yard=\(yard))"
    }
}

/// What signing in at the edge answers: the session token, the account
/// it signed in as, and the account's handle, which the edge names its
/// own yard by (empty where the answer holds none).
struct SignedIn: Equatable, Sendable {
    var session: String
    var account: String
    var handle: String
}

extension SignedIn: CustomStringConvertible {
    var description: String {
        "SignedIn(session=<token>, account=\(account), handle=\(handle))"
    }
}

struct Settings: Equatable, Sendable {
    var `operator`: String = ""
    /// A whole number in a string; absent when the yard has set none.
    var blobMaxBytes: String = ""
    var filesMax: String = ""
}

struct User: Equatable, Sendable {
    var name: String
    /// The user's mail is read through this seq.
    var cursor: Int64 = 0
    /// The same for the user's notifications.
    var notificationCursor: Int64 = 0
}

struct CrewMember: Equatable, Sendable {
    var name: String
    var enabled: Bool = false
    /// `stopped`, `running` or `failed`.
    var state: String = ""
    /// `working`, `idle`, `blocked`, `unknown`, or empty when none runs.
    var status: String = ""
    /// Whether the running session sits at its harness's login screen.
    var loginScreen: Bool = false
}

/// A file a letter carries; the phone says how many and shows none.
struct BlobRef: Equatable, Sendable {
    var hash: String = ""
    var kind: String = ""
    var bytes: Int64 = 0
    var name: String = ""
}

/// A file mail carries, by the hash `PutBlob` answered and the base name
/// the person gave it.
struct MailFile: Equatable, Sendable, Codable {
    var hash: String
    var name: String
}

struct Reaction: Equatable, Sendable {
    var from: String = ""
    var emoji: String = ""
}

/// One mail, of an inbox or a conversation.
struct Letter: Equatable, Sendable {
    var seq: Int64
    var at: String = ""
    var from: String = ""
    var to: String = ""
    var text: String = ""
    var read: Bool = false
    var reactions: [Reaction] = []
    var files: [BlobRef] = []
}

struct Inbox: Equatable, Sendable {
    var mail: [Letter] = []
    /// All the unread, shown or not.
    var unread: Int64 = 0
    /// The seq of the newest unread, 0 when none is.
    var last: Int64 = 0
    /// Who the unread are from, in the order they first wrote.
    var from: [String] = []
}

/// A part of a conversation, oldest first, and whether the yard has
/// older mail of it than this.
struct Page: Equatable, Sendable {
    var letters: [Letter]
    var more: Bool
}

/// One notice of the yard to a user, apart from every conversation.
struct Notification: Equatable, Sendable {
    var seq: Int64
    var at: String = ""
    var kind: String = ""
    var bead: String = ""
    var text: String = ""
    var read: Bool = false
}

struct Notifications: Equatable, Sendable {
    var notifications: [Notification] = []
    var unread: Int64 = 0
    var last: Int64 = 0
}

/// What a mapping ask maps: a pick writes a user's identity, so it goes
/// through the weighty gate with `weighed`.
struct Identity: Equatable, Sendable {
    var source: String = ""
    var sender: String = ""
    var channel: String = ""
}

/// One class of a card's weight, and the yard's line for it. A client
/// draws a class it does not know as weighty, with its line.
struct AskWeight: Equatable, Sendable {
    var kind: String = ""
    var line: String = ""
}

/// What a secret ask asks for. The phone gives one only where the card is
/// a harness login's one-time code (`givesLoginCode`); every other is
/// answered on the yard's machine.
struct Secret: Equatable, Sendable {
    var source: String = ""
    var env: [String] = []
    /// What is asked for, in the yard's words: shown as it is.
    var line: String = ""
    /// The waiting harness login the value goes to: what its sign-in page
    /// gave. Empty on any other secret.
    var login: String = ""
    /// The harness kind whose API key is asked for. Empty on any other
    /// secret.
    var harness: String = ""
    /// The hook whose signing secret is asked for.
    var hook: String = ""
    /// The user whose own address in the source is asked for.
    var user: String = ""
    /// The crew member whose own credential, or at whose login screen the
    /// harness key, is asked for.
    var crew: String = ""
    /// The user whose own credential is asked for; with `login`, the user
    /// whose own login that is.
    var `as`: String = ""
}

/// The command a run ask proposes: what a card says of it. The phone
/// sends no `ask` values; an approval the yard refuses for them shows
/// the yard command instead (design 3.5).
struct Run: Equatable, Sendable {
    var argv: [String] = []
    /// The command whole, as it is typed in a terminal: never cut.
    var command: String = ""
    var description: String = ""
    var does: [String] = []
    var back: String = ""
    var backBy: String = ""
    /// The names the approval gives values for in the clear.
    var ask: [String] = []
}

/// A yard source whose account a setup card offers to reuse.
struct SetupCandidate: Equatable, Sendable {
    var source: String = ""
    var file: String = ""
    var values: [String: String] = [:]
}

struct SetupGrant: Equatable, Sendable {
    var source: String = ""
    var calls: [String] = []
}

struct SetupPreset: Equatable, Sendable {
    var name: String = ""
    var grants: [SetupGrant] = []
}

/// The setup a setup ask proposes, as far as a card shows it. The phone
/// keeps the account that stands or shows the yard command; it types
/// no account and takes no candidate on the wire.
struct Setup: Equatable, Sendable {
    var pack: String = ""
    var label: String = ""
    var account: [String] = []
    var accountFile: String = ""
    /// On an update whose file holds every name: true. Absent otherwise.
    var given: Bool? = nil
    var missing: [String] = []
    var candidates: [SetupCandidate] = []
    var does: [String] = []
    var back: String = ""
    var backBy: String = ""
    var presets: [SetupPreset] = []
}

/// One open question addressed to the user, as the queue lists it.
struct OpenAsk: Equatable, Sendable {
    var bead: String
    var beadTitle: String = ""
    var topic: String = ""
    /// The ask note's seq: what an answer names.
    var ask: Int64 = 0
    var question: String = ""
    var asker: String = ""
    var since: String = ""
    var secret: Secret? = nil
    var run: Run? = nil
    var setup: Setup? = nil
    var identity: Identity? = nil
    /// One entry a class; empty on a routine card.
    var weight: [AskWeight] = []
}

/// One that is open no more, newest first.
struct DecidedAsk: Equatable, Sendable {
    var bead: String
    var beadTitle: String = ""
    var topic: String = ""
    var ask: Int64 = 0
    var question: String = ""
    var asker: String = ""
    var since: String = ""
    /// `answered`, `put aside`, `declined` or `taken back`.
    var state: String = ""
    var option: Int64 = 0
    var optionLabel: String = ""
    var words: String = ""
    var by: String = ""
    var returnAt: String = ""
    var secret: Secret? = nil
    var run: Run? = nil
    var setup: Setup? = nil
    var identity: Identity? = nil
    var weight: [AskWeight] = []
}

/// The person's decisions: the open asks, oldest first, and the decided.
struct Asks: Equatable, Sendable {
    var open: [OpenAsk] = []
    var decided: [DecidedAsk] = []
}

/// One option of an ask, in order, `you decide` last.
struct AskOption: Equatable, Sendable {
    var label: String = ""
    var consequence: String = ""
}

/// One bead a decision is about, as its id, title and stage.
struct AboutBead: Equatable, Sendable {
    var id: String = ""
    var title: String = ""
    var stage: String = ""
}

/// One of the bead's asks with its options, recommendation and state.
struct BeadAsk: Equatable, Sendable {
    var ask: Int64 = 0
    var to: String = ""
    var asker: String = ""
    var since: String = ""
    var question: String = ""
    var context: [String] = []
    var options: [AskOption] = []
    /// The recommended option's number; 0 when nothing is recommended.
    var recommend: Int64 = 0
    var why: String = ""
    var about: [AboutBead] = []
    /// `open`, `answered`, `put aside`, `declined` or `taken back`.
    var state: String = ""
    var option: Int64 = 0
    var words: String = ""
    var secret: Secret? = nil
    var run: Run? = nil
    var setup: Setup? = nil
    var identity: Identity? = nil
    var weight: [AskWeight] = []
}

struct BeadNote: Equatable, Sendable {
    var seq: Int64 = 0
    var kind: String = ""
    var author: String = ""
    var text: String = ""
    var at: String = ""
}

/// One bead whole: body, stage, labels, notes and its asks.
struct Bead: Equatable, Sendable {
    var id: String = ""
    var title: String = ""
    var body: String = ""
    var stage: String = ""
    var labels: [String] = []
    var notes: [BeadNote] = []
    var asks: [BeadAsk] = []
}

/// The flows view: the yard's depots as lines with the open beads on
/// each, the beads travelling with no line, and the travelling total.
struct Flows: Equatable, Sendable {
    /// The yard's open beads outside the backlog: the depots' totals
    /// plus the unassigned count. Complete, not capped.
    var travelling: Int64 = 0
    var depots: [FlowDepot] = []
    /// The open beads outside the backlog with no depot, newest first.
    var unassigned: [FlowBead] = []
}

struct FlowDepot: Equatable, Sendable {
    var name: String
    /// `git` or `dir`, as the depot is.
    var kind: String = ""
    /// The depot's open beads outside the backlog.
    var travelling: Int64 = 0
    var flows: [DepotFlow] = []
    /// The depot's open beads in no stage of the flows above.
    var elsewhere: [FlowBead] = []
    /// Why the depot's flows could not be read. Absent when they read.
    var error: String = ""
}

struct DepotFlow: Equatable, Sendable {
    var name: String
    /// The bead type it governs, `""` for the depot's own.
    var type: String = ""
    /// Where the flow comes from: `store`, `repo@<sha>`, `repo (directory)`.
    var source: String = ""
    /// The flow's stages in travel order.
    var stages: [FlowStage] = []
    /// The beads that entered merged in the trailing 24 hours, newest
    /// first, at most 30: what landed under its landed station.
    var landings: [FlowLanding] = []
}

/// One bead landed in the trailing 24 hours, as a flow serves it.
struct FlowLanding: Equatable, Sendable {
    var bead: String
    var title: String = ""
    /// When the bead entered merged, as an RFC 3339 time.
    var landedAt: String = ""
}

struct FlowStage: Equatable, Sendable {
    var stage: String
    /// The group a bead of the flow's type would be routed to here.
    var group: String = ""
    /// The group is a manual one.
    var human: Bool = false
    /// `fault`, `turn` or `none`.
    var lamp: String = "none"
    /// The stage closes the bead entering it.
    var terminal: Bool = false
    /// The routed group's seat limit; nil where no route matches.
    var limit: Int64? = nil
    /// Seats live sessions hold; nil where no route matches.
    var taken: Int64? = nil
    var beads: [FlowBead] = []
}

struct FlowBead: Equatable, Sendable {
    var bead: String
    var title: String = ""
    /// The expected arrival as the yard prints it.
    var expected: String = ""
    /// Held, stalled, blocked, waits, late; `""` when there is none.
    var remark: String = ""
    /// `red`, `amber` or `none`.
    var tone: String = "none"
    /// Who holds a held bead. Absent where the bead is not held.
    var heldBy: String = ""
    /// A session claimed it; a manual group's claim is no work.
    var working: Bool = false
    /// Who works it. Absent where no session claimed it.
    var worker: String = ""
    /// The group working it. Absent wherever no worker can be named.
    var group: String = ""
    /// The harness kind the claiming session started with.
    var kind: String = ""
    /// The model the claiming session started with.
    var model: String = ""
    /// When the bead entered its stage, as an RFC 3339 time.
    var enteredStageAt: String = ""
}

/// One event of the stream. `data` depends on the kind, and a client
/// passes over a kind or a field it does not know.
struct Event: Equatable, Sendable {
    var seq: Int64
    var kind: String = ""
    var actor: String = ""
    var at: String = ""
    /// The bead the event is about, when it is about one.
    var bead: String = ""
    var data: [String: JSONValue] = [:]

    /// A text of the event's data, empty when it has none of that name.
    func text(_ field: String) -> String {
        data[field]?.text ?? ""
    }

    /// A number of the event's data, 0 when it has none of that name.
    func number(_ field: String) -> Int64 {
        data[field]?.number ?? 0
    }
}

extension Me: Codable {
    enum CodingKeys: String, CodingKey {
        case user, yard
        case saidBy = "said_by"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        user = box.string(.user)
        saidBy = box.string(.saidBy)
        yard = box.string(.yard)
    }
}

extension Paired: Codable {
    enum CodingKeys: String, CodingKey { case token, user, device, yard }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        token = box.string(.token)
        user = box.string(.user)
        device = box.string(.device)
        yard = box.string(.yard)
    }
}

extension Settings: Codable {
    enum CodingKeys: String, CodingKey {
        case `operator`
        case blobMaxBytes = "blob_max_bytes"
        case filesMax = "files_max"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        `operator` = box.string(.operator)
        blobMaxBytes = box.string(.blobMaxBytes)
        filesMax = box.string(.filesMax)
    }
}

extension User: Codable {
    enum CodingKeys: String, CodingKey {
        case name, cursor
        case notificationCursor = "notification_cursor"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = box.string(.name)
        cursor = box.int64(.cursor)
        notificationCursor = box.int64(.notificationCursor)
    }
}

extension CrewMember: Codable {
    enum CodingKeys: String, CodingKey {
        case name, enabled, state, status
        case loginScreen = "login_screen"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = box.string(.name)
        enabled = box.bool(.enabled)
        state = box.string(.state)
        status = box.string(.status)
        loginScreen = box.bool(.loginScreen)
    }
}

extension BlobRef: Codable {
    enum CodingKeys: String, CodingKey {
        case hash, bytes, name
        case kind = "type"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        hash = box.string(.hash)
        kind = box.string(.kind)
        bytes = box.int64(.bytes)
        name = box.string(.name)
    }
}

extension Reaction: Codable {
    enum CodingKeys: String, CodingKey { case from, emoji }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        from = box.string(.from)
        emoji = box.string(.emoji)
    }
}

extension Letter: Codable {
    enum CodingKeys: String, CodingKey { case seq, at, from, to, text, read, reactions, files }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        seq = box.int64(.seq)
        at = box.string(.at)
        from = box.string(.from)
        to = box.string(.to)
        text = box.string(.text)
        read = box.bool(.read)
        reactions = box.list(.reactions, of: Reaction.self)
        files = box.list(.files, of: BlobRef.self)
    }
}

extension Inbox: Codable {
    enum CodingKeys: String, CodingKey { case mail, unread, last, from }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        mail = box.list(.mail, of: Letter.self)
        unread = box.int64(.unread)
        last = box.int64(.last)
        from = box.list(.from, of: String.self)
    }
}

extension Notification: Codable {
    enum CodingKeys: String, CodingKey { case seq, at, kind, bead, text, read }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        seq = box.int64(.seq)
        at = box.string(.at)
        kind = box.string(.kind)
        bead = box.string(.bead)
        text = box.string(.text)
        read = box.bool(.read)
    }
}

extension Notifications: Codable {
    enum CodingKeys: String, CodingKey { case notifications, unread, last }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        notifications = box.list(.notifications, of: Notification.self)
        unread = box.int64(.unread)
        last = box.int64(.last)
    }
}

extension Identity: Codable {
    enum CodingKeys: String, CodingKey { case source, sender, channel }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        source = box.string(.source)
        sender = box.string(.sender)
        channel = box.string(.channel)
    }
}

extension AskWeight: Codable {
    enum CodingKeys: String, CodingKey {
        case line
        case kind = "class"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        kind = box.string(.kind)
        line = box.string(.line)
    }
}

extension Secret: Codable {
    enum CodingKeys: String, CodingKey { case source, env, line, login, harness, hook, user, crew, `as` }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        source = box.string(.source)
        env = box.list(.env, of: String.self)
        line = box.string(.line)
        login = box.string(.login)
        harness = box.string(.harness)
        hook = box.string(.hook)
        user = box.string(.user)
        crew = box.string(.crew)
        `as` = box.string(.as)
    }
}

extension Run: Codable {
    enum CodingKeys: String, CodingKey {
        case argv, command, description, does, back, ask
        case backBy = "back_by"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        argv = box.list(.argv, of: String.self)
        command = box.string(.command)
        description = box.string(.description)
        does = box.list(.does, of: String.self)
        back = box.string(.back)
        backBy = box.string(.backBy)
        ask = box.list(.ask, of: String.self)
    }
}

extension SetupCandidate: Codable {
    enum CodingKeys: String, CodingKey { case source, file, values }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        source = box.string(.source)
        file = box.string(.file)
        values = box.optional(.values, of: [String: String].self) ?? [:]
    }
}

extension SetupGrant: Codable {
    enum CodingKeys: String, CodingKey { case source, calls }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        source = box.string(.source)
        calls = box.list(.calls, of: String.self)
    }
}

extension SetupPreset: Codable {
    enum CodingKeys: String, CodingKey { case name, grants }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = box.string(.name)
        grants = box.list(.grants, of: SetupGrant.self)
    }
}

extension Setup: Codable {
    enum CodingKeys: String, CodingKey {
        case pack, label, account, given, missing, candidates, does, back, presets
        case accountFile = "account_file"
        case backBy = "back_by"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        pack = box.string(.pack)
        label = box.string(.label)
        account = box.list(.account, of: String.self)
        accountFile = box.string(.accountFile)
        given = box.optional(.given, of: Bool.self)
        missing = box.list(.missing, of: String.self)
        candidates = box.list(.candidates, of: SetupCandidate.self)
        does = box.list(.does, of: String.self)
        back = box.string(.back)
        backBy = box.string(.backBy)
        presets = box.list(.presets, of: SetupPreset.self)
    }
}

extension OpenAsk: Codable {
    enum CodingKeys: String, CodingKey {
        case bead, topic, ask, question, asker, since, secret, run, setup, identity, weight
        case beadTitle = "bead_title"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        bead = box.string(.bead)
        beadTitle = box.string(.beadTitle)
        topic = box.string(.topic)
        ask = box.int64(.ask)
        question = box.string(.question)
        asker = box.string(.asker)
        since = box.string(.since)
        secret = box.optional(.secret, of: Secret.self)
        run = box.optional(.run, of: Run.self)
        setup = box.optional(.setup, of: Setup.self)
        identity = box.optional(.identity, of: Identity.self)
        weight = box.list(.weight, of: AskWeight.self)
    }
}

extension DecidedAsk: Codable {
    enum CodingKeys: String, CodingKey {
        case bead, topic, ask, question, asker, since, state, option, words, by, secret, run, setup, identity, weight
        case beadTitle = "bead_title"
        case optionLabel = "option_label"
        case returnAt = "return_at"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        bead = box.string(.bead)
        beadTitle = box.string(.beadTitle)
        topic = box.string(.topic)
        ask = box.int64(.ask)
        question = box.string(.question)
        asker = box.string(.asker)
        since = box.string(.since)
        state = box.string(.state)
        option = box.int64(.option)
        optionLabel = box.string(.optionLabel)
        words = box.string(.words)
        by = box.string(.by)
        returnAt = box.string(.returnAt)
        secret = box.optional(.secret, of: Secret.self)
        run = box.optional(.run, of: Run.self)
        setup = box.optional(.setup, of: Setup.self)
        identity = box.optional(.identity, of: Identity.self)
        weight = box.list(.weight, of: AskWeight.self)
    }
}

extension Asks: Codable {
    enum CodingKeys: String, CodingKey { case open, decided }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        open = box.list(.open, of: OpenAsk.self)
        decided = box.list(.decided, of: DecidedAsk.self)
    }
}

extension AskOption: Codable {
    enum CodingKeys: String, CodingKey { case label, consequence }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        label = box.string(.label)
        consequence = box.string(.consequence)
    }
}

extension AboutBead: Codable {
    enum CodingKeys: String, CodingKey { case id, title, stage }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = box.string(.id)
        title = box.string(.title)
        stage = box.string(.stage)
    }
}

extension BeadAsk: Codable {
    enum CodingKeys: String, CodingKey {
        case ask, to, asker, since, question, context, options, recommend, why, about, state, option, words, secret, run, setup, identity, weight
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        ask = box.int64(.ask)
        to = box.string(.to)
        asker = box.string(.asker)
        since = box.string(.since)
        question = box.string(.question)
        context = box.list(.context, of: String.self)
        options = box.list(.options, of: AskOption.self)
        recommend = box.int64(.recommend)
        why = box.string(.why)
        about = box.list(.about, of: AboutBead.self)
        state = box.string(.state)
        option = box.int64(.option)
        words = box.string(.words)
        secret = box.optional(.secret, of: Secret.self)
        run = box.optional(.run, of: Run.self)
        setup = box.optional(.setup, of: Setup.self)
        identity = box.optional(.identity, of: Identity.self)
        weight = box.list(.weight, of: AskWeight.self)
    }
}

extension BeadNote: Codable {
    enum CodingKeys: String, CodingKey { case seq, kind, author, text, at }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        seq = box.int64(.seq)
        kind = box.string(.kind)
        author = box.string(.author)
        text = box.string(.text)
        at = box.string(.at)
    }
}

extension Bead: Codable {
    enum CodingKeys: String, CodingKey { case id, title, body, stage, labels, notes, asks }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = box.string(.id)
        title = box.string(.title)
        body = box.string(.body)
        stage = box.string(.stage)
        labels = box.list(.labels, of: String.self)
        notes = box.list(.notes, of: BeadNote.self)
        asks = box.list(.asks, of: BeadAsk.self)
    }
}

extension Flows: Codable {
    enum CodingKeys: String, CodingKey { case travelling, depots, unassigned }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        travelling = box.int64(.travelling)
        depots = box.list(.depots, of: FlowDepot.self)
        unassigned = box.list(.unassigned, of: FlowBead.self)
    }
}

extension FlowDepot: Codable {
    enum CodingKeys: String, CodingKey { case name, kind, travelling, flows, elsewhere, error }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = box.string(.name)
        kind = box.string(.kind)
        travelling = box.int64(.travelling)
        flows = box.list(.flows, of: DepotFlow.self)
        elsewhere = box.list(.elsewhere, of: FlowBead.self)
        error = box.string(.error)
    }
}

extension DepotFlow: Codable {
    enum CodingKeys: String, CodingKey { case name, type, source, stages, landings }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        name = box.string(.name)
        type = box.string(.type)
        source = box.string(.source)
        stages = box.list(.stages, of: FlowStage.self)
        landings = box.list(.landings, of: FlowLanding.self)
    }
}

extension FlowLanding: Codable {
    enum CodingKeys: String, CodingKey {
        case bead, title
        case landedAt = "landed_at"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        bead = box.string(.bead)
        title = box.string(.title)
        landedAt = box.string(.landedAt)
    }
}

extension FlowStage: Codable {
    enum CodingKeys: String, CodingKey { case stage, group, human, lamp, terminal, limit, taken, beads }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        stage = box.string(.stage)
        group = box.string(.group)
        human = box.bool(.human)
        lamp = box.string(.lamp, "none")
        terminal = box.bool(.terminal)
        limit = box.optional(.limit, of: Int64.self)
        taken = box.optional(.taken, of: Int64.self)
        beads = box.list(.beads, of: FlowBead.self)
    }
}

extension FlowBead: Codable {
    enum CodingKeys: String, CodingKey {
        case bead, title, expected, remark, tone, working, worker, group, kind, model
        case heldBy = "held_by"
        case enteredStageAt = "entered_stage_at"
    }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        bead = box.string(.bead)
        title = box.string(.title)
        expected = box.string(.expected)
        remark = box.string(.remark)
        tone = box.string(.tone, "none")
        heldBy = box.string(.heldBy)
        working = box.bool(.working)
        worker = box.string(.worker)
        group = box.string(.group)
        kind = box.string(.kind)
        model = box.string(.model)
        enteredStageAt = box.string(.enteredStageAt)
    }
}

extension Event: Codable {
    enum CodingKeys: String, CodingKey { case seq, kind, actor, at, bead, data }
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        seq = box.int64(.seq)
        kind = box.string(.kind)
        actor = box.string(.actor)
        at = box.string(.at)
        bead = box.string(.bead)
        data = box.optional(.data, of: [String: JSONValue].self) ?? [:]
    }
}
