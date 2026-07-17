import Foundation
import SwiftData
import Testing
import ASTRACore
import ASTRAModels
import ASTRAPersistence
@testable import ASTRA

@Suite("Workspace Packages")
struct WorkspacePackageTests {

    // MARK: - Round trip

    @MainActor
    @Test("exported configuration package round-trips through validation")
    func exportedPackageRoundTripsThroughValidation() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        workspace.instructions = "Prefer concise summaries."

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        let result = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        #expect(result.manifest.workspaceName == workspace.name)
        #expect(result.manifest.exportProfile == .configurationOnly)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        #expect(report.workspaceConfig?.instructions == "Prefer concise summaries.")
    }

    @MainActor
    @Test("exported package excludes task history and workspace app run data")
    func exportedPackageExcludesHistory() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let task = AgentTask(title: "Investigate flaky test", goal: "Root-cause it", workspace: workspace)
        container.mainContext.insert(task)

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        #expect(report.workspaceConfig?.tasks == nil)
        #expect(report.workspaceConfig?.workspaceApps == nil)
    }

    // MARK: - Capability governance

    @MainActor
    @Test("exported package clamps custom capability governance to local draft")
    func exportedPackageClampsCapabilityGovernance() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        // Starts already-approved locally, so a passing test proves the
        // exporter actively clamps it down rather than happening to match a
        // default.
        try capabilityLibrary.install(
            Self.makeCapability(id: "local.tool", governance: .builtInApproved()),
            sourceMetadata: .localLibrary()
        )
        workspace.enabledCapabilityIDs = ["local.tool"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        let result = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        #expect(result.manifest.capabilityEntries.map(\.packageID) == ["local.tool"])
        let embeddedData = try Data(contentsOf: destination.appendingPathComponent("capabilities/local.tool.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let embedded = try decoder.decode(PluginPackage.self, from: embeddedData)
        #expect(embedded.governance.approvalStatus == .draft)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
    }

    // Deliberately no "excludes built-in capabilities" test: CapabilityLibrary's
    // read path (decodeInstalledPackage) re-derives trust from
    // CapabilityLibrary.trustedBuiltInPackageIDs — a real, compiled catalog —
    // not from whatever sourceMetadata a caller writes to disk, so a fixture
    // can't fake a built-in ID without coupling the test to production
    // catalog contents. The exporter's exclusion branch is simple, directly
    // reviewable code; the "embeds and clamps a non-built-in capability" test
    // above exercises the other side of the same condition.

    // MARK: - Exporter self-verification

    @MainActor
    @Test("exporter rejects a workspace whose instructions contain credential-like content")
    func exporterRejectsCredentialLikeContent() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        workspace.instructions = "Use the api_key stored in ~/.env for local runs."

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        #expect(throws: WorkspacePackageExportError.self) {
            _ = try WorkspacePackageExporter().exportConfigurationPackage(
                workspace: workspace,
                modelContext: container.mainContext,
                to: destination
            )
        }
        // Self-verification failure must not leave a staged or published
        // artifact behind for the caller to accidentally pick up.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Validation

    @MainActor
    @Test("package validation blocks tampered checksums")
    func validationBlocksTamperedChecksums() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let configURL = destination.appendingPathComponent("workspace-config.json")
        var data = try Data(contentsOf: configURL)
        data.append(contentsOf: "\n// tampered".utf8)
        try data.write(to: configURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("Checksum does not match") })
    }

    @MainActor
    @Test("package validation rejects package below minimum ASTRA version")
    func validationRejectsOldMinimumVersion() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let manifestURL = destination.appendingPathComponent("manifest.json")
        var manifest = try Self.decodeManifest(at: manifestURL)
        manifest.minimumASTRAVersion = "999.0.0"
        try Self.encodeManifest(manifest, to: manifestURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("requires ASTRA 999.0.0 or later") })
    }

    @MainActor
    @Test("package validation rejects unlisted files not present in checksums.json")
    func validationRejectsUnlistedFiles() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        try Data("stowaway".utf8).write(to: destination.appendingPathComponent("extra.txt"))

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("not listed in checksums.json") })
    }

    @MainActor
    @Test("package validation rejects embedded capability with elevated governance")
    func validationRejectsElevatedEmbeddedGovernance() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        try capabilityLibrary.install(
            Self.makeCapability(id: "local.tool", governance: .localDraft()),
            sourceMetadata: .localLibrary()
        )
        workspace.enabledCapabilityIDs = ["local.tool"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let capabilityURL = destination.appendingPathComponent("capabilities/local.tool.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var capability = try decoder.decode(PluginPackage.self, from: Data(contentsOf: capabilityURL))
        capability.governance.approvalStatus = .approved
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(capability).write(to: capabilityURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("must land as a local draft") })
    }

    // MARK: - Embedded apps

    @MainActor
    @Test("exported package embeds workspace apps as validated .astra-app bundles")
    func exportedPackageEmbedsWorkspaceApps() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)

        // Plant a real app on the workspace via the already-tested .astra-app
        // import path, rather than hand-building WorkspaceApp + on-disk
        // manifest bookkeeping ourselves.
        let sourcePackageURL = root.appendingPathComponent("source.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.minimalAppManifest(id: "notes", name: "Notes"),
            to: sourcePackageURL
        )
        _ = try WorkspaceAppPackageService().importPackage(
            at: sourcePackageURL,
            into: workspace,
            modelContext: container.mainContext
        )

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        let result = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        #expect(result.manifest.appEntries.count == 1)
        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        let entry = try #require(result.manifest.appEntries.first)
        let appReport = try #require(report.appReports[entry.logicalID])
        #expect(appReport.canInstall)
    }

    // MARK: - Machine-local state stripping

    @MainActor
    @Test("exported package strips the machine-local execution environment")
    func exportedPackageStripsExecutionEnvironment() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        workspace.activeExecutionEnvironmentJSON = "{\"kind\":\"docker\",\"sourcePath\":\"/opt/only-on-sender\"}"

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        #expect(report.workspaceConfig?.activeExecutionEnvironmentJSON == nil)
    }

    @MainActor
    @Test("exported package blanks SSH key paths but flags them for local setup")
    func exportedPackageBlanksSSHKeyPaths() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        SSHConnectionManager.save(
            [SSHConnection(name: "prod", host: "prod.example.com", user: "deploy", keyPath: "/Users/alice/.ssh/prod_key")],
            workspacePath: workspace.primaryPath
        )

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        let result = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // The sender's absolute private-key path never leaves the machine...
        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(report.canInstall)
        let ssh = try #require(report.workspaceConfig?.sshConnections)
        #expect(ssh.count == 1)
        #expect(ssh.allSatisfy { $0.keyPath.isEmpty })
        // ...but the connection is still flagged so the recipient knows to
        // re-point a key locally.
        #expect(result.manifest.sshConnectionsRequiringLocalKeys == ["prod"])
    }

    @MainActor
    @Test("exported package downgrades an asset-icon capability to its fallback symbol")
    func exportedPackageDowngradesAssetIcon() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)

        // A capability whose icon is an on-disk asset: CapabilityLibrary.install
        // would copy it from an asset root the draft clamp strips, so import
        // would throw and roll back the whole workspace. The exporter must
        // downgrade the icon to the descriptor's fallback symbol.
        let assetRoot = root.appendingPathComponent("asset-source", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assetRoot.appendingPathComponent("assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("png".utf8).write(to: assetRoot.appendingPathComponent("assets/icon.png"))
        var capability = Self.makeCapability(id: "local.tool", governance: .localDraft())
        capability.iconDescriptor = .asset("assets/icon.png", fallbackSystemName: "puzzlepiece.extension")

        let capabilityLibrary = CapabilityLibrary(directory: root.appendingPathComponent("capabilities", isDirectory: true))
        try capabilityLibrary.install(CapabilityPackageSource(package: capability, manifestURL: nil, assetRootURL: assetRoot))
        workspace.enabledCapabilityIDs = ["local.tool"]

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter(capabilityLibrary: capabilityLibrary).exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let embedded = try decoder.decode(
            PluginPackage.self,
            from: Data(contentsOf: destination.appendingPathComponent("capabilities/local.tool.json"))
        )
        #expect(embedded.iconDescriptor.kind == .systemSymbol)
        #expect(embedded.iconDescriptor.value == "puzzlepiece.extension")
        #expect(WorkspacePackageService().validatePackage(at: destination).canInstall)
    }

    // MARK: - Embedded app containment / version gate

    @MainActor
    @Test("package validation rejects an embedded app bundle path outside the package")
    func validationRejectsAppBundlePathTraversal() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let sourceApp = root.appendingPathComponent("source.astra-app", isDirectory: true)
        _ = try WorkspaceAppPackageService().exportPackage(
            manifest: Self.minimalAppManifest(id: "notes", name: "Notes"),
            to: sourceApp
        )
        _ = try WorkspaceAppPackageService().importPackage(at: sourceApp, into: workspace, modelContext: container.mainContext)

        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        // Point the app bundle outside the package: an untrusted manifest whose
        // checksums cover only its own files must not be able to validate/import
        // a bundle escaping the `.astra-share` directory.
        let manifestURL = destination.appendingPathComponent("manifest.json")
        var manifest = try Self.decodeManifest(at: manifestURL)
        manifest.appEntries = manifest.appEntries.map { entry in
            var tampered = entry
            tampered.relativeBundlePath = "../escape.astra-app"
            return tampered
        }
        try Self.encodeManifest(manifest, to: manifestURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("must stay inside the package") })
    }

    @MainActor
    @Test("package validation rejects a malformed minimum ASTRA version")
    func validationRejectsMalformedVersion() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (container, workspace) = try Self.makeWorkspace(root: root)
        let destination = root.appendingPathComponent("export.astra-share", isDirectory: true)
        _ = try WorkspacePackageExporter().exportConfigurationPackage(
            workspace: workspace,
            modelContext: container.mainContext,
            to: destination
        )

        let manifestURL = destination.appendingPathComponent("manifest.json")
        var manifest = try Self.decodeManifest(at: manifestURL)
        manifest.minimumASTRAVersion = "not-a-version"
        try Self.encodeManifest(manifest, to: manifestURL)

        let report = WorkspacePackageService().validatePackage(at: destination)
        #expect(!report.canInstall)
        #expect(report.blockers.contains { $0.message.contains("is not a valid version string") })
    }

    // MARK: - Fixtures

    @MainActor
    private static func makeWorkspace(root: URL, name: String = "Package Export") throws -> (ModelContainer, Workspace) {
        let container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let workspaceURL = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let workspace = Workspace(name: name, primaryPath: workspaceURL.path)
        container.mainContext.insert(workspace)
        return (container, workspace)
    }

    private static func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("workspace-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func minimalAppManifest(id: String, name: String) -> WorkspaceAppManifest {
        WorkspaceAppManifest(app: WorkspaceAppManifestMetadata(
            id: id,
            name: name,
            icon: "app",
            description: "Fixture app.",
            tags: [],
            archetypes: []
        ))
    }

    private static func makeCapability(id: String, governance: CapabilityGovernance) -> PluginPackage {
        PluginPackage(
            id: id,
            name: "Fixture Capability",
            icon: "puzzlepiece.extension",
            description: "Fixture capability for package export tests.",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: governance
        )
    }

    private static func decodeManifest(at url: URL) throws -> WorkspacePackageManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspacePackageManifest.self, from: Data(contentsOf: url))
    }

    private static func encodeManifest(_ manifest: WorkspacePackageManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url)
    }
}
