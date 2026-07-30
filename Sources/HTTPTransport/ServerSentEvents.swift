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
    /// 生バイトのままバッファする。行分割は必ずバイトレベルで行う —
    /// Swift の String は `\r\n` を 1 書記素として扱うため、String に対する
    /// `firstIndex(of: "\n")` は CRLF 行末のストリームで行境界を一切検出できない。
    /// バイト保持は UTF-8 マルチバイト文字がチャンク境界で分断されるケースも
    /// 同時に解決する（String 変換は完成した行に対してのみ行う）。
    private var buffer: [UInt8] = []
    private var event: String?
    private var dataLines: [String] = []
    private var id: String?
    private var retry: Int?

    public init() {}

    /// 受信した生バイトチャンクを内部バッファに追記し、完成したイベントを返す。
    ///
    /// 内部バッファを行境界（LF。直前の CR は除去 = CRLF 対応）で分割し、
    /// 空行を検出するたびに ``SSEEvent`` をディスパッチする。
    /// 1 回の呼び出しで複数のイベントが完成している場合は複数要素を返す。
    ///
    /// - Parameter chunk: HTTP レスポンスボディから受け取った生バイトのチャンク。
    /// - Returns: このチャンクで完成した ``SSEEvent`` の配列。完成イベントがなければ空配列。
    public mutating func consume(_ chunk: Data) -> [SSEEvent] {
        buffer.append(contentsOf: chunk)
        var events: [SSEEvent] = []
        var start = 0
        var index = 0
        while index < buffer.count {
            if buffer[index] == 0x0A {
                var line = buffer[start ..< index]
                if line.last == 0x0D {
                    line = line.dropLast()
                }
                if let event = process(line: String(decoding: line, as: UTF8.self)) {
                    events.append(event)
                }
                start = index + 1
            }
            index += 1
        }
        buffer.removeFirst(start)
        return events
    }

    /// ストリーム終端で保留中のイベントをフラッシュする。
    /// 末尾改行なしで終わったストリームの最終行も処理してからフラッシュする。
    public mutating func finish() -> SSEEvent? {
        if !buffer.isEmpty {
            var line = buffer[...]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            buffer.removeAll()
            if let event = process(line: String(decoding: line, as: UTF8.self)) {
                return event
            }
        }
        return process(line: "")
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
