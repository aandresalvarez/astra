import Foundation
import ASTRACore
import ASTRAModels

/// Repairs legacy duplicate structure inside the caller's account transaction.
/// Existing endpoint/name fields own their values; only empty fields adopt a
/// validated legacy value. No endpoint or alias remains as plain configuration.
@MainActor
enum PluginAccountStructureReconciliation {
    /// Endpoint aliases are part of a legacy credential address. Stage that
    /// address into a private generation before restoring a missing endpoint;
    /// accepted requests keep the old address until they release it.
    static func requiresCredentialCutover(for account: Connector, declaration: PluginConnector) -> Bool {
        guard account.credentialNamespaceID == nil, !account.credentialKeys.isEmpty,
              account.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let field = declaration.accountBaseURLField else { return false }
        return account.configKeys.enumerated().contains { index, key in
            key == field.key && index < account.configValues.count
                && !account.configValues[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func apply(to account: Connector, declaration: PluginConnector) throws -> Bool {
        var inputs: [String: String] = [:]
        let fields = [
            (declaration.accountBaseURLField, account.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            (declaration.accountAliasField, account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        ]
        for (hint, empty) in fields {
            guard empty, let hint else { continue }
            let values = Set(account.configKeys.enumerated().compactMap { index, key -> String? in
                guard key == hint.key, index < account.configValues.count else { return nil }
                let value = account.configValues[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            })
            guard values.count <= 1 else {
                throw CapabilityInstaller.InstallationError.blocked([
                    "Conflicting saved values for \(hint.key). Set the account field before updating."
                ])
            }
            inputs[hint.key] = values.first
        }
        // Validate before changing the account or deleting a legacy value.
        let structure = try CapabilityInstaller.AccountStructure(declaration, inputs: inputs)
        let keys = Set(declaration.configHints.filter(\.isAccountStructure).map(\.key))
        let indices = account.configKeys.indices.filter { keys.contains(account.configKeys[$0]) }
        if let endpoint = structure.baseURL { account.baseURL = endpoint }
        if let alias = structure.alias { account.name = alias }
        for index in indices.reversed() {
            account.configKeys.remove(at: index)
            if index < account.configValues.count { account.configValues.remove(at: index) }
        }
        return !indices.isEmpty || structure.baseURL != nil || structure.alias != nil
    }
}
