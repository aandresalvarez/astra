import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

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
    nonisolated static let retiredBuiltInIDs: [String] = [
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
        /// Left for a later launch: the shared context held unsaved edits,
        /// which this pass must not commit along with its own.
        var deferred: [String] = []
    }

    /// Whether a launch may go on without an enabled activation of
    /// `pluginID` that has no definition: a listed former built-in with no
    /// package stored under its ID, which this pass will retire. Nothing of it
    /// can run. A stored package that failed to decode is a local plugin, not a
    /// retired one, and keeps failing the launch contract
    /// (`PluginQueuedContractValidation`).
    ///
    /// Not while `workspace` still holds rows a V20 migration kept as the
    /// plugin's pending overrides: those stay in scope as authored rows until
    /// this pass retires them, so the launch keeps failing rather than run them.
    nonisolated static func awaitsRetirement(_ pluginID: String, in workspace: Workspace,
                                             library: CapabilityLibrary = CapabilityLibrary()) -> Bool {
        retiredBuiltInIDs.contains(pluginID) && !isStored(pluginID, in: library)
            && !holdsPendingOverrides(pluginID, workspace)
    }

    /// The listed IDs with no definition that still hold something in a
    /// workspace: what Remove acts on (an activation row, or a plugin held only
    /// in legacy state after a deferred activation migration, as
    /// `PluginRemovalScope` reads them), or rows a V20 store's migration kept
    /// as the plugin's pending overrides. A store that can't be read counts
    /// every listed ID as pending, so the pass tries them and reports why.
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
        let missing = missingIDs(library: library, builtInIDs: builtInIDs, ids: ids)
        guard !missing.isEmpty else { return [] }
        guard let workspaces = try? modelContext.fetch(FetchDescriptor<Workspace>()).filter({ !$0.isDeleted }) else {
            return missing
        }
        return missing.filter { id in
            workspaces.contains { inRemovalScope(id, $0) || holdsPendingOverrides(id, $0) }
        }
    }

    /// How often, and how far apart, startup tries before it leaves a
    /// retirement to the next launch: about a minute for edits to be saved.
    nonisolated static let savedContextTries = 12
    nonisolated static let savedContextPause: Duration = .seconds(5)

    /// `retireActivations`, tried again while the shared context holds unsaved
    /// edits. The pass can't commit them, and startup runs it once: refused a
    /// single time, the retirement waited for the next launch, and for every
    /// launch after it when something leaves an edit unsaved at each one.
    ///
    /// An edit is saved by its owner or by autosave. Until then each try
    /// waits `pause` without running the pass or reporting anything, and
    /// `mayRun` is asked again after every wait. Only the last try lets the
    /// pass refuse and say so; what it leaves is retried at the next launch,
    /// as before. With nothing to retire there is nothing to wait for.
    @discardableResult
    static func retireActivationsOnceSaved(
        modelContext: ModelContext,
        library: CapabilityLibrary = CapabilityLibrary(),
        builtInIDs: Set<String> = Set(PluginCatalog.builtInPackages.map(\.id)),
        ids: [String] = retiredBuiltInIDs,
        forget: (@MainActor (String, ModelContext) throws -> Void)? = nil,
        tries: Int = savedContextTries,
        pause: Duration = savedContextPause,
        wait: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        mayRun: @MainActor () -> Bool = { !Task.isCancelled }
    ) async -> Outcome {
        var total = Outcome()
        var remaining = ids
        var reportedWait = false
        for attempt in 1...max(tries, 1) {
            if attempt < tries, modelContext.hasChanges {
                total.deferred = pendingIDs(modelContext: modelContext, library: library, builtInIDs: builtInIDs, ids: remaining)
                guard !total.deferred.isEmpty else { break }
                if !reportedWait {
                    reportedWait = true
                    AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                        "operation": "retired_builtin_cleanup", "result": "waiting_for_unsaved_edits",
                        "plugin_ids": total.deferred.joined(separator: ",")
                    ], level: .info)
                }
                await wait(pause)
                guard mayRun() else { break }
                continue
            }
            let outcome = MainThreadPhase.tracking("startup_cleanup_retired_builtins") {
                retireActivations(modelContext: modelContext, library: library, builtInIDs: builtInIDs,
                                  ids: remaining, forget: forget)
            }
            total.retired += outcome.retired
            total.failed += outcome.failed
            total.deferred = outcome.deferred
            // A refused Remove is reported once and left for the next launch;
            // only what the pass put off is tried again.
            remaining = outcome.deferred
            if remaining.isEmpty { break }
        }
        return total
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
        let pending = pendingIDs(modelContext: modelContext, library: library, builtInIDs: builtInIDs, ids: ids)
        for (index, id) in pending.enumerated() {
            // The pass shares the app's context and saves it: an unrelated
            // unsaved edit would be committed (and its mirror skipped) with it.
            guard !modelContext.hasChanges else {
                outcome.deferred = Array(pending[index...])
                AppLogger.audit(.capabilityEnableFailed, category: "Capabilities", fields: [
                    "operation": "retired_builtin_cleanup", "result": "deferred_unsaved_edits",
                    "plugin_ids": outcome.deferred.joined(separator: ",")
                ], level: .error)
                break
            }
            do {
                let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>()).filter { !$0.isDeleted }
                if workspaces.contains(where: { inRemovalScope(id, $0) }) {
                    try forget(id, modelContext)
                }
                // Rows a V20 migration kept as the plugin's pending overrides
                // stay in scope as authored rows; a retired plugin's rows leave
                // it with its activation, and come back as overrides on Add.
                for workspace in workspaces where WorkspaceCapabilityActivation.retirePendingOverrides(pluginID: id, in: workspace) {
                    do {
                        try WorkspacePersistenceCoordinator.saveAndAutoExportOrThrow(
                            workspace: workspace, modelContext: modelContext,
                            auditFields: ["operation": "retired_builtin_cleanup", "plugin_id": id])
                    } catch {
                        // Not committed: the context was clean before this
                        // change, so rolling back restores the saved record and
                        // the rows stay pending for the next launch.
                        if modelContext.hasChanges { modelContext.rollback() }
                        throw error
                    }
                }
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

    private static func missingIDs(library: CapabilityLibrary, builtInIDs: Set<String>, ids: [String]) -> [String] {
        let defined = builtInIDs.union(library.installedPackages().map(\.id))
        return ids.filter { !defined.contains($0) && !isStored($0, in: library) }
    }

    /// A package stored under the ID that failed to decode (a local import
    /// reusing the ID, briefly unreadable) is not missing: leave it be.
    /// The JSON file, or the package folder even without its manifest, as the
    /// library itself counts occupied storage.
    nonisolated private static func isStored(_ id: String, in library: CapabilityLibrary) -> Bool {
        [library.packageURL(for: id), library.packageManifestURL(for: id).deletingLastPathComponent()]
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func inRemovalScope(_ id: String, _ workspace: Workspace) -> Bool {
        workspace.pluginActivations.contains { !$0.isDeleted && $0.pluginID == id }
            || WorkspaceCapabilityActivation.pendingLegacyInstallations(in: workspace).contains { $0.id == id }
            || WorkspaceCapabilityActivation.pendingLegacyState(of: workspace).enabledPluginIDs.contains(id)
    }

    /// Listed former built-ins whose V20 pending rows `workspace` still holds in
    /// scope (`PluginQueuedContractValidation`). A package stored under the ID
    /// keeps this pass from retiring them, but not the launch from being
    /// refused while they are in scope without a definition.
    nonisolated static func pendingRowPluginIDs(in workspace: Workspace) -> [String] {
        retiredBuiltInIDs.filter { holdsPendingOverrides($0, workspace) }
    }

    nonisolated private static func holdsPendingOverrides(_ id: String, _ workspace: Workspace) -> Bool {
        WorkspaceCapabilityActivation.retiredActivations(of: workspace)
            .contains { $0.pluginID == id && !($0.pendingOverrides ?? []).isEmpty }
    }
}
