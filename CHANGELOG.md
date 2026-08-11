# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Builds and tests on Linux. `URLSession` lives in `FoundationNetworking` there, and
  corelibs-foundation has no `URLSession.bytes(for:)` — streaming is rebuilt on the
  `URLSessionDataDelegate` callbacks it does provide, so the streaming conformance is intact
  rather than gated away. The buffer drains in fixed slices to match the chunking Apple's
  byte-wise loop produces.


## [1.1.2] - 2026-07-30

### Fixed

- `SSEParser` splits lines at byte level. Swift treats CRLF as a single
  grapheme, so searching a `String` for a newline found no line breaks at all
  and a CRLF event stream decoded to zero events.

## [1.1.1] - 2026-07-19

### Added

- DocC catalog with a landing page, and doc comments across the public API.
- Tests exercising the real `URLSessionTransport` through a `URLProtocol` stub,
  plus table-driven tests for `ExponentialBackoff` and `RetryingTransport`.

### Fixed

- `URLSessionTransport` reports the error contract its documentation describes.

## [1.1.0] - 2026-05-31

### Changed

- `RetryingTransport` takes an existential `base` instead of being generic over
  the wrapped transport.

## [1.0.0] - 2026-05-31

Initial release.
