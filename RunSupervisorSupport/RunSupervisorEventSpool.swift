import Darwin
import Foundation

public final class RunSupervisorEventSpool: @unchecked Sendable {
    public static let defaultMaximumBytes = 8 * 1_024 * 1_024
    public static let defaultCriticalReserveBytes = 256 * 1_024
    private static let filename = "events.spool"

    private let directory: RunSupervisorRunDirectory
    private let capability: RunSupervisorCapability
    private let maximumBytes: Int
    private let criticalReserveBytes: Int
    private let terminalReserveBytes: Int
    private let clock: any RunSupervisorClock
    private let faultInjector: any RunSupervisorSpoolFaultInjecting
    private let lock = NSCondition()
    private var fileDescriptor: Int32
    private var events: [RunSupervisorEvent] = []
    private var currentBytes = 0
    private var highestSequence: UInt64 = 0
    private var acknowledgedSequence: UInt64 = 0
    private var outputBackpressured = false
    private var persistencePoisoned = false

    public convenience init(
        directory: RunSupervisorRunDirectory,
        capability: RunSupervisorCapability,
        maximumBytes: Int = defaultMaximumBytes,
        criticalReserveBytes: Int = defaultCriticalReserveBytes,
        clock: any RunSupervisorClock = SystemRunSupervisorClock()
    ) throws {
        try self.init(
            directory: directory,
            capability: capability,
            maximumBytes: maximumBytes,
            criticalReserveBytes: criticalReserveBytes,
            clock: clock,
            faultInjector: NoOpRunSupervisorSpoolFaultInjector()
        )
    }

    package init(
        directory: RunSupervisorRunDirectory,
        capability: RunSupervisorCapability,
        maximumBytes: Int = defaultMaximumBytes,
        criticalReserveBytes: Int = defaultCriticalReserveBytes,
        clock: any RunSupervisorClock = SystemRunSupervisorClock(),
        faultInjector: any RunSupervisorSpoolFaultInjecting,
        createIfMissing: Bool = true
    ) throws {
        guard maximumBytes > 0,
              criticalReserveBytes > 0,
              criticalReserveBytes < maximumBytes else {
            throw RunSupervisorError.invalidSchema
        }
        self.directory = directory
        self.capability = capability
        self.maximumBytes = maximumBytes
        self.criticalReserveBytes = criticalReserveBytes
        self.terminalReserveBytes = max(1, criticalReserveBytes / 2)
        self.clock = clock
        self.faultInjector = faultInjector
        let opened = try RunSupervisorSpoolFileIO.openSpool(
            in: directory,
            createIfMissing: createIfMissing
        )
        self.fileDescriptor = opened.fileDescriptor
        do {
            try RunSupervisorSpoolDurability.ensureAuthenticationMarker(
                in: directory,
                spoolFileDescriptor: fileDescriptor,
                capability: capability,
                allowCreation: opened.wasCreated
            )
            let recovery = try reopenAndValidate()
            let persistedAcknowledgement = try RunSupervisorSpoolDurability.readAcknowledgement(
                in: directory,
                capability: capability
            )
            guard persistedAcknowledgement <= highestSequence,
                  RunSupervisorSpoolDurability.isValidCompactedPrefix(
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
        } catch {
            _ = flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
            fileDescriptor = -1
            throw error
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
        guard !persistencePoisoned else { throw RunSupervisorError.corruptCommittedSpool }
        let candidate = makeEvent(kind, payload: .init(data: data))
        let frame = try RunSupervisorSpoolFrameCodec.encode(candidate, capability: capability)
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
        guard !persistencePoisoned else { throw RunSupervisorError.corruptCommittedSpool }
        let event = makeEvent(kind, payload: payload)
        try appendEncodedCritical(event)
        return event
    }

    public func replay(after sequence: UInt64, limit: Int = 1_024) throws -> [RunSupervisorEvent] {
        guard limit > 0, limit <= 4_096 else { throw RunSupervisorError.oversizedFrame(limit: 4_096) }
        lock.lock()
        defer { lock.unlock() }
        guard !persistencePoisoned else { throw RunSupervisorError.corruptCommittedSpool }
        let replayFloor = max(sequence, acknowledgedSequence)
        return Array(events.lazy.filter { $0.sequence > replayFloor }.prefix(limit))
    }

    public func acknowledge(through sequence: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !persistencePoisoned else { throw RunSupervisorError.corruptCommittedSpool }
        guard sequence >= acknowledgedSequence, sequence <= highestSequence else {
            throw RunSupervisorError.invalidAcknowledgement
        }
        if sequence == acknowledgedSequence { return }
        do {
            try RunSupervisorSpoolDurability.persistAcknowledgement(
                sequence,
                directory: directory,
                capability: capability,
                faultInjector: faultInjector
            )
            acknowledgedSequence = sequence
            try compactLocked(through: sequence)
            if outputBackpressured, currentBytes < maximumBytes - criticalReserveBytes {
                outputBackpressured = false
                let released = makeEvent(.outputBackpressureReleased, payload: .init())
                try appendEncodedCritical(released)
                lock.broadcast()
            }
        } catch {
            persistencePoisoned = true
            throw error
        }
    }

    public func waitForOutputCapacity(deadline: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if persistencePoisoned { return false }
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
        let frame = try RunSupervisorSpoolFrameCodec.encode(event, capability: capability)
        let capacity = event.kind.isTerminalTruth ? maximumBytes : maximumBytes - terminalReserveBytes
        guard currentBytes + frame.count <= capacity else {
            throw RunSupervisorError.spoolCriticalCapacityExhausted
        }
        try appendEncoded(event, frame: frame)
    }

    private func appendEncoded(_ event: RunSupervisorEvent, frame: Data) throws {
        try RunSupervisorSpoolFileIO.writeAll(frame, to: fileDescriptor)
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
            if !succeeded {
                close(tempFD)
                unlinkat(directory.fileDescriptor, temporary, 0)
            }
        }
        var bytes = 0
        for event in retained {
            let frame = try RunSupervisorSpoolFrameCodec.encode(event, capability: capability)
            try RunSupervisorSpoolFileIO.writeAll(frame, to: tempFD)
            bytes += frame.count
        }
        guard fsync(tempFD) == 0 else { throw RunSupervisorError.systemCall("fsync compacted spool", errno) }
        try faultInjector.checkpoint(.compactionTemporarySynced)
        guard flock(tempFD, LOCK_EX | LOCK_NB) == 0 else {
            throw RunSupervisorError.alreadyRunningOrInDoubt
        }
        guard renameat(
            directory.fileDescriptor,
            temporary,
            directory.fileDescriptor,
            Self.filename
        ) == 0 else {
            throw RunSupervisorError.systemCall("rename compacted spool", errno)
        }
        try faultInjector.checkpoint(.compactionRenamed)
        guard fsync(directory.fileDescriptor) == 0 else {
            throw RunSupervisorError.systemCall("fsync run directory", errno)
        }
        try faultInjector.checkpoint(.compactionDirectorySynced)
        succeeded = true
        let oldFD = fileDescriptor
        fileDescriptor = tempFD
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
                fileSize: fileSize,
                capability: capability
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
            try RunSupervisorSpoolFileIO.quarantineTail(
                fileDescriptor: fileDescriptor,
                directory: directory,
                offset: offset,
                byteCount: tailBytes
            )
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
}
