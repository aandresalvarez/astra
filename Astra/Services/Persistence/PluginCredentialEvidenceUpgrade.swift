import Foundation
import SwiftData
import ASTRACore
import ASTRAModels

/// Admits the prior own mirror once before replacing it from an existing store.
/// The durable activation owner retains only value-free evidence. Future
/// exports use that owner and do not rescan mirrors or backup directories.
enum PluginCredentialEvidenceUpgrade {
    enum AdmissionError: Error { case pendingChanges, workspaceIdentityMismatch, readOnlyContext }

    /// Recovery metadata needs no UI fields, dates or legacy row payloads.
    /// Relevant malformed plugin fields still fail decoding and hold cleanup.
    struct Source: Decodable {
        let id: String?
        let installedPlugins: [WorkspaceConfigManager.InstalledPluginRef]?

        init(_ config: WorkspaceConfigManager.WorkspaceConfig) {
            id = config.id
            installedPlugins = config.installedPlugins
        }
    }

    static func isOwnMirror(_ url: URL, workspace: Workspace) -> Bool {
        [WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath),
         WorkspaceFileLayout.legacyWorkspaceConfigFile(for: workspace.primaryPath)]
            .contains { URL(fileURLWithPath: $0).standardizedFileURL == url.standardizedFileURL }
    }

    static func requiresAdmission(workspace: Workspace) -> Bool {
        WorkspaceCapabilityActivation.activations(of: workspace).contains(where: requiresAdmission)
    }

    private static func requiresAdmission(_ activation: PluginActivation) -> Bool {
        WorkspaceCapabilityActivation.credentialRecoveryEvidence(of: activation)?.hasAdmittedMirror(for: activation) != true
    }

    static func admit(workspace: Workspace, context: ModelContext,
        load: (URL) throws -> Source? = loadPrior,
        save: (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let activations = WorkspaceCapabilityActivation.activations(of: workspace).filter(requiresAdmission)
        guard !activations.isEmpty else { return }
        let url = URL(fileURLWithPath: WorkspaceFileLayout.workspaceConfigFile(for: workspace.primaryPath))
        // Discovery runs asynchronously. Its decoded value may no longer
        // describe this path when admission starts. Read the current own file
        // once here; the durable completion marker skips future admissions.
        let config = try load(url)
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
        if let id = config?.id, UUID(uuidString: id) != workspace.id { throw AdmissionError.workspaceIdentityMismatch }
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

    static func refresh(_ records: [RetiredPluginActivation], workspace: Workspace, context: ModelContext) throws {
        let before = WorkspaceCapabilityActivation.snapshot(workspace)
        guard before.retired != records else { return }
        guard !context.hasChanges else { throw AdmissionError.pendingChanges }
        guard context.container.configurations.contains(where: { $0.allowsSave }) else { throw AdmissionError.readOnlyContext }
        WorkspaceCapabilityActivation.preserveCredentialRecoveryEvidence(from: records, in: workspace)
        guard WorkspaceCapabilityActivation.snapshot(workspace).retired != before.retired else { return }
        do {
            try WorkspaceSavedExportLease.preservingPriorProjection(for: workspace.id, context: context) { try context.save() }
        } catch {
            context.rollback()
            WorkspaceCapabilityActivation.restore(before, to: workspace)
            throw error
        }
    }

    private static func loadPrior(_ current: URL) throws -> Source? {
        let root = WorkspaceFileLayout.workspaceRoot(forConfigFile: current).path
        let candidates = [current, URL(fileURLWithPath: WorkspaceFileLayout.legacyWorkspaceConfigFile(for: root))]
        for url in candidates {
            guard try WorkspaceFileLayout.itemIdentityConfirmingAbsence(at: url.path) != nil else { continue }
            let data = try HostFileAccessBroker().readData(at: url,
                intent: .astraManagedStorage(root: URL(fileURLWithPath: root, isDirectory: true)))
            return try JSONDecoder().decode(Source.self, from: data)
        }
        return nil
    }
}
