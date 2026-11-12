import Foundation
import Synchronization

// One paired yard's calls, as its device: design 3.1's table, each
// with its arguments by name and its answer read as docs/api.md has
// it. Plain calls carry the device token; channel calls carry only the
// edge session and yard name outside the envelope, with the token sealed
// inside no call. Made by `Edge.yard` and `Edge.yardDirect`. The phone sends no `run.ask`
// values and no setup account: `approveAsk` and `approveSetup` carry
// only the pick and `weighed`, so a yard refusal is what a later bead
// shows the yard command for; ordinary picks go through `answerAsk`.
// The one value it sends is a harness login's one-time code, in
// `giveSecret`.

final class YardClient: Sendable {
    private let edge: Edge
    private let device: String
    /// The edge's session; empty for a yard of its own, and no
    /// `X-Edge-Token` is sent then.
    private let session: String
    /// The yard's name at the edge; empty for the account's own yard,
    /// and for a yard of its own, which has no name at any edge.
    let name: String
    /// Whether this yard has said it takes no `weighed` (`refusesWeighed`):
    /// one from before yardr v0.15.0, which has no weighty gate either.
    /// Learned from its first refusal and kept for as long as this client
    /// is: a new one, after a restart or a new sign-in, asks again.
    private let takesNoWeighed = Mutex(false)
    /// The yard's channel, where the device pinned one at its
    /// pairing: every call is sealed inside it, on the one outer
    /// path, and no device token crosses on one. Nil, and the
    /// calls are the plain ones of today.
    private let channel: ChannelKeys?
    /// The channel's session, founded by one handshake and dropped
    /// where the yard says it stands no longer.
    private let channelPhase = Mutex(ChannelPhase.closed)

    private enum ChannelPhase {
        case closed
        case opening(UUID, Task<SealedSession, Error>)
        case open(SealedSession)
    }

    init(edge: Edge, device: String, session: String, name: String, channel: ChannelKeys? = nil) throws {
        try requireToken(device)
        guard session.isEmpty || isToken(session) else {
            throw InvalidValueError("a session is one line of visible characters")
        }
        try requireName(name)
        guard !session.isEmpty || name.isEmpty else {
            throw InvalidValueError("a yard of its own has no name at the edge")
        }
        if let channel {
            guard channel.devicePrivate.count == 32, channel.yardPublic.count == 32 else {
                throw InvalidValueError("a channel key is 32 bytes")
            }
        }
        self.edge = edge
        self.device = device
        self.session = session
        self.name = name
        self.channel = channel
    }

    /// Whether every call of this client is sealed inside the yard's
    /// channel, the device token crossing on none: the door an approval
    /// goes through, which a pairing card says before it is sent.
    var sealed: Bool { channel != nil }

    /// Who the token is: the user every call is made as, the device and
    /// the yard. Asked at every start.
    func me() async throws -> Me {
        let answer = try await perform(method: "GET", path: "/user/me", headers: [:], body: Data())
        if let error = refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) {
            throw error
        }
        return try decode("who this device is", Me.self, from: answer.data)
    }

    /// Registers this device for wakes with the relay, through the
    /// edge (design 8787 3.2): a fresh voucher from the yard's channel
    /// names the device in place of the token probe, and the router
    /// answers without forwarding the push token to the yard. `token`
    /// is the system's push token for this installation; it rides in
    /// this call's body alone.
    /// A yard of its own is never registered — no router stands in
    /// front of it — and this client is never made for one here.
    func registerPush(token: String) async throws {
        // A registration only has the voucher path. Sending the device
        // token when migration has not pinned a channel would expose it
        // to the edge and repeat the probe this path replaces.
        guard channel != nil else {
            throw ApiError.refused(code: "not_sealed", message: Self.notSealedWords)
        }
        let authorization = "Bearer \(try await pushVoucher())"
        var request = routedRequest(path: "/user/push/register")
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(jsonContentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonBody(["platform": "apns", "token": token])
        let answer = try await edge.exchange(request)
        if let error = refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) {
            throw error
        }
        guard answer.status == 200 else {
            throw ApiError.protocol(what: "the push registration: status \(answer.status)")
        }
    }

    /// Undoes the registration, as the phone unpairs itself (3.3):
    /// the same door, with no body, deleting this device's row.
    /// With a channel its voucher stands in the token's place, as
    /// at registration.
    func unregisterPush() async throws {
        guard channel != nil else {
            throw ApiError.refused(code: "not_sealed", message: Self.notSealedWords)
        }
        let authorization = "Bearer \(try await pushVoucher())"
        var request = routedRequest(path: "/user/push/unregister")
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let answer = try await edge.exchange(request)
        if let error = refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) {
            throw error
        }
        guard answer.status == 200 else {
            throw ApiError.protocol(what: "the push unregistration: status \(answer.status)")
        }
    }

    /// Registers this device's channel public key in place, under
    /// its token (yardr-n9d2): the one plain call a pre-release
    /// device still makes, answered by the yard's channel public,
    /// pinned without any check of its signature — a phone paired
    /// before the channel holds no yard identity to check it with
    /// (its QR carried address, code and yard name only), so the
    /// pin stands under the design's disclosed, accepted risk
    /// (3.4, 1D), and the yard's list says sealed (in place). A
    /// refusal (a key pinned already, a key another device pins,
    /// a key that is none) answers as a call's refusal does, and
    /// nothing is pinned by it.
    func registerChannelKey(devicePublic: Data) async throws -> Data {
        let reply = try await call(
            method: "RegisterChannelKey",
            args: ["channel_key": channelPublicString(devicePublic)]
        )
        guard let result = reply.whole["result"] as? [String: Any],
              let text = result["channel_key"] as? String,
              let yardPublic = try? parseChannelPublic(text)
        else {
            throw ApiError.protocol(what: "the channel registration: no yard channel key in the answer")
        }
        return yardPublic
    }

    /// A fresh registration voucher, asked of the yard inside the
    /// channel for the user and device the channel proved: the
    /// yard signs one for ten minutes, and the phone asks on each
    /// registration, so none is kept.
    private func pushVoucher() async throws -> String {
        let answer = try await sealedAnswer(method: "POST", path: "/user/push/voucher", headers: [:], body: Data(), marked: false)
        if let error = refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) {
            throw error
        }
        guard answer.status == 200,
              let voucher = jsonObject(answer.body)?["voucher"] as? String, !voucher.isEmpty
        else {
            throw ApiError.protocol(what: "the push voucher: status \(answer.status)")
        }
        return voucher
    }

    /// The seq of the newest event: where the stream starts.
    func head() async throws -> Int64 {
        try await answer(method: "Head", args: [:], as: Int64.self)
    }

    func settings() async throws -> Settings {
        try await answer(method: "Settings", args: [:], as: Settings.self)
    }

    /// One user, with where their mail and notifications are read
    /// through.
    func getUser(name: String) async throws -> User {
        try await answer(method: "GetUser", args: ["name": name], as: User.self)
    }

    /// The crew, running or not.
    func crew() async throws -> [CrewMember] {
        try await list(method: "Crew", args: [:], of: CrewMember.self)
    }

    /// The users of the yard.
    func users() async throws -> [User] {
        try await list(method: "Users", args: [:], of: User.self)
    }

    /// The mail to a user, the unread first; `limit` 0 is all.
    func userInbox(name: String, limit: Int64) async throws -> Inbox {
        try await answer(method: "UserInbox", args: ["name": name, "limit": limit], as: Inbox.self)
    }

    /// The newest `limit` letters between `a` and `b` older than the
    /// seq `before` (0: the newest of all), oldest first, and whether
    /// there are older ones still.
    func conversation(a: String, b: String, limit: Int64, before: Int64 = 0) async throws -> Page {
        var args: [String: Any] = ["a": a, "b": b, "limit": limit]
        if before > 0 { args["before"] = before }
        let reply = try await call(method: "Conversation", args: args)
        let letters = try decode("Conversation", [Letter]?.self, from: resultData(reply)) ?? []
        let more = reply.whole["more"] as? Bool ?? false
        return Page(letters: letters, more: more)
    }

    /// The bytes the yard holds under `hash`: `nil` for a hash the yard
    /// holds no more, and for anything other than 64 ASCII hex
    /// characters. The hash is what a letter said, and goes into the
    /// request's first line, so it is checked before anything is sent.
    func blob(hash: String) async throws -> Data? {
        guard isSHA256Hash(hash) else { return nil }
        let answer = try await perform(method: "GET", path: "/user/blobs/\(hash)", headers: [:], body: Data())
        // A hash the yard no longer holds: none, not an error, and not
        // a device's 404, which the table below would read it as. The
        // bytes themselves are never read for a refusal's shape.
        if answer.status == 404 { return nil }
        if !(200...299).contains(answer.status) || answer.edgeRefusal != nil {
            if let error = refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) {
                throw error
            }
        }
        return answer.data
    }

    /// Gives the yard a file, so mail can carry it: the bytes in
    /// base64, what kind it is read from them. What it answers names
    /// the file.
    func putBlob(_ bytes: Data) async throws -> BlobRef {
        try await answer(method: "PutBlob", args: ["data": bytes.base64EncodedString()], as: BlobRef.self)
    }

    /// Sends mail, with the files `files` names by the hash `putBlob`
    /// answered, each with its base name; nothing answers, and the
    /// `mail` event follows. Left out, the mail carries none.
    func mail(to: String, text: String, actor: String, files: [MailFile] = []) async throws {
        var args: [String: Any] = ["to": to, "text": text, "actor": actor]
        if !files.isEmpty {
            args["files"] = files.map { ["hash": $0.hash, "name": $0.name] }
        }
        _ = try await call(method: "Mail", args: args)
    }

    /// Sends mail to `to` of the linked yard `peer`: what the yard
    /// queues is not read, and the `mail` event follows. Refused when
    /// the link carries no mail out, with nothing queued.
    func mailPeer(to: String, peer: String, text: String, actor: String, files: [MailFile] = []) async throws {
        var args: [String: Any] = ["to": to, "peer": peer, "text": text, "actor": actor]
        if !files.isEmpty {
            args["files"] = files.map { ["hash": $0.hash, "name": $0.name] }
        }
        _ = try await call(method: "MailPeer", args: args)
    }

    /// Marks the user's mail read through a seq.
    func ackUserInbox(name: String, through: Int64) async throws {
        _ = try await call(method: "AckUserInbox", args: ["name": name, "through": through])
    }

    /// What the yard reports to a user apart from every conversation.
    func userNotifications(name: String, limit: Int64) async throws -> Notifications {
        try await answer(method: "UserNotifications", args: ["name": name, "limit": limit], as: Notifications.self)
    }

    func ackUserNotifications(name: String, through: Int64) async throws {
        _ = try await call(method: "AckUserNotifications", args: ["name": name, "through": through])
    }

    /// The person's decisions: the open asks, oldest first, and the
    /// decided.
    func userAsks(name: String) async throws -> Asks {
        try await answer(method: "UserAsks", args: ["name": name], as: Asks.self)
    }

    /// One bead whole, with its asks' options, recommendation and
    /// state.
    func bead(_ bead: String) async throws -> Bead {
        try await answer(method: "Bead", args: ["bead": bead], as: Bead.self)
    }

    /// The flows view: the depots as lines with the open beads on
    /// each. A device's viewer is its user, which the yard reads from
    /// the token and fills in where the call leaves it out, so none is
    /// sent: a yard from before yardr v0.15.0 takes no argument here
    /// and refuses one.
    func flows() async throws -> Flows {
        try await answer(method: "Flows", args: [:], as: Flows.self)
    }

    /// Picks `option` with `words` beside it (left out where empty).
    /// `weighed` is the phone's word that its person saw the card's
    /// weight and passed the unlock: sent only where it is true, and
    /// not to a yard that takes none (`call`).
    func answerAsk(bead: String, ask: Int64, option: Int64, words: String, actor: String, weighed: Bool = false) async throws {
        var args: [String: Any] = ["bead": bead, "ask": ask, "option": option, "actor": actor]
        if !words.isEmpty { args["words"] = words }
        if weighed { args["weighed"] = true }
        _ = try await call(method: "AnswerAsk", args: args)
    }

    /// Approves a run ask: the yard runs the command the ask holds, as
    /// its operator. No `run.ask` values are sent; a card that asks
    /// for any is refused by the yard, which a later bead shows the
    /// yard command for. `weighed` as in `answerAsk`. A `user device
    /// pair` card's approval answers the pairing it opened, once and to
    /// this call alone, and that is the value returned: the yard reads
    /// it back to no one, nothing here keeps or prints it, and every
    /// other approval returns nil. A pairing the answer holds in a
    /// shape that cannot be shown is nil too, and the approval stands.
    @discardableResult
    func approveAsk(bead: String, ask: Int64, actor: String, weighed: Bool = false) async throws -> Pairing? {
        var args: [String: Any] = ["bead": bead, "ask": ask, "actor": actor]
        if weighed { args["weighed"] = true }
        let reply = try await call(method: "ApproveAsk", args: args)
        return Pairing(result: reply.whole["result"] as? [String: Any])
    }

    /// Ends the open pairing of `user`, who is this device's own: the
    /// yard holds the name to the device's user on its listener and
    /// answers no pairing of another's. How a person takes back a
    /// pairing an approval opened from the screen that showed its code.
    func devicePairCloseSelf(user: String) async throws {
        _ = try await call(method: "DevicePairCloseSelf", args: ["user": user])
    }

    /// Approves a setup ask with the preset pick `option`, keeping the
    /// account that stands: the phone types no account and takes no
    /// candidate, so a card that wants either is refused with a
    /// sentence the card shows. `weighed` as in `approveAsk`.
    func approveSetup(bead: String, ask: Int64, option: Int64, actor: String, weighed: Bool = false) async throws {
        var args: [String: Any] = ["bead": bead, "ask": ask, "option": option, "actor": actor]
        if weighed { args["weighed"] = true }
        _ = try await call(method: "ApproveSetup", args: args)
    }

    /// Gives a secret ask the value it asked for, each name of its
    /// `secret.env` to what the person typed. The edge link takes it for
    /// one ask alone, the daemon's for the one-time code a harness's
    /// sign-in page gave (the yard reads the ask the call names and
    /// refuses any other secret): the phone sends it for no other.
    /// The yard hands the value to the waiting login and keeps it
    /// nowhere, and answers the names given; the value is in no
    /// description or error of ours either. `weighed` as in
    /// `answerAsk`: the yard refuses a giving without it.
    func giveSecret(bead: String, ask: Int64, values: [String: String], actor: String, weighed: Bool = false) async throws {
        var args: [String: Any] = ["bead": bead, "ask": ask, "values": values, "actor": actor]
        if weighed { args["weighed"] = true }
        _ = try await call(method: "GiveSecret", args: args)
    }

    /// Later: the ask leaves the queue and comes back as the yard
    /// says.
    func deferAsk(bead: String, ask: Int64, actor: String) async throws {
        _ = try await call(method: "DeferAsk", args: ["bead": bead, "ask": ask, "actor": actor])
    }

    /// Decline: the ask ends with no option picked.
    func declineAsk(bead: String, ask: Int64, words: String, actor: String) async throws {
        _ = try await call(method: "DeclineAsk", args: ["bead": bead, "ask": ask, "words": words, "actor": actor])
    }

    /// The events after `after`, those the yard still has and then
    /// each as it happens, as a cold sequence: each iteration opens a
    /// stream of its own, and cancelling the iteration closes it. A
    /// blank line is the edge's heartbeat and is skipped. A stream
    /// that says nothing for `quiet` (two heartbeats missed) ends
    /// with `ApiError.down`; one the far end closes completes, and is
    /// opened again after the last seq read. `onOpen` runs once after
    /// a successful response has opened.
    func events(
        after: Int64,
        quiet: Duration = YardClient.streamQuiet,
        onOpen: @escaping @Sendable () -> Void = {}
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamEvents(after: after, quiet: quiet, onOpen: onOpen) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Two of the edge's 30-second heartbeats missed, and a little.
    static let streamQuiet: Duration = .seconds(75)
    static let replacingPause: Duration = .milliseconds(100)
    static let replacingPatience: Duration = .seconds(30)

    private func streamEvents(
        after: Int64,
        quiet: Duration,
        onOpen: @Sendable () -> Void,
        emit: (Event) -> Void
    ) async throws {
        if channel != nil {
            try await streamEventsSealed(after: after, quiet: quiet, onOpen: onOpen, emit: emit)
            return
        }
        var request = request(path: "/user/events")
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "after", value: String(after))]
        request.url = components.url!
        request.httpMethod = "GET"
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        // The watchdog below is the stream's idle timeout, as
        // Android's separate read timeout is; the request itself is
        // left open past it.
        request.timeoutInterval = 60 * 60
        let (bytes, head) = try await edge.transport.bytes(for: request)
        if !(200...299).contains(head.status) {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            let refused = refusal(
                status: head.status,
                edgeRefusal: head.header(edgeRefusalHeader),
                retryAfterHeader: head.header("Retry-After"),
                body: body,
                stream: true
            )
            if let refused {
                if case .refused(let code, _) = refused, code == replacingCode {
                    throw ApiError.down(why: "the yard is replacing itself")
                }
                throw refused
            }
            throw ApiError.protocol(what: "the stream answered status \(head.status)")
        }
        onOpen()
        let reader = LineReader(bytes: bytes)
        while let line = try await reader.nextLine(quiet: quiet) {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            emit(try decode("an event", Event.self, from: Data(line.utf8)))
        }
    }

    private func request(path: String) -> URLRequest {
        var request = edge.makeRequest(path: path)
        request.setValue("Bearer \(device)", forHTTPHeaderField: "Authorization")
        if !session.isEmpty {
            request.setValue(session, forHTTPHeaderField: edgeTokenHeader)
        }
        if !name.isEmpty {
            request.setValue(name, forHTTPHeaderField: edgeYardHeader)
        }
        return request
    }

    /// A routed edge call with no device credential: the outer
    /// `/user/e2e` calls and voucher-authenticated push calls use this.
    private func routedRequest(path: String) -> URLRequest {
        var request = edge.makeRequest(path: path)
        if !session.isEmpty {
            request.setValue(session, forHTTPHeaderField: edgeTokenHeader)
        }
        if !name.isEmpty {
            request.setValue(name, forHTTPHeaderField: edgeYardHeader)
        }
        return request
    }

    // MARK: - The channel

    /// The words of a yard that cannot be reached sealed, as the
    /// design has them (3.3): a pinned device fails sealed, and
    /// never sends a plain call under its old token instead.
    private static let notSealedWords = "The yard could not be reached sealed; update or pair again."

    /// One call, plain or sealed as this yard stands: the plain
    /// call carries the device token, as it always did; the sealed
    /// one rides the channel, and the token crosses on none.
    private func perform(method: String, path: String, headers: [String: String], body: Data) async throws -> Answer {
        if channel != nil {
            return try await sealedAnswer(method: method, path: path, headers: headers, body: body, marked: false)
        }
        var request = request(path: path)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !body.isEmpty {
            request.httpBody = body
        }
        return try await edge.exchange(request)
    }

    /// A request on the outer path alone: the edge's session and
    /// the yard's name as every device call carries them, and no
    /// device token — the channel is the call's credential.
    private func outerRequest() -> URLRequest {
        routedRequest(path: "/user/e2e")
    }

    /// The channel's session, founded by one handshake where none
    /// stands: the handshake's first message names no call, which
    /// is how the yard tells it from an enveloped call. A yard
    /// that knows no device of this key refuses it, and the device
    /// is let in no more.
    private func sealedSession() async throws -> SealedSession {
        guard let channel else { throw ApiError.protocol(what: "a sealed call of a yard with no channel") }
        // One handshake at a time: every caller in the same want
        // awaits the one opening, and its answer stands for all.
        let task: Task<SealedSession, Error> = channelPhase.withLock { phase in
            switch phase {
            case .open(let session):
                return Task { session }
            case .opening(_, let opening):
                return opening
            case .closed:
                let id = UUID()
                let opening = Task<SealedSession, Error> { [self] in
                    do {
                        let session = try await handshake(channel: channel)
                        channelPhase.withLock { phase in
                            if case .opening(let current, _) = phase, current == id {
                                phase = .open(session)
                            }
                        }
                        return session
                    } catch {
                        channelPhase.withLock { phase in
                            if case .opening(let current, _) = phase, current == id {
                                phase = .closed
                            }
                        }
                        throw error
                    }
                }
                phase = .opening(id, opening)
                return opening
            }
        }
        return try await task.value
    }

    private func dropSealedSession(_ stale: SealedSession) {
        channelPhase.withLock { phase in
            if case .open(let current) = phase, current === stale {
                phase = .closed
            }
        }
    }

    /// Opens the channel to the yard: one outer call with the
    /// handshake's first message and no call named. Its refusal
    /// is read as a device call's is, the yard's 401 as the
    /// device let in no more, and any other failure as a yard
    /// that could not be reached sealed.
    private func handshake(channel: ChannelKeys) async throws -> SealedSession {
        let opening: ChannelOpening
        do {
            opening = try ChannelOpening(devicePrivate: channel.devicePrivate, yardPublic: channel.yardPublic)
        } catch let failure as ChannelFailure {
            throw ApiError.protocol(what: "the channel handshake: \(failure.description)")
        }
        var request = outerRequest()
        request.httpMethod = "POST"
        request.httpBody = opening.first
        let answer = try await edge.exchange(request)
        if let error = refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) {
            throw error
        }
        if answer.status == 401 {
            throw ApiError.notLetIn
        }
        guard answer.status == 200 else {
            throw ApiError.refused(code: "not_sealed", message: Self.notSealedWords)
        }
        do {
            return try opening.openAnswer(answer.data)
        } catch {
            throw ApiError.refused(code: "not_sealed", message: Self.notSealedWords)
        }
    }

    /// One sealed call whole: the inner call — method, path,
    /// headers and body — sealed in records inside one outer call,
    /// and its answer opened against the call that asked for it.
    /// A session the yard stands no longer (its 401, before any
    /// record is opened) is founded again once and the call made
    /// again, since the yard never served it; any other outer
    /// refusal is the caller's, as a plain one's is.
    private func sealedAnswer(method: String, path: String, headers: [String: String], body: Data, marked: Bool) async throws -> Answer {
        var foundedAgain = false
        while true {
            let session = try await sealedSession()
            let call: Data
            let run: Data
            do {
                call = try newCallID()
                let head = try sealedHead(method: method, path: path, headers: headers)
                run = try session.sealWhole(
                    call: call, marker: marked ? streamLongLived : "", present: marked,
                    plaintext: joinSealed(head: head, body: body)
                )
            } catch let failure as ChannelFailure {
                throw ApiError.protocol(what: "a call that could not be sealed: \(failure.description)")
            }
            var request = outerRequest()
            request.httpMethod = "POST"
            request.setValue(base64URL(call), forHTTPHeaderField: "X-Edge-E2E-Call")
            if marked {
                request.setValue(streamLongLived, forHTTPHeaderField: "X-Edge-E2E-Stream")
            }
            request.httpBody = run
            let answer = try await edge.exchange(request)
            if answer.status == 401, answer.edgeRefusal == nil, !foundedAgain {
                dropSealedSession(session)
                foundedAgain = true
                continue
            }
            if let error = refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) {
                throw error
            }
            guard answer.status == 200 else {
                throw ApiError.protocol(what: "the sealed call: status \(answer.status)")
            }
            let plain: Data
            do {
                plain = try session.openWhole(run: answer.data, call: call, marker: marked ? streamLongLived : "", present: marked)
            } catch {
                throw ApiError.protocol(what: "a sealed answer that does not open")
            }
            let (status, head, innerBody) = try splitSealed(plain)
            return Answer(status: status, head: head, data: innerBody)
        }
    }

    /// The events stream sealed: the inner call marked long-lived
    /// on its outer call, its answer records opened one by one as
    /// they cross, the router's empty records read past, and its
    /// lines read as a plain stream's are once its sealed head has
    /// opened. An outer ending with no final record is a cut
    /// stream, said as one that went silent is.
    private func streamEventsSealed(
        after: Int64,
        quiet: Duration,
        onOpen: @Sendable () -> Void,
        emit: (Event) -> Void
    ) async throws {
        var foundedAgain = false
        while true {
            let session = try await sealedSession()
            let call: Data
            let run: Data
            do {
                call = try newCallID()
                let head = try sealedHead(
                    method: "GET", path: "/user/events?after=\(after)",
                    headers: ["Accept": "application/x-ndjson"]
                )
                run = try session.sealWhole(
                    call: call, marker: streamLongLived, present: true,
                    plaintext: joinSealed(head: head, body: Data())
                )
            } catch let failure as ChannelFailure {
                throw ApiError.protocol(what: "a call that could not be sealed: \(failure.description)")
            }
            var request = outerRequest()
            request.httpMethod = "POST"
            request.setValue(base64URL(call), forHTTPHeaderField: "X-Edge-E2E-Call")
            request.setValue(streamLongLived, forHTTPHeaderField: "X-Edge-E2E-Stream")
            request.httpBody = run
            request.timeoutInterval = 60 * 60
            let (bytes, head) = try await edge.transport.bytes(for: request)
            if head.status == 401, head.header(edgeRefusalHeader) == nil, !foundedAgain {
                dropSealedSession(session)
                foundedAgain = true
                continue
            }
            if !(200...299).contains(head.status) {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                let refused = refusal(
                    status: head.status,
                    edgeRefusal: head.header(edgeRefusalHeader),
                    retryAfterHeader: head.header("Retry-After"),
                    body: body,
                    stream: true
                )
                if let refused {
                    if case .refused(let code, _) = refused, code == replacingCode {
                        throw ApiError.down(why: "the yard is replacing itself")
                    }
                    throw refused
                }
                throw ApiError.protocol(what: "the stream answered status \(head.status)")
            }
            let inner = sealedBytes(bytes: bytes, session: session, call: call)
            let source = ByteSource(inner)
            // The sealed head first: a length-prefixed block, as a
            // whole call's, before any line of the body.
            var headBytes = Data()
            while headBytes.count < 4 {
                guard let byte = try await source.next() else {
                    throw ApiError.down(why: "the sealed stream ended before its head")
                }
                headBytes.append(byte)
            }
            let headLength = Int(bigEndian32(headBytes))
            while headBytes.count < 4 + headLength {
                guard let byte = try await source.next() else {
                    throw ApiError.down(why: "the sealed stream ended before its head")
                }
                headBytes.append(byte)
            }
            let (status, innerHead, _) = try splitSealed(headBytes)
            let leftover = Data(headBytes.dropFirst(4 + headLength))
            let rest = AsyncThrowingStream<UInt8, Error> { continuation in
                let task = Task {
                    do {
                        for byte in leftover {
                            continuation.yield(byte)
                        }
                        while let byte = try await source.next() {
                            continuation.yield(byte)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            if !(200...299).contains(status) {
                var data = Data()
                for try await byte in rest {
                    data.append(byte)
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                let refused = refusal(
                    status: status,
                    edgeRefusal: innerHead.header(edgeRefusalHeader),
                    retryAfterHeader: innerHead.header("Retry-After"),
                    body: body,
                    stream: true
                )
                if let refused {
                    if case .refused(let code, _) = refused, code == replacingCode {
                        throw ApiError.down(why: "the yard is replacing itself")
                    }
                    throw refused
                }
                throw ApiError.protocol(what: "the stream answered status \(status)")
            }
            onOpen()
            let reader = LineReader(bytes: rest)
            while let line = try await reader.nextLine(quiet: quiet) {
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                emit(try decode("an event", Event.self, from: Data(line.utf8)))
            }
            return
        }
    }

    /// The inner bytes of a sealed stream: its records opened as
    /// they cross, the empty ones (the router's beat) read past
    /// before any opening. The outer ending answers only where
    /// the final record opened; without it the stream is cut.
    private func sealedBytes(bytes: AsyncThrowingStream<UInt8, Error>, session: SealedSession, call: Data) -> AsyncThrowingStream<UInt8, Error> {
        let opener = session.opener(call: call, marker: streamLongLived, present: true)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var pending: [UInt8] = []
                do {
                    for try await byte in bytes {
                        pending.append(byte)
                        while pending.count >= 4 {
                            let length = Int(pending[0]) << 24 | Int(pending[1]) << 16 | Int(pending[2]) << 8 | Int(pending[3])
                            if length == 0 {
                                pending.removeFirst(4)
                                continue
                            }
                            guard length <= 65_535 else {
                                throw ChannelFailure(description: "a sealed stream record exceeds the Noise message limit")
                            }
                            guard pending.count >= 4 + length else { break }
                            let message = Data(pending[4..<(4 + length)])
                            pending.removeFirst(4 + length)
                            let opened = try opener.open(message)
                            for inner in opened.plain {
                                continuation.yield(inner)
                            }
                        }
                    }
                    if !pending.isEmpty {
                        throw ChannelFailure(description: "a sealed stream ended inside a record")
                    }
                    try opener.close()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let failure as ChannelFailure {
                    continuation.finish(throwing: ApiError.down(why: "the sealed stream ended early: \(failure.description)"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The outer stream marker's one value, as the router reads
    /// it and the first record binds it.
    private var streamLongLived: String { "long-lived" }

    /// An inner call's head as it travels sealed: its method, its
    /// path with its query, and its headers, as JSON. The device
    /// token is not among them — the channel is the credential.
    private func sealedHead(method: String, path: String, headers: [String: String]) throws -> Data {
        var header: [String: [String]] = [:]
        for (name, value) in headers {
            header[name] = [value]
        }
        do {
            return try JSONSerialization.data(withJSONObject: ["method": method, "path": path, "header": header], options: [.sortedKeys])
        } catch {
            throw ApiError.protocol(what: "a sealed call that cannot be written")
        }
    }

    struct Reply {
        let whole: [String: Any]
    }

    func resultData(_ reply: Reply) throws -> Data {
        guard let result = reply.whole["result"] else {
            return Data("null".utf8)
        }
        if result is NSNull {
            return Data("null".utf8)
        }
        do {
            return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
        } catch {
            // A fragment the serializer will not write alone is
            // wrapped and unwrapped, so a number or a string of a
            // result still decodes.
            let wrapped = try JSONSerialization.data(withJSONObject: [result], options: [])
            return Data(wrapped.dropFirst().dropLast())
        }
    }

    func decode<T: Decodable>(_ what: String, _ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let first = String(describing: error).split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "unreadable"
            throw ApiError.protocol(what: "\(what): \(first)")
        }
    }

    private func answer<T: Decodable>(method: String, args: [String: Any], as type: T.Type) async throws -> T {
        let reply = try await call(method: method, args: args)
        return try decode(method, type, from: resultData(reply))
    }

    private func list<T: Decodable>(method: String, args: [String: Any], of type: T.Type) async throws -> [T] {
        let reply = try await call(method: method, args: args)
        return try decode(method, [T]?.self, from: resultData(reply)) ?? []
    }

    /// Makes a call. A yard that is replacing itself did not run it:
    /// it is made again every 100 ms, also through the moment in
    /// which nothing answers between the two builds, for up to 30
    /// seconds, and nothing is said meanwhile. A yard from before yardr
    /// v0.15.0 refuses `weighed` as a name it does not know, and the call
    /// is made once more without it, which is what the phone sent before
    /// the word was added: its person passed the unlock already, and a
    /// yard that has no weighty gate asks for none. That yard is told no
    /// more of it, on this call or any other. Any other refusal is the
    /// caller's, and so is a second one.
    private func call(method: String, args: [String: Any]) async throws -> Reply {
        var args = args
        if takesNoWeighed.withLock({ $0 }) {
            args["weighed"] = nil
        }
        var replacingSince: ContinuousClock.Instant?
        while true {
            do {
                return try await callOnce(method: method, args: args)
            } catch let error as ApiError {
                switch error {
                case .refused(let code, _) where code == replacingCode:
                    let since = replacingSince ?? ContinuousClock.now
                    if replacingSince == nil { replacingSince = since }
                    if since.duration(to: ContinuousClock.now) >= YardClient.replacingPatience {
                        throw ApiError.down(why: "the yard is replacing itself")
                    }
                case .refused(_, let message) where args["weighed"] != nil && refusesWeighed(message, method: method):
                    takesNoWeighed.withLock { $0 = true }
                    args["weighed"] = nil
                    continue
                case .down:
                    guard let since = replacingSince else { throw error }
                    if since.duration(to: ContinuousClock.now) >= YardClient.replacingPatience {
                        throw error
                    }
                default:
                    throw error
                }
            }
            try await Task.sleep(for: YardClient.replacingPause)
        }
    }

    private func callOnce(method: String, args: [String: Any]) async throws -> Reply {
        let answer = try await perform(
            method: "POST", path: "/user/call/\(method)",
            headers: ["Content-Type": jsonContentType], body: try jsonBody(args)
        )
        if let error = refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) {
            throw error
        }
        guard let whole = jsonObject(answer.body) else {
            throw ApiError.protocol(what: "\(method): status \(answer.status), and no JSON object")
        }
        return Reply(whole: whole)
    }
}

extension YardClient: CustomStringConvertible {
    var description: String {
        if session.isEmpty {
            "YardClient(\(edge.origin), direct, device=<token>)"
        } else {
            "YardClient(\(edge.origin), yard=\(name.isEmpty ? "<the account's>" : name), device=<token>, session=<token>)"
        }
    }
}

/// Reads lines from a byte stream, one watchdog at a time. Only the
/// task that reads a line touches the buffer; when the watchdog wins
/// the reader is abandoned with its stream.
final class LineReader: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<UInt8, Error>.AsyncIterator
    private var buffer: [UInt8] = []
    private var finished = false

    init(bytes: AsyncThrowingStream<UInt8, Error>) {
        iterator = bytes.makeAsyncIterator()
    }

    private enum LineResult {
        case line(String?)
        case timeout
    }

    /// The next line without its ending, or nil at the end of the
    /// stream. Throws `ApiError.down` after `quiet` with no line.
    func nextLine(quiet: Duration) async throws -> String? {
        try await withThrowingTaskGroup(of: LineResult.self) { group in
            group.addTask { [self] in
                .line(try await readLine())
            }
            group.addTask {
                do {
                    try await Task.sleep(for: quiet)
                } catch {
                    // Cancelled because a line arrived: the result is
                    // discarded either way.
                }
                return .timeout
            }
            guard let first = try await group.next() else { return nil }
            group.cancelAll()
            switch first {
            case .line(let line):
                return line
            case .timeout:
                throw ApiError.down(why: "the stream said nothing for \(quiet)")
            }
        }
    }

    private func readLine() async throws -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            if finished {
                if buffer.isEmpty { return nil }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll()
                return line
            }
            if let byte = try await iterator.next() {
                buffer.append(byte)
            } else {
                finished = true
            }
        }
    }
}

/// The blob route accepts a content SHA-256 digest: exactly 64 ASCII
/// hex characters, so a letter cannot turn the first line into
/// another path.
func isSHA256Hash(_ hash: String) -> Bool {
    hash.count == 64 && hash.allSatisfy {
        ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") || ($0 >= "A" && $0 <= "F")
    }
}

/// A sealed plaintext whole: the head as a length-prefixed block,
/// then the body as it stands.
func joinSealed(head: Data, body: Data) -> Data {
    var out = Data()
    var length = UInt32(head.count).bigEndian
    withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
    out.append(head)
    out.append(body)
    return out
}

/// `joinSealed` read back: the inner answer's status and headers,
/// and its body. The outer head of a sealed answer names the
/// envelope alone, so these are the caller's alone to read.
func splitSealed(_ plain: Data) throws -> (status: Int, head: HTTPHead, body: Data) {
    guard plain.count >= 4 else {
        throw ApiError.protocol(what: "a sealed answer with no head")
    }
    let length = Int(bigEndian32(plain))
    guard plain.count >= 4 + length,
          let object = try? JSONSerialization.jsonObject(with: plain.subdata(in: 4..<(4 + length))) as? [String: Any],
          let status = object["status"] as? Int
    else {
        throw ApiError.protocol(what: "a sealed answer with no head")
    }
    var headers: [String: String] = [:]
    if let header = object["header"] as? [String: [String]] {
        for (name, values) in header {
            headers[name] = values.joined(separator: ",")
        }
    }
    return (status, HTTPHead(status: status, headers: headers), Data(plain.dropFirst(4 + length)))
}

/// The first four bytes of `data`, big-endian, as a record's or a
/// head's length stands.
func bigEndian32(_ data: Data) -> UInt32 {
    data.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
}

/// One byte stream read from two places in turn: its sealed head
/// first, then its lines. The iterator is the stream's alone, and
/// its two readers never stand in it at once.
final class ByteSource: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<UInt8, Error>.AsyncIterator

    init(_ stream: AsyncThrowingStream<UInt8, Error>) {
        iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> UInt8? {
        try await iterator.next()
    }
}
