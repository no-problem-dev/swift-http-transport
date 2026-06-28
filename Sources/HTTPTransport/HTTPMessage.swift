import Foundation

/// 大文字・小文字を区別せず挿入順を保持する HTTP ヘッダストレージ。
public struct HTTPHeaders: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    private var entries: [(name: String, value: String)]

    public init() { entries = [] }

    public init(_ pairs: [(String, String)]) {
        entries = pairs.map { ($0.0, $0.1) }
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements)
    }

    public subscript(_ name: String) -> String? {
        get { entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        set {
            entries.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let newValue { entries.append((name, newValue)) }
        }
    }

    public var pairs: [(name: String, value: String)] { entries }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        return lhs.entries.allSatisfy { rhs[$0.name] == $0.value }
    }
}

/// `URLSession` に依存しないトランスポート層の HTTP リクエスト。
public struct HTTPRequest: Sendable {
    /// HTTP メソッド（`"GET"`, `"POST"` 等）。
    public var method: String
    /// リクエスト先 URL。
    public var url: URL
    /// HTTP リクエストヘッダ。
    public var headers: HTTPHeaders
    /// リクエストボディ。`nil` は本文なし（`GET` 等）。
    public var body: Data?
    /// タイムアウト秒数。`nil` のとき ``URLSessionTransport/defaultTimeout`` が適用される。
    public var timeout: TimeInterval?

    public init(
        method: String,
        url: URL,
        headers: HTTPHeaders = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// トランスポート層の HTTP レスポンス。
public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: HTTPHeaders
    public let body: Data

    public init(status: Int, headers: HTTPHeaders, body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// HTTP ステータスコードが `200..<300`（2xx 成功範囲）なら `true`。
    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// HTTP 通信が完了する前にトランスポート層で発生するエラー。
public enum TransportError: Error, Sendable {
    /// レスポンスを `HTTPURLResponse` として解釈できなかった。
    case invalidResponse
    /// ネットワーク層のエラー（接続拒否・DNS 解決失敗等）。
    case network(any Error)
    /// レスポンス受信前にタスクがキャンセルされた。
    case cancelled
}
