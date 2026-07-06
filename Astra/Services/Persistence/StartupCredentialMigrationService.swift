import Foundation
import SwiftData
import ASTRAModels

enum StartupCredentialMigrationService {
    @MainActor
    static func schedule(modelContainer: ModelContainer) {
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--uitesting") }) else {
            return
        }

        Task { @MainActor in
            migrate(modelContext: modelContainer.mainContext)
        }
    }

    @MainActor
    static func migrate(modelContext: ModelContext) {
        let workspaces: [Workspace]
        do {
            workspaces = try modelContext.fetch(FetchDescriptor<Workspace>())
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
        migrateSkillSecrets(skills: skills)
        AppLogger.audit(.keychainSecretsMigrated, category: "Keychain", fields: [
            "scope": "startup",
            "result": "checked",
            "workspace_count": String(workspaces.count),
            "workspace_connector_count": String(workspaces.reduce(0) { $0 + $1.connectors.count }),
            "global_connector_count": String(globalConnectors.count),
            "skill_count": String(skills.count)
        ], level: .debug)
    }

    static func migrateConnectorCredentials(workspaces: [Workspace], globalConnectors: [Connector] = []) {
        var seen = Set<UUID>()
        let connectors = workspaces.flatMap(\.connectors) + globalConnectors
        for connector in connectors where seen.insert(connector.id).inserted {
            connector.migrateToKeychain()
            // Move any secrets older versions stored in the login keychain
            // into ASTRA's dedicated keychain. Idempotent; runs once at launch
            // (not on every Connector instantiation), enumerating by service
            // so it covers every credential/OAuth key without naming them.
            KeychainService.migrateConnectorFromLoginKeychain(connector: connector)
        }
    }

    static func migrateSkillSecrets(skills: [Skill]) {
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
        AppLogger.audit(.keychainSecretsMigrated, category: "Keychain", fields: [
            "scope": scope,
            "result": "fetch_failed",
            "reason": error.localizedDescription,
            "error_type": String(describing: type(of: error))
        ], level: .warning)
    }
}
