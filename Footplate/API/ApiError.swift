import Foundation

// Why a request did not answer, as design 3.1 reads it. Every call and
// the stream throw one of these and nothing else of their own. No message
// holds a token or a password: what is said comes from the status, the
// edge's sentence or the yard's, never from the request.
enum ApiError: Error, Equatable, Sendable {
    /// The edge refused the session (401 with `X-Edge-Refusal: session`):
    /// sign in again. The device token is kept.
    case notSignedIn
    /// The yard refused the device token (401 without the edge's word):
    /// pair again.
    case notLetIn
    /// The yard has no device at all: 404 to a call. Pair again.
    case noDevice
    /// A yard is kept under the pairing's name already (`title` what the
    /// head line calls it): forget it first. Thrown by the pairer before
    /// anything is sent, never read from an answer.
    case nameKept(title: String)
    /// The connected yard's link is down (503 `away`), or a hosted yard's
    /// container did not answer (the edge's 502).
    case away
    /// The edge's link to the yard is full (429 `busy`), or the yard holds
    /// as many streams of this device as it takes (its own 503 with
    /// `Retry-After`). Not asked again before `retryAfter`.
    case busy(retryAfter: Duration)
    /// The edge holds no ready yard by that name (its 403): `why` is the
    /// edge's sentence without `edge: `.
    case notReady(why: String)
    /// The edge's own trouble: its 503, with the edge's body.
    case edgeDown(why: String)
    /// The yard took more than the edge's 30 seconds (the edge's 504). A
    /// call is not made again by itself.
    case slow
    /// The yard, or Kratos, said no: `message` is a sentence for a person,
    /// shown, never parsed.
    case refused(code: String, message: String)
    /// Nothing answers: no connection, a stream that went silent, or an
    /// answer no row of 3.1 reads. `why` is what was found, in a few words.
    case down(why: String)
    /// What came back is not what docs/api.md says.
    case `protocol`(what: String)

    var message: String {
        switch self {
        case .notSignedIn: return "this session is no longer signed in"
        case .notLetIn: return "this device is no longer let in"
        case .noDevice: return "the yard has no device"
        case .nameKept(let title): return "\(title) is paired already. Forget it first to pair another yard of the same name."
        case .away: return "the yard is away"
        case .busy(let retryAfter): return "the yard is busy, again after \(retryAfter)"
        case .notReady(let why): return "the yard is not ready: \(why)"
        case .edgeDown(let why): return "the edge is down: \(why)"
        case .slow: return "the yard took too long to answer"
        case .refused(_, let message): return message
        case .down(let why): return "nothing answers: \(why)"
        case .protocol(let what): return "an answer footplate cannot read: \(what)"
        }
    }

    var caseName: String {
        switch self {
        case .notSignedIn: return "NotSignedIn"
        case .notLetIn: return "NotLetIn"
        case .noDevice: return "NoDevice"
        case .nameKept: return "NameKept"
        case .away: return "Away"
        case .busy: return "Busy"
        case .notReady: return "NotReady"
        case .edgeDown: return "EdgeDown"
        case .slow: return "Slow"
        case .refused: return "Refused"
        case .down: return "Down"
        case .protocol: return "Protocol"
        }
    }
}

extension ApiError: CustomStringConvertible {
    var description: String { "\(caseName): \(message)" }
}

extension ApiError: LocalizedError {
    var errorDescription: String? { message }
}

/// The yard's code for a server about to start a newer build of itself:
/// the call did not run, and is made again.
let replacingCode = "replacing"

/// What `Retry-After` is read as where it is missing or unreadable.
let defaultRetryAfter: Duration = .seconds(5)

/// The shape of a body that is not a 2xx, or of a yard's refusal on 200.
enum Shape: Equatable, Sendable {
    /// `{"error": {"code", "message"}}`: the yard's.
    case yard(code: String, message: String)
    /// `{"error": "edge: …"}`: the edge's, `why` without the prefix.
    case edge(why: String)
    /// Neither: no JSON, or JSON of neither shape.
    case neither
}

private let edgePrefix = "edge:"

func bodyShape(_ body: String) -> Shape {
    guard let data = body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = object["error"] else {
        return .neither
    }
    if let yard = error as? [String: Any] {
        return .yard(
            code: yard["code"] as? String ?? "",
            message: yard["message"] as? String ?? ""
        )
    }
    if let text = error as? String, text.hasPrefix(edgePrefix) {
        let why = String(text.dropFirst(edgePrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return .edge(why: why)
    }
    return .neither
}

/// `Retry-After` in seconds; 5 where it is missing, unreadable (an HTTP
/// date included) or not above 0.
func retryAfterDuration(_ header: String?) -> Duration {
    guard let header else { return defaultRetryAfter }
    let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seconds = Int64(trimmed), seconds > 0 else { return defaultRetryAfter }
    return .seconds(seconds)
}

/// Reads an answer as 3.1's table does, the first row that matches
/// deciding: `X-Edge-Refusal` first, which only the edge sets; then the
/// body's shape, an `error` object being the yard's and an `error` string
/// beginning `edge: ` the edge's; the status alone last. Nil for an answer
/// that is no refusal (a 2xx with no `error`). A yard's `replacing` comes
/// back as `.refused` with that code, for the caller to make again.
/// `stream` is whether it answered `/user/events`, where a 503 of neither
/// shape is the yard's own limit of streams.
func refusal(status: Int, edgeRefusal: String?, retryAfterHeader: String?, body: String, stream: Bool = false) -> ApiError? {
    switch edgeRefusal?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "session": return .notSignedIn
    case "away": return .away
    case "busy": return .busy(retryAfter: retryAfterDuration(retryAfterHeader))
    default: break
    }
    switch bodyShape(body) {
    case .yard(let code, let message):
        return .refused(code: code, message: message)
    case .edge(let why):
        switch status {
        case 403: return .notReady(why: why)
        case 502: return .away
        case 503: return .edgeDown(why: why)
        case 504: return .slow
        default: return .down(why: "the edge answered status \(status): \(why)")
        }
    case .neither:
        break
    }
    if (200...299).contains(status) { return nil }
    if status == 401 { return .notLetIn }
    if status == 404 { return .noDevice }
    // The yard's own 503 carries a line of plain text: on the stream
    // it is the device's 16 streams, with or without a readable
    // Retry-After. A Retry-After alone does not identify a call's 503.
    if status == 503 && stream {
        return .busy(retryAfter: retryAfterDuration(retryAfterHeader))
    }
    return .down(why: "status \(status)")
}
