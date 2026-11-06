// swift-tools-version: 5.10
//
// nostrLibBench Swift harness: the parent launcher (libbench). It runs each client in a
// fresh process of its library's binary. Each library lives in its own package under
// libs/<name>/ with its own Package.resolved, because the Swift Nostr libraries cannot share
// one dependency graph: two of them export a module named `NostrSDK` (nostr-sdk-ios and
// rust-nostr's nostr-sdk-swift), and they pin incompatible versions of secp256k1.swift
// (whose vendored C library would also clash at link time). The shared harness code is the
// BenchCore package (BenchCore/), which has no dependencies.
import PackageDescription

let package = Package(
    name: "libbench-swift",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "BenchCore")],
    targets: [
        .executableTarget(name: "libbench", dependencies: [.product(name: "BenchCore", package: "BenchCore")]),
    ]
)
