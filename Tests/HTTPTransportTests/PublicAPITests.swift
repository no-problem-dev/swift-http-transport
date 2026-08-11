import Foundation
import Testing

// Deliberately NOT `@testable`: these checks are about what a consumer of the
// shipped module can reach. `@testable` would grant internal visibility and hide
// exactly the defects this file exists to catch.
import HTTPTransport

/// Checks that the public surface is usable from outside the module.
struct PublicSurfaceTests {
    @Test("consumers can build an HTTPStatusError to fake a streaming failure")
    func httpStatusErrorIsConstructibleOutsideTheModule() {
        let error = HTTPStatusError(
            status: 429,
            headers: ["retry-after": "3"],
            body: Data("slow down".utf8)
        )
        #expect(error.status == 429)
        #expect(error.headers["Retry-After"] == "3")
        #expect(String(decoding: error.body, as: UTF8.self) == "slow down")
    }

    @Test("wrapping a streaming transport in RetryingTransport keeps it streaming")
    func retryingTransportPreservesTheStreamingCapability() async throws {
        let base = MockTransport(streamChunks: [Data("data: a\n\ndata: b\n\n".utf8)])
        let retrying = RetryingTransport(base: base, policy: NoRetry(), sleep: { _ in })
        let request = HTTPRequest(method: "GET", url: URL(string: "https://example.com/sse")!)

        var chunks = 0
        for try await _ in retrying.stream(request) { chunks += 1 }
        #expect(chunks == 1)

        var events: [String] = []
        for try await event in retrying.sseEvents(request) { events.append(event.data) }
        #expect(events == ["a", "b"])
    }

    @Test("a retrying wrapper is still usable where a plain transport is expected")
    func retryingTransportIsStillAnHTTPTransport() async throws {
        let transport: any HTTPTransport = RetryingTransport(
            base: MockTransport(status: 200, body: Data("ok".utf8)),
            policy: NoRetry(),
            sleep: { _ in }
        )
        let response = try await transport.send(HTTPRequest(method: "GET", url: URL(string: "https://example.com")!))
        #expect(String(decoding: response.body, as: UTF8.self) == "ok")
    }
}
