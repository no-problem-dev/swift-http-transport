import Foundation

/// Wraps an existential transport in a concrete type, so it can be given to something generic.
///
/// `RetryingTransport` is generic over its base and picks up `HTTPStreamingTransport` through a
/// conditional conformance. That is what makes the compiler keep the streaming capability instead
/// of it disappearing when a transport is wrapped. The cost is that a value typed
/// `any HTTPTransport & HTTPStreamingTransport` cannot be handed to it — an existential does not
/// conform to the protocol it erases, so it cannot satisfy `Base: HTTPTransport`.
///
/// A caller that stores its transport as an existential — which is the ordinary shape for a
/// dependency injected at a composition root — needs a concrete box. This is it.
///
/// ```swift
/// let transport: any HTTPTransport & HTTPStreamingTransport = URLSessionTransport()
/// let retrying = RetryingTransport(base: AnyStreamingTransport(transport), policy: policy)
/// // retrying still has `stream` and `sseEvents`
/// ```
///
/// There is deliberately no eraser for `any HTTPTransport` alone: wrapping one loses nothing, so
/// `RetryingTransport` can take it through a generic parameter directly.
public struct AnyStreamingTransport: HTTPTransport, HTTPStreamingTransport {

    private let base: any HTTPTransport & HTTPStreamingTransport

    /// Boxes a transport that can do both.
    public init(_ base: any HTTPTransport & HTTPStreamingTransport) {
        self.base = base
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await base.send(request)
    }

    public func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, any Error> {
        base.stream(request)
    }
}
