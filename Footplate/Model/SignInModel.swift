import Foundation

// The Sign in screen's model (design 3.2): the email and the
// password to the build's edge alone, through Kratos's API flow, and
// the session kept. The password is held only until it is sent.

struct SignInState: Equatable, Sendable {
    var email: String = ""
    var password: String = ""
    /// Signing in again: the email is the account's, and only the
    /// password is asked.
    var again: Bool = false
    var busy: Bool = false
    /// Kratos's messages, or why nothing answered.
    var error: String? = nil
}

@MainActor
@Observable
final class SignInModel {
    private(set) var state = SignInState()

    private let pairer: Pairer
    private let records: Records
    private let nav: Nav

    /// The screen this model was opened for, left once signed in.
    private var shown: Screen = .signIn(again: false)

    init(pairer: Pairer, records: Records, nav: Nav) {
        self.pairer = pairer
        self.records = records
        self.nav = nav
    }

    /// The edge's host, which the screen names: never an address
    /// from a code.
    var host: String {
        pairer.origin.split(separator: "://", maxSplits: 1).last.map(String.init) ?? pairer.origin
    }

    /// The edge's recovery page, opened in the browser (3.2).
    var recovery: String { "\(pairer.origin)/account/recovery" }

    /// The screen is shown: for a first sign-in, or `again` with the
    /// account's email filled.
    func opened(again: Bool) {
        shown = .signIn(again: again)
        let account = records.accountNameForSignIn ?? ""
        if again, !account.isEmpty {
            state = SignInState(email: account, again: true)
        } else {
            state = SignInState(email: state.email)
        }
    }

    func email(_ email: String) {
        if state.again { return }
        state.email = email
    }

    func password(_ password: String) {
        state.password = password
    }

    func signIn() async {
        let typed = state
        let leaving = shown
        guard !typed.busy, !typed.email.trimmingCharacters(in: .whitespaces).isEmpty, !typed.password.isEmpty else { return }
        // The password leaves the field as it is sent, whatever answers.
        state.password = ""
        state.busy = true
        state.error = nil
        do {
            try await pairer.signIn(email: typed.email.trimmingCharacters(in: .whitespacesAndNewlines), password: typed.password)
        } catch let error as ApiError {
            state.busy = false
            state.error = words(error)
            return
        } catch {
            state.busy = false
            state.error = words(ApiError.down(why: "an unexpected error"))
            return
        }
        state.busy = false
        nav.leave(leaving)
    }
}
