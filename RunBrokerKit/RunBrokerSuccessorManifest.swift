import CryptoKit
import Foundation

/// Release-signed identity of an ASTRA successor. The broker reads this from
/// the live peer's bundle; callers never supply paths or trust roots.
public struct RunBrokerSuccessorManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let channel: RunBrokerChannel
    public let bundleIdentifier: String
    public let version: String
    public let build: String
    public let executableSHA256: String
    public let brokerSHA256: String
    public let supervisorSHA256: String

    public init(channel: RunBrokerChannel, bundleIdentifier: String, version: String,
                build: String, executableSHA256: String, brokerSHA256: String,
                supervisorSHA256: String) {
        self.schemaVersion = 1
        self.channel = channel
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.executableSHA256 = executableSHA256
        self.brokerSHA256 = brokerSHA256
        self.supervisorSHA256 = supervisorSHA256
    }
}

public enum RunBrokerSuccessorManifestError: Error, Equatable, Sendable {
    case invalidPublicKey, invalidSignature, invalidManifest
}

public enum RunBrokerSuccessorManifestVerifier {
    public static func verify(manifestData: Data, signature: Data, publicKey: Data)
        throws -> RunBrokerSuccessorManifest {
        guard publicKey.count == 32,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            throw RunBrokerSuccessorManifestError.invalidPublicKey
        }
        guard signature.count == 64, key.isValidSignature(signature, for: manifestData) else {
            throw RunBrokerSuccessorManifestError.invalidSignature
        }
        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(RunBrokerSuccessorManifest.self, from: manifestData),
              manifest.schemaVersion == 1,
              !manifest.bundleIdentifier.isEmpty,
              !manifest.version.isEmpty,
              !manifest.build.isEmpty,
              [manifest.executableSHA256, manifest.brokerSHA256, manifest.supervisorSHA256]
                .allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw RunBrokerSuccessorManifestError.invalidManifest
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard (try? encoder.encode(manifest)) == manifestData else {
            throw RunBrokerSuccessorManifestError.invalidManifest
        }
        return manifest
    }
}
