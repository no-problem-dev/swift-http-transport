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

@Suite("existential を generic に渡せること")
struct AnyStreamingTransportTests {
    /// The shape a composition root actually has.
    ///
    /// `RetryingTransport` being generic is what keeps the streaming capability when a transport is
    /// wrapped — but it also means an existential cannot be passed directly, because an existential
    /// does not conform to the protocol it erases. A caller storing `any HTTPTransport &
    /// HTTPStreamingTransport`, which is the ordinary shape for an injected dependency, needs a box.
    @Test func wrapsAnExistentialAndKeepsStreaming() async throws {
        let mock = MockTransport(
            [.response(HTTPResponse(status: 200, headers: [:], body: Data("ok".utf8)))],
            streamChunks: [Data("ok".utf8)])
        let erased: any HTTPTransport & HTTPStreamingTransport = AnyStreamingTransport(mock)

        let retrying = RetryingTransport(base: AnyStreamingTransport(erased), policy: NoRetry())
        let response = try await retrying.send(HTTPRequest(method: "GET", url: URL(string: "https://x.dev")!))
        #expect(response.status == 200)

        // The point of the box: `stream` survives the wrap. This line not compiling is the failure.
        var chunks: [Data] = []
        for try await chunk in retrying.stream(HTTPRequest(method: "GET", url: URL(string: "https://x.dev")!)) {
            chunks.append(chunk)
        }
        #expect(chunks.joined().isEmpty == false)
    }
}
