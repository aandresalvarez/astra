import Foundation
import Security

/// Stores and retrieves Astra secrets in the macOS Keychain.
///
/// Each credential is stored as a generic password with:
/// - service: entity-specific namespace + stable UUID
/// - account: the credential key name (e.g. "JIRA_API_TOKEN")
enum KeychainService {

    private static func connectorService(for connectorID: UUID) -> String {
        "astra-\(connectorID.uuidString)"
    }

    private static func skillService(for skillID: UUID) -> String {
        "astra-skill-\(skillID.uuidString)"
    }

    // MARK: - Save

    /// Save or update a credential value for a connector.
    @discardableResult
    static func save(key: String, value: String, connectorID: UUID, label: String? = nil) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let service = connectorService(for: connectorID)

        // Try to update first
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrComment as String: label ?? "Astra connector credential",
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            // Add new item
            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrComment as String: label ?? "Astra connector credential",
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            ]
            if let label {
                addQuery[kSecAttrLabel as String] = label
            }

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }

        AppLogger.audit(.keychainSaveFailed, category: "Keychain", fields: [
            "scope": "connector",
            "status": String(updateStatus)
        ], level: .warning)
        return false
    }

    /// Save or update a credential value for a skill-owned secret.
    @discardableResult
    static func save(key: String, value: String, skillID: UUID, label: String? = nil) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let service = skillService(for: skillID)

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrComment as String: label ?? "Astra skill secret",
        ]

        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess {
            return true
        }

        if updateStatus == errSecItemNotFound {
            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrComment as String: label ?? "Astra skill secret",
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            ]
            if let label {
                addQuery[kSecAttrLabel as String] = label
            }

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            return addStatus == errSecSuccess
        }

        AppLogger.audit(.keychainSaveFailed, category: "Keychain", fields: [
            "scope": "skill",
            "status": String(updateStatus)
        ], level: .warning)
        return false
    }

    // MARK: - Load

    /// Load a credential value for a connector.
    static func load(key: String, connectorID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectorService(for: connectorID),
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Load a credential value for a skill-owned secret.
    static func load(key: String, skillID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: skillService(for: skillID),
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
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

    // MARK: - Delete

    /// Delete a single credential for a connector.
    @discardableResult
    static func delete(key: String, connectorID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectorService(for: connectorID),
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        let ok = status == errSecSuccess || status == errSecItemNotFound
        if !ok {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector",
                "status": String(status)
            ], level: .warning)
        }
        return ok
    }

    /// Delete a single credential for a skill-owned secret.
    @discardableResult
    static func delete(key: String, skillID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: skillService(for: skillID),
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        let ok = status == errSecSuccess || status == errSecItemNotFound
        if !ok {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "skill",
                "status": String(status)
            ], level: .warning)
        }
        return ok
    }

    /// Delete all credentials for a connector.
    static func deleteAll(connectorID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectorService(for: connectorID),
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "connector_all",
                "status": String(status)
            ], level: .warning)
        }
    }

    /// Delete all credentials for a skill.
    static func deleteAll(skillID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: skillService(for: skillID),
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLogger.audit(.keychainDeleteFailed, category: "Keychain", fields: [
                "scope": "skill_all",
                "status": String(status)
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

    // MARK: - Check

    /// Check if a credential exists in the keychain (without reading the value).
    static func exists(key: String, connectorID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: connectorService(for: connectorID),
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Check if a skill-owned secret exists in the keychain (without reading the value).
    static func exists(key: String, skillID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: skillService(for: skillID),
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }
}
