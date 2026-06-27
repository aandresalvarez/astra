import Foundation
import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability Package Factory")
struct CapabilityPackageFactoryTests {
    @Test("behavior-only capability creates one skill")
    @MainActor
    func behaviorOnlyCapability() {
        let package = CapabilityPackageFactory.makePackage(
            name: "Research Reviewer",
            description: "Review research docs",
            behaviorInstructions: "Stay read-only.",
            allowedTools: ["Read", "Grep"]
        )

        #expect(package.id == "local.research-reviewer")
        #expect(package.skills.count == 1)
        #expect(package.connectors.isEmpty)
        #expect(package.localTools.isEmpty)
        #expect(package.skills.first?.behaviorInstructions == "Stay read-only.")
    }

    @Test("connector-only capability creates standalone connector package")
    @MainActor
    func connectorOnlyCapability() {
        let connector = Connector(name: "REDCap", serviceType: "rest_api", icon: "server.rack", connectorDescription: "REDCap API")
        connector.baseURL = "https://redcap.stanford.edu"
        connector.authMethod = "bearer"
        connector.credentialKeys = ["REDCAP_TOKEN"]
        connector.configKeys = ["REDCAP_PROJECT"]

        let package = CapabilityPackageFactory.makePackage(
            name: "REDCap Connector",
            description: "Connect to REDCap",
            connectors: [connector]
        )

        #expect(package.skills.isEmpty)
        #expect(package.connectors.count == 1)
        #expect(package.connectors.first?.credentialHints.map(\.key) == ["REDCAP_TOKEN"])
        #expect(package.connectors.first?.configHints.map(\.key) == ["REDCAP_PROJECT"])
    }

    @Test("tool-only capability creates standalone tool package")
    @MainActor
    func toolOnlyCapability() {
        let tool = LocalTool(name: "bq", toolDescription: "BigQuery CLI", toolType: "cli", command: "bq", arguments: "--format=json")

        let package = CapabilityPackageFactory.makePackage(
            name: "BigQuery Tool",
            description: "Run bq",
            localTools: [tool]
        )

        #expect(package.skills.isEmpty)
        #expect(package.localTools.count == 1)
        #expect(package.localTools.first?.command == "bq")
        #expect(package.localTools.first?.arguments == "--format=json")
    }

    @Test("MCP-only capability creates standalone MCP server package")
    @MainActor
    func mcpOnlyCapability() {
        let server = PluginMCPServer(
            id: "github",
            displayName: "GitHub MCP",
            transport: .stdio,
            command: "github-mcp-server",
            arguments: ["stdio"],
            allowedTools: ["issues.list"]
        )

        let package = CapabilityPackageFactory.makePackage(
            name: "GitHub MCP",
            description: "Expose GitHub MCP tools",
            mcpServers: [server]
        )
        let report = CapabilityPackageValidator.validate(package: package, checkPrerequisites: false)

        #expect(package.skills.isEmpty)
        #expect(package.mcpServers == [server])
        #expect(package.contentSummary == "1 MCP server")
        #expect(report.blockers.isEmpty)
    }

    @Test("full capability includes behavior connectors and tools")
    @MainActor
    func fullCapability() {
        let connector = Connector(name: "Google Cloud", serviceType: "google_cloud")
        let tool = LocalTool(name: "gcloud", toolType: "cli", command: "gcloud")

        let package = CapabilityPackageFactory.makePackage(
            name: "GCP Analyst",
            description: "Analyze GCP projects",
            behaviorInstructions: "Prefer dry runs.",
            connectors: [connector],
            localTools: [tool]
        )

        #expect(package.skills.count == 1)
        #expect(package.connectors.count == 1)
        #expect(package.localTools.count == 1)
        #expect(package.sourceMetadata == .localLibrary())
    }

    @Test("source exporter resolves repository capability library from dev app bundle")
    func sourceExporterResolvesBundleRepositoryLibrary() throws {
        let root = try temporaryDirectory(named: "astra-source-export-bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("capabilities", isDirectory: true),
            withIntermediateDirectories: true
        )
        let bundleURL = root
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("ASTRA Dev.app", isDirectory: true)

        let directory = CapabilityPackageSourceExporter.defaultSourceDirectory(
            startingAt: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            bundleURL: bundleURL,
            environment: [:]
        )

        #expect(directory?.standardizedFileURL == root
            .appendingPathComponent("capabilities", isDirectory: true)
            .appendingPathComponent("local", isDirectory: true)
            .standardizedFileURL)
    }

    @Test("source exporter supports explicit environment override")
    func sourceExporterSupportsEnvironmentOverride() throws {
        let root = try temporaryDirectory(named: "astra-source-export-env")
        defer { try? FileManager.default.removeItem(at: root) }
        let override = root.appendingPathComponent("library", isDirectory: true)

        let directory = CapabilityPackageSourceExporter.defaultSourceDirectory(
            environment: [CapabilityPackageSourceExporter.sourceLibraryEnvironmentKey: override.path]
        )

        #expect(directory?.standardizedFileURL == override.standardizedFileURL)
    }

    @Test("source exporter writes normalized draft package JSON")
    @MainActor
    func sourceExporterWritesNormalizedDraftPackageJSON() throws {
        let root = try temporaryDirectory(named: "astra-source-export-write")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = CapabilityPackageFactory.makePackage(
            name: "Exported Capability",
            description: "Saved from create flow",
            behaviorInstructions: "Stay read-only.",
            allowedTools: ["Read"]
        )
        var approvedPackage = package
        approvedPackage.governance = .builtInApproved(
            riskLevel: .high,
            dataAccess: [.workspaceFiles],
            externalEffects: [.externalAPIWrite]
        )
        let destination = root
            .appendingPathComponent("capabilities", isDirectory: true)
            .appendingPathComponent("local", isDirectory: true)
            .appendingPathComponent("exported.json")

        let writtenURL = try CapabilityPackageSourceExporter().export(approvedPackage, to: destination)
        let data = try Data(contentsOf: writtenURL)
        let decoded = try JSONDecoder().decode(PluginPackage.self, from: data)
        let report = CapabilityPackageValidator.validate(data: data, checkPrerequisites: false)

        #expect(writtenURL == destination)
        #expect(decoded.sourceMetadata == .localLibrary())
        #expect(decoded.governance.approvalStatus == .draft)
        #expect(decoded.governance.visibility == .adminOnly)
        #expect(decoded.governance.requiresAdminApproval)
        #expect(decoded.governance.requiresExplicitUserConsent)
        #expect(decoded.governance.approvedBy == nil)
        #expect(decoded.governance.approvedAt == nil)
        #expect(decoded.governance.riskLevel == .high)
        #expect(decoded.governance.dataAccess == [.workspaceFiles])
        #expect(decoded.governance.externalEffects == [.externalAPIWrite])
        #expect(report.blockers.isEmpty)
    }

    @Test("source exporter writes package folder with icon asset")
    func sourceExporterWritesPackageFolderWithIconAsset() throws {
        let root = try temporaryDirectory(named: "astra-source-export-assets")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("source", isDirectory: true)
        let assets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let sourceIcon = assets.appendingPathComponent("icon.svg")
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><path d=\"M0 0h1v1H0z\"/></svg>".utf8)
            .write(to: sourceIcon)
        let sourceManifest = sourceRoot.appendingPathComponent("capability.json")
        var package = PluginPackage(
            id: "local.export-asset",
            name: "Export Asset",
            icon: "puzzlepiece.extension",
            iconDescriptor: .asset("assets/icon.svg", fallbackSystemName: "puzzlepiece.extension"),
            description: "Export asset package",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .localDraft()
        )
        package.sourceMetadata = .localLibrary(url: sourceManifest)
        let destination = root.appendingPathComponent("exported-package", isDirectory: true)

        let writtenURL = try CapabilityPackageSourceExporter().export(package, to: destination)
        let copiedIcon = destination.appendingPathComponent("assets/icon.svg")
        let report = CapabilityPackageValidator.validateSource(at: destination, checkPrerequisites: false)

        #expect(writtenURL == destination.appendingPathComponent("capability.json"))
        #expect(FileManager.default.fileExists(atPath: copiedIcon.path))
        #expect(report.blockers.isEmpty)
    }
}

private func temporaryDirectory(named prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
