import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HTTPTransport

/// A `URLProtocol` stub that answers `URLSession` without touching the network.
///
/// Scripts are registered per URL so the real `URLSessionTransport` is exercised
/// through the actual URL loading system. Keying both the scripts and the
/// received requests by URL keeps parallel tests from colliding.
final class StubURLProtocol: URLProtocol {
    enum Script {
        /// Answer with an HTTP response. Each chunk is delivered as one `didLoad`.
        case http(status: Int, headers: [String: String] = [:], chunks: [Data] = [])
        /// Fail the load with the given error.
        case failure(any Error)
        /// Answer with a bare `URLResponse`, which is not an `HTTPURLResponse`.
        case nonHTTPResponse
        /// Never answer, so the caller can cancel a request that is in flight.
        case hang
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [URL: Script] = [:]
    nonisolated(unsafe) private static var received: [URL: (request: URLRequest, body: Data?)] = [:]

    static func register(_ script: Script, for url: URL) {
        lock.withLock { scripts[url] = script }
    }

    /// The request the stub received, with its body already read from the stream.
    static func received(for url: URL) -> (request: URLRequest, body: Data?)? {
        lock.withLock { received[url] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let script = Self.lock.withLock({ Self.scripts[url] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let body = Self.bodyData(of: request)
        Self.lock.withLock { Self.received[url] = (request, body) }
        switch script {
        case .http(let status, let headers, let chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .nonHTTPResponse:
            let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    /// `URLSession` converts the body to an `httpBodyStream`, so read it back out.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private func makeStubbedTransport(defaultTimeout: TimeInterval = 60) -> URLSessionTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSessionTransport(session: URLSession(configuration: configuration), defaultTimeout: defaultTimeout)
}

/// Waits until the stub has actually started loading, so a cancellation lands
/// on a request that is in flight rather than on one not yet begun.
private func waitUntilRequestStarted(_ url: URL) async {
    for _ in 0 ..< 400 {
        if StubURLProtocol.received(for: url) != nil { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("スタブがリクエストを受け取らなかった")
}

/// The cancellation the URL loading system reports for a cancelled task.
///
/// It is a `URLError`, never a `CancellationError` — which is why matching only
/// the latter left ``TransportError/cancelled`` unreachable.
struct CancellationTests {
    @Test("cancelling a send surfaces as TransportError.cancelled, not as a network error")
    func cancellingSendYieldsCancelled() async {
        let url = URL(string: "https://stub.test/cancel/send")!
        StubURLProtocol.register(.hang, for: url)
        let transport = makeStubbedTransport()

        let task = Task { try await transport.send(HTTPRequest(method: "GET", url: url)) }
        await waitUntilRequestStarted(url)
        task.cancel()

        switch await task.result {
        case .success:
            Issue.record("キャンセルされたのにレスポンスが返った")
        case .failure(let error):
            #expect(error as? TransportError != nil)
            guard case .cancelled? = error as? TransportError else {
                Issue.record("TransportError.cancelled を期待したが \(error) だった")
                return
            }
        }
    }

    @Test("a URLError.cancelled from the loading system maps to TransportError.cancelled on send")
    func urlErrorCancelledMapsToCancelledOnSend() async {
        let url = URL(string: "https://stub.test/cancel/send-urlerror")!
        StubURLProtocol.register(.failure(URLError(.cancelled)), for: url)
        do {
            _ = try await makeStubbedTransport().send(HTTPRequest(method: "GET", url: url))
            Issue.record("エラーがスローされるべき")
        } catch let error as TransportError {
            guard case .cancelled = error else {
                Issue.record("TransportError.cancelled を期待したが \(error) だった")
                return
            }
        } catch {
            Issue.record("TransportError を期待したが \(error) だった")
        }
    }

    @Test("the same mapping applies to the streaming path")
    func urlErrorCancelledMapsToCancelledOnStream() async {
        let url = URL(string: "https://stub.test/cancel/stream")!
        StubURLProtocol.register(.failure(URLError(.cancelled)), for: url)
        do {
            for try await _ in makeStubbedTransport().stream(HTTPRequest(method: "GET", url: url)) {}
            Issue.record("エラーがスローされるべき")
        } catch let error as TransportError {
            guard case .cancelled = error else {
                Issue.record("TransportError.cancelled を期待したが \(error) だった")
                return
            }
        } catch {
            Issue.record("TransportError を期待したが \(error) だった")
        }
    }

    @Test("an ordinary network failure is still reported as one")
    func otherURLErrorsRemainNetworkFailures() async {
        let url = URL(string: "https://stub.test/cancel/not-cancelled")!
        StubURLProtocol.register(.failure(URLError(.notConnectedToInternet)), for: url)
        do {
            _ = try await makeStubbedTransport().send(HTTPRequest(method: "GET", url: url))
            Issue.record("エラーがスローされるべき")
        } catch TransportError.network(let underlying) {
            #expect((underlying as? URLError)?.code == .notConnectedToInternet)
        } catch {
            Issue.record("TransportError.network を期待したが \(error) だった")
        }
    }
}

struct URLSessionTransportSendTests {
    @Test
    func sendDeliversRequestAndParsesResponse() async throws {
        let url = URL(string: "https://stub.test/send/success")!
        StubURLProtocol.register(
            .http(status: 201, headers: ["X-Trace": "abc"], chunks: [Data("created".utf8)]),
            for: url
        )
        let request = HTTPRequest(
            method: "POST",
            url: url,
            headers: ["X-Client": "t", "Content-Type": "application/json"],
            body: Data("payload".utf8),
            timeout: 5
        )
        let response = try await makeStubbedTransport().send(request)
        #expect(response.status == 201)
        #expect(response.isSuccess)
        #expect(response.headers["x-trace"] == "abc")
        #expect(String(decoding: response.body, as: UTF8.self) == "created")

        let received = try #require(StubURLProtocol.received(for: url))
        #expect(received.request.httpMethod == "POST")
        #expect(received.request.value(forHTTPHeaderField: "X-Client") == "t")
        #expect(received.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(received.request.timeoutInterval == 5)
        #expect(received.body.map { String(decoding: $0, as: UTF8.self) } == "payload")
    }

    @Test
    func sendAppliesDefaultTimeoutWhenRequestOmitsIt() async throws {
        let url = URL(string: "https://stub.test/send/default-timeout")!
        StubURLProtocol.register(.http(status: 200), for: url)
        _ = try await makeStubbedTransport(defaultTimeout: 42).send(HTTPRequest(method: "GET", url: url))
        let received = try #require(StubURLProtocol.received(for: url))
        #expect(received.request.timeoutInterval == 42)
    }

    @Test
    func sendReturnsNon2xxAsResponseNotError() async throws {
        let url = URL(string: "https://stub.test/send/404")!
        StubURLProtocol.register(.http(status: 404, chunks: [Data("missing".utf8)]), for: url)
        let response = try await makeStubbedTransport().send(HTTPRequest(method: "GET", url: url))
        #expect(response.status == 404)
        #expect(!response.isSuccess)
        #expect(String(decoding: response.body, as: UTF8.self) == "missing")
    }

    @Test
    func sendWrapsNetworkFailureInTransportError() async {
        let url = URL(string: "https://stub.test/send/network-error")!
        StubURLProtocol.register(.failure(URLError(.notConnectedToInternet)), for: url)
        do {
            _ = try await makeStubbedTransport().send(HTTPRequest(method: "GET", url: url))
            Issue.record("エラーがスローされるべき")
        } catch TransportError.network(let underlying) {
            #expect((underlying as? URLError)?.code == .notConnectedToInternet)
        } catch {
            Issue.record("TransportError.network を期待したが \(error) がスローされた")
        }
    }

    @Test
    func sendMapsNonHTTPResponseToInvalidResponse() async {
        let url = URL(string: "https://stub.test/send/non-http")!
        StubURLProtocol.register(.nonHTTPResponse, for: url)
        do {
            _ = try await makeStubbedTransport().send(HTTPRequest(method: "GET", url: url))
            Issue.record("エラーがスローされるべき")
        } catch let error as TransportError {
            guard case .invalidResponse = error else {
                Issue.record("TransportError.invalidResponse を期待したが \(error) がスローされた")
                return
            }
        } catch {
            Issue.record("TransportError を期待したが \(error) がスローされた")
        }
    }
}

struct URLSessionTransportStreamTests {
    @Test
    func streamDeliversAllBytes() async throws {
        let url = URL(string: "https://stub.test/stream/bytes")!
        StubURLProtocol.register(
            .http(status: 200, chunks: [Data("hello ".utf8), Data("world".utf8)]),
            for: url
        )
        var collected = Data()
        for try await chunk in makeStubbedTransport().stream(HTTPRequest(method: "GET", url: url)) {
            collected.append(chunk)
        }
        #expect(String(decoding: collected, as: UTF8.self) == "hello world")
    }

    @Test
    func streamFlushesBufferAcross4096ByteBoundary() async throws {
        let url = URL(string: "https://stub.test/stream/large")!
        let body = Data(repeating: 0x61, count: 10_000)
        StubURLProtocol.register(.http(status: 200, chunks: [body]), for: url)
        var collected = Data()
        var chunkCount = 0
        for try await chunk in makeStubbedTransport().stream(HTTPRequest(method: "GET", url: url)) {
            collected.append(chunk)
            chunkCount += 1
        }
        #expect(collected == body)
        #expect(chunkCount >= 2) // split at the 4096-byte buffer boundary
    }

    @Test
    func streamDecodesSSEEventsThroughRealTransport() async throws {
        let url = URL(string: "https://stub.test/stream/sse")!
        StubURLProtocol.register(
            .http(
                status: 200,
                headers: ["Content-Type": "text/event-stream"],
                chunks: [Data("event: delta\ndata: hel".utf8), Data("lo\n\ndata: done\n\n".utf8)]
            ),
            for: url
        )
        var events: [SSEEvent] = []
        for try await event in makeStubbedTransport().sseEvents(HTTPRequest(method: "GET", url: url)) {
            events.append(event)
        }
        #expect(events == [SSEEvent(event: "delta", data: "hello"), SSEEvent(data: "done")])
    }

    @Test
    func streamThrowsHTTPStatusErrorWithAggregatedBodyOnNon2xx() async {
        let url = URL(string: "https://stub.test/stream/429")!
        StubURLProtocol.register(
            .http(status: 429, headers: ["Retry-After": "7"], chunks: [Data("rate ".utf8), Data("limited".utf8)]),
            for: url
        )
        do {
            for try await _ in makeStubbedTransport().stream(HTTPRequest(method: "GET", url: url)) {
                Issue.record("2xx 以外ではチャンクが yield されないべき")
            }
            Issue.record("エラーがスローされるべき")
        } catch let error as HTTPStatusError {
            #expect(error.status == 429)
            #expect(error.headers["retry-after"] == "7")
            #expect(String(decoding: error.body, as: UTF8.self) == "rate limited")
        } catch {
            Issue.record("HTTPStatusError を期待したが \(error) がスローされた")
        }
    }

    /// The streaming path exists so a body never has to be held whole, but a
    /// non-2xx used to drain all of it before throwing — so an unbounded error
    /// page was materialised in full on exactly the path meant to prevent that.
    @Test("a huge error body is truncated rather than held whole")
    func errorBodyIsCappedAtTheConfiguredLimit() async {
        let url = URL(string: "https://stub.test/stream/huge-error")!
        let huge = Data(repeating: 0x62, count: 2_000_000)
        StubURLProtocol.register(.http(status: 500, chunks: [huge]), for: url)

        var transport = makeStubbedTransport()
        transport.maxErrorBodyBytes = 4096
        do {
            for try await _ in transport.stream(HTTPRequest(method: "GET", url: url)) {
                Issue.record("2xx 以外ではチャンクが yield されないべき")
            }
            Issue.record("エラーがスローされるべき")
        } catch let error as HTTPStatusError {
            #expect(error.status == 500)
            #expect(error.body.count == 4096)
        } catch {
            Issue.record("HTTPStatusError を期待したが \(error) だった")
        }
    }

    @Test("an error body under the cap still arrives whole")
    func errorBodyUnderTheCapIsNotTruncated() async {
        let url = URL(string: "https://stub.test/stream/small-error")!
        StubURLProtocol.register(.http(status: 400, chunks: [Data("bad request".utf8)]), for: url)
        var transport = makeStubbedTransport()
        transport.maxErrorBodyBytes = 4096
        do {
            for try await _ in transport.stream(HTTPRequest(method: "GET", url: url)) {}
            Issue.record("エラーがスローされるべき")
        } catch let error as HTTPStatusError {
            #expect(String(decoding: error.body, as: UTF8.self) == "bad request")
        } catch {
            Issue.record("HTTPStatusError を期待したが \(error) だった")
        }
    }

    @Test("a large success body still streams in chunks rather than being buffered")
    func largeSuccessBodyArrivesInManyChunks() async throws {
        let url = URL(string: "https://stub.test/stream/large-success")!
        let body = Data(repeating: 0x63, count: 200_000)
        StubURLProtocol.register(.http(status: 200, chunks: [body]), for: url)
        var collected = Data()
        var chunkCount = 0
        var largest = 0
        for try await chunk in makeStubbedTransport().stream(HTTPRequest(method: "GET", url: url)) {
            collected.append(chunk)
            chunkCount += 1
            largest = max(largest, chunk.count)
        }
        #expect(collected == body)
        #expect(chunkCount >= 48)
        #expect(largest <= 4096)
    }

    @Test
    func streamWrapsNetworkFailureInTransportError() async {
        let url = URL(string: "https://stub.test/stream/network-error")!
        StubURLProtocol.register(.failure(URLError(.timedOut)), for: url)
        do {
            for try await _ in makeStubbedTransport().stream(HTTPRequest(method: "GET", url: url)) {}
            Issue.record("エラーがスローされるべき")
        } catch TransportError.network(let underlying) {
            #expect((underlying as? URLError)?.code == .timedOut)
        } catch {
            Issue.record("TransportError.network を期待したが \(error) がスローされた")
        }
    }
}
