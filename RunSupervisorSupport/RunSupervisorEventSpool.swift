import CryptoKit
import Darwin
import Foundation

public final class RunSupervisorEventSpool: @unchecked Sendable {
    public static let defaultMaximumBytes = 8 * 1_024 * 1_024
    public static let defaultCriticalReserveBytes = 256 * 1_024
    private static let filename = "events.spool"
    private static let acknowledgementFilename = "events.ack"

    private let directory: RunSupervisorRunDirectory
    private let maximumBytes: Int
    private let criticalReserveBytes: Int
    private let terminalReserveBytes: Int
    private let clock: any RunSupervisorClock
    private let lock = NSCondition()
    private var fileDescriptor: Int32
    private var events: [RunSupervisorEvent] = []
    private var currentBytes = 0
    private var highestSequence: UInt64 = 0
    private var acknowledgedSequence: UInt64 = 0
    private var outputBackpressured = false

    public init(
        directory: RunSupervisorRunDirectory,
        maximumBytes: Int = defaultMaximumBytes,
        criticalReserveBytes: Int = defaultCriticalReserveBytes,
        clock: any RunSupervisorClock = SystemRunSupervisorClock()
    ) throws {
        guard maximumBytes > 0,
              criticalReserveBytes > 0,
              criticalReserveBytes < maximumBytes else {
            throw RunSupervisorError.invalidSchema
        }
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.criticalReserveBytes = criticalReserveBytes
        self.terminalReserveBytes = max(1, criticalReserveBytes / 2)
        self.clock = clock
        self.fileDescriptor = try Self.openSpool(in: directory)
        let recovery = try reopenAndValidate()
        let persistedAcknowledgement = try Self.readAcknowledgement(in: directory)
        guard persistedAcknowledgement <= highestSequence,
              Self.isValidCompactedPrefix(
                firstSequence: events.first?.sequence,
                acknowledgement: persistedAcknowledgement
              ) else {
            throw RunSupervisorError.corruptCommittedSpool
        }
        acknowledgedSequence = persistedAcknowledgement
        if recovery > 0 {
            _ = try appendCritical(
                .recoveryTailQuarantined,
                payload: .init(quarantinedByteCount: UInt64(recovery))
            )
        }
    }

    deinit { close(fileDescriptor) }

    public var lastSequence: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return highestSequence
    }

    public var lastAcknowledgedSequence: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return acknowledgedSequence
    }

    @discardableResult
    public func appendOutput(_ kind: RunSupervisorEventKind, data: Data) throws -> RunSupervisorEvent {
        guard kind.isOutput, data.count <= 32_768 else {
            throw RunSupervisorError.oversizedFrame(limit: 32_768)
        }
        lock.lock()
        defer { lock.unlock() }
        let candidate = makeEvent(kind, payload: .init(data: data))
        let frame = try RunSupervisorSpoolFrameCodec.encode(candidate)
        guard currentBytes + frame.count <= maximumBytes - criticalReserveBytes else {
            if !outputBackpressured {
                outputBackpressured = true
                let marker = makeEvent(.outputBackpressureStarted, payload: .init())
                try appendEncodedCritical(marker)
            }
            throw RunSupervisorError.spoolBackpressured
        }
        try appendEncoded(candidate, frame: frame)
        return candidate
    }

    @discardableResult
    public func appendCritical(
        _ kind: RunSupervisorEventKind,
        payload: RunSupervisorEventPayload = .init()
    ) throws -> RunSupervisorEvent {
        guard !kind.isOutput else { throw RunSupervisorError.invalidSchema }
        try payload.validate(for: kind)
        lock.lock()
        defer { lock.unlock() }
        let event = makeEvent(kind, payload: payload)
        try appendEncodedCritical(event)
        return event
    }

    public func replay(after sequence: UInt64, limit: Int = 1_024) throws -> [RunSupervisorEvent] {
        guard limit > 0, limit <= 4_096 else { throw RunSupervisorError.oversizedFrame(limit: 4_096) }
        lock.lock()
        defer { lock.unlock() }
        let replayFloor = max(sequence, acknowledgedSequence)
        return Array(events.lazy.filter { $0.sequence > replayFloor }.prefix(limit))
    }

    public func acknowledge(through sequence: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sequence >= acknowledgedSequence, sequence <= highestSequence else {
            throw RunSupervisorError.invalidAcknowledgement
        }
        if sequence == acknowledgedSequence { return }
        try persistAcknowledgement(sequence)
        acknowledgedSequence = sequence
        try compactLocked(through: sequence)
        if outputBackpressured, currentBytes < maximumBytes - criticalReserveBytes {
            outputBackpressured = false
            let released = makeEvent(.outputBackpressureReleased, payload: .init())
            try appendEncodedCritical(released)
            lock.broadcast()
        }
    }

    public func waitForOutputCapacity(deadline: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        while outputBackpressured {
            if !lock.wait(until: deadline) { return false }
        }
        return true
    }

    private func makeEvent(
        _ kind: RunSupervisorEventKind,
        payload: RunSupervisorEventPayload
    ) -> RunSupervisorEvent {
        RunSupervisorEvent(
            sequence: highestSequence + 1,
            id: UUID(),
            timestamp: clock.persistedNow(),
            kind: kind,
            payload: payload
        )
    }

    private func appendEncodedCritical(_ event: RunSupervisorEvent) throws {
        let frame = try RunSupervisorSpoolFrameCodec.encode(event)
        let capacity = event.kind.isTerminalTruth ? maximumBytes : maximumBytes - terminalReserveBytes
        guard currentBytes + frame.count <= capacity else {
            throw RunSupervisorError.spoolCriticalCapacityExhausted
        }
        try appendEncoded(event, frame: frame)
    }

    private func appendEncoded(_ event: RunSupervisorEvent, frame: Data) throws {
        try Self.writeAll(frame, to: fileDescriptor)
        guard fsync(fileDescriptor) == 0 else {
            throw RunSupervisorError.systemCall("fsync event spool", errno)
        }
        events.append(event)
        highestSequence = event.sequence
        currentBytes += frame.count
    }

    private func compactLocked(through sequence: UInt64) throws {
        var retained = events.filter { $0.sequence > sequence }
        if retained.isEmpty, let anchor = events.last { retained = [anchor] }
        let temporary = ".events-spool-\(UUID().uuidString.lowercased()).tmp"
        let tempFD = openat(
            directory.fileDescriptor,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard tempFD >= 0 else { throw RunSupervisorError.systemCall("open spool compaction", errno) }
        var succeeded = false
        defer {
            close(tempFD)
            if !succeeded { unlinkat(directory.fileDescriptor, temporary, 0) }
        }
        var bytes = 0
        for event in retained {
            let frame = try RunSupervisorSpoolFrameCodec.encode(event)
            try Self.writeAll(frame, to: tempFD)
            bytes += frame.count
        }
        guard fsync(tempFD) == 0 else { throw RunSupervisorError.systemCall("fsync compacted spool", errno) }
        guard renameat(
            directory.fileDescriptor,
            temporary,
            directory.fileDescriptor,
            Self.filename
        ) == 0 else {
            throw RunSupervisorError.systemCall("rename compacted spool", errno)
        }
        guard fsync(directory.fileDescriptor) == 0 else {
            throw RunSupervisorError.systemCall("fsync run directory", errno)
        }
        let replacementFD = try Self.openSpool(in: directory)
        succeeded = true
        let oldFD = fileDescriptor
        fileDescriptor = replacementFD
        close(oldFD)
        events = retained
        currentBytes = bytes
    }

    private func reopenAndValidate() throws -> Int {
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0 else {
            throw RunSupervisorError.systemCall("fstat event spool", errno)
        }
        let fileSize = Int(status.st_size)
        guard fileSize <= maximumBytes else {
            throw RunSupervisorError.corruptCommittedSpool
        }
        var offset = 0
        var previousSequence: UInt64?
        var decoded: [RunSupervisorEvent] = []
        while offset < fileSize {
            switch try RunSupervisorSpoolFrameCodec.decode(
                fileDescriptor: fileDescriptor,
                offset: offset,
                fileSize: fileSize
            ) {
            case .incompleteTail:
                break
            case .corruptCommittedFrame:
                throw RunSupervisorError.corruptCommittedSpool
            case .committed(let event, let byteCount):
                if let previousSequence, event.sequence != previousSequence + 1 {
                    throw RunSupervisorError.corruptCommittedSpool
                }
                decoded.append(event)
                previousSequence = event.sequence
                offset += byteCount
                continue
            }
            break
        }
        let tailBytes = fileSize - offset
        if tailBytes > 0 {
            try quarantineTail(offset: offset, byteCount: tailBytes)
            guard fsync(directory.fileDescriptor) == 0 else {
                throw RunSupervisorError.systemCall("fsync tail quarantine directory", errno)
            }
            guard ftruncate(fileDescriptor, off_t(offset)) == 0,
                  fsync(fileDescriptor) == 0 else {
                throw RunSupervisorError.systemCall("truncate recovered spool", errno)
            }
        }
        events = decoded
        currentBytes = offset
        highestSequence = decoded.last?.sequence ?? 0
        return tailBytes
    }

    private func persistAcknowledgement(_ sequence: UInt64) throws {
        var encodedSequence = sequence.bigEndian
        let sequenceData = withUnsafeBytes(of: &encodedSequence) { Data($0) }
        let data = sequenceData + Data(SHA256.hash(data: sequenceData))
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
        try Self.writeAll(data, to: fd)
        guard fsync(fd) == 0 else {
            throw RunSupervisorError.systemCall("fsync acknowledgement", errno)
        }
        guard renameat(
            directory.fileDescriptor,
            temporary,
            directory.fileDescriptor,
            Self.acknowledgementFilename
        ) == 0 else {
            throw RunSupervisorError.systemCall("rename acknowledgement", errno)
        }
        guard fsync(directory.fileDescriptor) == 0 else {
            throw RunSupervisorError.systemCall("fsync acknowledgement directory", errno)
        }
        succeeded = true
    }

    private static func readAcknowledgement(in directory: RunSupervisorRunDirectory) throws -> UInt64 {
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
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              (status.st_mode & 0o077) == 0,
              status.st_nlink == 1,
              status.st_size == 40 else {
            throw RunSupervisorError.corruptCommittedSpool
        }
        let data = try RunSupervisorSpoolFrameCodec.preadExactly(40, from: fd, offset: 0)
        let sequenceData = data.prefix(8)
        guard Data(SHA256.hash(data: sequenceData)) == data.suffix(32) else {
            throw RunSupervisorError.corruptCommittedSpool
        }
        return sequenceData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
    }

    private static func isValidCompactedPrefix(
        firstSequence: UInt64?,
        acknowledgement: UInt64
    ) -> Bool {
        guard let firstSequence else { return acknowledgement == 0 }
        if acknowledgement == 0 { return firstSequence == 1 }
        return firstSequence == acknowledgement
            || (acknowledgement < UInt64.max && firstSequence == acknowledgement + 1)
    }

    private func quarantineTail(offset: Int, byteCount: Int) throws {
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
        try Self.writeAll(evidence, to: fd)
        guard fsync(fd) == 0 else { throw RunSupervisorError.systemCall("fsync spool quarantine", errno) }
    }

    private static func openSpool(in directory: RunSupervisorRunDirectory) throws -> Int32 {
        let fd = openat(
            directory.fileDescriptor,
            filename,
            O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
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
        return fd
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
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
