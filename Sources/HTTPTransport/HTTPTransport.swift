import Foundation

/// The single seam for sending an HTTP request and awaiting a full response.
///
/// All higher layers (api-client, providers) depend on this abstraction rather
/// than `URLSession`, so transport can be mocked, decorated (retry), or swapped
/// without touching call sites.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Streaming counterpart: yields raw byte chunks as they arrive (for SSE etc.).
public protocol HTTPStreamingTransport: Sendable {
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error>
}

/// `URLSession`-backed transport. The default concrete implementation.
public struct URLSessionTransport: HTTPTransport, HTTPStreamingTransport {
    public let session: URLSession
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

/// Thrown by streaming when the server responds with a non-2xx status.
public struct HTTPStatusError: Error, Sendable {
    public let status: Int
    public let headers: HTTPHeaders
    public let body: Data
}
