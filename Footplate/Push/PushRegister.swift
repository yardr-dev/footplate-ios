import Foundation

// Registering the phone for wakes (design 8787 section 3.2): once
// footplate holds a yard device token, its edge session and a push
// token from the system, it sends `POST /user/push/register` through
// the edge for that yard, as it sends every device call — and again
// on every launch and whenever the system rotates the token, with
// no new pairing. The router answers it itself; a yard of its own
// is never registered, since no router stands in front of it. The
// push token is kept on the secret shelf alone, beside the device
// tokens, and is named in no log, error or note: it is a delivery
// address, and the one value that tells a rotation from a launch.

/// A push token as the system gives it, in the hex the register
/// call carries.
func apnsTokenHex(_ token: Data) -> String {
    token.map { String(format: "%02x", $0) }.joined()
}

/// Keeps the relay's rows standing for the yards paired here: the
/// token on the secret shelf, one registration a yard, redone whole
/// on launch, on rotation and where a yard is paired meanwhile, and
/// undone for a yard as it is forgotten, while its credentials
/// stand to make the call. The rows it made are remembered in
/// memory, so a change of the records that pairs no yard — a pick
/// in the switch publishes them as a pairing does — sends nothing.
/// A failed call is left for the next change or launch:
/// registration is a later call, and nothing waits on it.
@MainActor
final class PushRegistrar {
    private let edge: Edge
    private let records: Records
    private let secret: any Shelf

    /// The row last made for each edge yard, by its name at the edge,
    /// which a name of the person's own leaves as it was. Not kept
    /// across a launch: the relay is told again then.
    private var rows: [String: Row] = [:]

    /// What a row was made with. The relay's row is the device's, so
    /// a yard paired again under its name — a new device token — has
    /// none yet, whatever push token the old one was told.
    private struct Row: Equatable {
        let push: String
        let device: String
    }

    init(edge: Edge, records: Records, secret: any Shelf) {
        self.edge = edge
        self.records = records
        self.secret = secret
    }

    /// The token the system last gave, where it gave one.
    var token: String? { secret.get(Self.tokenKey) }

    /// A token the system gave, on launch or rotated: kept, and
    /// every edge yard registered with it where it is new. The same
    /// token again registers nothing: the row stands.
    func tokenReceived(_ token: String) async {
        guard isToken(token) else { return }
        let rotated = token != self.token
        secret.write(put: [Self.tokenKey: token])
        if rotated {
            await registerAll(token: token)
        }
    }

    /// Every launch: the rows are the relay's, and a relay that
    /// lost them — its store restored from no backup — is told
    /// again by the phone's next launch (design 3.2), so what was
    /// remembered of them goes first.
    func launch() async {
        rows.removeAll()
        guard let token else { return }
        await registerAll(token: token)
    }

    /// The yards changed: a yard paired meanwhile is registered with
    /// the token that stands, and one forgotten is dropped from the
    /// checkpoints by its caller, not here. The yards whose rows
    /// stand are not registered again.
    func yardsChanged() async {
        guard let token else { return }
        await registerAll(token: token)
    }

    /// Undoes one yard's row while its credentials stand, as the
    /// phone unpairs itself (design 3.3): best-effort, since the
    /// yard's own device removal and the provider's word are the
    /// backstop where the call cannot land. Nothing of the row is
    /// remembered after, whether the call lands or not: a yard paired
    /// again under the name is registered anew.
    func unregister(yard: PairedYard) async {
        rows[yard.name] = nil
        guard let client = client(yard) else { return }
        try? await client.unregisterPush()
    }

    private func registerAll(token: String) async {
        for yard in records.kept.yards where yard.origin.isEmpty {
            let row = Row(push: token, device: yard.token)
            guard rows[yard.name] != row, let client = client(yard) else { continue }
            // Remembered before the call, since a pairing keeps the
            // yard twice and the second change can come while the
            // first call is in flight; a call that fails forgets it
            // again, and the next change or launch makes it.
            rows[yard.name] = row
            do {
                try await client.registerPush(token: token)
            } catch {
                rows[yard.name] = nil
            }
        }
    }

    /// One yard's calls as its device, where the yard is the edge's
    /// and a session stands: a yard of its own has no register call
    /// to make (design section 7).
    private func client(_ yard: PairedYard) -> YardClient? {
        guard yard.origin.isEmpty, let session = records.kept.account?.session else { return nil }
        return try? edge.yard(device: yard.token, session: session, name: yard.name)
    }

    private static let tokenKey = "push-token"
}
