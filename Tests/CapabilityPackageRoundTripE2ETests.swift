import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Capability package round trip E2E")
@MainActor
struct CapabilityPackageRoundTripE2ETests {
    @Test("create flow saves source JSON and enables the workspace")
    func createFlowSavesSourceJSONAndEnablesWorkspace() throws {
        let root = try roundTripTemporaryDirectory(named: "astra-capability-create-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root
            .appendingPathComponent("capabilities", isDirectory: true)
            .appendingPathComponent("local", isDirectory: true)
            .appendingPathComponent("created.json")
        let library = CapabilityLibrary(directory: root.appendingPathComponent("app-library", isDirectory: true))
        let approvalStore = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals", isDirectory: true))
        let container = try makeRoundTripContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Round Trip Workspace", primaryPath: root.appendingPathComponent("workspace", isDirectory: true).path)
        context.insert(workspace)

        let package = roundTripPackage(name: "Created Round Trip")
        let service = CapabilityPackageCreationService(
            library: library,
            sourceExporter: CapabilityPackageSourceExporter(),
            approvalStore: approvalStore,
            appVersion: SemanticVersion(1, 0, 0)
        )

        let result = try service.create(
            package,
            enableHere: true,
            sourceURL: sourceURL,
            workspace: workspace,
            modelContext: context,
            configInputs: ["ROUNDTRIP_PROJECT": "dev"],
            policyContext: CapabilityCatalogPolicyContext.workspaceUser(
                workspace: workspace,
                isAdmin: true,
                currentAppVersion: SemanticVersion(1, 0, 0),
                approvalRecords: []
            )
        )

        let sourcePackage = try JSONDecoder().decode(PluginPackage.self, from: Data(contentsOf: sourceURL))
        let installedPackage = try #require(library.installedPackage(id: package.id))
        let approvalRecord = try #require(result.approvalRecord)
        let storedApproval = try #require(approvalStore.record(for: installedPackage))
        let skills = try context.fetch(FetchDescriptor<Skill>())
        let tools = try context.fetch(FetchDescriptor<LocalTool>())

        #expect(result.sourceURL == sourceURL)
        #expect(result.installationResult?.packageID == package.id)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(sourcePackage.sourceMetadata == .localLibrary())
        #expect(sourcePackage.governance.approvalStatus == .draft)
        #expect(sourcePackage.governance.visibility == .adminOnly)
        #expect(sourcePackage.governance.approvedBy == nil)
        #expect(sourcePackage.governance.approvedAt == nil)
        #expect(installedPackage.id == package.id)
        #expect(approvalRecord.sourceDigest == storedApproval.sourceDigest)
        #expect(workspace.enabledCapabilityIDs == [package.id])
        #expect(workspace.installedVersion(of: package.id) == package.version)
        #expect(skills.contains { $0.originPackageID == package.id && $0.name == package.name })
        #expect(tools.contains { $0.originPackageID == package.id && $0.name == "jq" })

        let runDecision = CapabilityCatalogPolicy.decision(
            for: installedPackage,
            context: CapabilityCatalogPolicyContext.workspaceUser(
                workspace: workspace,
                isAdmin: true,
                currentAppVersion: SemanticVersion(1, 0, 0),
                approvalRecords: approvalStore.records()
            )
        )
        #expect(runDecision.canRun)
    }

    @Test("exported source JSON imports and enables only after local approval")
    func exportedSourceJSONImportsAndEnablesAfterApproval() throws {
        let root = try roundTripTemporaryDirectory(named: "astra-capability-import-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root
            .appendingPathComponent("capabilities", isDirectory: true)
            .appendingPathComponent("local", isDirectory: true)
            .appendingPathComponent("source.json")
        let library = CapabilityLibrary(directory: root.appendingPathComponent("app-library", isDirectory: true))
        let approvalStore = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals", isDirectory: true))
        let container = try makeRoundTripContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Imported Source Workspace", primaryPath: root.appendingPathComponent("workspace", isDirectory: true).path)
        context.insert(workspace)

        let package = roundTripPackage(name: "Imported Round Trip")
        _ = try CapabilityPackageSourceExporter().export(package, to: sourceURL)
        let importResult = try CapabilityPackageImporter(library: library).importFile(
            at: sourceURL,
            checkPrerequisites: false
        )
        let importedPackage = importResult.package

        #expect(importedPackage.governance.approvalStatus == .draft)
        #expect(approvalStore.record(for: importedPackage) == nil)

        do {
            _ = try CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0)).install(
                importedPackage,
                into: workspace,
                modelContext: context,
                policyContext: CapabilityCatalogPolicyContext.workspaceUser(
                    workspace: workspace,
                    isAdmin: true,
                    currentAppVersion: SemanticVersion(1, 0, 0),
                    approvalRecords: []
                )
            )
            Issue.record("Imported source JSON should require approval before enablement.")
        } catch let error as CapabilityInstaller.InstallationError {
            if case .blocked(let messages) = error {
                #expect(messages.contains { $0.contains("draft review") || $0.contains("requires approval") })
            }
        }

        let approvalRecord = try approvalStore.save(
            package: importedPackage,
            status: .approved,
            approvedBy: "Test Review",
            reviewNotes: "Approved imported source package for E2E round trip."
        )
        let result = try CapabilityInstaller(library: library, appVersion: SemanticVersion(1, 0, 0)).install(
            importedPackage,
            into: workspace,
            modelContext: context,
            configInputs: ["ROUNDTRIP_PROJECT": "dev"],
            policyContext: CapabilityCatalogPolicyContext.workspaceUser(
                workspace: workspace,
                isAdmin: true,
                currentAppVersion: SemanticVersion(1, 0, 0),
                approvalRecords: [approvalRecord]
            )
        )

        #expect(result.packageID == importedPackage.id)
        #expect(workspace.enabledCapabilityIDs.contains(importedPackage.id))
        #expect(library.installedPackage(id: importedPackage.id)?.sourceMetadata == .localLibrary())
    }

    @Test("create flow rejects invalid packages without partial writes")
    func createFlowRejectsInvalidPackagesWithoutPartialWrites() throws {
        let root = try roundTripTemporaryDirectory(named: "astra-capability-invalid-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root
            .appendingPathComponent("capabilities", isDirectory: true)
            .appendingPathComponent("local", isDirectory: true)
            .appendingPathComponent("invalid.json")
        let library = CapabilityLibrary(directory: root.appendingPathComponent("app-library", isDirectory: true))
        let approvalStore = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals", isDirectory: true))
        let container = try makeRoundTripContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Invalid Package Workspace", primaryPath: root.appendingPathComponent("workspace", isDirectory: true).path)
        context.insert(workspace)

        var package = roundTripPackage(name: "Invalid Round Trip")
        package.localTools = [
            PluginLocalTool(
                name: "Danger",
                description: "Unsafe shell command",
                icon: "terminal",
                toolType: "cli",
                command: "curl;rm",
                arguments: ""
            )
        ]
        let service = CapabilityPackageCreationService(
            library: library,
            sourceExporter: CapabilityPackageSourceExporter(),
            approvalStore: approvalStore,
            appVersion: SemanticVersion(1, 0, 0)
        )

        do {
            _ = try service.create(
                package,
                enableHere: true,
                sourceURL: sourceURL,
                workspace: workspace,
                modelContext: context,
                policyContext: CapabilityCatalogPolicyContext.workspaceUser(
                    workspace: workspace,
                    isAdmin: true,
                    currentAppVersion: SemanticVersion(1, 0, 0),
                    approvalRecords: []
                )
            )
            Issue.record("Unsafe created capability should be rejected before any writes.")
        } catch let error as CapabilityPackageCreationError {
            if case .invalidPackage(let report) = error {
                #expect(report.blockers.map(\.code).contains(.unsafeLocalTool))
            }
        }

        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(library.installedPackages().isEmpty)
        #expect(approvalStore.records().isEmpty)
        #expect(workspace.enabledCapabilityIDs.isEmpty)
    }

    @Test("create flow rejects duplicate package IDs without partial writes")
    func createFlowRejectsDuplicatePackageIDWithoutPartialWrites() throws {
        let root = try roundTripTemporaryDirectory(named: "astra-capability-duplicate-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root
            .appendingPathComponent("capabilities", isDirectory: true)
            .appendingPathComponent("local", isDirectory: true)
            .appendingPathComponent("duplicate.json")
        let library = CapabilityLibrary(directory: root.appendingPathComponent("app-library", isDirectory: true))
        let approvalStore = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals", isDirectory: true))
        let container = try makeRoundTripContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Duplicate Package Workspace", primaryPath: root.appendingPathComponent("workspace", isDirectory: true).path)
        context.insert(workspace)

        let package = roundTripPackage(name: "Duplicate Round Trip")
        var existing = package
        existing.version = "9.0.0"
        try library.install(existing, sourceMetadata: .localLibrary())
        let service = CapabilityPackageCreationService(
            library: library,
            sourceExporter: CapabilityPackageSourceExporter(),
            approvalStore: approvalStore,
            appVersion: SemanticVersion(1, 0, 0)
        )

        do {
            _ = try service.create(
                package,
                enableHere: true,
                sourceURL: sourceURL,
                workspace: workspace,
                modelContext: context,
                policyContext: CapabilityCatalogPolicyContext.workspaceUser(
                    workspace: workspace,
                    isAdmin: true,
                    currentAppVersion: SemanticVersion(1, 0, 0),
                    approvalRecords: []
                )
            )
            Issue.record("Duplicate created capability should be rejected before overwriting package state.")
        } catch let error as CapabilityPackageCreationError {
            if case .invalidPackage(let report) = error {
                #expect(report.blockers.map(\.code).contains(.duplicatePackageID))
            }
        }

        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(library.installedPackage(id: package.id)?.version == "9.0.0")
        #expect(approvalStore.records().isEmpty)
        #expect(workspace.enabledCapabilityIDs.isEmpty)
    }

    @Test("create flow does not persist approval if install fails")
    func createFlowDoesNotPersistApprovalIfInstallFails() throws {
        let root = try roundTripTemporaryDirectory(named: "astra-capability-install-failure-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedLibraryURL = root.appendingPathComponent("blocked-library")
        try Data("not a directory".utf8).write(to: blockedLibraryURL)
        let library = CapabilityLibrary(directory: blockedLibraryURL)
        let approvalStore = CapabilityApprovalStore(directory: root.appendingPathComponent("approvals", isDirectory: true))
        let container = try makeRoundTripContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Install Failure Workspace", primaryPath: root.appendingPathComponent("workspace", isDirectory: true).path)
        context.insert(workspace)

        let package = roundTripPackage(name: "Install Failure Round Trip")
        let service = CapabilityPackageCreationService(
            library: library,
            sourceExporter: CapabilityPackageSourceExporter(),
            approvalStore: approvalStore,
            appVersion: SemanticVersion(1, 0, 0)
        )

        do {
            _ = try service.create(
                package,
                enableHere: true,
                sourceURL: nil,
                workspace: workspace,
                modelContext: context,
                policyContext: CapabilityCatalogPolicyContext.workspaceUser(
                    workspace: workspace,
                    isAdmin: true,
                    currentAppVersion: SemanticVersion(1, 0, 0),
                    approvalRecords: []
                )
            )
            Issue.record("Create flow should surface the failed package install.")
        } catch {
            #expect(approvalStore.records().isEmpty)
            #expect(workspace.enabledCapabilityIDs.isEmpty)
        }
    }
}

private func makeRoundTripContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@MainActor
private func roundTripPackage(name: String) -> PluginPackage {
    let connector = Connector(name: "Round Trip API", serviceType: "rest_api", icon: "network", connectorDescription: "Round trip API")
    connector.baseURL = "https://api.example.com"
    connector.authMethod = "none"
    connector.configKeys = ["ROUNDTRIP_PROJECT"]

    let tool = LocalTool(
        name: "jq",
        toolDescription: "JSON processor",
        toolType: "cli",
        command: "jq",
        arguments: "."
    )

    return CapabilityPackageFactory.makePackage(
        name: name,
        description: "Capability package round trip test",
        behaviorInstructions: "Stay read-only and summarize JSON.",
        allowedTools: ["Read", "Grep"],
        connectors: [connector],
        localTools: [tool]
    )
}

private func roundTripTemporaryDirectory(named prefix: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
