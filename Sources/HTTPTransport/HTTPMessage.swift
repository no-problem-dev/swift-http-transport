import Foundation

/// Header storage with case-insensitive lookup and insertion order preserved.
///
/// Subscript assignment replaces any field of the same name whatever its case,
/// so headers built that way hold each name once. The array and dictionary
/// initialisers do *not* deduplicate: give the same name twice and lookup
/// returns the first, leaving the second unreachable.
public struct HTTPHeaders: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    private var entries: [(name: String, value: String)]

    public init() { entries = [] }

    public init(_ pairs: [(String, String)]) {
        entries = pairs.map { ($0.0, $0.1) }
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements)
    }

    public subscript(_ name: String) -> String? {
        get { entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value }
        set {
            entries.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if let newValue { entries.append((name, newValue)) }
        }
    }

    /// The fields in insertion order, with original capitalisation intact.
    ///
    /// Use this when the order or the exact spelling matters, such as when
    /// replaying headers onto another request. Lookup by name should go through
    /// the subscript instead, which ignores case.
    public var pairs: [(name: String, value: String)] { entries }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        return lhs.entries.allSatisfy { rhs[$0.name] == $0.value }
    }
}

/// A request described without reference to `URLSession`, so any transport can carry it.
public struct HTTPRequest: Sendable {
    /// The method verb, uppercase by convention and never validated here.
    public var method: String

    /// The destination. Any query string must already be percent-encoded.
    public var url: URL

    /// Fields to send.
    ///
    /// Each name is *set* on the outgoing request rather than appended, so a
    /// name repeated in ``HTTPHeaders`` collapses to its last value on the wire.
    public var headers: HTTPHeaders

    /// Raw body bytes, sent exactly as given, or `nil` for a request with none.
    ///
    /// Nothing is inferred from the bytes — set `Content-Type` yourself.
    public var body: Data?

    /// Timeout in seconds for this request alone.
    ///
    /// `nil` defers to the transport's own default, such as
    /// ``URLSessionTransport/defaultTimeout``.
    public var timeout: TimeInterval?

    public init(
        method: String,
        url: URL,
        headers: HTTPHeaders = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// A complete response, including one whose status reports failure.
///
/// The body is already fully in memory by the time this exists. A non-2xx
/// status arrives here rather than being thrown, so check ``isSuccess`` before
/// reading the body as a success payload.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: HTTPHeaders
    public let body: Data

    public init(status: Int, headers: HTTPHeaders, body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Whether the status is 2xx. Redirects and 304 count as unsuccessful.
    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// A failure that stopped any response from forming.
///
/// An HTTP error status is never reported this way — 4xx and 5xx arrive as an
/// ordinary ``HTTPResponse``.
public enum TransportError: Error, Sendable {
    /// The reply was not an HTTP response, so it carries no status or headers.
    case invalidResponse

    /// An error from the URL loading system, wrapped unchanged.
    ///
    /// Usually a `URLError`: connection refused, DNS failure, timeout. Note
    /// that cancellation reported by the URL loading system also arrives here,
    /// wrapping `URLError.cancelled`, rather than as ``cancelled``.
    case network(any Error)

    /// The task was cancelled before a response arrived.
    ///
    /// Only raised when cancellation surfaces as a `CancellationError`. Match
    /// ``network(_:)`` for `URLError.cancelled` too if cancellation needs to be
    /// handled uniformly.
    case cancelled
}
