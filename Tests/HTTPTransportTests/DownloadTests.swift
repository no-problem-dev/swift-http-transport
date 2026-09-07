import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HTTPTransport

/// A directory that exists for one test and is removed with it.
///
/// Downloads are the one part of this package that touches the file system, so
/// every test here needs somewhere of its own to write — sharing one path would
/// let parallel tests overwrite each other's results.
private final class Scratch {
    let directory: URL

    init(_ name: String) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("http-transport-download-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func file(_ name: String = "payload.bin") -> URL {
        directory.appendingPathComponent(name)
    }

    /// Removed from a `defer` rather than from `deinit`: the last use of this
    /// object is often the call that hands its path to the transport, and ARC
    /// is free to release it there — deleting the directory while the download
    /// that was aimed at it is still running.
    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeStubbedDownloadTransport() -> URLSessionTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSessionTransport(session: URLSession(configuration: configuration))
}

/// Collects progress reports from the loading system's queue.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [DownloadProgress] = []

    var recorded: [DownloadProgress] { lock.withLock { reports } }

    var callback: @Sendable (DownloadProgress) -> Void {
        { [self] progress in lock.withLock { reports.append(progress) } }
    }
}
// A custom `URLProtocol` cannot answer a download task on Linux, so everything
// below needs a stubbed *response* and runs on Apple platforms only.
//
// swift-corelibs-foundation hands the download delegate
// `urlProtocol.properties[.temporaryFileURL] as! URL` (`URLSessionTask.swift:1170`),
// and that property is set in exactly one place — its own internal
// `NativeProtocol` (`NativeProtocol.swift:281`). A `URLProtocol` written by
// anyone else never sets it, so the force-unwrap kills the process instead of
// failing a test. A real download there goes through `NativeProtocol` and is
// unaffected; what cannot be reproduced on Linux is the stub, not the feature.
// The failure paths below, which never reach a response, are outside the guard.
#if !canImport(FoundationNetworking)
@Suite("ファイルへ落とす")
struct URLSessionDownloadTests {
    @Test("the body is written to the destination rather than returned in memory")
    func downloadWritesTheBodyToTheDestination() async throws {
        let scratch = Scratch("writes")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/writes")!
        let body = Data(repeating: 0x61, count: 40_000)
        StubURLProtocol.register(
            .http(status: 200, headers: ["Content-Length": "40000", "X-Trace": "abc"], chunks: [body]),
            for: url
        )

        let destination = scratch.file()
        let file = try await makeStubbedDownloadTransport()
            .download(HTTPRequest(method: "GET", url: url), to: destination)

        #expect(file.url == destination)
        #expect(file.status == 200)
        #expect(file.byteCount == 40_000)
        #expect(file.headers["x-trace"] == "abc")
        #expect(try Data(contentsOf: destination) == body)
    }

    @Test("missing parent directories are created, and an older file is replaced")
    func downloadCreatesDirectoriesAndReplaces() async throws {
        let scratch = Scratch("replaces")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/replaces")!
        StubURLProtocol.register(.http(status: 200, chunks: [Data("new".utf8)]), for: url)

        let destination = scratch.directory
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("payload.bin")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stale and longer".utf8).write(to: destination)

        let file = try await makeStubbedDownloadTransport()
            .download(HTTPRequest(method: "GET", url: url), to: destination)
        #expect(file.byteCount == 3)
        #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "new")
    }

    @Test("progress never goes backwards and ends at the size that landed")
    func progressIsMonotonicAndEndsAtTheTotal() async throws {
        let scratch = Scratch("progress")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/progress")!
        let chunks = (0 ..< 8).map { _ in Data(repeating: 0x62, count: 25_000) }
        let total = chunks.reduce(0) { $0 + $1.count }
        StubURLProtocol.register(
            .http(status: 200, headers: ["Content-Length": "\(total)"], chunks: chunks),
            for: url
        )

        let recorder = ProgressRecorder()
        let file = try await makeStubbedDownloadTransport().download(
            HTTPRequest(method: "GET", url: url),
            to: scratch.file(),
            onProgress: recorder.callback
        )

        let reports = recorder.recorded
        #expect(!reports.isEmpty)
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.received <= $1.received })
        #expect(reports.last?.received == Int64(total))
        #expect(reports.allSatisfy { $0.expected == Int64(total) })
        #expect(reports.last?.fraction == 1)
        #expect(file.byteCount == Int64(total))
    }

    @Test("a total the server did not state is nil rather than a sentinel")
    func progressExpectedIsNilWithoutContentLength() async throws {
        let scratch = Scratch("no-length")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/no-length")!
        StubURLProtocol.register(.http(status: 200, chunks: [Data(repeating: 0x63, count: 5_000)]), for: url)

        let recorder = ProgressRecorder()
        _ = try await makeStubbedDownloadTransport().download(
            HTTPRequest(method: "GET", url: url),
            to: scratch.file(),
            onProgress: recorder.callback
        )

        // A stub without Content-Length leaves the total unknown. Whatever was
        // reported must say so rather than reporting -1 as a byte count — and
        // something must have been reported, or `allSatisfy` passes vacuously.
        #expect(!recorder.recorded.isEmpty)
        #expect(recorder.recorded.allSatisfy { $0.expected == nil && $0.fraction == nil })
    }

    @Test("Content-Range comes back parsed from a ranged answer")
    func contentRangeIsReadableFromTheResult() async throws {
        let scratch = Scratch("range")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/range")!
        StubURLProtocol.register(
            .http(
                status: 206,
                headers: ["Content-Range": "bytes 200-1023/4096", "Content-Length": "824"],
                chunks: [Data(repeating: 0x64, count: 824)]
            ),
            for: url
        )

        let request = HTTPRequest(method: "GET", url: url, headers: ["Range": "bytes=200-1023"])
        let file = try await makeStubbedDownloadTransport().download(request, to: scratch.file())

        #expect(file.status == 206)
        #expect(file.headers.contentLength == 824)
        #expect(file.headers.contentRange == ContentRange(bytes: 200 ... 1023, completeLength: 4096))
        #expect(file.headers.contentRange?.byteCount == 824)
        #expect(file.byteCount == 824)

        // The Range header is the caller's to set; nothing is added here.
        let received = try #require(StubURLProtocol.received(for: url))
        #expect(received.request.value(forHTTPHeaderField: "Range") == "bytes=200-1023")
    }

    @Test("a non-2xx throws with a bounded body and writes nothing")
    func nonSuccessStatusLeavesNoFile() async throws {
        let scratch = Scratch("404")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/404")!
        StubURLProtocol.register(
            .http(status: 404, headers: ["Content-Type": "text/plain"], chunks: [Data("gone".utf8)]),
            for: url
        )

        let destination = scratch.file()
        do {
            _ = try await makeStubbedDownloadTransport().download(HTTPRequest(method: "GET", url: url), to: destination)
            Issue.record("エラーがスローされるべき")
        } catch let error as HTTPStatusError {
            #expect(error.status == 404)
            #expect(String(decoding: error.body, as: UTF8.self) == "gone")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("a huge error page is truncated rather than held whole")
    func errorBodyIsCappedAtTheConfiguredLimit() async throws {
        let scratch = Scratch("huge-error")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/huge-error")!
        StubURLProtocol.register(.http(status: 500, chunks: [Data(repeating: 0x65, count: 2_000_000)]), for: url)

        var transport = makeStubbedDownloadTransport()
        transport.maxErrorBodyBytes = 4096
        do {
            _ = try await transport.download(HTTPRequest(method: "GET", url: url), to: scratch.file())
            Issue.record("エラーがスローされるべき")
        } catch let error as HTTPStatusError {
            #expect(error.status == 500)
            #expect(error.body.count == 4096)
        }
    }

    @Test("a reply that is not HTTP is reported as such")
    func nonHTTPResponseIsInvalidResponse() async throws {
        let scratch = Scratch("non-http")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/non-http")!
        StubURLProtocol.register(.nonHTTPResponse, for: url)
        do {
            _ = try await makeStubbedDownloadTransport().download(HTTPRequest(method: "GET", url: url), to: scratch.file())
            Issue.record("エラーがスローされるべき")
        } catch let interruption as DownloadInterruption {
            guard case .transfer(.invalidResponse) = interruption.reason else {
                Issue.record("transfer(.invalidResponse) を期待したが \(interruption.reason) だった")
                return
            }
            #expect(interruption.resumption == nil)
        }
    }

    /// The bytes arrived; the file system refused them. That is a different
    /// failure from a transfer that stopped, and it carries nothing to resume.
    @Test("a destination that cannot be written is not reported as a transfer failure")
    func unwritableDestinationIsADestinationFailure() async throws {
        let scratch = Scratch("bad-destination")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/bad-destination")!
        StubURLProtocol.register(.http(status: 200, chunks: [Data("ok".utf8)]), for: url)

        // A regular file where a directory would have to be: creating the
        // parent directory fails, so the move never happens.
        let blocker = scratch.file("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let destination = blocker.appendingPathComponent("payload.bin")

        do {
            _ = try await makeStubbedDownloadTransport().download(HTTPRequest(method: "GET", url: url), to: destination)
            Issue.record("エラーがスローされるべき")
        } catch let interruption as DownloadInterruption {
            guard case .destination = interruption.reason else {
                Issue.record("destination を期待したが \(interruption.reason) だった")
                return
            }
            #expect(interruption.resumption == nil)
        }
    }
}
#endif

@Suite("落とすのが止まる")
struct URLSessionDownloadFailureTests {
    @Test("a network failure leaves no half-written file behind")
    func networkFailureLeavesNoFile() async throws {
        let scratch = Scratch("network-error")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/network-error")!
        StubURLProtocol.register(.failure(URLError(.networkConnectionLost)), for: url)

        let destination = scratch.file()
        do {
            _ = try await makeStubbedDownloadTransport().download(HTTPRequest(method: "GET", url: url), to: destination)
            Issue.record("エラーがスローされるべき")
        } catch let interruption as DownloadInterruption {
            guard case .transfer(.network(let underlying)) = interruption.reason else {
                Issue.record("transfer(.network) を期待したが \(interruption.reason) だった")
                return
            }
            #expect((underlying as? URLError)?.code == .networkConnectionLost)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("cancelling a download in flight reports cancellation, not a network error")
    func cancellingSurfacesAsCancelled() async throws {
        let scratch = Scratch("cancel")
        defer { scratch.remove() }
        let url = URL(string: "https://stub.test/download/cancel")!
        StubURLProtocol.register(.hang, for: url)
        let destination = scratch.file()
        let transport = makeStubbedDownloadTransport()

        let task = Task { try await transport.download(HTTPRequest(method: "GET", url: url), to: destination) }
        await waitUntilRequestStarted(url)
        task.cancel()

        switch await task.result {
        case .success:
            Issue.record("キャンセルされたのにファイルが返った")
        case .failure(let error):
            guard let interruption = error as? DownloadInterruption,
                  case .transfer(.cancelled) = interruption.reason
            else {
                Issue.record("DownloadInterruption(.transfer(.cancelled)) を期待したが \(error) だった")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// A `URLProtocol` stub never produces resume data — the loading system
    /// only mints it for a server that answered a ranged request — so the seam
    /// that has to be pinned is the extraction itself.
    @Test("resume data travels in the failure's userInfo and is found there")
    func resumeDataIsReadFromTheFailure() {
        let payload = Data("resume-me".utf8)
        #if canImport(FoundationNetworking)
        let key = URLSessionDownloadTaskResumeData
        #else
        let key = NSURLSessionDownloadTaskResumeData
        #endif
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [key: payload])

        #expect(DownloadResumeData.from(error) == payload)
        #expect(DownloadResumeData.from(URLError(.networkConnectionLost)) == nil)
    }
}

@Suite("Content-Range を読む")
struct ContentRangeTests {
    @Test("the three shapes RFC 9110 §14.4 allows", arguments: [
        ("bytes 0-499/1234", ContentRange(bytes: 0 ... 499, completeLength: 1234)),
        ("bytes 0-499/*", ContentRange(bytes: 0 ... 499, completeLength: nil)),
        ("bytes */1234", ContentRange(bytes: nil, completeLength: 1234)),
        ("  BYTES   200-1023/4096  ", ContentRange(bytes: 200 ... 1023, completeLength: 4096)),
        ("bytes 1233-1233/1234", ContentRange(bytes: 1233 ... 1233, completeLength: 1234)),
    ])
    func parsesTheValidForms(field: String, expected: ContentRange) {
        #expect(ContentRange(field: field) == expected)
    }

    @Test("a field that cannot be made sense of is ignored rather than guessed at", arguments: [
        "",
        "bytes",
        "0-499/1234",           // no unit
        "items 0-499/1234",     // a unit this type cannot describe
        "bytes */*",            // the unsatisfied form must state the size
        "bytes 499-0/1234",     // end before start
        "bytes 0-1234/1234",    // runs past the stated total
        "bytes -5-10/1234",
        "bytes 0-499/abc",
    ])
    func rejectsTheInvalidForms(field: String) {
        #expect(ContentRange(field: field) == nil)
    }

    @Test("the unsatisfied form covers no bytes at all")
    func unsatisfiedRangeCountsZero() {
        #expect(ContentRange(field: "bytes */1234")?.byteCount == 0)
        #expect(ContentRange(field: "bytes 0-0/1234")?.byteCount == 1)
    }

    @Test("headers expose both fields, and absent ones stay nil")
    func headersReadBothFields() {
        let headers: HTTPHeaders = ["content-length": " 824 ", "Content-Range": "bytes 200-1023/4096"]
        #expect(headers.contentLength == 824)
        #expect(headers.contentRange == ContentRange(bytes: 200 ... 1023, completeLength: 4096))

        #expect(HTTPHeaders().contentLength == nil)
        #expect(HTTPHeaders().contentRange == nil)

        let unparseable: HTTPHeaders = ["Content-Length": "not a number", "Content-Range": "items 0-1/2"]
        #expect(unparseable.contentLength == nil)
        #expect(unparseable.contentRange == nil)

        let negative: HTTPHeaders = ["Content-Length": "-1"]
        #expect(negative.contentLength == nil)
    }
}

@Suite("ネットワーク無しで落とす")
struct MockDownloadTests {
    @Test("a scripted body is written to the destination")
    func mockWritesTheScriptedBody() async throws {
        let scratch = Scratch("mock-writes")
        defer { scratch.remove() }
        let mock = MockTransport(status: 200, headers: ["Content-Length": "5"], body: Data("hello".utf8))
        let request = HTTPRequest(method: "GET", url: URL(string: "https://example.com/f.bin")!)

        let recorder = ProgressRecorder()
        let file = try await mock.download(request, to: scratch.file(), onProgress: recorder.callback)

        #expect(file.byteCount == 5)
        #expect(String(decoding: try Data(contentsOf: scratch.file()), as: UTF8.self) == "hello")
        #expect(mock.recordedRequests.count == 1)
        #expect(recorder.recorded == [DownloadProgress(received: 5, expected: 5)])
    }

    @Test("a caller's resume loop can be driven end to end")
    func mockDrivesAResumeLoop() async throws {
        let scratch = Scratch("mock-resume")
        defer { scratch.remove() }
        let destination = scratch.file()
        let interruption = DownloadInterruption(
            reason: .transfer(.network(URLError(.networkConnectionLost))),
            resumption: DownloadResumption(destination: destination, resumeData: Data("state".utf8))
        )
        let mock = MockTransport([
            .failure(interruption),
            .response(HTTPResponse(status: 200, headers: [:], body: Data("finished".utf8))),
        ])
        let request = HTTPRequest(method: "GET", url: URL(string: "https://example.com/f.bin")!)

        var file: DownloadedFile?
        do {
            file = try await mock.download(request, to: destination)
        } catch let stopped as DownloadInterruption {
            let resumption = try #require(stopped.resumption)
            file = try await mock.download(continuing: resumption)
        }

        #expect(file?.byteCount == 8)
        #expect(String(decoding: try Data(contentsOf: destination), as: UTF8.self) == "finished")
        // The continuation carries no request, so only the first call was recorded.
        #expect(mock.recordedRequests.count == 1)
    }

    @Test("a scripted non-2xx becomes an HTTPStatusError, as it does on the real transport")
    func mockThrowsStatusErrors() async throws {
        let scratch = Scratch("mock-404")
        defer { scratch.remove() }
        let mock = MockTransport(status: 404, body: Data("missing".utf8))
        let destination = scratch.file()
        do {
            _ = try await mock.download(
                HTTPRequest(method: "GET", url: URL(string: "https://example.com/f.bin")!),
                to: destination
            )
            Issue.record("エラーがスローされるべき")
        } catch let error as HTTPStatusError {
            #expect(error.status == 404)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

@Suite("落とす口が module の外から使えること")
struct DownloadPublicSurfaceTests {
    /// The composition-root shape: a transport injected as an existential that
    /// can send and download.
    @Test func downloadIsReachableThroughAnExistential() async throws {
        let scratch = Scratch("existential")
        defer { scratch.remove() }
        let transport: any HTTPTransport & HTTPDownloadTransport = MockTransport(
            status: 200,
            body: Data("bytes".utf8)
        )
        let file = try await transport.download(
            HTTPRequest(method: "GET", url: URL(string: "https://example.com/f.bin")!),
            to: scratch.file()
        )
        #expect(file.byteCount == 5)
    }

    @Test func urlSessionTransportIsADownloadTransport() {
        let transport: any HTTPDownloadTransport = URLSessionTransport()
        #expect(transport is URLSessionTransport)
    }
}
