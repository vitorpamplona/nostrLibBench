// swift-tools-version: 5.10
// nostr-sdk-ios (the `NostrSDK` package of github.com/nostr-sdk/nostr-sdk-ios).
// Apple platforms only: the library imports Combine, os.log, CommonCrypto and Security.
import PackageDescription

let package = Package(
    name: "libbench-nostr-sdk-ios",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../BenchCore"),
        // main as of 2026-01-10: the 0.3.0 tag (2025-02) predates #216, the fix for the
        // `Data.bytes` ambiguity that breaks its build with current Apple SDKs.
        .package(url: "https://github.com/nostr-sdk/nostr-sdk-ios", revision: "e5855cbd3bdabf44075fd2abdf76f63bac4cbd5f"),
    ],
    targets: [
        .executableTarget(
            name: "libbench-nostr-sdk-ios",
            dependencies: [
                .product(name: "BenchCore", package: "BenchCore"),
                .product(name: "NostrSDK", package: "nostr-sdk-ios", condition: .when(platforms: [.macOS, .iOS])),
            ]
        ),
    ]
)
