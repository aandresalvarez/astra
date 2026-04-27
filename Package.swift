// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ASTRA",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ASTRA", targets: ["ASTRAExecutable"])
    ],
    targets: [
        .target(
            name: "ASTRACore",
            path: "ASTRACore"
        ),
        .target(
            name: "ASTRA",
            dependencies: ["ASTRACore"],
            path: "Astra",
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .executableTarget(
            name: "ASTRAExecutable",
            dependencies: ["ASTRA"],
            path: "AppExecutable"
        ),
        .testTarget(
            name: "ASTRATests",
            dependencies: ["ASTRA", "ASTRACore"],
            path: "Tests"
        )
    ]
)
