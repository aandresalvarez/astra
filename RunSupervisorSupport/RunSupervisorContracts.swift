import ASTRACore
import CryptoKit
import Foundation

public enum RunSupervisorProtocol {
    public static let minimumVersion: UInt16 = 1
    public static let maximumVersion: UInt16 = 1
    public static let maximumBootstrapBytes = 1_048_576
    public static let maximumControlFrameBytes = 65_536
}

public enum RunSupervisorError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedProtocol(UInt16)
    case oversizedFrame(limit: Int)
    case truncatedFrame
    case invalidSchema
    case invalidManifestDigest
    case invalidArgumentDigest
    case invalidIdentity
    case staleAuthorityEpoch
    case invalidCapability
    case invalidEnvironmentNames
    case untrustedRoot
    case unsafeFilesystemEntry(String)
    case alreadyRunningOrInDoubt
    case launchPayloadConflict
    case authenticationFailed
    case responseAuthenticationFailed
    case replayedNonce
    case staleAuthentication
    case peerUIDMismatch
    case peerCodeIdentityMismatch
    case spoolBackpressured
    case spoolCriticalCapacityExhausted
    case corruptCommittedSpool
    case outputPersistenceFailed
    case terminalPersistenceFailed
    case invalidAcknowledgement
    case systemCall(String, Int32)

    public var description: String {
        switch self {
        case .unsupportedProtocol(let version): "unsupported protocol version \(version)"
        case .oversizedFrame(let limit): "frame exceeds \(limit) bytes"
        case .truncatedFrame: "truncated frame"
        case .invalidSchema: "invalid or unknown schema fields"
        case .invalidManifestDigest: "manifest digest mismatch"
        case .invalidArgumentDigest: "argument digest mismatch"
        case .invalidIdentity: "execution identity mismatch"
        case .staleAuthorityEpoch: "authority epoch is stale"
        case .invalidCapability: "invalid execution capability"
        case .invalidEnvironmentNames: "environment names do not match the manifest"
        case .untrustedRoot: "run root is not trusted"
        case .unsafeFilesystemEntry(let name): "unsafe filesystem entry: \(name)"
        case .alreadyRunningOrInDoubt: "existing execution is running or in doubt"
        case .launchPayloadConflict: "execution launch payload conflicts with the existing record"
        case .authenticationFailed: "control authentication failed"
        case .responseAuthenticationFailed: "control response authentication failed"
        case .replayedNonce: "control nonce was already used"
        case .staleAuthentication: "control authentication timestamp is stale"
        case .peerUIDMismatch: "control peer uid does not match the supervisor"
        case .peerCodeIdentityMismatch: "control peer code identity does not match the broker"
        case .spoolBackpressured: "output spool is applying backpressure"
        case .spoolCriticalCapacityExhausted: "critical spool reserve is exhausted"
        case .corruptCommittedSpool: "committed spool evidence is corrupt"
        case .outputPersistenceFailed: "provider output could not be persisted"
        case .terminalPersistenceFailed: "provider terminal truth could not be persisted"
        case .invalidAcknowledgement: "acknowledgement is not monotonic or exceeds observed output"
        case .systemCall(let operation, let code):
            "\(operation) failed with errno \(code)"
        }
    }
}

public struct RunSupervisorIdentity: Codable, Equatable, Hashable, Sendable {
    public let installationID: RunBrokerInstallationID
    public let storeID: RunBrokerStoreID
    public let executionID: RunBrokerExecutionID
    public let authority: RunBrokerAuthority

    public init(
        installationID: RunBrokerInstallationID,
        storeID: RunBrokerStoreID,
        executionID: RunBrokerExecutionID,
        authority: RunBrokerAuthority
    ) {
        self.installationID = installationID
        self.storeID = storeID
        self.executionID = executionID
        self.authority = authority
    }

    public init(manifest: ExecutionLaunchManifest) {
        self.init(
            installationID: manifest.installationID,
            storeID: manifest.storeID,
            executionID: manifest.executionID,
            authority: manifest.authority
        )
    }
}

public struct RunSupervisorCapability: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let byteCount = 32
    private let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw RunSupervisorError.invalidCapability }
        self.bytes = bytes
    }

    public init(base64: String) throws {
        guard let data = Data(base64Encoded: base64) else {
            throw RunSupervisorError.invalidCapability
        }
        try self.init(bytes: data)
    }

    public static func random() throws -> Self {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return try Self(bytes: Data(bytes))
    }

    public var base64: String { bytes.base64EncodedString() }
    public var description: String { "<redacted execution capability>" }
    public var debugDescription: String { description }
    package var symmetricKey: SymmetricKey { SymmetricKey(data: bytes) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(base64: container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Execution capability must be exactly 32 bytes"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64)
    }
}

public enum RunSupervisorDigests {
    public static func manifest(_ manifest: ExecutionLaunchManifest) throws -> ExecutionLaunchArgumentsSHA256 {
        try digest(canonicalData(manifest))
    }

    public static func arguments(_ arguments: [String]) throws -> ExecutionLaunchArgumentsSHA256 {
        var data = Data()
        for argument in arguments {
            let bytes = Data(argument.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return try digest(data)
    }

    public static func capability(_ capability: RunSupervisorCapability) throws -> ExecutionLaunchArgumentsSHA256 {
        try digest(Data(capability.base64.utf8))
    }

    public static func launchAuthenticator(
        payload: RunSupervisorBootstrapPayload,
        capability: RunSupervisorCapability
    ) throws -> String {
        let unsigned = RunSupervisorUnsignedLaunch(
            protocolVersion: payload.protocolVersion,
            manifest: payload.manifest,
            manifestSHA256: payload.manifestSHA256,
            expectedIdentity: payload.expectedIdentity,
            arguments: payload.arguments,
            environment: payload.environment
        )
        return hmac(try canonicalData(unsigned), capability: capability)
    }

    package static func hmac(_ data: Data, capability: RunSupervisorCapability) -> String {
        hmacBytes(data, capability: capability)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    package static func hmacBytes(
        _ data: Data,
        capability: RunSupervisorCapability
    ) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: capability.symmetricKey))
    }

    package static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    package static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        constantTimeEqual(Data(lhs.utf8), Data(rhs.utf8))
    }

    package static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    private static func digest(_ data: Data) throws -> ExecutionLaunchArgumentsSHA256 {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try ExecutionLaunchArgumentsSHA256(hexValue: hex)
    }
}

package struct RunSupervisorUnsignedLaunch: Codable {
    let protocolVersion: UInt16
    let manifest: ExecutionLaunchManifest
    let manifestSHA256: ExecutionLaunchArgumentsSHA256
    let expectedIdentity: RunSupervisorIdentity
    let arguments: [String]
    let environment: [String: String]
}

package extension KeyedDecodingContainer {
    func rejectUnknownKeys(_ allowedKeys: [Key]) throws {
        let allowedNames = Set(allowedKeys.map(\.stringValue))
        guard allKeys.allSatisfy({ allowedNames.contains($0.stringValue) }) else {
            throw RunSupervisorError.invalidSchema
        }
    }
}

package struct RunSupervisorAnyCodingKey: CodingKey {
    package let stringValue: String
    package let intValue: Int?
    package init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    package init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

package extension Decoder {
    func rejectUnknownKeyNames(_ allowed: Set<String>) throws {
        let container = try self.container(keyedBy: RunSupervisorAnyCodingKey.self)
        guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw RunSupervisorError.invalidSchema
        }
    }
}

public enum RunSupervisorWireCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try RunSupervisorDigests.canonicalData(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
