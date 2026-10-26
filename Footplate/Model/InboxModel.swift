import Foundation

// The crew place's model (design 3.5, after Android's
// model/InboxModel.kt): the head line with the selected yard's
// follow, the selected yard's rows from its `Board`, and the yard
// switch's rows, each with its waiting count or its follow's word,
// with Pair another yard and Forget this yard. The selection is the
// records', so the app opens on it.

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
    /// `2 waiting` where the yard has open asks and its follow is up.
    var waiting: String? = nil
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
    /// The selected yard's open asks, for a later place's count.
    var waiting: Int = 0
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
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone

    init(
        pairer: Pairer,
        records: Records,
        followers: @escaping @MainActor () -> [String: any Followed],
        mailroom: Mailroom,
        nav: Nav,
        now: @escaping @Sendable () -> Date = { Date() },
        zone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.pairer = pairer
        self.records = records
        self.followers = followers
        self.mailroom = mailroom
        self.nav = nav
        self.now = now
        self.zone = zone
    }

    var state: InboxState {
        inbox(kept: records.kept)
    }

    func select(_ name: String) {
        records.select(name)
    }

    /// Opens the row `name` of the selected yard: its conversation,
    /// or the yard's notices.
    func open(_ name: String) {
        guard let yard = records.kept.selected else { return }
        nav.show(.conversation(yard: yard, with: name))
    }

    func pairAnother() {
        nav.show(.pair)
    }

    /// A place starts a new back stack; back from it leaves the app.
    func place(_ screen: Screen) {
        guard screen.isPlace else { return }
        nav.reset(screen)
    }

    /// What the head line's word does: sign in again with the
    /// password alone, or pair the yard again.
    func act() {
        switch state.action {
        case .signInAgain: nav.show(.signIn(again: true))
        case .pairAgain: nav.show(.pair)
        case nil: break
        }
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
        do {
            try await pairer.forget(name: name)
        } catch let error as ApiError {
            forgetError = "The edge did not end the session: \(words(error))"
        } catch {
            forgetError = "The edge did not end the session: \(error)"
        }
        if records.kept.yards.isEmpty {
            nav.reset(.pair)
        }
    }

    private func inbox(kept: Kept) -> InboxState {
        let selected = kept.selectedYard
        let signedOut = kept.account == nil
        let follows = followers()
        let boards = mailroom.boards
        func followWord(_ yard: PairedYard) -> (String?, HeadAction?) {
            // Every yard here is an edge yard: all of them share the
            // one session, so a signed-out phone asks to sign in on
            // each (Android's own-yard exception has no iOS yard).
            if signedOut { return ("sign in again", .signInAgain) }
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
                    waiting: said == nil && open > 0 ? "\(open) waiting" : nil
                )
            },
            rows: board?.rows { at in stamp(at, now: now, zone: zone) } ?? [],
            nothing: selected != nil && board == nil
                ? "Nothing from \(selected!.title) yet" + (word.map { ": \($0)" } ?? "")
                : nil,
            error: forgetError,
            waiting: board?.open.count ?? 0
        )
    }
}
