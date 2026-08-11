import Foundation

/// One decoded frame from a `text/event-stream` body.
public struct SSEEvent: Sendable, Equatable {
    /// The event type, or `nil` when the frame carried no `event:` field.
    public var event: String?

    /// The payload, with repeated `data:` lines joined by newlines per the spec.
    public var data: String

    /// The last event ID seen.
    ///
    /// Carries forward from earlier frames until the server sends a new one, so
    /// this can be set on a frame that had no `id:` field of its own.
    public var id: String?

    /// The server's reconnection hint in milliseconds.
    ///
    /// This is the SSE `retry:` field and is unrelated to ``RetryPolicy``.
    /// Nothing in this package reconnects, so acting on it is the caller's job.
    public var retry: Int?

    public init(event: String? = nil, data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

/// An incremental parser turning raw bytes into complete SSE frames.
///
/// Feed it whatever arrives, in whatever sizes it arrives; it splits on line
/// boundaries and emits a frame at each blank line. Repeated `data:` lines are
/// joined with newlines as the spec requires. What a frame *means* to a given
/// provider is for a higher layer to decide.
public struct SSEParser: Sendable {
    /// Buffers raw bytes, because line splitting has to happen at byte level.
    ///
    /// Swift treats CR-LF as a single grapheme, so searching a `String` for a
    /// newline finds no line breaks at all in a CRLF stream. That bug shipped
    /// once and produced zero events from a perfectly valid response. Holding
    /// bytes also handles a multi-byte UTF-8 character split across a chunk
    /// boundary; only completed lines are ever decoded to text.
    private var buffer: [UInt8] = []
    private var event: String?
    private var dataLines: [String] = []
    private var id: String?
    private var retry: Int?

    public init() {}

    /// Appends a chunk of received bytes and returns any frames it completed.
    ///
    /// Splits the buffer on LF, dropping a preceding CR so CRLF streams work,
    /// and emits a frame at each blank line. One chunk may complete several
    /// frames, or none — an incomplete frame stays buffered for the next call.
    ///
    /// - Parameter chunk: Raw bytes from the response body.
    /// - Returns: The frames completed by this chunk, empty if none were.
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

    /// Flushes the frame still pending when the stream ends.
    ///
    /// A stream that stops without a trailing blank line leaves a complete
    /// frame in the buffer. Call this once at the end or that frame is lost.
    ///
    /// - Returns: The final frame, or `nil` if nothing was pending.
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
        if line.hasPrefix(":") { return nil } // an SSE comment line, often a keep-alive
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
    /// Decodes a raw byte stream into SSE frames.
    ///
    /// Chunk boundaries are absorbed by the parser, so a frame split across two
    /// network reads still arrives whole, and a stream ending without a blank
    /// line still yields its last frame. Errors from the byte stream propagate
    /// unchanged, including ``HTTPStatusError`` for a non-2xx status. Ending
    /// this stream cancels the underlying request.
    ///
    /// - Parameter request: The request to send. Set `Accept` to
    ///   `text/event-stream` yourself; nothing is added here.
    /// - Returns: A stream of decoded frames.
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
