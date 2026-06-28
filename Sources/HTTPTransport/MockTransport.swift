import Foundation

/// テスト用の決定論的トランスポート。
///
/// スクリプト済みレスポンス（または クロージャ）から応答し、受信したリクエストを記録する。
public final class MockTransport: HTTPTransport, HTTPStreamingTransport, @unchecked Sendable {
    /// 単一リクエストに対するスクリプト済みの結果。
    public enum Outcome: Sendable {
        /// 指定されたレスポンスを返す。
        case response(HTTPResponse)
        /// 指定されたエラーをスローする。
        case failure(any Error)
    }

    private let lock = NSLock()
    private var scripted: [Outcome]
    private let handler: (@Sendable (HTTPRequest) throws -> HTTPResponse)?
    private var streamChunks: [Data]
    /// ``send(_:)`` および ``stream(_:)`` が受け取ったリクエストを受信順に記録する。テストアサーションに使用する。
    public private(set) var recordedRequests: [HTTPRequest] = []

    /// スクリプト方式のイニシャライザ。
    ///
    /// `outcomes` を先着順に消費してレスポンスを決定する。「N 回目は成功、N+1 回目はエラー」のように
    /// 試行ごとの結果を固定したテストに使う。`streamChunks` は ``stream(_:)`` が yield するチャンク列に使用する。
    ///
    /// - Parameters:
    ///   - outcomes: ``send(_:)`` の呼び出しに対するスクリプト済みの結果。空のとき 200 OK を返す。
    ///   - streamChunks: ``stream(_:)`` が yield するバイトチャンク列。
    public init(_ outcomes: [Outcome] = [], streamChunks: [Data] = []) {
        self.scripted = outcomes
        self.handler = nil
        self.streamChunks = streamChunks
    }

    /// クロージャ方式のイニシャライザ。
    ///
    /// リクエストの内容を検査して動的にレスポンスを決定したい場合に使う。
    /// スクリプト方式（``init(_:streamChunks:)``）と異なり、受け取ったリクエストに基づいて結果を変えられる。
    ///
    /// - Parameter handler: リクエストを受け取りレスポンスを返す（またはスローする）クロージャ。
    public init(handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        self.scripted = []
        self.handler = handler
        self.streamChunks = []
    }

    /// 固定レスポンスを 1 件だけ返す便宜イニシャライザ。
    ///
    /// 単純な 1 回きりのレスポンスを確認するテストに使う。
    ///
    /// - Parameters:
    ///   - status: HTTP ステータスコード。
    ///   - headers: レスポンスヘッダ（デフォルト空）。
    ///   - body: レスポンスボディ（デフォルト空）。
    public convenience init(status: Int, headers: HTTPHeaders = [:], body: Data = Data()) {
        self.init([.response(HTTPResponse(status: status, headers: headers, body: body))])
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try lock.withLock {
            recordedRequests.append(request)
            if let handler { return try handler(request) }
            guard !scripted.isEmpty else {
                return HTTPResponse(status: 200, headers: [:], body: Data())
            }
            switch scripted.removeFirst() {
            case .response(let response): return response
            case .failure(let error): throw error
            }
        }
    }

    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        let chunks = lock.withLock { () -> [Data] in
            recordedRequests.append(request)
            return streamChunks
        }
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}
