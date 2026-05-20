import Testing
@testable import ASTRA
import ASTRACore

@Suite("Capability Lifecycle Resolver")
@MainActor
struct CapabilityLifecycleResolverTests {
    @Test("lifecycle reports available installed enabled and blocked states")
    func lifecycleReportsStates() {
        let workspace = Workspace(name: "Lifecycle", primaryPath: "/tmp/lifecycle")
        var package = PluginPackage(
            id: "lifecycle-package",
            name: "Lifecycle Package",
            icon: "puzzlepiece.extension",
            description: "Lifecycle test",
            author: "Tests",
            category: "Tests",
            tags: [],
            version: "1.0.0",
            skills: [],
            connectors: [],
            localTools: [],
            templates: [],
            governance: .builtInApproved(riskLevel: .medium)
        )
        let capabilities = WorkspaceCapabilities(workspace: workspace)

        var context = CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            currentAppVersion: SemanticVersion(1, 0, 0)
        )
        var snapshot = CapabilityLifecycleResolver.resolve(
            package: package,
            workspace: workspace,
            capabilities: capabilities,
            context: context
        )
        #expect(snapshot.stateLabel == "Available")
        #expect(snapshot.canEnable)

        workspace.recordInstalledPlugin(id: package.id, version: package.version)
        workspace.enabledCapabilityIDs = [package.id]
        context = CapabilityCatalogPolicyContext.workspaceUser(
            workspace: workspace,
            currentAppVersion: SemanticVersion(1, 0, 0)
        )
        snapshot = CapabilityLifecycleResolver.resolve(
            package: package,
            workspace: workspace,
            capabilities: capabilities,
            context: context
        )
        #expect(snapshot.isInstalled)
        #expect(snapshot.isEnabled)
        #expect(snapshot.canRun)
        #expect(snapshot.stateLabel == "Active")

        package.governance.approvalStatus = .blocked
        snapshot = CapabilityLifecycleResolver.resolve(
            package: package,
            workspace: workspace,
            capabilities: capabilities,
            context: context
        )
        #expect(!snapshot.canRun)
        #expect(snapshot.stateLabel == "Blocked")
    }
}
