import Foundation

/// A decoded Server-Sent Events frame (WHATWG `text/event-stream`).
public struct SSEEvent: Sendable, Equatable {
    /// Named event type, or `nil` for the default `"message"` event.
    public var event: String?
    /// The event payload, with multiple `data:` lines joined by `\n`.
    public var data: String
    /// Last event ID for reconnection bookkeeping.
    public var id: String?
    /// Reconnection time hint from the server (milliseconds), per the WHATWG
    /// SSE spec `retry:` field. Unrelated to ``RetryPolicy``.
    public var retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// Incremental SSE frame parser. Feed raw bytes; receive complete events.
///
/// Splits on line boundaries and dispatches an event on a blank line, joining
/// multiple `data:` lines with `\n` per the spec. Provider-specific meaning of
/// the events is interpreted upstream, not here.
public struct SSEParser: Sendable {
    private var buffer = ""
    private var event: String?
    private var dataLines: [String] = []
    private var id: String?
    private var retry: Int?

    public init() {}

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

    /// Flushes any pending event at end of stream.
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
    /// Adapts a raw byte stream into a stream of decoded ``SSEEvent``s.
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
