import Foundation
import RunBrokerClient
import Darwin
import ASTRACore

public enum RunBrokerSecureFileError: Error, Equatable, Sendable {
    case unsafePath(String)
    case wrongOwner(expected: UInt32, actual: UInt32)
    case wrongPermissions(expected: UInt16, actual: UInt16)
    case notRegularFile
    case invalidInstallationID
    case systemCall(operation: String, code: Int32)
}

public struct RunBrokerInstallationSecrets: Equatable, Sendable {
    public let installationID: RunBrokerInstallationID
    public let capabilitySecret: RunBrokerCapabilitySecret

    public init(
        installationID: RunBrokerInstallationID,
        capabilitySecret: RunBrokerCapabilitySecret
    ) {
        self.installationID = installationID
        self.capabilitySecret = capabilitySecret
    }
}

public struct RunBrokerSecureStore: Sendable {
    private static let installationIDMaximumByteCount = 64

    private let expectedUserID: UInt32
    private let random: any RunBrokerRandomGenerating

    public init(
        expectedUserID: UInt32 = getuid(),
        random: any RunBrokerRandomGenerating = SystemRunBrokerRandomGenerator()
    ) {
        self.expectedUserID = expectedUserID
        self.random = random
    }

    public func loadOrCreate(identity: RunBrokerChannelIdentity) throws -> RunBrokerInstallationSecrets {
        try ensurePrivateDirectory(identity.supportDirectory)
        try ensurePrivateDirectory(identity.authenticationDirectory)

        let installationID: RunBrokerInstallationID
        if fileExistsWithoutFollowingSymlink(identity.installationIDURL) {
            let data = try readPrivateFile(
                identity.installationIDURL,
                maximumByteCount: Self.installationIDMaximumByteCount
            )
            guard let text = String(data: data, encoding: .utf8),
                  text.last == "\n",
                  let uuid = UUID(uuidString: String(text.dropLast())),
                  text == uuid.uuidString + "\n" else {
                throw RunBrokerSecureFileError.invalidInstallationID
            }
            installationID = RunBrokerInstallationID(rawValue: uuid)
        } else {
            installationID = RunBrokerInstallationID()
            try createPrivateFile(
                Data((installationID.rawValue.uuidString + "\n").utf8),
                at: identity.installationIDURL
            )
        }

        let capabilitySecret: RunBrokerCapabilitySecret
        if fileExistsWithoutFollowingSymlink(identity.capabilitySecretURL) {
            capabilitySecret = try RunBrokerCapabilitySecret(
                bytes: readPrivateFile(identity.capabilitySecretURL)
            )
        } else {
            let bytes = try random.randomBytes(
                count: RunBrokerAuthenticationPolicy.secretByteCount
            )
            capabilitySecret = try RunBrokerCapabilitySecret(bytes: bytes)
            try createPrivateFile(bytes, at: identity.capabilitySecretURL)
        }

        return .init(installationID: installationID, capabilitySecret: capabilitySecret)
    }

    public func readPrivateFile(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RunBrokerSecureFileError.systemCall(operation: "open", code: errno)
        }
        defer { close(descriptor) }
        try validateFileDescriptor(descriptor, expectedMode: 0o600)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }

    private func readPrivateFile(_ url: URL, maximumByteCount: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RunBrokerSecureFileError.systemCall(operation: "open", code: errno)
        }
        defer { close(descriptor) }
        try validateFileDescriptor(descriptor, expectedMode: 0o600)

        var initial = stat()
        guard fstat(descriptor, &initial) == 0 else {
            throw RunBrokerSecureFileError.systemCall(operation: "fstat", code: errno)
        }
        guard initial.st_size >= 0,
              initial.st_size <= maximumByteCount else {
            throw RunBrokerSecureFileError.invalidInstallationID
        }

        let count = Int(initial.st_size)
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    count - offset
                )
            }
            if readCount < 0, errno == EINTR { continue }
            guard readCount > 0 else {
                throw RunBrokerSecureFileError.systemCall(operation: "read", code: errno)
            }
            offset += readCount
        }

        var final = stat()
        guard fstat(descriptor, &final) == 0 else {
            throw RunBrokerSecureFileError.systemCall(operation: "fstat", code: errno)
        }
        guard final.st_dev == initial.st_dev,
              final.st_ino == initial.st_ino,
              final.st_size == initial.st_size else {
            throw RunBrokerSecureFileError.invalidInstallationID
        }
        return data
    }

    public func ensurePrivateDirectory(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path, !FileManager.default.fileExists(atPath: parent.path) {
            try ensurePrivateDirectory(parent)
        }
        if parent.path != url.path {
            var parentInfo = stat()
            guard lstat(parent.path, &parentInfo) == 0,
                  (parentInfo.st_mode & S_IFMT) == S_IFDIR,
                  parentInfo.st_uid == expectedUserID else {
                throw RunBrokerSecureFileError.unsafePath(parent.path)
            }
        }

        if mkdir(url.path, 0o700) != 0, errno != EEXIST {
            throw RunBrokerSecureFileError.systemCall(operation: "mkdir", code: errno)
        }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw RunBrokerSecureFileError.systemCall(operation: "lstat", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw RunBrokerSecureFileError.unsafePath(url.path)
        }
        guard info.st_uid == expectedUserID else {
            throw RunBrokerSecureFileError.wrongOwner(
                expected: expectedUserID,
                actual: info.st_uid
            )
        }
        let mode = UInt16(info.st_mode & 0o777)
        guard mode == 0o700 else {
            throw RunBrokerSecureFileError.wrongPermissions(expected: 0o700, actual: mode)
        }
    }

    public func createPrivateFile(_ data: Data, at url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw RunBrokerSecureFileError.systemCall(operation: "open-create", code: errno)
        }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { unlink(url.path) }
        }
        try validateFileDescriptor(descriptor, expectedMode: 0o600)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw RunBrokerSecureFileError.systemCall(operation: "write", code: errno)
                }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw RunBrokerSecureFileError.systemCall(operation: "fsync", code: errno)
        }
        shouldRemove = false
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private func validateFileDescriptor(_ descriptor: Int32, expectedMode: UInt16) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw RunBrokerSecureFileError.systemCall(operation: "fstat", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw RunBrokerSecureFileError.notRegularFile
        }
        guard info.st_uid == expectedUserID else {
            throw RunBrokerSecureFileError.wrongOwner(
                expected: expectedUserID,
                actual: info.st_uid
            )
        }
        let mode = UInt16(info.st_mode & 0o777)
        guard mode == expectedMode else {
            throw RunBrokerSecureFileError.wrongPermissions(
                expected: expectedMode,
                actual: mode
            )
        }
    }

    private func fileExistsWithoutFollowingSymlink(_ url: URL) -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            return true
        }
        return false
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RunBrokerSecureFileError.systemCall(operation: "open-directory", code: errno)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw RunBrokerSecureFileError.systemCall(operation: "fsync-directory", code: errno)
        }
    }
}
