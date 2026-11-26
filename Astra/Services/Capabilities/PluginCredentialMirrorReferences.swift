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

    /// How many times this process has walked the skill snapshots a mirror's
    /// tasks carry on the main actor. A mirror decoded ahead was walked with
    /// its decode, off the main actor, so tests pin by this count what a
    /// capture walks on it.
    private(set) static var mainActorSnapshotWalkCount = 0

    /// `decodedAhead` holds mirror decodes made off the main actor, used only
    /// for the bytes this capture reads.
    static func capture(
        modelContext: ModelContext, extraMirrors: [String]? = nil, excludingWorkspaceIDs: Set<UUID>? = nil,
        decodedAhead: CredentialMirrorDecodes? = nil
    ) -> Self? {
        guard let files = CredentialRecoveryMirrors.read(modelContext: modelContext, extraMirrors: extraMirrors,
            excludingWorkspaceIDs: excludingWorkspaceIDs, decodedAhead: decodedAhead) else { return nil }
        return capture(files, modelContext: modelContext)
    }

    /// `capture` from mirror files already read, as a pass that reads them
    /// once for several readers does.
    static func capture(_ files: [CredentialRecoveryMirrors.Entry], modelContext: ModelContext) -> Self? {
        let saved = ModelContext(modelContext.container)
        var result = Self()
        for file in files {
            guard let listed = CredentialRecoveryMirrors.decoded(file, \.references,
                                                                 decodingWith: PluginCredentialMirrorListing.decode)
            else { return nil }
            var namespaces = Set<UUID>()
            for plugin in listed.installedPlugins ?? [] {
                guard let workspaceID = file.workspaceID else { return nil }
                let evidence = plugin.credentialRecoveryEvidence.flatMap {
                    $0.appliesTo(namespaceSeed: plugin.namespaceSeed ?? "", credentialNamespaceSeed: plugin.credentialNamespaceSeed ?? "") ? $0 : nil
                }
                guard let references = PluginCredentialMetadataPolicy.references(
                    pluginID: plugin.id, version: plugin.version, digest: plugin.digest,
                    knownComponentIDs: plugin.knownComponentIDs, credentialComponentIDs: plugin.credentialComponentIDs,
                    secretSettingKeys: plugin.secretSettingKeys, settingKeys: Array((plugin.settings ?? [:]).keys),
                    overriddenComponentIDs: plugin.overriddenComponentIDs, accountComponentIDs: (plugin.accounts ?? []).map(\.componentID),
                    recoveryEvidence: evidence) else {
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
            // Every task's skill snapshots, walked with the decode when it
            // was made ahead. What they hold only adds to the rest, and
            // nothing read below has an effect, so walking them before the
            // tasks' requests decides as walking them task by task did.
            let snapshots = file.decodedAhead?.taskSkillSnapshots ?? {
                mainActorSnapshotWalkCount += 1
                return MirrorTaskSkillSnapshots(listed)
            }()
            guard let held = snapshots.held else { return nil }
            result.requests.include(held)
            for task in listed.tasks ?? [] {
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
}

/// What `PluginCredentialMirrorReferences.capture` reads from a mirror: its
/// installed plugins, skills, and tasks.
struct PluginCredentialMirrorListing: Decodable, Sendable {
    struct Plugin: Decodable, Sendable {
        struct Account: Decodable, Sendable { let componentID: String }
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
    struct Skill: Decodable, Sendable {
        let id: String?
        let credentialNamespaceID: UUID?
        let environmentKeys: [String]?
    }
    struct Task: Decodable, Sendable {
        let status: String?
        let isDone: Bool?
        let skillSnapshots: [SkillSnapshotConfig]?
        let turnRequests: [TaskTurnRequestSnapshot]?
    }
    let installedPlugins: [Plugin]?
    let skills: [Skill]?
    let tasks: [Task]?

    /// Dates as the export writes them, or as an older writer did.
    static func decode(_ data: Data) -> Self? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Self.self, from: data)) ?? (try? JSONDecoder().decode(Self.self, from: data))
    }
}

/// What the skill snapshots of every task a mirror lists can still read, as
/// `PluginCredentialMirrorReferences.capture` gathers them: a pure function
/// of the listing, so a mirror decoded ahead (`CredentialMirrorDecodes`) is
/// walked there, off the main actor. A mirror's tasks can carry thousands.
struct MirrorTaskSkillSnapshots: Sendable {
    /// Nil when a snapshot names an ID that isn't one, which holds cleanup
    /// closed.
    let held: HeldCredentials?

    init(_ listing: PluginCredentialMirrorListing) {
        var held = HeldCredentials()
        for task in listing.tasks ?? [] where !held.includeSkillSnapshots(task.skillSnapshots ?? []) {
            self.held = nil
            return
        }
        self.held = held
    }
}
