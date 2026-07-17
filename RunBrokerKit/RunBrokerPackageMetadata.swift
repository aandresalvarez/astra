import Foundation
import Darwin

public enum RunBrokerPackageMetadataError: Error, Equatable, Sendable {
    case missingField(String)
    case unsupportedSchemaVersion(Int)
    case unexpectedExecutableName
    case packagedExecutableMissing
    case invalidCohortDigest
}

/// Signed app metadata PR7 will consume when it composes startup bootstrap.
/// PR5 deliberately does not install from this contract automatically.
public struct RunBrokerPackagedPayloadMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let executableName = RunBrokerCohort.brokerExecutableName
    public static let supervisorExecutableName = RunBrokerCohort.supervisorExecutableName
    public static let infoSchemaVersionKey = "ASTRARunBrokerPayloadSchemaVersion"
    public static let infoVersionKey = "ASTRARunBrokerPayloadVersion"
    public static let infoSHA256Key = "ASTRARunBrokerPayloadSHA256"
    public static let infoExecutableKey = "ASTRARunBrokerPayloadExecutable"
    public static let infoSupervisorSHA256Key = "ASTRARunSupervisorPayloadSHA256"
    public static let infoSupervisorExecutableKey = "ASTRARunSupervisorPayloadExecutable"
    public static let infoCohortSHA256Key = "ASTRARunBrokerCohortSHA256"

    public let schemaVersion: Int
    public let version: RunBrokerPayloadVersion
    public let sha256: RunBrokerSHA256Digest
    public let executable: String
    public let supervisorSHA256: RunBrokerSHA256Digest
    public let supervisorExecutable: String
    public let cohortSHA256: RunBrokerSHA256Digest

    public init(
        version: RunBrokerPayloadVersion,
        sha256: RunBrokerSHA256Digest,
        supervisorSHA256: RunBrokerSHA256Digest,
        cohortSHA256: RunBrokerSHA256Digest,
        executable: String = Self.executableName,
        supervisorExecutable: String = Self.supervisorExecutableName
    ) throws {
        guard executable == Self.executableName,
              supervisorExecutable == Self.supervisorExecutableName else {
            throw RunBrokerPackageMetadataError.unexpectedExecutableName
        }
        guard try RunBrokerCohort.digest(
            brokerSHA256: sha256,
            supervisorSHA256: supervisorSHA256
        ) == cohortSHA256 else {
            throw RunBrokerPackageMetadataError.invalidCohortDigest
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.version = version
        self.sha256 = sha256
        self.executable = executable
        self.supervisorSHA256 = supervisorSHA256
        self.supervisorExecutable = supervisorExecutable
        self.cohortSHA256 = cohortSHA256
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
        guard let rawSupervisorSHA256 =
                infoDictionary[Self.infoSupervisorSHA256Key] as? String else {
            throw RunBrokerPackageMetadataError.missingField(Self.infoSupervisorSHA256Key)
        }
        guard let supervisorExecutable =
                infoDictionary[Self.infoSupervisorExecutableKey] as? String else {
            throw RunBrokerPackageMetadataError.missingField(Self.infoSupervisorExecutableKey)
        }
        guard let rawCohortSHA256 = infoDictionary[Self.infoCohortSHA256Key] as? String else {
            throw RunBrokerPackageMetadataError.missingField(Self.infoCohortSHA256Key)
        }
        try self.init(
            version: RunBrokerPayloadVersion(rawValue: rawVersion),
            sha256: RunBrokerSHA256Digest(rawValue: rawSHA256),
            supervisorSHA256: RunBrokerSHA256Digest(rawValue: rawSupervisorSHA256),
            cohortSHA256: RunBrokerSHA256Digest(rawValue: rawCohortSHA256),
            executable: executable,
            supervisorExecutable: supervisorExecutable
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, version, sha256, executable
        case supervisorSHA256, supervisorExecutable, cohortSHA256
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
            supervisorSHA256: container.decode(
                RunBrokerSHA256Digest.self,
                forKey: .supervisorSHA256
            ),
            cohortSHA256: container.decode(RunBrokerSHA256Digest.self, forKey: .cohortSHA256),
            executable: container.decode(String.self, forKey: .executable),
            supervisorExecutable: container.decode(String.self, forKey: .supervisorExecutable)
        )
    }

    public func payload(toolsDirectory: URL) throws -> RunBrokerPayload {
        let executableURL = toolsDirectory.appendingPathComponent(executable, isDirectory: false)
        let supervisorURL = toolsDirectory.appendingPathComponent(
            supervisorExecutable,
            isDirectory: false
        )
        guard Self.isRegularExecutable(executableURL),
              Self.isRegularExecutable(supervisorURL) else {
            throw RunBrokerPackageMetadataError.packagedExecutableMissing
        }
        return try RunBrokerPayload(
            sourceExecutableURL: executableURL,
            sourceSupervisorExecutableURL: supervisorURL,
            version: version,
            expectedSHA256: sha256,
            expectedSupervisorSHA256: supervisorSHA256,
            expectedCohortSHA256: cohortSHA256
        )
    }

    private static func isRegularExecutable(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
            && (info.st_mode & S_IFMT) == S_IFREG
            && (info.st_mode & 0o111) != 0
    }
}
