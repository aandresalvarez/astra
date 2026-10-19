import Foundation
import SwiftData
import ASTRAModels
import ASTRACore

public enum StartupCredentialMigrationService {
    @MainActor
    public static func schedule(modelContainer: ModelContainer) {
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uitesting") }) else {
            return
        }

        Task { @MainActor in
            migrate(modelContext: modelContainer.mainContext)
        }
    }

    @MainActor
    public static func migrate(modelContext: ModelContext) {
        let workspaces: [Workspace]
        // Nil when the workspaces can't be read: no mirror can be rewritten.
        var mirroringWorkspaces: [Workspace]?
        do {
            workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
            mirroringWorkspaces = workspaces
        } catch {
            workspaces = []
            logFetchFailure(scope: "workspace_connectors", error: error)
        }

        let globalConnectors: [Connector]
        do {
            globalConnectors = try modelContext.fetch(
                FetchDescriptor<Connector>(predicate: #Predicate { $0.isGlobal == true })
            )
        } catch {
            globalConnectors = []
            logFetchFailure(scope: "global_connectors", error: error)
        }

        let skills: [Skill]
        do {
            skills = try modelContext.fetch(FetchDescriptor<Skill>())
        } catch {
            skills = []
            logFetchFailure(scope: "skills", error: error)
        }

        migrateConnectorCredentials(workspaces: workspaces, globalConnectors: globalConnectors)
        moveSettingsStoredAsCredentials(
            of: uniqueConnectors(workspaces: workspaces, globalConnectors: globalConnectors),
            mirroredBy: mirroringWorkspaces,
            modelContext: modelContext
        )
        migrateSkillSecrets(skills: skills)
        // The two passes above touch the dedicated keychain once per connector
        // and once per skill, so if it cannot be opened at all this is the
        // earliest and loudest place to find out. Previously it wasn't found out
        // anywhere: the migration logged `result=checked` just the same, and the
        // app went on to report every credential as simply not configured.
        AstraSecureKeychainStore.logPendingKeychainFailure(scope: "startup")
        AuditLoggingSeam.required.audit(.keychainSecretsMigrated, category: "Keychain", fields: [
            "scope": "startup",
            "result": "checked",
            "workspace_count": String(workspaces.count),
            "workspace_connector_count": String(workspaces.reduce(0) { $0 + $1.connectors.count }),
            "global_connector_count": String(globalConnectors.count),
            "skill_count": String(skills.count)
        ], level: .debug)
    }

    public static func migrateConnectorCredentials(workspaces: [Workspace], globalConnectors: [Connector] = []) {
        for connector in uniqueConnectors(workspaces: workspaces, globalConnectors: globalConnectors) {
            connector.migrateToKeychain()
            // Move any secrets older versions stored in the login keychain
            // into ASTRA's dedicated keychain. Idempotent; runs once at launch
            // (not on every Connector instantiation), enumerating by service
            // so it covers every credential/OAuth key without naming them.
            KeychainService.migrateConnectorFromLoginKeychain(connector: connector)
        }
    }

    /// Moves each plain setting a row's creator stores as a credential into
    /// the Keychain (`Connector.moveSettingsStoredAsCredentials`), then saves
    /// and rewrites every workspace's mirror on this thread: one an older
    /// build wrote still holds those values, and the export now withholds
    /// them. Which mirrors name a row (its workspace's, a skill's, an enabled
    /// shared one, a bound account) is the export's business, so all of
    /// them are rewritten. When the save or a rewrite fails, the rows and
    /// the Keychain are put back as they were, so the next launch moves the
    /// values, and rewrites the mirrors, again. With `workspaces` unknown
    /// (nil: they couldn't be read) nothing moves: a mirror nobody rewrites
    /// would keep the value the store no longer has. True when nothing was
    /// left to retry.
    @MainActor
    @discardableResult
    static func moveSettingsStoredAsCredentials(
        of connectors: [Connector],
        mirroredBy workspaces: [Workspace]?,
        modelContext: ModelContext,
        resolver: (any ConnectorSettingStorageResolving.Type)? = ConnectorSettingStorageSeam.resolver,
        store: SecretStore = SecretStoreSeam.required,
        rewriteMirror: ((Workspace) -> Bool)? = nil
    ) -> Bool {
        guard let workspaces else { return false }
        var restorers: [() -> Void] = []
        var writes: [ConnectorSettingSecretWrite] = []
        for connector in connectors {
            let row = (connector.configKeys, connector.configValues, connector.credentialKeys,
                       connector.credentialValues, connector.updatedAt)
            guard !connector.moveSettingsStoredAsCredentials(resolver: resolver, store: store, recording: { writes.append($0) }).isEmpty
            else { continue }
            restorers.append {
                (connector.configKeys, connector.configValues, connector.credentialKeys,
                 connector.credentialValues, connector.updatedAt) = row
            }
        }
        guard !restorers.isEmpty else { return true }
        let rewrite = rewriteMirror ?? { WorkspaceConfigManager.exportMirrorNow(workspace: $0, modelContext: modelContext) }
        let saved = WorkspacePersistenceCoordinator.saveWithoutAutoExport(
            modelContext: modelContext, auditFields: ["scope": "connector_setting_migration"]
        )
        let unwritten = saved ? workspaces.filter { !rewrite($0) }.count : workspaces.count
        guard unwritten > 0 else { return true }
        restorers.forEach { $0() }
        let unrestored = writes.reversed().filter { !$0.undo(store: store) }.count
        let restoreSaved = WorkspacePersistenceCoordinator.saveWithoutAutoExport(
            modelContext: modelContext, auditFields: ["scope": "connector_setting_migration_undo"]
        )
        AuditLoggingSeam.required.audit(.keychainSecretsMigrated, category: "Keychain", fields: [
            "scope": "connector_setting",
            "result": saved ? "mirror_rewrite_failed" : "save_failed",
            "unwritten_mirror_count": String(unwritten),
            "unrestored_secret_count": String(unrestored),
            "restore_saved": String(restoreSaved)
        ], level: .warning)
        return false
    }

    private static func uniqueConnectors(workspaces: [Workspace], globalConnectors: [Connector]) -> [Connector] {
        var seen = Set<UUID>()
        return (workspaces.flatMap(\.connectors) + globalConnectors).filter { seen.insert($0.id).inserted }
    }

    public static func migrateSkillSecrets(skills: [Skill]) {
        for skill in skills {
            skill.migrateSecretsToKeychain()
            // See migrateConnectorCredentials: relocate legacy login-keychain
            // secrets into ASTRA's dedicated keychain. Done here rather than in
            // Skill.migrateSecretsToKeychain() (which Skill.init() calls on every
            // instantiation) to keep the per-init path free of keychain queries.
            KeychainService.migrateSkillFromLoginKeychain(skillID: skill.id)
        }
    }

    private static func logFetchFailure(scope: String, error: Error) {
        AuditLoggingSeam.required.audit(.keychainSecretsMigrated, category: "Keychain", fields: [
            "scope": scope,
            "result": "fetch_failed",
            "reason": error.localizedDescription,
            "error_type": String(describing: type(of: error))
        ], level: .warning)
    }
}
