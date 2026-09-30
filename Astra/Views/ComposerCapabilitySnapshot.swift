import Foundation
import SwiftData
import SwiftUI
import ASTRACore
import ASTRAModels

struct ComposerCapabilitySnapshot {
    static let empty = ComposerCapabilitySnapshot(availableSkills: [])

    let availableSkills: [Skill]
    /// The workspace these skills were resolved for. `nil` both for "no
    /// workspace" and for the empty placeholder a composer holds while it waits
    /// for a newly selected workspace, which is why submission compares it with
    /// the workspace on screen rather than treating empty as ready.
    var workspaceID: UUID?

    func selectedSkills(excluding excludedSkillIDs: Set<UUID>) -> [Skill] {
        availableSkills.filter { !excludedSkillIDs.contains($0.id) }
    }

    /// Whether the loader may stamp a snapshot with its workspace. The pack
    /// policy and catalog it resolved against are cached per workspace, so until
    /// the catalog refresh for this workspace has completed they belong to the
    /// previous one, and stamping them would let a composer submit with the
    /// wrong capabilities. `nil` (no workspace) is always ready.
    static func stampedWorkspaceID(workspaceID: UUID?, catalogWorkspaceID: UUID?) -> UUID? {
        workspaceID == catalogWorkspaceID ? workspaceID : nil
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
        return ComposerCapabilitySnapshot(availableSkills: capabilities.activeSkills, workspaceID: workspace.id)
    }
}

/// Parent-driven diffing only. The loader sits in `TaskMainView` and
/// `ChatPanelView`, whose bodies re-run on every keystroke, and it takes a
/// closure — so without this SwiftUI re-evaluated it, and the
/// relationship-walking `capabilityRefreshSignature` with it, per keystroke.
/// Its own `@Query` and `@State` changes still invalidate it directly; the
/// call sites opt in with `.equatable()`.
extension ComposerCapabilitySnapshotLoader: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspace?.persistentModelID == rhs.workspace?.persistentModelID
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
    /// The workspace `catalogSnapshot` was last refreshed for.
    @State private var catalogWorkspaceID: UUID?
    @State private var catalogRefreshID = UUID()
    @State private var approvalRefreshID = UUID()

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
            .onReceive(NotificationCenter.default.publisher(for: .capabilityApprovalsChanged)) { _ in
                approvalRefreshID = UUID()
            }
    }

    private var catalogRefreshSignature: String {
        [
            workspace?.id.uuidString ?? "none",
            Self.joinFields(workspace?.enabledPackIDs ?? []),
            approvalRefreshID.uuidString
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
        let refreshWorkspaceID = workspace?.id
        catalogRefreshID = refreshID

        let loadTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil as ComposerCapabilityCatalogSnapshot? }
            let packages = CapabilityLibrary().installedPackages()
            guard !Task.isCancelled else { return nil as ComposerCapabilityCatalogSnapshot? }
            let approvalRecords = CapabilityApprovalStore().records()
            guard !Task.isCancelled else { return nil as ComposerCapabilityCatalogSnapshot? }
            return ComposerCapabilityCatalogSnapshot(
                packages: packages,
                approvalRecords: approvalRecords,
                packPolicy: PackWorkspacePolicyProvider.resolvedPolicy(enabledPackIDs: enabledPackIDs)
            )
        }
        let snapshot = await withTaskCancellationHandler {
            await loadTask.value
        } onCancel: {
            loadTask.cancel()
        }

        guard let snapshot, !Task.isCancelled, catalogRefreshID == refreshID else { return }
        catalogSnapshot = snapshot.withBuiltInsFallback()
        catalogWorkspaceID = refreshWorkspaceID
        emitSnapshot()
    }

    @MainActor
    private func emitSnapshot() {
        var snapshot = ComposerCapabilitySnapshotBuilder.make(
            workspace: workspace,
            globalSkills: globalSkills,
            globalConnectors: globalConnectors,
            globalTools: globalTools,
            packageDefinitions: catalogSnapshot.packages,
            approvalRecords: catalogSnapshot.approvalRecords,
            packPolicy: catalogSnapshot.packPolicy
        )
        snapshot.workspaceID = ComposerCapabilitySnapshot.stampedWorkspaceID(
            workspaceID: snapshot.workspaceID,
            catalogWorkspaceID: catalogWorkspaceID
        )
        onSnapshotChange(snapshot)
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
            joinFields(workspace.skills.map(Self.revisionSignature(for:))),
            joinFields(workspace.connectors.map(Self.revisionSignature(for:))),
            joinFields(workspace.localTools.map(Self.revisionSignature(for:))),
            joinFields(globalSkills.map(Self.revisionSignature(for:))),
            joinFields(globalConnectors.map(Self.revisionSignature(for:))),
            joinFields(globalTools.map(Self.revisionSignature(for:))),
            joinFields(packageDefinitions.map { "\($0.id):\($0.version)" }),
            joinFields(approvalRecords.map { "\($0.packageID):\($0.packageVersion):\($0.status.rawValue)" }),
            String(describing: packPolicy)
        ])
    }

    private static func revisionSignature(for skill: Skill) -> String {
        "\(skill.id.uuidString):\(skill.updatedAt.timeIntervalSince1970)"
    }

    private static func revisionSignature(for connector: Connector) -> String {
        "\(connector.id.uuidString):\(connector.updatedAt.timeIntervalSince1970)"
    }

    private static func revisionSignature(for tool: LocalTool) -> String {
        "\(tool.id.uuidString):\(tool.updatedAt.timeIntervalSince1970)"
    }

    private static func joinFields(_ fields: [String]) -> String {
        fields.sorted().map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}
