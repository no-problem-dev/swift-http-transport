import Foundation

/// Deterministic transport for tests. Responds from a script of canned
/// responses (or a closure), recording the requests it received.
public final class MockTransport: HTTPTransport, HTTPStreamingTransport, @unchecked Sendable {
    public enum Outcome: Sendable {
        case response(HTTPResponse)
        case failure(any Error)
    }

    private let lock = NSLock()
    private var scripted: [Outcome]
    private let handler: (@Sendable (HTTPRequest) throws -> HTTPResponse)?
    private var streamChunks: [Data]
    public private(set) var recordedRequests: [HTTPRequest] = []

    public init(_ outcomes: [Outcome] = [], streamChunks: [Data] = []) {
        self.scripted = outcomes
        self.handler = nil
        self.streamChunks = streamChunks
    }

    public init(handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        self.scripted = []
        self.handler = handler
        self.streamChunks = []
    }

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
