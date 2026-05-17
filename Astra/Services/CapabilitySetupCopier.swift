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
            guard let connector = matchingConnector(
                for: pluginConnector,
                in: workspace,
                globalConnectors: globalConnectors
            ) else {
                continue
            }

            let baseURL = connector.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !baseURL.isEmpty {
                inputs.baseURLOverrides[pluginConnector.name] = baseURL
                for key in packageEnvironmentKeys where Self.shouldMapBaseURL(baseURL, toEnvironmentKey: key, connector: pluginConnector) {
                    inputs.configInputs[key] = baseURL
                }
            }

            let connectorConfig = connector.config
            for hint in pluginConnector.configHints {
                if let value = nonEmpty(connectorConfig[hint.key]) {
                    inputs.configInputs[hint.key] = value
                }
            }
            for key in packageEnvironmentKeys {
                if let value = nonEmpty(connectorConfig[key]) {
                    inputs.configInputs[key] = value
                }
            }

            let credentials = connector.credentials(store: secretStore)
            for hint in pluginConnector.credentialHints {
                if let value = nonEmpty(credentials[hint.key]) {
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

    private func matchingConnector(
        for pluginConnector: PluginConnector,
        in workspace: Workspace,
        globalConnectors: [Connector]
    ) -> Connector? {
        let enabledGlobalConnectorIDs = Set(workspace.enabledGlobalConnectorIDs)
        let enabledGlobalConnectors = globalConnectors.filter { connector in
            enabledGlobalConnectorIDs.contains(connector.id.uuidString)
        }
        let candidates = workspace.connectors + enabledGlobalConnectors
        return candidates.first { connector in
            CapabilityRuntimeResourceMatcher.connectorMatches(pluginConnector, connector: connector)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedToken(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

private extension OnboardingCapabilityInstallationInputs {
    var isEmpty: Bool {
        credentialInputs.isEmpty && configInputs.isEmpty && baseURLOverrides.isEmpty
    }
}
