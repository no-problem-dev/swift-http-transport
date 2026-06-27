import Foundation

/// Case-insensitive HTTP header storage that preserves insertion order.
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

    public var pairs: [(name: String, value: String)] { entries }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        guard lhs.entries.count == rhs.entries.count else { return false }
        return lhs.entries.allSatisfy { rhs[$0.name] == $0.value }
    }
}

/// A transport-level HTTP request, independent of `URLSession`.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: HTTPHeaders
    public var body: Data?
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

/// A transport-level HTTP response.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: HTTPHeaders
    public let body: Data

    public init(status: Int, headers: HTTPHeaders, body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// `true` when the HTTP status code is in the 2xx success range.
    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Errors surfaced by transports before any HTTP exchange completes.
public enum TransportError: Error, Sendable {
    /// The response object could not be interpreted as an `HTTPURLResponse`.
    case invalidResponse
    /// A network-layer error (connection refused, DNS failure, etc.).
    case network(any Error)
    /// The task was cancelled before a response was received.
    case cancelled
}
