import Foundation
import ASTRACore

enum ConnectorSecretPersistence {
    static func credentials(for connector: Connector, store: SecretStore) -> [String: String] {
        let entityIDs = KeychainSecretStore.connectorEntityIDs(for: connector)
        var result: [String: String] = [:]
        for key in connector.credentialKeys {
            for entityID in entityIDs {
                if let value = store.load(key: key, entityID: entityID) {
                    result[key] = value
                    break
                }
            }
        }
        return result
    }

    static func missingCredentialKeys(for connector: Connector, store: SecretStore) -> [String] {
        let resolved = credentials(for: connector, store: store)
        return connector.credentialKeys.filter { key in
            let value = resolved[key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty
        }
    }

    static func saveCredential(on connector: Connector, key: String, value: String) {
        let upperKey = key.uppercased()
        let saved = KeychainService.save(key: upperKey, value: value, connector: connector, label: "Astra: \(connector.name)")

        if let index = connector.credentialKeys.firstIndex(where: { $0.caseInsensitiveCompare(upperKey) == .orderedSame }) {
            connector.credentialKeys[index] = upperKey
            if index < connector.credentialValues.count {
                connector.credentialValues[index] = ""
            }
        } else {
            connector.credentialKeys.append(upperKey)
            connector.credentialValues.append("")
        }
        connector.updatedAt = Date()
        AppLogger.audit(.connectorSecretAdded, category: "Keychain", fields: [
            "connector_id": connector.id.uuidString,
            "service_type": connector.serviceType,
            "result": saved ? "stored" : "failed"
        ], level: saved ? .info : .warning)
    }

    static func removeCredential(on connector: Connector, at index: Int) {
        guard index < connector.credentialKeys.count else { return }
        let key = connector.credentialKeys[index]
        let deleted = KeychainService.delete(key: key, connector: connector)
        connector.credentialKeys.remove(at: index)
        if index < connector.credentialValues.count {
            connector.credentialValues.remove(at: index)
        }
        connector.updatedAt = Date()
        AppLogger.audit(.connectorSecretRemoved, category: "Keychain", fields: [
            "connector_id": connector.id.uuidString,
            "service_type": connector.serviceType,
            "result": deleted ? "removed" : "failed"
        ], level: deleted ? .info : .warning)
    }

    static func migrateToKeychain(_ connector: Connector) {
        for (index, key) in connector.credentialKeys.enumerated() {
            guard index < connector.credentialValues.count else { continue }
            let value = connector.credentialValues[index]
            guard !value.isEmpty else { continue }

            if !KeychainService.exists(key: key, connector: connector) {
                KeychainService.save(key: key, value: value, connector: connector, label: "Astra: \(connector.name)")
            }
            connector.credentialValues[index] = ""
        }
        KeychainService.synchronizeConnectorCredentialNamespaces(connector: connector)
    }

    static func cleanupKeychain(for connector: Connector) {
        if connector.isStanfordOutlookMail {
            StanfordOutlookMailRegistry.remove(connectorID: connector.id)
        }
        KeychainService.deleteAll(connector: connector)
        AppLogger.audit(.connectorDeleted, category: "Keychain", fields: [
            "connector_id": connector.id.uuidString,
            "service_type": connector.serviceType
        ])
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
