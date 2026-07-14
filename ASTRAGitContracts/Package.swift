// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ASTRAGitContracts",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ASTRAGitContracts", targets: ["ASTRAGitContracts"])
    ],
    dependencies: [],
    targets: [
        .target(name: "ASTRAGitContracts"),
        .testTarget(
            name: "ASTRAGitContractsTests",
            dependencies: ["ASTRAGitContracts"]
        )
    ]
)
