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

enum SkillSecretPersistence {
    static func deleteRemovedSecret(key: String, from skill: Skill) {
        KeychainService.delete(key: key, skillID: skill.id)
    }

    static func valueForEnvironmentKey(on skill: Skill, at index: Int, store: SecretStore) -> String {
        guard index < skill.environmentKeys.count else { return "" }
        let key = skill.environmentKeys[index]
        let storedValue = skill.normalizedEnvironmentValue(at: index)
        if Skill.isSecretEnvironmentKey(key) {
            let entityID = KeychainSecretStore.skillEntityID(for: skill.id)
            return store.load(key: key, entityID: entityID) ?? storedValue
        }
        return storedValue
    }

    static func setEnvironmentValue(_ value: String, on skill: Skill, at index: Int) {
        guard index < skill.environmentKeys.count else { return }
        skill.ensureEnvironmentValueCapacity()

        let key = skill.environmentKeys[index]
        if Skill.isSecretEnvironmentKey(key) {
            if !value.isEmpty {
                let saved = KeychainService.save(key: key, value: value, skillID: skill.id, label: "Astra: \(skill.name)")
                AppLogger.audit(.skillSecretAdded, category: "Keychain", fields: [
                    "skill_id": skill.id.uuidString,
                    "result": saved ? "stored" : "failed"
                ], level: saved ? .info : .warning)
                skill.environmentValues[index] = saved ? "" : value
            } else {
                skill.environmentValues[index] = ""
            }
        } else {
            skill.environmentValues[index] = value
        }
        skill.updatedAt = Date()
    }

    static func removeEnvironmentEntry(on skill: Skill, at index: Int) {
        guard index < skill.environmentKeys.count else { return }
        let key = skill.environmentKeys[index]
        if Skill.isSecretEnvironmentKey(key) {
            let deleted = KeychainService.delete(key: key, skillID: skill.id)
            AppLogger.audit(.skillSecretRemoved, category: "Keychain", fields: [
                "skill_id": skill.id.uuidString,
                "result": deleted ? "removed" : "failed"
            ], level: deleted ? .info : .warning)
        }
        skill.environmentKeys.remove(at: index)
        if index < skill.environmentValues.count {
            skill.environmentValues.remove(at: index)
        }
        skill.updatedAt = Date()
    }

    static func migrateSecretsToKeychain(_ skill: Skill) {
        skill.ensureEnvironmentValueCapacity()

        for (index, key) in skill.environmentKeys.enumerated() where Skill.isSecretEnvironmentKey(key) {
            let legacyValue = skill.environmentValues[index]
            guard !legacyValue.isEmpty else { continue }

            if KeychainService.exists(key: key, skillID: skill.id) {
                skill.environmentValues[index] = ""
                continue
            }

            if KeychainService.save(key: key, value: legacyValue, skillID: skill.id, label: "Astra: \(skill.name)") {
                skill.environmentValues[index] = ""
            }
        }
    }

    static func cleanupKeychain(for skill: Skill) {
        KeychainService.deleteAll(skillID: skill.id)
        AppLogger.audit(.skillDeleted, category: "Keychain", fields: [
            "skill_id": skill.id.uuidString
        ])
    }
}
