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

    /// The listed IDs with no definition that Remove would still touch: an
    /// activation row, or a plugin held only in legacy state after a deferred
    /// activation migration, as `PluginRemovalScope` reads them. A store that
    /// can't be read counts every listed ID as pending, so the pass tries
    /// them and reports why.
    ///
    /// Startup recovery asks for a mirror scan while any is pending, as it does
    /// for other pending cleanup: the cleanup chain that runs this pass only
    /// runs on a launch whose recovery is trusted. Once they are retired,
    /// nothing is pending and launches go back to vouching without a scan.
    static func pendingIDs(
        modelContext: ModelContext,
        library: CapabilityLibrary = CapabilityLibrary(),
        builtInIDs: Set<String> = Set(PluginCatalog.builtInPackages.map(\.id)),
        ids: [String] = retiredBuiltInIDs
    ) -> [String] {
        let defined = builtInIDs.union(library.installedPackages().map(\.id))
        let missing = ids.filter { !defined.contains($0) }
        guard !missing.isEmpty else { return [] }
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()).filter({ !$0.isDeleted }) else {
            return missing
        }
        return missing.filter { id in
            workspaces.contains { workspace in
                workspace.pluginActivations.contains { !$0.isDeleted && $0.pluginID == id }
                    || WorkspaceCapabilityActivation.pendingLegacyInstallations(in: workspace).contains { $0.id == id }
                    || WorkspaceCapabilityActivation.pendingLegacyState(of: workspace).enabledPluginIDs.contains(id)
            }
        }
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
        for id in pendingIDs(modelContext: modelContext, library: library, builtInIDs: builtInIDs, ids: ids) {
            do {
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
