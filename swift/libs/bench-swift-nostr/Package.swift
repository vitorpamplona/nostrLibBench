// swift-tools-version: 5.10
// yysskk/swift-nostr (NostrClient). Builds on macOS and Linux; needs Swift 6.3+.
import PackageDescription

let package = Package(
    name: "libbench-swift-nostr",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../BenchCore"),
        .package(url: "https://github.com/yysskk/swift-nostr", exact: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "libbench-swift-nostr",
            dependencies: [
                .product(name: "BenchCore", package: "BenchCore"),
                .product(name: "NostrClient", package: "swift-nostr"),
                .product(name: "NostrCore", package: "swift-nostr"),
            ]
        ),
    ]
)
