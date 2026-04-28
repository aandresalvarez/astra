import Foundation
import Security
import ASTRACore

struct KeychainSecretStore: SecretStore {
    func load(key: String, entityID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: entityID,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func save(key: String, value: String, entityID: String, label: String?) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: entityID,
            kSecAttrAccount as String: key,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrComment as String: label ?? "Astra credential",
        ]
        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess { return true }

        if updateStatus == errSecItemNotFound {
            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: entityID,
                kSecAttrAccount as String: key,
                kSecValueData as String: data,
                kSecAttrComment as String: label ?? "Astra credential",
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            ]
            if let label { addQuery[kSecAttrLabel as String] = label }
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }

        return false
    }

    @discardableResult
    func delete(key: String, entityID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: entityID,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func deleteAll(entityID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: entityID,
        ]
        SecItemDelete(query as CFDictionary)
    }

    func exists(key: String, entityID: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: entityID,
            kSecAttrAccount as String: key,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    static func connectorEntityID(for connectorID: UUID) -> String {
        "\(AppChannel.current.keychainConnectorPrefix)-\(connectorID.uuidString)"
    }

    static func skillEntityID(for skillID: UUID) -> String {
        "\(AppChannel.current.keychainSkillPrefix)-\(skillID.uuidString)"
    }
}
