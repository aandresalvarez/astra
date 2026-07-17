import CryptoKit
import Darwin
import Foundation
import RunBrokerClient

public enum RunBrokerCohort {
    public static let brokerExecutableName = "astra-run-broker"
    public static let supervisorExecutableName = "astra-run-supervisor"

    public static func digest(
        brokerSHA256: RunBrokerSHA256Digest,
        supervisorSHA256: RunBrokerSHA256Digest
    ) throws -> RunBrokerSHA256Digest {
        var transcript = Data("astra.run-broker.cohort.v1".utf8)
        for value in [
            brokerExecutableName,
            brokerSHA256.rawValue,
            supervisorExecutableName,
            supervisorSHA256.rawValue
        ] {
            transcript.append(0)
            transcript.append(Data(value.utf8))
        }
        return try RunBrokerSHA256Digest(
            rawValue: SHA256.hash(data: transcript)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }
}

public struct RunBrokerPayload: Equatable, Sendable {
    public let sourceExecutableURL: URL
    public let sourceSupervisorExecutableURL: URL
    public let version: RunBrokerPayloadVersion
    public let expectedSHA256: RunBrokerSHA256Digest
    public let expectedSupervisorSHA256: RunBrokerSHA256Digest
    public let expectedCohortSHA256: RunBrokerSHA256Digest

    public init(
        sourceExecutableURL: URL,
        sourceSupervisorExecutableURL: URL,
        version: RunBrokerPayloadVersion,
        expectedSHA256: RunBrokerSHA256Digest,
        expectedSupervisorSHA256: RunBrokerSHA256Digest,
        expectedCohortSHA256: RunBrokerSHA256Digest
    ) throws {
        guard try RunBrokerCohort.digest(
            brokerSHA256: expectedSHA256,
            supervisorSHA256: expectedSupervisorSHA256
        ) == expectedCohortSHA256 else {
            throw RunBrokerInstallationError.invalidCohortDigest
        }
        self.sourceExecutableURL = sourceExecutableURL
        self.sourceSupervisorExecutableURL = sourceSupervisorExecutableURL
        self.version = version
        self.expectedSHA256 = expectedSHA256
        self.expectedSupervisorSHA256 = expectedSupervisorSHA256
        self.expectedCohortSHA256 = expectedCohortSHA256
    }
}

public struct RunBrokerInstalledCohort: Equatable, Sendable {
    public let brokerExecutableURL: URL
    public let supervisorExecutableURL: URL
}

public enum RunBrokerCohortResolver {
    public static func resolve(
        brokerExecutableURL: URL,
        expectedUserID: UInt32 = getuid()
    ) throws -> RunBrokerInstalledCohort {
        let broker = brokerExecutableURL.resolvingSymlinksInPath().standardizedFileURL
        guard broker.lastPathComponent == RunBrokerCohort.brokerExecutableName else {
            throw RunBrokerInstallationError.installedCohortIncomplete
        }
        let directory = broker.deletingLastPathComponent()
        try validateDirectory(directory, expectedUserID: expectedUserID)
        let supervisor = directory.appendingPathComponent(
            RunBrokerCohort.supervisorExecutableName,
            isDirectory: false
        )
        try validateExecutable(broker, expectedUserID: expectedUserID)
        try validateExecutable(supervisor, expectedUserID: expectedUserID)
        return .init(brokerExecutableURL: broker, supervisorExecutableURL: supervisor)
    }

    private static func validateDirectory(_ url: URL, expectedUserID: UInt32) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == expectedUserID,
              UInt16(info.st_mode & 0o777) == 0o700 else {
            throw RunBrokerInstallationError.installedCohortIncomplete
        }
    }

    private static func validateExecutable(_ url: URL, expectedUserID: UInt32) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == expectedUserID,
              UInt16(info.st_mode & 0o777) == 0o700,
              info.st_nlink == 1 else {
            throw RunBrokerInstallationError.installedCohortIncomplete
        }
    }
}
