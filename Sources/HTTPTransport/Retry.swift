import Foundation

/// The retry decision for a single attempt.
public enum RetryDecision: Sendable, Equatable {
    case retry(after: TimeInterval)
    case stop
}

/// The single retry policy abstraction for the whole stack.
///
/// Decides per attempt based on HTTP status, transport error, and any parsed
/// rate-limit snapshot. Replaces the previously duplicated status-based and
/// error-based policies.
public protocol RetryPolicy: Sendable {
    var maxAttempts: Int { get }
    func decision(
        status: Int?,
        error: (any Error)?,
        attempt: Int,
        rateLimit: RateLimitSnapshot?
    ) -> RetryDecision
}

/// Never retries.
public struct NoRetry: RetryPolicy {
    public let maxAttempts = 1
    public init() {}
    public func decision(status: Int?, error: (any Error)?, attempt: Int, rateLimit: RateLimitSnapshot?) -> RetryDecision {
        .stop
    }
}

/// Exponential backoff with jitter, honouring `Retry-After` / rate-limit resets.
///
/// Retries on 408/425/429 and 5xx, and on transport (network) errors.
public struct ExponentialBackoff: RetryPolicy {
    public let maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
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

/// Wraps any transport with retry behaviour, parsing rate-limit headers.
///
/// Centralises retry in one place (the transport layer), removing per-provider
/// retry loops. The `sleep` is injectable for deterministic tests.
public struct RetryingTransport: HTTPTransport {
    public let base: any HTTPTransport
    public let policy: any RetryPolicy
    public let rateLimitMapping: RateLimitHeaderMapping?
    private let sleep: @Sendable (TimeInterval) async throws -> Void

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
