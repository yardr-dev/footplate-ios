@testable import Footplate
import Foundation

// The fake yard of design 3.7: one account at a fake edge, in-process,
// with Kratos's sign-in and logout, yards told apart by X-Edge-Yard
// (the account's own two, and one of another account's it is a member
// of, named `owner/yard` as the edge names it), a pairing open in each,
// and a call with no edge headers served as a yard of its own by the
// home yard; every call of 3.1 answered with docs/api.md's examples,
// and the edge's and the yard's refusals on demand, a removed member's
// among them. It records every request, so a test asserts what a call
// carried. It implements the same transport seam as URLSession, so no
// socket is opened; URLSession's own framing is proved by the loopback
// smoke test alone.

struct RecordedRequest: Sendable {
    let method: String
    /// Path with its query, as `/user/events?after=151`.
    let path: String
    /// Header values by lowercased name.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    var bodyText: String {
        String(data: body, encoding: .utf8) ?? ""
    }

    /// The body as a JSON object, or empty where it is none.
    func bodyObject() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }
}

struct FakeResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    init(status: Int, headers: [String: String] = [:], text: String) {
        self.init(status: status, headers: headers, body: Data(text.utf8))
    }

    var head: HTTPHead {
        HTTPHead(status: status, headers: headers)
    }

    static func json(_ status: Int, _ body: String) -> FakeResponse {
        FakeResponse(status: status, headers: ["Content-Type": "application/json"], text: body)
    }

    // The edge's answers, as the router gives them.

    static func signedOut() -> FakeResponse {
        json(401, #"{"error": "edge: sign in"}"#)
            .withHeader("X-Edge-Refusal", "session")
    }

    static func away() -> FakeResponse {
        json(503, #"{"error": "edge: the yard's link is down"}"#)
            .withHeader("X-Edge-Refusal", "away")
    }

    static func busy() -> FakeResponse {
        json(429, #"{"error": "edge: the yard's link is full"}"#)
            .withHeader("X-Edge-Refusal", "busy")
    }

    static func notReady(_ why: String = "the yard is building") -> FakeResponse {
        json(403, "{\"error\": \"edge: \(why)\"}")
    }

    /// The edge's two 403s for a pairing code it will not pass on, as
    /// the router words them (giftedPairing): opened for another
    /// account, and not open for this yard.
    static func pairingSpent() -> FakeResponse {
        json(403, #"{"error": "edge: that pairing code was opened for another account; it is spent — open a new pairing"}"#)
    }

    static func pairingNotOpen() -> FakeResponse {
        json(403, #"{"error": "edge: that pairing code is not open for this yard"}"#)
    }

    static func badGateway() -> FakeResponse {
        json(502, #"{"error": "edge: the yard did not answer"}"#)
    }

    static func edgeDown() -> FakeResponse {
        json(503, #"{"error": "edge: the account service did not answer"}"#)
    }

    static func slow() -> FakeResponse {
        json(504, #"{"error": "edge: the yard took longer than 30s"}"#)
    }

    // The yard's own, passed on by the edge without X-Edge-Refusal.

    static func notLetIn() -> FakeResponse {
        FakeResponse(status: 401, text: "Unauthorized\n")
    }

    static func noDevice() -> FakeResponse {
        FakeResponse(status: 404, text: "404 page not found\n")
    }

    /// The device's 17th stream, with `retryAfter` as the header says
    /// it, or no header at all.
    static func streamsFull(retryAfter: String? = "5") -> FakeResponse {
        var response = FakeResponse(
            status: 503,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            text: "this device holds 16 streams already\n"
        )
        if let retryAfter {
            response = response.withHeader("Retry-After", retryAfter)
        }
        return response
    }

    static func replacing() -> FakeResponse {
        json(503, #"{"error": {"code": "replacing", "message": "the yard is replacing itself with a newer build"}}"#)
    }

    /// A call the yard will not make, as it refuses one: `message` under
    /// `code`, on a 200.
    static func refused(_ message: String, code: String = "error") -> FakeResponse {
        let refusal: [String: Any] = ["error": ["code": code, "message": message]]
        return json(200, String(decoding: try! JSONSerialization.data(withJSONObject: refusal), as: UTF8.self))
    }

    static func wrongCode() -> FakeResponse {
        json(403, #"{"refused": "wrong_code"}"#)
    }

    func withHeader(_ name: String, _ value: String) -> FakeResponse {
        var headers = self.headers
        headers[name] = value
        return FakeResponse(status: status, headers: headers, body: body)
    }
}

struct StreamScript: Sendable {
    var lines: [String]
    /// After the lines, nothing is sent and the stream stays open.
    var hang: Bool = false
}

/// A typed code's PAKE run as the fake yard holds it (userpair.go's
/// pakeSession): the yard's half of the exchange, the device's
/// confirmation once it has held, and the yard's own.
final class PAKERun: @unchecked Sendable {
    let session: String
    let handshake: YardPAKEHandshake
    var deviceConfirmation: Data?
    var yardConfirmation = Data()

    init(session: String, handshake: YardPAKEHandshake) {
        self.session = session
        self.handshake = handshake
    }
}

/// A hanging stream the fake holds open, until `closeStreams` or its hour.
private struct OpenStream {
    let continuation: AsyncThrowingStream<UInt8, Error>.Continuation
    let sleeper: Task<Void, Never>
}

final class FakeYard: HTTPTransport, @unchecked Sendable {
    let email = "jo@example.com"
    let password = "correct horse battery staple"

    /// The fake edge's origin: http on loopback, which the client
    /// allows for this machine alone. No socket listens there; the
    /// transport is this object.
    let origin = "http://localhost:18765"

    final class YardState: @unchecked Sendable {
        let name: String
        let user: String
        let device: String
        let yard: String
        /// The coordinator /user/me names; nil, and the answer holds no
        /// such field, as a yard older than the field answers.
        var coordinator: String? = "yardmaster"
        /// What the yard takes in a method where that is fewer arguments
        /// than docs/api.md lists today, as a yard from before the others
        /// were added: a call that names one it does not take is refused.
        var takes: [String: [String]] = [:]
        var code: String?
        var tokens: Set<String> = []
        var blobs: [String: Data] = [:]
        /// The yard's channel key pair, as `yardr user device pair
        /// --qr` would carry its public half: the fake opens sealed
        /// pairings and channel handshakes with the private half.
        let channelPrivate: Data
        let channelPublic: String
        /// The device channel keys this yard has pinned, by the
        /// token each pairing minted: a channel handshake is let
        /// in for a pinned key alone.
        var pinned: [String: String] = [:]
        /// Live channel sessions by their tag, as base64url.
        var channelSessions: [String: SealedSession] = [:]
        /// The one live PAKE run of a typed code's redemption: a new
        /// start replaces it, and a failed confirmation or a finish
        /// spends it.
        var pake: PAKERun?

        init(name: String, user: String, device: String, yard: String, code: String?) {
            self.name = name
            self.user = user
            self.device = device
            self.yard = yard
            self.code = code
            let key = try! makeDeviceKey()
            channelPrivate = key.devicePrivate
            channelPublic = channelPublicString(key.devicePublic)
        }
    }

    /// The yards of the account: the own one (no X-Edge-Yard), laptop,
    /// and alice's yard lab, which the account is a member of and acts
    /// in as the yard user its owner made for it.
    let home = YardState(name: "", user: "jo", device: "phone", yard: "south", code: "K7QM-2XPD")
    let laptop = YardState(name: "laptop", user: "jo", device: "pixel", yard: "laptop", code: "M4TR-9KWE")
    let lab = YardState(name: "alice/lab", user: "joe", device: "phone", yard: "lab", code: "R2VH-6NQD")

    private let lock = NSLock()
    /// The yards the edge lets the account into: a member yard whose
    /// owner removed the membership is none, and is answered as a yard
    /// the account does not hold.
    private var yards: [YardState] { [home, laptop, lab].filter { !removed.contains($0.name) } }
    private var removed: Set<String> = []
    private var sessions: Set<String> = []
    private var minted = 0
    private var expired = 0
    private var overrides: [String: [FakeResponse]] = [:]
    private var yardOverrides: [String: [FakeResponse]] = [:]
    private var alwaysHandlers: [String: () -> FakeResponse] = [:]
    private var streamScripts: [StreamScript] = []
    private var delays: [String: [Duration]] = [:]
    private var openStreams: [UUID: OpenStream] = [:]
    private var recorded: [RecordedRequest] = []
    private var takenIndex = 0
    /// The relay's rows as the fake router holds them, by yard name:
    /// the push token a register call last wrote for that yard.
    private var pushRows: [String: String] = [:]
    private var answeredPairings: [Data] = []

    /// The push token registered for the yard named `yardName`, or
    /// nil where no row stands (never registered, or unregistered).
    func pushToken(yardName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return pushRows[yardName]
    }

    func edge() throws -> Edge {
        try Edge(origin: origin, transport: self)
    }

    /// A session the edge knows, as a sign-in would have made.
    func session() -> String {
        lock.lock()
        defer { lock.unlock() }
        return mintSessionLocked()
    }

    /// The yard named `yardName`'s channel public key, as its
    /// pairing QR's fourth field carries it.
    func channelPublic(yardName: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return yards.first { $0.name == yardName }!.channelPublic
    }

    /// Pins a device channel key at the yard named `yardName`, as
    /// a sealed pairing there would have: the tests keep yards
    /// with their channel beside them, as the pairer does.
    func pin(yardName: String, devicePublic: String) {
        lock.lock()
        defer { lock.unlock() }
        yards.first { $0.name == yardName }!.pinned["pinned"] = devicePublic
    }

    /// The device channel public key the yard named `yardName` pinned
    /// for `token`, as its pairing recorded it: nil for a token no
    /// pairing of a key minted.
    func pinnedKey(yardName: String, token: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return yards.first { $0.name == yardName }?.pinned[token]
    }

    /// The bodies the fake answered the pairing path with, in order:
    /// what the edge reads of a pairing's answers, beside `allRequests`,
    /// what it reads of its requests.
    var pairingAnswers: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return answeredPairings
    }

    /// Drops the fake yard's live channel sessions, as a yard restart or
    /// its one-day idle expiry does; the device still has its session.
    func expireChannelSessions(yardName: String) {
        lock.lock()
        defer { lock.unlock() }
        yards.first { $0.name == yardName }?.channelSessions.removeAll()
    }

    /// A device token the yard named `yardName` lets in, as a pairing
    /// would have given.
    @discardableResult
    func token(yardName: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let yard = yards.first { $0.name == yardName }!
        return mintTokenLocked(yard)
    }

    /// The owner of the member yard named `name` removes the account's
    /// membership: from the next request the edge answers it 403, `the
    /// account holds no yard of that name`, before any yard is asked.
    func removeMember(_ name: String) {
        lock.lock()
        removed.insert(name)
        lock.unlock()
    }

    /// How many of the next submitted login flows the edge has
    /// forgotten: each answers 410.
    func setExpiredFlows(_ count: Int) {
        lock.lock()
        expired = count
        lock.unlock()
    }

    /// The next request to `path` (without its query) is answered so,
    /// and then the fake answers as before. Queued in order.
    func next(_ path: String, _ responses: FakeResponse...) {
        lock.lock()
        overrides[path, default: []].append(contentsOf: responses)
        lock.unlock()
    }

    /// The next request of the yard named `yard` ("" for the
    /// account's own) to `path` is answered so. Queued in order, and
    /// asked after the session's gate.
    func nextFor(yard: String, path: String, _ responses: FakeResponse...) {
        lock.lock()
        yardOverrides[yard + "\u{1}" + path, default: []].append(contentsOf: responses)
        lock.unlock()
    }

    /// Every request of the yard named `yard` to `path` is answered
    /// by `handler` from now on, as a yard away stays away.
    func setAlways(yard: String, path: String, handler: @escaping () -> FakeResponse) {
        lock.lock()
        alwaysHandlers[yard + "\u{1}" + path] = handler
        lock.unlock()
    }

    /// The next stream: `lines` one a line (a blank one is a
    /// heartbeat), then, with `hang`, nothing more before the stream
    /// would end.
    func stream(lines: [String], hang: Bool = false) {
        lock.lock()
        streamScripts.append(StreamScript(lines: lines, hang: hang))
        lock.unlock()
    }

    func setBlob(yardName: String, hash: String, bytes: Data) {
        lock.lock()
        yards.first { $0.name == yardName }?.blobs[hash] = bytes
        lock.unlock()
    }

    /// The name the yard named `yardName` answers as its coordinator;
    /// nil, and /user/me holds no such field, as a yard older than the
    /// field answers.
    func setCoordinator(yardName: String, coordinator: String?) {
        lock.lock()
        yards.first { $0.name == yardName }?.coordinator = coordinator
        lock.unlock()
    }

    /// The calls yardr keeps in its `OperatorCalls`, those the phone makes:
    /// a run or setup approval and a secret's giving.
    private static let operatorCalls: Set<String> = ["ApproveAsk", "ApproveSetup", "GiveSecret"]

    /// The yard named `yardName` takes only `names` in `method`, as a
    /// yard from before the others were added does; nil lifts it. A call
    /// that names another is refused in the yard's own words, as yardr's
    /// `named` words it.
    func setTakes(yardName: String, method: String, _ names: [String]?) {
        lock.lock()
        yards.first { $0.name == yardName }?.takes[method] = names
        lock.unlock()
    }

    /// The next request to `path` (without its query) waits `duration`
    /// before it is answered, as a slow yard would. Queued in order.
    func delay(_ path: String, _ duration: Duration) {
        lock.lock()
        delays[path, default: []].append(duration)
        lock.unlock()
    }

    /// Takes `token` from the yard named `yardName`, as its operator
    /// revoking the device would; `restoreToken` gives it back.
    func revokeToken(yardName: String, token: String) {
        lock.lock()
        defer { lock.unlock() }
        yards.first { $0.name == yardName }?.tokens.remove(token)
    }

    func restoreToken(yardName: String, token: String) {
        lock.lock()
        defer { lock.unlock() }
        yards.first { $0.name == yardName }?.tokens.insert(token)
    }

    /// Closes every open stream, as their far ends going quiet would: a
    /// collector suspended in one resumes at its end. The session tests
    /// call it once their followers are stopped.
    func closeStreams() {
        lock.lock()
        let open = openStreams
        openStreams.removeAll()
        lock.unlock()
        for stream in open.values {
            stream.sleeper.cancel()
            stream.continuation.finish()
        }
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    var openStreamCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return openStreams.count
    }

    var allRequests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The requests that carry `text` anywhere: in the path and its
    /// query, in a header's value or in the body.
    func requests(carrying text: String) -> [RecordedRequest] {
        allRequests.filter { request in
            request.path.contains(text)
                || request.headers.values.contains { $0.contains(text) }
                || request.bodyText.contains(text)
        }
    }

    /// The next request, recorded, in the order requests arrived.
    func taken() -> RecordedRequest {
        lock.lock()
        defer { lock.unlock() }
        precondition(takenIndex < recorded.count, "no request reached the fake yard")
        let request = recorded[takenIndex]
        takenIndex += 1
        return request
    }

    // MARK: - HTTPTransport

    func data(for request: URLRequest) async throws -> (Data, HTTPHead) {
        let recorded = record(request)
        let path = recorded.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? recorded.path
        if let delay = popDelay(path: path) {
            try await Task.sleep(for: delay)
        }
        let response = answerLocked(recorded: recorded)
        if path == "/user/pair" {
            notePairingAnswer(response.body)
        }
        return (response.body, response.head)
    }

    private func notePairingAnswer(_ body: Data) {
        lock.lock()
        answeredPairings.append(body)
        lock.unlock()
    }

    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPHead) {
        let recorded = record(request)
        let path = recordedURL(request).path
        if let response = popOverride(path: path) {
            return (finiteStream(response.body), response.head)
        }
        if path == "/user/e2e" {
            return sealedStream(recorded: recorded)
        }
        guard path == "/user/events" else {
            let response = answerLocked(recorded: recorded, popOverrides: false)
            return (finiteStream(response.body), response.head)
        }
        // The events route goes through the same gates as a call,
        // then through the next script, or ends at once.
        switch streamDecision(recorded: recorded) {
        case .gated(let response):
            return (finiteStream(response.body), response.head)
        case .script(let script):
            return (scriptStream(script), HTTPHead(status: 200, headers: ["Content-Type": "application/x-ndjson"]))
        case .empty:
            return (finiteStream(Data()), HTTPHead(status: 200, headers: ["Content-Type": "application/x-ndjson"]))
        }
    }

    private enum StreamDecision {
        case gated(FakeResponse)
        case script(StreamScript)
        case empty
    }

    private func popOverride(path: String) -> FakeResponse? {
        lock.lock()
        defer { lock.unlock() }
        guard var queue = overrides[path], !queue.isEmpty else { return nil }
        let response = queue.removeFirst()
        overrides[path] = queue
        return response
    }

    private func streamDecision(recorded: RecordedRequest) -> StreamDecision {
        lock.lock()
        defer { lock.unlock() }
        if let gated = streamGateLocked(recorded: recorded) {
            return .gated(gated)
        }
        if !streamScripts.isEmpty {
            return .script(streamScripts.removeFirst())
        }
        return .empty
    }

    private func record(_ request: URLRequest) -> RecordedRequest {
        let url = request.url!
        var path = url.path
        if let query = url.query, !query.isEmpty {
            path += "?" + query
        }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            path: path,
            headers: headers,
            body: request.httpBody ?? Data()
        )
        lock.lock()
        self.recorded.append(recorded)
        lock.unlock()
        return recorded
    }

    private func recordedURL(_ request: URLRequest) -> URL {
        request.url!
    }

    private func finiteStream(_ data: Data) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            for byte in data {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }

    private func scriptStream(_ script: StreamScript) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            for line in script.lines {
                for byte in (line + "\n").utf8 {
                    continuation.yield(byte)
                }
            }
            if script.hang {
                let id = UUID()
                let sleeper = Task {
                    try? await Task.sleep(for: .seconds(3600))
                    continuation.finish()
                }
                lock.lock()
                openStreams[id] = OpenStream(continuation: continuation, sleeper: sleeper)
                lock.unlock()
                continuation.onTermination = { [weak self] _ in
                    sleeper.cancel()
                    self?.removeOpenStream(id)
                }
            } else {
                continuation.finish()
            }
        }
    }

    private func popDelay(path: String) -> Duration? {
        lock.lock()
        defer { lock.unlock() }
        guard var queue = delays[path], !queue.isEmpty else { return nil }
        let delay = queue.removeFirst()
        delays[path] = queue
        return delay
    }

    private func removeOpenStream(_ id: UUID) {
        lock.lock()
        openStreams.removeValue(forKey: id)
        lock.unlock()
    }

    // The helpers below run with the lock held unless they say so.

    private func mintSessionLocked() -> String {
        minted += 1
        let session = "ory_st_\(minted)"
        sessions.insert(session)
        return session
    }

    private func mintTokenLocked(_ yard: YardState) -> String {
        let token = "yardr-dev-\(yard.yard)-\(yard.tokens.count + 1)"
        yard.tokens.insert(token)
        return token
    }

    /// Answers a recorded request. Takes the lock itself. The
    /// byte route pops a queued answer itself, so it asks for none
    /// here.
    private func answerLocked(recorded: RecordedRequest, popOverrides: Bool = true) -> FakeResponse {
        lock.lock()
        defer { lock.unlock() }
        let path = recorded.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? recorded.path
        if popOverrides, var queue = overrides[path], !queue.isEmpty {
            let response = queue.removeFirst()
            overrides[path] = queue
            return response
        }
        if path == "/kratos/self-service/login/api" && recorded.method == "GET" {
            minted += 1
            return FakeResponse.json(200, "{\"id\": \"flow-\(minted)\", \"type\": \"api\", \"ui\": {\"action\": \"\(origin)/kratos/self-service/login?flow=x\", \"method\": \"POST\", \"nodes\": []}}")
        }
        if path == "/kratos/self-service/login" && recorded.method == "POST" {
            return loginLocked(recorded)
        }
        if path == "/kratos/self-service/logout/api" && recorded.method == "DELETE" {
            return logoutLocked(recorded)
        }
        if path.hasPrefix("/user/") {
            return userLocked(path: path, recorded: recorded)
        }
        return FakeResponse(status: 404, text: "404 page not found\n")
    }

    private func loginLocked(_ recorded: RecordedRequest) -> FakeResponse {
        if expired > 0 {
            expired -= 1
            return FakeResponse.json(410, #"{"error": {"id": "self_service_flow_expired", "code": 410, "status": "Gone", "message": "The self-service flow expired"}}"#)
        }
        let body = recorded.bodyObject()
        guard (body["identifier"] as? String) == email, (body["password"] as? String) == password else {
            return FakeResponse.json(400, #"{"id": "flow-x", "ui": {"messages": [{"id": 4000006, "text": "The provided credentials are invalid, check for spelling mistakes in your password or username, email address, or phone number.", "type": "error"}], "nodes": []}}"#)
        }
        let session = mintSessionLocked()
        return FakeResponse.json(200, "{\"session_token\": \"\(session)\", \"session\": {\"id\": \"s-1\", \"active\": true, \"identity\": {\"id\": \"i-1\", \"traits\": {\"email\": \"\(email)\", \"handle\": \"jo\"}}}}")
    }

    private func logoutLocked(_ recorded: RecordedRequest) -> FakeResponse {
        guard let session = recorded.bodyObject()["session_token"] as? String, sessions.remove(session) != nil else {
            return FakeResponse.json(401, #"{"error": {"code": 401, "status": "Unauthorized", "message": "No valid session credentials found in the request."}}"#)
        }
        return FakeResponse(status: 204)
    }

    /// The gates of a stream, with the lock held: a response where
    /// the stream is refused before it opens, nil where it opens.
    private func streamGateLocked(recorded: RecordedRequest) -> FakeResponse? {
        // A stream with no edge headers is a yard of its own, reached
        // directly: the home yard, with its device tokens.
        guard let session = recorded.header("X-Edge-Token") else {
            return directStreamGateLocked(recorded: recorded)
        }
        guard sessions.contains(session) else {
            return FakeResponse.signedOut()
        }
        let named = recorded.header("X-Edge-Yard") ?? ""
        guard let yard = yards.first(where: { $0.name == named }) else {
            return FakeResponse.notReady("the account holds no yard of that name")
        }
        let path = "/user/events"
        if var queue = yardOverrides[named + "\u{1}" + path], !queue.isEmpty {
            let response = queue.removeFirst()
            yardOverrides[named + "\u{1}" + path] = queue
            return response
        }
        if let handler = alwaysHandlers[named + "\u{1}" + path] {
            return handler()
        }
        return tokenGateLocked(yard: yard, recorded: recorded)
    }

    private func directStreamGateLocked(recorded: RecordedRequest) -> FakeResponse? {
        if recorded.header("X-Edge-Yard") != nil {
            return FakeResponse(status: 400, text: "no edge is spoken to here\n")
        }
        let path = "/user/events"
        if var queue = yardOverrides["\u{1}" + path], !queue.isEmpty {
            let response = queue.removeFirst()
            yardOverrides["\u{1}" + path] = queue
            return response
        }
        if let handler = alwaysHandlers["\u{1}" + path] {
            return handler()
        }
        return tokenGateLocked(yard: home, recorded: recorded)
    }

    /// The yard's gate, with the lock held: the device token, or the
    /// refusal where it is missing or the yard knows it not.
    private func tokenGateLocked(yard: YardState, recorded: RecordedRequest) -> FakeResponse? {
        guard let authorization = recorded.header("Authorization"), authorization.hasPrefix("Bearer ") else {
            return FakeResponse(status: 401, text: "Unauthorized\n")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard yard.tokens.contains(token) else {
            return FakeResponse(status: 401, text: "Unauthorized\n")
        }
        return nil
    }

    private func userLocked(path: String, recorded: RecordedRequest) -> FakeResponse {
        // A call with no edge headers is a yard of its own, reached
        // directly: the home yard, with its pairing and its device tokens.
        guard let session = recorded.header("X-Edge-Token") else {
            return directLocked(path: path, recorded: recorded)
        }
        // The edge's gate first: a session Kratos knows, then the
        // yard the account names by X-Edge-Yard.
        guard sessions.contains(session) else {
            return FakeResponse.signedOut()
        }
        let named = recorded.header("X-Edge-Yard") ?? ""
        guard let yard = yards.first(where: { $0.name == named }) else {
            return FakeResponse.notReady("the account holds no yard of that name")
        }
        return serveLocked(yard: yard, named: named, path: path, recorded: recorded)
    }

    private func directLocked(path: String, recorded: RecordedRequest) -> FakeResponse {
        if recorded.header("X-Edge-Yard") != nil {
            return FakeResponse(status: 400, text: "no edge is spoken to here\n")
        }
        return serveLocked(yard: home, named: "", path: path, recorded: recorded)
    }

    private func serveLocked(yard: YardState, named: String, path: String, recorded: RecordedRequest, viaChannel: Bool = false) -> FakeResponse {
        if var queue = yardOverrides[named + "\u{1}" + path], !queue.isEmpty {
            let response = queue.removeFirst()
            yardOverrides[named + "\u{1}" + path] = queue
            return response
        }
        if let handler = alwaysHandlers[named + "\u{1}" + path] {
            return handler()
        }
        if !viaChannel, path == "/user/pair" {
            return pairLocked(yard: yard, recorded: recorded)
        }
        if !viaChannel, path == "/user/e2e" {
            return e2eLocked(yard: yard, named: named, recorded: recorded)
        }
        // The router's push doors stand before the yard's gate: a
        // voucher is checked there, and no probe is made of a
        // token, as the router now answers them (bead 6).
        if path == "/user/push/register" || path == "/user/push/unregister" {
            return pushLocked(path: path, named: named, recorded: recorded)
        }
        // Then the yard's: the device token, or the channel the
        // call came sealed inside, which is its credential.
        if !viaChannel, let gated = tokenGateLocked(yard: yard, recorded: recorded) {
            return gated
        }
        if path.hasPrefix("/user/blobs/") {
            let hash = String(path.dropFirst("/user/blobs/".count))
            guard let bytes = yard.blobs[hash] else {
                return FakeResponse(status: 404, text: "not found\n")
            }
            return FakeResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], body: bytes)
        }
        if path == "/user/push/voucher" {
            // The yard issues a voucher to a sealed call alone.
            guard viaChannel else {
                return FakeResponse(status: 403, text: "a push registration voucher is issued only to a call sealed to this yard's channel key, never to a plain one\n")
            }
            return FakeResponse.json(200, "{\"voucher\": \"yardr-voucher-fake.\(named)\"}")
        }
        if path == "/user/me" {
            let coordinator = yard.coordinator.map { ", \"yardmaster\": \"\($0)\"" } ?? ""
            return FakeResponse.json(200, "{\"user\": \"\(yard.user)\", \"said_by\": \"\(yard.device)\", \"yard\": \"\(yard.yard)\"\(coordinator)}")
        }
        if path == "/user/events" {
            return FakeResponse(status: 200, headers: ["Content-Type": "application/x-ndjson"], body: Data())
        }
        if path == "/user/call/RegisterChannelKey" {
            // A pre-release device registers its channel key in
            // place (yardr-n9d2): under its token, plainly, once.
            // A sealed call is refused before its body is read.
            if viaChannel {
                return FakeResponse.json(200, #"{"error": {"code": "conflict", "message": "the device pins a channel key already"}}"#)
            }
            guard let text = recorded.bodyObject()["channel_key"] as? String,
                  (try? parseChannelPublic(text)) != nil
            else {
                return FakeResponse.json(200, #"{"error": {"code": "error", "message": "a channel key is the base64url of a 32-byte X25519 public key"}}"#)
            }
            // The device whose token this is, by the gate it passed.
            let token = recorded.header("Authorization").map { String($0.dropFirst("Bearer ".count)) } ?? ""
            if yard.pinned[token] != nil {
                return FakeResponse.json(200, #"{"error": {"code": "conflict", "message": "the device pins a channel key already"}}"#)
            }
            if yard.pinned.values.contains(text) {
                return FakeResponse.json(200, #"{"error": {"code": "conflict", "message": "another device pins that channel key"}}"#)
            }
            yard.pinned[token] = text
            return FakeResponse.json(200, "{\"result\": {\"user\": \"\(yard.user)\", \"device\": \"\(yard.device)\", \"channel_key\": \"\(yard.channelPublic)\", \"channel_signature\": \"fake-signature\", \"yard_key\": \"fake-yard-key\"}}")
        }
        if path.hasPrefix("/user/call/") {
            let method = String(path.dropFirst("/user/call/".count))
            let body = recorded.bodyObject()
            // One stray name refuses the call, the first by order.
            if let takes = yard.takes[method], let stray = body.keys.filter({ !takes.contains($0) }).min() {
                let list = takes.isEmpty ? "none" : takes.joined(separator: ", ")
                // As yardr's `named` words it: a call of its OperatorCalls
                // does not say the name, since a secret might be in it.
                let message = FakeYard.operatorCalls.contains(method)
                    ? "an argument: \(method) has none of that name (it takes \(list))"
                    : "argument \"\(stray)\": \(method) has none of that name (it takes \(list))"
                return FakeResponse.refused(message)
            }
            let bead = body["bead"] as? String
            let canned = (method == "Bead" ? bead.flatMap { Canned.beads[$0] } : nil)
                ?? Canned.replies[method]
                ?? "{\"error\": {\"code\": \"error\", \"message\": \"no such method \(method)\"}}"
            return FakeResponse.json(200, canned)
        }
        return FakeResponse(status: 401, text: "Unauthorized\n")
    }

    /// The router's push doors, as the relay answers them now: a
    /// yard-signed voucher in place of the device token, checked
    /// here, and no probe made of one. A platform and a token at
    /// registration, as they always were.
    private func pushLocked(path: String, named: String, recorded: RecordedRequest) -> FakeResponse {
        guard let authorization = recorded.header("Authorization"),
              authorization.hasPrefix("Bearer yardr-voucher-")
        else {
            return FakeResponse.json(401, #"{\"error\": \"edge: a yard-signed registration voucher is required\"}"#)
        }
        if path == "/user/push/unregister" {
            guard recorded.method == "POST" else {
                return FakeResponse(status: 405, text: "method not allowed\n")
            }
            pushRows.removeValue(forKey: named)
            return FakeResponse.json(200, #"{\"status\": \"unregistered\"}"#)
        }
        let body = recorded.bodyObject()
        guard recorded.method == "POST",
              (body["platform"] as? String) == "apns",
              let token = body["token"] as? String, !token.isEmpty
        else {
            return FakeResponse.json(400, #"{\"error\": \"edge: a registration names its platform (apns or fcm) and its push token\"}"#)
        }
        pushRows[named] = token
        return FakeResponse.json(200, #"{\"status\": \"registered\"}"#)
    }

    /// One outer call of a channel, as the yard answers it down
    /// the link: a handshake where it names no call, and an
    /// enveloped call opened and served as its inner call, with
    /// the answer sealed the same way. The channel key, not the
    /// token, authenticates it.
    private func e2eLocked(yard: YardState, named: String, recorded: RecordedRequest) -> FakeResponse {
        guard let callHeader = recorded.header("X-Edge-E2E-Call") else {
            // A handshake: the device it proves must be one this
            // yard has pinned, or no session is made.
            let handshake: YardChannelHandshake
            do {
                handshake = try YardChannelHandshake(yardPrivate: yard.channelPrivate, first: recorded.body)
            } catch {
                return FakeResponse(status: 400, text: "Bad Request\n")
            }
            guard yard.pinned.values.contains(handshake.deviceKey) else {
                return FakeResponse(status: 401, text: "Unauthorized\n")
            }
            do {
                let tag = try newCallID()
                let reply = try handshake.sealAnswer(tag: tag)
                guard let session = handshake.session else {
                    return FakeResponse(status: 500, text: "Internal Server Error\n")
                }
                yard.channelSessions[base64URL(tag)] = session
                return FakeResponse(status: 200, headers: ["X-Edge-E2E": "handshake"], body: reply)
            } catch {
                return FakeResponse(status: 500, text: "Internal Server Error\n")
            }
        }
        guard let call = dataFromBase64URL(callHeader),
              let tag = firstRecordTag(recorded.body),
              let session = yard.channelSessions[base64URL(tag)]
        else {
            return FakeResponse(status: 401, text: "Unauthorized\n")
        }
        let marker = recorded.header("X-Edge-E2E-Stream") ?? ""
        let present = recorded.headers.keys.contains("x-edge-e2e-stream")
        let plain: Data
        do {
            plain = try session.openWhole(run: recorded.body, call: call, marker: marker, present: present)
        } catch {
            return FakeResponse(status: 400, text: "Bad Request\n")
        }
        guard let head = sealedHeadObject(plain) else {
            return FakeResponse(status: 400, text: "Bad Request\n")
        }
        let innerBody = Data(plain.dropFirst(4 + Int(bigEndian32(plain))))
        let innerPath = (head["path"] as? String) ?? ""
        let innerPathOnly = innerPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? innerPath
        var innerHeaders: [String: String] = [:]
        if let header = head["header"] as? [String: [String]] {
            for (name, values) in header {
                innerHeaders[name.lowercased()] = values.joined(separator: ",")
            }
        }
        let inner = RecordedRequest(
            method: (head["method"] as? String) ?? "GET",
            path: innerPath,
            headers: innerHeaders,
            body: innerBody
        )
        let response = serveLocked(yard: yard, named: named, path: innerPathOnly, recorded: inner, viaChannel: true)
        do {
            let headData = try sealedHeadData(status: response.status, headers: response.headers)
            let run = try session.sealWhole(
                call: call, marker: marker, present: present,
                plaintext: joinSealed(head: headData, body: response.body)
            )
            return FakeResponse(status: 200, headers: ["X-Edge-E2E": "sealed"], body: run)
        } catch {
            return FakeResponse(status: 500, text: "Internal Server Error\n")
        }
    }

    /// A sealed stream's outer call, answered as a byte stream:
    /// its request opened whole, then the next script's lines
    /// sealed record by record under its call, closed by the
    /// final record unless the script hangs.
    private func sealedStream(recorded: RecordedRequest) -> (AsyncThrowingStream<UInt8, Error>, HTTPHead) {
        let refused = { (response: FakeResponse) in
            (self.finiteStream(response.body), response.head)
        }
        guard let sessionHeader = recorded.header("X-Edge-Token"), sessions.contains(sessionHeader) else {
            return refused(FakeResponse.signedOut())
        }
        let named = recorded.header("X-Edge-Yard") ?? ""
        guard let yard = yards.first(where: { $0.name == named }) else {
            return refused(FakeResponse.notReady("the account holds no yard of that name"))
        }
        guard let callHeader = recorded.header("X-Edge-E2E-Call"),
              let call = dataFromBase64URL(callHeader),
              let tag = firstRecordTag(recorded.body),
              let session = yard.channelSessions[base64URL(tag)]
        else {
            return refused(FakeResponse(status: 401, text: "Unauthorized\n"))
        }
        let marker = recorded.header("X-Edge-E2E-Stream") ?? ""
        let present = recorded.headers.keys.contains("x-edge-e2e-stream")
        guard let plain = try? session.openWhole(run: recorded.body, call: call, marker: marker, present: present),
              let head = sealedHeadObject(plain),
              (head["path"] as? String)?.hasPrefix("/user/events") == true
        else {
            return refused(FakeResponse(status: 400, text: "Bad Request\n"))
        }
        let script: StreamScript
        lock.lock()
        if streamScripts.isEmpty {
            script = StreamScript(lines: [])
        } else {
            script = streamScripts.removeFirst()
        }
        lock.unlock()
        let sealer = session.sealer(call: call, marker: marker, present: present)
        return (sealedScriptStream(sealer: sealer, script: script), HTTPHead(status: 200, headers: [:]))
    }

    private func sealedScriptStream(sealer: SealedSealer, script: StreamScript) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            do {
                let head = try sealedHeadData(status: 200, headers: ["Content-Type": "application/x-ndjson"])
                for byte in try sealer.seal(joinSealed(head: head, body: Data())) {
                    continuation.yield(byte)
                }
                for line in script.lines {
                    for byte in try sealer.seal(Data((line + "\n").utf8)) {
                        continuation.yield(byte)
                    }
                }
                if script.hang {
                    let id = UUID()
                    let sleeper = Task {
                        try? await Task.sleep(for: .seconds(3600))
                        continuation.finish()
                    }
                    lock.lock()
                    openStreams[id] = OpenStream(continuation: continuation, sleeper: sleeper)
                    lock.unlock()
                    continuation.onTermination = { [weak self] _ in
                        sleeper.cancel()
                        self?.removeOpenStream(id)
                    }
                } else {
                    for byte in try sealer.sealFinal() {
                        continuation.yield(byte)
                    }
                    continuation.finish()
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// The tag a record run's first message carries, or nil where
    /// the run holds none.
    private func firstRecordTag(_ run: Data) -> Data? {
        guard run.count >= 4 + 16 else { return nil }
        let length = Int(bigEndian32(run))
        guard length >= 16, run.count >= 4 + length else { return nil }
        return run.subdata(in: 4..<(4 + 16))
    }

    /// An inner head as `sealedHead` wrote it, read back.
    private func sealedHeadObject(_ plain: Data) -> [String: Any]? {
        guard plain.count >= 4 else { return nil }
        let length = Int(bigEndian32(plain))
        guard plain.count >= 4 + length else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain.subdata(in: 4..<(4 + length)))) as? [String: Any]
    }

    /// An inner answer's head, as the yard seals it: its status
    /// and its headers, told to the device alone.
    private func sealedHeadData(status: Int, headers: [String: String]) throws -> Data {
        var header: [String: [String]] = [:]
        for (name, value) in headers {
            header[name] = [value]
        }
        return try JSONSerialization.data(withJSONObject: ["status": status, "header": header], options: [.sortedKeys])
    }

    /// A pairing redeemed sealed: the code inside a Noise
    /// handshake to this yard's channel key, the device recorded
    /// with the key the handshake proved, and the answer sealed
    /// in reply with a voucher beside the token.
    private func pairSealedLocked(yard: YardState, open: String, sealed: String) -> FakeResponse {
        guard let first = dataFromBase64URL(sealed) else {
            return FakeResponse(status: 400, text: "Bad Request\n")
        }
        let handshake: YardPairingHandshake
        do {
            handshake = try YardPairingHandshake(yardPrivate: yard.channelPrivate, first: first)
        } catch {
            return FakeResponse(status: 400, text: "Bad Request\n")
        }
        let normalized = handshake.code.replacingOccurrences(of: "-", with: "").uppercased()
        let expected = open.replacingOccurrences(of: "-", with: "").uppercased()
        guard normalized == expected else {
            return FakeResponse.wrongCode()
        }
        yard.code = nil
        let token = mintTokenLocked(yard)
        yard.pinned[token] = handshake.deviceKey
        let answer = "{\"token\": \"\(token)\", \"user\": \"\(yard.user)\", \"device\": \"\(yard.device)\", \"yard\": \"\(yard.yard)\", \"voucher\": \"yardr-voucher-fake\"}"
        do {
            let reply = try handshake.sealAnswer(Data(answer.utf8))
            return FakeResponse.json(200, "{\"sealed\": \"\(base64URL(reply))\"}")
                .withHeader("Cache-Control", "no-store")
        } catch {
            return FakeResponse(status: 500, text: "Internal Server Error\n")
        }
    }

    /// A PAKE step as the yard answers it: `{"pake": {...}}` with the
    /// fields the step names.
    private func pakeReply(_ fields: [String: String]) -> FakeResponse {
        let body = try! JSONSerialization.data(withJSONObject: ["pake": fields], options: [.sortedKeys])
        return FakeResponse.json(200, String(decoding: body, as: UTF8.self))
    }

    /// A typed code redeemed through a PAKE, as the yard serves it
    /// (docs/users.md, "By a typed code, through a PAKE"): three
    /// posts of one run on the code of the pairing it has open. A
    /// message that does not open is 400 and no try; a confirmation
    /// that does not hold is 403 `wrong_code` and spends the run; a
    /// finish of a confirmed run spends it whatever it carries, and
    /// redeems with the device's key pinned and the yard's own key
    /// beside the token, sealed under the run's key.
    private func pairPAKELocked(yard: YardState, open: String, ask: [String: Any]) -> FakeResponse {
        let bad = FakeResponse(status: 400, text: "Bad Request\n")
        func field(_ name: String) -> String { ask[name] as? String ?? "" }
        switch field("step") {
        case "start":
            guard let first = dataFromBase64URL(field("msg")),
                  let handshake = try? YardPAKEHandshake(code: open, first: first)
            else { return bad }
            let session = base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
            yard.pake = PAKERun(session: session, handshake: handshake)
            return pakeReply(["step": "exchange", "session": session, "msg": base64URL(handshake.second)])
        case "confirm":
            guard let run = yard.pake, run.session == field("session"),
                  let confirm = dataFromBase64URL(field("confirm"))
            else { return bad }
            if let held = run.deviceConfirmation {
                // A repeated valid confirmation gets the same answer
                // if a relay lost it; any other is no live step.
                guard held == confirm else { return bad }
                return pakeReply(["step": "confirmed", "confirm": base64URL(run.yardConfirmation)])
            }
            do {
                run.yardConfirmation = try run.handshake.confirm(confirm)
                run.deviceConfirmation = confirm
            } catch let failure as ChannelFailure where failure.unconfirmed {
                yard.pake = nil
                return FakeResponse.wrongCode()
            } catch {
                yard.pake = nil
                return bad
            }
            return pakeReply(["step": "confirmed", "confirm": base64URL(run.yardConfirmation)])
        case "finish":
            guard let run = yard.pake, run.session == field("session"), run.deviceConfirmation != nil else { return bad }
            yard.pake = nil
            guard let sealedKey = dataFromBase64URL(field("key")),
                  let deviceKey = try? run.handshake.openKey(sealedKey)
            else { return bad }
            yard.code = nil
            let token = mintTokenLocked(yard)
            yard.pinned[token] = deviceKey
            let answer = "{\"token\": \"\(token)\", \"user\": \"\(yard.user)\", \"device\": \"\(yard.device)\", \"yard\": \"\(yard.yard)\", \"voucher\": \"yardr-voucher-fake\", \"channel_key\": \"\(yard.channelPublic)\"}"
            guard let reply = try? run.handshake.sealAnswer(Data(answer.utf8)) else {
                return FakeResponse(status: 500, text: "Internal Server Error\n")
            }
            return pakeReply(["step": "done", "answer": base64URL(reply)])
                .withHeader("Cache-Control", "no-store")
        default:
            return bad
        }
    }

    private func pairLocked(yard: YardState, recorded: RecordedRequest) -> FakeResponse {
        guard let open = yard.code else {
            return FakeResponse(status: 401, text: "Unauthorized\n")
        }
        if let ask = recorded.bodyObject()["pake"] as? [String: Any] {
            return pairPAKELocked(yard: yard, open: open, ask: ask)
        }
        if let sealed = recorded.bodyObject()["sealed"] as? String {
            return pairSealedLocked(yard: yard, open: open, sealed: sealed)
        }
        guard let code = recorded.bodyObject()["code"] as? String else {
            return FakeResponse(status: 400, text: "no code\n")
        }
        let normalized = code.replacingOccurrences(of: "-", with: "").uppercased()
        let expected = open.replacingOccurrences(of: "-", with: "").uppercased()
        guard normalized == expected else {
            return FakeResponse.wrongCode()
        }
        yard.code = nil
        let token = mintTokenLocked(yard)
        return FakeResponse.json(200, "{\"token\": \"\(token)\", \"user\": \"\(yard.user)\", \"device\": \"\(yard.device)\", \"yard\": \"\(yard.yard)\"}")
            .withHeader("Cache-Control", "no-store")
    }
}
