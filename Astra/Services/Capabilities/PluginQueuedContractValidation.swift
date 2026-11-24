import Foundation
import ASTRACore
import ASTRAModels

/// A detached launch must either execute its accepted definition or report
/// why it cannot. Merely filtering an incompatible plugin out of projection
/// would let the task run with missing capabilities. Live inventory keeps its
/// existing focus rules; launchWorkspaceID identifies a request-time copy.
enum PluginQueuedContractValidation {
    static func issues(in workspace: Workspace, packages: [PluginPackage],
                       library: CapabilityLibrary = CapabilityLibrary()) -> [CapabilityRuntimeIntegrityIssue] {
        let definitions = Dictionary(packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return activationIssues(in: workspace, definitions: definitions, library: library)
            + retiredRowIssues(in: workspace, definitions: definitions, library: library)
    }

    /// Rows a V20 migration kept as a retired built-in's pending overrides are
    /// still in scope as authored rows until `RetiredBuiltInActivationCleanup`
    /// retires them, also once the activation itself is gone (a Remove that
    /// saved before the rows' own save failed, or a crash in between). A
    /// request-time copy holding them is refused, so they never run.
    private static func retiredRowIssues(
        in workspace: Workspace, definitions: [String: PluginPackage], library: CapabilityLibrary
    ) -> [CapabilityRuntimeIntegrityIssue] {
        guard workspace.launchPluginDefinitions != nil else { return [] }
        let live = Set(WorkspaceCapabilityActivation.activations(of: workspace).map(\.pluginID))
        return RetiredBuiltInActivationCleanup.pendingRowPluginIDs(in: workspace, library: library)
            .filter { definitions[$0] == nil && !live.contains($0) }
            .map { pluginID in
                CapabilityRuntimeIntegrityIssue(
                    packageID: pluginID,
                    packageName: pluginID,
                    source: .enabledPackage,
                    resourceKind: .policy,
                    resourceName: pluginID,
                    message: "A retired plugin's leftover skills or tools are still in this workspace. ASTRA retires them at the next launch; submit the request again after that."
                )
            }
    }

    private static func activationIssues(
        in workspace: Workspace, definitions: [String: PluginPackage], library: CapabilityLibrary
    ) -> [CapabilityRuntimeIntegrityIssue] {
        WorkspaceCapabilityActivation.activations(of: workspace).compactMap { activation in
            guard activation.isEnabled, activation.launchWorkspaceID != nil else { return nil }
            let package = definitions[activation.pluginID]
            // A former built-in this build retired, with nothing stored under
            // its ID: nothing of it can run, and startup retires the activation
            // (`RetiredBuiltInActivationCleanup`). Until it has, a launch goes
            // on without it instead of failing.
            if package == nil, RetiredBuiltInActivationCleanup.awaitsRetirement(activation.pluginID, in: workspace, library: library) {
                return nil
            }
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
