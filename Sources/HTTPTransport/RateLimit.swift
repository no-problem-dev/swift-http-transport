import Foundation

/// What one response said about the caller's remaining quota.
///
/// Every field is optional because providers send different subsets, and any
/// field the mapping did not name or could not parse stays `nil`.
public struct RateLimitSnapshot: Sendable, Equatable {
    /// How long the server asked the caller to wait, from `Retry-After`.
    ///
    /// Both forms RFC 9110 §10.2.3 allows are understood — delay-seconds and
    /// HTTP-date — and a date is converted to seconds from now. Never negative:
    /// a deadline already past reads as `0`, meaning retry immediately, which is
    /// distinct from the `nil` that means the server said nothing. A policy that
    /// honours this generally uses it instead of its own backoff.
    public var retryAfter: TimeInterval?

    /// Calls left in the current window, counted separately from ``remainingTokens``.
    public var remainingRequests: Int?

    /// Seconds until the call quota refills.
    public var requestsReset: TimeInterval?

    /// Model tokens left in the current window, input and output combined.
    ///
    /// A separate counter from ``remainingRequests``: either can run out first.
    public var remainingTokens: Int?

    /// Seconds until the token quota refills.
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

    /// Whether nothing at all was recognised in the headers.
    ///
    /// Distinguishes "this response carried no quota information" from "the
    /// quota is exhausted", which otherwise look alike.
    public var isEmpty: Bool {
        retryAfter == nil && remainingRequests == nil && requestsReset == nil
            && remainingTokens == nil && tokensReset == nil
    }
}

/// A declaration of which header names a given provider uses for its quota.
///
/// Providers differ only in what they call these headers and how they spell a
/// reset time. Stating those two facts keeps the parsing itself in one place
/// instead of once per provider.
public struct RateLimitHeaderMapping: Sendable {
    /// How a provider expresses the moment a quota refills.
    public enum ResetFormat: Sendable {
        /// Seconds remaining until reset.
        case secondsRemaining
        /// Milliseconds remaining until reset.
        case millisecondsRemaining
        /// An absolute RFC 3339 timestamp, converted to seconds from now.
        ///
        /// Goes negative if the window already reset before the value was read.
        case rfc3339
        /// A Go-style duration such as `1s` or `6m0s`, as Anthropic and OpenAI send.
        case durationSuffix
    }

    public var retryAfter: String?
    public var remainingRequests: String?
    public var requestsReset: String?
    public var remainingTokens: String?
    public var tokensReset: String?

    /// How to read the two reset fields.
    ///
    /// ``retryAfter`` is read as RFC 9110 defines it whatever this says, but
    /// ``ResetFormat/durationSuffix`` additionally lets it be spelled the same
    /// way as a reset — providers that send `6m0s` resets also send `1s` here.
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

    /// Reads the mapped headers into a snapshot.
    ///
    /// Missing and unparseable fields are left `nil` rather than failing, so
    /// this never returns an optional and never throws. Consult
    /// ``RateLimitSnapshot/isEmpty`` to tell an absent quota from an exhausted one.
    ///
    /// - Parameter headers: The response headers to read.
    /// - Returns: Whatever could be parsed, with the rest left `nil`.
    public func extract(from headers: HTTPHeaders) -> RateLimitSnapshot {
        var snapshot = RateLimitSnapshot()
        if let name = retryAfter, let value = headers[name] { snapshot.retryAfter = retryAfterSeconds(from: value) }
        if let name = remainingRequests, let value = headers[name] { snapshot.remainingRequests = Int(value) }
        if let name = requestsReset, let value = headers[name] { snapshot.requestsReset = reset(from: value) }
        if let name = remainingTokens, let value = headers[name] { snapshot.remainingTokens = Int(value) }
        if let name = tokensReset, let value = headers[name] { snapshot.tokensReset = reset(from: value) }
        return snapshot
    }

    /// Reads `Retry-After` in either form RFC 9110 §10.2.3 permits.
    ///
    /// Tried in order: delay-seconds, then the Go-style duration when this
    /// mapping's provider spells resets that way, then HTTP-date. Discarding the
    /// date form is what made a server's backpressure indistinguishable from a
    /// response that carried no quota headers at all.
    ///
    /// - Returns: Seconds to wait, never negative, or `nil` when nothing parsed.
    func retryAfterSeconds(from value: String) -> TimeInterval? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(text), seconds.isFinite { return max(0, seconds) }
        if resetFormat == .durationSuffix, let seconds = Self.parseDuration(text) { return max(0, seconds) }
        if let date = Self.parseHTTPDate(text) { return max(0, date.timeIntervalSinceNow) }
        return nil
    }

    /// The three date spellings RFC 9110 §5.6.7 requires a recipient to accept.
    ///
    /// Formatters are built per call rather than shared: `DateFormatter` is not
    /// `Sendable`, and this runs only on the rare path where a server actually
    /// sent a date.
    static func parseHTTPDate(_ text: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",  // IMF-fixdate, the one to send
            "EEEE, dd-MMM-yy HH:mm:ss zzz",   // obsolete RFC 850
            "EEE MMM d HH:mm:ss yyyy",        // obsolete asctime
        ]
        // asctime pads a single-digit day with a second space, which the
        // pattern above does not match literally.
        let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: collapsed) { return date }
        }
        return nil
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

    /// Sums a Go-style duration such as `1s`, `6m0s`, `1m30s`, or `500ms`.
    ///
    /// Returns `nil` only when no number-and-unit pair was found at all; a
    /// trailing fragment that fails to parse keeps whatever came before it.
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
