import Foundation

// The Pair screen's model (design 3.2): a code read from a scan or
// typed, then paired with under the session kept. Where no session
// is kept, or the edge refuses it, the Sign in screen is shown, and
// the pairing goes on by itself once a session is kept.

/// Where the Pair screen is.
enum PairStep: Equatable, Sendable {
    /// **Scan**, and **Type the code**.
    case choose
    /// **Type the code**: the yard's name at the edge and the code,
    /// and no address: the edge is the build's, shown as a line of text.
    case typing(yard: String, code: String)
    /// What a scan or the typed fields read, and **Pair**.
    case read(PairingCode)
}

struct PairState: Equatable, Sendable {
    var step: PairStep = .choose
    /// The pairing is under way.
    var busy: Bool = false
    /// Why the last step failed, under the button.
    var error: String? = nil
}

@MainActor
@Observable
final class PairModel {
    private(set) var state = PairState()

    private let pairer: Pairer
    private let records: Records
    private let nav: Nav

    /// The code waiting for a sign-in, and the session it waits to
    /// be replaced.
    private var waiting: (code: PairingCode, before: String?)?
    private var recordsObserver: UUID?

    /// The edge the app speaks to: the line **Type the code** shows.
    var edge: String { pairer.origin }

    init(pairer: Pairer, records: Records, nav: Nav) {
        self.pairer = pairer
        self.records = records
        self.nav = nav
        recordsObserver = records.observe { [weak self] kept in
            guard let self, let (code, before) = self.waiting else { return }
            guard let session = kept.account?.session, session != before else { return }
            self.waiting = nil
            Task { @MainActor in await self.run(code) }
        }
    }

    /// What the code scanner read. Nothing is sent: the address is
    /// checked against the edge and never used.
    func scanned(_ text: String) {
        read(readQr(text, edge: pairer.origin))
    }

    /// The scanner did not read a code: `why` in its words, or
    /// nothing where the person closed it.
    func scanFailed(_ why: String?) {
        state.error = why
    }

    func typeCode() {
        waiting = nil
        state = PairState(step: .typing(yard: "", code: ""))
    }

    func typed(yard: String, code: String) {
        state.step = .typing(yard: yard, code: code)
        state.error = nil
    }

    /// Reads the typed fields as a code.
    func readTyped() {
        guard case .typing(let yard, let code) = state.step else { return }
        read(typedCode(yard: yard, code: code))
    }

    /// Back to **Scan** and **Type the code**; false where it is there.
    @discardableResult
    func back() -> Bool {
        if state.step == .choose || state.busy { return false }
        waiting = nil
        state = PairState()
        return true
    }

    /// The Pair cover shut without pairing: nothing waits any more,
    /// and a later sign-in from the tabs pairs nothing.
    func close() {
        waiting = nil
        if !state.busy { state = PairState() }
    }

    /// Pairs with the code read: at once under the session kept, or
    /// after the Sign in screen where there is none.
    func pair() async {
        guard case .read(let code) = state.step, !state.busy else { return }
        if records.kept.account == nil {
            signInFirst(code: code, session: nil, again: false)
            return
        }
        await run(code)
    }

    private func run(_ code: PairingCode) async {
        state.busy = true
        state.error = nil
        let session = records.kept.account?.session
        do {
            _ = try await pairer.pair(code: code)
        } catch ApiError.notSignedIn {
            state.busy = false
            signInFirst(code: code, session: session, again: session != nil)
            return
        } catch let error as ApiError {
            state.busy = false
            state.error = words(error)
            return
        } catch {
            state.busy = false
            state.error = words(ApiError.down(why: "an unexpected error"))
            return
        }
        state = PairState()
        nav.didPair()
    }

    private func signInFirst(code: PairingCode, session: String?, again: Bool) {
        waiting = (code, session)
        nav.showSignIn(again: again)
    }

    private func read(_ read: CodeRead) {
        waiting = nil
        switch read {
        case .code(let code):
            state = PairState(step: .read(code))
        case .refused(let why):
            state.error = why
        }
    }
}
