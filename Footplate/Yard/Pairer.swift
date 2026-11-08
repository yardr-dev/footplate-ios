import Foundation

// Signing in, pairing and forgetting, as design 3.2 has them: the
// steps between the yard's calls and the records, for the models to
// call. Every request goes to `edge`, the app's one origin, but a code
// with an address of its own, which goes to that address with no edge.
@MainActor
final class Pairer {
    private let edge: Edge
    private let records: Records

    /// Called with a yard as it is forgotten, while its credentials
    /// stand: the app undoes the yard's push registration there
    /// (design 8787 3.3). Nothing else rides on it.
    var onForget: (@MainActor (PairedYard) async -> Void)?

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
    /// once when a web view link or a pairing needs it.
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
    /// every later call to `<address>` with the device token alone; the
    /// yard is kept under the name its address gives it (`ownName`).
    @discardableResult
    func pair(code: PairingCode) async throws -> PairedYard {
        // One name holds one yard: the head line, the followers and the
        // boards all read by name, so a second yard under a kept name
        // would show one yard's rows and send what is typed to the
        // other. Refused before anything is sent, so the code is not
        // burned. The same yard again, the same name at the same
        // origin, pairs as before. A yard of its own is named by its
        // address, so the clash left for it is an edge yard that
        // carries that very name.
        let name: String
        if code.address.isEmpty {
            name = try await edgeName(code.yard)
        } else {
            name = ownName(code.address)
        }
        let origin = code.address
        if let clash = records.kept.yards.first(where: { $0.name == name && $0.origin != origin }) {
            throw ApiError.nameKept(title: clash.title)
        }
        if !code.address.isEmpty {
            return try await pairDirect(code: code, name: name)
        }
        guard let account = records.kept.account else { throw ApiError.notSignedIn }
        // A yard of another account pairs as an own named yard does: the
        // member's own session beside the code, and its `owner/yard` in
        // `X-Edge-Yard`, which is how the edge names it. Where the QR
        // the code came from held the yard's channel key, the code is
        // redeemed sealed to it, with a key of this phone's made for
        // the yard and kept beside the token.
        if !code.channel.isEmpty {
            return try await pairSealed(code: code, name: name, session: account.session)
        }
        let paired = try await edge.pair(code: code.code, session: account.session, yard: name)
        let kept = PairedYard(name: name, yard: paired.yard, user: paired.user, device: paired.device, token: paired.token)
        records.keepYard(kept)
        // The pairing stands whatever /user/me answers: the follower
        // asks it again, and says what is wrong where something is.
        let me: Me
        do {
            me = try await edge.yard(device: paired.token, session: account.session, name: name).me()
        } catch is ApiError {
            return kept
        }
        let yard = PairedYard(
            name: name,
            yard: me.yard.isEmpty ? paired.yard : me.yard,
            user: me.user,
            device: me.saidBy.isEmpty ? paired.device : me.saidBy,
            token: paired.token
        )
        records.keepYard(yard)
        return yard
    }

    /// Pairs sealed, where the QR held the yard's channel key: a
    /// key pair of this phone's for the yard, the code redeemed
    /// inside the handshake to the pinned key, and the yard kept
    /// with the private half beside the token and the yard's key
    /// pinned, recorded paired. Every later call is sealed inside
    /// the channel the two keys found, and no plain call is sent
    /// for this yard from here on.
    private func pairSealed(code: PairingCode, name: String, session: String) async throws -> PairedYard {
        let yardPublic = try parseChannelPublic(code.channel)
        let device = try makeDeviceKey()
        let paired = try await edge.pairSealed(
            code: code.code, session: session, yard: name,
            devicePrivate: device.devicePrivate, yardPublic: yardPublic
        )
        let kept = PairedYard(
            name: name, yard: paired.yard, user: paired.user, device: paired.device, token: paired.token,
            channelPrivate: device.devicePrivate, yardChannelPublic: yardPublic, sealedHow: "paired"
        )
        records.keepYard(kept)
        let me: Me
        do {
            me = try await edge.yard(device: paired.token, session: session, name: name, channel: kept.channel).me()
        } catch is ApiError {
            return kept
        }
        let yard = PairedYard(
            name: name,
            yard: me.yard.isEmpty ? paired.yard : me.yard,
            user: me.user,
            device: me.saidBy.isEmpty ? paired.device : me.saidBy,
            token: paired.token,
            channelPrivate: device.devicePrivate, yardChannelPublic: yardPublic, sealedHow: "paired"
        )
        records.keepYard(yard)
        return yard
    }

    /// The name the edge's yard `yard` is kept under. A yard of another
    /// account stays `owner/yard`; one spelled with the account's own
    /// handle is the account's own yard, kept by its bare name, so the
    /// head line never calls a yard of its own another's. The handle is
    /// the one kept with the session, or the edge's word for a session
    /// kept before the handle was, asked once.
    private func edgeName(_ yard: String) async throws -> String {
        guard let member = memberYard(yard) else { return yard }
        let handle = try await accountHandleForWebView()
        return member.owner == handle ? member.yard : yard
    }

    private func pairDirect(code: PairingCode, name: String) async throws -> PairedYard {
        // The app's client at the yard's address: the timeouts and what
        // TLS trusts are the client's, the origin the address's.
        let direct: Edge
        do {
            direct = try Edge(origin: code.address, transport: edge.transport)
        } catch {
            throw ApiError.protocol(what: "the pairing: the yard's address cannot be read")
        }
        // A yard of its own is reached with its token alone, as it
        // always was: its channel stands on its link from the edge,
        // which no direct yard has, so a channel key its QR held is
        // not redeemed against — the pairing is the plain one.
        let paired = try await direct.pairDirect(code: code.code)
        let kept = PairedYard(name: name, yard: paired.yard, user: paired.user, device: paired.device, token: paired.token, origin: code.address)
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
            name: name,
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
        if let yard = kept.yards.first(where: { $0.name == name }) {
            await onForget?(yard)
        }
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
