import Foundation

/// A transport for tests that answers from a script instead of the network.
///
/// Every request is kept in ``recordedRequests`` for assertions afterwards.
///
/// Note that ``stream(_:)`` ignores the scripted outcomes entirely: it always
/// replays `streamChunks` and always succeeds, so streaming failure paths
/// cannot be exercised through it.
public final class MockTransport: HTTPTransport, HTTPStreamingTransport, @unchecked Sendable {
    /// One scripted answer, consumed by a single ``send(_:)`` call.
    public enum Outcome: Sendable {
        /// Return this response, whatever its status.
        case response(HTTPResponse)
        /// Throw this error instead of answering.
        case failure(any Error)
    }

    private let lock = NSLock()
    private var scripted: [Outcome]
    private let handler: (@Sendable (HTTPRequest) throws -> HTTPResponse)?
    private var streamChunks: [Data]

    /// Requests seen so far, in arrival order.
    ///
    /// Reading this while requests are still in flight is not synchronised;
    /// assert on it once the calls under test have finished.
    public private(set) var recordedRequests: [HTTPRequest] = []

    /// Creates a transport that answers from a fixed script.
    ///
    /// Outcomes are consumed in order, one per ``send(_:)`` call, which is what
    /// you want for "fail twice, then succeed" style tests. Once the script
    /// runs out every further call returns an empty 200.
    ///
    /// - Parameters:
    ///   - outcomes: Answers for successive ``send(_:)`` calls.
    ///   - streamChunks: Bytes for ``stream(_:)`` to yield, replayed in full on
    ///     every call regardless of `outcomes`.
    public init(_ outcomes: [Outcome] = [], streamChunks: [Data] = []) {
        self.scripted = outcomes
        self.handler = nil
        self.streamChunks = streamChunks
    }

    /// Creates a transport that computes each answer from the request.
    ///
    /// Use when the response has to depend on what was sent — a different body
    /// per URL, say. Unlike the scripted form this never runs out, and the
    /// closure takes precedence over any scripted outcomes.
    ///
    /// - Parameter handler: Produces a response, or throws, for each request.
    public init(handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        self.scripted = []
        self.handler = handler
        self.streamChunks = []
    }

    /// Creates a transport that answers one request, then falls back to empty 200s.
    ///
    /// - Parameters:
    ///   - status: Status for the first response.
    ///   - headers: Headers for the first response.
    ///   - body: Body for the first response.
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
