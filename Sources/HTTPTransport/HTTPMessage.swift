import Foundation

/// Header storage with case-insensitive lookup and insertion order preserved.
///
/// This models a **dictionary**, not a multimap: a field name appears at most
/// once, whatever its case. Every way of building one — subscript assignment,
/// the array initialiser, the dictionary literal — obeys that single rule, so
/// initialising is exactly equivalent to setting each pair in turn. A name
/// supplied twice therefore keeps the *last* value, at the *last* position,
/// which is also what ``HTTPRequest`` puts on the wire.
///
/// The alternative — modelling HTTP's repeated field names — was rejected
/// because the type could never hold up its end: `URLSession` folds repeated
/// fields into one comma-joined value before this package ever sees them, so a
/// multimap API would promise access to values that cannot be recovered.
/// Callers needing the individual values of a repeated `Set-Cookie` must read
/// them from the `HTTPURLResponse` themselves.
public struct HTTPHeaders: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    /// Invariant: no two entries share a name under case-insensitive comparison.
    private var entries: [(name: String, value: String)]

    public init() { entries = [] }

    public init(_ pairs: [(String, String)]) {
        entries = []
        for pair in pairs { self[pair.0] = pair.1 }
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

    /// The fields in insertion order, each name once, capitalisation intact.
    ///
    /// Use this when the order or the exact spelling matters, such as when
    /// replaying headers onto another request. Lookup by name should go through
    /// the subscript instead, which ignores case.
    public var pairs: [(name: String, value: String)] { entries }

    /// Compares by name and value, ignoring both field order and name case.
    ///
    /// Field order carries no meaning between different names in HTTP, so two
    /// header sets that differ only in order are equal here. This is a genuine
    /// equivalence relation only because names are unique: counting entries and
    /// then looking each one up would otherwise report a value that has a
    /// duplicate as unequal to itself.
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
    /// Each name is *set* on the outgoing request rather than appended, which
    /// matches ``HTTPHeaders`` holding every name at most once.
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

    /// Whether delivering this request twice is as safe as delivering it once.
    ///
    /// ``RetryingTransport`` will not replay a request that says `false`, so
    /// this is what stands between a timed-out payment and a double charge.
    /// Defaults to the method's own semantics per RFC 9110 §9.2.2, which makes
    /// POST and PATCH unsafe.
    ///
    /// Set it explicitly to override: `true` for a POST carrying an idempotency
    /// key, `false` for a DELETE the server implements destructively.
    public var isIdempotent: Bool

    public init(
        method: String,
        url: URL,
        headers: HTTPHeaders = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil,
        isIdempotent: Bool? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.isIdempotent = isIdempotent ?? HTTPRequest.methodIsIdempotent(method)
    }

    /// The methods RFC 9110 §9.2.2 defines as idempotent.
    ///
    /// POST and PATCH are absent by design; so is any extension method, because
    /// nothing here can know whether repeating it is safe.
    static func methodIsIdempotent(_ method: String) -> Bool {
        ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE"].contains(method.uppercased())
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
    /// Usually a `URLError`: connection refused, DNS failure, timeout. Never
    /// cancellation, which is reported as ``cancelled`` however it arose.
    case network(any Error)

    /// The task was cancelled before a response arrived.
    ///
    /// Raised whichever way cancellation surfaced — as a `CancellationError`,
    /// or as the `URLError.cancelled` that `URLSession` actually reports when a
    /// surrounding task is cancelled. `catch TransportError.cancelled` is
    /// therefore enough on its own.
    case cancelled
}
