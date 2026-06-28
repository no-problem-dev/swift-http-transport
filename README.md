English | [日本語](./README.ja.md)

# swift-http-transport

The single raw-HTTP seam for the NOPROBLEM stack. Places `URLSession` behind a
protocol and centralises retry, rate-limit parsing, and SSE decoding so that
higher layers (swift-api-client, providers) depend only on this abstraction.

## Installation

Add to `Package.swift`:

```swift
.package(url: "https://github.com/no-problem-dev/swift-http-transport", from: "1.0.0")
```

Add to your target's dependencies:

```swift
.target(name: "MyTarget", dependencies: ["HTTPTransport"])
```

## Usage

### Basic request

```swift
import HTTPTransport

let transport = URLSessionTransport()
let request = HTTPRequest(method: "GET", url: URL(string: "https://api.example.com/data")!)
let response = try await transport.send(request)
if response.isSuccess {
    // use response.body
}
```

### Retry

```swift
let transport = RetryingTransport(
    base: URLSessionTransport(),
    policy: ExponentialBackoff(maxAttempts: 3),
    rateLimitMapping: RateLimitHeaderMapping(
        remainingRequests: "x-ratelimit-remaining-requests",
        requestsReset: "x-ratelimit-reset-requests",
        resetFormat: .durationSuffix
    )
)
```

### Server-Sent Events

```swift
let transport = URLSessionTransport()
let request = HTTPRequest(method: "POST", url: url, headers: ["Accept": "text/event-stream"])
for try await event in transport.sseEvents(request) {
    print(event.data)
}
```

### Testing

```swift
let mock = MockTransport(status: 200, body: Data("{\"ok\":true}".utf8))
let response = try await mock.send(request)
print(mock.recordedRequests.count) // 1
```

## Module overview

| Type | Role |
|---|---|
| `HTTPTransport` / `HTTPStreamingTransport` | Core protocols (`send` / `stream`) |
| `URLSessionTransport` | Default concrete implementation (`URLSession`-backed) |
| `MockTransport` | Deterministic testing (scripted/closure responses, request recording) |
| `RetryPolicy` / `ExponentialBackoff` / `NoRetry` | Single retry abstraction (status + error + rate-limit) |
| `RetryingTransport` | Decorator that centralises retry at the transport layer |
| `RateLimitHeaderMapping` / `RateLimitSnapshot` | Rate-limit extraction via header-name mapping (seconds / milliseconds / RFC 3339 / duration suffix) |
| `SSEParser` / `SSEEvent` / `sseEvents(_:)` | WHATWG SSE frame splitting and decoding |

`HTTPRequest` / `HTTPResponse` / `HTTPHeaders` (case-insensitive, insertion-ordered) are minimal Foundation value types.

## License

MIT
