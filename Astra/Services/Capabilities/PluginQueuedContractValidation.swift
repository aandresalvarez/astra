import Foundation
import ASTRACore
import ASTRAModels

/// A detached launch must either execute its accepted definition or report
/// why it cannot. Merely filtering an incompatible plugin out of projection
/// would let the task run with missing capabilities. Live inventory keeps its
/// existing focus rules; launchWorkspaceID identifies a request-time copy.
enum PluginQueuedContractValidation {
    static func issues(in workspace: Workspace, packages: [PluginPackage]) -> [CapabilityRuntimeIntegrityIssue] {
        let definitions = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return WorkspaceCapabilityActivation.activations(of: workspace).compactMap { activation in
            guard activation.isEnabled, activation.launchWorkspaceID != nil else { return nil }
            let package = definitions[activation.pluginID]
            guard package.map({ PluginRuntimeProjection.awaitsUpdate(activation, to: $0) }) ?? true else { return nil }
            return CapabilityRuntimeIntegrityIssue(
                packageID: activation.pluginID,
                packageName: package?.name ?? activation.pluginID,
                source: .enabledPackage,
                resourceKind: .policy,
                resourceName: activation.pluginID,
                message: "The plugin definition no longer matches this queued request. Submit a new request to use the current plugin configuration."
            )
        }
    }
}
