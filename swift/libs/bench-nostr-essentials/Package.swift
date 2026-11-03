// swift-tools-version: 5.10
// NostrEssentials (github.com/nostur-com/nostr-essentials), the library of the Nostur app.
// Apple platforms only: its relay pool imports Combine, Network (NWPathMonitor) and CoreData.
import PackageDescription

let package = Package(
    name: "libbench-nostr-essentials",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../BenchCore"),
        // main as of 2026-03-28; the only tag, 1.0.0, is from 2024-02 (78 commits behind).
        .package(url: "https://github.com/nostur-com/nostr-essentials", revision: "50bd46edd4cf2fed1d042868aa91ea4fcb953787"),
    ],
    targets: [
        .executableTarget(
            name: "libbench-nostr-essentials",
            dependencies: [
                .product(name: "BenchCore", package: "BenchCore"),
                .product(name: "NostrEssentials", package: "nostr-essentials", condition: .when(platforms: [.macOS, .iOS])),
            ]
        ),
    ]
)
