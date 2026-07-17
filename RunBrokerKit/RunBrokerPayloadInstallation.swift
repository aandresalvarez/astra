import Foundation
import CryptoKit
import Darwin

extension RunBrokerInstaller {
    public static func sha256(of url: URL) throws -> RunBrokerSHA256Digest {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RunBrokerInstallationError.systemCall(operation: "open-digest", code: errno)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw RunBrokerInstallationError.systemCall(operation: "fstat-digest", code: errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw RunBrokerInstallationError.sourceIsNotRegularExecutable
        }
        return try sha256(descriptor: descriptor)
    }

    private static func sha256(descriptor: Int32) throws -> RunBrokerSHA256Digest {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return try RunBrokerSHA256Digest(
            rawValue: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    func validateSource(_ payload: RunBrokerPayload) throws {
        let descriptor = open(
            payload.sourceExecutableURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw RunBrokerInstallationError.sourceIsNotRegularExecutable
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o111) != 0 else {
            throw RunBrokerInstallationError.sourceIsNotRegularExecutable
        }
        guard try Self.sha256(descriptor: descriptor) == payload.expectedSHA256 else {
            throw RunBrokerInstallationError.sourceDigestMismatch
        }
    }

    func stagePayloadIfNeeded(
        _ payload: RunBrokerPayload,
        destinationDirectory: URL,
        destinationExecutable: URL
    ) throws {
        var destinationInfo = stat()
        if lstat(destinationDirectory.path, &destinationInfo) == 0 {
            guard (destinationInfo.st_mode & S_IFMT) == S_IFDIR,
                  destinationInfo.st_uid == userID,
                  UInt16(destinationInfo.st_mode & 0o777) == 0o700 else {
                throw RunBrokerInstallationError.unsafeExistingPayload
            }
            var executableInfo = stat()
            guard lstat(destinationExecutable.path, &executableInfo) == 0,
                  (executableInfo.st_mode & S_IFMT) == S_IFREG,
                  executableInfo.st_uid == userID,
                  UInt16(executableInfo.st_mode & 0o777) == 0o700 else {
                throw RunBrokerInstallationError.unsafeExistingPayload
            }
            guard try Self.sha256(of: destinationExecutable) == payload.expectedSHA256 else {
                throw RunBrokerInstallationError.installedDigestMismatch
            }
            return
        } else if errno != ENOENT {
            throw RunBrokerInstallationError.systemCall(operation: "lstat-version", code: errno)
        }

        let staging = identitySafeStagingURL(
            beside: destinationDirectory,
            identifier: stagingIdentifier()
        )
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        let stagedExecutable = staging.appendingPathComponent("astra-run-broker")
        try copyExecutableNoFollow(from: payload.sourceExecutableURL, to: stagedExecutable)
        guard try Self.sha256(of: stagedExecutable) == payload.expectedSHA256 else {
            throw RunBrokerInstallationError.installedDigestMismatch
        }
        try fileManager.moveItem(at: staging, to: destinationDirectory)
    }

    private func copyExecutableNoFollow(from source: URL, to destination: URL) throws {
        let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw RunBrokerInstallationError.sourceIsNotRegularExecutable
        }
        defer { close(sourceDescriptor) }
        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFREG,
              (sourceInfo.st_mode & 0o111) != 0 else {
            throw RunBrokerInstallationError.sourceIsNotRegularExecutable
        }

        let destinationDescriptor = open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o700
        )
        guard destinationDescriptor >= 0 else {
            throw RunBrokerInstallationError.systemCall(operation: "open-staged", code: errno)
        }
        var removeDestination = true
        defer {
            close(destinationDescriptor)
            if removeDestination { unlink(destination.path) }
        }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(sourceDescriptor, bytes.baseAddress!, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw RunBrokerInstallationError.systemCall(operation: "read-source", code: errno)
            }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destinationDescriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        count - offset
                    )
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw RunBrokerInstallationError.systemCall(
                        operation: "write-staged",
                        code: errno
                    )
                }
                offset += written
            }
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw RunBrokerInstallationError.systemCall(operation: "fsync-staged", code: errno)
        }
        removeDestination = false
    }

    private func identitySafeStagingURL(beside destination: URL, identifier: String) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".installing-\(identifier)",
            isDirectory: true
        )
    }
}
