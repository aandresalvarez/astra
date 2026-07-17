import Foundation
import Darwin

/// Cross-process serialization for one channel's complete installation
/// transaction. The descriptor remains open and exclusively locked until
/// `release()` or deinitialization.
final class RunBrokerInstallationTransactionLock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL, expectedUserID: UInt32) throws -> Self {
        let descriptor = open(
            url.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw RunBrokerInstallationError.systemCall(
                operation: "open-installer-lock",
                code: errno
            )
        }
        do {
            try validate(
                descriptor: descriptor,
                path: url.path,
                expectedUserID: expectedUserID
            )
            while flock(descriptor, LOCK_EX) != 0 {
                guard errno == EINTR else {
                    throw RunBrokerInstallationError.systemCall(
                        operation: "flock-installer-lock",
                        code: errno
                    )
                }
            }
            // Revalidate after a potentially long wait. Normal installers do
            // not replace the lock file; a changed pathname must fail closed
            // so later processes cannot split onto a different inode.
            try validate(
                descriptor: descriptor,
                path: url.path,
                expectedUserID: expectedUserID
            )
            return Self(descriptor: descriptor)
        } catch {
            close(descriptor)
            throw error
        }
    }

    func release() {
        stateLock.lock()
        let descriptor = self.descriptor
        self.descriptor = -1
        stateLock.unlock()
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    deinit { release() }

    private static func validate(
        descriptor: Int32,
        path: String,
        expectedUserID: UInt32
    ) throws {
        var descriptorInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0 else {
            throw RunBrokerInstallationError.systemCall(
                operation: "fstat-installer-lock",
                code: errno
            )
        }
        guard (descriptorInfo.st_mode & S_IFMT) == S_IFREG,
              descriptorInfo.st_uid == expectedUserID,
              UInt16(descriptorInfo.st_mode & 0o777) == 0o600,
              descriptorInfo.st_nlink == 1 else {
            throw RunBrokerInstallationError.unsafeInstallerLock
        }

        var pathInfo = stat()
        guard lstat(path, &pathInfo) == 0,
              (pathInfo.st_mode & S_IFMT) == S_IFREG,
              pathInfo.st_uid == expectedUserID,
              UInt16(pathInfo.st_mode & 0o777) == 0o600,
              pathInfo.st_nlink == 1,
              pathInfo.st_dev == descriptorInfo.st_dev,
              pathInfo.st_ino == descriptorInfo.st_ino else {
            throw RunBrokerInstallationError.unsafeInstallerLock
        }
    }
}
