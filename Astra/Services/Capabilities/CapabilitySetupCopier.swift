import Foundation
import ASTRACore

struct CapabilitySetupCopySummary: Equatable {
    var sourceWorkspaceName: String
    var selectedPackageIDs: Set<String>
    var inputsByPackageID: [String: OnboardingCapabilityInstallationInputs]
    var copiedCredentialCount: Int
    var copiedConfigCount: Int

    var packageCount: Int {
        selectedPackageIDs.count
    }
}

struct CapabilitySetupCopier {
    let secretStore: SecretStore

    init(secretStore: SecretStore = KeychainSecretStore()) {
        self.secretStore = secretStore
    }

    func copyablePackageIDs(from workspace: Workspace) -> Set<String> {
        Set(workspace.enabledCapabilityIDs).intersection(OnboardingCapabilitySetup.installablePackageIDs)
    }

    func copySetup(
        from workspace: Workspace,
        packages: [PluginPackage] = PluginCatalog.builtInPackages,
        globalConnectors: [Connector] = []
    ) -> CapabilitySetupCopySummary {
        let explicitlyEnabledPackageIDs = copyablePackageIDs(from: workspace)
        var packageIDs = Set<String>()
        var inputsByPackageID: [String: OnboardingCapabilityInstallationInputs] = [:]
        var credentialCount = 0
        var configCount = 0

        for package in packages where OnboardingCapabilitySetup.installablePackageIDs.contains(package.id) {
            let inputs = installationInputs(for: package, from: workspace, globalConnectors: globalConnectors)
            guard explicitlyEnabledPackageIDs.contains(package.id) || !inputs.isEmpty else {
                continue
            }

            packageIDs.insert(package.id)
            if !inputs.isEmpty {
                inputsByPackageID[package.id] = inputs
                credentialCount += inputs.credentialInputs.count
                configCount += inputs.configInputs.count + inputs.baseURLOverrides.count
            }
        }

        return CapabilitySetupCopySummary(
            sourceWorkspaceName: workspace.name,
            selectedPackageIDs: packageIDs,
            inputsByPackageID: inputsByPackageID,
            copiedCredentialCount: credentialCount,
            copiedConfigCount: configCount
        )
    }

    func installationInputs(
        for package: PluginPackage,
        from workspace: Workspace,
        globalConnectors: [Connector] = []
    ) -> OnboardingCapabilityInstallationInputs {
        var inputs = OnboardingCapabilityInstallationInputs()
        let packageEnvironmentKeys = package.skills.flatMap(\.environmentKeys)

        for pluginConnector in package.connectors {
            let connectors = matchingConnectors(
                for: pluginConnector,
                in: workspace,
                globalConnectors: globalConnectors
            )

            for connector in connectors {
                let baseURL = connector.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !baseURL.isEmpty,
                   baseURL != pluginConnector.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) {
                    inputs.baseURLOverrides[pluginConnector.name] = baseURL
                    for key in packageEnvironmentKeys where Self.shouldMapBaseURL(baseURL, toEnvironmentKey: key, connector: pluginConnector) {
                        inputs.configInputs[key] = baseURL
                    }
                }

                let connectorConfig = connector.config
                for hint in pluginConnector.configHints where inputs.configInputs[hint.key] == nil {
                    if let value = connectorValue(for: hint.key, in: connectorConfig, serviceType: pluginConnector.serviceType) {
                        inputs.configInputs[hint.key] = value
                    }
                }
                for key in packageEnvironmentKeys where inputs.configInputs[key] == nil {
                    if let value = connectorValue(for: key, in: connectorConfig, serviceType: pluginConnector.serviceType) {
                        inputs.configInputs[key] = value
                    }
                }

                for hint in pluginConnector.credentialHints where inputs.credentialInputs[hint.key] == nil {
                    if let value = credentialValue(for: hint.key, in: connector, serviceType: pluginConnector.serviceType)
                        ?? connectorValue(for: hint.key, in: connectorConfig, serviceType: pluginConnector.serviceType) {
                        inputs.credentialInputs[hint.key] = value
                    }
                }
            }

            for hint in pluginConnector.credentialHints where inputs.credentialInputs[hint.key] == nil {
                if let value = legacyGlobalCredentialValue(
                    for: hint.key,
                    workspace: workspace,
                    serviceType: pluginConnector.serviceType
                ) {
                    inputs.credentialInputs[hint.key] = value
                }
            }
        }

        return inputs
    }

    static func shouldMapBaseURL(
        _ baseURL: String,
        toEnvironmentKey key: String,
        connector: PluginConnector? = nil
    ) -> Bool {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else { return false }
        let normalizedKey = normalizedToken(key)
        guard normalizedKey.contains("url") else { return false }
        guard let connector else { return true }

        let serviceType = normalizedToken(connector.serviceType)
        if !serviceType.isEmpty, normalizedKey.contains(serviceType) {
            return true
        }

        let name = normalizedToken(connector.name)
        return !name.isEmpty && normalizedKey.contains(name)
    }

    private func matchingConnectors(
        for pluginConnector: PluginConnector,
        in workspace: Workspace,
        globalConnectors: [Connector]
    ) -> [Connector] {
        let enabledGlobalConnectorIDs = Set(workspace.enabledGlobalConnectorIDs.map(Self.normalizedID))
        let enabledGlobalConnectors = globalConnectors.filter { connector in
            enabledGlobalConnectorIDs.contains(Self.normalizedID(connector.id.uuidString))
        }
        let candidates = workspace.connectors + enabledGlobalConnectors
        return candidates.filter { connector in
            CapabilityRuntimeResourceMatcher.connectorMatches(pluginConnector, connector: connector)
        }
    }

    private func credentialValue(for key: String, in connector: Connector, serviceType: String) -> String? {
        let keyCandidates = Self.copyKeyCandidates(
            requestedKey: key,
            sourceKeys: connector.credentialKeys,
            serviceType: serviceType
        )

        for entityID in Self.copySourceEntityIDs(for: connector.id) {
            for candidate in keyCandidates {
                if let value = nonEmpty(secretStore.load(key: candidate, entityID: entityID)) {
                    return value
                }
            }
        }

        for sourceKey in keyCandidates {
            guard let index = connector.credentialKeys.firstIndex(where: {
                Self.keysMatch($0, sourceKey, serviceType: serviceType)
            }), index < connector.credentialValues.count else {
                continue
            }
            if let value = nonEmpty(connector.credentialValues[index]) {
                return value
            }
        }

        return nil
    }

    private func legacyGlobalCredentialValue(
        for key: String,
        workspace: Workspace,
        serviceType: String
    ) -> String? {
        let keyCandidates = Self.copyKeyCandidates(
            requestedKey: key,
            sourceKeys: Self.legacyCredentialKeyAliases(for: key, serviceType: serviceType),
            serviceType: serviceType
        )
        for rawID in workspace.enabledGlobalConnectorIDs {
            guard let connectorID = UUID(uuidString: rawID) else { continue }
            for entityID in Self.copySourceEntityIDs(for: connectorID) {
                for candidate in keyCandidates {
                    if let value = nonEmpty(secretStore.load(key: candidate, entityID: entityID)) {
                        return value
                    }
                }
            }
        }
        return nil
    }

    private static func copySourceEntityIDs(for connectorID: UUID) -> [String] {
        [
            KeychainSecretStore.connectorEntityID(for: connectorID),
            "agentflow-\(connectorID.uuidString)"
        ]
    }

    private func connectorValue(
        for key: String,
        in values: [String: String],
        serviceType: String
    ) -> String? {
        for (sourceKey, value) in values where Self.keysMatch(sourceKey, key, serviceType: serviceType) {
            if let value = nonEmpty(value) {
                return value
            }
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func copyKeyCandidates(
        requestedKey: String,
        sourceKeys: [String],
        serviceType: String
    ) -> [String] {
        var candidates: [String] = [requestedKey, requestedKey.uppercased(), requestedKey.lowercased()]
        candidates += legacyCredentialKeyAliases(for: requestedKey, serviceType: serviceType)
        candidates += sourceKeys.filter { keysMatch($0, requestedKey, serviceType: serviceType) }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func legacyCredentialKeyAliases(for key: String, serviceType: String) -> [String] {
        let normalizedKey = normalizedToken(key)
        let servicePrefix = normalizedToken(serviceType)
        var aliases: [String] = []

        if !servicePrefix.isEmpty, normalizedKey.hasPrefix(servicePrefix) {
            let suffix = String(normalizedKey.dropFirst(servicePrefix.count))
            if suffix == "email" {
                aliases += ["EMAIL", "USERNAME"]
            }
            if suffix == "apitoken" || suffix == "token" || suffix == "apikey" || suffix == "key" {
                aliases += ["API_TOKEN", "TOKEN", "\(serviceType.uppercased())_TOKEN"]
            }
        }

        return aliases
    }

    private static func keysMatch(_ sourceKey: String, _ requestedKey: String, serviceType: String) -> Bool {
        let source = normalizedToken(sourceKey)
        let requested = normalizedToken(requestedKey)
        guard !source.isEmpty, !requested.isEmpty else { return false }
        if source == requested { return true }

        let servicePrefix = normalizedToken(serviceType)
        guard !servicePrefix.isEmpty, requested.hasPrefix(servicePrefix) else {
            return false
        }

        let unprefixedRequested = String(requested.dropFirst(servicePrefix.count))
        return !unprefixedRequested.isEmpty && source == unprefixedRequested
    }

    private static func normalizedToken(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func normalizedID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

private extension OnboardingCapabilityInstallationInputs {
    var isEmpty: Bool {
        credentialInputs.isEmpty && configInputs.isEmpty && baseURLOverrides.isEmpty
    }
}
