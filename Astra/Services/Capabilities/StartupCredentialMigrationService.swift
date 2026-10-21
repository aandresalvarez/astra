import Foundation
import SwiftData
import ASTRAModels
import ASTRACore
import ASTRAPersistence

/// Application orchestration: persistence remains the domain owner; account
/// cutover delegates to the same durable protocol as explicit credential edits.
@MainActor
public enum StartupCredentialMigrationService {
    public static func schedule(modelContainer: ModelContainer) {
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uitesting") }) else { return }
        Task { @MainActor in migrate(modelContext: modelContainer.mainContext) }
    }

    public static func migrate(modelContext: ModelContext) {
        guard !modelContext.hasChanges else { audit("unsaved_changes"); return }
        do {
            let workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
            let connectors = try modelContext.fetch(FetchDescriptor<Connector>())
            let skills = try modelContext.fetch(FetchDescriptor<Skill>())
            // Historical vault values were already accepted. Moving their
            // storage service does not admit raw model values or change owners.
            for account in connectors { KeychainService.migrateConnectorFromLoginKeychain(connector: account) }
            let accountsComplete = migrateAccounts(connectors, mirroredBy: workspaces, modelContext: modelContext)
            // Each skill has its own durable transaction. An unrelated account
            // with legacy debt must not retain every skill's plaintext too.
            let skillsComplete = migrateSkillSecrets(skills: skills, modelContext: modelContext)
            if !accountsComplete || !skillsComplete { audit("migration_deferred") }
            AstraSecureKeychainStore.logPendingKeychainFailure(scope: "startup")
        } catch { audit("fetch_failed", error: error) }
    }

    @discardableResult
    static func migrateAccounts(
        _ accounts: [Connector], mirroredBy workspaces: [Workspace]?, modelContext: ModelContext,
        resolver: (any ConnectorSettingStorageResolving.Type)? = ConnectorSettingStorageSeam.resolver,
        persist: (ModelContext) throws -> Void = { try $0.save() }, rewriteMirror: ((Workspace) -> Bool)? = nil
    ) -> Bool {
        guard let workspaces else { audit("workspace_scope_unreadable"); return false }
        var completed = true
        for account in accounts {
            do {
                _ = try ConnectorCredentialMigration.migrate(account, mirroredBy: workspaces, modelContext: modelContext,
                    resolver: resolver, persist: persist, rewriteMirror: rewriteMirror)
            } catch {
                completed = false
                audit("account_migration_deferred", error: error)
            }
        }
        return completed
    }

    @discardableResult
    static func migrateSkillSecrets(skills: [Skill], modelContext: ModelContext,
                                   persist: (ModelContext) throws -> Void = { try $0.save() },
                                   rewriteMirror: ((Workspace) -> Bool)? = nil) -> Bool {
        guard !modelContext.hasChanges else { audit("unsaved_changes"); return false }
        var completed = true
        for skill in skills {
            do {
                KeychainService.migrateSkillFromLoginKeychain(skillID: skill.secretNamespaceID)
                _ = try SkillCredentialMigration.migrate(skill, modelContext: modelContext,
                    persist: persist, rewriteMirror: rewriteMirror)
            } catch {
                completed = false
                audit("skill_migration_deferred", error: error)
            }
        }
        return completed
    }

    private static func audit(_ result: String, error: Error? = nil) {
        // Error types identify debt without putting legacy credential text or
        // paths supplied by a plugin into the audit trail.
        var fields = ["scope": "startup", "result": result]
        if let error { fields["error_type"] = String(describing: type(of: error)) }
        AuditLoggingSeam.required.audit(.keychainSecretsMigrated, category: "Keychain", fields: fields, level: .warning)
    }
}
