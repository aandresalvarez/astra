import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Plugin sources on the Plugins surface: adding, fetching and removing a
/// source, and importing a plugin from one after its review.
extension CapabilityCatalogActionService {
    /// Adds a source and fetches it. Returns false when the location is
    /// refused (a token in the URL, an unsupported scheme, an option).
    @discardableResult
    func addSource(_ input: String, coordinator: PluginSourceCoordinator = .shared) async throws -> Bool {
        try await coordinator.add(input) != nil
    }

    func refreshSource(_ source: PluginSource, coordinator: PluginSourceCoordinator = .shared) async throws {
        try await coordinator.refresh(source)
    }

    func removeSource(_ source: PluginSource, coordinator: PluginSourceCoordinator = .shared) async throws {
        try await coordinator.remove(source)
    }

    /// The validation report a source plugin's review shows.
    func review(_ plugin: SourcedPlugin) -> CapabilityPackageValidationReport? {
        guard let package = plugin.package else { return nil }
        return CapabilityPackageValidator.validate(
            package: package,
            installedPackages: library.installedPackages().filter { $0.id.lowercased() != package.id.lowercased() },
            checkPrerequisites: false
        )
    }

    /// Imports the exact package that was reviewed into the library, after
    /// confirming its source still offers that digest (T8). Adding it to a
    /// workspace is the row's Add, as for an imported file.
    ///
    /// The check and the writes run as one step for the plugin's ID across
    /// every source (`PluginSourceStore.exclusively`, T5, T13): another
    /// source's Add of the same ID, a file import or a Remove can't run
    /// between them, so the conflict check below sees the library the
    /// writes change.
    @discardableResult
    func importReviewed(
        _ plugin: SourcedPlugin,
        workspace: Workspace,
        modelContext: ModelContext,
        coordinator: PluginSourceCoordinator = .shared
    ) throws -> CapabilityPackageImportResult {
        guard let id = plugin.package?.id else { throw PluginSourceCatalogError.noLongerOffered }
        return try sourceStore.exclusively(pluginID: id) {
            try importReviewedExclusively(plugin, workspace: workspace, modelContext: modelContext, coordinator: coordinator)
        }
    }

    private func importReviewedExclusively(
        _ plugin: SourcedPlugin,
        workspace: Workspace,
        modelContext: ModelContext,
        coordinator: PluginSourceCoordinator
    ) throws -> CapabilityPackageImportResult {
        let package = try PluginSourceCatalog.confirmReviewed(
            plugin,
            store: coordinator.store,
            installed: library.installedPackages()
        )
        // The listing's rules (T5) already refused an ID installed from
        // elsewhere; the copy this source installed is replaced.
        let installed = library.installedPackages()
        let ownCopy = installed.first { $0.id == package.id }.map {
            PluginSourceCatalog.isOwnCopy($0, of: plugin.source, provenance: coordinator.store.provenance())
        } ?? false
        let report = CapabilityPackageValidator.validate(
            package: package,
            installedPackages: installed.filter { $0.id != package.id },
            checkPrerequisites: false
        )
        guard report.canInstall else { throw CapabilityPackageImportError(report: report) }
        // Provenance first: an exit after the library write still finds the
        // new copy named, and a failed write still finds the old one.
        try coordinator.store.beginProvenance(
            pluginID: package.id, sourceID: plugin.source.id, digest: PluginSourceCatalog.contentDigest(package)
        )
        let result = try CapabilityPackageImporter(library: library).importValidatedPackage(
            report,
            modelContext: modelContext,
            replacesInstalledCopy: ownCopy
        )
        if let stored = library.installedPackage(id: package.id) {
            try coordinator.recordInstalled(stored, from: plugin.source)
        }
        AppLogger.audit(.capabilityInstalled, category: "Capabilities", fields: [
            "source": "plugin_source",
            "source_id": plugin.source.id,
            "package_id": package.id,
            "package_version": package.version,
            "workspace_id": workspace.id.uuidString
        ])
        return result
    }
}
