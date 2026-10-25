@testable import Footplate
import Foundation

// The fake yard of design 3.7: one account at a fake edge, in-process,
// with Kratos's sign-in and logout, two yards told apart by X-Edge-Yard,
// a pairing open in each, every call of 3.1 answered with docs/api.md's
// examples, and the edge's and the yard's refusals on demand. It
// records every request, so a test asserts what a call carried. It
// implements the same transport seam as URLSession, so no socket is
// opened; URLSession's own framing is proved by the loopback smoke
// test alone.

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
        var code: String?
        var tokens: Set<String> = []
        var blobs: [String: Data] = [:]

        init(name: String, user: String, device: String, yard: String, code: String?) {
            self.name = name
            self.user = user
            self.device = device
            self.yard = yard
            self.code = code
        }
    }

    /// The yards of the account: the own one (no X-Edge-Yard) and
    /// laptop.
    let home = YardState(name: "", user: "jo", device: "phone", yard: "south", code: "K7QM-2XPD")
    let laptop = YardState(name: "laptop", user: "jo", device: "pixel", yard: "laptop", code: "M4TR-9KWE")

    private let lock = NSLock()
    private var yards: [YardState] { [home, laptop] }
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

    func edge() throws -> Edge {
        try Edge(origin: origin, transport: self)
    }

    /// A session the edge knows, as a sign-in would have made.
    func session() -> String {
        lock.lock()
        defer { lock.unlock() }
        return mintSessionLocked()
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
        return (response.body, response.head)
    }

    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPHead) {
        let recorded = record(request)
        let path = recordedURL(request).path
        if let response = popOverride(path: path) {
            return (finiteStream(response.body), response.head)
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
        guard let session = recorded.header("X-Edge-Token"), sessions.contains(session) else {
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
        // The edge's gate first: a session Kratos knows, then the
        // yard the account names by X-Edge-Yard.
        guard let session = recorded.header("X-Edge-Token"), sessions.contains(session) else {
            return FakeResponse.signedOut()
        }
        let named = recorded.header("X-Edge-Yard") ?? ""
        guard let yard = yards.first(where: { $0.name == named }) else {
            return FakeResponse.notReady("the account holds no yard of that name")
        }
        if var queue = yardOverrides[named + "\u{1}" + path], !queue.isEmpty {
            let response = queue.removeFirst()
            yardOverrides[named + "\u{1}" + path] = queue
            return response
        }
        if let handler = alwaysHandlers[named + "\u{1}" + path] {
            return handler()
        }
        if path == "/user/pair" {
            return pairLocked(yard: yard, recorded: recorded)
        }
        // Then the yard's: the device token.
        guard let authorization = recorded.header("Authorization"), authorization.hasPrefix("Bearer ") else {
            return FakeResponse(status: 401, text: "Unauthorized\n")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard yard.tokens.contains(token) else {
            return FakeResponse(status: 401, text: "Unauthorized\n")
        }
        if path.hasPrefix("/user/blobs/") {
            let hash = String(path.dropFirst("/user/blobs/".count))
            guard let bytes = yard.blobs[hash] else {
                return FakeResponse(status: 404, text: "not found\n")
            }
            return FakeResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], body: bytes)
        }
        if path == "/user/me" {
            return FakeResponse.json(200, "{\"user\": \"\(yard.user)\", \"said_by\": \"\(yard.device)\", \"yard\": \"\(yard.yard)\"}")
        }
        if path == "/user/events" {
            return FakeResponse(status: 200, headers: ["Content-Type": "application/x-ndjson"], body: Data())
        }
        if path.hasPrefix("/user/call/") {
            let method = String(path.dropFirst("/user/call/".count))
            let bead = recorded.bodyObject()["bead"] as? String
            let canned = (method == "Bead" ? bead.flatMap { Canned.beads[$0] } : nil)
                ?? Canned.replies[method]
                ?? "{\"error\": {\"code\": \"error\", \"message\": \"no such method \(method)\"}}"
            return FakeResponse.json(200, canned)
        }
        return FakeResponse(status: 401, text: "Unauthorized\n")
    }

    private func pairLocked(yard: YardState, recorded: RecordedRequest) -> FakeResponse {
        guard let open = yard.code else {
            return FakeResponse(status: 401, text: "Unauthorized\n")
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
