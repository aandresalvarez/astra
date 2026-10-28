import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

/// The save seam used by capability lifecycle services (install, enable,
/// disable, uninstall). Production goes through
/// `WorkspacePersistenceCoordinator.saveAndAutoExport`; tests inject a stub
/// that returns `false` to exercise the save-failure rollback paths without
/// a real failing `ModelContext`.
enum CapabilityPersistence {
    /// The property is nonisolated so it can be a default argument on the
    /// `@MainActor` lifecycle methods; the closure it holds is `@MainActor`
    /// and only runs the coordinator save when actually invoked.
    static let defaultPersist: @MainActor (Workspace?, ModelContext) -> Bool = { workspace, context in
        WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: workspace, modelContext: context)
    }

    /// Resource editors sit outside the catalog lifecycle services, but their
    /// successful saves still change catalog projections in every open window.
    /// Publish the same typed event used by install/enable workflows instead
    /// of relying on broad SwiftData save observation.
    @MainActor
    @discardableResult
    static func saveResourceMutation(
        workspace: Workspace?,
        isGlobal: Bool = false,
        modelContext: ModelContext
    ) -> Bool {
        guard defaultPersist(workspace, modelContext) else { return false }
        CapabilityCatalogPersistenceEvents.post(resourceChange(for: workspace, isGlobal: isGlobal))
        return true
    }

    static func resourceChange(
        for workspace: Workspace?,
        isGlobal: Bool = false
    ) -> CapabilityCatalogPersistenceChange {
        if isGlobal { return .global }
        guard let workspace else { return .global }
        return .workspace(workspace.id)
    }
}
