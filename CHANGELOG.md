# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `AnyStreamingTransport`, a concrete box for `any HTTPTransport & HTTPStreamingTransport`.
  Making `RetryingTransport` generic is what keeps the streaming capability through a wrap, but it
  also means an existential cannot be passed to it — an existential does not conform to the
  protocol it erases. A composition root that stores its transport as an existential, which is the
  ordinary shape for an injected dependency, needs this. Found by swift-api-client failing to build
  against 2.0.0.


## [2.0.0] - 2026-08-11

### Removed

- **BREAKING** — `RetryingTransport` is generic over its base, so wrapping a streaming transport
  keeps `stream`/`sseEvents` instead of silently dropping them. A caller holding
  `any HTTPTransport` can no longer wrap it directly; that is the cost of the compiler enforcing
  the capability rather than it disappearing at run time.
- `HTTPHeaders.init(_:)` now enforces uniqueness. `URLSession` folds repeated field names into one
  comma-joined value before this package sees them, so a multimap would promise access to values
  that cannot be recovered.

### Fixed

- **The retry jitter was a constant.** `backoff * 0.25` then `backoff - jitter` is `0.75 × backoff`
  every time, despite the name — five calls produced five identical delays. Clients that fail
  together retried together, which is the thundering herd the jitter exists to break up.
- **A POST that failed was silently re-sent.** Retry looked at the status and the error and never at
  the method. Replay is now allowed only for idempotent requests, decided per request rather than
  per policy, and overridable both ways (a POST carrying an idempotency key, a destructive DELETE).
- **`Equatable` was not reflexive.** `dup == dup` was false, because `==` counted entries and then
  looked up by name while the initialisers did not dedupe. Fixed in the initialiser: the comparison
  was only wrong because its precondition was unenforced.
- **The server's backpressure was discarded.** `Retry-After` was parsed as a bare number, so
  RFC 9110's HTTP-date form produced `nil` *and* `isEmpty == true` — indistinguishable from no
  rate-limit headers at all. All three date spellings are read now, and a past deadline reads `0`
  rather than `nil`, so `isEmpty` means what it says.
- **`TransportError.cancelled` was unreachable.** `catch is CancellationError` sat after the
  `URLError` path, so a cancelled task surfaced as `.network(URLError -999)`.
- **Streaming failures could not be tested.** `MockTransport.stream` ignored `scripted` and
  `handler`, so a scripted failure completed successfully with zero chunks. That is why the
  streaming defects above went unnoticed.
- **`HTTPStatusError` could not be constructed outside the module** — public properties, internal
  memberwise init — so consumers could not stage a streaming status failure.
- **An error body was buffered whole on the path that exists to avoid buffering**, byte at a time
  (~10k awaits per 10 KB). The delegate implementation now serves both platforms; error bodies are
  capped at `maxErrorBodyBytes`.
- `MockTransport.recordedRequests` was written under a lock and read without one.


## [1.1.3] - 2026-08-11

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
