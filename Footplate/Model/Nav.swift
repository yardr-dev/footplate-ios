import Foundation

// Which screen is shown, held as state and drawn by a `switch`:
// no navigation library (design 3.5). The system back goes one step
// back, through the screens shown since the last `reset`.

/// The screens that exist so far.
enum Screen: Equatable, Sendable {
    /// Pair with a yard: the first screen, and **Pair another yard**.
    case pair
    /// Sign in at the edge; `again` when the session ran out or was
    /// revoked, and only the password is asked.
    case signIn(again: Bool)
    /// The selected yard's crew place: the inbox rows and the yard
    /// switch.
    case crew
    /// One conversation of the yard named `yard`, with `with`; the
    /// yard's notices where `with` is `yardRow`. Full screen over
    /// the crew place.
    case conversation(yard: String, with: String)

    /// The places that have the yard header in the full design.
    var isPlace: Bool { self == .crew }
}

/// Which screen is shown. Made with the screen the app opens on.
@MainActor
@Observable
final class Nav {
    private(set) var screen: Screen
    private var shown: [Screen]
    private var observers: [UUID: @MainActor (Screen) -> Void] = [:]

    init(first: Screen) {
        self.screen = first
        self.shown = [first]
    }

    /// Whether `back` has a screen to go back to.
    var canBack: Bool { shown.count > 1 }

    func observe(_ observer: @escaping @MainActor (Screen) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func publish() {
        for observer in observers.values { observer(screen) }
    }

    /// Shows `screen` over the one shown, unless it is shown already.
    func show(_ screen: Screen) {
        guard shown.last != screen else { return }
        shown.append(screen)
        self.screen = screen
        publish()
    }

    /// Shows `screen` with nothing to go back to.
    func reset(_ screen: Screen) {
        shown = [screen]
        self.screen = screen
        publish()
    }

    /// Goes one step back; false where there is no step to go back
    /// to, and the system's back then leaves the app.
    @discardableResult
    func back() -> Bool {
        guard shown.count >= 2 else { return false }
        shown.removeLast()
        screen = shown[shown.count - 1]
        publish()
        return true
    }

    /// Leaves `screen` where it is the one shown.
    func leave(_ screen: Screen) {
        if shown.last == screen { back() }
    }
}
