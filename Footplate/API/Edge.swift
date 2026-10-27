import Foundation

// One origin every request through it goes to (design 3.2): the edge
// the app was built for, with Kratos's sign-in, logout and session
// identity lookup, the pairing, and through
// `yard(device:session:name:)` every /user/* call and the stream; or a
// yard of its own, at the address typed, with `pairDirect` and
// `yardDirect` and no edge's headers. Nothing scanned changes it, and
// no redirect is followed, so the password and the tokens reach this
// origin alone.

let clientHeaderName = "X-Yardr-Client"
let edgeTokenHeader = "X-Edge-Token"
let edgeYardHeader = "X-Edge-Yard"
let edgeRefusalHeader = "X-Edge-Refusal"
let jsonContentType = "application/json"

/// An answer read whole: its status, the headers 3.1 reads, its body.
struct Answer: Sendable {
    let status: Int
    let edgeRefusal: String?
    let retryAfter: String?
    let data: Data

    var body: String {
        String(data: data, encoding: .utf8) ?? ""
    }

    init(status: Int, head: HTTPHead, data: Data) {
        self.status = status
        self.edgeRefusal = head.header(edgeRefusalHeader)
        self.retryAfter = head.header("Retry-After")
        self.data = data
    }
}

func jsonBody(_ object: [String: Any]) throws -> Data {
    do {
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    } catch {
        throw ApiError.protocol(what: "a request that cannot be written")
    }
}

func jsonObject(_ body: String) -> [String: Any]? {
    guard let data = body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

final class Edge: Sendable {
    let base: URL
    /// The origin, as `https://host[:port]`, for a sentence.
    let origin: String
    let transport: any HTTPTransport
    /// The `X-Yardr-Client` value on every request.
    let client: String

    init(origin: String, transport: any HTTPTransport, version: String? = nil) throws {
        base = try originURL(origin)
        var text = base.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        self.origin = text
        self.transport = transport
        let resolved = version
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0"
        client = "footplate-ios/\(resolved)"
    }

    /// The app's edge: the one place an origin is built from, read from
    /// the built `EDGE_URL`. No other code builds a URL from an origin.
    static func live(transport: any HTTPTransport = URLSessionTransport()) throws -> Edge {
        let origin = (Bundle.main.object(forInfoDictionaryKey: "EDGE_URL") as? String) ?? "https://my.yardr.dev"
        return try Edge(origin: origin, transport: transport)
    }

    /// Signs the account in with Kratos's API flow for native clients:
    /// one flow is opened, and the password method answers it. A flow
    /// the edge forgot meanwhile (410) is opened once more; one
    /// forgotten twice is said, not tried a third time. The password is
    /// in the request's body and in nothing else: no error, no log, no
    /// field kept.
    func signIn(email: String, password: String) async throws -> SignedIn {
        let flow = try await loginFlow()
        do {
            return try await submitLogin(flow: flow, email: email, password: password)
        } catch is ExpiredFlow {
            do {
                return try await submitLogin(flow: try await loginFlow(), email: email, password: password)
            } catch is ExpiredFlow {
                throw ApiError.refused(
                    code: "bad_sign_in",
                    message: "The sign-in expired before it was sent. Sign in again."
                )
            }
        }
    }

    /// Ends the session at Kratos: the token is no longer known to the
    /// edge, and every call carrying it is refused from then on.
    func logout(session: String) async throws {
        try requireToken(session)
        var request = makeRequest(path: "/kratos/self-service/logout/api")
        request.httpMethod = "DELETE"
        request.setValue(jsonContentType, forHTTPHeaderField: "Accept")
        request.setValue(jsonContentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonBody(["session_token": session])
        let answer = try await exchange(request)
        if answer.status == 204 { return }
        throw edgeOr(answer) {
            ApiError.refused(code: "no_logout", message: "The edge did not end the session: status \(answer.status).")
        }
    }

    /// The handle of an already-kept session, for accounts saved before
    /// the app began keeping it beside the display name. The token goes
    /// only to this edge, as it does on every /user call.
    func accountHandle(session: String) async throws -> String {
        try requireToken(session)
        var request = makeRequest(path: "/kratos/sessions/whoami")
        request.httpMethod = "GET"
        request.setValue(jsonContentType, forHTTPHeaderField: "Accept")
        request.setValue(session, forHTTPHeaderField: edgeTokenHeader)
        let answer = try await exchange(request)
        guard answer.status == 200 else {
            throw edgeOr(answer) {
                ApiError.refused(code: "no_account_handle", message: "The edge did not identify the account.")
            }
        }
        guard let identity = jsonObject(answer.body)?["identity"] as? [String: Any],
              let traits = identity["traits"] as? [String: Any],
              let raw = traits["handle"] as? String
        else {
            throw ApiError.protocol(what: "the edge's account identity has no handle")
        }
        let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !handle.isEmpty else {
            throw ApiError.protocol(what: "the edge's account identity has no handle")
        }
        return handle
    }

    /// Redeems a pairing code at the yard named `yard` (empty: the
    /// account's own yard, as the edge reads a call without
    /// `X-Edge-Yard`), with the session beside it and no device token.
    /// The code goes as it was typed; the yard reads it without its dash
    /// and in either case.
    func pair(code: String, session: String, yard: String = "") async throws -> Paired {
        try requireToken(session)
        try requireName(yard)
        var request = makeRequest(path: "/user/pair")
        request.httpMethod = "POST"
        request.setValue(session, forHTTPHeaderField: edgeTokenHeader)
        if !yard.isEmpty {
            request.setValue(yard, forHTTPHeaderField: edgeYardHeader)
        }
        request.setValue(jsonContentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonBody(["code": code])
        let answer = try await exchange(request)
        // The edge's answers first, by its header and then its body's
        // shape: the edge's 403 is a yard not ready, never a wrong code.
        if answer.edgeRefusal != nil || isEdgeShape(answer.body) {
            throw refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body)
                ?? ApiError.protocol(what: "the pairing: status \(answer.status)")
        }
        return try paired(answer)
    }

    /// Redeems a pairing code at a yard of its own, with no edge: the
    /// code to `<address>/user/pair`, with neither a session nor a
    /// yard's name beside it, and no device token. What refuses speaks
    /// of the yard, as the yard's answers do.
    func pairDirect(code: String) async throws -> Paired {
        var request = makeRequest(path: "/user/pair")
        request.httpMethod = "POST"
        request.setValue(jsonContentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonBody(["code": code])
        let answer = try await exchange(request)
        // No edge stands in front: the yard's `refused` and its
        // statuses alone, and an `error` object of its own elsewhere.
        if let refused = pairRefused(answer.body) {
            throw pairingRefused(refused)
        }
        switch answer.status {
        case 200:
            return try decodePaired(answer.data)
        case 400:
            throw pairingRefused("no_code")
        case 409:
            throw pairingRefused("not_added")
        case 401, 404:
            throw pairingRefused("no_pairing")
        default:
            if case .yard(let yardCode, let message) = bodyShape(answer.body) {
                throw ApiError.refused(code: yardCode, message: message)
            }
            throw ApiError.down(why: "status \(answer.status)")
        }
    }

    /// The calls of one paired yard, as its device: `device` is the
    /// token the pairing answered, `session` the edge's, `name` the
    /// yard's name at the edge (empty: the account's own yard, and no
    /// `X-Edge-Yard` is sent).
    func yard(device: String, session: String, name: String = "") throws -> YardClient {
        try YardClient(edge: self, device: device, session: session, name: name)
    }

    /// The calls of one paired yard of its own, as its device:
    /// `device` the token the pairing answered, carried alone, with
    /// no edge's headers.
    func yardDirect(device: String) throws -> YardClient {
        try YardClient(edge: self, device: device, session: "", name: "")
    }

    /// A pairing's answer read, past the edge's answers: the yard's
    /// `refused`, its four statuses, and anywhere else the table.
    private func paired(_ answer: Answer) throws -> Paired {
        if let refused = pairRefused(answer.body) {
            throw pairingRefused(refused)
        }
        switch answer.status {
        case 200:
            return try decodePaired(answer.data)
        case 400:
            throw pairingRefused("no_code")
        case 409:
            throw pairingRefused("not_added")
        case 401, 404:
            throw pairingRefused("no_pairing")
        default:
            throw refusal(status: answer.status, edgeRefusal: nil, retryAfterHeader: answer.retryAfter, body: answer.body)
                ?? ApiError.protocol(what: "the pairing: status \(answer.status)")
        }
    }

    private func pairRefused(_ body: String) -> String? {
        jsonObject(body)?["refused"] as? String
    }

    private func decodePaired(_ data: Data) throws -> Paired {
        let paired: Paired
        do {
            paired = try JSONDecoder().decode(Paired.self, from: data)
        } catch {
            throw ApiError.protocol(what: "the pairing: \(String(describing: type(of: error)))")
        }
        guard isToken(paired.token) else {
            throw ApiError.protocol(what: "the pairing: no token in the answer")
        }
        return paired
    }

    /// A request to `path` under the origin, with the client's name.
    func makeRequest(path: String) -> URLRequest {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = path
        var request = URLRequest(url: components.url!)
        request.setValue(client, forHTTPHeaderField: clientHeaderName)
        return request
    }

    /// Sends one request and reads its answer whole. Cancelling the
    /// caller cancels the request.
    func exchange(_ request: URLRequest) async throws -> Answer {
        let (data, head) = try await transport.data(for: request)
        return Answer(status: head.status, head: head, data: data)
    }

    private struct ExpiredFlow: Error {}

    private func loginFlow() async throws -> String {
        var request = makeRequest(path: "/kratos/self-service/login/api")
        request.httpMethod = "GET"
        request.setValue(jsonContentType, forHTTPHeaderField: "Accept")
        let answer = try await exchange(request)
        if answer.status != 200 {
            throw edgeOr(answer) { noSignIn("status \(answer.status)") }
        }
        let id = jsonObject(answer.body)?["id"] as? String
        guard let id, isToken(id) else {
            throw noSignIn("an answer with no flow")
        }
        return id
    }

    private func submitLogin(flow: String, email: String, password: String) async throws -> SignedIn {
        // The flow's own action names the same URL by the edge's shape,
        // and is not read for where to send the password.
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = "/kratos/self-service/login"
        components.queryItems = [URLQueryItem(name: "flow", value: flow)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(client, forHTTPHeaderField: clientHeaderName)
        request.setValue(jsonContentType, forHTTPHeaderField: "Accept")
        request.setValue(jsonContentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = try jsonBody([
            "method": "password",
            "identifier": email,
            "password": password,
        ])
        let answer = try await exchange(request)
        switch answer.status {
        case 200:
            return try signedIn(body: answer.body, email: email)
        case 400:
            let why = kratosErrors(answer.body).first ?? "the edge refused it with no reason"
            throw ApiError.refused(
                code: "bad_sign_in",
                message: "The sign-in failed: \(why). Check the email and password, and sign in again."
            )
        case 410:
            throw ExpiredFlow()
        default:
            throw edgeOr(answer) { noSignIn("status \(answer.status)") }
        }
    }

    private func signedIn(body: String, email: String) throws -> SignedIn {
        guard let answered = jsonObject(body) else {
            throw noSignIn("an answer that cannot be read")
        }
        guard let session = answered["session_token"] as? String, isToken(session) else {
            throw noSignIn("an answer with no session token")
        }
        let traits = ((answered["session"] as? [String: Any])?["identity"] as? [String: Any])?["traits"] as? [String: Any]
        // A trait's first line, trimmed; empty where it is no string or says nothing.
        func trait(_ key: String) -> String {
            guard let raw = traits?[key] as? String else { return "" }
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        // The account is named by its email, else its handle, else what
        // was typed; the handle is kept apart too, since the edge names
        // the account's own yard by it.
        let handle = trait("handle")
        let account = [trait("email"), handle].first { !$0.isEmpty } ?? email
        return SignedIn(session: session, account: account, handle: handle)
    }

    private func noSignIn(_ why: String) -> ApiError {
        ApiError.refused(
            code: "no_sign_in",
            message: "No sign-in answers at \(origin): \(why). Sign in again."
        )
    }
}

/// Whether the body's shape is the edge's (`{"error": "edge: …"}`).
func isEdgeShape(_ body: String) -> Bool {
    if case .edge = bodyShape(body) { return true }
    return false
}

/// The edge's own refusal where the answer is one (its header, or its
/// body's shape), else `otherwise`: Kratos's answers have shapes of
/// their own, so only the edge's are read by 3.1's table.
func edgeOr(_ answer: Answer, otherwise: () -> ApiError) -> ApiError {
    if answer.edgeRefusal != nil || isEdgeShape(answer.body) {
        return refusal(status: answer.status, edgeRefusal: answer.edgeRefusal, retryAfterHeader: answer.retryAfter, body: answer.body) ?? otherwise()
    }
    return otherwise()
}

/// The pairing's own sentences, by the yard's `refused`.
func pairingRefused(_ code: String) -> ApiError {
    let message: String
    switch code {
    case "wrong_code":
        message = "That is not the code. The yard counts a wrong one, and the fifth ends the pairing."
    case "not_added":
        message = "The code was right and is used up, but the yard could not add the device. Its operator opens another pairing."
    case "no_code":
        message = "That is no code: a code is eight letters and digits, as the yard printed them."
    case "no_pairing":
        message = "No pairing is open at this yard: none was opened, or the code was used, ran out or was ended. Its operator opens one: yardr user device pair <user> <device>"
    default:
        message = "The yard refused the pairing: \(code)."
    }
    return .refused(code: code, message: message)
}

/// What a refused login flow says: its messages, then each field's, in
/// Kratos's words.
func kratosErrors(_ body: String) -> [String] {
    guard let ui = jsonObject(body)?["ui"] as? [String: Any] else { return [] }
    func texts(_ value: Any?) -> [String] {
        guard let messages = value as? [[String: Any]] else { return [] }
        return messages.compactMap { ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    var result = texts(ui["messages"])
    if let nodes = ui["nodes"] as? [[String: Any]] {
        for node in nodes {
            result += texts(node["messages"])
        }
    }
    return result
}
