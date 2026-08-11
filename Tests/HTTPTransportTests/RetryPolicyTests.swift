import Foundation
import Testing
@testable import HTTPTransport

/// Table-driven checks of the backoff curve, its ceiling, the flat reduction,
/// and where it gives up. The decision function is pure, so no I/O is needed.
struct ExponentialBackoffTests {
    /// The default curve at baseDelay 0.5 and maxDelay 30:
    /// delay = min(0.5 x 2^(attempt-1), 30) x 0.75, the 25% cut being constant.
    private let policy = ExponentialBackoff(maxAttempts: 10, baseDelay: 0.5, maxDelay: 30)

    @Test(arguments: [
        (1, 0.375),
        (2, 0.75),
        (3, 1.5),
        (4, 3.0),
        (5, 6.0),
        (6, 12.0),
    ])
    func backoffCurveDoublesPerAttemptWithQuarterJitterReduction(_ pair: (Int, Double)) {
        let decision = policy.decision(status: 500, error: nil, attempt: pair.0, rateLimit: nil)
        #expect(decision == .retry(after: pair.1))
    }

    @Test(arguments: [7, 8, 9])
    func delayIsCappedAtMaxDelayBeforeJitter(_ attempt: Int) {
        // 0.5 x 2^6 = 32 exceeds maxDelay 30, so it pins at 30 x 0.75 = 22.5
        let decision = policy.decision(status: 500, error: nil, attempt: attempt, rateLimit: nil)
        #expect(decision == .retry(after: 22.5))
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
        #expect(policy.decision(status: status, error: nil, attempt: 1, rateLimit: nil) == .retry(after: 0.375))
    }

    @Test(arguments: [200, 201, 204, 301, 400, 401, 403, 404, 409, 422])
    func stopsOnNonRetryableStatuses(_ status: Int) {
        #expect(policy.decision(status: status, error: nil, attempt: 1, rateLimit: nil) == .stop)
    }

    @Test
    func retriesTransportErrorWithoutStatus() {
        let decision = policy.decision(status: nil, error: URLError(.timedOut), attempt: 1, rateLimit: nil)
        #expect(decision == .retry(after: 0.375))
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
        let policy = ExponentialBackoff(maxAttempts: 3, retryableStatuses: [418])
        #expect(policy.decision(status: 418, error: nil, attempt: 1, rateLimit: nil) == .retry(after: 0.375))
        #expect(policy.decision(status: 500, error: nil, attempt: 1, rateLimit: nil) == .stop)
    }
}

/// How ``RetryingTransport`` behaves when the base transport throws rather
/// than answering with a failing status.
struct RetryingTransportErrorPathTests {
    private let url = URL(string: "https://example.com/v1")!

    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var delays: [TimeInterval] = []
        func record(_ delay: TimeInterval) { lock.withLock { delays.append(delay) } }
        var recorded: [TimeInterval] { lock.withLock { delays } }
    }

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
        #expect(sleeps.recorded == [0.375, 0.75]) // two waits, following the backoff curve
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
