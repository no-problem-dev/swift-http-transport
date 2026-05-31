import Foundation

/// A parsed snapshot of a provider's rate-limit headers.
public struct RateLimitSnapshot: Sendable, Equatable {
    public var retryAfter: TimeInterval?
    public var remainingRequests: Int?
    public var requestsReset: TimeInterval?
    public var remainingTokens: Int?
    public var tokensReset: TimeInterval?

    public init(
        retryAfter: TimeInterval? = nil,
        remainingRequests: Int? = nil,
        requestsReset: TimeInterval? = nil,
        remainingTokens: Int? = nil,
        tokensReset: TimeInterval? = nil
    ) {
        self.retryAfter = retryAfter
        self.remainingRequests = remainingRequests
        self.requestsReset = requestsReset
        self.remainingTokens = remainingTokens
        self.tokensReset = tokensReset
    }

    public var isEmpty: Bool {
        retryAfter == nil && remainingRequests == nil && requestsReset == nil
            && remainingTokens == nil && tokensReset == nil
    }
}

/// Declarative mapping from a provider's header names to ``RateLimitSnapshot``.
///
/// Replaces the per-provider extractor copies: a provider supplies only its
/// header names and reset format; the parsing logic lives here once.
public struct RateLimitHeaderMapping: Sendable {
    public enum ResetFormat: Sendable {
        /// Seconds remaining until reset.
        case secondsRemaining
        /// Milliseconds remaining until reset.
        case millisecondsRemaining
        /// An absolute RFC 3339 timestamp; converted to seconds-from-now.
        case rfc3339
        /// A duration suffix such as `1s` / `6m0s` (Anthropic/OpenAI style).
        case durationSuffix
    }

    public var retryAfter: String?
    public var remainingRequests: String?
    public var requestsReset: String?
    public var remainingTokens: String?
    public var tokensReset: String?
    public var resetFormat: ResetFormat

    public init(
        retryAfter: String? = "retry-after",
        remainingRequests: String? = nil,
        requestsReset: String? = nil,
        remainingTokens: String? = nil,
        tokensReset: String? = nil,
        resetFormat: ResetFormat = .secondsRemaining
    ) {
        self.retryAfter = retryAfter
        self.remainingRequests = remainingRequests
        self.requestsReset = requestsReset
        self.remainingTokens = remainingTokens
        self.tokensReset = tokensReset
        self.resetFormat = resetFormat
    }

    public func extract(from headers: HTTPHeaders) -> RateLimitSnapshot {
        var snapshot = RateLimitSnapshot()
        if let name = retryAfter, let value = headers[name] { snapshot.retryAfter = TimeInterval(value) }
        if let name = remainingRequests, let value = headers[name] { snapshot.remainingRequests = Int(value) }
        if let name = requestsReset, let value = headers[name] { snapshot.requestsReset = reset(from: value) }
        if let name = remainingTokens, let value = headers[name] { snapshot.remainingTokens = Int(value) }
        if let name = tokensReset, let value = headers[name] { snapshot.tokensReset = reset(from: value) }
        return snapshot
    }

    private func reset(from value: String) -> TimeInterval? {
        switch resetFormat {
        case .secondsRemaining: return TimeInterval(value)
        case .millisecondsRemaining: return TimeInterval(value).map { $0 / 1000 }
        case .rfc3339:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = formatter.date(from: value) ?? {
                let plain = ISO8601DateFormatter()
                plain.formatOptions = [.withInternetDateTime]
                return plain.date(from: value)
            }()
            return date.map { $0.timeIntervalSinceNow }
        case .durationSuffix:
            return RateLimitHeaderMapping.parseDuration(value)
        }
    }

    /// Parses Go-style durations like `1s`, `6m0s`, `1m30s`, `500ms`.
    static func parseDuration(_ text: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var matched = false
        var index = text.startIndex
        func unit(_ s: String) -> TimeInterval? {
            switch s {
            case "ms": return 0.001
            case "s": return 1
            case "m": return 60
            case "h": return 3600
            default: return nil
            }
        }
        while index < text.endIndex {
            let ch = text[index]
            if ch.isNumber || ch == "." {
                number.append(ch)
                index = text.index(after: index)
            } else {
                var unitText = ""
                while index < text.endIndex, text[index].isLetter {
                    unitText.append(text[index]); index = text.index(after: index)
                }
                guard let value = Double(number), let scale = unit(unitText) else { return matched ? total : nil }
                total += value * scale
                matched = true
                number = ""
            }
        }
        return matched ? total : nil
    }
}
