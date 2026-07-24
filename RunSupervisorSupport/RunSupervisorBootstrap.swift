import ASTRACore
import Darwin
import Foundation

public struct RunSupervisorBootstrapPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let protocolVersion: UInt16
    public let manifest: ExecutionLaunchManifest
    public let manifestSHA256: ExecutionLaunchArgumentsSHA256
    public let expectedIdentity: RunSupervisorIdentity
    public let arguments: [String]
    public let environment: [String: String]
    public let capability: RunSupervisorCapability

    public init(
        protocolVersion: UInt16 = RunSupervisorProtocol.maximumVersion,
        manifest: ExecutionLaunchManifest,
        manifestSHA256: ExecutionLaunchArgumentsSHA256,
        expectedIdentity: RunSupervisorIdentity,
        arguments: [String],
        environment: [String: String],
        capability: RunSupervisorCapability
    ) {
        self.schemaVersion = 1
        self.protocolVersion = protocolVersion
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
        self.expectedIdentity = expectedIdentity
        self.arguments = arguments
        self.environment = environment
        self.capability = capability
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, protocolVersion, manifest, manifestSHA256, expectedIdentity
        case arguments, environment, capability
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeyNames(Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == 1 else { throw RunSupervisorError.invalidSchema }
        self.schemaVersion = schemaVersion
        self.protocolVersion = try container.decode(UInt16.self, forKey: .protocolVersion)
        self.manifest = try container.decode(ExecutionLaunchManifest.self, forKey: .manifest)
        self.manifestSHA256 = try container.decode(ExecutionLaunchArgumentsSHA256.self, forKey: .manifestSHA256)
        self.expectedIdentity = try container.decode(RunSupervisorIdentity.self, forKey: .expectedIdentity)
        self.arguments = try container.decode([String].self, forKey: .arguments)
        self.environment = try container.decode([String: String].self, forKey: .environment)
        self.capability = try container.decode(RunSupervisorCapability.self, forKey: .capability)
    }
}

public enum RunSupervisorBootstrapValidator {
    public static func validate(_ payload: RunSupervisorBootstrapPayload) throws {
        guard payload.protocolVersion >= RunSupervisorProtocol.minimumVersion,
              payload.protocolVersion <= RunSupervisorProtocol.maximumVersion else {
            throw RunSupervisorError.unsupportedProtocol(payload.protocolVersion)
        }
        guard payload.expectedIdentity == RunSupervisorIdentity(manifest: payload.manifest),
              payload.manifest.authority.epoch.rawValue > 0 else {
            throw RunSupervisorError.invalidIdentity
        }
        guard try RunSupervisorDigests.manifest(payload.manifest) == payload.manifestSHA256 else {
            throw RunSupervisorError.invalidManifestDigest
        }
        let argumentSummary = payload.manifest.configuration.launchArguments
        if payload.arguments.isEmpty {
            guard argumentSummary == .none else { throw RunSupervisorError.invalidArgumentDigest }
        } else {
            guard argumentSummary.argumentCount == UInt(payload.arguments.count),
                  let expected = argumentSummary.argumentsSHA256,
                  try RunSupervisorDigests.arguments(payload.arguments) == expected else {
                throw RunSupervisorError.invalidArgumentDigest
            }
        }
        guard payload.arguments.count <= 4_096,
              payload.arguments.allSatisfy({ $0.utf8.count <= 65_536 }),
              payload.environment.count <= 1_024,
              payload.environment.allSatisfy({
                  $0.key.utf8.count <= 1_024 && $0.value.utf8.count <= 262_144
              }) else {
            throw RunSupervisorError.oversizedFrame(limit: RunSupervisorProtocol.maximumBootstrapBytes)
        }
        guard payload.arguments.allSatisfy({ !$0.utf8.contains(0) }),
              payload.environment.allSatisfy({
                  !$0.key.isEmpty
                      && !$0.key.contains("=")
                      && !$0.key.utf8.contains(0)
                      && !$0.value.utf8.contains(0)
              }) else {
            throw RunSupervisorError.invalidSchema
        }
        let declaredEnvironmentNames = payload.manifest.configuration.environmentVariableNames
        guard declaredEnvironmentNames.count == Set(declaredEnvironmentNames).count,
              payload.environment.count == declaredEnvironmentNames.count,
              Set(payload.environment.keys) == Set(declaredEnvironmentNames) else {
            throw RunSupervisorError.invalidEnvironmentNames
        }
        guard payload.manifest.configuration.executablePath.hasPrefix("/"),
              payload.manifest.configuration.workingDirectory.hasPrefix("/"),
              !payload.manifest.configuration.executablePath.utf8.contains(0),
              !payload.manifest.configuration.workingDirectory.utf8.contains(0) else {
            throw RunSupervisorError.invalidSchema
        }
    }
}

public enum RunSupervisorFrameIO {
    public static func readFrame(
        from fileDescriptor: Int32,
        maximumBytes: Int
    ) throws -> Data {
        let header = try readExactly(4, from: fileDescriptor)
        let length = header.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard length > 0, Int(length) <= maximumBytes else {
            throw RunSupervisorError.oversizedFrame(limit: maximumBytes)
        }
        return try readExactly(Int(length), from: fileDescriptor)
    }

    public static func writeFrame(_ data: Data, to fileDescriptor: Int32, maximumBytes: Int) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw RunSupervisorError.oversizedFrame(limit: maximumBytes)
        }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll(Data($0), to: fileDescriptor) }
        try writeAll(data, to: fileDescriptor)
    }

    private static func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            let readCount = result.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if readCount == 0 { throw RunSupervisorError.truncatedFrame }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw RunSupervisorError.systemCall("read", errno)
            }
            offset += readCount
        }
        return result
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let wrote = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if wrote < 0 {
                if errno == EINTR { continue }
                throw RunSupervisorError.systemCall("write", errno)
            }
            if wrote == 0 { throw RunSupervisorError.systemCall("write", EIO) }
            offset += wrote
        }
    }
}

public final class RunSupervisorTrustedRoot: @unchecked Sendable {
    public let fileDescriptor: Int32
    public let path: String

    public init(fileDescriptor: Int32) throws {
        let duplicate = fcntl(fileDescriptor, F_DUPFD_CLOEXEC, 64)
        guard duplicate >= 0 else { throw RunSupervisorError.systemCall("fcntl(F_DUPFD_CLOEXEC)", errno) }
        do {
            try Self.validateDirectory(duplicate)
            self.fileDescriptor = duplicate
            self.path = try Self.path(for: duplicate)
        } catch {
            close(duplicate)
            throw error
        }
    }

    public convenience init(path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw RunSupervisorError.systemCall("open trusted root", errno) }
        defer { close(fd) }
        try self.init(fileDescriptor: fd)
    }

    deinit { close(fileDescriptor) }

    public func acquireExecutionDirectory(
        _ executionID: RunBrokerExecutionID
    ) throws -> RunSupervisorRunDirectoryAcquisition {
        let name = "execution-\(executionID.rawValue.uuidString.lowercased())"
        let created: Bool
        if mkdirat(fileDescriptor, name, 0o700) == 0 {
            created = true
        } else if errno == EEXIST {
            created = false
        } else {
            throw RunSupervisorError.systemCall("mkdirat execution directory", errno)
        }
        let fd = openat(fileDescriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw RunSupervisorError.unsafeFilesystemEntry(name) }
        do {
            try Self.validateDirectory(fd)
            return try RunSupervisorRunDirectoryAcquisition(
                directory: .init(fileDescriptor: fd, path: Self.path(for: fd)),
                wasCreated: created
            )
        } catch {
            close(fd)
            throw error
        }
    }

    public func openExecutionDirectory(_ executionID: RunBrokerExecutionID) throws -> RunSupervisorRunDirectory {
        let name = "execution-\(executionID.rawValue.uuidString.lowercased())"
        let fd = openat(fileDescriptor, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw RunSupervisorError.systemCall(Self.openExecutionDirectoryOperation, errno)
        }
        do {
            try Self.validateDirectory(fd)
            return .init(fileDescriptor: fd, path: try Self.path(for: fd))
        } catch {
            close(fd)
            throw error
        }
    }

    private static let openExecutionDirectoryOperation = "openat execution directory"

    /// True exactly when `error` is the typed signal thrown by
    /// `openExecutionDirectory` because the execution directory does not
    /// exist. This distinguishes supervisor absence (no directory was ever
    /// created, or spawn has not progressed that far yet) from
    /// authentication, tamper, and I/O failures, which never match.
    public static func isExecutionDirectoryAbsence(_ error: Error) -> Bool {
        guard case RunSupervisorError.systemCall(let operation, let code) = error else {
            return false
        }
        return operation == openExecutionDirectoryOperation && code == ENOENT
    }

    private static func validateDirectory(_ fd: Int32) throws {
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid(),
              (status.st_mode & 0o077) == 0,
              status.st_nlink >= 2 else {
            throw RunSupervisorError.untrustedRoot
        }
    }

    private static func path(for fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else {
            throw RunSupervisorError.systemCall("fcntl(F_GETPATH)", errno)
        }
        return String(cString: buffer)
    }
}

public struct RunSupervisorRunDirectoryAcquisition: Sendable {
    public let directory: RunSupervisorRunDirectory
    public let wasCreated: Bool

    public init(directory: RunSupervisorRunDirectory, wasCreated: Bool) {
        self.directory = directory
        self.wasCreated = wasCreated
    }
}

public final class RunSupervisorRunDirectory: @unchecked Sendable {
    public let fileDescriptor: Int32
    public let path: String

    package init(fileDescriptor: Int32, path: String) {
        self.fileDescriptor = fileDescriptor
        self.path = path
    }

    deinit { close(fileDescriptor) }
}
