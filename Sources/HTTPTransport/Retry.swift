import Foundation

/// What to do once an attempt has finished.
///
/// Returned by ``RetryPolicy/decision(status:error:attempt:rateLimit:)`` and
/// acted on by ``RetryingTransport``, which either sleeps and sends again, or
/// hands the last response or error back to the caller.
public enum RetryDecision: Sendable, Equatable {
    /// Wait the given number of seconds, then send the same request again.
    case retry(after: TimeInterval)
    /// Give up and propagate whatever the last attempt produced.
    case stop
}

/// The single place that decides whether a failed attempt is repeated.
///
/// One policy sees all three inputs — HTTP status, thrown transport error, and
/// parsed rate-limit headers — so status-driven and error-driven rules cannot
/// drift apart the way two separate policies did.
public protocol RetryPolicy: Sendable {
    /// Total attempts allowed including the first, so `1` disables retrying.
    var maxAttempts: Int { get }

    /// Decides what happens after one attempt has completed.
    ///
    /// Exactly one of `status` and `error` is non-`nil`: a response came back,
    /// or it did not. Note that a policy sees no part of the request, so it
    /// cannot distinguish a safe retry from an unsafe one.
    ///
    /// - Parameters:
    ///   - status: The response status, or `nil` when the attempt threw.
    ///   - error: The error thrown, or `nil` when a response came back.
    ///   - attempt: Which attempt just finished, counting from 1.
    ///   - rateLimit: Quota headers parsed from the response, when there was
    ///     one and a mapping was configured.
    /// - Returns: Whether to send again, and after how long.
    func decision(
        status: Int?,
        error: (any Error)?,
        attempt: Int,
        rateLimit: RateLimitSnapshot?
    ) -> RetryDecision
}

/// A policy that never retries: the first outcome is final.
public struct NoRetry: RetryPolicy {
    public let maxAttempts = 1
    public init() {}
    public func decision(status: Int?, error: (any Error)?, attempt: Int, rateLimit: RateLimitSnapshot?) -> RetryDecision {
        .stop
    }
}

/// Doubling backoff that defers to `Retry-After` whenever the server sent one.
///
/// Retries 408, 425, 429 and 5xx by default, plus any thrown transport error.
/// The delay doubles per attempt, is capped at ``maxDelay``, then has a flat
/// quarter subtracted. That subtraction is constant, not random, so clients
/// that fail together will also retry together.
///
/// A `Retry-After` value wins over the computed delay and is used as given,
/// capped at ``maxDelay``.
public struct ExponentialBackoff: RetryPolicy {
    public let maxAttempts: Int

    /// Delay before the second attempt, doubled for each attempt after that.
    public var baseDelay: TimeInterval

    /// Ceiling for any wait, applied to computed delays and `Retry-After` alike.
    public var maxDelay: TimeInterval

    /// Statuses worth another attempt.
    ///
    /// Assigning replaces the default set outright rather than adding to it.
    public var retryableStatuses: Set<Int>

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 30,
        retryableStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.retryableStatuses = retryableStatuses
    }

    public func decision(status: Int?, error: (any Error)?, attempt: Int, rateLimit: RateLimitSnapshot?) -> RetryDecision {
        guard attempt < maxAttempts else { return .stop }
        let shouldRetry = (status.map { retryableStatuses.contains($0) } ?? false) || (status == nil && error != nil)
        guard shouldRetry else { return .stop }
        if let retryAfter = rateLimit?.retryAfter {
            return .retry(after: min(retryAfter, maxDelay))
        }
        let backoff = min(baseDelay * pow(2, Double(attempt - 1)), maxDelay)
        let jitter = backoff * 0.25
        return .retry(after: backoff - jitter)
    }
}

/// A decorator that re-sends failed requests according to a policy.
///
/// Retrying lives here instead of in every caller, so everything routed through
/// the stack retries the same way. Rate-limit headers are read from each
/// response and passed to the policy, which may honour them in place of its own
/// backoff.
///
/// Two things to know before wrapping a transport in this:
///
/// - Only ``HTTPTransport`` is implemented. Wrapping a streaming transport does
///   not make ``HTTPStreamingTransport/stream(_:)`` retry.
/// - The request is replayed unchanged whatever its method, so a non-idempotent
///   request can reach the server more than once.
public struct RetryingTransport: HTTPTransport {
    public let base: any HTTPTransport
    public let policy: any RetryPolicy
    public let rateLimitMapping: RateLimitHeaderMapping?
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Wraps a transport so its failures are retried.
    ///
    /// - Parameters:
    ///   - base: The transport that actually sends the request.
    ///   - policy: Decides whether to retry and how long to wait.
    ///   - rateLimitMapping: Which header names carry quota information. When
    ///     `nil`, the policy is never given a rate-limit snapshot.
    ///   - sleep: How to wait between attempts. Defaults to `Task.sleep`; pass
    ///     a closure that returns immediately to run the backoff schedule in
    ///     tests without real delay.
    public init(
        base: any HTTPTransport,
        policy: any RetryPolicy,
        rateLimitMapping: RateLimitHeaderMapping? = nil,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.base = base
        self.policy = policy
        self.rateLimitMapping = rateLimitMapping
        self.sleep = sleep
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            let status: Int?
            let response: HTTPResponse?
            let thrown: (any Error)?
            do {
                let result = try await base.send(request)
                if result.isSuccess { return result }
                status = result.status
                response = result
                thrown = nil
            } catch {
                status = nil
                response = nil
                thrown = error
            }
            let rateLimit = response.flatMap { r in rateLimitMapping?.extract(from: r.headers) }
            switch policy.decision(status: status, error: thrown, attempt: attempt, rateLimit: rateLimit) {
            case .retry(let delay):
                try await sleep(max(0, delay))
            case .stop:
                if let response { return response }
                throw thrown ?? TransportError.invalidResponse
            }
        }
    }
}
