import Foundation

/// A transport for tests that answers from a script instead of the network.
///
/// Every request is kept in ``recordedRequests`` for assertions afterwards.
///
/// ``send(_:)`` and ``stream(_:)`` draw on the same script, one outcome per
/// call, so a streamed request can be made to fail exactly as a sent one can.
/// The two differ only in how a successful outcome is delivered: `send` returns
/// the scripted response whole, while `stream` yields `streamChunks` — a
/// scripted response contributes only its status and headers to a stream.
public final class MockTransport: HTTPTransport, HTTPStreamingTransport, @unchecked Sendable {
    /// One scripted answer, consumed by a single ``send(_:)`` or ``stream(_:)`` call.
    public enum Outcome: Sendable {
        /// Return this response, whatever its status.
        ///
        /// On ``stream(_:)`` a non-2xx status becomes an ``HTTPStatusError``
        /// carrying this response's headers and body, matching what
        /// ``URLSessionTransport`` does.
        case response(HTTPResponse)
        /// Throw this error instead of answering.
        case failure(any Error)
    }

    private let lock = NSLock()
    private var scripted: [Outcome]
    private let handler: (@Sendable (HTTPRequest) throws -> HTTPResponse)?
    private var streamChunks: [Data]
    private var recorded: [HTTPRequest] = []

    /// Requests seen so far, in arrival order.
    ///
    /// Read under the same lock that guards recording, so this is safe to
    /// consult while other requests are still in flight.
    public var recordedRequests: [HTTPRequest] { lock.withLock { recorded } }

    /// Creates a transport that answers from a fixed script.
    ///
    /// Outcomes are consumed in order, one per ``send(_:)`` call, which is what
    /// you want for "fail twice, then succeed" style tests. Once the script
    /// runs out every further call returns an empty 200.
    ///
    /// - Parameters:
    ///   - outcomes: Answers for successive ``send(_:)`` and ``stream(_:)`` calls.
    ///   - streamChunks: Bytes for ``stream(_:)`` to yield whenever its outcome
    ///     is a success, replayed in full on every such call.
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
            switch nextOutcome(for: request) {
            case .response(let response): return response
            case .failure(let error): throw error
            }
        }
    }

    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        enum Plan {
            case chunks([Data])
            case failure(any Error)
        }
        let plan: Plan = lock.withLock {
            switch nextOutcome(for: request) {
            case .failure(let error):
                return .failure(error)
            case .response(let response):
                guard response.isSuccess else {
                    return .failure(
                        HTTPStatusError(
                            status: response.status,
                            headers: response.headers,
                            body: response.body
                        )
                    )
                }
                return .chunks(streamChunks)
            }
        }
        return AsyncThrowingStream { continuation in
            switch plan {
            case .chunks(let chunks):
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }

    /// Records the request and picks the answer for it. Call holding `lock`.
    private func nextOutcome(for request: HTTPRequest) -> Outcome {
        recorded.append(request)
        if let handler {
            do { return .response(try handler(request)) } catch { return .failure(error) }
        }
        guard !scripted.isEmpty else {
            return .response(HTTPResponse(status: 200, headers: [:], body: Data()))
        }
        return scripted.removeFirst()
    }
}
