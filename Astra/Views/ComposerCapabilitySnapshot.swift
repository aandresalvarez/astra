import Foundation
import SwiftData
import SwiftUI
import ASTRACore

struct ComposerCapabilitySnapshot {
    static let empty = ComposerCapabilitySnapshot(availableSkills: [])

    let availableSkills: [Skill]

    func selectedSkills(excluding excludedSkillIDs: Set<UUID>) -> [Skill] {
        availableSkills.filter { !excludedSkillIDs.contains($0.id) }
    }
}

enum ComposerCapabilitySnapshotBuilder {
    @MainActor
    static func make(
        workspace: Workspace?,
        globalSkills: [Skill],
        globalConnectors: [Connector],
        globalTools: [LocalTool],
        packageDefinitions: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord] = [],
        packPolicy: PackResolvedPolicy
    ) -> ComposerCapabilitySnapshot {
        guard let workspace else { return .empty }
        let capabilities = WorkspaceCapabilities(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools,
            packageDefinitions: packageDefinitions,
            approvalRecords: approvalRecords,
            packPolicy: packPolicy
        )
        return ComposerCapabilitySnapshot(availableSkills: capabilities.activeSkills)
    }
}

struct ComposerCapabilitySnapshotLoader: View {
    let workspace: Workspace?
    let onSnapshotChange: @MainActor (ComposerCapabilitySnapshot) -> Void

    @Query(filter: #Predicate<Skill> { $0.isGlobal == true })
    private var globalSkills: [Skill]
    @Query(filter: #Predicate<Connector> { $0.isGlobal == true })
    private var globalConnectors: [Connector]
    @Query(filter: #Predicate<LocalTool> { $0.isGlobal == true })
    private var globalTools: [LocalTool]

    @State private var catalogSnapshot = ComposerCapabilityCatalogSnapshot.empty
    @State private var catalogRefreshID = UUID()

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: catalogRefreshSignature) {
                await refreshCatalogSnapshot()
            }
            .task(id: capabilityRefreshSignature) {
                emitSnapshot()
            }
    }

    private var catalogRefreshSignature: String {
        [
            workspace?.id.uuidString ?? "none",
            Self.joinFields(workspace?.enabledPackIDs ?? [])
        ].joined(separator: "|")
    }

    private var capabilityRefreshSignature: String {
        ComposerCapabilitySnapshotSignature.make(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools,
            packageDefinitions: catalogSnapshot.packages,
            approvalRecords: catalogSnapshot.approvalRecords,
            packPolicy: catalogSnapshot.packPolicy
        )
    }

    @MainActor
    private func refreshCatalogSnapshot() async {
        let refreshID = UUID()
        let enabledPackIDs = workspace?.enabledPackIDs ?? []
        catalogRefreshID = refreshID

        let snapshot = await Task.detached(priority: .userInitiated) {
            ComposerCapabilityCatalogSnapshot(
                packages: CapabilityLibrary().installedPackages(),
                approvalRecords: CapabilityApprovalStore().records(),
                packPolicy: PackWorkspacePolicyProvider.resolvedPolicy(enabledPackIDs: enabledPackIDs)
            )
        }.value

        guard !Task.isCancelled, catalogRefreshID == refreshID else { return }
        catalogSnapshot = snapshot.withBuiltInsFallback()
        emitSnapshot()
    }

    @MainActor
    private func emitSnapshot() {
        onSnapshotChange(ComposerCapabilitySnapshotBuilder.make(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools,
            packageDefinitions: catalogSnapshot.packages,
            approvalRecords: catalogSnapshot.approvalRecords,
            packPolicy: catalogSnapshot.packPolicy
        ))
    }

    private static func joinFields(_ fields: [String]) -> String {
        fields.sorted().map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

private struct ComposerCapabilityCatalogSnapshot: Sendable {
    static let empty = ComposerCapabilityCatalogSnapshot(
        packages: PluginCatalog.builtInPackages,
        approvalRecords: [],
        packPolicy: .empty
    )

    var packages: [PluginPackage]
    var approvalRecords: [CapabilityApprovalRecord]
    var packPolicy: PackResolvedPolicy

    func withBuiltInsFallback() -> ComposerCapabilityCatalogSnapshot {
        ComposerCapabilityCatalogSnapshot(
            packages: packages.isEmpty ? PluginCatalog.builtInPackages : packages,
            approvalRecords: approvalRecords,
            packPolicy: packPolicy
        )
    }
}

private enum ComposerCapabilitySnapshotSignature {
    static func make(
        workspace: Workspace?,
        globalSkills: [Skill],
        globalConnectors: [Connector],
        globalTools: [LocalTool],
        packageDefinitions: [PluginPackage],
        approvalRecords: [CapabilityApprovalRecord],
        packPolicy: PackResolvedPolicy
    ) -> String {
        guard let workspace else { return "none" }
        return joinFields([
            workspace.id.uuidString,
            String(workspace.updatedAt.timeIntervalSince1970),
            joinFields(workspace.enabledGlobalSkillIDs),
            joinFields(workspace.enabledGlobalConnectorIDs),
            joinFields(workspace.enabledGlobalToolIDs),
            joinFields(workspace.enabledCapabilityIDs),
            joinFields(workspace.enabledPackIDs),
            joinFields(workspace.skills.map { "\($0.id.uuidString):\($0.name)" }),
            joinFields(workspace.connectors.map { "\($0.id.uuidString):\($0.name)" }),
            joinFields(workspace.localTools.map { "\($0.id.uuidString):\($0.name)" }),
            joinFields(globalSkills.map { "\($0.id.uuidString):\($0.name)" }),
            joinFields(globalConnectors.map { "\($0.id.uuidString):\($0.name)" }),
            joinFields(globalTools.map { "\($0.id.uuidString):\($0.name)" }),
            joinFields(packageDefinitions.map { "\($0.id):\($0.version)" }),
            joinFields(approvalRecords.map { "\($0.packageID):\($0.packageVersion):\($0.status.rawValue)" }),
            String(describing: packPolicy)
        ])
    }

    private static func joinFields(_ fields: [String]) -> String {
        fields.sorted().map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
