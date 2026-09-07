import Foundation
#if canImport(FoundationNetworking)
// On Linux the URL loading system ships as a module of its own rather than as
// part of Foundation, so `URLSession`, `URLRequest` and `HTTPURLResponse` are
// only in scope once this is imported.
import FoundationNetworking
#endif

/// A transport that writes a response body to a file instead of into memory.
///
/// The third seam, beside ``HTTPTransport`` and ``HTTPStreamingTransport``. It
/// exists because the other two cannot answer "put this 60 MB file on disk"
/// without the whole file existing in memory first: ``HTTPTransport/send(_:)``
/// buffers by contract, and ``HTTPStreamingTransport/stream(_:)`` hands over
/// bytes but leaves writing, counting, and cleaning up after a failure to every
/// caller in turn.
///
/// Writing to a file is the transport's job rather than the API layer's or the
/// app's: it is where the response already is, and it is the only layer that
/// can keep a half-written file from ever reaching the destination.
///
/// What this deliberately does *not* do is decide **which** file to fetch or
/// where to keep it. Version-stamped names, collapsing concurrent requests for
/// the same resource, and falling back from bundled to cached to network are
/// policies about a library of assets. They belong to whoever owns that library.
///
/// It also does not compose with ``RetryingTransport``. A download that stops
/// halfway hands back a ``DownloadResumption``, and whether to continue from
/// the bytes already on disk or start over is a decision about those bytes — a
/// retry policy, which sees only a status and an error, cannot make it.
public protocol HTTPDownloadTransport: Sendable {
    /// Downloads a response body to a file, reporting progress as it arrives.
    ///
    /// The destination's parent directories are created if missing, and an
    /// existing file there is replaced. Nothing is written to the destination
    /// until the body has arrived whole, so a failure never leaves a truncated
    /// file behind: what was received lives in the URL loading system's own
    /// scratch space and is discarded with it.
    ///
    /// Unlike ``HTTPTransport/send(_:)``, a non-2xx status is a failure here —
    /// as it is for ``HTTPStreamingTransport/stream(_:)``, and for the same
    /// reason. There is no such thing as writing an error page to the file the
    /// caller asked for. The status arrives as ``HTTPStatusError``, carrying a
    /// bounded prefix of the error payload, and the destination is left alone.
    ///
    /// - Parameters:
    ///   - request: The request to send. Any method and any headers, so a
    ///     `Range` request is made by setting the header yourself; read what
    ///     the server granted from ``HTTPHeaders/contentRange``.
    ///   - destination: Where to put the finished file.
    ///   - onProgress: Called as bytes are written, with the running total.
    ///     Called from the URL loading system's own queue, not from the caller's
    ///     actor, so hop before touching UI state. Pass `nil` when nothing is
    ///     watching.
    /// - Returns: The file, its status, and the response headers.
    /// - Throws: ``HTTPStatusError`` on a non-2xx status, and
    ///   ``DownloadInterruption`` when the transfer stopped or the file could
    ///   not be put where it was asked for.
    func download(
        _ request: HTTPRequest,
        to destination: URL,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> DownloadedFile

    /// Continues a download that stopped, from the bytes it already has.
    ///
    /// The resumption carries the original request and the destination inside
    /// it, which is why neither is passed again: the URL loading system's resume
    /// data *is* the request plus a description of what has already been
    /// written, and letting a caller supply a different request beside it would
    /// only let the two contradict each other.
    ///
    /// Progress continues to count from the start of the whole file, not from
    /// where this attempt picked up, so a progress bar built on
    /// ``DownloadProgress/fraction`` does not jump backwards.
    ///
    /// - Parameters:
    ///   - resumption: What a previous ``DownloadInterruption`` handed back.
    ///   - onProgress: Called as bytes are written, with the running total.
    /// - Returns: The file, its status, and the response headers.
    /// - Throws: The same failures as a fresh download. A server that no longer
    ///   holds the representation the resume data describes answers 412, which
    ///   arrives as ``HTTPStatusError`` — start over rather than continuing.
    func download(
        continuing resumption: DownloadResumption,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> DownloadedFile
}

extension HTTPDownloadTransport {
    /// Downloads a response body to a file with nothing watching the progress.
    public func download(_ request: HTTPRequest, to destination: URL) async throws -> DownloadedFile {
        try await download(request, to: destination, onProgress: nil)
    }

    /// Continues a stopped download with nothing watching the progress.
    public func download(continuing resumption: DownloadResumption) async throws -> DownloadedFile {
        try await download(continuing: resumption, onProgress: nil)
    }
}

/// How much of a download has arrived.
///
/// Delivered repeatedly during a transfer. ``received`` never decreases within
/// one download, and counts from the start of the whole file even when the
/// transfer was continued from a ``DownloadResumption``.
public struct DownloadProgress: Sendable, Equatable {
    /// Bytes written so far, counted from the start of the file.
    public let received: Int64

    /// Bytes the whole body will come to, or `nil` when the server did not say.
    ///
    /// A chunked response without `Content-Length` genuinely has no total, so
    /// this is optional rather than a sentinel: a progress bar that cannot be
    /// drawn should be replaced with a spinner, not drawn wrong.
    public let expected: Int64?

    public init(received: Int64, expected: Int64?) {
        self.received = received
        self.expected = expected
    }

    /// How far along, from 0 to 1, or `nil` when the total is unknown.
    public var fraction: Double? {
        guard let expected, expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }
}

/// A body that finished arriving and is now a file on disk.
public struct DownloadedFile: Sendable {
    /// Where the file is — the destination that was asked for.
    public let url: URL

    /// The status the server answered with. Always 2xx: anything else threw.
    public let status: Int

    /// The response headers.
    ///
    /// ``HTTPHeaders/contentLength`` and ``HTTPHeaders/contentRange`` read the
    /// two fields a download usually cares about. `Content-Length` is what the
    /// server *said*; ``byteCount`` is what actually landed, and a truncated
    /// transfer is exactly the case where the two differ.
    public let headers: HTTPHeaders

    /// The size of the file on disk, measured after it was written.
    public let byteCount: Int64

    public init(url: URL, status: Int, headers: HTTPHeaders, byteCount: Int64) {
        self.url = url
        self.status = status
        self.headers = headers
        self.byteCount = byteCount
    }
}

/// What is needed to continue a download that stopped partway.
///
/// Produced by the transport, never assembled by hand: ``resumeData`` is the
/// URL loading system's own opaque description of a half-finished transfer,
/// which already contains the original request and the scratch file holding the
/// bytes so far. It can be written to disk and used in a later process.
///
/// The type exists so that continuing is only expressible when there is in fact
/// something to continue from — ``DownloadInterruption/resumption`` is optional,
/// and a server that does not support ranged requests leaves it `nil`.
///
/// - Note: On Linux this is never produced. swift-corelibs-foundation compiles
///   the whole resume path and implements none of it: `cancel(byProducingResumeData:)`
///   hands its completion handler `nil` unconditionally, and
///   `downloadTask(withResumeData:)` builds a task marked invalid that fetches
///   nothing. A resume loop written against this therefore degrades to starting
///   over there, which is correct behaviour rather than a silent failure —
///   ``DownloadInterruption/resumption`` simply stays `nil`.
public struct DownloadResumption: Sendable {
    /// Where the finished file was going, carried through so a continuation
    /// does not have to be told again.
    public let destination: URL

    /// The URL loading system's resume data.
    public let resumeData: Data

    public init(destination: URL, resumeData: Data) {
        self.destination = destination
        self.resumeData = resumeData
    }
}

/// A download that produced no file.
///
/// Every failure of ``HTTPDownloadTransport`` other than a non-2xx status
/// arrives as one of these, so there is a single thing to catch. The plain
/// ``TransportError`` that ``HTTPTransport/send(_:)`` throws is inside
/// ``Reason/transfer(_:)`` rather than thrown directly, because a download has
/// something to say that a send does not: whether continuing is possible.
public struct DownloadInterruption: Error, Sendable {
    /// What stopped the download.
    public enum Reason: Sendable {
        /// The transfer itself failed, was cancelled, or answered with
        /// something that was not an HTTP response.
        case transfer(TransportError)

        /// Every byte arrived, but the file could not be put at the
        /// destination — an unwritable directory, a full disk, a name already
        /// taken by something that cannot be removed. The underlying file
        /// system error, unchanged.
        case destination(any Error)
    }

    public let reason: Reason

    /// What to pass to ``HTTPDownloadTransport/download(continuing:onProgress:)``,
    /// or `nil` when continuing is not possible.
    ///
    /// `nil` whenever the server does not support ranged requests, when nothing
    /// had been written yet, and always for ``Reason/destination(_:)`` — there
    /// the bytes arrived whole and were discarded with the scratch file, so
    /// there is nothing partial left to continue from.
    public let resumption: DownloadResumption?

    public init(reason: Reason, resumption: DownloadResumption?) {
        self.reason = reason
        self.resumption = resumption
    }
}

/// Which part of a representation a body covers, from `Content-Range`.
///
/// Parsed per RFC 9110 §14.4, which allows two shapes: a range with the total
/// (`bytes 0-499/1234`) or with the total withheld (`bytes 0-499/*`), and the
/// unsatisfied form a 416 carries (`bytes */1234`), which states the size and
/// sends no bytes at all.
public struct ContentRange: Sendable, Equatable {
    /// The byte positions this body covers, inclusive on both ends.
    ///
    /// `nil` for the unsatisfied form, where the server sent no bytes.
    public let bytes: ClosedRange<Int64>?

    /// The size of the whole representation, or `nil` when the server sent `*`
    /// because it does not know it.
    public let completeLength: Int64?

    public init(bytes: ClosedRange<Int64>?, completeLength: Int64?) {
        self.bytes = bytes
        self.completeLength = completeLength
    }

    /// Reads a `Content-Range` field value.
    ///
    /// Returns `nil` for anything that does not parse, including a range whose
    /// end precedes its start or that runs past the stated total. RFC 9110 asks
    /// a recipient to ignore a field it cannot make sense of, and a header
    /// nobody can read is exactly a header that should not be acted on.
    ///
    /// - Parameter field: The raw field value, such as `bytes 0-499/1234`.
    public init?(field: String) {
        let text = field.trimmingCharacters(in: .whitespaces)
        // Only the `bytes` unit is defined for ranged responses; a different
        // unit is something this type has no way to describe.
        guard let separator = text.firstIndex(where: { $0 == " " || $0 == "\t" }),
              text[text.startIndex ..< separator].lowercased() == "bytes"
        else { return nil }
        let spec = text[separator...].trimmingCharacters(in: .whitespaces)

        guard let slash = spec.lastIndex(of: "/") else { return nil }
        let rangePart = String(spec[spec.startIndex ..< slash])
        let lengthPart = String(spec[spec.index(after: slash)...])

        let completeLength: Int64?
        if lengthPart == "*" {
            completeLength = nil
        } else if let parsed = Int64(lengthPart), parsed >= 0 {
            completeLength = parsed
        } else {
            return nil
        }

        if rangePart == "*" {
            // The unsatisfied form must state the size; `bytes */*` says nothing.
            guard completeLength != nil else { return nil }
            self.init(bytes: nil, completeLength: completeLength)
            return
        }

        let ends = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard ends.count == 2,
              let first = Int64(ends[0]), let last = Int64(ends[1]),
              first >= 0, last >= first
        else { return nil }
        if let completeLength, last >= completeLength { return nil }
        self.init(bytes: first ... last, completeLength: completeLength)
    }

    /// How many bytes this body covers. Zero for the unsatisfied form.
    public var byteCount: Int64 {
        guard let bytes else { return 0 }
        return bytes.upperBound - bytes.lowerBound + 1
    }
}

extension HTTPHeaders {
    /// `Content-Length` as a number, or `nil` when absent or unreadable.
    ///
    /// This is what the server *claimed*. Compare it against what arrived
    /// rather than trusting it: a truncated transfer is precisely the case
    /// where the claim outlives the bytes.
    public var contentLength: Int64? {
        guard let value = self["Content-Length"]?.trimmingCharacters(in: .whitespaces) else { return nil }
        guard let parsed = Int64(value), parsed >= 0 else { return nil }
        return parsed
    }

    /// `Content-Range` parsed, or `nil` when absent or unreadable.
    ///
    /// A `Range` request is made by setting the header on ``HTTPRequest``; this
    /// is how to read what the server actually granted, which may be less than
    /// what was asked for or the whole representation instead.
    public var contentRange: ContentRange? {
        guard let value = self["Content-Range"] else { return nil }
        return ContentRange(field: value)
    }
}

extension URLSessionTransport: HTTPDownloadTransport {
    public func download(
        _ request: HTTPRequest,
        to destination: URL,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> DownloadedFile {
        try await runDownload(to: destination, onProgress: onProgress) { session in
            session.downloadTask(with: makeURLRequest(request))
        }
    }

    public func download(
        continuing resumption: DownloadResumption,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> DownloadedFile {
        try await runDownload(to: resumption.destination, onProgress: onProgress) { session in
            session.downloadTask(withResumeData: resumption.resumeData)
        }
    }

    /// Runs one download task to completion, whichever way it was created.
    ///
    /// The two entry points differ only in how the task is made, so everything
    /// after that — the delegate, the cancellation handling, the bridge to
    /// `async` — exists once.
    private func runDownload(
        to destination: URL,
        onProgress: (@Sendable (DownloadProgress) -> Void)?,
        makeTask: (URLSession) -> URLSessionDownloadTask
    ) async throws -> DownloadedFile {
        let delegate = DownloadSessionDelegate(
            destination: destination,
            maxErrorBodyBytes: maxErrorBodyBytes,
            onProgress: onProgress
        )
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no per-task delegate, so a delegate can
        // only be attached when a session is created. Rebuilding one from this
        // transport's configuration keeps any URLProtocol stub and caching
        // policy the caller installed. The delegate invalidates it on
        // completion, which is why only this branch owns a session.
        let delegateSession = URLSession(configuration: session.configuration, delegate: delegate, delegateQueue: nil)
        let task = makeTask(delegateSession)
        #else
        let task = makeTask(session)
        task.delegate = delegate
        #endif
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            // Not a plain `cancel()`: asking for resume data is what turns a
            // cancellation into a pause. The caller gets it back inside the
            // thrown ``DownloadInterruption`` and can continue later.
            delegate.cancelProducingResumeData()
        }
    }
}

/// Carries one download task, on every platform.
///
/// The shape mirrors `StreamingSessionDelegate`: state is reached from the
/// delegate queue and from the cancellation handler, so it is guarded by a lock
/// rather than by an actor — the delegate methods are synchronous and cannot
/// await isolation.
///
/// The contract: the destination is written only once the body has arrived
/// whole, a non-2xx fails with ``HTTPStatusError`` carrying at most
/// ``URLSessionTransport/maxErrorBodyBytes`` of the payload and writes nothing,
/// and everything else that stops the transfer fails with
/// ``DownloadInterruption`` carrying resume data when the server left that
/// possible.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let maxErrorBodyBytes: Int
    private let onProgress: (@Sendable (DownloadProgress) -> Void)?

    private let lock = NSLock()
    private var continuation: CheckedContinuation<DownloadedFile, any Error>?
    private var task: URLSessionDownloadTask?
    private var isSettled = false
    private var cancellationRequested = false
    private var resumeDataFromCancellation: Data?

    init(
        destination: URL,
        maxErrorBodyBytes: Int,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) {
        self.destination = destination
        self.maxErrorBodyBytes = max(0, maxErrorBodyBytes)
        self.onProgress = onProgress
    }

    /// Adopts the continuation and starts the task.
    ///
    /// The continuation is stored before `resume()`, and no delegate callback
    /// can arrive before that, so there is no window in which a completion has
    /// nowhere to go.
    func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<DownloadedFile, any Error>) {
        let alreadyCancelled: Bool = lock.withLock {
            self.task = task
            self.continuation = continuation
            return cancellationRequested
        }
        task.resume()
        // A surrounding task cancelled before this ran leaves the request to be
        // stopped here instead; cancelling before `resume()` is not reliable.
        if alreadyCancelled { cancelProducingResumeData() }
    }

    /// Stops the transfer, keeping what was received so it can be continued.
    func cancelProducingResumeData() {
        let task: URLSessionDownloadTask? = lock.withLock {
            cancellationRequested = true
            return self.task
        }
        guard let task else { return }
        task.cancel(byProducingResumeData: { [self] data in
            lock.withLock { resumeDataFromCancellation = data }
        })
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let onProgress else { return }
        // The loading system reports an unknown total as a negative sentinel;
        // a genuinely empty body reports zero, which is a real total.
        let expected = totalBytesExpectedToWrite >= 0 ? totalBytesExpectedToWrite : nil
        onProgress(DownloadProgress(received: totalBytesWritten, expected: expected))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard let onProgress else { return }
        let expected = expectedTotalBytes >= 0 ? expectedTotalBytes : nil
        onProgress(DownloadProgress(received: fileOffset, expected: expected))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The scratch file is deleted the moment this method returns, so the
        // move has to happen here rather than after the continuation resumes.
        guard let http = downloadTask.response as? HTTPURLResponse else {
            settle(.failure(DownloadInterruption(reason: .transfer(.invalidResponse), resumption: nil)))
            return
        }
        let headers = URLSessionTransport.headers(from: http)
        guard (200 ..< 300).contains(http.statusCode) else {
            settle(.failure(
                HTTPStatusError(status: http.statusCode, headers: headers, body: errorBody(at: location))
            ))
            return
        }
        do {
            let byteCount = try place(location)
            settle(.success(
                DownloadedFile(url: destination, status: http.statusCode, headers: headers, byteCount: byteCount)
            ))
        } catch {
            settle(.failure(DownloadInterruption(reason: .destination(error), resumption: nil)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        #if canImport(FoundationNetworking)
        // Only the Linux path owns its session. On Apple the delegate is
        // attached per task, so the session belongs to the caller and
        // invalidating it would tear down every other request on it.
        defer { session.finishTasksAndInvalidate() }
        #endif

        guard let error else {
            // A success already settled in `didFinishDownloadingTo`. Reaching
            // here without one means the body never arrived at all.
            settle(.failure(DownloadInterruption(reason: .transfer(.invalidResponse), resumption: nil)))
            return
        }
        settle(.failure(
            DownloadInterruption(
                reason: .transfer(URLSessionTransport.transportError(from: error)),
                resumption: resumption(after: error)
            )
        ))
    }

    /// Resolves the continuation once and only once.
    ///
    /// `didFinishDownloadingTo` and `didCompleteWithError` both fire on a
    /// successful download, in that order, so the second must find the outcome
    /// already decided rather than overwrite it.
    private func settle(_ result: Result<DownloadedFile, any Error>) {
        let continuation: CheckedContinuation<DownloadedFile, any Error>? = lock.withLock {
            guard !isSettled else { return nil }
            isSettled = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }

    /// Puts the finished scratch file at the destination.
    ///
    /// Replacing rather than refusing: a download to a name that already holds
    /// an older copy of the same thing is the ordinary case, and leaving the
    /// old bytes in place while reporting success would be the lie.
    private func place(_ scratch: URL) throws -> Int64 {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: scratch, to: destination)
        let attributes = try manager.attributesOfItem(atPath: destination.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw CocoaError(.fileReadUnknown)
        }
        return size
    }

    /// Reads a bounded prefix of a non-2xx payload so it can be reported.
    ///
    /// Best effort: the payload is diagnostic, and a status that cannot be
    /// explained is still worth more than a read error thrown in its place.
    private func errorBody(at scratch: URL) -> Data {
        guard maxErrorBodyBytes > 0, let handle = try? FileHandle(forReadingFrom: scratch) else { return Data() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxErrorBodyBytes) else { return Data() }
        return data
    }

    /// What the failure left behind to continue from, if anything.
    ///
    /// Two sources, because the loading system uses two. A transfer that failed
    /// on its own carries resume data in the error; one stopped by
    /// ``cancelProducingResumeData()`` hands it to that method's completion
    /// handler instead. Whichever arrived is used.
    private func resumption(after error: any Error) -> DownloadResumption? {
        let stored = lock.withLock { resumeDataFromCancellation }
        guard let data = stored ?? Self.resumeData(in: error) else { return nil }
        return DownloadResumption(destination: destination, resumeData: data)
    }

    /// Digs the resume data out of a failure from the URL loading system.
    ///
    /// Internal rather than private so a test can pin the extraction without a
    /// server that supports ranged requests — a `URLProtocol` stub never
    /// produces resume data, so this seam is where the behaviour is checkable.
    static func resumeData(in error: any Error) -> Data? {
        (error as NSError).userInfo[resumeDataKey] as? Data
    }
}

/// The key the URL loading system files resume data under.
///
/// The two platforms export the same string under different names, so naming
/// either one unguarded is a compile error on the other. Darwin has
/// `NSURLSessionDownloadTaskResumeData`; swift-corelibs-foundation declares
/// `public let URLSessionDownloadTaskResumeData = "NSURLSessionDownloadTaskResumeData"`
/// — the `NS` survives in the value and is gone from the name.
#if canImport(FoundationNetworking)
private let resumeDataKey = URLSessionDownloadTaskResumeData
#else
private let resumeDataKey = NSURLSessionDownloadTaskResumeData
#endif

/// Reaches the delegate's extraction from the test target.
///
/// The delegate itself is private, which is right — nothing outside this file
/// constructs one — but the mapping from a failure to a ``DownloadResumption``
/// is the one piece of the resume path a stubbed server cannot exercise.
enum DownloadResumeData {
    static func from(_ error: any Error) -> Data? {
        DownloadSessionDelegate.resumeData(in: error)
    }
}

extension MockTransport: HTTPDownloadTransport {
    /// Writes a scripted body to the destination instead of fetching one.
    ///
    /// Draws on the same script as ``MockTransport/send(_:)``, one outcome per
    /// call, so a download can be made to fail exactly as a send can — script a
    /// ``DownloadInterruption`` to test a caller's resume loop. A scripted
    /// non-2xx becomes an ``HTTPStatusError``, matching ``URLSessionTransport``.
    ///
    /// Progress is reported once, complete, since there is no transfer to
    /// observe partway.
    public func download(
        _ request: HTTPRequest,
        to destination: URL,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> DownloadedFile {
        try write(outcome: outcome(recording: request), to: destination, onProgress: onProgress)
    }

    /// Continues a scripted download by drawing the next outcome.
    ///
    /// A continuation carries no ``HTTPRequest`` — the real resume data hides
    /// it — so there is nothing to record and nothing for the request-computing
    /// initialiser to compute from. This form therefore always uses the
    /// scripted outcomes, even on a transport built with a handler.
    public func download(
        continuing resumption: DownloadResumption,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) async throws -> DownloadedFile {
        try write(outcome: outcome(recording: nil), to: resumption.destination, onProgress: onProgress)
    }

    private func write(
        outcome: Outcome,
        to destination: URL,
        onProgress: (@Sendable (DownloadProgress) -> Void)?
    ) throws -> DownloadedFile {
        let response: HTTPResponse
        switch outcome {
        case .failure(let error): throw error
        case .response(let scripted): response = scripted
        }
        guard response.isSuccess else {
            throw HTTPStatusError(status: response.status, headers: response.headers, body: response.body)
        }
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try response.body.write(to: destination, options: .atomic)
        let byteCount = Int64(response.body.count)
        onProgress?(DownloadProgress(received: byteCount, expected: byteCount))
        return DownloadedFile(
            url: destination,
            status: response.status,
            headers: response.headers,
            byteCount: byteCount
        )
    }
}
