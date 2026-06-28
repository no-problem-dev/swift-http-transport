import Foundation

/// 1 回のリトライ評価の結果。
///
/// ``RetryPolicy/decision(status:error:attempt:rateLimit:)`` が返し、
/// ``RetryingTransport`` がスリープしてリトライするか、
/// エラー/レスポンスを呼び出し元へ伝播するかを決定する。
public enum RetryDecision: Sendable, Equatable {
    /// 指定された秒数スリープしてから再度リクエストを発行する。
    case retry(after: TimeInterval)
    /// リトライせず、レスポンスまたはエラーをそのまま伝播する。
    case stop
}

/// スタック全体で使用するリトライポリシーの唯一の抽象。
///
/// HTTP ステータス・トランスポートエラー・レート制限スナップショットをもとに
/// 試行ごとにリトライ可否を判断する。
/// 以前重複していたステータス基準・エラー基準の両ポリシーを統合する。
public protocol RetryPolicy: Sendable {
    /// 最大試行回数（初回 + リトライの合計）。
    var maxAttempts: Int { get }

    /// 1 回の試行完了後にリトライ可否を返す。
    ///
    /// - Parameters:
    ///   - status: レスポンスの HTTP ステータスコード。トランスポートエラー（ネットワークエラー・キャンセル）の場合は `nil`。
    ///   - error: `status` が `nil` の場合にスローされたエラー。レスポンスがある場合は `nil`。
    ///   - attempt: 完了した試行の 1-based インデックス（1 = 初回試行）。
    ///   - rateLimit: レスポンスから解析したレート制限ヘッダ情報（あれば）。
    /// - Returns: ``RetryDecision/retry(after:)`` または ``RetryDecision/stop``。
    func decision(
        status: Int?,
        error: (any Error)?,
        attempt: Int,
        rateLimit: RateLimitSnapshot?
    ) -> RetryDecision
}

/// リトライを一切行わないポリシー。
public struct NoRetry: RetryPolicy {
    public let maxAttempts = 1
    public init() {}
    public func decision(status: Int?, error: (any Error)?, attempt: Int, rateLimit: RateLimitSnapshot?) -> RetryDecision {
        .stop
    }
}

/// ジッタ付き指数バックオフ。`Retry-After` / レート制限リセット値を尊重する。
///
/// 408/425/429 および 5xx、トランスポート（ネットワーク）エラーでリトライする。
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

/// レート制限ヘッダを解析しながらリトライ処理を付与するトランスポートデコレータ。
///
/// プロバイダごとのリトライループをトランスポート層に集約する。
/// `sleep` はテスト時に差し替え可能。
public struct RetryingTransport: HTTPTransport {
    public let base: any HTTPTransport
    public let policy: any RetryPolicy
    public let rateLimitMapping: RateLimitHeaderMapping?
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// リトライデコレータを初期化する。
    ///
    /// - Parameters:
    ///   - base: リクエストを実際に送信する下位トランスポート。
    ///   - policy: リトライ可否と待機時間を決定するポリシー。
    ///   - rateLimitMapping: レート制限ヘッダの解析設定。`nil` の場合はレート制限情報を参照しない。
    ///   - sleep: 待機処理の実装。デフォルトは `Task.sleep`。テスト時は即時返却するクロージャを渡して時間を制御できる注入ポイント。
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
