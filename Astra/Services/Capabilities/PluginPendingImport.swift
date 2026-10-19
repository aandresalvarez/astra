import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// A chosen workspace file's activation that this Mac couldn't accept on
/// import (R5, T5): its plugin wasn't installed, or another copy or source of
/// it was. The import keeps its non-secret payload on the workspace
/// (`RetiredPluginActivation.pendingImport`); nothing of it runs or is
/// projected until an installed copy has the same digest and the same
/// source, when Add or a launch pass restores it here, once.
enum PluginPendingImport {
    /// Whether `package`, as installed here, is the copy `pending` was
    /// recorded against: its content or approval digest, and its source
    /// (`PluginSourceStore.mirrorIdentity`; nil and "local" are both local).
    static func matches(
        _ pending: RetiredPluginActivation.PendingImport,
        installed package: PluginPackage,
        provenance: [String: PluginSourceStore.Provenance]
    ) -> Bool {
        let approval = (try? CapabilityApprovalDigest.digest(for: package)) ?? ""
        guard pending.digest == PluginDefinitionDigest.content(of: package) || (!approval.isEmpty && pending.digest == approval) else {
            return false
        }
        func identity(_ value: String?) -> String? { value == "local" || value?.isEmpty == true ? nil : value }
        let here = PluginSourceStore.mirrorIdentity(
            pluginID: package.id, digest: PluginSourceCatalog.contentDigest(package), provenance: provenance
        )
        return identity(pending.source) == identity(here)
    }

    /// Restores the pending import for `activation`'s plugin when `package`
    /// matches it, then forgets it; a pending import for another copy or
    /// source stays as it is. Settings, known components, overrides and
    /// accounts come back only for components `package` declares, and an
    /// account only onto a row the import created for that component's
    /// service. No secret was kept, so none is restored. True when restored.
    @discardableResult
    static func restore(
        on activation: PluginActivation,
        package: PluginPackage,
        in workspace: Workspace,
        provenance: [String: PluginSourceStore.Provenance]
    ) -> Bool {
        guard let pending = WorkspaceCapabilityActivation.pendingImport(pluginID: package.id, in: workspace),
              matches(pending, installed: package, provenance: provenance) else { return false }
        let declared = Set(PluginRuntimeProjection.componentIDs(of: package))
        for (key, value) in (pending.settings ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let componentID = PluginActivation.componentID(ofSettingKey: key), declared.contains(componentID) else { continue }
            WorkspaceCapabilityActivation.setConfigValue(value, forKey: key, on: activation)
        }
        let known = (pending.knownComponentIDs ?? []).filter(declared.contains)
        if !known.isEmpty {
            WorkspaceCapabilityActivation.setKnownComponents(activation.knownComponentIDs + known, on: activation)
        }
        let rows = pending.overridingRowIDs ?? []
        for (index, componentID) in (pending.overriddenComponentIDs ?? []).enumerated()
        where declared.contains(componentID) && !activation.overriddenComponentIDs.contains(componentID) {
            guard index < rows.count, let rowID = UUID(uuidString: rows[index]) else { continue }
            WorkspaceCapabilityActivation.setOverridden(true, componentID: componentID, rowID: rowID, on: activation)
        }
        WorkspaceCapabilityActivation.takeOverridesOffSharedLists(in: workspace)
        let verifier = WorkspaceConfigManager.CapabilityImportVerifier(
            approvedPackageIDs: [], installedPackageIDs: [], availablePackIDs: [],
            connectorComponents: WorkspaceConfigManager.CapabilityImportVerifier.connectorComponents(of: [package])
        )
        for account in pending.accounts ?? [] where declared.contains(account.componentID) {
            guard let id = UUID(uuidString: account.connectorID), let connector = connector(id, near: workspace),
                  verifier.acceptsAccount(
                      connector, componentID: account.componentID, pluginID: package.id,
                      createdByImport: account.createdByImport ?? false
                  ) else { continue }
            WorkspaceCapabilityActivation.bind(
                connector, toComponent: account.componentID, of: activation, isDefault: account.isDefault,
                createdAt: account.boundAt.map(Date.init(timeIntervalSinceReferenceDate:))
            )
        }
        WorkspaceCapabilityActivation.dropPendingImport(pluginID: package.id, in: workspace)
        AppLogger.audit(.capabilityInstalled, category: "Capabilities", fields: [
            "operation": "pending_import_restored", "package_id": package.id, "workspace_id": workspace.id.uuidString
        ])
        return true
    }

    private static func connector(_ id: UUID, near workspace: Workspace) -> Connector? {
        if let own = workspace.connectors.first(where: { $0.id == id && !$0.isDeleted }) { return own }
        guard let context = workspace.modelContext else { return nil }
        var descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
