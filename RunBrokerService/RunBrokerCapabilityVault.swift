import ASTRACore
import Darwin
import Foundation
import RunSupervisorSupport

public struct DarwinRunBrokerCapabilityVault: RunBrokerCapabilityVaulting, Sendable {
    private struct PersistedRecord: Codable {
        let schemaVersion: Int
        let identity: RunSupervisorIdentity
        let manifestSHA256: ExecutionLaunchArgumentsSHA256
        let capability: RunSupervisorCapability
        let launchMaterialAuthenticator: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion, identity, manifestSHA256, capability, launchMaterialAuthenticator
        }

        init(
            schemaVersion: Int,
            identity: RunSupervisorIdentity,
            manifestSHA256: ExecutionLaunchArgumentsSHA256,
            capability: RunSupervisorCapability,
            launchMaterialAuthenticator: String?
        ) {
            self.schemaVersion = schemaVersion
            self.identity = identity
            self.manifestSHA256 = manifestSHA256
            self.capability = capability
            self.launchMaterialAuthenticator = launchMaterialAuthenticator
        }

        init(from decoder: Decoder) throws {
            let keys = try decoder.container(keyedBy: CapabilityCodingKey.self).allKeys
            let allowed = Set(CodingKeys.allCases.map(\.stringValue))
            guard keys.allSatisfy({ allowed.contains($0.stringValue) }) else {
                throw RunBrokerServiceError.capabilityIdentityMismatch
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == 1 || schemaVersion == 2 else {
                throw RunBrokerServiceError.capabilityIdentityMismatch
            }
            identity = try container.decode(RunSupervisorIdentity.self, forKey: .identity)
            manifestSHA256 = try container.decode(
                ExecutionLaunchArgumentsSHA256.self,
                forKey: .manifestSHA256
            )
            capability = try container.decode(RunSupervisorCapability.self, forKey: .capability)
            launchMaterialAuthenticator = try container.decodeIfPresent(
                String.self,
                forKey: .launchMaterialAuthenticator
            )
            if let launchMaterialAuthenticator {
                let allowed = CharacterSet(charactersIn: "0123456789abcdef")
                guard launchMaterialAuthenticator.utf8.count == 64,
                      launchMaterialAuthenticator.unicodeScalars.allSatisfy(allowed.contains) else {
                    throw RunBrokerServiceError.capabilityIdentityMismatch
                }
            }
        }
    }

    private let directoryURL: URL
    private let expectedUserID: uid_t
    private let directorySynchronizer: @Sendable (URL) throws -> Void

    public init(directoryURL: URL, expectedUserID: uid_t = geteuid()) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.expectedUserID = expectedUserID
        self.directorySynchronizer = { try Self.synchronizeDirectory($0) }
    }

    init(
        directoryURL: URL,
        expectedUserID: uid_t = geteuid(),
        directorySynchronizer: @escaping @Sendable (URL) throws -> Void
    ) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.expectedUserID = expectedUserID
        self.directorySynchronizer = directorySynchronizer
    }

    public func persistAndSynchronize(_ record: RunBrokerCapabilityRecord) throws {
        try ensureDirectory()
        let destination = fileURL(for: record.identity.executionID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(PersistedRecord(
            schemaVersion: 2,
            identity: record.identity,
            manifestSHA256: record.manifestSHA256,
            capability: record.capability,
            launchMaterialAuthenticator: record.launchMaterialAuthenticator
        ))

        let temporary = directoryURL.appendingPathComponent(
            ".capability-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError("open capability temp") }
        var removeTemporary = true
        defer {
            close(fd)
            if removeTemporary { unlink(temporary.path) }
        }
        try validatePrivateRegularFile(fd)
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else { throw posixError("fsync capability") }
        guard renameatx_np(
            AT_FDCWD,
            temporary.path,
            AT_FDCWD,
            destination.path,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST {
                let existing = try load(executionID: record.identity.executionID)
                guard existing?.identity == record.identity,
                      existing?.manifestSHA256 == record.manifestSHA256,
                      existing?.capability == record.capability,
                      existing?.launchMaterialAuthenticator == record.launchMaterialAuthenticator else {
                    throw RunBrokerServiceError.capabilityIdentityMismatch
                }
                try directorySynchronizer(directoryURL)
                return
            }
            throw posixError("publish capability")
        }
        removeTemporary = false
        try directorySynchronizer(directoryURL)
    }

    public func load(executionID: RunBrokerExecutionID) throws -> RunBrokerCapabilityRecord? {
        let url = fileURL(for: executionID)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw posixError("open capability") }
        defer { close(fd) }
        try validatePrivateRegularFile(fd)
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size > 0, status.st_size <= 65_536 else {
            throw RunBrokerServiceError.capabilityIdentityMismatch
        }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let persisted = try decoder.decode(PersistedRecord.self, from: data)
        guard (persisted.schemaVersion == 1 || persisted.schemaVersion == 2),
              persisted.identity.executionID == executionID else {
            throw RunBrokerServiceError.capabilityIdentityMismatch
        }
        return .init(
            identity: persisted.identity,
            manifestSHA256: persisted.manifestSHA256,
            capability: persisted.capability,
            launchMaterialAuthenticator: persisted.launchMaterialAuthenticator
        )
    }

    private func fileURL(for executionID: RunBrokerExecutionID) -> URL {
        directoryURL.appendingPathComponent(
            "execution-\(executionID.rawValue.uuidString.lowercased()).capability",
            isDirectory: false
        )
    }

    private func ensureDirectory() throws {
        if mkdir(directoryURL.path, 0o700) != 0, errno != EEXIST {
            throw posixError("mkdir capability vault")
        }
        let fd = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError("open capability vault") }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == expectedUserID,
              UInt16(status.st_mode & 0o777) == 0o700 else {
            throw RunBrokerServiceError.capabilityIdentityMismatch
        }
    }

    private func validatePrivateRegularFile(_ fd: Int32) throws {
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == expectedUserID,
              UInt16(status.st_mode & 0o777) == 0o600,
              status.st_nlink == 1 else {
            throw RunBrokerServiceError.capabilityIdentityMismatch
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let result = data.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw posixError("write capability") }
            offset += result
        }
    }

    private static func synchronizeDirectory(_ directoryURL: URL) throws {
        let fd = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw synchronizationError("open capability directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw synchronizationError("fsync capability directory") }
    }

    private static func synchronizationError(_ operation: String) -> NSError {
        NSError(
            domain: "RunBrokerCapabilityVault",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed"]
        )
    }

    private func posixError(_ operation: String) -> NSError {
        NSError(
            domain: "RunBrokerCapabilityVault",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed"]
        )
    }
}

private struct CapabilityCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}
