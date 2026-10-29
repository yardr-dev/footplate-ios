import Foundation

// One conversation (design 3.5, after Android's
// model/ConversationModel.kt): read a page at a time from its newest
// end, older pages on scroll up while the yard says `more`; written
// to with `Mail`, the letter appearing once its `mail` event comes,
// never before and never twice; acknowledged as it is shown, through
// the Mailroom. The yard's row opens the same screen over its
// notices. A letter's images are drawn under its text; its other
// files are said by count (`1 file, open it in footplate`).

/// One letter as the conversation shows it.
struct Shown: Equatable, Sendable {
    var seq: Int64
    /// The person's own: drawn at the other side, on no surface.
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

/// One image of a letter: drawn under its text, opened full on tap.
struct ShownImage: Equatable, Sendable {
    var hash: String
    var name: String
    /// The bytes, once fetched; nil while asked for, or missed.
    var bytes: Data? = nil
    /// Asked and missed: drawn as a placeholder with `name`.
    var missed: Bool = false
}

/// The picture picked for the letter: the shrunk JPEG and the name
/// it goes under. `id` tells one pick from the next, so a send
/// clears only the pick it sent.
struct Attached: Equatable, Sendable {
    var id: UUID = UUID()
    var bytes: Data
    var name: String
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
    /// The picture picked for the letter, drawn above the field.
    var attached: Attached? = nil
    /// A picked picture is being shrunk.
    var attaching: Bool = false
    /// Why a page or a letter did not go, under the field.
    var error: String? = nil
    /// The picture opened full, drawn over the conversation.
    var full: ShownImage? = nil
}

private struct ConversationKey: Hashable {
    var yard: String
    var with: String
}

/// What asking for a picture answered: the bytes, or that there
/// are none.
private enum Picture: Equatable {
    case got(Data)
    case missed
}

/// How many letters a page is.
let conversationPage: Int64 = 30

/// The crew member a bead card's Ask writes to.
let yardmaster = "yardmaster"

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
    private(set) var attachedPicture: Attached? = nil
    private(set) var attaching: Bool = false
    private var fetched: [String: Picture] = [:]
    private var fullHash: String? = nil
    /// The bead card's Ask, waiting for the open of the conversation
    /// it names.
    private var pendingAsk: (key: ConversationKey, bead: String)? = nil

    private let mailroom: Mailroom
    private let pictures: Pictures
    private let shrink: @Sendable (Data) -> Data?
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
    private var attachTask: Task<Void, Never>? = nil
    private var attachToken: UUID? = nil

    init(
        mailroom: Mailroom,
        pictures: Pictures? = nil,
        shrink: @escaping @Sendable (Data) -> Data? = { downscaleForLetter($0) },
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
                error: sendError
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
            attached: attachedPicture,
            attaching: attaching,
            error: sendError,
            full: fullHash.flatMap { hash in letters.flatMap(\.images).first { $0.hash == hash } }
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
        attachTask?.cancel()
        attachTask = nil
        attachToken = nil
        attaching = false
        if !same {
            pageLetters = []
            pageMore = false
            pageRead = false
            draftRevision &+= 1
            draftText = ""
            sendError = nil
            attachedPicture = nil
        }
        // What was missed is asked for again; what is here stays.
        fetched = fetched.filter { _, picture in
            if case .got = picture { return true }
            return false
        }
        fullHash = nil
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
        attachTask?.cancel()
        attachTask = nil
        attachToken = nil
        attaching = false
        fullHash = nil
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
    /// the yardmaster starts its draft with `bead` as the first words.
    /// Taken before the screen is shown, as `open` clears the draft of
    /// a conversation it was not showing.
    func askAbout(yard: String, bead: String) {
        pendingAsk = (ConversationKey(yard: yard, with: yardmaster), bead)
    }

    /// The picture picked under `name` is shrunk for the letter,
    /// off the main thread, and drawn above the field. One picked
    /// while another shrinks replaces it.
    func attach(bytes: Data, name: String, yard: String, with: String) {
        guard active, openedYard == yard, openedWith == with, with != yardRow else { return }
        attachTask?.cancel()
        let token = UUID()
        attachToken = token
        attaching = true
        sendError = nil
        let shrink = self.shrink
        let screen = (yard, with)
        attachTask = Task { @MainActor in
            let shrunk = await Task.detached { shrink(bytes) }.value
            // A newer pick, or another conversation, meanwhile.
            guard self.attachToken == token, (self.openedYard, self.openedWith) == screen else { return }
            if let shrunk {
                self.attaching = false
                self.attachedPicture = Attached(bytes: shrunk, name: jpegName(name))
            } else {
                self.attaching = false
                self.sendError = "The phone cannot read that picture."
            }
        }
    }

    /// The picked picture is taken back.
    func removeAttach() {
        attachTask?.cancel()
        attachTask = nil
        attachToken = nil
        attaching = false
        attachedPicture = nil
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

    /// Sends the draft with `Mail`, carrying the picked picture:
    /// the blob is put first, then the mail names its hash, and
    /// the bytes are kept so the letter draws the picture at
    /// once. The letter is shown when its event comes, so it is
    /// shown once. The text may be empty with a picture; without
    /// one, the mail goes as before.
    func send() async {
        guard active, !attaching, let yard = openedYard, let with = openedWith, with != yardRow else { return }
        let key = ConversationKey(yard: yard, with: with)
        guard !sending.contains(key) else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = draftRevision
        let attached = attachedPicture
        guard !text.isEmpty || attached != nil, let followed = mailroom.followed(yard) else { return }
        sending.insert(key)
        defer { sending.remove(key) }
        sendError = nil
        do {
            if let attached {
                let blob = try await followed.putBlob(attached.bytes)
                try await followed.mail(to: with, text: text, files: [MailFile(hash: blob.hash, name: attached.name)])
                await pictures.keep(hash: blob.hash, bytes: attached.bytes)
            } else {
                try await followed.mail(to: with, text: text, files: [])
            }
            guard active, openedYard == yard, openedWith == with else { return }
            if draftRevision == revision {
                draftText = ""
                draftRevision &+= 1
            }
            if let attached, attachedPicture?.id == attached.id {
                attachedPicture = nil
            }
        } catch let error as ApiError {
            guard active, openedYard == yard, openedWith == with, draftRevision == revision else { return }
            let what = attached == nil ? "The letter did not go" : "The picture did not go"
            sendError = "\(what): \(words(error))"
        } catch {
            guard active, openedYard == yard, openedWith == with, draftRevision == revision else { return }
            let what = attached == nil ? "The letter did not go" : "The picture did not go"
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
