# ``HTTPTransport``

The one seam raw HTTP passes through, so nothing above it has to touch `URLSession`.

## Overview

Providers and `swift-api-client` depend on the ``HTTPTransport`` and
``HTTPStreamingTransport`` protocols, never on a concrete session. Retry,
rate-limit parsing, and SSE decoding therefore exist once here rather than once
per caller, and any transport can be replaced with a mock or wrapped in a
decorator without a call site changing.

Two rules are worth knowing before the first call:

- An HTTP status is not an error. ``HTTPTransport/send(_:)`` returns 4xx and 5xx
  as ordinary responses; check ``HTTPResponse/isSuccess``. Only failures that
  stop a response forming throw ``TransportError``.
- ``HTTPStreamingTransport/stream(_:)`` is the exception: a non-2xx status fails
  the stream with ``HTTPStatusError`` and no chunk is ever yielded.

## Getting started

### Compose the transport

Retry is a decorator, so it composes rather than being configured. The policy
sees the status, the thrown error, and the parsed quota headers together.

```swift
let transport = RetryingTransport(
    base: URLSessionTransport(defaultTimeout: 30),
    policy: ExponentialBackoff(maxAttempts: 3),
    rateLimitMapping: RateLimitHeaderMapping(
        remainingRequests: "x-ratelimit-remaining-requests",
        requestsReset: "x-ratelimit-reset-requests",
        resetFormat: .durationSuffix
    )
)
```

A `Retry-After` header wins over the computed backoff. The request is replayed
unchanged whatever its method, so weigh that before retrying writes.

### Read an event stream

``HTTPStreamingTransport/sseEvents(_:)`` decodes frames as they arrive,
absorbing chunk boundaries and CRLF line endings.

```swift
let request = HTTPRequest(
    method: "POST",
    url: url,
    headers: ["Accept": "text/event-stream"],
    body: payload
)
for try await event in URLSessionTransport().sseEvents(request) {
    guard event.data != "[DONE]" else { break }
    handle(event.data)
}
```

Leaving the loop cancels the underlying request.

### Test without a network

``MockTransport`` scripts outcomes in order and records what was sent.

```swift
let mock = MockTransport([
    .response(HTTPResponse(status: 429, headers: ["retry-after": "0"], body: Data())),
    .response(HTTPResponse(status: 200, headers: [:], body: Data("done".utf8))),
])
let retrying = RetryingTransport(base: mock, policy: ExponentialBackoff(), sleep: { _ in })
_ = try await retrying.send(request)
#expect(mock.recordedRequests.count == 2)
```

Injecting `sleep` runs the backoff schedule without real delay.

## Topics

### Requests and responses

- ``HTTPRequest``
- ``HTTPResponse``
- ``HTTPHeaders``
- ``TransportError``
- ``HTTPStatusError``

### Transport protocols

- ``HTTPTransport``
- ``HTTPStreamingTransport``

### Concrete transports

- ``URLSessionTransport``
- ``RetryingTransport``
- ``MockTransport``

### Retry

- ``RetryPolicy``
- ``RetryDecision``
- ``ExponentialBackoff``
- ``NoRetry``

### Rate limits

- ``RateLimitHeaderMapping``
- ``RateLimitSnapshot``

### Server-sent events

- ``SSEParser``
- ``SSEEvent``
