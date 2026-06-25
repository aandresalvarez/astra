// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ASTRA",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ASTRA", targets: ["ASTRAExecutable"]),
        .executable(name: "astra-browser", targets: ["AstraBrowserTool"]),
        .executable(name: "astra-workspace", targets: ["AstraWorkspaceTool"]),
        .executable(name: "stanford-mail", targets: ["StanfordMailTool"]),
        .executable(name: "stanford-apple-mail", targets: ["StanfordAppleMailTool"]),
        .executable(name: "stanford-graph-mail", targets: ["StanfordGraphMailTool"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0")
    ],
    targets: [
        // Tiny Obj-C shim: lets Swift recover from AppKit calls that raise
        // NSException (e.g. NSSplitView pane mutations mid-layout-transition).
        .target(
            name: "AstraObjCSupport",
            path: "AstraObjCSupport"
        ),
        .target(
            name: "ASTRACore",
            path: "ASTRACore"
        ),
        .target(
            name: "ASTRAGitContracts",
            path: "ASTRAGitContracts"
        ),
        .target(
            name: "MailToolSupport",
            path: "Tools/MailToolSupport"
        ),
        .target(
            name: "WorkspaceToolSupport",
            path: "Tools/WorkspaceToolSupport"
        ),
        .executableTarget(
            name: "AstraBrowserTool",
            dependencies: ["ASTRACore"],
            path: "Tools/AstraBrowserTool"
        ),
        .executableTarget(
            name: "AstraWorkspaceTool",
            dependencies: ["WorkspaceToolSupport"],
            path: "Tools/AstraWorkspaceTool"
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
                "AstraObjCSupport",
                "ASTRACore",
                "ASTRAGitContracts",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Astra",
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppIconDev.icns"),
                .copy("Resources/Capabilities"),
                .copy("Resources/Fonts"),
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
            dependencies: ["ASTRA", "ASTRACore", "ASTRAGitContracts", "WorkspaceToolSupport"],
            path: "Tests"
        )
    ]
)
