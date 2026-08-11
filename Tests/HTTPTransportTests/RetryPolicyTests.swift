import Foundation
import Testing
@testable import HTTPTransport

/// Reads the wait out of a decision, so a random delay can be range-checked.
func retryDelay(_ decision: RetryDecision, _ comment: Comment = "リトライを期待した") -> TimeInterval? {
    guard case .retry(let delay) = decision else {
        Issue.record(comment)
        return nil
    }
    return delay
}

/// Table-driven checks of the backoff curve, its ceiling, the jitter window,
/// and where it gives up. The decision function is pure, so no I/O is needed.
struct ExponentialBackoffTests {
    /// The default curve at baseDelay 0.5 and maxDelay 30: an uncut backoff of
    /// min(0.5 x 2^(attempt-1), 30), from which a *random* share of up to 25% is
    /// taken. Only the window is fixed; the value inside it is not.
    private let policy = ExponentialBackoff(maxAttempts: 10, baseDelay: 0.5, maxDelay: 30)

    /// Pins the draw so the curve itself can be asserted exactly.
    private func pinned(_ fraction: Double) -> ExponentialBackoff {
        ExponentialBackoff(maxAttempts: 10, baseDelay: 0.5, maxDelay: 30, randomFraction: { fraction })
    }

    @Test(arguments: [(1, 0.5), (2, 1.0), (3, 2.0), (4, 4.0), (5, 8.0), (6, 16.0)])
    func backoffCurveDoublesPerAttemptWithinTheJitterWindow(_ pair: (Int, Double)) {
        let (attempt, uncut) = pair
        guard let delay = retryDelay(policy.decision(status: 500, error: nil, attempt: attempt, rateLimit: nil)) else { return }
        #expect(delay <= uncut)
        #expect(delay >= uncut * 0.75)
    }

    @Test(arguments: [(0.0, 1.0), (0.5, 0.875), (1.0, 0.75)])
    func theDrawPlacesTheDelayInTheWindow(_ pair: (Double, Double)) {
        let (draw, expectedShare) = pair
        let decision = pinned(draw).decision(status: 500, error: nil, attempt: 3, rateLimit: nil)
        #expect(retryDelay(decision) == 2.0 * expectedShare)
    }

    @Test(arguments: [7, 8, 9])
    func delayIsCappedAtMaxDelayBeforeJitter(_ attempt: Int) {
        // 0.5 x 2^6 = 32 exceeds maxDelay 30, so the window is 22.5...30
        guard let delay = retryDelay(policy.decision(status: 500, error: nil, attempt: attempt, rateLimit: nil)) else { return }
        #expect(delay <= 30)
        #expect(delay >= 22.5)
    }

    /// The reason jitter exists: clients that failed together must not come back
    /// together. A constant reduction — however it is named — spreads nothing,
    /// so the assertion has to be about the spread of many draws, never about
    /// one value being equal to something.
    @Test("repeated decisions spread across the jitter window instead of repeating one value")
    func jitterIsDrawnAfreshForEveryDecision() {
        let samples = (0 ..< 500).compactMap { _ in
            retryDelay(policy.decision(status: 500, error: nil, attempt: 5, rateLimit: nil))
        }
        #expect(samples.count == 500)

        let uncut = 8.0
        let floor = uncut * 0.75
        #expect(samples.allSatisfy { $0 >= floor && $0 <= uncut })

        // A constant reduction yields exactly one distinct value.
        #expect(Set(samples).count > 100)

        // Both halves of the window get used, so it is a spread and not a wobble.
        let midpoint = (floor + uncut) / 2
        #expect(samples.contains { $0 < midpoint })
        #expect(samples.contains { $0 > midpoint })

        // A uniform draw over the window has mean 0.875 x uncut.
        let mean = samples.reduce(0, +) / Double(samples.count)
        #expect(abs(mean - uncut * 0.875) < uncut * 0.03)
    }

    @Test("two clients failing at the same moment do not pick the same delay")
    func independentClientsDoNotAgreeOnADelay() {
        let one = (0 ..< 20).compactMap { _ in retryDelay(policy.decision(status: 500, error: nil, attempt: 4, rateLimit: nil)) }
        let other = (0 ..< 20).compactMap { _ in retryDelay(policy.decision(status: 500, error: nil, attempt: 4, rateLimit: nil)) }
        #expect(one != other)
    }

    @Test("jitterFraction 0 opts out of jitter entirely")
    func zeroJitterFractionGivesTheBareCurve() {
        let policy = ExponentialBackoff(maxAttempts: 10, baseDelay: 0.5, maxDelay: 30, jitterFraction: 0)
        #expect(retryDelay(policy.decision(status: 500, error: nil, attempt: 3, rateLimit: nil)) == 2.0)
    }

    @Test
    func stopsWhenAttemptReachesMaxAttempts() {
        let policy = ExponentialBackoff(maxAttempts: 3)
        #expect(policy.decision(status: 500, error: nil, attempt: 2, rateLimit: nil) != .stop)
        #expect(policy.decision(status: 500, error: nil, attempt: 3, rateLimit: nil) == .stop)
        #expect(policy.decision(status: 500, error: nil, attempt: 4, rateLimit: nil) == .stop)
    }

    @Test(arguments: [408, 425, 429, 500, 502, 503, 504])
    func retriesDefaultRetryableStatuses(_ status: Int) {
        #expect(retryDelay(pinned(1).decision(status: status, error: nil, attempt: 1, rateLimit: nil)) == 0.375)
    }

    @Test(arguments: [200, 201, 204, 301, 400, 401, 403, 404, 409, 422])
    func stopsOnNonRetryableStatuses(_ status: Int) {
        #expect(policy.decision(status: status, error: nil, attempt: 1, rateLimit: nil) == .stop)
    }

    @Test
    func retriesTransportErrorWithoutStatus() {
        let decision = pinned(1).decision(status: nil, error: URLError(.timedOut), attempt: 1, rateLimit: nil)
        #expect(retryDelay(decision) == 0.375)
    }

    @Test
    func stopsWhenNeitherStatusNorErrorIsPresent() {
        #expect(policy.decision(status: nil, error: nil, attempt: 1, rateLimit: nil) == .stop)
    }

    @Test
    func honorsRetryAfterExactlyWithoutJitter() {
        let decision = policy.decision(status: 429, error: nil, attempt: 1, rateLimit: RateLimitSnapshot(retryAfter: 2))
        #expect(decision == .retry(after: 2))
    }

    @Test
    func capsRetryAfterAtMaxDelay() {
        let decision = policy.decision(status: 429, error: nil, attempt: 1, rateLimit: RateLimitSnapshot(retryAfter: 100))
        #expect(decision == .retry(after: 30))
    }

    @Test
    func retryAfterIsIgnoredOnceMaxAttemptsIsReached() {
        let policy = ExponentialBackoff(maxAttempts: 2)
        let decision = policy.decision(status: 429, error: nil, attempt: 2, rateLimit: RateLimitSnapshot(retryAfter: 1))
        #expect(decision == .stop)
    }

    @Test
    func customRetryableStatusesReplaceDefaults() {
        let policy = ExponentialBackoff(maxAttempts: 3, retryableStatuses: [418], randomFraction: { 1 })
        #expect(retryDelay(policy.decision(status: 418, error: nil, attempt: 1, rateLimit: nil)) == 0.375)
        #expect(policy.decision(status: 500, error: nil, attempt: 1, rateLimit: nil) == .stop)
    }
}

/// Which requests may be put on the wire twice.
///
/// A retry is a second delivery, so the decision belongs to HTTP semantics
/// rather than to the backoff curve: replaying a POST can charge a card twice.
struct RetryReplaySafetyTests {
    private let url = URL(string: "https://example.com/v1")!

    private func retrying(_ transport: MockTransport) -> any HTTPTransport {
        RetryingTransport(base: transport, policy: ExponentialBackoff(maxAttempts: 3), sleep: { _ in })
    }

    @Test(arguments: [
        ("GET", true), ("HEAD", true), ("PUT", true), ("DELETE", true),
        ("OPTIONS", true), ("TRACE", true), ("POST", false), ("PATCH", false),
    ])
    func methodsCarryTheirHTTPIdempotency(_ pair: (String, Bool)) {
        #expect(HTTPRequest(method: pair.0, url: url).isIdempotent == pair.1)
    }

    @Test("the method is read case-insensitively, since it is never validated")
    func lowercaseMethodsAreClassifiedToo() {
        #expect(HTTPRequest(method: "get", url: url).isIdempotent)
        #expect(!HTTPRequest(method: "post", url: url).isIdempotent)
    }

    @Test("a failing POST reaches the server once, however retryable the status")
    func postIsNotReplayedAfterARetryableStatus() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 500, headers: [:], body: Data())),
            .response(HTTPResponse(status: 200, headers: [:], body: Data("done".utf8))),
        ])
        let response = try await retrying(transport).send(HTTPRequest(method: "POST", url: url))
        #expect(response.status == 500)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("a POST that times out is not replayed either — the server may have run it")
    func postIsNotReplayedAfterAThrownError() async {
        let transport = MockTransport([
            .failure(URLError(.timedOut)),
            .response(HTTPResponse(status: 200, headers: [:], body: Data())),
        ])
        do {
            _ = try await retrying(transport).send(HTTPRequest(method: "POST", url: url))
            Issue.record("エラーがスローされるべき")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("an idempotent method is still replayed")
    func getIsReplayed() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 500, headers: [:], body: Data())),
            .response(HTTPResponse(status: 200, headers: [:], body: Data("done".utf8))),
        ])
        let response = try await retrying(transport).send(HTTPRequest(method: "GET", url: url))
        #expect(response.status == 200)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test("a caller who knows its POST is safe — an idempotency key, say — can opt in")
    func postCanOptIntoReplay() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 500, headers: [:], body: Data())),
            .response(HTTPResponse(status: 200, headers: [:], body: Data("done".utf8))),
        ])
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["Idempotency-Key": "abc"],
            isIdempotent: true
        )
        let response = try await retrying(transport).send(request)
        #expect(response.status == 200)
        #expect(transport.recordedRequests.count == 2)
    }

    @Test("a caller can also opt an idempotent method out")
    func idempotentMethodCanOptOutOfReplay() async throws {
        let transport = MockTransport([
            .response(HTTPResponse(status: 500, headers: [:], body: Data())),
            .response(HTTPResponse(status: 200, headers: [:], body: Data())),
        ])
        let request = HTTPRequest(method: "GET", url: url, isIdempotent: false)
        let response = try await retrying(transport).send(request)
        #expect(response.status == 500)
        #expect(transport.recordedRequests.count == 1)
    }

    @Test("refusing to replay does not swallow the response the caller asked for")
    func refusingToReplayStillReturnsTheLastResponse() async throws {
        let transport = MockTransport([.response(HTTPResponse(status: 503, headers: [:], body: Data("busy".utf8)))])
        let response = try await retrying(transport).send(HTTPRequest(method: "POST", url: url))
        #expect(response.status == 503)
        #expect(String(decoding: response.body, as: UTF8.self) == "busy")
    }
}

/// Retrying a stream is only safe before the caller has seen any of it.
struct RetryingStreamTests {
    private let url = URL(string: "https://example.com/sse")!

    /// Yields one chunk and then fails, which no scripted outcome can express.
    private final class ChunkThenFailTransport: HTTPTransport, HTTPStreamingTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            throw TransportError.invalidResponse
        }

        func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
            lock.withLock { calls += 1 }
            return AsyncThrowingStream { continuation in
                continuation.yield(Data("partial".utf8))
                continuation.finish(throwing: TransportError.network(URLError(.networkConnectionLost)))
            }
        }
    }

    private func collect(_ stream: AsyncThrowingStream<Data, Error>) async -> (chunks: [Data], error: (any Error)?) {
        var chunks: [Data] = []
        do {
            for try await chunk in stream { chunks.append(chunk) }
            return (chunks, nil)
        } catch {
            return (chunks, error)
        }
    }

    @Test("a status failure before the first byte is retried")
    func streamRetriesAStatusErrorBeforeAnyChunkArrives() async {
        let base = MockTransport(
            [
                .response(HTTPResponse(status: 503, headers: [:], body: Data())),
                .response(HTTPResponse(status: 200, headers: [:], body: Data())),
            ],
            streamChunks: [Data("payload".utf8)]
        )
        let retrying = RetryingTransport(base: base, policy: ExponentialBackoff(maxAttempts: 3), sleep: { _ in })
        let result = await collect(retrying.stream(HTTPRequest(method: "GET", url: url)))
        #expect(result.error == nil)
        #expect(result.chunks.map { String(decoding: $0, as: UTF8.self) } == ["payload"])
        #expect(base.recordedRequests.count == 2)
    }

    @Test("a transport failure before the first byte is retried too")
    func streamRetriesAThrownErrorBeforeAnyChunkArrives() async {
        let base = MockTransport(
            [.failure(URLError(.timedOut)), .response(HTTPResponse(status: 200, headers: [:], body: Data()))],
            streamChunks: [Data("payload".utf8)]
        )
        let retrying = RetryingTransport(base: base, policy: ExponentialBackoff(maxAttempts: 3), sleep: { _ in })
        let result = await collect(retrying.stream(HTTPRequest(method: "GET", url: url)))
        #expect(result.error == nil)
        #expect(base.recordedRequests.count == 2)
    }

    @Test("once a chunk has been handed over, replaying would duplicate it, so the error stands")
    func streamDoesNotRetryAfterDeliveringAChunk() async {
        let base = ChunkThenFailTransport()
        let retrying = RetryingTransport(base: base, policy: ExponentialBackoff(maxAttempts: 3), sleep: { _ in })
        let result = await collect(retrying.stream(HTTPRequest(method: "GET", url: url)))
        #expect(result.chunks.map { String(decoding: $0, as: UTF8.self) } == ["partial"])
        #expect(result.error != nil)
        #expect(base.callCount == 1)
    }

    @Test("a streamed POST is not replayed either")
    func streamDoesNotReplayANonIdempotentRequest() async {
        let base = MockTransport(
            [
                .response(HTTPResponse(status: 503, headers: [:], body: Data())),
                .response(HTTPResponse(status: 200, headers: [:], body: Data())),
            ],
            streamChunks: [Data("payload".utf8)]
        )
        let retrying = RetryingTransport(base: base, policy: ExponentialBackoff(maxAttempts: 3), sleep: { _ in })
        let result = await collect(retrying.stream(HTTPRequest(method: "POST", url: url)))
        #expect((result.error as? HTTPStatusError)?.status == 503)
        #expect(base.recordedRequests.count == 1)
    }

    @Test("the last failure is propagated once the attempts run out")
    func streamStopsAtMaxAttempts() async {
        let base = MockTransport([
            .response(HTTPResponse(status: 503, headers: [:], body: Data())),
            .response(HTTPResponse(status: 503, headers: [:], body: Data())),
            .response(HTTPResponse(status: 503, headers: [:], body: Data())),
        ])
        let retrying = RetryingTransport(base: base, policy: ExponentialBackoff(maxAttempts: 2), sleep: { _ in })
        let result = await collect(retrying.stream(HTTPRequest(method: "GET", url: url)))
        #expect((result.error as? HTTPStatusError)?.status == 503)
        #expect(base.recordedRequests.count == 2)
    }

    @Test("Retry-After on the failing status is honoured on the streaming path as well")
    func streamHonoursRateLimitHeaders() async {
        let base = MockTransport(
            [
                .response(HTTPResponse(status: 429, headers: ["retry-after": "7"], body: Data())),
                .response(HTTPResponse(status: 200, headers: [:], body: Data())),
            ],
            streamChunks: [Data("payload".utf8)]
        )
        let sleeps = SleepRecorder()
        let retrying = RetryingTransport(
            base: base,
            policy: ExponentialBackoff(maxAttempts: 3),
            rateLimitMapping: RateLimitHeaderMapping(),
            sleep: { sleeps.record($0) }
        )
        let result = await collect(retrying.stream(HTTPRequest(method: "GET", url: url)))
        #expect(result.error == nil)
        #expect(sleeps.recorded == [7])
    }
}

/// Records the waits a retrying transport asked for.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval] = []
    func record(_ delay: TimeInterval) { lock.withLock { delays.append(delay) } }
    var recorded: [TimeInterval] { lock.withLock { delays } }
}

/// How ``RetryingTransport`` behaves when the base transport throws rather
/// than answering with a failing status.
struct RetryingTransportErrorPathTests {
    private let url = URL(string: "https://example.com/v1")!

    @Test
    func retriesThrownErrorsUntilMaxAttemptsThenRethrowsLastError() async {
        let transport = MockTransport([
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
            .failure(URLError(.cannotFindHost)),
        ])
        let sleeps = SleepRecorder()
        let retrying = RetryingTransport(
            base: transport,
            policy: ExponentialBackoff(maxAttempts: 3, baseDelay: 0.5),
            sleep: { sleeps.record($0) }
        )
        do {
            _ = try await retrying.send(HTTPRequest(method: "GET", url: url))
            Issue.record("エラーがスローされるべき")
        } catch {
            #expect((error as? URLError)?.code == .cannotFindHost)
        }
        #expect(transport.recordedRequests.count == 3)
        // Two waits, each inside its own jittered window on the backoff curve.
        let waits = sleeps.recorded
        #expect(waits.count == 2)
        #expect(waits.first.map { $0 >= 0.375 && $0 <= 0.5 } == true)
        #expect(waits.last.map { $0 >= 0.75 && $0 <= 1.0 } == true)
    }

    @Test
    func recoversWhenErrorIsFollowedBySuccess() async throws {
        let transport = MockTransport([
            .failure(URLError(.networkConnectionLost)),
            .response(HTTPResponse(status: 200, headers: [:], body: Data("ok".utf8))),
        ])
        let retrying = RetryingTransport(base: transport, policy: ExponentialBackoff(maxAttempts: 3), sleep: { _ in })
        let response = try await retrying.send(HTTPRequest(method: "GET", url: url))
        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == "ok")
        #expect(transport.recordedRequests.count == 2)
    }

    @Test
    func noRetryPolicyRethrowsImmediatelyWithoutSleeping() async {
        let transport = MockTransport([.failure(URLError(.timedOut))])
        let retrying = RetryingTransport(
            base: transport,
            policy: NoRetry(),
            sleep: { _ in Issue.record("リトライしないポリシーで sleep が呼ばれた") }
        )
        do {
            _ = try await retrying.send(HTTPRequest(method: "GET", url: url))
            Issue.record("エラーがスローされるべき")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(transport.recordedRequests.count == 1)
    }
}
