// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ASTRA",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ASTRARunLedger", targets: ["ASTRARunLedger"]),
        .library(name: "RunBrokerService", targets: ["RunBrokerService"]),
        // Standalone process-boundary fixture; never embedded in ASTRA.app.
        .executable(name: "run-ledger-open-harness", targets: ["RunLedgerOpenHarness"]),
        .executable(name: "ASTRA", targets: ["ASTRAExecutable"]),
        .executable(name: "astra-browser", targets: ["AstraBrowserTool"]),
        .executable(name: "astra-mcp-gateway", targets: ["AstraMCPGatewayTool"]),
        .executable(name: "astra-host-control", targets: ["AstraHostControlTool"]),
        .executable(name: "astra-run-supervisor", targets: ["AstraRunSupervisor"]),
        .executable(name: "astra-run-broker", targets: ["AstraRunBrokerTool"]),
        // Test-only: gives `swift test` an independently killable owner
        // process for parent-death regressions. The app bundle uses the
        // explicit TOOL_PRODUCTS allowlist and never stages this executable.
        .executable(name: "astra-agent-process-crash-harness", targets: ["AgentProcessCrashHarness"]),
        .executable(name: "astra-run-supervisor-broker-harness", targets: ["RunSupervisorBrokerHarness"]),
        .executable(name: "astra-workspace", targets: ["AstraWorkspaceTool"]),
        .executable(name: "stanford-mail", targets: ["StanfordMailTool"]),
        .executable(name: "stanford-apple-mail", targets: ["StanfordAppleMailTool"]),
        .executable(name: "stanford-graph-mail", targets: ["StanfordGraphMailTool"])
    ],
    dependencies: [
        .package(path: "ASTRAGitContracts"),
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
            dependencies: ["ASTRALogging"],
            path: "ASTRACore"
        ),
        .target(
            name: "ASTRALogging",
            path: "ASTRALogging"
        ),
        .target(
            name: "ASTRARunLedger",
            dependencies: ["ASTRACore"],
            path: "ASTRARunLedger",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "RunLedgerOpenHarness",
            dependencies: ["ASTRARunLedger", "ASTRACore"],
            path: "Tests/RunLedgerOpenHarness"
        ),
        .target(
            name: "RunSupervisorSupport",
            dependencies: ["ASTRACore"],
            path: "RunSupervisorSupport"
        ),
        .target(
            name: "RunBrokerKit",
            dependencies: ["ASTRACore", "ASTRARunLedger"],
            path: "RunBrokerKit"
        ),
        .target(
            name: "RunBrokerService",
            dependencies: [
                "ASTRACore",
                "ASTRARunLedger",
                "RunSupervisorSupport",
                "RunBrokerKit",
            ],
            path: "RunBrokerService"
        ),
        .target(
            name: "MailToolSupport",
            dependencies: ["ASTRACore"],
            path: "Tools/MailToolSupport"
        ),
        .target(
            name: "MCPServerKit",
            path: "Tools/MCPServerKit"
        ),
        .target(
            name: "WorkspaceToolSupport",
            dependencies: ["ASTRACore", "MCPServerKit"],
            path: "Tools/WorkspaceToolSupport"
        ),
        .target(
            name: "HostControlToolSupport",
            dependencies: ["MCPServerKit"],
            path: "Tools/HostControlToolSupport"
        ),
        .target(
            name: "MCPGatewaySupport",
            dependencies: ["MCPServerKit"],
            path: "Tools/MCPGatewaySupport"
        ),
        .executableTarget(
            name: "AstraBrowserTool",
            dependencies: ["ASTRACore"],
            path: "Tools/AstraBrowserTool"
        ),
        .executableTarget(
            name: "AstraMCPGatewayTool",
            dependencies: ["MCPGatewaySupport"],
            path: "Tools/AstraMCPGatewayTool"
        ),
        .executableTarget(
            name: "AstraHostControlTool",
            dependencies: ["HostControlToolSupport"],
            path: "Tools/AstraHostControlTool"
        ),
        .executableTarget(
            name: "AstraRunBrokerTool",
            dependencies: ["RunBrokerKit"],
            path: "Tools/AstraRunBrokerTool"
        ),
        .executableTarget(
            name: "AstraWorkspaceTool",
            dependencies: ["WorkspaceToolSupport"],
            path: "Tools/AstraWorkspaceTool"
        ),
        .executableTarget(
            name: "AstraRunSupervisor",
            dependencies: ["RunSupervisorSupport"],
            path: "Tools/AstraRunSupervisor"
        ),
        // Kept under Tests and excluded from ASTRATests source discovery.
        .executableTarget(
            name: "AgentProcessCrashHarness",
            dependencies: ["ASTRA"],
            path: "Tests/AgentProcessCrashHarness"
        ),
        .executableTarget(
            name: "RunSupervisorBrokerHarness",
            dependencies: ["RunSupervisorSupport"],
            path: "Tests/RunSupervisorBrokerHarness"
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
            name: "ASTRAModels",
            dependencies: ["ASTRACore"],
            path: "Astra/Models"
        ),
        .target(
            name: "ASTRAPersistence",
            dependencies: ["AstraObjCSupport", "ASTRACore", "ASTRAModels"],
            path: "Astra/Services/Persistence"
        ),
        .target(
            name: "ASTRA",
            dependencies: [
                "AstraObjCSupport",
                "ASTRACore",
                "ASTRALogging",
                "ASTRAModels",
                "ASTRAPersistence",
                "RunSupervisorSupport",
                .product(name: "ASTRAGitContracts", package: "ASTRAGitContracts"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Astra",
            exclude: ["Models", "Services/Persistence"],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppIconDev.icns"),
                .copy("Resources/Capabilities"),
                .copy("Resources/Fonts"),
                .copy("Resources/Packs"),
                .copy("Resources/Tools")
            ]
        ),
        .executableTarget(
            name: "ASTRAExecutable",
            dependencies: ["ASTRA"],
            path: "AppExecutable"
        ),
        .testTarget(
            name: "MCPGatewaySupportTests",
            dependencies: ["MCPGatewaySupport"],
            path: "Tests/MCPGatewaySupportTests"
        ),
        .testTarget(
            name: "ArchitectureFitnessTests",
            dependencies: [],
            path: "Tests/ArchitectureFitnessTests",
            exclude: ["Package.swift"]
        ),
        .testTarget(
            name: "ASTRAGitContractsTests",
            dependencies: [
                .product(name: "ASTRAGitContracts", package: "ASTRAGitContracts")
            ],
            path: "ASTRAGitContracts/Tests/ASTRAGitContractsTests"
        ),
        // Test-only C shim: the module-load hook Swift itself lacks. Its
        // __attribute__((constructor)) runs when dyld loads the ASTRATests
        // bundle — before either test framework schedules a suite, while the
        // process is still single-threaded — and calls the @_cdecl entry
        // point in Tests/RuntimeSeamTestBootstrap.swift, which runs
        // RuntimeSeamRegistration.registerAll(). Never link this into a
        // production target: the app registers explicitly in ASTRAApp.init(),
        // and the seams' fail-fast traps must stay meaningful there.
        .target(
            name: "AstraTestSeamBootstrap",
            path: "Tests/AstraTestSeamBootstrap"
        ),
        .testTarget(
            name: "ASTRATests",
            dependencies: [
                "ASTRA",
                "ASTRACore",
                "ASTRAModels",
                "ASTRAPersistence",
                "AstraTestSeamBootstrap",
                "HostControlToolSupport",
                "MCPGatewaySupport",
                "MCPServerKit",
                "WorkspaceToolSupport",
                .product(name: "ASTRAGitContracts", package: "ASTRAGitContracts")
            ],
            path: "Tests",
            exclude: ["ArchitectureFitnessTests", "AgentProcessCrashHarness", "ASTRARunLedgerTests", "RunSupervisorBrokerHarness", "AstraTestSeamBootstrap", "MCPGatewaySupportTests", "MCPServerKitTests", "MailToolSupportTests", "RunLedgerOpenHarness", "RunSupervisorSupportTests", "RunBrokerKitTests", "RunBrokerServiceTests"],
            resources: [.copy("Fixtures/feedback-only-v12-htf3-empty.store")]
        ),
        .testTarget(
            name: "ASTRARunLedgerTests",
            dependencies: ["ASTRARunLedger", "ASTRACore"],
            path: "Tests/ASTRARunLedgerTests",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "MailToolSupportTests",
            dependencies: ["MailToolSupport"],
            path: "Tests/MailToolSupportTests"
        ),
        .testTarget(
            name: "MCPServerKitTests",
            dependencies: ["MCPServerKit"],
            path: "Tests/MCPServerKitTests"
        ),
        .testTarget(
            name: "RunSupervisorSupportTests",
            dependencies: ["RunSupervisorSupport", "ASTRACore"],
            path: "Tests/RunSupervisorSupportTests"
        ),
        .testTarget(
            name: "RunBrokerKitTests",
            dependencies: ["RunBrokerKit", "ASTRARunLedger"],
            path: "Tests/RunBrokerKitTests"
        ),
        .testTarget(
            name: "RunBrokerServiceTests",
            dependencies: [
                "RunBrokerService",
                "ASTRACore",
                "ASTRARunLedger",
                "RunSupervisorSupport",
                "RunBrokerKit",
            ],
            path: "Tests/RunBrokerServiceTests"
        )
    ]
)
