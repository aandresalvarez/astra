import Foundation

package enum RunSupervisorSpoolPersistenceCheckpoint: CaseIterable, Equatable, Sendable {
    case acknowledgementTemporarySynced
    case acknowledgementRenamed
    case acknowledgementDirectorySynced
    case compactionTemporarySynced
    case compactionRenamed
    case compactionDirectorySynced
}

package protocol RunSupervisorSpoolFaultInjecting: Sendable {
    func checkpoint(_ checkpoint: RunSupervisorSpoolPersistenceCheckpoint) throws
}

package struct NoOpRunSupervisorSpoolFaultInjector: RunSupervisorSpoolFaultInjecting {
    package func checkpoint(_ checkpoint: RunSupervisorSpoolPersistenceCheckpoint) throws {}
}

public struct RunSupervisorOfflineReplayBatch: Equatable, Sendable {
    public let events: [RunSupervisorEvent]
    public let lastSequence: UInt64
    public let lastAcknowledgedSequence: UInt64

    public init(
        events: [RunSupervisorEvent],
        lastSequence: UInt64,
        lastAcknowledgedSequence: UInt64
    ) {
        self.events = events
        self.lastSequence = lastSequence
        self.lastAcknowledgedSequence = lastAcknowledgedSequence
    }
}

/// Capability-gated recovery for a supervisor that is no longer reachable.
///
/// The spool is exclusively locked while it is validated, replayed, or
/// acknowledged. A live supervisor therefore causes recovery to fail closed
/// instead of racing its append/compaction path.
public enum RunSupervisorOfflineSpoolRecovery {
    public static let maximumReplayEvents = 4

    public static func replay(
        directory: RunSupervisorRunDirectory,
        capability: RunSupervisorCapability,
        after sequence: UInt64,
        limit: Int = maximumReplayEvents
    ) throws -> RunSupervisorOfflineReplayBatch {
        guard limit > 0, limit <= maximumReplayEvents else {
            throw RunSupervisorError.oversizedFrame(limit: maximumReplayEvents)
        }
        let spool = try RunSupervisorEventSpool(
            directory: directory,
            capability: capability,
            faultInjector: NoOpRunSupervisorSpoolFaultInjector(),
            createIfMissing: false
        )
        return try .init(
            events: spool.replay(after: sequence, limit: limit),
            lastSequence: spool.lastSequence,
            lastAcknowledgedSequence: spool.lastAcknowledgedSequence
        )
    }

    public static func acknowledge(
        directory: RunSupervisorRunDirectory,
        capability: RunSupervisorCapability,
        through sequence: UInt64
    ) throws {
        let spool = try RunSupervisorEventSpool(
            directory: directory,
            capability: capability,
            faultInjector: NoOpRunSupervisorSpoolFaultInjector(),
            createIfMissing: false
        )
        try spool.acknowledge(through: sequence)
    }
}
