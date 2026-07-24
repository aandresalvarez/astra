import ASTRACore
import Darwin
import Foundation

public struct RunSupervisorDiscoveryRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let protocolMinimumVersion: UInt16
    public let protocolMaximumVersion: UInt16
    public let identity: RunSupervisorIdentity
    public let manifestSHA256: ExecutionLaunchArgumentsSHA256
    public let launchAuthenticator: String
    public let capabilitySHA256: ExecutionLaunchArgumentsSHA256
    public let socketName: String
    public let supervisorPIDDiagnostic: Int32?
    public let providerPIDDiagnostic: Int32?
    public let createdAt: Date

    public init(
        identity: RunSupervisorIdentity,
        manifestSHA256: ExecutionLaunchArgumentsSHA256,
        launchAuthenticator: String,
        capabilitySHA256: ExecutionLaunchArgumentsSHA256,
        socketName: String = "control.sock",
        supervisorPIDDiagnostic: Int32? = nil,
        providerPIDDiagnostic: Int32? = nil,
        createdAt: Date
    ) {
        self.schemaVersion = 1
        self.protocolMinimumVersion = RunSupervisorProtocol.minimumVersion
        self.protocolMaximumVersion = RunSupervisorProtocol.maximumVersion
        self.identity = identity
        self.manifestSHA256 = manifestSHA256
        self.launchAuthenticator = launchAuthenticator
        self.capabilitySHA256 = capabilitySHA256
        self.socketName = socketName
        self.supervisorPIDDiagnostic = supervisorPIDDiagnostic
        self.providerPIDDiagnostic = providerPIDDiagnostic
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, protocolMinimumVersion, protocolMaximumVersion, identity
        case manifestSHA256, launchAuthenticator, capabilitySHA256, socketName
        case supervisorPIDDiagnostic, providerPIDDiagnostic, createdAt
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeyNames(Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw RunSupervisorError.invalidSchema
        }
        schemaVersion = 1
        protocolMinimumVersion = try container.decode(UInt16.self, forKey: .protocolMinimumVersion)
        protocolMaximumVersion = try container.decode(UInt16.self, forKey: .protocolMaximumVersion)
        identity = try container.decode(RunSupervisorIdentity.self, forKey: .identity)
        manifestSHA256 = try container.decode(ExecutionLaunchArgumentsSHA256.self, forKey: .manifestSHA256)
        launchAuthenticator = try container.decode(String.self, forKey: .launchAuthenticator)
        capabilitySHA256 = try container.decode(ExecutionLaunchArgumentsSHA256.self, forKey: .capabilitySHA256)
        socketName = try container.decode(String.self, forKey: .socketName)
        supervisorPIDDiagnostic = try container.decodeIfPresent(Int32.self, forKey: .supervisorPIDDiagnostic)
        providerPIDDiagnostic = try container.decodeIfPresent(Int32.self, forKey: .providerPIDDiagnostic)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        guard launchAuthenticator.utf8.count == 64,
              socketName == "control.sock",
              protocolMinimumVersion <= protocolMaximumVersion else {
            throw RunSupervisorError.invalidSchema
        }
    }
}

public protocol RunSupervisorFileSystem: Sendable {
    func readDiscovery(in directory: RunSupervisorRunDirectory) throws -> RunSupervisorDiscoveryRecord?
    func writeDiscovery(_ record: RunSupervisorDiscoveryRecord, in directory: RunSupervisorRunDirectory) throws
    func removeControlSocket(in directory: RunSupervisorRunDirectory) throws
}

public struct DarwinRunSupervisorFileSystem: RunSupervisorFileSystem {
    private static let discoveryName = "supervisor.json"
    public init() {}

    public func readDiscovery(in directory: RunSupervisorRunDirectory) throws -> RunSupervisorDiscoveryRecord? {
        let fd = openat(directory.fileDescriptor, Self.discoveryName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw RunSupervisorError.unsafeFilesystemEntry(Self.discoveryName) }
        defer { close(fd) }
        try validateRegular(fd, name: Self.discoveryName)
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size <= 65_536 else {
            throw RunSupervisorError.oversizedFrame(limit: 65_536)
        }
        let data = try readAll(fd, count: Int(status.st_size))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(RunSupervisorDiscoveryRecord.self, from: data)
    }

    public func writeDiscovery(
        _ record: RunSupervisorDiscoveryRecord,
        in directory: RunSupervisorRunDirectory
    ) throws {
        let data = try RunSupervisorDigests.canonicalData(record)
        guard data.count <= 65_536 else { throw RunSupervisorError.oversizedFrame(limit: 65_536) }
        let tempName = ".supervisor-\(UUID().uuidString.lowercased()).tmp"
        let fd = openat(
            directory.fileDescriptor,
            tempName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else { throw RunSupervisorError.systemCall("open discovery temp", errno) }
        var succeeded = false
        defer {
            close(fd)
            if !succeeded { unlinkat(directory.fileDescriptor, tempName, 0) }
        }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else { throw RunSupervisorError.systemCall("fsync discovery", errno) }
        guard renameat(
            directory.fileDescriptor,
            tempName,
            directory.fileDescriptor,
            Self.discoveryName
        ) == 0 else {
            throw RunSupervisorError.systemCall("rename discovery", errno)
        }
        guard fsync(directory.fileDescriptor) == 0 else {
            throw RunSupervisorError.systemCall("fsync run directory", errno)
        }
        succeeded = true
    }

    public func removeControlSocket(in directory: RunSupervisorRunDirectory) throws {
        var status = stat()
        if fstatat(directory.fileDescriptor, "control.sock", &status, AT_SYMLINK_NOFOLLOW) == 0 {
            throw RunSupervisorError.unsafeFilesystemEntry("control.sock")
        }
        guard errno == ENOENT else {
            throw RunSupervisorError.systemCall("inspect control socket", errno)
        }
    }

    private func validateRegular(_ fd: Int32, name: String) throws {
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & 0o077) == 0,
              status.st_nlink == 1 else {
            throw RunSupervisorError.unsafeFilesystemEntry(name)
        }
    }

    private func readAll(_ fd: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let result = data.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset)
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw RunSupervisorError.truncatedFrame }
            offset += result
        }
        return data
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let result = data.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw RunSupervisorError.systemCall("write discovery", errno)
            }
            if result == 0 { throw RunSupervisorError.systemCall("write discovery", EIO) }
            offset += result
        }
    }
}

public enum RunSupervisorAdmissionDecision: Equatable, Sendable {
    case launchNew
    case existingLive
}

public protocol RunSupervisorLivenessProbing: Sendable {
    func authenticate(
        discovery: RunSupervisorDiscoveryRecord,
        directory: RunSupervisorRunDirectory,
        capability: RunSupervisorCapability
    ) -> Bool
}

public struct RunSupervisorAdmission {
    public static func decide(
        payload: RunSupervisorBootstrapPayload,
        existing: RunSupervisorDiscoveryRecord?,
        wasDirectoryCreated: Bool,
        authenticatedLiveness: Bool
    ) throws -> RunSupervisorAdmissionDecision {
        if wasDirectoryCreated {
            guard existing == nil else { throw RunSupervisorError.alreadyRunningOrInDoubt }
            return .launchNew
        }
        guard let existing else { throw RunSupervisorError.alreadyRunningOrInDoubt }
        let requested = payload.expectedIdentity
        guard existing.identity.installationID == requested.installationID,
              existing.identity.storeID == requested.storeID,
              existing.identity.executionID == requested.executionID else {
            throw RunSupervisorError.invalidIdentity
        }
        if requested.authority.epoch < existing.identity.authority.epoch {
            throw RunSupervisorError.staleAuthorityEpoch
        }
        guard requested.authority == existing.identity.authority else {
            throw RunSupervisorError.invalidIdentity
        }
        let launchAuthenticator = try RunSupervisorDigests.launchAuthenticator(
            payload: payload,
            capability: payload.capability
        )
        guard existing.manifestSHA256 == payload.manifestSHA256,
              existing.launchAuthenticator == launchAuthenticator,
              existing.capabilitySHA256 == (try RunSupervisorDigests.capability(payload.capability)) else {
            throw RunSupervisorError.launchPayloadConflict
        }
        guard authenticatedLiveness else { throw RunSupervisorError.alreadyRunningOrInDoubt }
        return .existingLive
    }
}
