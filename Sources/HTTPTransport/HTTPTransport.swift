import Foundation

/// The one seam through which a request is sent and a whole response awaited.
///
/// Everything above this layer depends on the protocol rather than on
/// `URLSession`, so the transport can be swapped for a mock, wrapped in a
/// decorator such as ``RetryingTransport``, or replaced outright without any
/// call site changing.
public protocol HTTPTransport: Sendable {
    /// Sends a request and waits for the complete response.
    ///
    /// An HTTP status is not an error here. A 404 or a 500 comes back as an
    /// ordinary ``HTTPResponse``; check ``HTTPResponse/isSuccess`` before
    /// treating the body as a success payload. Only failures that stop a
    /// response from forming at all are thrown.
    ///
    /// The body is fully buffered in memory before this returns. This is the
    /// opposite of ``HTTPStreamingTransport/stream(_:)``, which delivers bytes
    /// as they arrive and does throw on a non-2xx status.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: The complete response, non-2xx ones included.
    /// - Throws: ``TransportError`` on network failure, on cancellation, or
    ///   when the reply is not an HTTP response.
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// A transport that hands back body bytes as they arrive instead of buffering.
public protocol HTTPStreamingTransport: Sendable {
    /// Sends a request and yields the response body in chunks as it arrives.
    ///
    /// Meant for long-lived bodies such as server-sent events. The stream
    /// finishes normally once every byte has been delivered.
    ///
    /// A non-2xx status fails the stream with ``HTTPStatusError`` and no chunk
    /// is ever yielded — the error body is drained in full first, so a large
    /// error page is held in memory before the throw. Network failure and
    /// cancellation fail the stream with ``TransportError``.
    ///
    /// Ending the returned stream — breaking out of the loop, or cancelling the
    /// surrounding task — cancels the underlying request.
    ///
    /// - Parameter request: The request to send.
    /// - Returns: A stream of body chunks, each flushed at roughly 4 KB.
    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error>
}

/// The production transport, backed by `URLSession`.
public struct URLSessionTransport: HTTPTransport, HTTPStreamingTransport {
    /// The session carrying every request, buffered and streamed alike.
    ///
    /// Pass a configured session to install a `URLProtocol` stub in tests, or
    /// to change caching, proxy, and connection-reuse behaviour.
    public let session: URLSession

    /// Timeout in seconds for requests that do not carry one of their own.
    ///
    /// A request's own ``HTTPRequest/timeout`` always wins. This maps to
    /// `URLRequest.timeoutInterval`, which bounds the wait for *more data*
    /// rather than the total call, so a slowly trickling response can outlive
    /// it without ever timing out.
    public var defaultTimeout: TimeInterval

    /// Creates a transport over the given session.
    ///
    /// - Parameters:
    ///   - session: The session to send through. Defaults to `URLSession.shared`.
    ///   - defaultTimeout: Fallback timeout for requests that omit their own.
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
        } catch let error as TransportError {
            throw error
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
                } catch let error as HTTPStatusError {
                    continuation.finish(throwing: error)
                } catch let error as TransportError {
                    continuation.finish(throwing: error)
                } catch is CancellationError {
                    continuation.finish(throwing: TransportError.cancelled)
                } catch {
                    continuation.finish(throwing: TransportError.network(error))
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

/// The failure a stream reports when the server answered with a non-2xx status.
///
/// Only ``HTTPStreamingTransport/stream(_:)`` throws this; the buffered
/// ``HTTPTransport/send(_:)`` path returns a non-2xx as a normal response
/// instead. The body is the complete error payload, drained before the throw.
public struct HTTPStatusError: Error, Sendable {
    public let status: Int
    public let headers: HTTPHeaders
    public let body: Data
}
