import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Retires workspace activations of former built-in plugins this build no
/// longer ships, through the normal Remove for a missing plugin
/// (`CapabilityCatalogActionService.forgetMissing`).
///
/// An enabled activation whose definition is gone fails the launch contract
/// (`PluginQueuedContractValidation`): every new task in that workspace stops
/// at preflight with `capability_runtime_resources_missing`, though nothing
/// of the plugin could run. Remove keeps what a person's Remove keeps (the
/// namespace seed, override rows, accounts and template IDs) as a retired
/// activation for a later Add; like that Remove, it does not keep the
/// activation's non-secret settings or its secrets.
///
/// Only the IDs listed here are retired, and only while no definition for
/// them exists (bundled or in the library): a local plugin whose file is
/// briefly unreadable is never forgotten by this pass. Idempotent: once the
/// activations are retired there is nothing left to do.
@MainActor
enum RetiredBuiltInActivationCleanup {
    /// Former built-ins: the five archived in `capabilities/archived/`, and
    /// two removed from the catalog earlier whose activations were left behind.
    static let retiredBuiltInIDs: [String] = [
        "code-reviewer",
        "google-drive-browser",
        "google-workspace",
        "security-auditor",
        "stanford-apple-mail",
        "stanford-healthcare-graph-mail",
        "stanford-outlook-mail"
    ]

    struct Outcome: Equatable {
        var retired: [String] = []
        var failed: [String] = []
    }

    @discardableResult
    static func retireActivations(
        modelContext: ModelContext,
        library: CapabilityLibrary = CapabilityLibrary(),
        builtInIDs: Set<String> = Set(PluginCatalog.builtInPackages.map(\.id)),
        ids: [String] = retiredBuiltInIDs,
        forget: (@MainActor (String, ModelContext) throws -> Void)? = nil
    ) -> Outcome {
        // Remove acts on the same library that said the definition is missing.
        let forget = forget ?? { id, context in
            try CapabilityCatalogActionService(library: library).forgetMissing(pluginID: id, modelContext: context)
        }
        var outcome = Outcome()
        let defined = builtInIDs.union(library.installedPackages().map(\.id))
        for id in ids where !defined.contains(id) {
            do {
                // The workspaces Remove would touch: an activation row, or a
                // plugin still held only in legacy state after a deferred
                // activation migration (`PluginRemovalScope`).
                guard try !PluginRemovalScope.capture(pluginID: id, modelContext: modelContext).workspaces.isEmpty else {
                    continue
                }
                try forget(id, modelContext)
                outcome.retired.append(id)
                AppLogger.audit(.capabilityDisabled, category: "Capabilities", fields: [
                    "operation": "retired_builtin_cleanup", "plugin_id": id, "result": "retired"
                ])
            } catch {
                outcome.failed.append(id)
                AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                    "operation": "retired_builtin_cleanup", "plugin_id": id,
                    "error_type": String(describing: error)
                ], level: .error)
            }
        }
        return outcome
    }
}
