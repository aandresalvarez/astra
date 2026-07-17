import Foundation
import Darwin

public enum RunBrokerPackageMetadataError: Error, Equatable, Sendable {
    case missingField(String)
    case unsupportedSchemaVersion(Int)
    case unexpectedExecutableName
    case packagedExecutableMissing
}

/// Signed app metadata PR7 will consume when it composes startup bootstrap.
/// PR5 deliberately does not install from this contract automatically.
public struct RunBrokerPackagedPayloadMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let executableName = "astra-run-broker"
    public static let infoSchemaVersionKey = "ASTRARunBrokerPayloadSchemaVersion"
    public static let infoVersionKey = "ASTRARunBrokerPayloadVersion"
    public static let infoSHA256Key = "ASTRARunBrokerPayloadSHA256"
    public static let infoExecutableKey = "ASTRARunBrokerPayloadExecutable"

    public let schemaVersion: Int
    public let version: RunBrokerPayloadVersion
    public let sha256: RunBrokerSHA256Digest
    public let executable: String

    public init(
        version: RunBrokerPayloadVersion,
        sha256: RunBrokerSHA256Digest,
        executable: String = Self.executableName
    ) throws {
        guard executable == Self.executableName else {
            throw RunBrokerPackageMetadataError.unexpectedExecutableName
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.version = version
        self.sha256 = sha256
        self.executable = executable
    }

    public init(infoDictionary: [String: Any]) throws {
        guard let schemaVersion = infoDictionary[Self.infoSchemaVersionKey] as? Int else {
            throw RunBrokerPackageMetadataError.missingField(Self.infoSchemaVersionKey)
        }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RunBrokerPackageMetadataError.unsupportedSchemaVersion(schemaVersion)
        }
        guard let rawVersion = infoDictionary[Self.infoVersionKey] as? String else {
            throw RunBrokerPackageMetadataError.missingField(Self.infoVersionKey)
        }
        guard let rawSHA256 = infoDictionary[Self.infoSHA256Key] as? String else {
            throw RunBrokerPackageMetadataError.missingField(Self.infoSHA256Key)
        }
        guard let executable = infoDictionary[Self.infoExecutableKey] as? String else {
            throw RunBrokerPackageMetadataError.missingField(Self.infoExecutableKey)
        }
        try self.init(
            version: RunBrokerPayloadVersion(rawValue: rawVersion),
            sha256: RunBrokerSHA256Digest(rawValue: rawSHA256),
            executable: executable
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, version, sha256, executable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RunBrokerPackageMetadataError.unsupportedSchemaVersion(schemaVersion)
        }
        try self.init(
            version: container.decode(RunBrokerPayloadVersion.self, forKey: .version),
            sha256: container.decode(RunBrokerSHA256Digest.self, forKey: .sha256),
            executable: container.decode(String.self, forKey: .executable)
        )
    }

    public func payload(toolsDirectory: URL) throws -> RunBrokerPayload {
        let executableURL = toolsDirectory.appendingPathComponent(executable, isDirectory: false)
        var info = stat()
        guard lstat(executableURL.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o111) != 0 else {
            throw RunBrokerPackageMetadataError.packagedExecutableMissing
        }
        return RunBrokerPayload(
            sourceExecutableURL: executableURL,
            version: version,
            expectedSHA256: sha256
        )
    }
}
