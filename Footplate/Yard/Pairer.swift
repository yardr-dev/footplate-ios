import Foundation

// Signing in, pairing and forgetting, as design 3.2 has them: the
// steps between the edge's calls and the records, for the models to
// call. Every request goes to `edge`, the app's one origin.
@MainActor
final class Pairer {
    private let edge: Edge
    private let records: Records

    init(edge: Edge, records: Records) {
        self.edge = edge
        self.records = records
    }

    /// The edge's origin, as a sentence names it.
    var origin: String { edge.origin }

    /// Signs in at the edge and keeps the session, in place of any
    /// before. The password is sent and kept nowhere.
    func signIn(email: String, password: String) async throws {
        let signedIn = try await edge.signIn(email: email, password: password)
        records.keepSession(account: signedIn.account, session: signedIn.session)
    }

    /// Pairs with `code` under the session kept: the code to
    /// `/user/pair` with `X-Edge-Yard` where the code names a yard, the
    /// device token kept at once (the pairing's answer is the one time
    /// it is anywhere), then `/user/me` for who the device is. Throws
    /// `ApiError.notSignedIn` where no session is kept, or where the
    /// edge refuses the one kept.
    @discardableResult
    func pair(code: PairingCode) async throws -> PairedYard {
        guard let account = records.kept.account else { throw ApiError.notSignedIn }
        let paired = try await edge.pair(code: code.code, session: account.session, yard: code.yard)
        let kept = PairedYard(name: code.yard, yard: paired.yard, user: paired.user, device: paired.device, token: paired.token)
        records.keepYard(kept)
        // The pairing stands whatever /user/me answers: the follower
        // asks it again, and says what is wrong where something is.
        let me: Me
        do {
            me = try await edge.yard(device: paired.token, session: account.session, name: code.yard).me()
        } catch is ApiError {
            return kept
        }
        let yard = PairedYard(
            name: code.yard,
            yard: me.yard.isEmpty ? paired.yard : me.yard,
            user: me.user,
            device: me.saidBy.isEmpty ? paired.device : me.saidBy,
            token: paired.token
        )
        records.keepYard(yard)
        return yard
    }

    /// Deletes the record of the yard named `name`. The last yard
    /// forgotten also ends the session at Kratos and deletes the
    /// account's record, so the phone holds no credential at all:
    /// every record goes even where the logout is not answered, and
    /// the error is thrown after.
    func forget(name: String) async throws {
        let kept = records.kept
        if kept.yards.contains(where: { $0.name != name }) {
            records.forgetYard(name)
            return
        }
        var thrown: Error?
        if let account = kept.account {
            do {
                try await edge.logout(session: account.session)
            } catch ApiError.notSignedIn {
                // Ended already.
            } catch {
                thrown = error
            }
        }
        records.forgetAll()
        if let thrown { throw thrown }
    }
}
