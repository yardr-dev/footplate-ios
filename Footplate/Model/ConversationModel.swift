import Foundation

// One conversation (design 3.5, after Android's
// model/ConversationModel.kt): read a page at a time from its newest
// end, older pages on scroll up while the yard says `more`; written
// to with `Mail`, the letter appearing once its `mail` event comes,
// never before and never twice; acknowledged as it is shown, through
// the Mailroom. The yard's row opens the same screen over its
// notices. A letter's images are drawn under its text; its other
// files are said by count (`1 file, open it in footplate`). A chip
// tapped opens its bead as a sheet over the conversation.

/// One letter as the conversation shows it.
struct Shown: Equatable, Sendable {
    var seq: Int64
    /// The person's own: drawn in a bubble at the right. Any other is
    /// drawn the width of the conversation on no surface.
    var mine: Bool
    var text: String
    var time: String
    /// `1 file, open it in footplate`, where the letter carries
    /// files that are no image.
    var files: String? = nil
    /// The letter's images, drawn under its text.
    var images: [ShownImage] = []
}

/// The whole text a long-press on the letter offers to copy, or nil
/// where the letter has none (an image alone). The copy is the
/// letter's words entire, never one link of them.
func copyableMessage(_ letter: Shown) -> String? {
    letter.text.isEmpty ? nil : letter.text
}

/// One image of a letter or of a bead's note: drawn under its text,
/// opened full on tap.
struct ShownImage: Equatable, Sendable {
    var hash: String
    var name: String
    /// The bytes, once fetched; nil while asked for, or missed.
    var bytes: Data? = nil
    /// Asked and missed: drawn as a placeholder with `name`.
    var missed: Bool = false
}

/// A picture picked for the letter: the shrunk JPEG and the name it
/// goes under. `id` tells one pick from the next: a pick is taken back by
/// it, and a send clears only the picks it sent.
struct Attached: Equatable, Sendable {
    var id: UUID = UUID()
    var bytes: Data
    var name: String
}

/// How many pictures one letter carries from the phone. Each is held,
/// shrunk to 700 KB at most, until the letter goes, so the bound is what
/// the phone's memory allows, far under the yard's own (64 files a mail).
let maxAttached = 10

/// The word under the letters while `count` picked pictures are prepared,
/// none where none does.
func attachingWords(_ count: Int) -> String? {
    switch count {
    case ...0: return nil
    case 1: return "Preparing the picture…"
    default: return "Preparing \(count) pictures…"
    }
}

/// One pick of the letter's row: its picture once it is prepared, and its
/// task while it is being read from Photos or shrunk.
private struct Pick {
    var id: UUID
    var picture: Attached? = nil
    var task: Task<Void, Never>? = nil
}

struct ConversationState: Equatable, Sendable {
    /// Whom it is with, or `yard` for the yard's notices.
    var title: String = ""
    /// A crew member's state word, in meta beside the name.
    var state: String? = nil
    var waiting: Bool = false
    /// Oldest first, the newest at the foot.
    var letters: [Shown] = []
    /// Older letters wait, read on scroll up.
    var more: Bool = false
    /// A page is being read.
    var reading: Bool = false
    /// The bead ids that chip in the letters: the open and decided asks'
    /// beads, the beads the stream named, and those the yard confirmed
    /// when mail named them.
    var knownBeads: Set<String> = []
    /// The notices are read, not answered: no field.
    var writable: Bool = true
    var draft: String = ""
    var sending: Bool = false
    /// The pictures picked for the letter, in the order they were picked,
    /// drawn above the field.
    var attached: [Attached] = []
    /// How many picked pictures are being prepared.
    var attaching: Int = 0
    /// Why a page or a letter did not go, under the field.
    var error: String? = nil
    /// The picture opened full, drawn over the conversation.
    var full: ShownImage? = nil
    /// A chip's bead, drawn as a sheet over the conversation.
    var sheet: BeadRoute? = nil
}

private struct ConversationKey: Hashable {
    var yard: String
    var with: String
}

/// What asking for a picture answered: the bytes, or that there
/// are none. A bead's notes keep their pictures' answers the same way.
enum Picture: Equatable {
    case got(Data)
    case missed
}

/// How many letters a page is.
let conversationPage: Int64 = 30

/// The crew member a bead card's Ask writes to where the yard names
/// none of its own: a yard older than /user/me's `yardmaster` field.
let yardmaster = "yardmaster"

/// The crew member an Ask about a bead of `followed`'s yard writes to,
/// and names: what /user/me answered, or the yardmaster where the yard
/// answers none or is not read yet.
@MainActor
func coordinator(of followed: (any Followed)?) -> String {
    let named = followed?.state.loaded?.me.yardmaster ?? ""
    return named.isEmpty ? yardmaster : named
}

/// The draft with `bead` as its first words, keeping what is there.
func askDraft(_ draft: String, bead: String) -> String {
    if draft.hasPrefix("\(bead) ") { return draft }
    if draft == bead { return "\(bead) " }
    return "\(bead) \(draft)"
}

/// One id the yard was asked about, in one yard's mail.
struct AskedBead: Hashable, Sendable {
    var yard: String
    var bead: String
}

/// The bead ids that chip in `yard`'s mail: the open and decided asks'
/// beads, the beads the stream named, and those the yard confirmed when
/// mail named them (`looked`, by yard and id), a closed bead among them.
/// Only these chip: any other id-shaped word stays plain text.
func knownBeads(board: Board?, yard: String?, looked: [AskedBead: Bool]) -> Set<String> {
    var known: Set<String> = []
    if let board {
        known.formUnion(board.open.map(\.bead))
        known.formUnion(board.decided.map(\.bead))
        known.formUnion(board.beadEvents.keys)
    }
    for (asked, confirmed) in looked where confirmed && asked.yard == yard {
        known.insert(asked.bead)
    }
    return known
}

@MainActor
@Observable
final class ConversationModel {
    private var openedYard: String? = nil
    private var openedWith: String? = nil
    private var pageLetters: [Letter] = []
    private var pageMore: Bool = false
    private var pageRead: Bool = false
    private(set) var draftText: String = ""
    private var sending: Set<ConversationKey> = []
    private var draftRevision: UInt64 = 0
    private(set) var reading: Bool = false
    private(set) var sendError: String? = nil
    /// The letter's row of pictures, in the order they were picked. A pick
    /// has its place from the moment it is picked, so a shrink that ends
    /// before an earlier pick's does not move ahead of it.
    private var picks: [Pick] = []
    private var fetched: [String: Picture] = [:]
    private var fullHash: String? = nil
    private var sheetBead: BeadRoute? = nil
    /// The bead card's Ask, waiting for the open of the conversation
    /// it names.
    private var pendingAsk: (key: ConversationKey, bead: String)? = nil

    private let mailroom: Mailroom
    private let pictures: Pictures
    private let shrink: @Sendable (Data) async -> Data?
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    private var active = false
    private var generation = 0
    private var lastHead: Int64? = nil
    private var boardsObserver: UUID? = nil
    private var readTask: Task<Void, Never>? = nil
    private var activeRead: UUID? = nil
    /// A fetch in flight, by hash: one letter's image is asked
    /// for once.
    private var fetching: [String: Task<Void, Never>] = [:]
    /// What the yard answered for the ids shown mail named, by yard and
    /// id: a closed bead among the confirmed.
    private var looked: [AskedBead: Bool] = [:]
    /// The ids asked about and not yet answered, by yard and id: each is
    /// asked once.
    private var looking: Set<AskedBead> = []

    init(
        mailroom: Mailroom,
        pictures: Pictures? = nil,
        shrink: @escaping @Sendable (Data) async -> Data? = { downscaleForLetter($0) },
        now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.mailroom = mailroom
        self.pictures = pictures ?? Pictures.live()
        self.shrink = shrink
        self.now = now
        self.zone = zone
        boardsObserver = mailroom.observeBoards { [weak self] in
            self?.boardChanged()
        }
    }

    var state: ConversationState {
        guard let with = openedWith, let yard = openedYard else { return ConversationState() }
        let board = mailroom.boards[yard]
        let now = now()
        let zone = zone()
        if with == yardRow {
            return ConversationState(
                title: yardRow,
                letters: (board?.notices ?? []).sorted { $0.seq < $1.seq }.map {
                    Shown(seq: $0.seq, mine: false, text: $0.text, time: stamp($0.at, now: now, zone: zone))
                },
                knownBeads: knownBeads(board: board, yard: yard, looked: looked),
                writable: false,
                draft: draftText,
                error: sendError,
                sheet: sheetBead
            )
        }
        let stateWord = board?.stateOf(with)
        let letters = mergedLetters(board).map { letter in
            let images = letter.files.filter(isImage)
            let others = letter.files.filter { !isImage($0) }
            return Shown(
                seq: letter.seq,
                mine: board.map { letter.from == $0.me } ?? false,
                text: letter.text,
                time: stamp(letter.at, now: now, zone: zone),
                files: filesWords(others.count).map { "\($0), open it in footplate" },
                images: images.map { file in
                    switch fetched[file.hash] {
                    case .got(let bytes): return ShownImage(hash: file.hash, name: file.name, bytes: bytes)
                    case .missed: return ShownImage(hash: file.hash, name: file.name, missed: true)
                    case nil: return ShownImage(hash: file.hash, name: file.name)
                    }
                }
            )
        }
        return ConversationState(
            title: with,
            state: stateWord,
            waiting: stateWord == waitingOnYou,
            letters: letters,
            more: pageMore,
            reading: reading,
            knownBeads: knownBeads(board: board, yard: yard, looked: looked),
            draft: draftText,
            sending: sending.contains(ConversationKey(yard: yard, with: with)),
            attached: picks.compactMap(\.picture),
            attaching: picks.filter { $0.picture == nil }.count,
            error: sendError,
            full: fullHash.flatMap { hash in letters.flatMap(\.images).first { $0.hash == hash } },
            sheet: sheetBead
        )
    }

    /// The conversation `yard`/`with` is shown: read from its newest
    /// end, again whenever its yard is read again, and acknowledged
    /// as it is shown.
    func open(yard: String, with: String) {
        let same = openedYard == yard && openedWith == with
        // Any open takes the Ask, and only the conversation it names
        // keeps it.
        let ask = pendingAsk.flatMap { $0.key == ConversationKey(yard: yard, with: with) ? $0.bead : nil }
        pendingAsk = nil
        if same, active {
            if let ask { draft(askDraft(draftText, bead: ask)) }
            return
        }
        generation += 1
        readTask?.cancel()
        readTask = nil
        activeRead = nil
        reading = false
        dropPreparing()
        if !same {
            pageLetters = []
            pageMore = false
            pageRead = false
            draftRevision &+= 1
            draftText = ""
            sendError = nil
            picks = []
        }
        // What was missed is asked for again; what is here stays.
        fetched = fetched.filter { _, picture in
            if case .got = picture { return true }
            return false
        }
        fullHash = nil
        sheetBead = nil
        if let ask { draft(askDraft(draftText, bead: ask)) }
        // A conversation that comes back on screen reads its newest page
        // again, even when the follower's head has not changed.
        lastHead = nil
        openedYard = yard
        openedWith = with
        active = true
        showVisible()
        boardChanged()
        fetchShown()
        lookupShown()
    }

    /// The conversation is no longer on the screen.
    func leave() {
        active = false
        generation += 1
        readTask?.cancel()
        readTask = nil
        activeRead = nil
        reading = false
        dropPreparing()
        fullHash = nil
        sheetBead = nil
        for task in fetching.values { task.cancel() }
        mailroom.show(nil)
    }

    /// The person scrolled to the oldest letter shown: the page
    /// before it, while the yard has one.
    func older() async {
        guard active, pageMore, !reading, let oldest = pageLetters.first?.seq,
              let yard = openedYard, let with = openedWith, with != yardRow else { return }
        await read(yard: yard, with: with, before: oldest)
    }

    func draft(_ text: String) {
        draftRevision &+= 1
        draftText = text
        sendError = nil
    }

    /// The bead card's Ask: the next open of `yard`'s conversation with
    /// the coordinator named `with` starts its draft with `bead` as the
    /// first words. Taken before the screen is shown, as `open` clears
    /// the draft of a conversation it was not showing.
    func askAbout(yard: String, bead: String, with: String = yardmaster) {
        pendingAsk = (ConversationKey(yard: yard, with: with), bead)
    }

    /// The open visit that may accept a picture after Photos has read it.
    /// A conversation can be left and reopened with the same names while a
    /// library read is still in flight, so its yard and correspondent alone
    /// do not identify the visit that launched the read.
    func attachmentVisit(yard: String, with: String) -> Int? {
        guard active, openedYard == yard, openedWith == with, with != yardRow else { return nil }
        return generation
    }

    /// Bytes already read join the row on the visit that opened the picker
    /// or camera. A failed read names the picture and takes no place.
    @discardableResult
    func attach(bytes: Data?, name: String, yard: String, with: String) -> (id: UUID, task: Task<Void, Never>)? {
        guard let visit = attachmentVisit(yard: yard, with: with) else { return nil }
        return attach(bytes: bytes, name: name, yard: yard, with: with, visit: visit)
    }

    /// Bytes already read join the row on the visit that opened the picker
    /// or camera. The visit prevents a late answer from an earlier screen
    /// from joining a later visit to this same conversation.
    @discardableResult
    func attach(bytes: Data?, name: String, yard: String, with: String, visit: Int) -> (id: UUID, task: Task<Void, Never>)? {
        let named = jpegName(name)
        guard let bytes else {
            guard isCurrentAttachmentVisit(visit, yard: yard, with: with) else { return nil }
            sendError = "The phone cannot read \(named)."
            return nil
        }
        return attach(load: { bytes }, name: name, yard: yard, with: with, visit: visit)
    }

    /// Reserve a row position before an asynchronous Photos read starts.
    /// Send joins this task, so a slow original cannot be left for the next
    /// letter merely because its bytes have not reached the model yet.
    @discardableResult
    func attach(
        load: @escaping @MainActor () async -> Data?,
        name: String,
        yard: String,
        with: String,
        visit: Int
    ) -> (id: UUID, task: Task<Void, Never>)? {
        guard isCurrentAttachmentVisit(visit, yard: yard, with: with) else { return nil }
        guard picks.count < maxAttached else {
            sendError = "A letter carries at most \(maxAttached) pictures."
            return nil
        }
        let named = jpegName(name)
        let id = UUID()
        let shrink = self.shrink
        let task = Task { @MainActor [weak self] in
            guard let bytes = await load() else {
                self?.landed(nil, id: id, named: named)
                return
            }
            guard !Task.isCancelled else { return }
            let worker = Task.detached { await shrink(bytes) }
            let shrunk = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            self?.landed(shrunk, id: id, named: named)
        }
        picks.append(Pick(id: id, task: task))
        return (id, task)
    }

    private func isCurrentAttachmentVisit(_ visit: Int, yard: String, with: String) -> Bool {
        active && openedYard == yard && openedWith == with && generation == visit && with != yardRow
    }

    /// A shrink ended: its picture takes its place in the row, or its pick
    /// is skipped with words naming it. A pick taken back, or dropped with
    /// its conversation, has no place any more, and what ended after it
    /// lands nowhere: whoever holds the pick's place owns it.
    private func landed(_ shrunk: Data?, id: UUID, named: String) {
        guard let index = picks.firstIndex(where: { $0.id == id }) else { return }
        if let shrunk {
            picks[index].picture = Attached(id: id, bytes: shrunk, name: named)
            picks[index].task = nil
        } else {
            picks.remove(at: index)
            sendError = "The phone cannot read \(named)."
        }
    }

    /// Every read or shrink in flight is cancelled and its pick dropped, so
    /// it never lands; the pictures already prepared stay.
    private func dropPreparing() {
        for pick in picks { pick.task?.cancel() }
        picks.removeAll { $0.picture == nil }
    }

    /// The picked picture `id` is taken back: a read or shrink in flight is
    /// cancelled and never lands, a prepared one leaves the row.
    func removeAttach(id: UUID) {
        guard let index = picks.firstIndex(where: { $0.id == id }) else { return }
        picks[index].task?.cancel()
        picks.remove(at: index)
    }

    /// The picture `hash` is opened full, drawn over the
    /// conversation until `closePicture`. One no letter shown
    /// carries opens nothing.
    func openPicture(_ hash: String) {
        fullHash = hash
    }

    /// The full picture shuts.
    func closePicture() {
        fullHash = nil
    }

    /// A chip tapped: its bead opens as a sheet over the
    /// conversation, leaving the tab alone, until `closeBeadSheet`.
    func openBead(_ id: String) {
        guard let yard = openedYard else { return }
        sheetBead = BeadRoute(yard: yard, bead: id)
    }

    /// The chip's sheet shuts: swiped down, or opened on the line.
    func closeBeadSheet() {
        sheetBead = nil
    }

    /// Sends the draft with `Mail`, carrying the picked pictures: each
    /// blob is put first, in the row's order, then one mail names their
    /// hashes, and the bytes are kept, once the mail has gone, so the
    /// letter draws the pictures at once. The letter is shown when its
    /// event comes, so it is shown once. The text may be empty with
    /// pictures; without any, the mail goes as before. Pictures still
    /// being read or shrunk are waited for, and a letter goes only with
    /// every picture it set out with: one taken back, one that will not
    /// shrink or a screen left meanwhile stops it, the draft and row as they were.
    /// Only the pictures sent leave the row: one picked after the send
    /// began is for the next letter.
    func send() async {
        guard active, let yard = openedYard, let with = openedWith, with != yardRow else { return }
        let key = ConversationKey(yard: yard, with: with)
        guard !sending.contains(key) else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = draftRevision
        let carried = picks.map(\.id)
        guard !text.isEmpty || !carried.isEmpty, let followed = mailroom.followed(yard) else { return }
        let visit = generation
        sending.insert(key)
        defer { sending.remove(key) }
        sendError = nil
        for task in picks.compactMap(\.task) { await task.value }
        let attached = carried.compactMap { id in picks.first { $0.id == id }?.picture }
        guard attached.count == carried.count, visit == generation else { return }
        let what = switch attached.count {
        case 0: "The letter did not go"
        case 1: "The picture did not go"
        default: "The pictures did not go"
        }
        do {
            var files: [MailFile] = []
            for picture in attached {
                let blob = try await followed.putBlob(picture.bytes)
                files.append(MailFile(hash: blob.hash, name: picture.name))
            }
            try await followed.mail(to: with, text: text, files: files)
            for (picture, file) in zip(attached, files) {
                await pictures.keep(hash: file.hash, bytes: picture.bytes)
            }
            guard active, openedYard == yard, openedWith == with else { return }
            if draftRevision == revision {
                draftText = ""
                draftRevision &+= 1
            }
            let sent = Set(attached.map(\.id))
            picks.removeAll { sent.contains($0.id) }
        } catch let error as ApiError {
            guard active, openedYard == yard, openedWith == with, draftRevision == revision else { return }
            sendError = "\(what): \(words(error))"
        } catch {
            guard active, openedYard == yard, openedWith == with, draftRevision == revision else { return }
            sendError = "\(what): \(words(ApiError.down(why: "an unexpected error")))"
        }
    }

    /// Asks for every shown image not yet answered, once each:
    /// the fetch answers the state, which asks for what is still
    /// missing, until nothing is.
    private func fetchShown() {
        guard active, let yard = openedYard, let with = openedWith, with != yardRow,
              let followed = mailroom.followed(yard) else { return }
        let board = mailroom.boards[yard]
        for letter in mergedLetters(board) {
            for file in letter.files where isImage(file) {
                fetch(followed: followed, hash: file.hash)
            }
        }
    }

    /// Asks for `hash` once while its request is active: a
    /// cancelled request may be replaced, and a miss is a
    /// placeholder, not an error.
    private func fetch(followed: any Followed, hash: String) {
        if fetched[hash] != nil { return }
        if let current = fetching[hash], !current.isCancelled { return }
        let pictures = self.pictures
        let task = Task { @MainActor in
            let bytes: Data?
            do {
                bytes = try await pictures.bytes(hash: hash) { try await followed.blob(hash: hash) }
            } catch is ApiError {
                bytes = nil
            } catch {
                bytes = nil
            }
            if Task.isCancelled { return }
            // Only the fetch still registered for this hash may
            // answer: a cancelled one replaced on reopen does not.
            guard self.fetching[hash] != nil else { return }
            self.fetching.removeValue(forKey: hash)
            self.fetched[hash] = bytes.map { .got($0) } ?? .missed
        }
        fetching[hash] = task
    }

    /// Asks the yard which of the ids the shown mail names are beads, of
    /// those the app does not know: a bead that closed falls out of every
    /// list, and its id in old mail would stand plain. Each id once per
    /// yard, through the `Bead` call, which answers for a closed bead too:
    /// what the yard answered is kept, and what it did not answer for want
    /// of a link is asked again when mail next comes into view. An id a
    /// list holds stays a bead after it leaves the list.
    private func lookupShown() {
        guard active, let yard = openedYard, let with = openedWith,
              let followed = mailroom.followed(yard) else { return }
        let board = mailroom.boards[yard]
        let texts = with == yardRow
            ? board?.notices.map(\.text) ?? []
            : mergedLetters(board).map(\.text)
        let known = knownBeads(board: board, yard: yard, looked: looked)
        var seen: Set<String> = []
        let named = texts.flatMap(beadIds).filter { seen.insert($0).inserted }
        for id in named where known.contains(id) && looked[AskedBead(yard: yard, bead: id)] != true {
            looked[AskedBead(yard: yard, bead: id)] = true
        }
        var wanted: [String] = []
        for id in named where !known.contains(id) && looked[AskedBead(yard: yard, bead: id)] == nil {
            if looking.insert(AskedBead(yard: yard, bead: id)).inserted { wanted.append(id) }
        }
        guard !wanted.isEmpty else { return }
        Task { @MainActor [weak self] in
            for id in wanted {
                let found: String?
                do {
                    found = try await followed.bead(id).id
                } catch ApiError.refused {
                    found = nil
                } catch is ApiError {
                    // The link says nothing of the id: asked again when
                    // mail next comes into view.
                    continue
                } catch {
                    continue
                }
                self?.looked[AskedBead(yard: yard, bead: id)] = (found == id)
            }
            for id in wanted { self?.looking.remove(AskedBead(yard: yard, bead: id)) }
        }
    }

    private func boardChanged() {
        guard active, let yard = openedYard, let with = openedWith else { return }
        // The notices name beads too, and read no pages.
        if with == yardRow {
            lookupShown()
            return
        }
        guard let board = mailroom.boards[yard] else { return }
        pageLetters = withEvents(board.lettersWith(with))
        showVisible()
        fetchShown()
        lookupShown()
        if board.head != lastHead {
            lastHead = board.head
            let gen = generation
            readTask?.cancel()
            readTask = Task { @MainActor in
                guard gen == self.generation else { return }
                await self.read(yard: yard, with: with, before: 0)
            }
        }
    }

    /// The pages read with the letters `since` the events brought:
    /// those newer than the oldest read, so no gap opens where an
    /// older page is unread. Nothing before the first page is read.
    private func withEvents(_ since: [Letter]) -> [Letter] {
        if !pageRead { return pageLetters }
        let board = openedYard.flatMap { mailroom.boards[$0] }
        let overlaid = since.map { letter in
            var copy = letter
            copy.reactions = board?.reactionsFor(letter) ?? letter.reactions
            return copy
        }
        let oldest = pageLetters.first?.seq ?? 0
        let newer = overlaid.filter { !pageMore || $0.seq >= oldest }
        if newer.allSatisfy({ candidate in pageLetters.contains(candidate) }) { return pageLetters }
        var bySeq: [Int64: Letter] = [:]
        for letter in pageLetters { bySeq[letter.seq] = letter }
        for letter in newer { bySeq[letter.seq] = letter }
        return bySeq.values.sorted { $0.seq < $1.seq }
    }

    private func mergedLetters(_ board: Board?) -> [Letter] {
        guard let board, let with = openedWith else { return pageLetters }
        let since = board.lettersWith(with)
        if !pageRead { return pageLetters }
        let oldest = pageLetters.first?.seq ?? 0
        let newer = since.filter { !pageMore || $0.seq >= oldest }
        var bySeq: [Int64: Letter] = [:]
        for letter in pageLetters { bySeq[letter.seq] = letter }
        for letter in newer {
            var copy = letter
            copy.reactions = board.reactionsFor(letter)
            bySeq[letter.seq] = copy
        }
        return bySeq.values.sorted { $0.seq < $1.seq }
    }

    /// Reads the page before `before` (0: the newest) into the pages,
    /// by seq, so a page read again adds only what is new.
    private func read(yard: String, with: String, before: Int64) async {
        guard let followed = mailroom.followed(yard) else { return }
        let gen = generation
        let request = UUID()
        activeRead = request
        reading = true
        do {
            let page = try await followed.conversation(with: with, limit: conversationPage, before: before)
            guard gen == generation, request == activeRead, active, openedYard == yard, openedWith == with else { return }
            var bySeq: [Int64: Letter] = [:]
            for letter in pageLetters { bySeq[letter.seq] = letter }
            for letter in page.letters { bySeq[letter.seq] = letter }
            // The newest page read again says nothing of what is
            // older than it; an older page says whether more is
            // older still.
            pageMore = before == 0 && pageRead ? pageMore : page.more
            pageLetters = bySeq.values.sorted { $0.seq < $1.seq }
            pageRead = true
            reading = false
            activeRead = nil
            showVisible()
            fetchShown()
            lookupShown()
        } catch let error as ApiError {
            guard gen == generation, request == activeRead else { return }
            reading = false
            activeRead = nil
            sendError = words(error)
        } catch {
            guard gen == generation, request == activeRead else { return }
            reading = false
            activeRead = nil
        }
    }

    /// Only letters in the pages shown by this screen can move the
    /// shared inbox acknowledgement cursor. Older unread letters wait
    /// for their page, even when they are from the same correspondent.
    private func showVisible() {
        guard active, let yard = openedYard, let with = openedWith else { return }
        if with == yardRow {
            mailroom.show(OnScreen(yard: yard, party: yardRow, visible: []))
            return
        }
        let shown = mergedLetters(mailroom.boards[yard])
        mailroom.show(OnScreen(yard: yard, party: with, visible: Set(shown.map(\.seq))))
    }
}
