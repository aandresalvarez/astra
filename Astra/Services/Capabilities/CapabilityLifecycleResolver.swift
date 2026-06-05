import Foundation
import ASTRACore

struct CapabilityLifecycleSnapshot: Equatable {
    var packageID: String
    var isInstalled: Bool
    var isEnabled: Bool
    var isVisible: Bool
    var canInstall: Bool
    var canEnable: Bool
    var canRun: Bool
    var requiresApproval: Bool
    var blockers: [String]
    var warnings: [String]

    var stateLabel: String {
        if canRun { return "Active" }
        if !blockers.isEmpty { return "Blocked" }
        if requiresApproval { return "Needs approval" }
        if isEnabled { return "Enabled" }
        if isInstalled { return "Installed" }
        if isVisible { return "Available" }
        return "Hidden"
    }
}

enum CapabilityLifecycleResolver {
    static func resolve(
        package: PluginPackage,
        workspace: Workspace,
        capabilities: WorkspaceCapabilities,
        context: CapabilityCatalogPolicyContext
    ) -> CapabilityLifecycleSnapshot {
        let decision = CapabilityCatalogPolicy.decision(for: package, context: context)
        let state = CapabilityPackageState(
            package: package,
            workspace: workspace,
            capabilities: capabilities
        )

        return CapabilityLifecycleSnapshot(
            packageID: package.id,
            isInstalled: context.installedPackageIDs.contains(package.id),
            isEnabled: state.isEnabled,
            isVisible: decision.isVisible,
            canInstall: decision.canInstall,
            canEnable: decision.canEnable,
            canRun: decision.canRun,
            requiresApproval: decision.requiresApproval,
            blockers: decision.blockerMessages,
            warnings: decision.warnings.map(\.message)
        )
    }
}
