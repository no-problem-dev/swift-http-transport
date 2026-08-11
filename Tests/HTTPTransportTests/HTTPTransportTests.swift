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

    @Test("a value is never left unreachable behind an earlier spelling of the same name")
    func repeatedNameCollapsesToTheLastValue() {
        let headers = HTTPHeaders([("Set-Cookie", "a"), ("set-cookie", "b")])
        #expect(headers["set-cookie"] == "b")
        #expect(headers["Set-Cookie"] == "b")
        #expect(headers.pairs.count == 1)
    }

    @Test("equality is reflexive even when the same name was supplied twice")
    func equalityIsReflexive() {
        let fromArray = HTTPHeaders([("Set-Cookie", "a"), ("set-cookie", "b")])
        let fromLiteral: HTTPHeaders = ["Set-Cookie": "a", "set-cookie": "b"]
        #expect(fromArray == fromArray)
        #expect(fromLiteral == fromLiteral)
        #expect(fromArray == fromLiteral)
    }

    @Test("initialising is the same as setting each pair in turn")
    func initialisingMatchesRepeatedSubscriptAssignment() {
        var built = HTTPHeaders()
        built["A"] = "1"
        built["B"] = "2"
        built["a"] = "3"
        #expect(HTTPHeaders([("A", "1"), ("B", "2"), ("a", "3")]) == built)
        #expect(built.pairs.map(\.name) == ["B", "a"])
    }

    @Test("equal headers differing only in field order and name case compare equal")
    func equalityIgnoresOrderAndNameCase() {
        let one = HTTPHeaders([("Accept", "json"), ("X-Id", "1")])
        let other = HTTPHeaders([("x-id", "1"), ("accept", "json")])
        #expect(one == other)
        #expect(other == one)
        #expect(one != HTTPHeaders([("Accept", "json"), ("X-Id", "2")]))
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
        // GET, not POST: this checks the 429 path, and a non-idempotent request
        // is never replayed regardless of status. See RetryReplaySafetyTests.
        let response = try await retrying.send(HTTPRequest(method: "GET", url: url))
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

/// ``MockTransport/stream(_:)`` has to be able to fail, or streaming failure
/// handling in callers is never exercised by anyone's tests.
struct MockTransportStreamingTests {
    private let url = URL(string: "https://example.com/stream")!

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async -> Result<[Data], any Error> {
        var chunks: [Data] = []
        do {
            for try await chunk in stream { chunks.append(chunk) }
            return .success(chunks)
        } catch {
            return .failure(error)
        }
    }

    @Test("scripted .failure fails the stream instead of completing empty")
    func streamPropagatesScriptedFailure() async {
        let transport = MockTransport([.failure(URLError(.timedOut))])
        let result = await collect(transport.stream(HTTPRequest(method: "GET", url: url)))
        guard case .failure(let error) = result else {
            Issue.record("スクリプトされた .failure がストリームを失敗させるべき")
            return
        }
        #expect((error as? URLError)?.code == .timedOut)
    }

    @Test("scripted non-2xx fails the stream with HTTPStatusError and yields nothing")
    func streamMapsScriptedNon2xxToHTTPStatusError() async {
        let transport = MockTransport([
            .response(HTTPResponse(status: 503, headers: ["retry-after": "1"], body: Data("down".utf8)))
        ])
        let result = await collect(transport.stream(HTTPRequest(method: "GET", url: url)))
        guard case .failure(let error) = result, let status = error as? HTTPStatusError else {
            Issue.record("HTTPStatusError を期待したが \(result) だった")
            return
        }
        #expect(status.status == 503)
        #expect(status.headers["Retry-After"] == "1")
    }

    @Test("the handler decides the streamed outcome too")
    func streamConsultsHandler() async {
        let transport = MockTransport { _ in throw URLError(.cannotFindHost) }
        let result = await collect(transport.stream(HTTPRequest(method: "GET", url: url)))
        guard case .failure(let error) = result else {
            Issue.record("handler の throw がストリームを失敗させるべき")
            return
        }
        #expect((error as? URLError)?.code == .cannotFindHost)
    }

    @Test("a scripted 2xx streams the configured chunks")
    func streamYieldsChunksOnScriptedSuccess() async {
        let transport = MockTransport(
            [.response(HTTPResponse(status: 200, headers: [:], body: Data()))],
            streamChunks: [Data("a".utf8), Data("b".utf8)]
        )
        let result = await collect(transport.stream(HTTPRequest(method: "GET", url: url)))
        guard case .success(let chunks) = result else {
            Issue.record("成功を期待したが \(result) だった")
            return
        }
        #expect(chunks.map { String(decoding: $0, as: UTF8.self) } == ["a", "b"])
    }

    @Test("an exhausted script still streams, so the simple streamChunks form keeps working")
    func streamSucceedsWhenNoOutcomeIsScripted() async {
        let transport = MockTransport(streamChunks: [Data("only".utf8)])
        let result = await collect(transport.stream(HTTPRequest(method: "GET", url: url)))
        guard case .success(let chunks) = result else {
            Issue.record("成功を期待したが \(result) だった")
            return
        }
        #expect(chunks.map { String(decoding: $0, as: UTF8.self) } == ["only"])
    }

    @Test("recordedRequests survives concurrent writers and readers")
    func recordedRequestsIsSafeUnderConcurrentAccess() async {
        let transport = MockTransport()
        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 40 {
                group.addTask {
                    _ = try? await transport.send(
                        HTTPRequest(method: "GET", url: URL(string: "https://example.com/\(index)")!)
                    )
                }
                group.addTask { _ = transport.recordedRequests.count }
            }
        }
        #expect(transport.recordedRequests.count == 40)
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

    private func snapshot(retryAfter value: String, format: RateLimitHeaderMapping.ResetFormat = .secondsRemaining) -> RateLimitSnapshot {
        RateLimitHeaderMapping(retryAfter: "retry-after", resetFormat: format)
            .extract(from: ["retry-after": value])
    }

    /// RFC 9110 §10.2.3 allows an HTTP-date as well as delay-seconds.
    @Test("the IMF-fixdate form of Retry-After becomes seconds from now")
    func parsesRetryAfterAsHTTPDate() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let text = formatter.string(from: Date().addingTimeInterval(120))

        let seconds = snapshot(retryAfter: text).retryAfter
        #expect(seconds != nil)
        #expect((seconds ?? -1) > 110 && (seconds ?? -1) <= 121)
    }

    /// RFC 9110 §5.6.7 requires recipients to accept two obsolete date forms too.
    @Test("the obsolete RFC 850 date form is accepted and clamped at zero once past")
    func parsesRetryAfterAsRFC850Date() {
        let parsed = snapshot(retryAfter: "Sunday, 06-Nov-94 08:49:37 GMT")
        #expect(parsed.retryAfter == 0)
        #expect(!parsed.isEmpty)
    }

    @Test("the obsolete asctime date form is accepted")
    func parsesRetryAfterAsAsctimeDate() {
        let seconds = snapshot(retryAfter: "Sun Nov  6 08:49:37 2094").retryAfter
        #expect(seconds != nil)
        #expect((seconds ?? 0) > 1_000_000_000)
    }

    @Test("a Retry-After already in the past means retry now, not 'no headers at all'")
    func pastRetryAfterIsZeroRatherThanNil() {
        let parsed = snapshot(retryAfter: "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(parsed.retryAfter == 0)
        #expect(!parsed.isEmpty)
    }

    @Test("a provider that spells resets as durations may spell Retry-After that way too")
    func parsesRetryAfterWithDurationSuffix() {
        #expect(snapshot(retryAfter: "1s", format: .durationSuffix).retryAfter == 1)
        #expect(snapshot(retryAfter: "1m30s", format: .durationSuffix).retryAfter == 90)
        // Plain seconds still win under the same mapping.
        #expect(snapshot(retryAfter: "2", format: .durationSuffix).retryAfter == 2)
    }

    @Test("genuinely unparseable values stay nil so isEmpty still means 'nothing was sent'")
    func unparseableRetryAfterLeavesTheSnapshotEmpty() {
        let parsed = snapshot(retryAfter: "not-a-date")
        #expect(parsed.retryAfter == nil)
        #expect(parsed.isEmpty)
    }

    @Test("a negative delay-seconds is treated as retry now")
    func negativeRetryAfterClampsToZero() {
        #expect(snapshot(retryAfter: "-5").retryAfter == 0)
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

    @Test("CRLF 行末のストリームでも行境界を検出する（Swift String の \\r\\n 1 書記素問題の回帰）")
    func parsesCRLFLineEndings() {
        var parser = SSEParser()
        let events = parser.consume(Data("event: delta\r\ndata: {\"x\":1}\r\n\r\ndata: b\r\n\r\n".utf8))
        #expect(events.count == 2)
        #expect(events[0].event == "delta")
        #expect(events[0].data == "{\"x\":1}")
        #expect(events[1].data == "b")
    }

    @Test("UTF-8 マルチバイト文字がチャンク境界で分断されても壊れない")
    func handlesMultibyteSplitAcrossChunks() {
        var parser = SSEParser()
        let payload = Array("data: こんにちは\n\n".utf8)
        // Cut the chunk in the middle of a 3-byte character
        let splitIndex = 9 // "data: " is 6 bytes + 3 for the next character
        var events = parser.consume(Data(payload[..<(splitIndex + 1)]))
        #expect(events.isEmpty)
        events = parser.consume(Data(payload[(splitIndex + 1)...]))
        #expect(events.count == 1)
        #expect(events[0].data == "こんにちは")
    }

    @Test("末尾改行なしで終わるストリームの最終イベントを finish で救う")
    func finishFlushesTrailingLineWithoutNewline() {
        var parser = SSEParser()
        let events = parser.consume(Data("data: tail".utf8))
        #expect(events.isEmpty)
        let last = parser.finish()
        #expect(last?.data == "tail")
    }
}
