import Foundation
import ASTRACore
import ASTRAModels

/// A derived plan from the definition being accepted and the account's current
/// fields. No vault reads, writes or independently persisted configuration.
@MainActor
enum PluginAccountCredentialCutoverPlan {
    struct Candidate {
        let account: Connector
        var keeping: Set<String>
        var formats: [String: [ConnectorCredentialFormat]]
        var migratingSettings: Set<String>
    }

    static func formats(of spec: PluginConnector) -> [String: [ConnectorCredentialFormat]] {
        spec.credentialHints.reduce(into: [:]) { result, hint in
            if let format = hint.format { result[ConnectorCredentialKey.canonical(hint.key), default: []].append(format) }
        }
    }

    static func candidates(for package: PluginPackage, activation: PluginActivation) -> [Candidate] {
        var result: [Candidate] = []
        for declared in package.connectors {
            let spec = PluginConnectorFieldTrust.asStored(declared, in: package)
            let component = CapabilityResourceOrigin.componentID(for: spec)
            let predecessors = Set(CapabilityResourceOrigin.replacedComponentIDs(for: spec))
            let components = predecessors.union([component])
            let moved = PluginConnectorFieldTrust.settingsStoredAsCredentials(of: declared, in: package)
            for binding in activation.bindings where !binding.isDeleted && components.contains(binding.componentID) {
                guard let account = binding.account, !account.isDeleted, account.originPackageID == package.id else { continue }
                let declared = Set(moved.map(ConnectorCredentialKey.canonical))
                let promoted = Set(account.configKeys.indices.compactMap { index -> String? in
                    let key = ConnectorCredentialKey.canonical(account.configKeys[index])
                    guard declared.contains(key), index < account.configValues.count,
                          !account.configValues[index].isEmpty else { return nil }
                    return key
                })
                let addsKey = spec.credentialHints.contains { hint in
                    !account.credentialKeys.contains { ConnectorCredentialKey.same($0, hint.key) }
                }
                let renamesLegacy = account.credentialNamespaceID == nil
                    && account.originComponentID.map { predecessors.contains($0) && $0 != component } == true
                let hasLegacyValues = account.credentialValues.contains { !$0.isEmpty }
                guard !promoted.isEmpty || addsKey || renamesLegacy || hasLegacyValues else { continue }
                let keeping = Set(account.credentialKeys.map(ConnectorCredentialKey.canonical)).union(promoted)
                let declaredFormats = formats(of: spec)
                if let index = result.firstIndex(where: { $0.account.id == account.id }) {
                    result[index].keeping.formUnion(keeping)
                    result[index].migratingSettings.formUnion(promoted)
                    for (key, constraints) in declaredFormats {
                        for constraint in constraints where !result[index].formats[key, default: []].contains(constraint) {
                            result[index].formats[key, default: []].append(constraint)
                        }
                    }
                } else { result.append(Candidate(account: account, keeping: keeping, formats: declaredFormats, migratingSettings: promoted)) }
            }
        }
        return result
    }
}
