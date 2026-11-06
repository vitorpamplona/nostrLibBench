// swift-tools-version: 5.10
// yysskk/swift-nostr (NostrClient). Builds on macOS and Linux; needs Swift 6.3+.
// Not a copy of the library: only the harness's client code, against the upstream package.
import PackageDescription

let package = Package(
    name: "libbench-swift-nostr",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../BenchCore"),
        .package(url: "https://github.com/yysskk/swift-nostr", exact: "0.9.0"),
        // Only for the swift-nostr-websocketkit variant: the WebSocketSessionFactory the
        // library documents for platforms without URLSession WebSockets (e.g. Linux).
        .package(url: "https://github.com/vapor/websocket-kit", exact: "2.16.2"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
    ],
    targets: [
        .executableTarget(
            name: "libbench-swift-nostr",
            dependencies: [
                .product(name: "BenchCore", package: "BenchCore"),
                .product(name: "NostrClient", package: "swift-nostr"),
                .product(name: "NostrCore", package: "swift-nostr"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ]
)
