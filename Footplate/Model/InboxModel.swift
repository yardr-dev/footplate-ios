import Foundation

// The crew place's model (design 3.5, after Android's
// model/InboxModel.kt): the head line with the selected yard's
// follow, the selected yard's rows from its `Board`, and the yard
// switch's rows, each with its waiting count or its follow's word,
// with Pair another yard, Rename this yard and Forget this yard. The
// selection is the records', so the app opens on it.

/// What tapping the head line's word does, where it does anything.
enum HeadAction: Equatable, Sendable {
    case signInAgain, pairAgain
}

/// One row of the yard switch.
struct YardRow: Equatable, Sendable {
    var name: String
    var title: String
    var user: String
    var device: String
    var selected: Bool
    /// The follow's word where it is not up, else nil.
    var word: String?
    /// `2 to decide` where the yard has open asks and its follow is up.
    var waiting: String? = nil
    /// `not yet sealed` where the yard holds this device's channel
    /// key: no sealed claim stands until the bound library's
    /// review passes (Channel.swift), and this says no more.
    var channelNote: String? = nil
    /// An in-place migration has completed, so the person can choose
    /// to pair again by QR and replace the migration's trust-on-first-use.
    var canPairAgainByQR: Bool = false
}

struct InboxState: Equatable, Sendable {
    /// The selected yard and the user: `laptop · mckean`.
    var head: String = ""
    /// The selected yard's follow, where it is not up.
    var word: String? = nil
    var action: HeadAction? = nil
    var yards: [YardRow] = []
    /// The selected yard's rows, newest letter first.
    var rows: [Row] = []
    /// In place of the rows, for a yard not read yet since the app
    /// came to the front: `Nothing from laptop yet: yard away`.
    var nothing: String? = nil
    /// Why the last forgetting said something, under the switch.
    var error: String? = nil
    /// The one sentence of a yard that left on its own: its owner
    /// removed the account's access.
    var notice: String? = nil
    /// The selected yard's open asks, for a later place's count.
    var waiting: Int = 0
    /// The yard is the demo's: the switch offers the way out in place of
    /// pairing another yard or forgetting this one.
    var demo: Bool = false
}

@MainActor
@Observable
final class InboxModel {
    private(set) var forgetError: String? = nil

    private let pairer: Pairer
    private let records: Records
    /// The followed yards by name at the edge; set by the app once
    /// its services stand, since the followers are rebuilt with them.
    var followers: @MainActor () -> [String: any Followed]
    private let mailroom: Mailroom
    private let nav: Nav
    /// The way out of a demo yard, which pairs nothing: set by the demo
    /// alone, and then the model is the demo's.
    private let leave: (@MainActor () -> Void)?
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone

    init(
        pairer: Pairer,
        records: Records,
        followers: @escaping @MainActor () -> [String: any Followed],
        mailroom: Mailroom,
        nav: Nav,
        leave: (@MainActor () -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.pairer = pairer
        self.records = records
        self.followers = followers
        self.mailroom = mailroom
        self.nav = nav
        self.leave = leave
        self.now = now
        self.zone = zone
    }

    var state: InboxState {
        inbox(kept: records.kept)
    }

    func select(_ name: String) {
        nav.notice = nil
        records.select(name)
    }

    /// The sentence of a yard that left is put away.
    func dismissNotice() {
        nav.notice = nil
    }

    /// Opens the row `name` of the selected yard: its conversation,
    /// or the yard's notices, pushed onto the crew stack.
    func open(_ name: String) {
        guard let yard = records.kept.selected else { return }
        nav.openConversation(yard: yard, with: name)
    }

    /// Pair another yard; in a demo, the way out of it to the Pair screen.
    func pairAnother() {
        if let leave {
            leave()
        } else {
            nav.showPair()
        }
    }

    /// What the follow word does: sign in again with the password
    /// alone, or pair the yard again.
    func act() {
        switch state.action {
        case .signInAgain: nav.showSignIn(again: true)
        case .pairAgain: nav.showPair()
        case nil: break
        }
    }

    /// What Rename this yard starts from: the name the person gave the
    /// selected yard (empty where they gave none), and the name clearing
    /// it brings back.
    func renaming() -> (given: String, original: String)? {
        guard let yard = records.kept.selectedYard else { return nil }
        return (yard.localName ?? "", yard.defaultName)
    }

    /// Names the selected yard as the person typed; empty brings its old
    /// name back. The name stays on this phone.
    func rename(_ name: String) {
        guard let selected = records.kept.selected else { return }
        records.renameYard(selected, to: name)
    }

    /// The sentence Forget this yard says first: the device stays at
    /// the yard until its operator removes it.
    func forgetting() -> String? {
        guard let yard = records.kept.selectedYard else { return nil }
        return "footplate forgets \(yard.title). The device stays at the yard until its operator runs yardr user device rm \(yard.user) \(yard.device)"
    }

    /// Forgets the selected yard; the last one forgotten ends the
    /// session too, and the Pair screen is shown.
    func forget() async {
        guard let name = records.kept.selected else { return }
        forgetError = nil
        nav.notice = nil
        do {
            try await pairer.forget(name: name)
        } catch let error as ApiError {
            forgetError = "The edge did not end the session: \(words(error))"
        } catch {
            forgetError = "The edge did not end the session: \(error)"
        }
        left(name)
    }

    /// A yard of another account whose owner removed the account's
    /// access, which its follower found: forgotten as Forget this yard
    /// forgets one, rather than left standing as a yard that always
    /// fails, and `words` is the one sentence that says why. Where it
    /// was the last yard, the session ends with it and the Pair screen
    /// says the sentence. A logout the edge does not answer changes
    /// nothing: every record is gone either way.
    func removed(_ name: String, _ words: String) async {
        guard records.kept.yards.contains(where: { $0.name == name }) else { return }
        nav.notice = words
        try? await pairer.forget(name: name)
        left(name)
    }

    /// The screens of a yard no longer paired are put away, and the
    /// Pair screen is the root where none is left.
    private func left(_ name: String) {
        if !records.kept.yards.contains(where: { $0.name == name }) {
            nav.didForgetYard(name)
        }
        if records.kept.yards.isEmpty {
            nav.didForgetAll()
        }
    }

    private func inbox(kept: Kept) -> InboxState {
        let selected = kept.selectedYard
        let signedOut = kept.account == nil
        let follows = followers()
        let boards = mailroom.boards
        func followWord(_ yard: PairedYard) -> (String?, HeadAction?) {
            // Only an edge yard is signed out: a yard of its own has
            // no session to run out of.
            if signedOut && yard.origin.isEmpty { return ("sign in again", .signInAgain) }
            switch follows[yard.name]?.state.status {
            case .down(_, let short): return (short, nil)
            case .pairAgain: return ("pair again", .pairAgain)
            case .signInAgain: return ("sign in again", .signInAgain)
            default: return (nil, nil)
            }
        }
        let (word, action) = selected.map { followWord($0) } ?? (nil, nil)
        let board = selected.flatMap { boards[$0.name] }
        let now = now()
        let zone = zone()
        return InboxState(
            head: selected.map { "\($0.title) · \($0.user)" } ?? "",
            word: word,
            action: action,
            yards: kept.yards.map { yard in
                let said = followWord(yard).0
                let open = boards[yard.name]?.open.count ?? 0
                return YardRow(
                    name: yard.name, title: yard.title, user: yard.user, device: yard.device,
                    selected: yard.name == kept.selected,
                    word: said,
                    waiting: said == nil && open > 0 ? "\(open) to decide" : nil,
                    channelNote: yard.channelNote,
                    canPairAgainByQR: yard.sealedHow == "in place" && yard.yardChannelPublic != nil
                )
            },
            rows: board?.rows { at in stamp(at, now: now, zone: zone) } ?? [],
            nothing: selected != nil && board == nil
                ? "Nothing from \(selected!.title) yet" + (word.map { ": \($0)" } ?? "")
                : nil,
            error: forgetError,
            notice: nav.notice,
            waiting: board?.open.count ?? 0,
            demo: leave != nil
        )
    }
}
