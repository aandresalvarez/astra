import Foundation
import ASTRACore

/// `SecretStore` backed by ASTRA's dedicated keychain file (see
/// `AstraSecureKeychainStore`), keeping connector/skill secrets out of the
/// user's `login.keychain-db`. The protocol surface is unchanged — only the
/// backing store moved.
struct KeychainSecretStore: SecretStore {
    func load(key: String, entityID: String) -> String? {
        AstraSecureKeychainStore.load(service: entityID, account: key)
    }

    @discardableResult
    func save(key: String, value: String, entityID: String, label: String?) -> Bool {
        AstraSecureKeychainStore.save(
            service: entityID,
            account: key,
            value: value,
            label: label ?? "Astra credential"
        )
    }

    @discardableResult
    func delete(key: String, entityID: String) -> Bool {
        AstraSecureKeychainStore.delete(service: entityID, account: key)
    }

    func deleteAll(entityID: String) {
        AstraSecureKeychainStore.deleteAll(service: entityID)
    }

    func exists(key: String, entityID: String) -> Bool {
        AstraSecureKeychainStore.exists(service: entityID, account: key)
    }

    static func connectorEntityID(for connectorID: UUID) -> String {
        "\(AppChannel.current.keychainConnectorPrefix)-\(connectorID.uuidString)"
    }

    static func skillEntityID(for skillID: UUID) -> String {
        "\(AppChannel.current.keychainSkillPrefix)-\(skillID.uuidString)"
    }
}
