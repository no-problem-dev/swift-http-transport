import Foundation

/// WHATWG `text/event-stream` 形式のデコード済み SSE フレーム。
public struct SSEEvent: Sendable, Equatable {
    /// イベントタイプ名。デフォルトの `"message"` イベントの場合は `nil`。
    public var event: String?
    /// イベントのペイロード。複数の `data:` 行は `\n` で結合される。
    public var data: String
    /// 再接続時に使用するラストイベント ID。
    public var id: String?
    /// サーバーからの再接続時間ヒント（ミリ秒）。WHATWG SSE 仕様の `retry:` フィールドに対応。``RetryPolicy`` とは無関係。
    public var retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// インクリメンタル SSE フレームパーサ。生バイトを受け取り、完成したイベントを返す。
///
/// 行境界で分割し、空行でイベントをディスパッチする。
/// 複数の `data:` 行は仕様に従い `\n` で結合する。
/// イベントのプロバイダ固有の意味解釈は上位層が担う。
public struct SSEParser: Sendable {
    private var buffer = ""
    private var event: String?
    private var dataLines: [String] = []
    private var id: String?
    private var retry: Int?

    public init() {}

    /// 受信した生バイトチャンクを内部バッファに追記し、完成したイベントを返す。
    ///
    /// 内部バッファを行境界で分割し、空行を検出するたびに ``SSEEvent`` をディスパッチする。
    /// 1 回の呼び出しで複数のイベントが完成している場合は複数要素を返す。
    ///
    /// - Parameter chunk: HTTP レスポンスボディから受け取った生バイトのチャンク。
    /// - Returns: このチャンクで完成した ``SSEEvent`` の配列。完成イベントがなければ空配列。
    public mutating func consume(_ chunk: Data) -> [SSEEvent] {
        buffer += String(decoding: chunk, as: UTF8.self)
        var events: [SSEEvent] = []
        while let newline = buffer.firstIndex(of: "\n") {
            var line = String(buffer[..<newline])
            buffer = String(buffer[buffer.index(after: newline)...])
            if line.hasSuffix("\r") { line.removeLast() }
            if let event = process(line: line) { events.append(event) }
        }
        return events
    }

    /// ストリーム終端で保留中のイベントをフラッシュする。
    public mutating func finish() -> SSEEvent? {
        process(line: "")
    }

    private mutating func process(line: String) -> SSEEvent? {
        if line.isEmpty {
            guard !dataLines.isEmpty || event != nil else { return nil }
            let result = SSEEvent(event: event, data: dataLines.joined(separator: "\n"), id: id, retry: retry)
            event = nil; dataLines = []; retry = nil
            return result
        }
        if line.hasPrefix(":") { return nil } // comment
        let field: String
        let value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var rest = line[line.index(after: colon)...]
            if rest.first == " " { rest = rest.dropFirst() }
            value = String(rest)
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event": event = value
        case "data": dataLines.append(value)
        case "id": id = value
        case "retry": retry = Int(value)
        default: break
        }
        return nil
    }
}

extension HTTPStreamingTransport {
    /// 生バイトストリームをデコード済みの ``SSEEvent`` ストリームに変換する。
    public func sseEvents(_ request: HTTPRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        let byteStream = stream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                do {
                    for try await chunk in byteStream {
                        for event in parser.consume(chunk) { continuation.yield(event) }
                    }
                    if let last = parser.finish() { continuation.yield(last) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
