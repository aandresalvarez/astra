import Foundation
import ASTRACore
import ASTRAPersistence

extension WorkspaceConfigManager.CapabilityImportVerifier {
    /// This machine's capability state, read once for one config import:
    /// packages installed and effectively approved (the digest-bound check the
    /// share import and runtime exposure use), every installed package, and
    /// the packs the catalog resolves.
    static func live(
        library: CapabilityLibrary = CapabilityLibrary(),
        approvalRecords: [CapabilityApprovalRecord] = CapabilityApprovalStore().records(),
        packCatalog: AstraPackCatalog = AstraPackCatalog()
    ) -> Self {
        let installed = library.installedPackages()
        return Self(
            approvedPackageIDs: Set(installed
                .filter { WorkspacePackageCapabilityApproval.isEffectivelyApproved($0, records: approvalRecords) }
                .map(\.id)),
            installedPackageIDs: Set(installed.map(\.id)),
            availablePackIDs: Set(packCatalog.load().entries.map { $0.manifest.id })
        )
    }
}
