import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA
import ASTRACore

private func makeCapabilityActionContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

private func makeCapabilityActionLibrary() -> (CapabilityLibrary, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("astra-capability-action-\(UUID().uuidString)", isDirectory: true)
    return (CapabilityLibrary(directory: root), root)
}

private func makeActionPackage(id: String = "action-package") -> PluginPackage {
    PluginPackage(
        id: id,
        name: "Action Package",
        icon: "puzzlepiece.extension",
        description: "Package for action service tests",
        author: "Tests",
        category: "Tests",
        tags: ["action"],
        version: "1.0.0",
        skills: [
            PluginSkill(
                name: "Action Skill",
                icon: "puzzlepiece.extension",
                description: "Action skill",
                allowedTools: ["Read"],
                disallowedTools: [],
                customTools: [],
                behaviorInstructions: "Use the action package.",
                environmentKeys: [],
                environmentValues: []
            )
        ],
        connectors: [],
        localTools: [],
        templates: [],
        governance: .builtInApproved(riskLevel: .medium)
    )
}

@Suite("Capability Catalog Action Service")
@MainActor
struct CapabilityCatalogActionServiceTests {
    @Test("enable action installs package and enables workspace resources")
    func enableActionInstallsPackageAndEnablesWorkspaceResources() throws {
        let container = try makeCapabilityActionContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Actions", primaryPath: "/tmp/action-enable")
        context.insert(workspace)
        let (library, root) = makeCapabilityActionLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeActionPackage()
        let result = try CapabilityCatalogActionService(library: library).enable(
            package,
            workspace: workspace,
            modelContext: context,
            policyContext: CapabilityCatalogPolicyContext(isAdmin: true),
            source: "test",
            traceID: "trace-enable"
        )

        #expect(result.packageID == package.id)
        #expect(library.installedPackages().map(\.id) == [package.id])
        #expect(workspace.enabledCapabilityIDs == [package.id])
        #expect(workspace.enabledGlobalSkillIDs == result.skillIDs.map(\.uuidString))
    }

    @Test("create action installs draft package without enabling workspace")
    func createActionInstallsDraftPackageWithoutEnablingWorkspace() throws {
        let container = try makeCapabilityActionContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Actions", primaryPath: "/tmp/action-create")
        context.insert(workspace)
        let (library, root) = makeCapabilityActionLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeActionPackage(id: "created-action-package")
        let result = try CapabilityCatalogActionService(library: library).create(
            package,
            enableHere: false,
            sourceURL: nil,
            workspace: workspace,
            modelContext: context,
            policyContext: CapabilityCatalogPolicyContext(isAdmin: true),
            traceID: "trace-create"
        )

        #expect(result.package.id == package.id)
        #expect(!result.approvalRecordChanged)
        #expect(result.installedPackage == nil)
        #expect(library.installedPackages().map(\.id) == [package.id])
        #expect(workspace.enabledCapabilityIDs.isEmpty)
    }

    @Test("remove action delegates package cleanup to uninstaller")
    func removeActionDelegatesPackageCleanupToUninstaller() throws {
        let container = try makeCapabilityActionContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Actions", primaryPath: "/tmp/action-remove")
        context.insert(workspace)
        let (library, root) = makeCapabilityActionLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let package = makeActionPackage(id: "remove-action-package")
        let service = CapabilityCatalogActionService(library: library)
        try service.enable(
            package,
            workspace: workspace,
            modelContext: context,
            policyContext: CapabilityCatalogPolicyContext(isAdmin: true),
            source: "test",
            traceID: "trace-remove-enable"
        )

        let removal = try service.remove(package, modelContext: context)

        #expect(removal.packageID == package.id)
        #expect(library.installedPackage(id: package.id) == nil)
        #expect(workspace.enabledCapabilityIDs.isEmpty)
    }
}
