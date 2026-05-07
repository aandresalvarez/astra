// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ASTRA",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ASTRA", targets: ["ASTRAExecutable"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1")
    ],
    targets: [
        .target(
            name: "ASTRACore",
            path: "ASTRACore"
        ),
        .target(
            name: "ASTRA",
            dependencies: [
                "ASTRACore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Astra",
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/Capabilities"),
                .copy("Resources/Tools")
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
