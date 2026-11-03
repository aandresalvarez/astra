// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DevScaleBenchmarkSupport",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DevScaleBenchmarkSupport"),
        .testTarget(name: "DevScaleBenchmarkSupportTests", dependencies: ["DevScaleBenchmarkSupport"])
    ]
)
