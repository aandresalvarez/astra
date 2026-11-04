import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Credential references in every recoverable copy, including request-time
/// generations no longer present in the current activation. Values never
/// enter this derived view. Missing or unreadable evidence holds cleanup closed.
@MainActor
struct PluginCredentialMirrorReferences {
    private var namespaceIDs: Set<UUID> = []
    private var keys: Set<PluginUpdateService.StaleSecret> = []
    private var unknownKeys: Set<UUID> = []
    private var requests = PendingTaskCredentialReferences()

    func holdsSkill(_ id: UUID, key: String? = nil) -> Bool {
        if requests.holdsSkill(id, key: key) { return true }
        guard let key else { return namespaceIDs.contains(id) }
        return unknownKeys.contains(id) || keys.contains(.init(key: key, skillID: id))
    }
    func holdsAccount(_ cleanup: ConnectorKeychainCleanup) -> Bool { requests.holdsAccount(cleanup) }

    static func capture(
        modelContext: ModelContext, extraMirrors: [String]? = nil, excludingWorkspaceIDs: Set<UUID>? = nil
    ) -> Self? {
        guard let files = CredentialRecoveryMirrors.read(modelContext: modelContext, extraMirrors: extraMirrors,
            excludingWorkspaceIDs: excludingWorkspaceIDs) else { return nil }
        let saved = ModelContext(modelContext.container)
        var result = Self()
        for file in files {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let listed = (try? decoder.decode(Listed.self, from: file.data))
                ?? (try? JSONDecoder().decode(Listed.self, from: file.data)) else { return nil }
            var namespaces = Set<UUID>()
            for plugin in listed.installedPlugins ?? [] {
                guard let workspaceID = file.workspaceID else { return nil }
                guard let references = PluginCredentialMetadataPolicy.references(
                    pluginID: plugin.id, version: plugin.version, digest: plugin.digest,
                    knownComponentIDs: plugin.knownComponentIDs, credentialComponentIDs: plugin.credentialComponentIDs,
                    secretSettingKeys: plugin.secretSettingKeys, settingKeys: Array((plugin.settings ?? [:]).keys),
                    overriddenComponentIDs: plugin.overriddenComponentIDs, accountComponentIDs: (plugin.accounts ?? []).map(\.componentID),
                    recoveryEvidence: plugin.credentialRecoveryEvidence) else {
                    ambiguousMetadata(workspaceID: workspaceID, pluginID: plugin.id)
                    return nil
                }
                for component in references.componentIDs {
                    let id = PluginActivation.credentialID(workspaceID: workspaceID, pluginID: plugin.id,
                        componentID: component, runtimeSeed: plugin.namespaceSeed ?? "", generation: plugin.credentialNamespaceSeed ?? "")
                    namespaces.insert(id)
                    if references.unknownSecretComponentIDs.contains(component) { result.unknownKeys.insert(id) }
                    for setting in references.secretSettingKeys where PluginActivation.componentID(ofSettingKey: setting) == component {
                        let key = String(setting.dropFirst(component.count + 1))
                        result.keys.insert(.init(key: key, skillID: id))
                    }
                }
            }
            result.namespaceIDs.formUnion(namespaces)
            for skill in listed.skills ?? [] {
                let id = skill.credentialNamespaceID ?? skill.id.flatMap(UUID.init(uuidString:))
                guard let id else { continue }
                result.namespaceIDs.insert(id)
                if let declared = skill.environmentKeys {
                    for key in declared where Skill.isSecretEnvironmentKey(key) { result.keys.insert(.init(key: key, skillID: id)) }
                } else { result.unknownKeys.insert(id) }
            }
            for task in listed.tasks ?? [] {
                guard result.requests.includeSkillSnapshots(task.skillSnapshots ?? []) else { return nil }
                let requests = task.turnRequests ?? []
                let latestSequence = requests.map(\.sequence).max()
                let status = task.status.flatMap(TaskStatus.init(rawValue:))
                // Before importing a recoverable copy there is no saved
                // request to query. Its latest failed turn can still own a
                // permission continuation while the task awaits the person.
                // Older/unknown task status is unproved, so retain it too.
                let mayResume = task.isDone != true && (status == nil || status == .pendingUser)
                for request in requests {
                    let permissionCandidate = mayResume && request.state == .failed && request.sequence == latestSequence
                    guard !request.state.isTerminal || permissionCandidate else { continue }
                    if let json = request.executionPolicySnapshotJSON,
                       !result.requests.includePolicyJSON(json, in: saved) { return nil }
                }
            }
        }
        return result
    }

    private static func ambiguousMetadata(workspaceID: UUID, pluginID: String) {
        AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
            "scope": "plugin_credential_mirror", "reason": "ambiguous_plugin_credential_metadata",
            "workspace_id": workspaceID.uuidString, "plugin_id": pluginID
        ], level: .warning)
    }

    private struct Listed: Decodable {
        struct Plugin: Decodable {
            struct Account: Decodable { let componentID: String }
            let id: String
            let version: String?
            let digest: String?
            let settings: [String: String]?
            let accounts: [Account]?
            let overriddenComponentIDs: [String]?
            let knownComponentIDs: [String]?
            let credentialComponentIDs: [String]?
            let secretSettingKeys: [String]?
            let credentialRecoveryEvidence: PluginCredentialRecoveryEvidence?
            let namespaceSeed: String?
            let credentialNamespaceSeed: String?
        }
        struct Skill: Decodable {
            let id: String?
            let credentialNamespaceID: UUID?
            let environmentKeys: [String]?
        }
        struct Task: Decodable {
            let status: String?
            let isDone: Bool?
            let skillSnapshots: [SkillSnapshotConfig]?
            let turnRequests: [TaskTurnRequestSnapshot]?
        }
        let installedPlugins: [Plugin]?
        let skills: [Skill]?
        let tasks: [Task]?
    }
}
