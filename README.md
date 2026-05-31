# swift-http-transport

通信層の唯一の生 HTTP 実体。`URLSession` をプロトコルの背後に置き、リトライ・レート制限・
SSE を一元化する。上位（swift-api-client、各プロバイダ）はこの抽象にのみ依存する。

## 構成

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
