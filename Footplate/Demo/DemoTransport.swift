import Foundation

// The demo yard's transport (Try a demo): an `HTTPTransport` compiled into
// the app, so the app's own client, follower and screens read a yard that
// is a `DemoYard` in memory. It answers what a paired device asks of a
// yard (`/user/me`, `/user/call/<Method>`, `/user/events`, `/user/blobs/`)
// in the shapes docs/api.md has, and nothing else: it opens no socket and
// holds no `URLSession`, so no request leaves the phone. A write changes
// the yard and leaves its event on every open stream, as a real yard's
// stream tells every device of it.

final class DemoTransport: HTTPTransport, @unchecked Sendable {
    /// The origin the demo's edge is made with. `.invalid` is reserved to
    /// name no host (RFC 2606), so a request that ever reached the network
    /// would find nothing to send it to.
    static let origin = "https://demo.invalid"

    /// How often an open stream is told it is alive, as the edge's empty
    /// line does every 30 seconds: the follower ends a stream that says
    /// nothing for 75.
    static let heartbeat: Duration = .seconds(25)

    private let lock = NSLock()
    private var yard: DemoYard
    private var listeners: [UUID: AsyncThrowingStream<UInt8, Error>.Continuation] = [:]
    private var served: [String] = []
    private let heartbeat: Duration

    init(heartbeat: Duration = DemoTransport.heartbeat, now: @escaping @Sendable () -> Date = { Date() }) {
        self.heartbeat = heartbeat
        yard = DemoYard(now: now)
    }

    /// Every request this transport answered, as `POST /user/call/Mail`,
    /// oldest first: what the tests read to say what a demo asked for.
    var requests: [String] {
        lock.withLock { served }
    }

    /// How many streams are open now: none once the demo is left.
    var streams: Int {
        lock.withLock { listeners.count }
    }

    // MARK: - HTTPTransport

    func data(for request: URLRequest) async throws -> (Data, HTTPHead) {
        let reply = serve(request)
        return (reply.body, reply.head)
    }

    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPHead) {
        guard request.url?.path == "/user/events" else {
            let reply = serve(request)
            return (finite(reply.body), reply.head)
        }
        note("\(request.httpMethod ?? "GET") /user/events")
        let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
        let after = query?.first { $0.name == "after" }?.value.flatMap { Int64($0) } ?? 0
        let stream = AsyncThrowingStream<UInt8, Error> { continuation in
            let id = UUID()
            // The listener stands and the backlog is told in one hold of
            // the lock, so an event written meanwhile follows it and none
            // is told twice or out of order.
            lock.withLock {
                for event in yard.events where event.seq > after {
                    tell(event, to: continuation)
                }
                listeners[id] = continuation
            }
            let beat = Task { [self, heartbeat] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: heartbeat)
                    if Task.isCancelled { return }
                    // Whole under the lock, as an event is, so it never
                    // falls inside a line.
                    lock.withLock { _ = continuation.yield(0x0A) }
                }
            }
            continuation.onTermination = { [weak self] _ in
                beat.cancel()
                self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) }
            }
        }
        return (stream, HTTPHead(status: 200, headers: ["Content-Type": "application/x-ndjson"]))
    }

    // MARK: - The routes

    private struct Reply {
        var status: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data

        var head: HTTPHead { HTTPHead(status: status, headers: headers) }
    }

    private func serve(_ request: URLRequest) -> Reply {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        note("\(method) \(path)")
        if method == "GET", path == "/user/me" {
            return Reply(body: encoded(withYard { $0.me }))
        }
        if method == "GET", path.hasPrefix("/user/blobs/") {
            let hash = String(path.dropFirst("/user/blobs/".count))
            guard let bytes = withYard({ $0.blob(hash: hash) }) else {
                return Reply(status: 404, headers: ["Content-Type": "text/plain"], body: Data("not found\n".utf8))
            }
            return Reply(headers: ["Content-Type": "application/octet-stream"], body: bytes)
        }
        if method == "POST", path.hasPrefix("/user/call/") {
            let args = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
            return call(String(path.dropFirst("/user/call/".count)), args)
        }
        // A path no device asks of a yard: nothing is hidden behind it.
        return Reply(status: 404, headers: ["Content-Type": "text/plain"], body: Data("404 page not found\n".utf8))
    }

    private func call(_ method: String, _ args: [String: Any]) -> Reply {
        switch method {
        case "Head":
            return result(withYard { $0.head })
        case "Settings":
            return result(withYard { $0.settings })
        case "GetUser":
            return result(withYard { $0.user(args.text("name")) })
        case "Crew":
            return result(withYard { $0.crew })
        case "Users":
            return result(withYard { $0.users })
        case "UserInbox":
            return result(withYard { $0.inbox(limit: args.number("limit")) })
        case "Conversation":
            let page = withYard {
                $0.conversation(a: args.text("a"), b: args.text("b"), limit: args.number("limit"), before: args.number("before"))
            }
            return result(page.letters, more: page.more)
        case "Mail":
            let files = (args["files"] as? [[String: Any]] ?? []).map {
                MailFile(hash: $0.text("hash"), name: $0.text("name"))
            }
            withYard { $0.mail(to: args.text("to"), text: args.text("text"), files: files) }
            return done
        case "AckUserInbox":
            withYard { $0.ackInbox(through: args.number("through")) }
            return done
        case "UserNotifications":
            return result(withYard { $0.notifications })
        case "AckUserNotifications":
            withYard { $0.ackNotifications(through: args.number("through")) }
            return done
        case "UserAsks":
            return result(withYard { $0.asks })
        case "Bead":
            let id = args.text("bead")
            guard let bead = withYard({ $0.bead(id) }) else {
                return refused("no_bead", "The demo yard holds no bead \(id).")
            }
            return result(bead)
        case "Flows":
            return result(withYard { $0.flows })
        case "AnswerAsk":
            let (bead, ask) = (args.text("bead"), args.number("ask"))
            return withYard({ $0.answer(bead: bead, ask: ask, option: args.number("option"), words: args.text("words")) })
                ? done : notOpen
        case "DeferAsk":
            return withYard({ $0.putAside(bead: args.text("bead"), ask: args.number("ask")) }) ? done : notOpen
        case "DeclineAsk":
            return withYard({ $0.decline(bead: args.text("bead"), ask: args.number("ask"), words: args.text("words")) })
                ? done : notOpen
        case "PutBlob":
            guard let bytes = Data(base64Encoded: args.text("data")) else {
                return refused("no_data", "That file could not be read.")
            }
            return result(withYard { $0.putBlob(bytes) })
        default:
            // The cards that ask for a secret, a command or a setup are
            // not in this yard, so these are never asked.
            return refused("not_in_demo", "The demo yard does not take that call.")
        }
    }

    // MARK: - Answers

    private var done: Reply { Reply(body: Data("{}".utf8)) }

    private var notOpen: Reply {
        refused("not_open", "That question is not open any more.")
    }

    /// The yard's refusal, `{"error": {"code", "message"}}`, which the
    /// client reads whatever the status.
    private func refused(_ code: String, _ message: String) -> Reply {
        Reply(status: 400, body: encoded(["error": ["code": code, "message": message]]))
    }

    /// `{"result": value}`, with `more` beside it where a page says it.
    private func result<T: Encodable>(_ value: T, more: Bool? = nil) -> Reply {
        var body = Data("{\"result\":".utf8)
        body.append(encoded(value))
        if let more {
            body.append(Data(",\"more\":\(more)".utf8))
        }
        body.append(Data("}".utf8))
        return Reply(body: body)
    }

    private func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data("null".utf8)
    }

    private func finite(_ data: Data) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream { continuation in
            for byte in data {
                continuation.yield(byte)
            }
            continuation.finish()
        }
    }

    // MARK: - The yard, and its stream

    private func note(_ request: String) {
        lock.withLock { served.append(request) }
    }

    /// Runs `body` on the yard, and tells every open stream the events it
    /// left, whole and in order, before another call can touch the yard.
    @discardableResult
    private func withYard<T>(_ body: (inout DemoYard) -> T) -> T {
        lock.withLock {
            let before = yard.events.count
            let result = body(&yard)
            for event in yard.events[before...] {
                for continuation in listeners.values {
                    tell(event, to: continuation)
                }
            }
            return result
        }
    }

    /// One event as a line. Called with the lock held.
    private func tell(_ event: Event, to continuation: AsyncThrowingStream<UInt8, Error>.Continuation) {
        for byte in encoded(event) + [0x0A] {
            continuation.yield(byte)
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func text(_ key: String) -> String {
        self[key] as? String ?? ""
    }

    func number(_ key: String) -> Int64 {
        (self[key] as? NSNumber)?.int64Value ?? 0
    }
}
