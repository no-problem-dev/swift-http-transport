import Foundation

/// HTTP リクエストを送信して完全なレスポンスを待機するための唯一の接合点。
///
/// 上位のすべての層（api-client・各プロバイダ）は `URLSession` ではなくこの抽象にのみ依存する。
/// トランスポートをモック・デコレータ（リトライ）・別実装へ差し替えても呼び出し元を変更しなくてよい。
public protocol HTTPTransport: Sendable {
    /// HTTP リクエストを送信し、完全なレスポンスを返す。
    ///
    /// HTTP ステータスコードはエラーとして扱わず ``HTTPResponse/status`` に含まれる。
    /// ステータスに応じた処理が必要な場合は ``HTTPResponse/isSuccess`` を確認する。
    /// ネットワーク障害・キャンセル・非 HTTP レスポンスの場合は ``TransportError`` をスローする。
    /// ストリーミング時の 2xx 以外ステータスで ``HTTPStatusError`` をスローする ``HTTPStreamingTransport/stream(_:)`` とは異なる。
    ///
    /// - Parameter request: 送信するリクエスト。
    /// - Returns: サーバーから受信した完全な HTTP レスポンス。
    /// - Throws: ``TransportError``（ネットワーク障害・キャンセル・非 HTTP レスポンス等）。
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// ストリーミング版トランスポート。届いた生バイト列をチャンク単位で逐次返す（SSE 等に使用）。
public protocol HTTPStreamingTransport: Sendable {
    /// HTTP リクエストを送信し、レスポンスボディをチャンク単位で逐次 yield する `AsyncThrowingStream` を返す。
    ///
    /// SSE など長命なバイトストリームに使用する。
    /// 全バイトを受信するとストリームは正常終了する。
    /// サーバーが 2xx 以外のステータスを返した場合は ``HTTPStatusError`` をスローし、
    /// ネットワーク障害・キャンセルの場合は ``TransportError`` をスローする。
    ///
    /// - Parameter request: 送信するリクエスト。
    /// - Returns: レスポンスボディを随時 yield する `AsyncThrowingStream<Data, Error>`。
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error>
}

/// `URLSession` を背後に持つ標準の具象トランスポート。
public struct URLSessionTransport: HTTPTransport, HTTPStreamingTransport {
    /// すべてのリクエストで使用する `URLSession`。
    public let session: URLSession
    /// ``HTTPRequest/timeout`` を指定しないリクエストに適用するデフォルトタイムアウト。
    public var defaultTimeout: TimeInterval

    public init(session: URLSession = .shared, defaultTimeout: TimeInterval = 60) {
        self.session = session
        self.defaultTimeout = defaultTimeout
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = makeURLRequest(request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw TransportError.invalidResponse }
            return HTTPResponse(status: http.statusCode, headers: Self.headers(from: http), body: data)
        } catch is CancellationError {
            throw TransportError.cancelled
        } catch {
            throw TransportError.network(error)
        }
    }

    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        let urlRequest = makeURLRequest(request)
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw TransportError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw HTTPStatusError(status: http.statusCode, headers: Self.headers(from: http), body: body)
                    }
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= 4096 { continuation.yield(buffer); buffer.removeAll(keepingCapacity: true) }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeout ?? defaultTimeout
        for pair in request.headers.pairs {
            urlRequest.setValue(pair.value, forHTTPHeaderField: pair.name)
        }
        return urlRequest
    }

    private static func headers(from http: HTTPURLResponse) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let value = value as? String { headers[name] = value }
        }
        return headers
    }
}

/// ストリーミング時にサーバーが 2xx 以外のステータスを返した場合にスローされるエラー。
public struct HTTPStatusError: Error, Sendable {
    public let status: Int
    public let headers: HTTPHeaders
    public let body: Data
}
