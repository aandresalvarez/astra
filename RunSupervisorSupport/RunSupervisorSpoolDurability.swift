import Darwin
import Foundation

package enum RunSupervisorSpoolDurability {
    static let acknowledgementFilename = "events.ack"
    private static let authenticationFilename = "events.auth"
    private static let authenticationDomain = Data("astra.run-supervisor.spool-auth.v1\0".utf8)
    private static let acknowledgementDomain = Data("astra.run-supervisor.spool-ack.v1\0".utf8)

    static func ensureAuthenticationMarker(
        in directory: RunSupervisorRunDirectory,
        spoolFileDescriptor: Int32,
        capability: RunSupervisorCapability,
        allowCreation: Bool
    ) throws {
        let expected = RunSupervisorDigests.hmacBytes(authenticationDomain, capability: capability)
        let fd = openat(
            directory.fileDescriptor,
            authenticationFilename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if fd >= 0 {
            defer { close(fd) }
            try validateRegularEvidence(fd, expectedSize: 32)
            let persisted = try RunSupervisorSpoolFrameCodec.preadExactly(32, from: fd, offset: 0)
            guard RunSupervisorDigests.constantTimeEqual(expected, persisted) else {
                throw RunSupervisorError.corruptCommittedSpool
            }
            return
        }
        guard errno == ENOENT, allowCreation else {
            throw RunSupervisorError.corruptCommittedSpool
        }
        var spoolStatus = stat()
        guard fstat(spoolFileDescriptor, &spoolStatus) == 0,
              spoolStatus.st_size == 0 else {
            throw RunSupervisorError.corruptCommittedSpool
        }
        try persistAtomically(
            expected,
            finalName: authenticationFilename,
            temporaryPrefix: ".events-auth-",
            directory: directory
        )
    }

    static func persistAcknowledgement(
        _ sequence: UInt64,
        directory: RunSupervisorRunDirectory,
        capability: RunSupervisorCapability,
        faultInjector: any RunSupervisorSpoolFaultInjecting
    ) throws {
        var encodedSequence = sequence.bigEndian
        let sequenceData = withUnsafeBytes(of: &encodedSequence) { Data($0) }
        let data = sequenceData + RunSupervisorDigests.hmacBytes(
            acknowledgementDomain + sequenceData,
            capability: capability
        )
        let temporary = ".events-ack-\(UUID().uuidString.lowercased()).tmp"
        let fd = openat(
            directory.fileDescriptor,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else { throw RunSupervisorError.systemCall("open acknowledgement temp", errno) }
        var succeeded = false
        defer {
            close(fd)
            if !succeeded { unlinkat(directory.fileDescriptor, temporary, 0) }
        }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0 else {
            throw RunSupervisorError.systemCall("fsync acknowledgement", errno)
        }
        try faultInjector.checkpoint(.acknowledgementTemporarySynced)
        guard renameat(
            directory.fileDescriptor,
            temporary,
            directory.fileDescriptor,
            acknowledgementFilename
        ) == 0 else {
            throw RunSupervisorError.systemCall("rename acknowledgement", errno)
        }
        try faultInjector.checkpoint(.acknowledgementRenamed)
        guard fsync(directory.fileDescriptor) == 0 else {
            throw RunSupervisorError.systemCall("fsync acknowledgement directory", errno)
        }
        try faultInjector.checkpoint(.acknowledgementDirectorySynced)
        succeeded = true
    }

    static func readAcknowledgement(
        in directory: RunSupervisorRunDirectory,
        capability: RunSupervisorCapability
    ) throws -> UInt64 {
        let fd = openat(
            directory.fileDescriptor,
            acknowledgementFilename,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        if fd < 0, errno == ENOENT { return 0 }
        guard fd >= 0 else {
            throw RunSupervisorError.unsafeFilesystemEntry(acknowledgementFilename)
        }
        defer { close(fd) }
        try validateRegularEvidence(fd, expectedSize: 40)
        let data = try RunSupervisorSpoolFrameCodec.preadExactly(40, from: fd, offset: 0)
        let sequenceData = data.prefix(8)
        guard RunSupervisorDigests.constantTimeEqual(
            RunSupervisorDigests.hmacBytes(
                acknowledgementDomain + sequenceData,
                capability: capability
            ),
            Data(data.suffix(32))
        ) else {
            throw RunSupervisorError.corruptCommittedSpool
        }
        return sequenceData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
    }

    static func isValidCompactedPrefix(
        firstSequence: UInt64?,
        acknowledgement: UInt64
    ) -> Bool {
        guard let firstSequence else { return acknowledgement == 0 }
        if acknowledgement == 0 { return firstSequence == 1 }
        return firstSequence <= acknowledgement
            || (acknowledgement < UInt64.max && firstSequence == acknowledgement + 1)
    }

    private static func persistAtomically(
        _ data: Data,
        finalName: String,
        temporaryPrefix: String,
        directory: RunSupervisorRunDirectory
    ) throws {
        let temporary = "\(temporaryPrefix)\(UUID().uuidString.lowercased()).tmp"
        let fd = openat(
            directory.fileDescriptor,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else { throw RunSupervisorError.systemCall("open durable evidence temp", errno) }
        var succeeded = false
        defer {
            close(fd)
            if !succeeded { unlinkat(directory.fileDescriptor, temporary, 0) }
        }
        try writeAll(data, to: fd)
        guard fsync(fd) == 0,
              renameat(directory.fileDescriptor, temporary, directory.fileDescriptor, finalName) == 0,
              fsync(directory.fileDescriptor) == 0 else {
            throw RunSupervisorError.systemCall("persist durable evidence", errno)
        }
        succeeded = true
    }

    private static func validateRegularEvidence(_ fd: Int32, expectedSize: off_t) throws {
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & 0o077) == 0,
              status.st_nlink == 1,
              status.st_size == expectedSize else {
            throw RunSupervisorError.corruptCommittedSpool
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            let result = data.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if result < 0, errno == EINTR { continue }
            guard result > 0 else { throw RunSupervisorError.systemCall("write durable evidence", errno) }
            offset += result
        }
    }
}
