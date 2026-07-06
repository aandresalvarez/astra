import Foundation
import ASTRACore

/// Registered as the `ConnectorSecretSeam` (`ASTRACore/ConnectorSecretSeam.swift`)
/// backing implementation - see that file's header for why every method here
/// takes `ConnectorSecretFacts` instead of `Connector` directly: index
/// manipulation on `credentialKeys`/`credentialValues`, `updatedAt`, and
/// audit logging all moved into `Connector.swift` itself as part of Track
/// A2.5, which now calls through here only for the pure Keychain I/O.
enum ConnectorSecretPersistence: ConnectorSecretPersisting {
    static func loadAllCredentials(keys: [String], facts: ConnectorSecretFacts, store: SecretStore) -> [String: String] {
        let entityIDs = KeychainSecretStore.connectorEntityIDs(
            id: facts.id,
            serviceType: facts.serviceType,
            baseURL: facts.baseURL,
            originPackageID: facts.originPackageID,
            originComponentID: facts.originComponentID
        )
        var result: [String: String] = [:]
        for key in keys {
            for entityID in entityIDs {
                if let value = store.load(key: key, entityID: entityID) {
                    result[key] = value
                    break
                }
            }
        }
        return result
    }

    @discardableResult
    static func saveCredential(_ value: String, key: String, facts: ConnectorSecretFacts) -> Bool {
        let saved = KeychainService.save(key: key, value: value, facts: facts, label: "Astra: \(facts.name)")
        AppLogger.audit(.connectorSecretAdded, category: "Keychain", fields: [
            "connector_id": facts.id.uuidString,
            "service_type": facts.serviceType,
            "result": saved ? "stored" : "failed"
        ], level: saved ? .info : .warning)
        return saved
    }

    @discardableResult
    static func deleteCredential(key: String, facts: ConnectorSecretFacts) -> Bool {
        let deleted = KeychainService.delete(key: key, facts: facts)
        AppLogger.audit(.connectorSecretRemoved, category: "Keychain", fields: [
            "connector_id": facts.id.uuidString,
            "service_type": facts.serviceType,
            "result": deleted ? "removed" : "failed"
        ], level: deleted ? .info : .warning)
        return deleted
    }

    static func credentialExists(key: String, facts: ConnectorSecretFacts) -> Bool {
        KeychainService.exists(key: key, facts: facts)
    }

    static func loadCredential(key: String, facts: ConnectorSecretFacts) -> String? {
        KeychainService.load(key: key, facts: facts)
    }

    static func deleteAllCredentials(facts: ConnectorSecretFacts) {
        KeychainService.deleteAll(facts: facts)
    }

    static func synchronizeCredentialNamespaces(keys: [String], facts: ConnectorSecretFacts) {
        KeychainService.synchronizeConnectorCredentialNamespaces(keys: keys, facts: facts)
    }
}

/// Registered as the `SkillSecretSeam` (`ASTRACore/SkillSecretSeam.swift`)
/// backing implementation - see that file's header for why this is pure
/// Keychain I/O plumbing with no `Skill`/logging references (both moved to
/// `Skill.swift` as part of Track A2.4).
enum SkillSecretPersistence: SkillSecretPersisting {
    static func loadSecretValue(key: String, skillID: UUID, store: SecretStore) -> String? {
        let entityID = KeychainSecretStore.skillEntityID(for: skillID)
        return store.load(key: key, entityID: entityID)
    }

    static func saveSecretValue(_ value: String, key: String, skillID: UUID, skillName: String) -> Bool {
        KeychainService.save(key: key, value: value, skillID: skillID, label: "Astra: \(skillName)")
    }

    static func deleteSecret(key: String, skillID: UUID) -> Bool {
        KeychainService.delete(key: key, skillID: skillID)
    }

    static func secretExists(key: String, skillID: UUID) -> Bool {
        KeychainService.exists(key: key, skillID: skillID)
    }

    static func deleteAllSecrets(skillID: UUID) {
        KeychainService.deleteAll(skillID: skillID)
    }
}
