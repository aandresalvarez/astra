import Foundation
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Presentation-only status. No credential values cross into a view or a cache.
/// Runtime authorization always reads the credential generation independently.
struct PluginCredentialReadiness: Sendable {
    struct Account: Equatable, Sendable {
        let id: UUID
        let credentialNamespaceID: UUID?
        let serviceType: String
        let baseURL: String
        let originPackageID: String?
        let originComponentID: String?
        let credentialKeys: [String]
        let updatedAt: Date

        init(_ connector: Connector) {
            id = connector.id; credentialNamespaceID = connector.credentialNamespaceID
            serviceType = connector.serviceType; baseURL = connector.baseURL
            originPackageID = connector.originPackageID; originComponentID = connector.originComponentID
            credentialKeys = connector.credentialKeys; updatedAt = connector.updatedAt
        }
    }

    struct AccountStatus: Sendable {
        let account: Account
        let missingKeys: [String]
        let unavailableKeys: [String]
    }
    var accounts: [UUID: AccountStatus] = [:]

    func messages(for connector: Connector, requiredKeys: Set<String>) -> [String] {
        let name = connector.name.isEmpty ? "Connector" : connector.name
        guard let status = accounts[connector.id], status.account.credentialNamespaceID == connector.credentialNamespaceID,
              status.account.baseURL == connector.baseURL,
              status.account.serviceType == connector.serviceType,
              status.account.originPackageID == connector.originPackageID,
              status.account.originComponentID == connector.originComponentID,
              Set(connector.credentialKeys).isSubset(of: Set(status.account.credentialKeys)) else {
            return ["\(name): checking saved credentials…"]
        }
        let unavailable = status.unavailableKeys.filter { requiredKeys.contains($0) }
        if !unavailable.isEmpty { return ["\(name): couldn't read saved credentials; unlock the credential store and retry"] }
        let missing = status.missingKeys.filter { requiredKeys.contains($0) }
        return missing.isEmpty ? [] : ["\(name): missing Keychain value: \(missing.joined(separator: ", "))"]
    }

    /// Called on a utility task with value snapshots, never live SwiftData rows.
    static func load(_ accounts: [Account], store: SecretStore = KeychainSecretStore()) -> Self {
        var result = Self()
        for account in accounts {
            guard !Task.isCancelled else { break }
            let ids = KeychainSecretStore.connectorEntityIDs(id: account.id, serviceType: account.serviceType,
                baseURL: account.baseURL, originPackageID: account.originPackageID,
                originComponentID: account.originComponentID, credentialNamespaceID: account.credentialNamespaceID)
            var missing: [String] = []
            var unavailable: [String] = []
            for key in account.credentialKeys where !OutlookCredentialIdentity.isInternalKey(key) {
                var outcome = SecretReadOutcome.missing
                for id in ids {
                    outcome = store.read(key: key, entityID: id)
                    if outcome != .missing { break }
                }
                switch outcome {
                case .missing: missing.append(key)
                case .unavailable: unavailable.append(key)
                case .value(let value):
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(key) }
                }
            }
            result.accounts[account.id] = AccountStatus(account: account, missingKeys: missing, unavailableKeys: unavailable)
        }
        return result
    }
}
