// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ASTRAArchitectureFitness",
    platforms: [.macOS(.v14)],
    targets: [
        .testTarget(
            name: "ArchitectureFitnessTests",
            path: ".",
            exclude: ["Package.swift"]
        )
    ]
)
