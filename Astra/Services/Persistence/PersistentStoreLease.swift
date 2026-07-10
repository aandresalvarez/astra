import Darwin
import Foundation

/// A kernel-backed, process-lifetime lease for a channel's mutable SwiftData
/// store. The lock is advisory, so every current ASTRA writer must acquire it
/// before opening a writable store or changing the active-store pointer.
///
/// The file contents are diagnostic only. Ownership is the `flock` held on the
/// file descriptor, which the kernel releases if the owning process exits.
public final class PersistentStoreLease {
    public enum AcquisitionError: Error, Equatable {
        case alreadyOwned
        case couldNotOpen(errno: Int32)
        case couldNotLock(errno: Int32)
    }

    public struct OwnerMetadata: Codable, Equatable, Sendable {
        public let processID: Int32
        public let executablePath: String
        public let channel: String
        public let version: String
        public let build: String
        public let acquiredAt: Date

        public init(
            processID: Int32 = getpid(),
            executablePath: String = ProcessInfo.processInfo.arguments.first ?? "unknown",
            channel: String,
            version: String,
            build: String,
            acquiredAt: Date = Date()
        ) {
            self.processID = processID
            self.executablePath = executablePath
            self.channel = channel
            self.version = version
            self.build = build
            self.acquiredAt = acquiredAt
        }
    }

    public let lockURL: URL
    public let owner: OwnerMetadata
    private var fileDescriptor: Int32
    private let ownershipKey: String
    private static let registryLock = NSLock()
    private static var inProcessOwnershipKeys = Set<String>()

    private init(lockURL: URL, owner: OwnerMetadata, fileDescriptor: Int32) {
        self.lockURL = lockURL
        self.owner = owner
        self.fileDescriptor = fileDescriptor
        self.ownershipKey = lockURL.standardizedFileURL.path
    }

    deinit {
        release()
    }

    public static func acquire(
        at lockURL: URL,
        owner: OwnerMetadata,
        fileManager: FileManager = .default
    ) throws -> PersistentStoreLease {
        try fileManager.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let ownershipKey = lockURL.standardizedFileURL.path
        registryLock.lock()
        let registered = inProcessOwnershipKeys.insert(ownershipKey).inserted
        registryLock.unlock()
        guard registered else {
            throw AcquisitionError.alreadyOwned
        }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            unregister(ownershipKey)
            throw AcquisitionError.couldNotOpen(errno: errno)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            unregister(ownershipKey)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw AcquisitionError.alreadyOwned
            }
            throw AcquisitionError.couldNotLock(errno: lockError)
        }

        let lease = PersistentStoreLease(lockURL: lockURL, owner: owner, fileDescriptor: descriptor)
        do {
            try lease.writeOwnerMetadata()
            return lease
        } catch {
            lease.release()
            throw error
        }
    }

    public static func recordedOwner(at lockURL: URL) -> OwnerMetadata? {
        guard let data = try? Data(contentsOf: lockURL) else { return nil }
        return try? JSONDecoder().decode(OwnerMetadata.self, from: data)
    }

    public func release() {
        guard fileDescriptor >= 0 else { return }
        _ = flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
        fileDescriptor = -1
        Self.unregister(ownershipKey)
    }

    private func writeOwnerMetadata() throws {
        let data = try JSONEncoder().encode(owner)
        guard ftruncate(fileDescriptor, 0) == 0 else {
            throw AcquisitionError.couldNotLock(errno: errno)
        }
        let bytesWritten = data.withUnsafeBytes { buffer in
            write(fileDescriptor, buffer.baseAddress, buffer.count)
        }
        guard bytesWritten == data.count else {
            throw AcquisitionError.couldNotLock(errno: errno)
        }
        _ = fsync(fileDescriptor)
    }

    private static func unregister(_ ownershipKey: String) {
        registryLock.lock()
        inProcessOwnershipKeys.remove(ownershipKey)
        registryLock.unlock()
    }
}
