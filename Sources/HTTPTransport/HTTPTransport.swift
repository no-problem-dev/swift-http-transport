import Foundation
#if canImport(FoundationNetworking)
// On Linux the URL loading system ships as a module of its own rather than as
// part of Foundation, so `URLSession`, `URLRequest` and `HTTPURLResponse` are
// only in scope once this is imported.
import FoundationNetworking
#endif

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
    /// is ever yielded. The error payload is collected so it can be reported,
    /// but only up to a bound — see ``URLSessionTransport/maxErrorBodyBytes`` —
    /// so the far end cannot answer a stream with an unbounded allocation.
    /// Network failure and cancellation fail the stream with ``TransportError``.
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

    /// How much of a non-2xx body ``stream(_:)`` will hold before giving up on
    /// the rest.
    ///
    /// A streamed error still has to be collected to be reported, and a server
    /// under load can answer with an error page of any size at all. Past this
    /// many bytes the request is cancelled and ``HTTPStatusError/body`` carries
    /// the truncated prefix, so a stream can never be turned into an unbounded
    /// allocation by the far end.
    public var maxErrorBodyBytes = 64 * 1024

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
        } catch {
            throw Self.transportError(from: error)
        }
    }

    /// Classifies a failure from the URL loading system.
    ///
    /// Cancellation reaches us as `URLError.cancelled`, not as a
    /// `CancellationError`: `URLSession`'s async methods cancel the underlying
    /// task and report the loading system's own error. Matching only
    /// `CancellationError` therefore left ``TransportError/cancelled``
    /// unreachable and handed callers a `URLError -999` wrapped in
    /// ``TransportError/network(_:)`` instead.
    fileprivate static func transportError(from error: any Error) -> TransportError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        return .network(error)
    }

    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        let urlRequest = makeURLRequest(request)
        let session = self.session
        let errorLimit = maxErrorBodyBytes
        return AsyncThrowingStream { continuation in
            let delegate = StreamingSessionDelegate(
                continuation: continuation,
                maxErrorBodyBytes: errorLimit
            )
            #if canImport(FoundationNetworking)
            // swift-corelibs-foundation has no per-task delegate, so a delegate
            // can only be attached when a session is created. Rebuilding one
            // from this transport's configuration keeps any URLProtocol stub and
            // caching policy the caller installed.
            let delegateSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
            let task = delegateSession.dataTask(with: urlRequest)
            #else
            let task = session.dataTask(with: urlRequest)
            task.delegate = delegate
            #endif
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
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

    fileprivate static func headers(from http: HTTPURLResponse) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (key, value) in http.allHeaderFields {
            if let name = key as? String, let value = value as? String { headers[name] = value }
        }
        return headers
    }

    /// How much body is gathered before a chunk is handed to the caller.
    fileprivate static let chunkSize = 4096
}

/// The failure a stream reports when the server answered with a non-2xx status.
///
/// Only ``HTTPStreamingTransport/stream(_:)`` throws this; the buffered
/// ``HTTPTransport/send(_:)`` path returns a non-2xx as a normal response
/// instead. The body is the complete error payload, drained before the throw.
public struct HTTPStatusError: Error, Sendable {
    public let status: Int
    public let headers: HTTPHeaders

    /// The error payload, truncated to ``URLSessionTransport/maxErrorBodyBytes``
    /// when the server sent more than that.
    public let body: Data

    /// Builds a status failure.
    ///
    /// Public so callers can fake one — a stubbed streaming transport has no
    /// other way to reproduce a non-2xx for the code under test.
    public init(status: Int, headers: HTTPHeaders, body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Carries one streamed request, on every platform.
///
/// This is the single implementation of streaming. It used to be the fallback
/// for platforms lacking `URLSession.bytes(for:)`, with Apple served by an
/// `AsyncBytes` loop that appended one byte at a time — roughly ten thousand
/// awaits per ten kilobytes — and that drained an entire error body before
/// throwing. Two implementations of one contract also drifted: only this one
/// ever mapped a cancelled task to ``TransportError/cancelled``. The delegate
/// callbacks hand over `Data` as it arrives, so this path needs neither the
/// per-byte loop nor a second copy of the rules.
///
/// The contract: body arrives in chunks of at most
/// ``URLSessionTransport/chunkSize``, a non-2xx fails with ``HTTPStatusError``
/// carrying at most ``URLSessionTransport/maxErrorBodyBytes`` of the error
/// payload and yields no chunk, a reply that is not HTTP fails with
/// ``TransportError/invalidResponse``, and cancellation surfaces as
/// ``TransportError/cancelled``.
///
/// State is reached from the delegate queue and from `onTermination`, so it is
/// guarded by a lock rather than by an actor — the delegate methods are
/// synchronous and cannot await isolation.
private final class StreamingSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let maxErrorBodyBytes: Int
    private let lock = NSLock()
    private var status: Int?
    private var headers = HTTPHeaders()
    private var buffer = Data()
    private var isSuccess = true

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation, maxErrorBodyBytes: Int) {
        self.continuation = continuation
        self.maxErrorBodyBytes = max(0, maxErrorBodyBytes)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            continuation.finish(throwing: TransportError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        lock.withLock {
            status = http.statusCode
            headers = URLSessionTransport.headers(from: http)
            isSuccess = (200..<300).contains(http.statusCode)
        }
        completionHandler(.allow)
    }

    /// What arriving bytes should cause, decided under the lock and acted on
    /// outside it.
    private enum Delivery {
        case chunks([Data])
        case truncatedError(HTTPStatusError)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // The buffer is drained in fixed slices rather than handed over whole, so
        // that one large delegate callback still arrives as a sequence of
        // 4 KB chunks rather than as a single allocation the size of the read.
        //
        // An error body is held back instead, so it can travel inside
        // HTTPStatusError, which is why only the success path drains here — and
        // why only the error path needs a ceiling.
        let delivery: Delivery = lock.withLock {
            buffer.append(data)
            guard isSuccess else {
                guard buffer.count > maxErrorBodyBytes, let status else { return .chunks([]) }
                let truncated = Data(buffer.prefix(maxErrorBodyBytes))
                buffer.removeAll()
                return .truncatedError(
                    HTTPStatusError(status: status, headers: headers, body: truncated)
                )
            }
            var chunks: [Data] = []
            while buffer.count >= URLSessionTransport.chunkSize {
                chunks.append(Data(buffer.prefix(URLSessionTransport.chunkSize)))
                buffer.removeFirst(URLSessionTransport.chunkSize)
            }
            return chunks.isEmpty ? .chunks([]) : .chunks(chunks)
        }
        switch delivery {
        case .chunks(let chunks):
            for chunk in chunks { continuation.yield(chunk) }
        case .truncatedError(let error):
            // Report what was read and stop reading; the completion callback
            // that the cancellation triggers finds the stream already finished.
            continuation.finish(throwing: error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        #if canImport(FoundationNetworking)
        // Only the Linux path owns its session. On Apple the delegate is
        // attached per task, so the session belongs to the caller and
        // invalidating it would tear down every other request on it.
        defer { session.finishTasksAndInvalidate() }
        #endif

        if let error {
            continuation.finish(throwing: URLSessionTransport.transportError(from: error))
            return
        }

        let (remaining, succeeded, finalStatus, finalHeaders) = lock.withLock {
            (buffer, isSuccess, status, headers)
        }
        guard let finalStatus else {
            continuation.finish(throwing: TransportError.invalidResponse)
            return
        }
        guard succeeded else {
            continuation.finish(
                throwing: HTTPStatusError(status: finalStatus, headers: finalHeaders, body: remaining)
            )
            return
        }
        if !remaining.isEmpty { continuation.yield(remaining) }
        continuation.finish()
    }
}
