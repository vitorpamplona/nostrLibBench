// swift-tools-version: 5.10
//
// nostrLibBench Swift harness: the shared harness code (BenchCore) and the parent
// launcher (libbench). Each library lives in its own package under libs/<name>/ with its
// own Package.resolved, because the Swift Nostr libraries cannot share one dependency
// graph: two of them export a module named `NostrSDK` (nostr-sdk-ios and rust-nostr's
// nostr-sdk-swift), and they pin incompatible versions of secp256k1.swift (whose C code
// would also clash at link time). This package has no dependencies.
import PackageDescription

let package = Package(
    name: "libbench-swift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BenchCore", targets: ["BenchCore"]),
        .executable(name: "libbench", targets: ["libbench"]),
    ],
    targets: [
        .target(name: "BenchCore"),
        .executableTarget(name: "libbench", dependencies: ["BenchCore"]),
    ]
)
