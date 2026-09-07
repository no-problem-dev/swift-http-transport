[English](./README.md) | 日本語

# swift-http-transport

リトライ・レート制限・Server-Sent Events・ファイルのダウンロードを、API クライアントごとにではなく
1 回だけ書く。`URLSession` はプロトコルの背後にあるので、テストでは差し替えられる。

## 概要

この上の層はすべて `URLSession` ではなく `HTTPTransport` プロトコルに依存する。
それで得られるものが 5 つある。

- **リトライの規則がひとつ。** `RetryingTransport` は任意のトランスポートを包み、
  ステータス・スローされたエラー・解析済みのクォータヘッダをまとめて見るポリシーを
  適用する。プロバイダごとに少しずつ違うリトライループを書かなくてよい。
- **レート制限をプロバイダごとに解析しない。** プロバイダはヘッダ名とリセット時刻の
  表記形式を宣言するだけでよく、解析そのものはここにある。
- **実ストリームで壊れない SSE。** フレームの分割をバイト単位で行うため、CRLF 改行も
  チャンク境界をまたぐマルチバイト文字も正しくデコードされる。
- **ファイルをメモリに載せないダウンロード。** `HTTPDownloadTransport` は本文を
  そのまま宛先へ書き、進捗を返し、途中で止まった転送を続きから再開できる。
- **ネットワーク無しのテスト。** `MockTransport` は応答を台本どおりに返し、
  送られたリクエストを記録する。ダウンロードも同じ台本で動く。

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

ダウンロードはバイト列を返さずファイルへ書く。本文が全部届くまで宛先には何も置かないので、
失敗しても中途半端なファイルが残らない。

```swift
let file = try await transport.download(
    HTTPRequest(method: "GET", url: URL(string: "https://cdn.example.com/track.flac")!),
    to: destination,
    onProgress: { progress in print(progress.fraction ?? 0) }
)
print(file.byteCount, file.headers.contentRange as Any)
```

止まった転送は `DownloadInterruption` としてスローされる。サーバーが再開を許す場合は、
続きに必要なものがその中に入っている:

```swift
do {
    return try await transport.download(request, to: destination)
} catch let stopped as DownloadInterruption {
    guard let resumption = stopped.resumption else { throw stopped }
    return try await transport.download(continuing: resumption)
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
.package(url: "https://github.com/no-problem-dev/swift-http-transport", from: "2.0.0")
```

ターゲットにプロダクトを追加する:

```swift
.target(name: "MyTarget", dependencies: ["HTTPTransport"])
```

## コントリビュート

[CONTRIBUTING.md](./CONTRIBUTING.md) を参照。

## ライセンス

MIT — [LICENSE](./LICENSE) を参照。
