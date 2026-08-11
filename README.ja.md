[English](./README.md) | 日本語

# swift-http-transport

リトライ・レート制限・Server-Sent Events を、API クライアントごとにではなく 1 回だけ書く。
`URLSession` はプロトコルの背後にあるので、テストでは差し替えられる。

## 概要

この上の層はすべて `URLSession` ではなく `HTTPTransport` プロトコルに依存する。
それで得られるものが 4 つある。

- **リトライの規則がひとつ。** `RetryingTransport` は任意のトランスポートを包み、
  ステータス・スローされたエラー・解析済みのクォータヘッダをまとめて見るポリシーを
  適用する。プロバイダごとに少しずつ違うリトライループを書かなくてよい。
- **レート制限をプロバイダごとに解析しない。** プロバイダはヘッダ名とリセット時刻の
  表記形式を宣言するだけでよく、解析そのものはここにある。
- **実ストリームで壊れない SSE。** フレームの分割をバイト単位で行うため、CRLF 改行も
  チャンク境界をまたぐマルチバイト文字も正しくデコードされる。
- **ネットワーク無しのテスト。** `MockTransport` は応答を台本どおりに返し、
  送られたリクエストを記録する。

HTTP のエラーステータスはスローされない。4xx・5xx は通常のレスポンスとして返る。
スローされるのは、レスポンスが成立しなかった場合だけ。

依存は Foundation のみ。

## 使い方

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

リトライの組み立て・SSE のストリーミング・モックを使ったテストはドキュメントにある。

## ドキュメント

[API リファレンスとガイド](https://no-problem-dev.github.io/swift-http-transport/documentation/httptransport)

## 動作環境

Swift 6.2 · iOS 17 · macOS 14 · tvOS 17 · watchOS 10 · visionOS 1 · Linux

## インストール

`Package.swift` に追加する:

```swift
.package(url: "https://github.com/no-problem-dev/swift-http-transport", from: "1.0.0")
```

ターゲットにプロダクトを追加する:

```swift
.target(name: "MyTarget", dependencies: ["HTTPTransport"])
```

## コントリビュート

[CONTRIBUTING.md](./CONTRIBUTING.md) を参照。

## ライセンス

MIT — [LICENSE](./LICENSE) を参照。
