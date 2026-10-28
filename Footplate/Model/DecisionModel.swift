import Foundation

/// The session's telling of a refusal, under a name the model's own
/// `words` field does not shadow.
private func refusalWords(_ error: ApiError) -> String { words(error) }

// One decision (design 3.5, after Android's model/DecisionModel.kt),
// read with `Bead`: the weighty lines first, the question, its context
// (shut behind a toggle until it is tapped, and shut again for the next
// ask) and the beads it is about, the options with what each costs and
// the recommended one, the words, and Pick, Later and Decline. A pick that
// passes the gate (3.4) goes with `weighed` only after the unlock was
// passed, or the ask's number typed back where the phone has no screen
// lock; a cancelled unlock sends nothing and keeps the choice. A card
// the edge cannot approve shows the command that answers it instead of
// Pick. A run or setup ask is approved with Approve, always behind the
// gate, with `weighed`; an approval the yard refuses shows the yard's
// sentence with the per-type command instead, and is not made again.
// A secret card shows that command too, but for the one secret the edge
// carries, a harness login's one-time code: that card takes the code in
// a field that does not echo and gives it with Give, always behind the
// gate, with `weighed`, and a giving the yard refuses is shown as an
// approval it refused. Decline asks why in a field and sends at the next
// press; on a secret card it sends at the first, with no words and no
// field, since the yard takes none there. What was sent leaves the card;
// the list moves it to Decided when the yard's `noted` event comes.

/// One option of a card, numbered from 1, `you decide` last.
struct Choice: Equatable, Sendable {
    var number: Int64
    var label: String
    /// What it costs, in body, secondary, under the label.
    var consequence: String
    /// Marked `recommended` in the accent at its right.
    var recommended: Bool = false
}

/// One bead the ask is about, with its details row's state: shut
/// until tapped, then the bead's description, read once with the
/// whole-bead call when first opened.
struct AboutDetail: Equatable, Sendable {
    var id: String
    var title: String
    var stage: String
    /// The row is open: the description, its loading or its error shows.
    var expanded: Bool = false
    /// The bead's description, read once and kept while the card is open.
    var body: String? = nil
    var loading: Bool = false
    /// Why the description was not read; the card stays usable.
    var error: String? = nil
}

struct DecisionState: Equatable, Sendable {
    /// The bead was read: the card can be drawn.
    var read: Bool = false
    /// The ask's number: what is typed back where there is no screen lock.
    var ask: Int64 = 0
    /// The `WEIGHTY` lines, first on the card.
    var weighty: [String] = []
    var question: String = ""
    var context: [String] = []
    /// The context lines are shown: shut when the card opens, until
    /// the toggle is tapped.
    var contextShown: Bool = false
    /// The beads it is about, one details row each.
    var details: [AboutDetail] = []
    var options: [Choice] = []
    /// Why the recommended option, under the list.
    var why: String = ""
    /// The option chosen, 0 while none is: Pick is enabled once one is.
    var chosen: Int64 = 0
    var words: String = ""
    /// What a card the edge cannot approve proposes, line by line.
    var proposes: [String] = []
    /// The card is approved with Approve behind the gate, not picked: a
    /// run or setup ask the yard has not refused.
    var approvable: Bool = false
    /// The command that answers it on the yard's machine, in place of
    /// Pick, Approve or Give: a secret ask, or an answer the yard
    /// refused. Nil on a card the phone answers on.
    var elsewhere: String? = nil
    /// The yard's sentence when it refused an approval, a pick or a
    /// giving.
    var refusal: String? = nil
    /// The card asks for a secret: it is given or answered on the yard's
    /// machine, and never picked or answered in words.
    var secret: Bool = false
    /// Only a secret card the edge cannot carry has the line that a
    /// secret never crosses the edge.
    var secretElsewhere: Bool = false
    /// The card is the ask for a harness login's one-time code, the one
    /// secret the phone gives: a field that does not echo and Give, in
    /// place of Pick, until the yard refuses the giving.
    var givesCode: Bool = false
    /// The ask's number is to be typed back before the pick: the phone
    /// has no screen lock and the chosen pick passes the gate.
    var typeBack: Bool = false
    var typed: String = ""
    /// The prompt's reason while the unlock is asked.
    var unlocking: String? = nil
    /// Decline opened its field for why.
    var declining: Bool = false
    var declineWords: String = ""
    var sending: Bool = false
    /// What became of the ask, once it is open no more.
    var done: String? = nil
    /// Why the card was not read or a call did not go.
    var error: String? = nil
}

@MainActor
@Observable
final class DecisionModel {
    private var openedYard: String? = nil
    private var openedBead: String? = nil
    private var openedAsk: Int64 = 0
    private var readAsk: BeadAsk? = nil
    private var chosen: Int64 = 0
    private var wordsText: String = ""
    private var typedText: String = ""
    private var unlocking: String? = nil
    private var declining: Bool = false
    private var declineWordsText: String = ""
    private var sending: Bool = false
    /// The context toggle is open. Per ask and kept nowhere: shut again
    /// whenever another ask opens.
    private var contextShown: Bool = false
    /// The details rows open, the descriptions read and their errors,
    /// by the bead each row is about. A read description is kept while
    /// the card is open; a failed row's error is forgotten when the row
    /// shuts, so opening it again reads anew.
    private var expandedDetails: Set<String> = []
    private var detailBodies: [String: String] = [:]
    /// Identifies the read that owns each loading row, so a stale read
    /// cannot clear a newer read for the same bead.
    private var detailReads: [String: UUID] = [:]
    private var detailErrors: [String: String] = [:]
    /// An answer was refused: the card shows the command instead.
    private var refused: Bool = false
    private var refusal: String? = nil
    private var errorText: String? = nil

    private let mailroom: Mailroom
    private let records: Records
    private let nav: Nav
    private let unlock: any UnlockPrompt
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    private var boardsObserver: UUID? = nil
    private var readTask: Task<Void, Never>? = nil
    private var lastReadKey: String? = nil
    private var active = false
    /// Invalidates work that finishes after this card leaves the screen,
    /// including when the same card is opened again.
    private var activation = 0

    init(
        mailroom: Mailroom,
        records: Records,
        nav: Nav,
        unlock: any UnlockPrompt,
        now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.mailroom = mailroom
        self.records = records
        self.nav = nav
        self.unlock = unlock
        self.now = now
        self.zone = zone
        boardsObserver = mailroom.observeBoards { [weak self] in
            self?.boardChanged()
        }
    }

    var state: DecisionState {
        guard let yard = openedYard, let bead = openedBead else { return DecisionState() }
        let board = mailroom.boards[yard]
        guard let ask = readAsk else { return DecisionState(error: errorText) }
        let weight = weightOf(board: board, bead: bead, askNumber: openedAsk, ask: ask)
        let done = board?.decided.first { $0.bead == bead && $0.ask == openedAsk }
            .flatMap { decided in
                board?.open.contains { $0.bead == bead && $0.ask == openedAsk } == false
                    ? became(decided, now: now(), zone: zone())
                    : nil
            }
        let approvable = approvable(ask)
        let givesCode = givesCode(ask)
        // An approval always passes the gate: a run wants nothing
        // picked, a setup its preset. So does the giving of a login's
        // code.
        let gated = approvable
            ? ask.run != nil || chosen > 0
            : givesCode || (chosen > 0 && needsGate(weight: weight, identity: ask.identity, options: ask.options, option: chosen))
        return DecisionState(
            read: true,
            ask: openedAsk,
            weighty: weight.map(weightLine),
            question: ask.question,
            context: ask.context,
            contextShown: contextShown,
            details: ask.about.map {
                AboutDetail(
                    id: $0.id,
                    title: $0.title,
                    stage: $0.stage,
                    expanded: expandedDetails.contains($0.id),
                    body: detailBodies[$0.id],
                    loading: detailReads[$0.id] != nil,
                    error: detailErrors[$0.id]
                )
            },
            options: ask.options.enumerated().map { index, option in
                Choice(number: Int64(index + 1), label: option.label, consequence: option.consequence, recommended: ask.recommend == Int64(index + 1))
            },
            why: ask.recommend > 0 ? ask.why : "",
            chosen: chosen,
            words: wordsText,
            proposes: proposes(ask),
            approvable: approvable,
            elsewhere: elsewhereCommand(bead: bead, ask: ask, chosen: chosen, refused: refused),
            refusal: refusal,
            secret: ask.secret != nil,
            secretElsewhere: answeredElsewhere(ask.secret),
            givesCode: givesCode,
            typeBack: gated && unlock.gate() == .typeBack,
            typed: typedText,
            unlocking: unlocking,
            declining: declining,
            declineWords: declineWordsText,
            sending: sending,
            done: done,
            error: errorText
        )
    }

    /// The card of `yard`/`bead`/`ask` is shown: its bead is read, and
    /// read again as the yard's queue moves.
    func open(yard: String, bead: String, ask: Int64) {
        let same = openedYard == yard && openedBead == bead && openedAsk == ask
        if same, active { return }
        activation += 1
        readTask?.cancel()
        if !same {
            openedYard = yard
            openedBead = bead
            openedAsk = ask
            readAsk = nil
            chosen = 0
            wordsText = ""
            typedText = ""
            unlocking = nil
            declining = false
            declineWordsText = ""
            sending = false
            contextShown = false
            expandedDetails = []
            detailBodies = [:]
            detailReads = [:]
            detailErrors = [:]
            refused = false
            refusal = nil
            errorText = nil
            lastReadKey = nil
        }
        active = true
        boardChanged()
        if readAsk == nil {
            startRead()
        }
    }

    /// The card is no longer on the screen.
    func leave() {
        activation += 1
        active = false
        readTask?.cancel()
        readTask = nil
        unlocking = nil
        // A read finishing off-screen is discarded. Shut its empty row
        // so reopening the card offers a fresh tap instead of a blank one.
        for id in detailReads.keys where detailBodies[id] == nil {
            expandedDetails.remove(id)
        }
        detailReads = [:]
    }

    /// Chooses option `number`; a prompt asked for another is forgotten.
    func choose(_ number: Int64) {
        guard unlocking == nil, !sending else { return }
        chosen = number
        errorText = nil
    }

    func words(_ text: String) {
        wordsText = text
    }

    func typed(_ text: String) {
        typedText = text
        errorText = nil
    }

    func declineWords(_ text: String) {
        declineWordsText = text
    }

    /// The context toggle tapped: the ask's context lines show where
    /// they were shut and shut where they showed. Nothing else on the
    /// card folds; the next ask opens shut.
    func toggleContext() {
        guard readAsk != nil else { return }
        contextShown.toggle()
    }

    /// A details row tapped: shut where open, and where shut opened
    /// with the bead's description, read once with the whole-bead call.
    /// A description that fails to read shows its error on the row and
    /// the card stays usable; shutting the row forgets the error, so
    /// opening it again reads anew. A read description is kept while
    /// the card is open: opening the row again reads nothing more.
    func toggleDetails(_ id: String) async {
        guard let target = screen(), let ask = readAsk else { return }
        guard ask.about.contains(where: { $0.id == id }) else { return }
        if expandedDetails.contains(id) {
            expandedDetails.remove(id)
            detailErrors.removeValue(forKey: id)
            return
        }
        expandedDetails.insert(id)
        if detailBodies[id] != nil || detailReads[id] != nil { return }
        guard let followed = mailroom.followed(target.yard) else {
            expandedDetails.remove(id)
            return
        }
        let activation = self.activation
        let read = UUID()
        detailReads[id] = read
        detailErrors.removeValue(forKey: id)
        defer {
            if detailReads[id] == read {
                detailReads.removeValue(forKey: id)
            }
        }
        do {
            let bead = try await followed.bead(id)
            guard active, self.activation == activation, screen() == target else { return }
            detailBodies[id] = bead.body
        } catch let error as ApiError {
            guard active, self.activation == activation, screen() == target else { return }
            detailErrors[id] = refusalWords(error)
        } catch {
            guard active, self.activation == activation, screen() == target else { return }
            detailErrors[id] = refusalWords(ApiError.down(why: "an unexpected error"))
        }
    }

    /// Pick: straight to the yard where the pick passes no gate; else
    /// the unlock is asked first, or the ask's number typed back is
    /// checked, and only then is the pick sent with `weighed`.
    func pick() async {
        guard let screen = screen(), let ask = readAsk else { return }
        if sending || unlocking != nil { return }
        if elsewhereCommand(bead: screen.bead, ask: ask, chosen: chosen, refused: refused) != nil { return }
        // A run or setup ask is approved, not picked, even where the
        // yard refused the approval and the card shows the command.
        if ask.run != nil || ask.setup != nil { return }
        // A secret ask is given, never picked or answered in words: the
        // yard refuses both, and the words field is no place for a code.
        // A login's code is given on the phone (`give`), every other
        // secret on the yard's machine.
        if ask.secret != nil { return }
        // An ask with no options is answered as option 0 with words:
        // an answer, not a pick, so it needs words but no weight gate.
        if ask.options.isEmpty {
            if wordsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            await send(target: screen, weighed: false)
            return
        }
        if chosen == 0 { return }
        let board = mailroom.boards[screen.yard]
        let weight = weightOf(board: board, bead: screen.bead, askNumber: screen.ask, ask: ask)
        if !needsGate(weight: weight, identity: ask.identity, options: ask.options, option: chosen) {
            await send(target: screen, weighed: false)
            return
        }
        let label = ask.options.indices.contains(Int(chosen - 1)) ? ask.options[Int(chosen - 1)].label : ""
        await passingTheGate(screen, ask: ask, reason: pickReason(option: label, yard: title(screen.yard))) {
            await send(target: screen, weighed: true)
        }
    }

    /// Approve: a run or setup ask, always behind the gate, with
    /// `weighed`. A setup wants its preset picked first. Where the
    /// phone has no screen lock the ask's number typed back stands for
    /// the unlock, as a pick's.
    func approve() async {
        guard let screen = screen(), let ask = readAsk else { return }
        if sending || unlocking != nil || !approvable(ask) { return }
        if ask.setup != nil, chosen == 0 { return }
        await passingTheGate(screen, ask: ask, reason: approveReason(what: approvalOf(ask), yard: title(screen.yard))) {
            await sendApproval(target: screen, ask: ask)
        }
    }

    /// Give: the one-time code a harness's sign-in page gave, as the
    /// person typed it, to the login that waits for it. Only on the
    /// card that asks for it (`givesLoginCode`): any other secret is
    /// answered on the yard's machine, so no path leads here from a key
    /// ask. Always behind the gate, with `weighed`; where the phone has
    /// no screen lock the ask's number typed back stands for the unlock.
    /// The code is held nowhere but in the call: the field is the view's.
    func give(code: String) async {
        guard let screen = screen(), let ask = readAsk else { return }
        if sending || unlocking != nil || !givesCode(ask) { return }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.isEmpty { return }
        await passingTheGate(screen, ask: ask, reason: giveReason(yard: title(screen.yard))) {
            await sendCode(target: screen, code: code)
        }
    }

    /// Later: the ask is put aside.
    func later() async {
        guard let screen = screen(), !sending, unlocking == nil else { return }
        await call(target: screen, failed: "Not put aside") { followed in
            try await followed.later(bead: screen.bead, ask: screen.ask)
        }
    }

    /// Decline: the first press opens the field for why, the next sends.
    /// A secret ask takes no words in a decline (the yard refuses any, as
    /// they may be the secret), so its first press sends with none, and no
    /// field opens.
    func decline() async {
        guard let screen = screen(), !sending, unlocking == nil else { return }
        let why: String
        if readAsk?.secret != nil {
            why = ""
        } else {
            if !declining {
                declining = true
                return
            }
            why = declineWordsText.trimmingCharacters(in: .whitespacesAndNewlines)
            if why.isEmpty { return }
        }
        await call(target: screen, failed: "Not declined") { followed in
            try await followed.decline(bead: screen.bead, ask: screen.ask, words: why)
        }
    }

    private struct ScreenRef: Equatable {
        var yard: String
        var bead: String
        var ask: Int64
    }

    private func screen() -> ScreenRef? {
        guard let yard = openedYard, let bead = openedBead else { return nil }
        return ScreenRef(yard: yard, bead: bead, ask: openedAsk)
    }

    /// Passes the gate in front of a weighty call, and only then goes on:
    /// the system's prompt with `reason`, or the ask's number typed back
    /// where the phone has no screen lock. A prompt that is cancelled, a
    /// card that left the screen and a number not typed back send
    /// nothing, and a card that changed while the prompt was open is to
    /// be reviewed again first.
    private func passingTheGate(_ screen: ScreenRef, ask: BeadAsk, reason: String, then proceed: () async -> Void) async {
        let activation = self.activation
        let readKey = lastReadKey
        switch unlock.gate() {
        case .prompt:
            unlocking = reason
            let passed = await unlock.prompt(reason: reason)
            guard self.activation == activation else { return }
            unlocking = nil
            guard passed, active, self.screen() == screen else { return }
            guard lastReadKey == readKey, readAsk == ask else {
                errorText = "The card changed while the unlock was open. Review it before answering."
                return
            }
            await proceed()
        case .typeBack:
            guard typedBack(typedText, screen.ask) else {
                errorText = "ask \(screen.ask)'s number was not typed back, so nothing was done"
                return
            }
            typedText = ""
            await proceed()
        }
    }

    private func send(target: ScreenRef, weighed: Bool) async {
        let option = chosen
        let words = wordsText.trimmingCharacters(in: .whitespacesAndNewlines)
        await answerCall(target: target, failed: "Not answered") { followed in
            try await followed.answer(bead: target.bead, ask: target.ask, option: option, words: words, weighed: weighed)
        }
    }

    private func sendApproval(target: ScreenRef, ask: BeadAsk) async {
        if ask.run != nil {
            await answerCall(target: target, failed: "Not approved", isApproval: true) { followed in
                try await followed.approve(bead: target.bead, ask: target.ask, weighed: true)
            }
        } else {
            let option = chosen
            await answerCall(target: target, failed: "Not approved", isApproval: true) { followed in
                try await followed.approveSetup(bead: target.bead, ask: target.ask, option: option, weighed: true)
            }
        }
    }

    /// Gives the code under the one name the ask asks for. A call that
    /// ends with no word from the yard may have been taken, so a failure
    /// says it was not confirmed, never that it was not given.
    private func sendCode(target: ScreenRef, code: String) async {
        await answerCall(target: target, failed: "Not confirmed", isApproval: true) { followed in
            try await followed.give(bead: target.bead, ask: target.ask, values: [loginInputName: code], weighed: true)
        }
    }

    /// Makes an answering call; what went leaves the card. What the yard
    /// refused shows the yard's sentence with the command that answers
    /// it instead, and is not made again; any other failure says why
    /// and keeps what was chosen.
    private func answerCall(target: ScreenRef, failed: String, isApproval: Bool = false, _ body: @escaping @MainActor (any Followed) async throws -> Void) async {
        guard let followed = mailroom.followed(target.yard) else { return }
        let activation = self.activation
        sending = true
        errorText = nil
        if isApproval { refusal = nil }
        defer { sending = false }
        do {
            try await body(followed)
            guard active, self.activation == activation, screen() == target else { return }
            nav.closeDecision(yard: target.yard, bead: target.bead, ask: target.ask)
        } catch let error as ApiError {
            guard active, self.activation == activation, screen() == target else { return }
            if case .refused = error,
               let ask = readAsk,
               elsewhereCommand(bead: target.bead, ask: ask, chosen: chosen, refused: true) != nil {
                refused = true
                refusal = refusalWords(error)
                errorText = nil
            } else {
                refused = false
                refusal = nil
                errorText = "\(failed): \(refusalWords(error))"
            }
        } catch {
            guard active, self.activation == activation, screen() == target else { return }
            errorText = "\(failed): \(refusalWords(ApiError.down(why: "an unexpected error")))"
        }
    }

    /// Makes a call of the card; what went leaves the card for the
    /// list, what did not says why on it.
    private func call(target: ScreenRef, failed: String, _ body: @escaping @MainActor (any Followed) async throws -> Void) async {
        guard let followed = mailroom.followed(target.yard) else { return }
        let activation = self.activation
        sending = true
        errorText = nil
        defer { sending = false }
        do {
            try await body(followed)
            guard active, self.activation == activation, screen() == target else { return }
            nav.closeDecision(yard: target.yard, bead: target.bead, ask: target.ask)
        } catch let error as ApiError {
            guard active, self.activation == activation, screen() == target else { return }
            errorText = "\(failed): \(refusalWords(error))"
        } catch {
            guard active, self.activation == activation, screen() == target else { return }
            errorText = "\(failed): \(refusalWords(ApiError.down(why: "an unexpected error")))"
        }
    }

    private func boardChanged() {
        guard active, let screen = screen() else { return }
        let board = mailroom.boards[screen.yard]
        let key = [
            board.map { String($0.head) } ?? "-",
            board?.beadEvents[screen.bead].map(String.init) ?? "-",
            board?.open.contains { $0.bead == screen.bead && $0.ask == screen.ask } == true ? "open" : "no",
            board?.decided.contains { $0.bead == screen.bead && $0.ask == screen.ask } == true ? "decided" : "no",
        ].joined(separator: "|")
        if key != lastReadKey {
            lastReadKey = key
            if readAsk != nil {
                startRead()
            }
        }
    }

    private func startRead() {
        guard let screen = screen() else { return }
        let activation = self.activation
        readTask?.cancel()
        readTask = Task { @MainActor in
            await readBead(target: screen, activation: activation)
        }
    }

    private func readBead(target: ScreenRef, activation: Int) async {
        guard let followed = mailroom.followed(target.yard) else { return }
        do {
            let bead = try await followed.bead(target.bead)
            guard active, self.activation == activation, screen() == target else { return }
            if let found = bead.asks.first(where: { $0.ask == target.ask }) {
                readAsk = found
                if errorText?.hasPrefix("The yard has no ask") == true { errorText = nil }
            } else {
                errorText = "The yard has no ask \(target.ask) on \(target.bead)."
            }
        } catch let error as ApiError {
            guard active, self.activation == activation, screen() == target else { return }
            errorText = refusalWords(error)
        } catch {
            guard active, self.activation == activation, screen() == target else { return }
            errorText = refusalWords(ApiError.down(why: "an unexpected error"))
        }
    }

    private func approvable(_ ask: BeadAsk) -> Bool {
        (ask.run != nil || ask.setup != nil) && !refused
    }

    /// The card takes the code of a harness login's sign-in page: it is
    /// that ask, and the yard has not refused a giving of it.
    private func givesCode(_ ask: BeadAsk) -> Bool {
        givesLoginCode(ask.secret) && !refused
    }

    /// What the prompt names for the approval: the run's command whole,
    /// or the setup's pack.
    private func approvalOf(_ ask: BeadAsk) -> String {
        if let run = ask.run {
            return run.command.isEmpty ? run.argv.joined(separator: " ") : run.command
        }
        if let setup = ask.setup {
            return "setup of \(setup.label.isEmpty ? setup.pack : setup.label)"
        }
        return ""
    }

    private func title(_ yard: String) -> String {
        records.kept.yards.first { $0.name == yard }?.title ?? yard
    }
}

/// The card's weight: the queue's, which is read again with it, else
/// the bead's own.
private func weightOf(board: Board?, bead: String, askNumber: Int64, ask: BeadAsk) -> [AskWeight] {
    board?.open.first { $0.bead == bead && $0.ask == askNumber }?.weight
        ?? board?.decided.first { $0.bead == bead && $0.ask == askNumber }?.weight
        ?? ask.weight
}

/// What a card the edge cannot approve proposes, as its lines: the
/// command whole and what it does, the setup's pack and what it does,
/// or what a secret is asked for.
func proposes(_ ask: BeadAsk) -> [String] {
    if let run = ask.run {
        var lines: [String] = []
        let command = run.command.isEmpty ? run.argv.joined(separator: " ") : run.command
        if !command.isEmpty { lines.append(command) }
        if !run.description.isEmpty { lines.append(run.description) }
        lines += run.does
        if !run.back.isEmpty { lines.append("back: \(run.back)") }
        return lines
    }
    if let setup = ask.setup {
        var lines: [String] = []
        let label = setup.label.isEmpty ? setup.pack : setup.label
        if !label.isEmpty { lines.append("setup of \(label)") }
        lines += setup.does
        if !setup.back.isEmpty { lines.append("back: \(setup.back)") }
        return lines
    }
    if let secret = ask.secret {
        var lines: [String] = []
        if !secret.line.isEmpty { lines.append(secret.line) }
        if !secret.env.isEmpty { lines.append(secret.env.joined(separator: ", ")) }
        return lines
    }
    return []
}
