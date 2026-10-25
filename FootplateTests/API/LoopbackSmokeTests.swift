@testable import Footplate
import Darwin
import Foundation
import XCTest

// The one smoke test of design 3.7: the fake yard proves the
// client's reading of every answer without proving URLSession's own
// framing, which this test covers against a minimal loopback
// listener in the test target. The listener is addressed by the
// localhost name, never a raw IP literal, so no ATS exception is
// needed and the app target carries none.

final class LoopbackSmokeTests: XCTestCase {
    func testHeadAndEventsOverLoopback() async throws {
        let listener = LoopbackListener()
        try listener.start()
        defer { listener.stop() }
        listener.serve(count: 2) { request in
            if request.contains("/user/events") {
                return LoopbackListener.httpResponse(
                    contentType: "application/x-ndjson",
                    body: "{\"seq\": 152, \"kind\": \"mail\", \"actor\": \"yardmaster\", \"data\": {\"text\": \"The shed is painted.\"}, \"at\": \"2026-10-08T09:30:00Z\"}\n\n{\"seq\": 153, \"kind\": \"noted\", \"actor\": \"yardmaster\", \"bead\": \"yd-shed\", \"data\": {\"note\": 1}, \"at\": \"2026-10-08T09:30:00Z\"}\n"
                )
            }
            return LoopbackListener.httpResponse(contentType: "application/json", body: "{\"result\": 151}")
        }

        let edge = try Edge(origin: "http://localhost:\(listener.port)", transport: URLSessionTransport())
        let yard = try edge.yard(device: "yardr-dev-south-1", session: "ory_st_1")
        let head = try await yard.head()
        XCTAssertEqual(head, 151)

        var events: [Event] = []
        for try await event in yard.events(after: 151) {
            events.append(event)
        }
        XCTAssertEqual(events.map(\.seq), [152, 153])
        XCTAssertEqual(events.first?.text("text"), "The shed is painted.")
    }
}

/// A minimal HTTP listener on a loopback port the system picks,
/// answering each accepted connection once and closing it.
private final class LoopbackListener: @unchecked Sendable {
    private var descriptor: Int32 = -1
    private(set) var port: Int = 0
    private var serving: Task<Void, Never>?

    func start() throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LoopbackError("socket") }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            throw LoopbackError("bind")
        }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(descriptor, sockaddrPointer, &length)
            }
        }
        guard named == 0 else { throw LoopbackError("getsockname") }
        port = Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    func serve(count: Int, responder: @escaping @Sendable (String) -> String) {
        let descriptor = self.descriptor
        serving = Task.detached {
            for _ in 0..<count {
                let connection = accept(descriptor, nil, nil)
                if connection < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 16384)
                let read = recv(connection, &buffer, buffer.count, 0)
                let request = read > 0 ? String(decoding: buffer[0..<read], as: UTF8.self) : ""
                let response = responder(request)
                let bytes = [UInt8](response.utf8)
                _ = bytes.withUnsafeBufferPointer { pointer in
                    send(connection, pointer.baseAddress, bytes.count, 0)
                }
                close(connection)
            }
        }
    }

    func stop() {
        serving?.cancel()
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    static func httpResponse(contentType: String, body: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    private struct LoopbackError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
