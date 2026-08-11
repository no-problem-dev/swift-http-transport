English | [日本語](./README.ja.md)

# swift-http-transport

Write retry, rate-limit handling, and server-sent events once instead of once per API client —
`URLSession` sits behind a protocol you can swap for a fake in tests.

## Overview

Everything above this package depends on the `HTTPTransport` protocol rather
than on `URLSession`. That buys four things:

- **One retry rule.** `RetryingTransport` wraps any transport with a policy that
  sees the status, the thrown error, and the parsed quota headers together —
  instead of a slightly different retry loop per provider.
- **Rate limits without per-provider parsing.** A provider declares which header
  names it uses and how it spells a reset time; the parsing lives here.
- **SSE that survives real streams.** Frames are split at byte level, so CRLF
  line endings and multi-byte characters straddling a chunk boundary both decode
  correctly.
- **Tests without a network.** `MockTransport` scripts responses and records
  what was sent.

An HTTP error status is not a thrown error: 4xx and 5xx come back as ordinary
responses. Only failures that stop a response from forming throw.

Foundation only — no third-party dependencies.

## Usage

```swift
import HTTPTransport

let transport = URLSessionTransport()
let response = try await transport.send(
    HTTPRequest(method: "GET", url: URL(string: "https://api.example.com/data")!)
)
if response.isSuccess {
    // response.body
}
```

Composing retry, streaming server-sent events, and testing against a mock are
covered in the documentation.

## Documentation

[API reference and guides](https://no-problem-dev.github.io/swift-http-transport/documentation/httptransport)

## Requirements

Swift 6.2 · iOS 17 · macOS 14 · tvOS 17 · watchOS 10 · visionOS 1

## Installation

Add the package to `Package.swift`:

```swift
.package(url: "https://github.com/no-problem-dev/swift-http-transport", from: "1.0.0")
```

Then add the product to your target:

```swift
.target(name: "MyTarget", dependencies: ["HTTPTransport"])
```

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

MIT — see [LICENSE](./LICENSE).
