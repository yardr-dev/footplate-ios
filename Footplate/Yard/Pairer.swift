import Foundation

// Signing in, pairing and forgetting, as design 3.2 has them: the
// steps between the yard's calls and the records, for the models to
// call. Every request goes to `edge`, the app's one origin, but a code
// with an address of its own, which goes to that address with no edge.
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
        records.keepSession(account: signedIn.account, handle: signedIn.handle, session: signedIn.session)
    }

    /// The handle the edge names the account's own yard by. Older kept
    /// sessions predate the plain-shelf handle, so read it from Kratos
    /// once when a web view link needs it.
    func accountHandleForWebView() async throws -> String {
        guard let account = records.kept.account else { throw ApiError.notSignedIn }
        if !account.handle.isEmpty { return account.handle }
        let handle = try await edge.accountHandle(session: account.session)
        records.keepAccountHandle(handle, for: account.session)
        guard let current = records.kept.account, current.session == account.session,
              !current.handle.isEmpty
        else { throw ApiError.notSignedIn }
        return current.handle
    }

    /// Pairs with `code` under the session kept: the code to
    /// `/user/pair` with `X-Edge-Yard` where the code names a yard, the
    /// device token kept at once (the pairing's answer is the one time
    /// it is anywhere), then `/user/me` for who the device is. Throws
    /// `ApiError.notSignedIn` where no session is kept, or where the
    /// edge refuses the one kept. A code with an address of its own
    /// pairs with no session: the code to `<address>/user/pair`, and
    /// every later call to `<address>` with the device token alone.
    @discardableResult
    func pair(code: PairingCode) async throws -> PairedYard {
        // One name holds one yard: the head line, the followers and the
        // boards all read by name, so a second yard under a kept name
        // would show one yard's rows and send what is typed to the
        // other. Refused before anything is sent, so the code is not
        // burned. The same yard again, the same name at the same
        // origin, pairs as before.
        let name = code.address.isEmpty ? code.yard : ""
        let origin = code.address
        if let clash = records.kept.yards.first(where: { $0.name == name && $0.origin != origin }) {
            throw ApiError.nameKept(title: clash.title)
        }
        if !code.address.isEmpty {
            return try await pairDirect(code: code)
        }
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

    private func pairDirect(code: PairingCode) async throws -> PairedYard {
        // The app's client at the yard's address: the timeouts and what
        // TLS trusts are the client's, the origin the address's.
        let direct: Edge
        do {
            direct = try Edge(origin: code.address, transport: edge.transport)
        } catch {
            throw ApiError.protocol(what: "the pairing: the yard's address cannot be read")
        }
        let paired = try await direct.pairDirect(code: code.code)
        let kept = PairedYard(name: "", yard: paired.yard, user: paired.user, device: paired.device, token: paired.token, origin: code.address)
        records.keepYard(kept)
        // The pairing stands whatever /user/me answers: the follower
        // asks it again, and says what is wrong where something is.
        let me: Me
        do {
            me = try await direct.yardDirect(device: paired.token).me()
        } catch is ApiError {
            return kept
        }
        let yard = PairedYard(
            name: "",
            yard: me.yard.isEmpty ? paired.yard : me.yard,
            user: me.user,
            device: me.saidBy.isEmpty ? paired.device : me.saidBy,
            token: paired.token,
            origin: code.address
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
