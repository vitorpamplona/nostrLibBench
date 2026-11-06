// swift-tools-version: 5.10
// rust-nostr's Swift bindings: package `nostr-sdk-swift` (github.com/rust-nostr/nostr-sdk-swift,
// now nostrdevkit/nostr-sdk-swift), module `NostrSDK`. That module name clashes with
// nostr-sdk-ios's, which is one reason every library has its own package here. Apple
// platforms only: the Rust core ships as a prebuilt nostr_sdkFFI.xcframework binary target.
import PackageDescription

let package = Package(
    name: "libbench-rust-nostr",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../BenchCore"),
        .package(url: "https://github.com/rust-nostr/nostr-sdk-swift", exact: "0.45.1"),
    ],
    targets: [
        .executableTarget(
            name: "libbench-rust-nostr",
            dependencies: [
                .product(name: "BenchCore", package: "BenchCore"),
                .product(name: "NostrSDK", package: "nostr-sdk-swift", condition: .when(platforms: [.macOS, .iOS])),
            ]
        ),
    ]
)
