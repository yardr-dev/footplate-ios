import Foundation

// What one yard's inbox holds, as footplate's model has it, in plain
// functions (after Android's model/Board.kt): read from the state a
// follower loaded, and moved on by each event after it. The Mailroom
// keeps one per followed yard; the screens' models read the rows and
// the letters from it.

/// What an event asks to be read again, since it carries less than
/// what changed.
enum Reread: Hashable, Sendable {
    case crew, notices, asks
}

/// One row of the inbox: a correspondent, or the yard's own.
struct Row: Equatable, Sendable {
    /// Whom the conversation is with; `yardRow` for the yard's row.
    var name: String
    /// The first line of the newest letter or notice, empty when
    /// none is.
    var line: String = ""
    /// When the newest letter came, in meta.
    var time: String = ""
    /// `3 unread`, or nil when nothing is.
    var unread: String? = nil
    /// A crew member's state word under the name; nil for anyone else.
    var state: String? = nil
    /// The state word is `waiting on you`, drawn in the accent.
    var waiting: Bool = false

    var isYard: Bool { name == yardRow }
}

/// The yard's row: its notices, not a conversation.
let yardRow = "yard"

/// The state word of a crew member who has asked the person something.
let waitingOnYou = "waiting on you"

struct Board: Equatable, Sendable {
    /// The user every call is made as.
    var me: String
    /// The seq the state was read at.
    var head: Int64
    var crew: [CrewMember] = []
    var users: [String] = []
    /// Every letter known to or from the user, by seq: the inbox's,
    /// then the events'.
    var letters: [Int64: Letter] = [:]
    /// Reactions changed by stream events, including letters only in
    /// a conversation page and not in the inbox.
    var reactionChanges: [Int64: [String: String]] = [:]
    /// The user's unread letters: seq to sender.
    var unread: [Int64: String] = [:]
    /// The unread the person was shown: they count no more, also
    /// while the yard has them unread still.
    var seen: Set<Int64> = []
    /// How far the user's mail is acknowledged.
    var cursor: Int64 = 0
    /// The yard's notices to the user, oldest first.
    var notices: [Notification] = []
    /// How far the notices are acknowledged.
    var noticeCursor: Int64 = 0
    /// The person's open asks, oldest first.
    var open: [OpenAsk] = []
    /// What became of the asks open no more, newest first.
    var decided: [DecidedAsk] = []
    /// The latest stream event for each bead, so its open card can be
    /// re-read even when the user's ask queue did not change.
    var beadEvents: [String: Int64] = [:]
    /// The seq of the last event applied.
    var applied: Int64

    init(me: String, head: Int64) {
        self.me = me
        self.head = head
        self.applied = head
    }

    /// Moves the board on by one event of the stream, and says what
    /// is to be read again. An event of a kind the inbox does not know
    /// changes no inbox rows (docs/api.md: a client passes over what
    /// it does not know); its bead sequence can still refresh an open
    /// `Bead` card.
    func apply(_ event: Event) -> (board: Board, rereads: Set<Reread>) {
        if event.seq <= applied { return (self, []) }
        var moved = self
        moved.applied = event.seq
        if !event.bead.isEmpty {
            moved.beadEvents[event.bead] = event.seq
        }
        var rereads: Set<Reread> = []
        if case .object(let notified) = event.data["notified"], notified[me] != nil {
            rereads.insert(.notices)
        }
        let board: Board
        if event.kind == "mail" {
            board = moved.mail(event)
        } else if event.kind == "mail_read", event.text("reader") == me {
            board = moved.read(event.number("through"))
        } else if event.kind == "notifications_read", event.text("reader") == me {
            board = moved.noticesRead(event.number("through"))
        } else if event.kind == "crew_status" {
            let name = event.text("crew")
            if moved.crew.allSatisfy({ $0.name != name }) {
                rereads.insert(.crew)
            }
            board = moved.withCrewStatus(name: name, status: event.text("status"))
        } else if event.kind.hasPrefix("crew_") {
            rereads.insert(.crew)
            board = moved
        } else if event.kind == "noted" {
            rereads.insert(.asks)
            board = moved
        } else if event.kind == "reaction" {
            board = moved.react(event)
        } else {
            board = moved
        }
        return (board, rereads)
    }

    private func withCrewStatus(name: String, status: String) -> Board {
        var copy = self
        copy.crew = crew.map { $0.name == name ? CrewMember(name: $0.name, enabled: $0.enabled, state: $0.state, status: status, loginScreen: $0.loginScreen) : $0 }
        return copy
    }

    /// A letter to or from the user; any other mail is not this
    /// inbox's. Mail to a party of a linked yard has `to_peer`: the
    /// user's own is kept as a letter to `<to>@<to_peer>`, the address
    /// of the conversation with that party, so an open conversation
    /// shows it at once; anyone else's is not this inbox's. A party's
    /// letter back arrives as mail to the user from `<name>@<peer>`.
    /// How far a letter to a linked yard has gone (queued, delivered)
    /// the phone does not say.
    private func mail(_ event: Event) -> Board {
        var to = event.text("to")
        var toMe = false
        let peer = event.text("to_peer")
        if !peer.isEmpty {
            if event.actor != me { return self }
            to = "\(to)@\(peer)"
        } else if to == me, case .bool(let isUser) = event.data["to_user"] {
            toMe = isUser
        }
        if !toMe, event.actor != me { return self }
        let letter = Letter(
            seq: event.seq, at: event.at, from: event.actor, to: to,
            text: event.text("text"), read: false, reactions: [], files: blobRefs(event.data["files"])
        )
        var copy = self
        copy.letters[event.seq] = letter
        if toMe, event.seq > cursor {
            copy.unread[event.seq] = event.actor
        }
        return copy
    }

    /// A reaction put on a letter, or taken away: the letter's
    /// reactions gain the actor's, or lose them where the emoji is
    /// empty. Per party the last reaction wins; a letter not held
    /// changes nothing, and its read carries them. No reread: the
    /// event says all of what changed.
    private func react(_ event: Event) -> Board {
        let seq = event.number("seq")
        var changes = reactionChanges[seq] ?? [:]
        changes[event.actor] = event.text("emoji")
        var copy = self
        copy.reactionChanges[seq] = changes
        if let letter = letters[seq] {
            var moved = letter
            moved.reactions = withReactionChanges(letter.reactions, changes)
            copy.letters[seq] = moved
        }
        return copy
    }

    /// Applies stream changes over a conversation page's snapshot.
    func reactionsFor(_ letter: Letter) -> [Reaction] {
        withReactionChanges(letter.reactions, reactionChanges[letter.seq] ?? [:])
    }

    /// The user's mail is read through `through`, here or by another
    /// client.
    func read(_ through: Int64) -> Board {
        if through <= cursor { return self }
        var copy = self
        copy.cursor = through
        copy.unread = unread.filter { $0.key > through }
        copy.seen = seen.filter { $0 > through }
        copy.letters = Dictionary(uniqueKeysWithValues: letters.map { (seq, letter) in
            if seq <= through, letter.to == me {
                var read = letter
                read.read = true
                return (seq, read)
            }
            return (seq, letter)
        })
        return copy
    }

    func noticesRead(_ through: Int64) -> Board {
        if through <= noticeCursor { return self }
        var copy = self
        copy.noticeCursor = through
        copy.notices = notices.map {
            if $0.seq <= through {
                var read = $0
                read.read = true
                return read
            }
            return $0
        }
        return copy
    }

    /// The notices read again: what is read stays read.
    func notices(_ fresh: [Notification]) -> Board {
        var copy = self
        copy.notices = fresh.map {
            if $0.seq <= noticeCursor {
                var read = $0
                read.read = true
                return read
            }
            return $0
        }
        return copy
    }

    /// The person was shown these letters: their unread count no more.
    func shown(_ seqs: Set<Int64>) -> Board {
        var copy = self
        copy.seen.formUnion(unread.keys.filter { seqs.contains($0) })
        return copy
    }

    /// Where the acknowledgement may go: through the newest letter
    /// shown, but not past an unread letter that was not, since one
    /// position stands for every sender and would mark that one read
    /// unseen. Never behind `cursor`.
    func ackThrough() -> Int64 {
        guard let shown = seen.max() else { return cursor }
        let unseen = unread.keys.filter { !seen.contains($0) }.min()
        let through = unseen.map { min(shown, $0 - 1) } ?? shown
        return max(cursor, through)
    }

    /// The newest notice, the one the yard's row acknowledges through.
    var newestNotice: Int64 {
        notices.map(\.seq).max() ?? 0
    }

    /// How many of `party`'s letters the person has not been shown.
    func unreadOf(_ party: String) -> Int {
        unread.count { (seq, from) in from == party && !seen.contains(seq) }
    }

    /// The letters of the conversation with `party`, oldest first.
    func lettersWith(_ party: String) -> [Letter] {
        letters.values.filter { partyOf($0) == party }.sorted { $0.seq < $1.seq }
    }

    /// Whom a letter's conversation is with: the other party, or the
    /// user for a note to self.
    func partyOf(_ letter: Letter) -> String {
        letter.from == me ? letter.to : letter.from
    }

    /// A crew member's state word, `waiting on you` where they asked
    /// the person something open; nil for anyone who is no crew member.
    func stateOf(_ name: String) -> String? {
        guard let member = crew.first(where: { $0.name == name }) else { return nil }
        if open.contains(where: { $0.asker == name }) { return waitingOnYou }
        return stateWord(member)
    }

    /// The inbox's rows: one per correspondent, newest letter first,
    /// those with no letter after them in the order the crew and the
    /// users have them; the yard's row first when it has unread
    /// notices, else last.
    func rows(stamp: (String) -> String) -> [Row] {
        var names: [String] = []
        func add(_ name: String) {
            if !names.contains(name) { names.append(name) }
        }
        for member in crew { add(member.name) }
        for user in users { add(user) }
        for letter in letters.values.sorted(by: { $0.seq < $1.seq }) { add(partyOf(letter)) }
        var newest: [String: Letter] = [:]
        for letter in letters.values {
            let party = partyOf(letter)
            if newest[party].map({ letter.seq > $0.seq }) ?? true {
                newest[party] = letter
            }
        }
        let people = names.enumerated().map { (index, name) -> (index: Int, row: Row) in
            let letter = newest[name]
            let state = stateOf(name)
            return (index, Row(
                name: name,
                line: letter.map { firstLine($0.text, $0.files.count) } ?? "",
                time: letter.map { stamp($0.at) } ?? "",
                unread: unreadOf(name) > 0 ? "\(unreadOf(name)) unread" : nil,
                state: state,
                waiting: state == waitingOnYou
            ))
        }.sorted { a, b in
            let aSeq = newest[a.row.name]?.seq ?? 0
            let bSeq = newest[b.row.name]?.seq ?? 0
            if aSeq != bSeq { return aSeq > bSeq }
            return a.index < b.index
        }.map(\.row)
        let notice = notices.max { $0.seq < $1.seq }
        let unreadNotices = notices.count { !$0.read && $0.seq > noticeCursor }
        let yard = Row(
            name: yardRow,
            line: notice.map { firstLine($0.text, 0) } ?? "",
            time: notice.map { stamp($0.at) } ?? "",
            unread: unreadNotices > 0 ? "\(unreadNotices) unread" : nil
        )
        return unreadNotices > 0 ? [yard] + people : people + [yard]
    }

    /// The board of a state just read: the inbox's letters, unread
    /// those the yard has unread, and nothing applied past the head.
    static func of(_ loaded: Loaded) -> Board {
        let me = loaded.me.user
        let cursor = loaded.user.cursor
        var board = Board(me: me, head: loaded.head)
        board.crew = loaded.crew
        board.users = loaded.users.map(\.name)
        board.letters = Dictionary(uniqueKeysWithValues: loaded.inbox.mail.map { ($0.seq, $0) })
        board.unread = Dictionary(uniqueKeysWithValues: loaded.inbox.mail.filter { !$0.read && $0.seq > cursor }.map { ($0.seq, $0.from) })
        board.cursor = cursor
        board.noticeCursor = loaded.user.notificationCursor
        board.open = loaded.asks.open
        board.decided = loaded.asks.decided
        return board.notices(loaded.notifications.notifications)
    }
}

private func withReactionChanges(_ reactions: [Reaction], _ changes: [String: String]) -> [Reaction] {
    if changes.isEmpty { return reactions }
    var byParty: [String: Reaction] = [:]
    for reaction in reactions { byParty[reaction.from] = reaction }
    for (party, emoji) in changes {
        if emoji.isEmpty {
            byParty.removeValue(forKey: party)
        } else {
            byParty[party] = Reaction(from: party, emoji: emoji)
        }
    }
    return byParty.values.sorted { $0.from < $1.from }
}

/// The files of a mail event's data, as the wire has them.
func blobRefs(_ value: JSONValue?) -> [BlobRef] {
    guard case .array(let items) = value else { return [] }
    return items.map { item in
        guard case .object(let fields) = item else { return BlobRef() }
        return BlobRef(
            hash: fields["hash"]?.text ?? "",
            kind: fields["type"]?.text ?? "",
            bytes: fields["bytes"]?.number ?? 0,
            name: fields["name"]?.text ?? ""
        )
    }
}

/// A crew member's state in a word, as footplate's `state_of` says it.
func stateWord(_ member: CrewMember) -> String {
    if member.state == "failed" { return "failed to start" }
    if member.state == "running", member.loginScreen { return "not logged in" }
    if member.state == "running" {
        switch member.status {
        case "working": return "working"
        case "idle": return "idle"
        case "blocked": return "blocked"
        default: return "running"
        }
    }
    return "not running"
}

/// A letter's first line, for a row; a letter of files alone says how
/// many.
func firstLine(_ text: String, _ files: Int) -> String {
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
    }
    return filesWords(files) ?? ""
}

/// What a letter's files are called on the phone, which shows none.
func filesWords(_ files: Int) -> String? {
    switch files {
    case 0: return nil
    case 1: return "1 file"
    default: return "\(files) files"
    }
}

/// When a letter came, in meta: the time on the day it is, else the
/// day and the month, and the year where it is another. A time the
/// yard wrote that cannot be read says nothing.
func stamp(_ at: String, now: Date, zone: TimeZone) -> String {
    guard let instant = parseInstant(at) else { return "" }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let pattern: String
    if calendar.isDate(instant, inSameDayAs: now) {
        pattern = "HH:mm"
    } else if calendar.component(.year, from: instant) == calendar.component(.year, from: now) {
        pattern = "d MMM"
    } else {
        pattern = "d MMM yyyy"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = pattern
    return formatter.string(from: instant)
}

/// An RFC 3339 time as the yard writes it, or nil where it is none.
func parseInstant(_ text: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
}
