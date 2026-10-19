import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

extension WorkspaceConfigManager.CapabilityImportVerifier {
    /// This machine's capability state, read once for one config import:
    /// packages installed and effectively approved (the digest-bound check the
    /// share import and runtime exposure use), every installed package, and
    /// the packs the catalog resolves.
    static func live(
        library: CapabilityLibrary = CapabilityLibrary(),
        approvalRecords: [CapabilityApprovalRecord] = CapabilityApprovalStore().records(),
        packCatalog: AstraPackCatalog = AstraPackCatalog(),
        sourceStore: PluginSourceStore = PluginSourceStore()
    ) -> Self {
        let installed = library.installedPackages()
        let provenance = sourceStore.provenance()
        return Self(
            approvedPackageIDs: Set(installed
                .filter { WorkspacePackageCapabilityApproval.isEffectivelyApproved($0, records: approvalRecords) }
                .map(\.id)),
            installedPackageIDs: Set(installed.map(\.id)),
            availablePackIDs: Set(packCatalog.load().entries.map { $0.manifest.id }),
            declaredComponentIDs: Dictionary(
                installed.map { package in
                    (package.id, Set(
                        package.skills.map(CapabilityResourceOrigin.componentID(for:))
                            + package.connectors.map(CapabilityResourceOrigin.componentID(for:))
                            + package.localTools.map(CapabilityResourceOrigin.componentID(for:))
                    ))
                },
                uniquingKeysWith: { first, _ in first }
            ),
            installedDigests: Dictionary(
                installed.compactMap { package in
                    (try? CapabilityApprovalDigest.digest(for: package)).map { (package.id, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            ),
            installedSources: Dictionary(
                installed.compactMap { package in
                    PluginSourceStore.mirrorIdentity(
                        pluginID: package.id, digest: PluginSourceCatalog.contentDigest(package), provenance: provenance
                    ).map { (package.id, $0) }
                },
                uniquingKeysWith: { first, _ in first }
            ),
            connectorComponents: connectorComponents(of: installed)
        )
    }

    /// Each package's connector components, for binding imported accounts.
    static func connectorComponents(of packages: [PluginPackage]) -> [String: [String: ConnectorComponent]] {
        Dictionary(
            packages.map { package in
                (package.id, Dictionary(
                    package.connectors.map {
                        (CapabilityResourceOrigin.componentID(for: $0), ConnectorComponent(serviceType: $0.serviceType, name: $0.name))
                    },
                    uniquingKeysWith: { first, _ in first }
                ))
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
