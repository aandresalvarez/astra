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
                let recorded = plugin.secretSettingKeys ?? []
                let plain = Array((plugin.settings ?? [:]).keys)
                let components = Set((plugin.knownComponentIDs ?? []) + (plugin.overriddenComponentIDs ?? [])
                    + (recorded + plain).compactMap(PluginActivation.componentID(ofSettingKey:)))
                guard !components.isEmpty else { return nil }
                for component in components {
                    let id = PluginActivation.credentialID(workspaceID: workspaceID, pluginID: plugin.id,
                        componentID: component, runtimeSeed: plugin.namespaceSeed ?? "", generation: plugin.credentialNamespaceSeed ?? "")
                    namespaces.insert(id)
                    // Current exports omit an empty marker array. A known
                    // component contract plus no markers means no secrets;
                    // older partial records without that contract are unknown.
                    if plugin.secretSettingKeys == nil && plugin.knownComponentIDs == nil { result.unknownKeys.insert(id) }
                    for setting in recorded + plain where PluginActivation.componentID(ofSettingKey: setting) == component {
                        let key = String(setting.dropFirst(component.count + 1))
                        if recorded.contains(setting) || Skill.isSecretEnvironmentKey(key) { result.keys.insert(.init(key: key, skillID: id)) }
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
                for request in task.turnRequests ?? [] where !request.state.isTerminal {
                    if let json = request.executionPolicySnapshotJSON,
                       !result.requests.includePolicyJSON(json, in: saved) { return nil }
                }
            }
        }
        return result
    }

    private struct Listed: Decodable {
        struct Plugin: Decodable {
            let id: String
            let settings: [String: String]?
            let overriddenComponentIDs: [String]?
            let knownComponentIDs: [String]?
            let secretSettingKeys: [String]?
            let namespaceSeed: String?
            let credentialNamespaceSeed: String?
        }
        struct Skill: Decodable {
            let id: String?
            let credentialNamespaceID: UUID?
            let environmentKeys: [String]?
        }
        struct Task: Decodable {
            let skillSnapshots: [SkillSnapshotConfig]?
            let turnRequests: [TaskTurnRequestSnapshot]?
        }
        let installedPlugins: [Plugin]?
        let skills: [Skill]?
        let tasks: [Task]?
    }
}
