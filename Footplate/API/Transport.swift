import Foundation

// The transport seam of design 3.7: data for a request, and a byte stream
// for a request. `URLSession` implements it for the app; the fake yard in
// the tests implements the same seam in-process, so the client is proved
// without the network.

/// An answer's head: its status and its headers, read case-insensitively.
struct HTTPHead: Equatable, Sendable {
    let status: Int
    /// Header values by lowercased name.
    let headers: [String: String]

    init(status: Int, headers: [String: String]) {
        self.status = status
        var lowered: [String: String] = [:]
        for (name, value) in headers {
            lowered[name.lowercased()] = value
        }
        self.headers = lowered
    }

    init(status: Int, allHeaderFields: [AnyHashable: Any]) {
        self.status = status
        var lowered: [String: String] = [:]
        for (name, value) in allHeaderFields {
            lowered["\(name)".lowercased()] = "\(value)"
        }
        self.headers = lowered
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// One origin's transport. Cancelling the Swift task cancels the request;
/// a network failure is thrown as `ApiError.down`, never with a token.
protocol HTTPTransport: Sendable {
    /// Sends one request and reads its answer whole.
    func data(for request: URLRequest) async throws -> (Data, HTTPHead)
    /// Sends one request and opens its answer as a byte stream. The head
    /// is known before the first byte is read.
    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPHead)
}

/// Thrown where an origin or a token cannot stand in a request. Its words
/// name no value, as a token in an error would give it away.
struct InvalidValueError: Error, Equatable, Sendable, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Whether `token` can stand in a request's head: one line of visible
/// characters, as a device's token and a session's are.
func isToken(_ token: String) -> Bool {
    !token.isEmpty && token.allSatisfy { $0 >= "!" && $0 <= "~" }
}

func requireToken(_ token: String) throws {
    guard isToken(token) else {
        throw InvalidValueError("a token is one line of visible characters")
    }
}

func requireName(_ name: String) throws {
    guard name.isEmpty || isToken(name) else {
        throw InvalidValueError("a yard's name is one word of visible characters")
    }
}

private let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]

/// What a network failure says: the connection failed, or nothing came in
/// time. Its words name the host and never a header.
func downError(_ error: Error) -> ApiError {
    if let api = error as? ApiError { return api }
    if let url = error as? URLError {
        if url.code == .timedOut { return .down(why: "no answer in time") }
        return .down(why: url.localizedDescription)
    }
    return .down(why: String(describing: type(of: error)))
}

/// Re-throws a transport failure as the caller reads it: cancellation
/// stays cancellation, the rest becomes `ApiError`.
func mapTransportError(_ error: Error) throws -> Never {
    if error is CancellationError { throw CancellationError() }
    if let url = error as? URLError, url.code == .cancelled { throw CancellationError() }
    throw downError(error)
}

/// Refuses every redirect, as the Android client does, so the password
/// and the tokens reach the built edge alone.
final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// The app's transport: a dedicated `URLSession` with a 30-second request
/// timeout and no waiting for connectivity, so a yard away is said at
/// once rather than held by the system. Nothing retries a call by itself;
/// the follower and the screens decide what is tried again.
final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectRefuser = RedirectRefuser()

    init() {
        session = URLSession(configuration: Self.configuration(), delegate: redirectRefuser, delegateQueue: nil)
    }

    /// The session's settings. Ephemeral, with no cache and no cookies,
    /// as the Android client has neither: an answer read with a token
    /// (a blob, who the device is) is kept on no disk, and nothing the
    /// edge sets rides on a later request.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return configuration
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPHead) {
        do {
            let (body, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApiError.protocol(what: "an answer with no status")
            }
            return (body, HTTPHead(status: http.statusCode, allHeaderFields: http.allHeaderFields))
        } catch {
            try mapTransportError(error)
        }
    }

    func bytes(for request: URLRequest) async throws -> (AsyncThrowingStream<UInt8, Error>, HTTPHead) {
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApiError.protocol(what: "an answer with no status")
            }
            let head = HTTPHead(status: http.statusCode, allHeaderFields: http.allHeaderFields)
            let bytes = AsyncThrowingStream<UInt8, Error> { continuation in
                let task = Task {
                    do {
                        for try await byte in stream {
                            continuation.yield(byte)
                        }
                        continuation.finish()
                    } catch {
                        if error is CancellationError {
                            continuation.finish(throwing: CancellationError())
                        } else if let url = error as? URLError, url.code == .cancelled {
                            continuation.finish(throwing: CancellationError())
                        } else {
                            continuation.finish(throwing: downError(error))
                        }
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return (bytes, head)
        } catch {
            try mapTransportError(error)
        }
    }
}

/// The origin as a URL with no path: `https://`, or `http://` for a host
/// that is this machine, which the tests' fake yard is (docs/api.md, "TLS
/// is yours, and the client's rule").
func originURL(_ origin: String) throws -> URL {
    guard let url = URL(string: origin),
          let scheme = url.scheme?.lowercased(),
          let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil,
          url.path.isEmpty || url.path == "/"
    else {
        throw InvalidValueError("the edge's origin is a scheme, a host and a port alone")
    }
    let isHTTPS = scheme == "https"
    let isLoopbackHTTP = scheme == "http" && loopbackHosts.contains(host.lowercased())
    guard isHTTPS || isLoopbackHTTP else {
        throw InvalidValueError("the edge's origin is https, or http on this machine alone")
    }
    return url
}
