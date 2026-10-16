import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

@Suite("Capability package round trip E2E")
@MainActor
struct CapabilityPackageRoundTripE2ETests {
    @Test("a shared package JSON imports and enables only after local approval")
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
        var shared = package
        shared.governance = .localDraft()
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(shared).write(to: sourceURL)
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
