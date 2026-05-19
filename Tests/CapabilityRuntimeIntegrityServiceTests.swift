import SwiftData
import Testing
@testable import ASTRA
import ASTRACore

private func makeRuntimeIntegrityContainer() throws -> ModelContainer {
    let schema = ASTRASchema.current
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, migrationPlan: ASTRAMigrationPlan.self, configurations: [config])
}

@Suite("CapabilityRuntimeIntegrityServiceTests")
@MainActor
struct CapabilityRuntimeIntegrityServiceTests {
    @Test("enabled package denied by catalog policy blocks runtime activation")
    func enabledPackageDeniedByCatalogPolicyBlocksRuntimeActivation() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Runtime Policy", primaryPath: "/tmp/runtime-policy")
        let package = PluginPackage(
            id: "runtime-draft",
            name: "Runtime Draft",
            icon: "puzzlepiece.extension",
            description: "Draft package",
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
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)
        let task = AgentTask(title: "Use draft", goal: "Run draft capability", workspace: workspace)
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false,
            policyContext: CapabilityCatalogPolicyContext.workspaceUser(
                workspace: workspace,
                currentAppVersion: SemanticVersion(1, 0, 0)
            )
        )

        #expect(issues.map(\.resourceKind) == [.policy])
        #expect(issues.first?.message.contains("catalog policy blocks runtime activation") == true)
    }

    @Test("unknown browser adapter IDs are runtime integrity issues")
    func unknownBrowserAdapterIDsAreRuntimeIntegrityIssues() throws {
        let container = try makeRuntimeIntegrityContainer()
        let context = container.mainContext
        let workspace = Workspace(name: "Unknown Adapter", primaryPath: "/tmp/runtime-unknown-adapter")
        let package = PluginPackage(
            id: "unknown-browser-package",
            name: "Unknown Browser Package",
            icon: "safari",
            description: "Unknown browser adapter",
            author: "Tests",
            category: "Browser",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            browserAdapters: ["unknownAdapter"],
            governance: .builtInApproved(riskLevel: .high)
        )
        workspace.enabledCapabilityIDs = [package.id]
        context.insert(workspace)
        let task = AgentTask(title: "Use browser", goal: "Use unknown adapter", workspace: workspace)
        context.insert(task)
        try context.save()

        let issues = CapabilityRuntimeIntegrityService.issues(
            for: task,
            packages: [package],
            checkExecutables: false
        )

        #expect(issues.map(\.resourceKind) == [.browserAdapter])
        #expect(issues.first?.resourceName == "unknownAdapter")
        #expect(issues.first?.message.contains("not known to ASTRA") == true)
    }
}
