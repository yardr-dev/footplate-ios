import Foundation

// The app's navigation state (design 3.5): the selected place for the
// TabView, one stack of pushed screens per place that pushes any, and
// the Pair and Sign in covers. The views read it through TabView
// selection and NavigationStack paths, so the tab bar, the titles,
// the back button and the swipe back are the system's own.

/// The three places of the tab bar.
enum Place: Hashable, Sendable {
    case crew
    case decide
    case lines
}

/// A conversation pushed onto the crew stack: with `with` of the yard
/// named `yard`, its notices where `with` is `yardRow`.
struct ConversationRoute: Hashable, Sendable {
    var yard: String
    var with: String
}

/// A decision pushed onto the decide stack: the ask `ask` on `bead`
/// of the yard named `yard`.
struct DecisionRoute: Hashable, Sendable {
    var yard: String
    var bead: String
    var ask: Int64
}

/// A Sign in cover, over the Pair screen or the tabs; `again` when the
/// session ran out or was revoked, and only the password is asked.
struct SignInRequest: Hashable, Sendable {
    var again: Bool
}

/// Which place is shown and what is pushed or covered over it.
@MainActor
@Observable
final class Nav {
    /// The selected tab.
    var place: Place
    /// The conversations pushed onto the crew stack.
    var crewPath: [ConversationRoute]
    /// The decisions pushed onto the decide stack.
    var decidePath: [DecisionRoute]
    /// Pair another yard, over the tabs. The Pair root, shown while no
    /// yard is paired, is the records', not this.
    var pairing: Bool
    /// Sign in, over the Pair screen or the tabs.
    var signIn: SignInRequest?

    init(place: Place = .crew) {
        self.place = place
        self.crewPath = []
        self.decidePath = []
        self.pairing = false
        self.signIn = nil
    }

    /// Pushes the conversation, unless it is the one pushed already.
    func openConversation(yard: String, with: String) {
        let route = ConversationRoute(yard: yard, with: with)
        guard crewPath.last != route else { return }
        crewPath.append(route)
    }

    /// Pushes the decision, unless it is the one pushed already.
    func openDecision(yard: String, bead: String, ask: Int64) {
        let route = DecisionRoute(yard: yard, bead: bead, ask: ask)
        guard decidePath.last != route else { return }
        decidePath.append(route)
    }

    /// Pops the decision where it is the one pushed: an answered card
    /// leaves for the list.
    func closeDecision(yard: String, bead: String, ask: Int64) {
        if decidePath.last == DecisionRoute(yard: yard, bead: bead, ask: ask) {
            decidePath.removeLast()
        }
    }

    /// Pair another yard, over the tabs.
    func showPair() {
        pairing = true
    }

    /// Sign in, over the Pair screen or the tabs.
    func showSignIn(again: Bool) {
        signIn = SignInRequest(again: again)
    }

    /// The sign-in finished: its cover shuts.
    func didSignIn() {
        signIn = nil
    }

    /// The pairing finished: the Pair cover shuts and the crew opens.
    func didPair() {
        pairing = false
        place = .crew
    }

    /// Removes pushed screens for a yard that is no longer paired.
    func didForgetYard(_ name: String) {
        if crewPath.contains(where: { $0.yard == name }) {
            crewPath = []
        }
        if decidePath.contains(where: { $0.yard == name }) {
            decidePath = []
        }
    }

    /// Every yard forgotten: the stacks are cleared for the Pair root.
    func didForgetAll() {
        pairing = false
        signIn = nil
        place = .crew
        crewPath = []
        decidePath = []
    }
}
