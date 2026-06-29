import Foundation

enum PackWorkspacePolicyProvider {
    static func resolvedPolicy(
        for workspace: Workspace?,
        catalogSnapshot: AstraPackCatalogSnapshot = AstraPackCatalog().load()
    ) -> PackResolvedPolicy {
        guard let workspace else { return .empty }
        let enabledPackIDs = Set(
            workspace.enabledPackIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !enabledPackIDs.isEmpty else { return .empty }

        let enabledEntries = catalogSnapshot.entries.filter { enabledPackIDs.contains($0.manifest.id) }
        guard !enabledEntries.isEmpty else { return .empty }

        return AstraPackPolicyResolver.resolve(
            composition: AstraPackComposition.resolve(entries: enabledEntries)
        )
    }
}
