import Foundation

/// Stores and retrieves Astra secrets in ASTRA's dedicated keychain file.
///
/// Each credential is a generic password keyed by:
/// - service: entity-specific namespace + stable UUID
/// - account: the credential key name (e.g. "JIRA_API_TOKEN")
///
/// The storage backend is `AstraSecureKeychainStore`, which keeps these secrets
/// in a dedicated keychain file separate from the user's `login.keychain-db`
/// (the only keychain the sandboxed agent can read, for the gh GitHub token).
/// This type's public API is unchanged from when secrets lived in the login
/// keychain — only the backing store moved.
enum KeychainService {

    private static func connectorService(for connectorID: UUID) -> String {
        "\(AppChannel.current.keychainConnectorPrefix)-\(connectorID.uuidString)"
    }

    private static func connectorServices(for connector: Connector) -> [String] {
        KeychainSecretStore.connectorEntityIDs(for: connector)
    }

    private static func skillService(for skillID: UUID) -> String {
        "\(AppChannel.current.keychainSkillPrefix)-\(skillID.uuidString)"
    }

    // MARK: - Save

    /// Save or update a credential value for a connector.
    @discardableResult
    static func save(
        key: String,
        value: String,
        connectorID: UUID,
        label: String? = nil,
        allowUserInteraction: Bool = false
    ) -> Bool {
        let saved = AstraSecureKeychainStore.save(
            service: connectorService(for: connectorID),
            account: key,
            value: value,
            label: label ?? "Astra connector credential",
            allowUserInteraction: allowUserInteraction
        )
        if !saved {
            AppLogger.audit(.keychainSaveFailed, category: "Keychain", fields: [
                "scope": "connector"
            ], level: .warning)
        }
        return saved
    }

    /// Save or update a credential value for a connector in every supported
    /// connector namespace. The UUID namespace preserves compatibility with
    /// existing rows; the stable namespace lets equivalent recreated connectors
    /// reuse user-entered secrets without another prompt.
    @discardableResult
    static func save(
        key: String,
        value: String,
        connector: Connector,
        label: String? = nil,
        allowUserInteraction: Bool = false
    ) -> Bool {
        let services = connectorServices(for: connector)
        let saved = services.map { service in
            AstraSecureKeychainStore.save(
                service: service,
                account: key,
                value: value,
                label: label ?? "Astra connector credential",
                allowUserInteraction: allowUserInteraction
            )
        }
        let ok = saved.allSatisfy { $0 }
        if !ok {
            AppLogger.audit(.keychainSaveFailed, category: "Keychain", fields: [
                "scope": "connector",
                "namespace_count": String(services.count)
            ], level: .warning)
        }
        return ok
    }

    /// Save or update a credential value for a skill-owned secret.
    @discardableResult
    static func save(
        key: String,
        value: String,
        skillID: UUID,
        label: String? = nil,
        allowUserInteraction: Bool = false
    ) -> Bool {
        let saved = AstraSecureKeychainStore.save(
            service: skillService(for: skillID),
            account: key,
            value: value,
            label: label ?? "Astra skill secret",
            allowUserInteraction: allowUserInteraction
        )
        if !saved {
            AppLogger.audit(.keychainSaveFailed, category: "Keychain", fields: [
                "scope": "skill"
            ], level: .warning)
        }
        return saved
    }

    // MARK: - Load

    /// Load a credential value for a connector.
    static func load(key: String, connectorID: UUID) -> String? {
        AstraSecureKeychainStore.load(service: connectorService(for: connectorID), account: key)
    }

    /// Load a credential value for a connector from the first namespace that
    /// contains it. UUID wins over stable so user edits to a specific connector
    /// can override shared stable defaults.
    static func load(key: String, connector: Connector) -> String? {
        for service in connectorServices(for: connector) {
            if let value = AstraSecureKeychainStore.load(service: service, account: key) {
                return value
            }
        }
        return nil
    }

    /// Load a credential value for a skill-owned secret.
    static func load(key: String, skillID: UUID) -> String? {
        AstraSecureKeychainStore.load(service: skillService(for: skillID), account: key)
    }

    /// Load all credential values for a connector, given the key names.
    static func loadAll(keys: [String], connectorID: UUID) -> [String: String] {
        var result: [String: String] = [:]
        for key in keys {
            if let value = load(key: key, connectorID: connectorID) {
                result[key] = value
            }
        }
        return result
    }

    /// Load all credential values for a connector, given the key names.
    static func loadAll(keys: [String], connector: Connector) -> [String: String] {
        var result: [String: String] = [:]
        for key in keys {
            if let value = load(key: key, connector: connector) {
                result[key] = value
            }
        }
        return result
    }

    // MARK: - Delete

    /// Delete a single credential for a connector.
    @discardableResult
    static func delete(key: String, connectorID: UUID) -> Bool {
        let ok = AstraSecureKeychainStore.delete(service: connectorService(for: connectorID), account: key)
        if !ok {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector"
            ], level: .warning)
        }
        return ok
    }

    /// Delete a single credential from every namespace owned by a connector.
    @discardableResult
    static func delete(key: String, connector: Connector) -> Bool {
        let services = connectorServices(for: connector)
        let deleted = services.map { service in
            AstraSecureKeychainStore.delete(service: service, account: key)
        }
        let ok = deleted.contains(true)
        if !ok {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector",
                "namespace_count": String(services.count)
            ], level: .warning)
        }
        return ok
    }

    /// Delete a single credential for a skill-owned secret.
    @discardableResult
    static func delete(key: String, skillID: UUID) -> Bool {
        let ok = AstraSecureKeychainStore.delete(service: skillService(for: skillID), account: key)
        if !ok {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "skill"
            ], level: .warning)
        }
        return ok
    }

    /// Delete all credentials for a connector.
    static func deleteAll(connectorID: UUID) {
        let ok = AstraSecureKeychainStore.deleteAll(service: connectorService(for: connectorID))
        if !ok {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_all"
            ], level: .warning)
        }
    }

    /// Delete all credentials for a connector from every supported namespace.
    static func deleteAll(connector: Connector) {
        let services = connectorServices(for: connector)
        let deleted = services.map { AstraSecureKeychainStore.deleteAll(service: $0) }
        if !deleted.contains(true) {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_all",
                "namespace_count": String(services.count)
            ], level: .warning)
        }
    }

    /// Delete all credentials for a skill.
    static func deleteAll(skillID: UUID) {
        let ok = AstraSecureKeychainStore.deleteAll(service: skillService(for: skillID))
        if !ok {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "skill_all"
            ], level: .warning)
        }
    }

    // MARK: - Bulk Save

    /// Save multiple credential key-value pairs for a connector.
    static func saveAll(credentials: [String: String], connectorID: UUID, connectorName: String = "") {
        let label = connectorName.isEmpty ? nil : "Astra: \(connectorName)"
        for (key, value) in credentials {
            save(key: key, value: value, connectorID: connectorID, label: label)
        }
    }

    /// Save multiple credential key-value pairs for a connector in every
    /// supported namespace.
    static func saveAll(credentials: [String: String], connector: Connector, connectorName: String = "") {
        let label = connectorName.isEmpty ? nil : "Astra: \(connectorName)"
        for (key, value) in credentials {
            save(key: key, value: value, connector: connector, label: label)
        }
    }

    // MARK: - Check

    /// Check if a credential exists in the keychain (without reading the value).
    static func exists(key: String, connectorID: UUID) -> Bool {
        AstraSecureKeychainStore.exists(service: connectorService(for: connectorID), account: key)
    }

    /// Check if a connector credential exists in any supported namespace.
    static func exists(key: String, connector: Connector) -> Bool {
        connectorServices(for: connector).contains { service in
            AstraSecureKeychainStore.exists(service: service, account: key)
        }
    }

    /// Check if a skill-owned secret exists in the keychain (without reading the value).
    static func exists(key: String, skillID: UUID) -> Bool {
        AstraSecureKeychainStore.exists(service: skillService(for: skillID), account: key)
    }

    // MARK: - Legacy login-keychain migration

    /// Move any of this connector's secrets that still live in the user's login
    /// keychain (from app versions that stored them there) into ASTRA's dedicated
    /// keychain. Idempotent; safe to call on every launch.
    static func migrateConnectorFromLoginKeychain(connectorID: UUID) {
        migrate(service: connectorService(for: connectorID), scope: "connector")
    }

    /// Move legacy login-keychain items for every namespace this connector can
    /// use, then copy any found declared credentials across all namespaces.
    static func migrateConnectorFromLoginKeychain(connector: Connector) {
        for service in connectorServices(for: connector) {
            migrate(service: service, scope: "connector")
        }
        synchronizeConnectorCredentialNamespaces(connector: connector)
    }

    /// Move any of this skill's secrets out of the login keychain. Idempotent.
    static func migrateSkillFromLoginKeychain(skillID: UUID) {
        migrate(service: skillService(for: skillID), scope: "skill")
    }

    /// If a declared connector credential exists in one namespace, backfill it
    /// into every namespace so future connector re-imports do not need the
    /// user to re-enter the same secret.
    static func synchronizeConnectorCredentialNamespaces(connector: Connector) {
        let label = connector.name.isEmpty ? nil : "Astra: \(connector.name)"
        for key in connector.credentialKeys {
            guard let value = load(key: key, connector: connector),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            save(key: key, value: value, connector: connector, label: label)
        }
    }

    private static func migrate(service: String, scope: String) {
        let moved = AstraSecureKeychainStore.migrateServiceFromLoginKeychain(service: service)
        if moved > 0 {
            AppLogger.audit(.keychainSecretsMigrated, category: "Keychain", fields: [
                "scope": scope,
                "result": "moved",
                "count": String(moved)
            ], level: .info)
        } else if moved < 0 {
            AppLogger.audit(.keychainSecretsMigrated, category: "Keychain", fields: [
                "scope": scope,
                "result": "failed"
            ], level: .warning)
        }
    }
}
