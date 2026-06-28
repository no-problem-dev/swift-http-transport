# ``HTTPTransport``

NOPROBLEM スタックの唯一の生 HTTP 接合点。`URLSession` はプロトコルの背後に隠蔽され、
リトライ・レート制限解析・SSE デコードをここに集約することで上位層は `URLSession` を直接扱わなくてよい。

## Overview

すべてのプロバイダと `swift-api-client` は ``HTTPTransport`` と
``HTTPStreamingTransport`` プロトコルにのみ依存するため、
本番用の `URLSessionTransport`・決定論的な `MockTransport`・
``RetryingTransport`` のようなカスタムデコレータへの差し替えが可能。

**基本的な使い方:**

1. ``HTTPRequest`` を構築する（メソッド・URL・ヘッダ・ボディ・タイムアウトを指定）。
2. ``HTTPTransport/send(_:)`` を呼び出してレスポンス ``HTTPResponse`` を受け取る。
   バイトストリーミングには ``HTTPStreamingTransport/stream(_:)`` を使用する。
3. ``RetryingTransport`` でラップすることで、``ExponentialBackoff`` と
   ``RateLimitHeaderMapping`` によるレート制限ヘッダ対応の自動リトライを追加できる。
4. `text/event-stream` レスポンスには ``HTTPStreamingTransport/sseEvents(_:)`` を呼び出して
   デコード済みの ``SSEEvent`` ストリームを受け取る。

## Topics

### リクエストとレスポンス

- ``HTTPRequest``
- ``HTTPResponse``
- ``HTTPHeaders``
- ``TransportError``
- ``HTTPStatusError``

### トランスポートプロトコル

- ``HTTPTransport``
- ``HTTPStreamingTransport``

### 具象トランスポート

- ``URLSessionTransport``
- ``RetryingTransport``
- ``MockTransport``

### リトライ

- ``RetryPolicy``
- ``RetryDecision``
- ``ExponentialBackoff``
- ``NoRetry``

### レート制限

- ``RateLimitHeaderMapping``
- ``RateLimitSnapshot``

### サーバー送信イベント

- ``SSEParser``
- ``SSEEvent``
