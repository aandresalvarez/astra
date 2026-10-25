import Foundation
import SwiftData
import ASTRAModels

/// Immutable first-tap consent for a library-wide Remove. Activations remain
/// the owners; this value records exactly which saved setup may be retired.
struct PluginRemovalScope: Equatable {
    struct WorkspaceEntry: Equatable {
        let id: UUID
        let name: String
        let activations: [PluginActivationRecord]
        let legacyVersion: String?
        let legacyEnabled: Bool
    }
    let pluginID: String
    let workspaces: [WorkspaceEntry]

    @MainActor
    static func capture(pluginID: String, modelContext: ModelContext) throws -> Self {
        try requireCurrent(pluginID: pluginID, confirmedScope: nil, modelContext: modelContext)
    }

    /// A fresh context is storage authority; the executing graph must match
    /// it too. Refuse before journals, library changes or credential cleanup.
    @MainActor
    @discardableResult
    static func requireCurrent(pluginID: String, confirmedScope: Self?, modelContext: ModelContext) throws -> Self {
        guard !modelContext.hasChanges else { throw PluginOperations.OperationError.pendingEdits }
        let saved = ModelContext(modelContext.container)
        saved.autosaveEnabled = false
        let persisted = try read(pluginID: pluginID, modelContext: saved)
        let executing = try read(pluginID: pluginID, modelContext: modelContext)
        guard persisted == executing, confirmedScope.map({ $0 == persisted }) ?? true else {
            throw Failure.scopeChanged
        }
        return persisted
    }

    @MainActor
    private static func read(pluginID: String, modelContext: ModelContext) throws -> Self {
        let rows = try modelContext.fetch(FetchDescriptor<Workspace>())
        let entries = rows.filter { !$0.isDeleted }.compactMap { workspace -> WorkspaceEntry? in
            let activations = workspace.pluginActivations.filter { !$0.isDeleted && $0.pluginID == pluginID }
                .sorted { $0.id.uuidString < $1.id.uuidString }.map(PluginActivationRecord.init)
            let version = WorkspaceCapabilityActivation.pendingLegacyInstallations(in: workspace)
                .first { $0.id == pluginID }?.version
            let enabled = WorkspaceCapabilityActivation.pendingLegacyState(of: workspace).enabledPluginIDs.contains(pluginID)
            guard !activations.isEmpty || version != nil || enabled else { return nil }
            return WorkspaceEntry(id: workspace.id, name: workspace.name, activations: activations,
                legacyVersion: version, legacyEnabled: enabled)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        return Self(pluginID: pluginID, workspaces: entries)
    }

    enum Failure: LocalizedError, Equatable {
        case scopeChanged
        var errorDescription: String? { "Plugin setup changed in an affected workspace. Review Remove again." }
    }
}
