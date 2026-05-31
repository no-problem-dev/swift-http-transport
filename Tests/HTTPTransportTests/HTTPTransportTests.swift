import Foundation
import Testing
@testable import HTTPTransport

struct HeaderTests {
    @Test
    func caseInsensitiveLookupPreservesOrder() {
        var headers: HTTPHeaders = ["Content-Type": "application/json"]
        headers["X-Id"] = "1"
        #expect(headers["content-type"] == "application/json")
        #expect(headers["x-id"] == "1")
        #expect(headers.pairs.map(\.name) == ["Content-Type", "X-Id"])
    }
}

struct MockAndRetryTests {
    private let url = URL(string: "https://example.com/v1")!

    @Test
    func mockRecordsAndResponds() async throws {
        let transport = MockTransport(status: 200, body: Data("ok".utf8))
        let response = try await transport.send(HTTPRequest(method: "GET", url: url))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "ok")
        #expect(transport.recordedRequests.count == 1)
    }

    @Test
    func retriesOn429ThenSucceeds() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 429, headers: ["retry-after": "0"], body: Data())),
            .response(HTTPResponse(status: 200, headers: [:], body: Data("done".utf8))),
        ])
        let retrying = RetryingTransport(
            base: transport,
            policy: ExponentialBackoff(maxAttempts: 3),
            rateLimitMapping: RateLimitHeaderMapping(),
            sleep: { _ in }
        )
        let response = try await retrying.send(HTTPRequest(method: "POST", url: url))
        #expect(response.status == 200)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test
    func stopsAfterMaxAttempts() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 500, headers: [:], body: Data())),
            .response(HTTPResponse(status: 500, headers: [:], body: Data())),
        ])
        let retrying = RetryingTransport(base: transport, policy: ExponentialBackoff(maxAttempts: 2), sleep: { _ in })
        let response = try await retrying.send(HTTPRequest(method: "GET", url: url))
        #expect(response.status == 500)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test
    func noRetryStopsImmediately() async throws {
        let transport = MockTransport(status: 503)
        let retrying = RetryingTransport(base: transport, policy: NoRetry(), sleep: { _ in })
        let response = try await retrying.send(HTTPRequest(method: "GET", url: url))
        #expect(response.status == 503)
        #expect(transport.recordedRequests.count == 1)
    }
}

struct RateLimitTests {
    @Test
    func extractsHeadersWithDurationSuffix() {
        let mapping = RateLimitHeaderMapping(
            retryAfter: "retry-after",
            remainingRequests: "x-ratelimit-remaining-requests",
            requestsReset: "x-ratelimit-reset-requests",
            resetFormat: .durationSuffix
        )
        let headers: HTTPHeaders = [
            "retry-after": "2",
            "x-ratelimit-remaining-requests": "59",
            "x-ratelimit-reset-requests": "6m30s",
        ]
        let snapshot = mapping.extract(from: headers)
        #expect(snapshot.retryAfter == 2)
        #expect(snapshot.remainingRequests == 59)
        #expect(snapshot.requestsReset == 390)
    }

    @Test(arguments: [("1s", 1.0), ("500ms", 0.5), ("1m30s", 90.0), ("2h", 7200.0)])
    func parsesDurations(_ pair: (String, Double)) {
        #expect(RateLimitHeaderMapping.parseDuration(pair.0) == pair.1)
    }
}

struct SSETests {
    @Test
    func parsesMultiLineDataAndEventBoundaries() {
        var parser = SSEParser()
        let events = parser.consume(Data("event: delta\ndata: hello\ndata: world\n\nevent: done\ndata: {}\n\n".utf8))
        #expect(events.count == 2)
        #expect(events[0].event == "delta")
        #expect(events[0].data == "hello\nworld")
        #expect(events[1].event == "done")
        #expect(events[1].data == "{}")
    }

    @Test
    func handlesChunkSplitAcrossBoundary() {
        var parser = SSEParser()
        var events = parser.consume(Data("data: par".utf8))
        #expect(events.isEmpty)
        events = parser.consume(Data("tial\n\n".utf8))
        #expect(events.count == 1)
        #expect(events[0].data == "partial")
    }

    @Test
    func streamsSSEEventsFromMock() async throws {
        let transport = MockTransport(streamChunks: [Data("data: a\n\ndata: b\n\n".utf8)])
        var received: [String] = []
        for try await event in transport.sseEvents(HTTPRequest(method: "GET", url: URL(string: "https://x.io")!)) {
            received.append(event.data)
        }
        #expect(received == ["a", "b"])
    }
}
