import Darwin
import Foundation

package enum RunSupervisorSpoolFileIO {
    private static let filename = "events.spool"

    static func openSpool(
        in directory: RunSupervisorRunDirectory,
        createIfMissing: Bool
    ) throws -> (fileDescriptor: Int32, wasCreated: Bool) {
        let baseFlags = O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW
        var wasCreated = false
        let fd: Int32
        if createIfMissing {
            let created = openat(
                directory.fileDescriptor,
                filename,
                baseFlags | O_CREAT | O_EXCL,
                0o600
            )
            if created >= 0 {
                fd = created
                wasCreated = true
            } else if errno == EEXIST {
                fd = openat(directory.fileDescriptor, filename, baseFlags)
            } else {
                fd = created
            }
        } else {
            fd = openat(directory.fileDescriptor, filename, baseFlags)
        }
        if fd < 0, errno == ENOENT {
            throw RunSupervisorError.corruptCommittedSpool
        }
        guard fd >= 0 else { throw RunSupervisorError.unsafeFilesystemEntry(filename) }
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & 0o077) == 0,
              status.st_nlink == 1 else {
            close(fd)
            throw RunSupervisorError.unsafeFilesystemEntry(filename)
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw RunSupervisorError.alreadyRunningOrInDoubt
        }
        return (fd, wasCreated)
    }

    static func quarantineTail(
        fileDescriptor: Int32,
        directory: RunSupervisorRunDirectory,
        offset: Int,
        byteCount: Int
    ) throws {
        let evidence = try RunSupervisorSpoolFrameCodec.preadExactly(
            byteCount,
            from: fileDescriptor,
            offset: offset
        )
        let name = "events-tail-\(UUID().uuidString.lowercased()).quarantine"
        let fd = openat(
            directory.fileDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else { throw RunSupervisorError.systemCall("open spool quarantine", errno) }
        defer { close(fd) }
        try writeAll(evidence, to: fd)
        guard fsync(fd) == 0 else {
            throw RunSupervisorError.systemCall("fsync spool quarantine", errno)
        }
    }

    static func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let result = data.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw RunSupervisorError.systemCall("write event spool", errno)
            }
            if result == 0 { throw RunSupervisorError.systemCall("write event spool", EIO) }
            offset += result
        }
    }
}
