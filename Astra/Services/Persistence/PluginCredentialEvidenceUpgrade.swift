import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Admits the prior own mirror once before replacing it from an existing store.
/// The durable activation owner retains only value-free evidence. Future
/// exports use that owner and do not rescan mirrors or backup directories.
enum PluginCredentialEvidenceUpgrade {
    enum AdmissionError: Error { case pendingChanges, workspaceIdentityMismatch, readOnlyContext }

    static func isOwnMirror(_ url: URL, workspace: Workspace) -> Bool {
        [WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath),
         WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspace.primaryPath)]
            .contains { URL(fileURLWithPath: $0).standardizedFileURL == url.standardizedFileURL }
    }

    static func admit(workspace: Workspace, context: ModelContext,
        prior: WorkspaceConfigManager.WorkspaceConfig? = nil,
        load: (URL) throws -> WorkspaceConfigManager.WorkspaceConfig? = loadPrior,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let activations = WorkspaceCapabilityActivation.activations(of: workspace).filter {
            WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: $0)?.hasAdmittedMirror(for: $0) != true
        }
        guard !activations.isEmpty else { return }
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath))
        let config = try prior ?? load(url)
        // A pre-reset read-only store may have no mirror yet. There is no
        // prior proof to destroy, and the raw durable projection is safe to
        // export without trying to save bookkeeping into that source store.
        if !context.container.configurations.contains(where: { $0.allowsSave }) {
            if config != nil { throw AdmissionError.readOnlyContext }
            return
        }
        // A first export has no prior proof to destroy. Its caller still owns
        // unsaved edits; do not commit them as an admission side effect.
        if context.hasChanges {
            if config != nil { throw AdmissionError.pendingChanges }
            return
        }
        if let id = config?.id, id != workspace.id.uuidString { throw AdmissionError.workspaceIdentityMismatch }
        let snapshot = WorkspaceCapabilityActivation.snapshot(workspace)
        for activation in activations {
            let refs = (config?.installedPlugins ?? []).filter { ref in
                let recordedID = ref.activationID.flatMap(UUID.init(uuidString:))
                return ref.id == activation.pluginID
                    && (recordedID == nil || recordedID == activation.id)
                    && (ref.credentialNamespaceSeed ?? "") == activation.credentialNamespaceSeed
                    && (!activation.credentialNamespaceSeed.isEmpty || (ref.namespaceSeed ?? "") == activation.namespaceSeed)
            }
            // Removed or replaced generations do not inherit old proof. All
            // matching records contribute; a duplicate cannot hide ambiguity.
            var evidence = PluginCredentialRecoveryEvidence(namespaceSeed: activation.namespaceSeed,
                credentialNamespaceSeed: activation.credentialNamespaceSeed, admittedActivationID: activation.id.uuidString)
            let keys = Set(activation.configKeys + activation.secretSettingKeys)
            let components = Set(activation.knownComponentIDs + activation.overriddenComponentIDs
                + keys.compactMap(PluginActivation.componentID(ofSettingKey:))
                + activation.bindings.filter { !$0.isDeleted }.map(\.componentID))
            for ref in refs {
                evidence = evidence.merging(WorkspaceConfigManager.credentialEvidence(from: ref, activation: activation,
                    representedComponents: components, representedKeys: keys,
                    connectorIDs: Set(activation.bindings.filter { !$0.isDeleted }.compactMap { $0.account?.id.uuidString }),
                    admittingPriorMirror: true))
            }
            WorkspaceCapabilityActivation.preserveCredentialRecoveryEvidence(evidence, on: activation)
        }
        do {
            try WorkspaceSavedExportLease.preservingPriorProjection(for: workspace.id, context: context) { try save(context) }
        } catch {
            context.rollback()
            WorkspaceCapabilityActivation.restore(snapshot, to: workspace)
            throw error
        }
    }

    private static func loadPrior(_ current: URL) throws -> WorkspaceConfigManager.WorkspaceConfig? {
        let root = WorkspaceFileLayout.workspaceRoot(forConfigFile: current).path
        let candidates = [current, URL(fileURLWithPath: WorkspaceFileLayout.legacyWorkspaceConfigFile(for: root))]
        for url in candidates {
            guard try WorkspaceFileLayout.itemIdentityConfirmingAbsence(at: url.path) != nil else { continue }
            return try WorkspaceConfigManager.loadConfig(from: url,
                accessIntent: .astraManagedStorage(root: URL(fileURLWithPath: root, isDirectory: true)))
        }
        return nil
    }
}
