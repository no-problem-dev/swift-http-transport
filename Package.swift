// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-http-transport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "HTTPTransport", targets: ["HTTPTransport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(name: "HTTPTransport"),
        .testTarget(name: "HTTPTransportTests", dependencies: ["HTTPTransport"]),
    ]
)
