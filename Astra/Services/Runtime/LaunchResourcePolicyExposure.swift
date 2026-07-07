import Foundation

struct LaunchResourcePolicyExposure: Equatable, Sendable {
    static let absent = LaunchResourcePolicyExposure()

    var launchResourceContractAvailable: Bool
    var providerEnvironmentSecretResourceLabels: [String]
    var providerFileCredentialResourceLabels: [String]
    var providerUnenforcedFileCredentialResourceLabels: [String]

    init(
        launchResourceContractAvailable: Bool = false,
        providerEnvironmentSecretResourceLabels: [String] = [],
        providerFileCredentialResourceLabels: [String] = [],
        providerUnenforcedFileCredentialResourceLabels: [String] = []
    ) {
        self.launchResourceContractAvailable = launchResourceContractAvailable
        self.providerEnvironmentSecretResourceLabels = Self.unique(providerEnvironmentSecretResourceLabels)
        self.providerFileCredentialResourceLabels = Self.unique(providerFileCredentialResourceLabels)
        self.providerUnenforcedFileCredentialResourceLabels = Self.unique(providerUnenforcedFileCredentialResourceLabels)
    }

    init(contract: LaunchResourceContract) {
        let environmentSecrets = contract.providerEnvironmentSecretResources
        let fileCredentials = contract.providerFileCredentialResources
        self.init(
            launchResourceContractAvailable: true,
            providerEnvironmentSecretResourceLabels: environmentSecrets.map(Self.resourceLabel),
            providerFileCredentialResourceLabels: fileCredentials.map(Self.resourceLabel),
            providerUnenforcedFileCredentialResourceLabels: fileCredentials
                .filter(Self.needsCredentialFileEnforcementDiagnostic)
                .map(Self.resourceLabel)
        )
    }

    private static func needsCredentialFileEnforcementDiagnostic(
        _ resource: LaunchResourceContract.Resource
    ) -> Bool {
        resource.enforcementBoundary != .launchResourceProjection
    }

    private static func resourceLabel(_ resource: LaunchResourceContract.Resource) -> String {
        resource.environmentKey
            ?? resource.credentialLabel
            ?? resource.path
            ?? resource.capability
            ?? resource.id
    }

    private static func unique(_ values: [String]) -> [String] {
        Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
}
