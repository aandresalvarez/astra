import Foundation

enum PackWorkspacePolicyProvider {
    static func resolvedPolicy(
        for workspace: Workspace?,
        catalogSnapshot: AstraPackCatalogSnapshot? = nil
    ) -> PackResolvedPolicy {
        guard let workspace else { return .empty }
        return resolvedPolicy(
            enabledPackIDs: workspace.enabledPackIDs,
            catalogSnapshot: catalogSnapshot
        )
    }

    static func resolvedPolicy(
        enabledPackIDs rawEnabledPackIDs: [String],
        catalogSnapshot: AstraPackCatalogSnapshot? = nil
    ) -> PackResolvedPolicy {
        let enabledPackIDs = Set(
            rawEnabledPackIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !enabledPackIDs.isEmpty else { return .empty }

        let snapshot = catalogSnapshot ?? AstraPackCatalog().load()
        let enabledEntries = snapshot.entries.filter { enabledPackIDs.contains($0.manifest.id) }
        let resolvedPackIDs = Set(enabledEntries.map { $0.manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let unresolvedPackIDs = enabledPackIDs.subtracting(resolvedPackIDs)
        guard unresolvedPackIDs.isEmpty else {
            return .unresolvedEnabledPacks(unresolvedPackIDs)
        }

        return AstraPackPolicyResolver.resolve(
            composition: AstraPackComposition.resolve(entries: enabledEntries)
        )
    }
}
