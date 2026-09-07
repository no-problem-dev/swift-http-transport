English | [日本語](./README.ja.md)

# swift-http-transport

Write retry, rate-limit handling, server-sent events, and file downloads once instead of once per
API client — `URLSession` sits behind a protocol you can swap for a fake in tests.

## Overview

Everything above this package depends on the `HTTPTransport` protocol rather
than on `URLSession`. That buys five things:

- **One retry rule.** `RetryingTransport` wraps any transport with a policy that
  sees the status, the thrown error, and the parsed quota headers together —
  instead of a slightly different retry loop per provider.
- **Rate limits without per-provider parsing.** A provider declares which header
  names it uses and how it spells a reset time; the parsing lives here.
- **SSE that survives real streams.** Frames are split at byte level, so CRLF
  line endings and multi-byte characters straddling a chunk boundary both decode
  correctly.
- **Downloads that never hold the file in memory.** `HTTPDownloadTransport`
  writes the body straight to a destination, reports progress, and can continue
  a transfer that stopped.
- **Tests without a network.** `MockTransport` scripts responses and records
  what was sent — downloads included.

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

Downloading writes to a file rather than returning bytes. Nothing reaches the
destination until the body has arrived whole, so a failure never leaves a
truncated file behind.

```swift
let file = try await transport.download(
    HTTPRequest(method: "GET", url: URL(string: "https://cdn.example.com/track.flac")!),
    to: destination,
    onProgress: { progress in print(progress.fraction ?? 0) }
)
print(file.byteCount, file.headers.contentRange as Any)
```

A transfer that stops throws `DownloadInterruption`, carrying what is needed to
continue when the server left that possible:

```swift
do {
    return try await transport.download(request, to: destination)
} catch let stopped as DownloadInterruption {
    guard let resumption = stopped.resumption else { throw stopped }
    return try await transport.download(continuing: resumption)
}
```

Composing retry, streaming server-sent events, and testing against a mock are
covered in the documentation.

## Documentation

[API reference and guides](https://no-problem-dev.github.io/swift-http-transport/documentation/httptransport)

## Requirements

Swift 6.2 · iOS 17 · macOS 14 · tvOS 17 · watchOS 10 · visionOS 1 · Linux

## Installation

Add the package to `Package.swift`:

```swift
.package(url: "https://github.com/no-problem-dev/swift-http-transport", from: "2.0.0")
```

Then add the product to your target:

```swift
.target(name: "MyTarget", dependencies: ["HTTPTransport"])
```

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

MIT — see [LICENSE](./LICENSE).
