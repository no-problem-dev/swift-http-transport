import Foundation

/// プロバイダのレート制限ヘッダを解析したスナップショット。
public struct RateLimitSnapshot: Sendable, Equatable {
    /// `Retry-After` ヘッダに基づく待機秒数。
    public var retryAfter: TimeInterval?
    /// API リクエスト（HTTP コール数）の残余クォータ。`remainingTokens` とは独立したカウンタ。
    public var remainingRequests: Int?
    /// API リクエストクォータのリセットまでの残り秒数。
    public var requestsReset: TimeInterval?
    /// LLM トークン（入出力トークン数の合算）の残余クォータ。`remainingRequests` とは独立したカウンタ。
    public var remainingTokens: Int?
    /// LLM トークンクォータのリセットまでの残り秒数。
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

    /// 全フィールドが `nil` のとき `true`。ヘッダに認識できる値が 1 件もなかったことを示す。
    public var isEmpty: Bool {
        retryAfter == nil && remainingRequests == nil && requestsReset == nil
            && remainingTokens == nil && tokensReset == nil
    }
}

/// プロバイダのヘッダ名を ``RateLimitSnapshot`` へ変換する宣言的マッピング。
///
/// プロバイダごとに実装していたレート制限抽出ロジックを一本化する。
/// プロバイダはヘッダ名とリセット形式を指定するだけでよく、解析ロジックはここに集約される。
public struct RateLimitHeaderMapping: Sendable {
    /// ヘッダ値のリセット時間形式。プロバイダごとに異なる表現を統一的に扱う。
    public enum ResetFormat: Sendable {
        /// リセットまでの残り秒数。
        case secondsRemaining
        /// リセットまでの残りミリ秒数。
        case millisecondsRemaining
        /// RFC 3339 の絶対タイムスタンプ。現在時刻からの秒数に変換する。
        case rfc3339
        /// `1s` / `6m0s` 形式の duration suffix（Anthropic/OpenAI スタイル）。
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

    /// ヘッダを解析して ``RateLimitSnapshot`` を返す。
    ///
    /// マッピングに登録されたヘッダ名を探索し、対応するフィールドを抽出する。
    /// ヘッダが存在しない・解析不能なフィールドは `nil` のままになるが、
    /// 戻り値は常に非 Optional の ``RateLimitSnapshot``（全フィールドが解析不能でも `nil` を返さない）。
    ///
    /// - Parameter headers: レスポンスの HTTP ヘッダ。
    /// - Returns: 解析結果を格納したスナップショット。全フィールドが解析不能な場合は ``RateLimitSnapshot/isEmpty`` が `true`。
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

    /// `1s`・`6m0s`・`1m30s`・`500ms` のような Go スタイルの duration 文字列を解析する。
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
