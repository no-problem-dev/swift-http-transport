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
    /// or it did not.
    ///
    /// A policy sees no part of the request, and does not need to: whether a
    /// request may be delivered twice is settled by
    /// ``HTTPRequest/isIdempotent`` before ``RetryingTransport`` acts on any
    /// answer given here. Asking for a retry can therefore never be unsafe, and
    /// no policy has to remember the rule.
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
/// The delay doubles per attempt and is capped at ``maxDelay``; a share of it,
/// drawn afresh for every decision, is then taken off. Two clients that failed
/// at the same instant therefore come back at different moments, which is the
/// whole point — a fixed reduction would merely shorten the wait and leave the
/// herd intact.
///
/// The draw spans `0...`` jitterFraction``, so a delay lands somewhere in
/// `[backoff x (1 - jitterFraction), backoff]` and never collapses toward zero
/// the way full jitter can.
///
/// A `Retry-After` value wins over the computed delay and is used as given,
/// capped at ``maxDelay``. It is deliberately not jittered: the server named a
/// time, and honouring it exactly is more useful than spreading it.
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

    /// The largest share of the computed backoff that jitter may remove.
    ///
    /// Clamped to `0...1`. At the default `0.25` a delay lands anywhere in the
    /// top quarter-window below the curve; `0` disables jitter and returns the
    /// bare curve.
    public var jitterFraction: Double

    /// Draws the share actually removed, as a value in `0...1`.
    ///
    /// Injectable for the same reason ``RetryingTransport``'s `sleep` is: a test
    /// that wants to assert the curve itself needs the draw held still. Nothing
    /// but tests should pass this.
    private let randomFraction: @Sendable () -> Double

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 0.5,
        maxDelay: TimeInterval = 30,
        retryableStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504],
        jitterFraction: Double = 0.25,
        randomFraction: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) }
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.retryableStatuses = retryableStatuses
        self.jitterFraction = min(max(jitterFraction, 0), 1)
        self.randomFraction = randomFraction
    }

    public func decision(status: Int?, error: (any Error)?, attempt: Int, rateLimit: RateLimitSnapshot?) -> RetryDecision {
        guard attempt < maxAttempts else { return .stop }
        let shouldRetry = (status.map { retryableStatuses.contains($0) } ?? false) || (status == nil && error != nil)
        guard shouldRetry else { return .stop }
        if let retryAfter = rateLimit?.retryAfter {
            return .retry(after: min(retryAfter, maxDelay))
        }
        let backoff = min(baseDelay * pow(2, Double(attempt - 1)), maxDelay)
        let draw = min(max(randomFraction(), 0), 1)
        return .retry(after: backoff * (1 - jitterFraction * draw))
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
/// - Streaming is preserved: wrap something that streams and the wrapper
///   streams too, because the conformance is conditional on `Base`. Wrap
///   something that does not and the wrapper does not either — a fact the
///   compiler enforces rather than one discovered at runtime.
/// - Only requests that ``HTTPRequest/isIdempotent`` marks safe are ever
///   replayed, so a POST that fails is handed straight back.
///
/// Generic over its base rather than holding an `any HTTPTransport`: the
/// streaming capability has to survive in the type for the conditional
/// conformance above to be expressible at all.
public struct RetryingTransport<Base: HTTPTransport>: HTTPTransport {
    public let base: Base
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
        base: Base,
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
            let outcome: AttemptOutcome
            do {
                let response = try await base.send(request)
                if response.isSuccess { return response }
                outcome = .response(response)
            } catch {
                outcome = .failure(error)
            }
            guard let delay = delayBeforeReplay(of: request, after: outcome, attempt: attempt) else {
                switch outcome {
                case .response(let response): return response
                case .failure(let error): throw error
                }
            }
            try await sleep(delay)
        }
    }

    /// What one attempt produced. Exactly one of the two, by construction —
    /// which is why giving up needs no fallback error to fall back to.
    fileprivate enum AttemptOutcome {
        case response(HTTPResponse)
        case failure(any Error)
    }

    /// How long to wait before sending again, or `nil` to give up.
    ///
    /// Two vetoes, in order: the policy's, and then HTTP's own. A request that
    /// is not idempotent is never replayed however eagerly the policy asks,
    /// because the veto belongs to whoever performs the second delivery, not to
    /// whoever chose the backoff curve. Putting it here means no custom
    /// ``RetryPolicy`` can reopen the hole by forgetting about it.
    private func delayBeforeReplay(
        of request: HTTPRequest,
        after outcome: AttemptOutcome,
        attempt: Int
    ) -> TimeInterval? {
        let status: Int?
        let thrown: (any Error)?
        let rateLimit: RateLimitSnapshot?
        switch outcome {
        case .response(let response):
            status = response.status
            thrown = nil
            rateLimit = rateLimitMapping?.extract(from: response.headers)
        case .failure(let error):
            status = nil
            thrown = error
            rateLimit = nil
        }
        let decision = policy.decision(status: status, error: thrown, attempt: attempt, rateLimit: rateLimit)
        guard case .retry(let delay) = decision, request.isIdempotent else { return nil }
        return max(0, delay)
    }

    /// Reads a streaming failure as the failed attempt it describes.
    ///
    /// ``HTTPStatusError`` carries exactly what a non-2xx ``HTTPResponse``
    /// carries, so folding it back into one lets a policy's status rules and
    /// the rate-limit mapping apply to streams unchanged.
    fileprivate func outcome(for error: any Error) -> AttemptOutcome {
        guard let status = error as? HTTPStatusError else { return .failure(error) }
        return .response(HTTPResponse(status: status.status, headers: status.headers, body: status.body))
    }
}

extension RetryingTransport: HTTPStreamingTransport where Base: HTTPStreamingTransport {
    /// Sends a request and yields the body, replaying only a failure that
    /// arrived before the caller saw any of it.
    ///
    /// A stream that has already handed over a chunk cannot be replayed: the
    /// caller would receive those bytes twice, and this layer cannot know
    /// whether that corrupts what they are building. So the window for a retry
    /// closes at the first yielded chunk, and after it every failure is final.
    /// Before it, a stream retries on exactly the terms ``send(_:)`` does —
    /// same policy, same `Retry-After`, same idempotency rule.
    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while true {
                    attempt += 1
                    var delivered = false
                    do {
                        for try await chunk in base.stream(request) {
                            delivered = true
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled {
                            continuation.finish(throwing: TransportError.cancelled)
                            return
                        }
                        guard !delivered,
                              let delay = delayBeforeReplay(
                                  of: request,
                                  after: outcome(for: error),
                                  attempt: attempt
                              )
                        else {
                            continuation.finish(throwing: error)
                            return
                        }
                        do {
                            try await sleep(delay)
                        } catch {
                            continuation.finish(throwing: TransportError.cancelled)
                            return
                        }
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
