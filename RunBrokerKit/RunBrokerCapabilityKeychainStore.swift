import Foundation
import AstraObjCSupport
import ASTRACore

public enum RunBrokerCapabilityKeychainError: Error, Equatable, Sendable {
    case unavailable
    case provisioningFailed
}

public protocol RunBrokerCapabilitySecretStoring: Sendable {
    func load(
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID
    ) throws -> RunBrokerCapabilitySecret

    func provision(
        _ secret: RunBrokerCapabilitySecret,
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID,
        trustedApplicationURLs: [URL]
    ) throws
}

/// OS-owned storage for the broker request MAC key. Its Keychain ACL binds
/// decrypt access to exact designated code requirements. For an ad-hoc binary
/// that requirement includes its CDHash, so a same-UID provider cannot obtain
/// the key merely by copying the public bundle identifier.
public struct RunBrokerCapabilityKeychainStore: RunBrokerCapabilitySecretStoring, Sendable {
    public init() {}

    public func load(
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID
    ) throws -> RunBrokerCapabilitySecret {
        guard let data = AstraSecureKeychain.runBrokerSecretData(
            forAccount: installationID.rawValue.uuidString,
            service: service(for: channel)
        ) else {
            throw RunBrokerCapabilityKeychainError.unavailable
        }
        return try RunBrokerCapabilitySecret(bytes: data)
    }

    public func provision(
        _ secret: RunBrokerCapabilitySecret,
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID,
        trustedApplicationURLs: [URL]
    ) throws {
        let paths = trustedApplicationURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        guard Set(paths).count == paths.count,
              AstraSecureKeychain.provisionRunBrokerSecretData(
                secret.keychainBytes,
                forAccount: installationID.rawValue.uuidString,
                service: service(for: channel),
                trustedApplicationPaths: paths
              ) else {
            throw RunBrokerCapabilityKeychainError.provisioningFailed
        }
    }

    private func service(for channel: RunBrokerChannel) -> String {
        switch channel {
        case .production: "com.coral.ASTRA.run-broker.capability"
        case .development: "com.coral.ASTRA.dev.run-broker.capability"
        }
    }
}
