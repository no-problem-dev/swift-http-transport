[English](./README.md) | 日本語

# swift-http-transport

通信層の唯一の生 HTTP 実体。`URLSession` をプロトコルの背後に置き、リトライ・レート制限・
SSE を一元化する。上位（swift-api-client、各プロバイダ）はこの抽象にのみ依存する。

## インストール

`Package.swift` に追加する:

```swift
.package(url: "https://github.com/no-problem-dev/swift-http-transport", from: "1.0.0")
```

ターゲットの依存へ追加する:

```swift
.target(name: "MyTarget", dependencies: ["HTTPTransport"])
```

## 使い方

### 基本リクエスト

```swift
import HTTPTransport

let transport = URLSessionTransport()
let request = HTTPRequest(method: "GET", url: URL(string: "https://api.example.com/data")!)
let response = try await transport.send(request)
if response.isSuccess {
    // response.body を利用する
}
```

### リトライ

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

### テスト

```swift
let mock = MockTransport(status: 200, body: Data("{\"ok\":true}".utf8))
let response = try await mock.send(request)
print(mock.recordedRequests.count) // 1
```

## モジュール構成

| 型 | 役割 |
|---|---|
| `HTTPTransport` / `HTTPStreamingTransport` | 送受信の規定プロトコル（`send` / `stream`） |
| `URLSessionTransport` | 既定の具象実装（`URLSession` 背後） |
| `MockTransport` | 決定論的テスト用（スクリプト/クロージャ応答・リクエスト記録） |
| `RetryPolicy` / `ExponentialBackoff` / `NoRetry` | 唯一のリトライ抽象（status + error + rate-limit で判定） |
| `RetryingTransport` | リトライをトランスポート層で一元化するデコレータ |
| `RateLimitHeaderMapping` / `RateLimitSnapshot` | ヘッダ名マッピングだけでレート制限抽出（秒/ミリ秒/RFC3339/duration suffix） |
| `SSEParser` / `SSEEvent` / `sseEvents(_:)` | WHATWG SSE フレーム分割・解釈 |

`HTTPRequest`/`HTTPResponse`/`HTTPHeaders`（大小文字無視・順序保持）は Foundation 最小の値型。

## ライセンス

MIT
