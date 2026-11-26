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
    private var held = HeldCredentials()

    func holdsSkill(_ id: UUID, key: String? = nil) -> Bool {
        guard let key else { return held.skills.contains(id) }
        return held.unknownKeys.contains(id) || held.keys[id, default: []].contains(key)
    }

    func holdsAccount(_ cleanup: ConnectorKeychainCleanup) -> Bool {
        guard let owned = KeychainSecretStore.ownedConnectorEntityIDs(for: cleanup.secretFacts) else { return true }
        return held.unknownAccountOwnership || held.accounts.contains(cleanup.connectorID)
            || !held.accountNamespaces.isDisjoint(with: owned)
    }

    /// `isCurrent` stands in for `TaskPermissionContinuation.isCurrent` in
    /// tests.
    static func capture(
        modelContext: ModelContext,
        taskReadBatch: Int = TaskTurnRequestOwnership.candidateLookupBatch,
        isCurrent: @escaping PermissionContexts.IsCurrent = {
            try TaskPermissionContinuation.isCurrent($0, task: $1, modelContext: $2)
        }
    ) -> Self? {
        // Unsaved changes, including a terminal transition that might roll
        // back, cannot authorize deleting credentials.
        let saved = ModelContext(modelContext.container)
        let descriptor = FetchDescriptor<TaskTurnRequest>(predicate: #Predicate {
            $0.stateRawValue != "completed" && $0.stateRawValue != "cancelled"
        })
        guard let requests = try? saved.fetch(descriptor) else { return nil }
        // Failed requests are never removed, and each can still hold its
        // context through its task. Their tasks are read once, up front.
        guard let tasks = try? tasksOfFailedRequests(requests, in: saved, batch: taskReadBatch) else { return nil }
        var permissions = PermissionContexts(context: saved, isCurrent: isCurrent)
        var result = Self()
        for request in requests {
            guard let state = TaskTurnRequestState(rawValue: request.stateRawValue) else { return nil }
            if state.isTerminal {
                guard let held = try? permissions.retainsContext(request, task: tasks[request.taskID]) else { return nil }
                if !held { continue }
            }
            // Requests before policy snapshots use live rows, already covered
            // by normal ownership. A present but unreadable policy is unsafe.
            guard let json = request.executionPolicySnapshotJSON else { continue }
            guard result.includePolicyJSON(json, in: saved) else { return nil }
        }
        return result
    }

    /// How many times this process has read a task's runs and open
    /// permission requests for a capture: once per paused task, however
    /// many of its failed requests ask about it. Tests pin that by this count.
    private(set) static var permissionTaskReadCount = 0

    /// Whether a failed provider run still owns an accepted context:
    /// approving its blocked permission creates a new request from this
    /// exact snapshot. It reads the saved approval and current-turn policy,
    /// not transient UI state.
    ///
    /// A paused task can hold dozens of failed requests, and each asks the
    /// same of it: its runs, its open requests and their continuations, and
    /// whether each continuation is still current. Those are read once per
    /// task and kept for the capture, which changes nothing. Each request
    /// still asks what it asked before, in the same order and only as far:
    /// a continuation no request reaches is never asked about, and one that
    /// throws fails the request that reached it, as before.
    @MainActor
    struct PermissionContexts {
        typealias IsCurrent = @MainActor (PermissionApprovalContinuation, AgentTask, ModelContext) throws -> Bool

        /// What one task's requests ask of it, each answer read when a
        /// request first asks for it.
        private struct Reads {
            let runs: [UUID: TaskRun]
            var payloads: [String]?
            var bindings: [Int: PermissionApprovalContinuation?] = [:]
            var current: [Int: Result<Bool, any Error>] = [:]
        }

        let context: ModelContext
        let isCurrent: IsCurrent
        private var tasks: [UUID: Reads] = [:]

        init(context: ModelContext, isCurrent: @escaping IsCurrent) {
            self.context = context
            self.isCurrent = isCurrent
        }

        mutating func retainsContext(_ request: TaskTurnRequest, task: AgentTask?) throws -> Bool {
            guard request.state == .failed, let runID = request.runID else { return false }
            guard let task, task.status == .pendingUser else { return false }
            // The first run with an ID stands for it, as `first(where:)` did.
            var reads = tasks.removeValue(forKey: task.id) ?? Reads(runs: Dictionary(
                task.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
            defer { tasks[task.id] = reads }
            guard let run = reads.runs[runID], run.typedStopReason == .permissionApprovalRequired else { return false }
            let payloads = reads.payloads ?? {
                PendingTaskCredentialReferences.permissionTaskReadCount += 1
                return TaskRuntimePermissionOpenRequestStore.openRequestPayloads(for: task)
            }()
            reads.payloads = payloads
            for (index, payload) in payloads.enumerated() {
                let binding = reads.bindings[index]
                    ?? TaskPermissionContinuation.binding(payload: payload, task: task, modelContext: context)
                reads.bindings[index] = .some(binding)
                guard let binding, binding.runID == runID else { continue }
                let current = reads.current[index] ?? Result { try isCurrent(binding, task, context) }
                reads.current[index] = current
                if try current.get() { return true }
            }
            return false
        }
    }

    /// The tasks `retainsContext` asks about, by ID: those of the failed
    /// requests that ran, in one lookup for all of them
    /// (`TaskTurnRequestOwnership.candidates(taskIDs:)`). A task ID has no
    /// index, so looking each one up walks the task table once per request,
    /// and this runs on the main actor at every launch, once per pending
    /// cleanup. The first row found for an ID stands for it, as a lookup of
    /// that one ID returned.
    private static func tasksOfFailedRequests(_ requests: [TaskTurnRequest], in context: ModelContext, batch: Int) throws -> [UUID: AgentTask] {
        let failed = TaskTurnRequestState.failed.rawValue
        let ids = requests.lazy.filter { $0.stateRawValue == failed && $0.runID != nil }.map(\.taskID)
        guard !ids.isEmpty else { return [:] }
        let found = try TaskTurnRequestOwnership.candidates(taskIDs: Array(ids), in: context, batch: batch)
        return Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
                held.skills.insert(id)
                if definition == nil { held.unknownKeys.insert(id) }
                for setting in activation.secretSettingKeys where PluginActivation.componentID(ofSettingKey: setting) == component {
                    held.keys[id, default: []].insert(String(setting.dropFirst(component.count + 1)))
                }
                for spec in specs where CapabilityResourceOrigin.componentID(for: spec) == component {
                    held.keys[id, default: []].formUnion(spec.environmentKeys.filter(Skill.isSecretEnvironmentKey))
                }
            }
            for binding in activation.bindings {
                guard let id = binding.accountID else { continue }
                if let frozen = policy.pluginAccounts {
                    if !frozen.contains(where: { $0.id == id }) {
                        // An older partial snapshot has only a logical ID;
                        // its missing credential generation remains unknown.
                        held.accounts.insert(id)
                        held.accountNamespaces.insert(KeychainSecretStore.connectorEntityID(for: id))
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
            held.includeSkill(skill.credentialNamespaceID ?? skill.id, keys: skill.environmentKeys)
            for account in skill.attachedConnectors ?? [] { include(account) }
        }
        guard let data = policy.skillSnapshotsJSON.data(using: .utf8),
              let snapshots = try? JSONDecoder().decode([SkillSnapshotConfig].self, from: data) else { return false }
        return includeSkillSnapshots(snapshots)
    }

    mutating func includeSkillSnapshots(_ snapshots: [SkillSnapshotConfig]) -> Bool {
        held.includeSkillSnapshots(snapshots)
    }

    /// Adds what `includeSkillSnapshots` would have for snapshots already
    /// walked, as a recovery mirror's tasks are, off the main actor.
    mutating func include(_ walked: HeldCredentials) {
        held.formUnion(walked)
    }

    private mutating func include(_ account: PluginAccountRecord) {
        let facts = ConnectorSecretFacts(id: account.id, name: account.name, serviceType: account.serviceType,
            baseURL: account.baseURL, originPackageID: account.originPackageID, originComponentID: account.originComponentID,
            credentialNamespaceID: account.credentialNamespaceID,
            outlookCredentialFormat: account.outlookCredentialFormat ?? OutlookCredentialIdentity.format(keys: account.configKeys, values: account.configValues))
        guard let owned = KeychainSecretStore.ownedConnectorEntityIDs(for: facts) else { held.unknownAccountOwnership = true; return }
        held.accountNamespaces.formUnion(owned)
    }
}

/// The credentials `PendingTaskCredentialReferences` holds, as plain values:
/// skill namespaces and their keys, and accounts with their namespaces. Free
/// of the main actor, so the skill snapshots a recovery mirror's tasks carry
/// can be walked off it, with the mirror's decode (`CredentialMirrorDecodes`).
/// What it gathers only grows, so walks merged in any order hold the same.
struct HeldCredentials: Sendable {
    fileprivate(set) var skills: Set<UUID> = []
    fileprivate(set) var keys: [UUID: Set<String>] = [:]
    fileprivate(set) var unknownKeys: Set<UUID> = []
    fileprivate(set) var accounts: Set<UUID> = []
    fileprivate(set) var accountNamespaces: Set<String> = []
    fileprivate(set) var unknownAccountOwnership = false

    /// False when a snapshot names an ID that isn't one, which holds
    /// cleanup closed.
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

    fileprivate mutating func includeSkill(_ id: UUID, keys declared: [String]) {
        skills.insert(id)
        keys[id, default: []].formUnion(declared.filter(Skill.isSecretEnvironmentKey))
    }

    fileprivate mutating func formUnion(_ other: Self) {
        skills.formUnion(other.skills)
        keys.merge(other.keys) { $0.union($1) }
        unknownKeys.formUnion(other.unknownKeys)
        accounts.formUnion(other.accounts)
        accountNamespaces.formUnion(other.accountNamespaces)
        unknownAccountOwnership = unknownAccountOwnership || other.unknownAccountOwnership
    }
}
