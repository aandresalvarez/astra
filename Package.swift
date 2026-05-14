// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ASTRA",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ASTRA", targets: ["ASTRAExecutable"]),
        .executable(name: "astra-browser", targets: ["AstraBrowserTool"]),
        .executable(name: "stanford-mail", targets: ["StanfordMailTool"]),
        .executable(name: "stanford-apple-mail", targets: ["StanfordAppleMailTool"]),
        .executable(name: "stanford-graph-mail", targets: ["StanfordGraphMailTool"])
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
            name: "MailToolSupport",
            path: "Tools/MailToolSupport"
        ),
        .executableTarget(
            name: "AstraBrowserTool",
            dependencies: ["ASTRACore"],
            path: "Tools/AstraBrowserTool"
        ),
        .executableTarget(
            name: "StanfordMailTool",
            dependencies: ["MailToolSupport"],
            path: "Tools/StanfordMailTool"
        ),
        .executableTarget(
            name: "StanfordAppleMailTool",
            dependencies: ["MailToolSupport"],
            path: "Tools/StanfordAppleMailTool"
        ),
        .executableTarget(
            name: "StanfordGraphMailTool",
            dependencies: ["MailToolSupport"],
            path: "Tools/StanfordGraphMailTool"
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
