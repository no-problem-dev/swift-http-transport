# ``HTTPTransport``

The single raw-HTTP seam for the NOPROBLEM stack. `URLSession` lives behind a
protocol; retry, rate-limit parsing, and SSE decoding are all centralised here
so higher layers never touch `URLSession` directly.

## Overview

All providers and `swift-api-client` depend only on the ``HTTPTransport`` and
``HTTPStreamingTransport`` protocols, so the underlying transport is swappable
(production `URLSessionTransport`, deterministic `MockTransport`, or any custom
decorator such as ``RetryingTransport``).

**Core flow:**

1. Build an ``HTTPRequest`` (method, URL, headers, optional body/timeout).
2. Call ``HTTPTransport/send(_:)`` — or ``HTTPStreamingTransport/stream(_:)``
   for byte-streaming — and await the ``HTTPResponse``.
3. Wrap the transport in ``RetryingTransport`` to add automatic retry with
   ``ExponentialBackoff`` and rate-limit header awareness via
   ``RateLimitHeaderMapping``.
4. For `text/event-stream` responses call ``HTTPStreamingTransport/sseEvents(_:)``
   to receive a stream of decoded ``SSEEvent`` values.

## Topics

### Request and Response

- ``HTTPRequest``
- ``HTTPResponse``
- ``HTTPHeaders``
- ``TransportError``
- ``HTTPStatusError``

### Transport Protocols

- ``HTTPTransport``
- ``HTTPStreamingTransport``

### Concrete Transports

- ``URLSessionTransport``
- ``RetryingTransport``
- ``MockTransport``

### Retry

- ``RetryPolicy``
- ``RetryDecision``
- ``ExponentialBackoff``
- ``NoRetry``

### Rate Limiting

- ``RateLimitHeaderMapping``
- ``RateLimitSnapshot``

### Server-Sent Events

- ``SSEParser``
- ``SSEEvent``
