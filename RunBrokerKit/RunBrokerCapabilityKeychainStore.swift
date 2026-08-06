import Foundation
import AstraObjCSupport
import ASTRACore

public enum RunBrokerCapabilityKeychainError: Error, Equatable, Sendable {
    case unavailable
    case provisioningFailed
    case invalidPinnedUpdateKey
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

    public func load(
        installationID: RunBrokerInstallationID
    ) throws -> RunBrokerCapabilitySecret {
        let matches = [RunBrokerChannel.production, .development].compactMap { channel in
            try? load(channel: channel, installationID: installationID)
        }
        guard matches.count == 1, let secret = matches.first else {
            throw RunBrokerCapabilityKeychainError.unavailable
        }
        return secret
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

    public func loadPinnedUpdatePublicKey(
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID
    ) throws -> Data {
        guard let data = AstraSecureKeychain.runBrokerSecretData(
            forAccount: installationID.rawValue.uuidString,
            service: updateKeyService(for: channel)
        ), data.count == 32 else {
            throw RunBrokerCapabilityKeychainError.unavailable
        }
        return data
    }

    public func provisionPinnedUpdatePublicKey(
        _ publicKey: Data,
        channel: RunBrokerChannel,
        installationID: RunBrokerInstallationID,
        trustedApplicationURLs: [URL]
    ) throws {
        guard publicKey.count == 32 else {
            throw RunBrokerCapabilityKeychainError.invalidPinnedUpdateKey
        }
        let paths = trustedApplicationURLs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
        guard Set(paths).count == paths.count,
              AstraSecureKeychain.provisionRunBrokerSecretData(
                publicKey,
                forAccount: installationID.rawValue.uuidString,
                service: updateKeyService(for: channel),
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

    private func updateKeyService(for channel: RunBrokerChannel) -> String {
        service(for: channel) + ".update-public-key"
    }
}
