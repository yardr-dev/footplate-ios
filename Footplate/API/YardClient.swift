import Foundation

// One paired yard's calls, as its device: design 3.1's table, each
// with its arguments by name and its answer read as docs/api.md has
// it. Through the edge every request carries the device token, the
// session and, for a yard with a name at the edge, X-Edge-Yard; a yard
// of its own carries the device token alone. Made by `Edge.yard` and
// `Edge.yardDirect`. The phone sends no `run.ask`
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

    init(edge: Edge, device: String, session: String, name: String) throws {
        try requireToken(device)
        guard session.isEmpty || isToken(session) else {
            throw InvalidValueError("a session is one line of visible characters")
        }
        try requireName(name)
        guard !session.isEmpty || name.isEmpty else {
            throw InvalidValueError("a yard of its own has no name at the edge")
        }
        self.edge = edge
        self.device = device
        self.session = session
        self.name = name
    }

    /// Who the token is: the user every call is made as, the device and
    /// the yard. Asked at every start.
    func me() async throws -> Me {
        var request = request(path: "/user/me")
        request.httpMethod = "GET"
        let answer = try await edge.exchange(request)
        if let error = refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) {
            throw error
        }
        return try decode("who this device is", Me.self, from: answer.data)
    }

    /// Registers this device for wakes with the relay, through the
    /// edge (design 8787 3.2): the router answers it itself, binds
    /// it to the session beside the device token, and forwards no
    /// part of it to the yard. `token` is the system's push token
    /// for this installation; it rides in this call's body alone.
    /// A yard of its own is never registered — no router stands in
    /// front of it — and this client is never made for one here.
    func registerPush(token: String) async throws {
        var request = request(path: "/user/push/register")
        request.httpMethod = "POST"
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
    func unregisterPush() async throws {
        var request = request(path: "/user/push/unregister")
        request.httpMethod = "POST"
        let answer = try await edge.exchange(request)
        if let error = refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) {
            throw error
        }
        guard answer.status == 200 else {
            throw ApiError.protocol(what: "the push unregistration: status \(answer.status)")
        }
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
        var request = request(path: "/user/blobs/\(hash)")
        request.httpMethod = "GET"
        let answer = try await edge.exchange(request)
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
    /// weight and passed the unlock: sent only where it is true.
    func answerAsk(bead: String, ask: Int64, option: Int64, words: String, actor: String, weighed: Bool = false) async throws {
        var args: [String: Any] = ["bead": bead, "ask": ask, "option": option, "actor": actor]
        if !words.isEmpty { args["words"] = words }
        if weighed { args["weighed"] = true }
        _ = try await call(method: "AnswerAsk", args: args)
    }

    /// Approves a run ask: the yard runs the command the ask holds, as
    /// its operator. No `run.ask` values are sent; a card that asks
    /// for any is refused by the yard, which a later bead shows the
    /// yard command for. `weighed` as in `answerAsk`.
    func approveAsk(bead: String, ask: Int64, actor: String, weighed: Bool = false) async throws {
        var args: [String: Any] = ["bead": bead, "ask": ask, "actor": actor]
        if weighed { args["weighed"] = true }
        _ = try await call(method: "ApproveAsk", args: args)
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
    /// seconds, and nothing is said meanwhile. Any other refusal is
    /// the caller's.
    private func call(method: String, args: [String: Any]) async throws -> Reply {
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
        var request = request(path: "/user/call/\(method)")
        request.httpMethod = "POST"
        request.setValue(jsonContentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonBody(args)
        let answer = try await edge.exchange(request)
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
