import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Credentials a durable, nonterminal request can still read. This is a
/// derived view of saved requests, never another owner of credential values.
/// Temporary ownership keeps cleanup intents pending, so they can be retried
/// after the request finishes. An unreadable request holds cleanup closed.
@MainActor
struct PendingTaskCredentialReferences {
    private var skills: Set<UUID> = []
    private var keys: [UUID: Set<String>] = [:]
    private var unknownKeys: Set<UUID> = []
    private var accounts: Set<UUID> = []
    private var accountNamespaces: Set<String> = []
    private var unknownAccountOwnership = false

    func holdsSkill(_ id: UUID, key: String? = nil) -> Bool {
        guard let key else { return skills.contains(id) }
        return unknownKeys.contains(id) || keys[id, default: []].contains(key)
    }

    func holdsAccount(_ cleanup: ConnectorKeychainCleanup) -> Bool {
        guard let owned = KeychainSecretStore.ownedConnectorEntityIDs(for: cleanup.secretFacts) else { return true }
        return unknownAccountOwnership || accounts.contains(cleanup.connectorID)
            || !accountNamespaces.isDisjoint(with: owned)
    }

    static func capture(modelContext: ModelContext) -> Self? {
        // Unsaved changes, including a terminal transition that might roll
        // back, cannot authorize deleting credentials.
        let saved = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<TaskTurnRequest>(predicate: #Predicate {
            $0.stateRawValue != "completed" && $0.stateRawValue != "cancelled"
        })
        guard let requests = try? saved.fetch(descriptor) else { return nil }
        var result = Self()
        for request in requests {
            guard let state = TaskTurnRequestState(rawValue: request.stateRawValue) else { return nil }
            if state.isTerminal {
                guard let held = try? retainsPermissionContext(request, in: saved) else { return nil }
                if !held { continue }
            }
            // Requests before policy snapshots use live rows, already covered
            // by normal ownership. A present but unreadable policy is unsafe.
            guard let json = request.executionPolicySnapshotJSON else { continue }
            guard result.includePolicyJSON(json, in: saved) else { return nil }
        }
        return result
    }

    /// A failed provider run may still own an accepted context: approving its
    /// blocked permission creates a new request from this exact snapshot.
    /// Read the saved approval and current-turn policy, not transient UI state.
    private static func retainsPermissionContext(_ request: TaskTurnRequest, in context: ModelContext) throws -> Bool {
        guard request.state == .failed, let runID = request.runID else { return false }
        let taskID = request.taskID
        var descriptor = FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID })
        descriptor.fetchLimit = 1
        guard let task = try context.fetch(descriptor).first, task.status == .pendingUser,
              let run = task.runs.first(where: { $0.id == runID }), run.typedStopReason == .permissionApprovalRequired
        else { return false }
        for payload in TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: task) {
            guard let binding = TaskPermissionContinuation.binding(payload: payload, task: task, modelContext: context),
                  binding.runID == runID else { continue }
            if try TaskPermissionContinuation.isCurrent(binding, task: task, modelContext: context) { return true }
        }
        return false
    }

    mutating func includePolicyJSON(_ json: String, in context: ModelContext) -> Bool {
        guard let data = json.data(using: .utf8),
              let policy = try? JSONDecoder().decode(TaskExecutionPolicySnapshotV1.self, from: data),
              policy.version == 1 else { return false }
        return include(policy, in: context)
    }

    private mutating func include(_ policy: TaskExecutionPolicySnapshotV1, in context: ModelContext) -> Bool {
        let definitions = Dictionary((policy.pluginDefinitions ?? []).map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        for activation in policy.pluginActivations ?? [] where activation.isEnabled {
            // Old snapshots did not preserve the namespace's workspace.
            // The task may have moved since submission, so its live owner
            // cannot prove that identity. Keep all cleanup pending instead.
            guard let workspaceID = activation.workspaceID else { return false }
            let definition = definitions[activation.pluginID]
            let specs = definition?.skills ?? []
            var components = Set(activation.knownComponentIDs + activation.overriddenComponentIDs)
            components.formUnion((activation.configKeys + activation.secretSettingKeys)
                .compactMap(PluginActivation.componentID(ofSettingKey:)))
            components.formUnion(specs.map { CapabilityResourceOrigin.componentID(for: $0) })
            for component in components {
                let id = PluginActivation.credentialID(workspaceID: workspaceID, pluginID: activation.pluginID,
                                                       componentID: component, runtimeSeed: activation.namespaceSeed, generation: activation.credentialNamespaceSeed)
                skills.insert(id)
                if definition == nil { unknownKeys.insert(id) }
                for setting in activation.secretSettingKeys where PluginActivation.componentID(ofSettingKey: setting) == component {
                    keys[id, default: []].insert(String(setting.dropFirst(component.count + 1)))
                }
                for spec in specs where CapabilityResourceOrigin.componentID(for: spec) == component {
                    keys[id, default: []].formUnion(spec.environmentKeys.filter(Skill.isSecretEnvironmentKey))
                }
            }
            for binding in activation.bindings {
                guard let id = binding.accountID else { continue }
                if let frozen = policy.pluginAccounts {
                    if !frozen.contains(where: { $0.id == id }) {
                        // An older partial snapshot has only a logical ID;
                        // its missing credential generation remains unknown.
                        accounts.insert(id)
                        accountNamespaces.insert(KeychainSecretStore.connectorEntityID(for: id))
                    }
                } else {
                    var descriptor = FetchDescriptor<Connector>(predicate: #Predicate { $0.id == id })
                    descriptor.fetchLimit = 1
                    guard let account = try? context.fetch(descriptor).first else { return false }
                    include(PluginAccountRecord(account))
                }
            }
        }
        for account in policy.pluginAccounts ?? [] { include(account) }
        for entry in policy.accountInventory?.entries ?? [] { include(entry.account) }
        let accountParents = policy.accountInventory?.entries.compactMap(\.parentSkill) ?? []
        for skill in (policy.pluginOverrides?.skills ?? []) + (policy.authoredSkills ?? []) + accountParents {
            includeSkill(skill.credentialNamespaceID ?? skill.id, keys: skill.environmentKeys)
            for account in skill.attachedConnectors ?? [] { include(account) }
        }
        guard let data = policy.skillSnapshotsJSON.data(using: .utf8),
              let snapshots = try? JSONDecoder().decode([SkillSnapshotConfig].self, from: data) else { return false }
        return includeSkillSnapshots(snapshots)
    }

    mutating func includeSkillSnapshots(_ snapshots: [SkillSnapshotConfig]) -> Bool {
        for skill in snapshots {
            if let namespace = skill.credentialNamespaceID {
                includeSkill(namespace, keys: skill.environmentKeys)
            } else if let rawID = skill.id {
                guard let id = UUID(uuidString: rawID) else { return false }
                includeSkill(id, keys: skill.environmentKeys)
            }
            for rawID in skill.connectorIDs ?? [] {
                guard let id = UUID(uuidString: rawID) else { return false }
                if !(skill.connectorSnapshots ?? []).contains(where: { $0.id.flatMap(UUID.init(uuidString:)) == id }) {
                    accounts.insert(id)
                    accountNamespaces.insert(KeychainSecretStore.connectorEntityID(for: id))
                }
            }
            for account in skill.connectorSnapshots ?? [] {
                guard let rawID = account.id, let id = UUID(uuidString: rawID) else { return false }
                let facts = ConnectorSecretFacts(id: id, name: account.name, serviceType: account.serviceType,
                    baseURL: account.baseURL, originPackageID: nil, originComponentID: nil,
                    credentialNamespaceID: account.credentialNamespaceID,
                    outlookCredentialFormat: account.outlookCredentialFormat ?? OutlookCredentialIdentity.format(keys: account.configKeys, values: account.configValues))
                guard let owned = KeychainSecretStore.ownedConnectorEntityIDs(for: facts) else { unknownAccountOwnership = true; continue }
                accountNamespaces.formUnion(owned)
            }
        }
        return true
    }

    private mutating func includeSkill(_ id: UUID, keys declared: [String]) {
        skills.insert(id)
        keys[id, default: []].formUnion(declared.filter(Skill.isSecretEnvironmentKey))
    }

    private mutating func include(_ account: PluginAccountRecord) {
        let facts = ConnectorSecretFacts(id: account.id, name: account.name, serviceType: account.serviceType,
            baseURL: account.baseURL, originPackageID: account.originPackageID, originComponentID: account.originComponentID,
            credentialNamespaceID: account.credentialNamespaceID,
            outlookCredentialFormat: account.outlookCredentialFormat ?? OutlookCredentialIdentity.format(keys: account.configKeys, values: account.configValues))
        guard let owned = KeychainSecretStore.ownedConnectorEntityIDs(for: facts) else { unknownAccountOwnership = true; return }
        accountNamespaces.formUnion(owned)
    }
}
