// swift-tools-version: 5.10
// The shared harness code (HARNESS.md): flags, manifest, the run loop, the accepted-set
// check, CPU/RSS, the JSON rows, and the parent that runs each client in a fresh process.
// No dependencies.
import PackageDescription

let package = Package(
    name: "BenchCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BenchCore", targets: ["BenchCore"])],
    targets: [.target(name: "BenchCore")]
)
