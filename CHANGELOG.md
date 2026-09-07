# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `HTTPDownloadTransport`, the third seam beside `HTTPTransport` and `HTTPStreamingTransport`. It
  writes a response body to a file rather than into memory — which the other two cannot do, since
  `send(_:)` buffers by contract and `stream(_:)` leaves writing, counting, and cleaning up after a
  failure to every caller in turn. Nothing reaches the destination until the body has arrived
  whole, so a failure never leaves a truncated file behind. `URLSessionTransport` implements it on
  `URLSessionDownloadTask`; `MockTransport` implements it from the same script it already answers
  `send(_:)` from, so a caller's download code is testable without a network.
- Progress arrives through an `onProgress` closure taking a `DownloadProgress`, rather than through
  a stream of events. A download's result is a file, not a sequence, and a stream cannot hand back
  resume data once its consumer has stopped consuming — which is exactly the moment a pause
  produces it. `expected` is optional rather than a sentinel: a chunked response genuinely has no
  total, and a progress bar that cannot be drawn should become a spinner rather than be drawn wrong.
- `DownloadInterruption` carries a `DownloadResumption` when the server left continuing possible,
  and cancelling the surrounding task is the same thing as pausing — the request stops and the
  resumption comes back in the thrown interruption. Continuing takes the resumption and nothing
  else: the URL loading system's resume data already contains the original request, so passing one
  beside it would only let the two contradict each other. On Linux this is always `nil`;
  swift-corelibs-foundation compiles the whole resume path and implements none of it, so a resume
  loop written against this degrades to starting over there rather than failing.
- `HTTPHeaders.contentLength` and `HTTPHeaders.contentRange`, the latter parsing all three shapes
  RFC 9110 §14.4 allows into a `ContentRange`. Range requests could already be *sent*; there was
  nothing to read the answer with. These sit on `HTTPHeaders` rather than on the download result,
  so they are reachable from an `HTTPResponse` and an `HTTPStatusError` too.
- `.github/workflows/tests.yml`, restoring the test gate removed in 2.2.0's workflow sync. The
  cost of not having it is on record: `agent-runtime` 0.18.0 was tagged with tests that did not
  compile, because a warm local `.build` answered green. Three packages are about to be changed;
  a gate that has never run cannot say whether the changes held.

### Fixed

- The DocC landing page linked `sseEvents(_:)`, which has not been the symbol's name since 2.2.0
  added `onRawFrame:` to it. The generated page dropped the link silently and the build warned
  where nobody was reading.

### Tested

- Twenty-one cases for the download path. The file lands with the right bytes, missing parent
  directories are created and a stale file replaced, progress never decreases and ends at the size
  that actually landed, a total the server withheld reads as `nil` rather than as `-1`,
  `Content-Range` comes back parsed from a 206, and a non-2xx, a network failure, a cancellation,
  and an unwritable destination each leave nothing at all at the destination.
- Nine of those are Apple-only, and the reason is worth writing down rather than working around: a
  custom `URLProtocol` cannot answer a download task on Linux. corelibs hands the delegate
  `urlProtocol.properties[.temporaryFileURL] as! URL`, and that property is set in exactly one
  place — its own internal `NativeProtocol`. The force-unwrap kills the process rather than failing
  a test. Real downloads there go through `NativeProtocol` and are unaffected; what cannot be
  reproduced on Linux is the stub, not the feature.
- The resume seam is pinned where it is reachable. A `URLProtocol` stub never mints resume data,
  so the extraction from a failure's `userInfo` is tested directly — including that the key is
  spelled `NSURLSessionDownloadTaskResumeData` on Darwin and `URLSessionDownloadTaskResumeData` on
  Linux, for the same string. Naming either one unguarded is a compile error on the other side.

## [2.2.1] - 2026-08-24

### Fixed

- The defaulted-argument cancellation added in 2.2.0 was too greedy: it dropped *every* defaulted
  parameter before comparing, so a declaration that already had several lost them all. That made a
  real break able to match the stripped form and be cancelled — computing minor where major was
  right, which is the more dangerous direction of the two. It now peels one defaulted parameter
  off the end at a time and looks for the baseline among those intermediate forms. Two depth-
  counting traps are handled: `->` whose `>` is not a closing bracket, and a parameter list whose
  `)` is not the last one in the declaration. Pinned by `scripts/lib/test-strip-defaulted-args.sh`,
  nine cases, weighted toward the ones that must *not* cancel.

## [2.2.0] - 2026-08-24

### Added

- `sseEvents(_:onRawFrame:)` hands over each chunk before parsing. Parsing is lossy in exactly the
  way that matters when the question is *what did the server actually send*: the bytes inside a
  `data:` line, and where one chunk ended, are both gone by the time a frame is decoded. Chasing a
  trailing newline in a model's streamed text had no way to tell one the model wrote from one the
  transport's own framing implied. Omitting the closure keeps the previous behaviour.

### Tested

- `data:` lines keep their newlines: several `data:` lines join with `\n`, and an empty one still
  counts as a line. Neither was pinned before.

### Fixed

- `scripts/compute-next-version.sh` counted a defaulted parameter as a removal. A USR carries the
  argument labels, so adding `b:` with a default rewrites it and reads as remove-plus-add — major,
  for a change no caller has to touch. It now cancels those out by comparing declarations with the
  defaulted parameter dropped, and leaves a real signature change alone (a changed type, a required
  parameter, a deleted function all still count). This release would have been 3.0.0 otherwise.
  Two `sed` patterns in that script also relied on `\t`, which BSD `sed` does not read as a tab;
  the USR prefix survived and the comparison silently compared the wrong strings.

## [2.1.0] - 2026-08-11

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
