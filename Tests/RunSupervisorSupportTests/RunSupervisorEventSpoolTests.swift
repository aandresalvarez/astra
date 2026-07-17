import Darwin
import Foundation
import Testing
@testable import RunSupervisorSupport

@Suite("Run supervisor event spool", .serialized)
struct RunSupervisorEventSpoolTests {
    @Test("reconnect replay is ordered and cursor-exclusive across reopen and acknowledgement")
    func orderedReplayAndCompaction() throws {
        let fixture = try makeFixture()
        var spool: RunSupervisorEventSpool? = try .init(
            directory: fixture.directory,
            capability: fixture.capability
        )
        let first = try spool!.appendOutput(.standardOutput, data: Data("one".utf8))
        let second = try spool!.appendOutput(.standardError, data: Data("two".utf8))
        let terminal = try spool!.appendCritical(
            .providerExited,
            payload: .init(exitCode: 0, terminationReason: .exited)
        )
        #expect(try spool!.replay(after: 0).map(\.sequence) == [first.sequence, second.sequence, terminal.sequence])
        #expect(try spool!.replay(after: first.sequence).map(\.sequence) == [second.sequence, terminal.sequence])
        try spool!.acknowledge(through: first.sequence)
        let highest = spool!.lastSequence
        spool?.releaseOwnership()
        spool = nil

        let reopened = try RunSupervisorEventSpool(
            directory: fixture.directory,
            capability: fixture.capability
        )
        #expect(reopened.lastSequence == highest)
        #expect(reopened.lastAcknowledgedSequence == first.sequence)
        #expect(try reopened.replay(after: first.sequence).allSatisfy { $0.sequence > first.sequence })
    }

    @Test("replay and acknowledgement pump converges and restores its non-event watermark")
    func replayAcknowledgementPumpConverges() throws {
        let fixture = try makeFixture()
        var spool: RunSupervisorEventSpool? = try .init(
            directory: fixture.directory,
            capability: fixture.capability
        )
        _ = try spool!.appendCritical(.supervisorReady)
        _ = try spool!.appendOutput(.standardOutput, data: Data("chunk".utf8))
        _ = try spool!.appendCritical(
            .providerExited,
            payload: .init(exitCode: 0, terminationReason: .exited)
        )
        let terminalSequence = spool!.lastSequence
        var iterations = 0
        while let event = try spool!.replay(after: 0, limit: 1).first {
            try spool!.acknowledge(through: event.sequence)
            iterations += 1
            #expect(iterations <= 3)
        }
        #expect(iterations == 3)
        #expect(spool!.lastSequence == terminalSequence)
        #expect(spool!.lastAcknowledgedSequence == terminalSequence)
        #expect(try spool!.replay(after: 0).isEmpty)
        spool?.releaseOwnership()
        spool = nil

        let reopened = try RunSupervisorEventSpool(
            directory: fixture.directory,
            capability: fixture.capability
        )
        #expect(reopened.lastSequence == terminalSequence)
        #expect(reopened.lastAcknowledgedSequence == terminalSequence)
        #expect(try reopened.replay(after: 0).isEmpty)
        let next = try reopened.appendCritical(.standardInputClosed)
        #expect(next.sequence == terminalSequence + 1)
        #expect(try reopened.replay(after: 0) == [next])
    }

    @Test("only incomplete trailing bytes are quarantined and recovery is evented")
    func incompleteTailRecovery() throws {
        let fixture = try makeFixture()
        var spool: RunSupervisorEventSpool? = try .init(
            directory: fixture.directory,
            capability: fixture.capability
        )
        let committed = try spool!.appendCritical(.supervisorReady)
        spool?.releaseOwnership()
        spool = nil
        let path = fixture.url.appendingPathComponent("events.spool").path
        let incomplete = try RunSupervisorSpoolFrameCodec.encode(
            .init(
                sequence: committed.sequence + 1,
                id: RunSupervisorTestSupport.uuid(77),
                timestamp: .distantPast,
                kind: .standardOutput,
                payload: .init(data: Data("incomplete".utf8))
            ),
            capability: fixture.capability
        ).prefix(9)
        let fd = open(path, O_WRONLY | O_APPEND)
        #expect(fd >= 0)
        _ = incomplete.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)

        let recovered = try RunSupervisorEventSpool(
            directory: fixture.directory,
            capability: fixture.capability
        )
        let events = try recovered.replay(after: 0)
        #expect(events.first?.sequence == committed.sequence)
        #expect(events.last?.kind == .recoveryTailQuarantined)
        #expect(events.last?.payload.quarantinedByteCount == 9)
        let quarantines = try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
            .filter { $0.hasSuffix(".quarantine") }
        #expect(quarantines.count == 1)
    }

    @Test("fully present committed-frame corruption fails closed without truncation")
    func committedCorruptionFailsClosed() throws {
        let fixture = try makeFixture()
        var spool: RunSupervisorEventSpool? = try .init(
            directory: fixture.directory,
            capability: fixture.capability
        )
        _ = try spool!.appendCritical(.supervisorReady)
        spool?.releaseOwnership()
        spool = nil
        let path = fixture.url.appendingPathComponent("events.spool").path
        let originalSize = try #require(
            (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
        )
        let fd = open(path, O_RDWR)
        #expect(fd >= 0)
        var byte: UInt8 = 0xFF
        #expect(pwrite(fd, &byte, 1, 12) == 1)
        close(fd)

        #expect(throws: RunSupervisorError.corruptCommittedSpool) {
            try RunSupervisorEventSpool(
                directory: fixture.directory,
                capability: fixture.capability
            )
        }
        let afterSize = try #require(
            (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
        )
        #expect(afterSize == originalSize)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path)
            .allSatisfy { !$0.hasSuffix(".quarantine") })
    }

    @Test("output and nonterminal control backpressure preserve isolated terminal capacity")
    func terminalReserve() throws {
        let fixture = try makeFixture()
        let spool = try RunSupervisorEventSpool(
            directory: fixture.directory,
            capability: fixture.capability,
            maximumBytes: 4_096,
            criticalReserveBytes: 2_048
        )
        var sawOutputBackpressure = false
        while !sawOutputBackpressure {
            do {
                _ = try spool.appendOutput(.standardOutput, data: Data(repeating: 7, count: 512))
            } catch RunSupervisorError.spoolBackpressured {
                sawOutputBackpressure = true
            }
        }
        #expect(sawOutputBackpressure)

        var sawControlBackpressure = false
        while !sawControlBackpressure {
            do {
                _ = try spool.appendCritical(.standardInputAccepted)
            } catch RunSupervisorError.spoolCriticalCapacityExhausted {
                sawControlBackpressure = true
            }
        }
        #expect(sawControlBackpressure)
        let terminal = try spool.appendCritical(
            .providerExited,
            payload: .init(exitCode: 137, terminationSignal: SIGKILL, terminationReason: .signaled)
        )
        #expect(terminal.kind == .providerExited)
        #expect(try spool.replay(after: terminal.sequence - 1).last == terminal)
    }

    @Test("symlink spool and public run directories are rejected without touching targets")
    func symlinkAndModeAttacks() throws {
        let fixture = try makeFixture()
        let victim = fixture.url.appendingPathComponent("victim")
        try Data("safe".utf8).write(to: victim)
        let spoolPath = fixture.url.appendingPathComponent("events.spool")
        #expect(symlink(victim.path, spoolPath.path) == 0)
        #expect(throws: RunSupervisorError.self) {
            try RunSupervisorEventSpool(
                directory: fixture.directory,
                capability: fixture.capability
            )
        }
        #expect(try String(contentsOf: victim) == "safe")

        let insecure = try RunSupervisorTestSupport.temporaryDirectory("insecure")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: insecure.path)
        #expect(throws: RunSupervisorError.untrustedRoot) {
            try RunSupervisorTrustedRoot(path: insecure.path)
        }
    }

    @Test("event timestamps persist at deterministic millisecond precision")
    func timestampPrecision() throws {
        let fixture = try makeFixture()
        let clock = FractionalClock(date: Date(timeIntervalSince1970: 123.456789))
        let spool = try RunSupervisorEventSpool(
            directory: fixture.directory,
            capability: fixture.capability,
            clock: clock
        )
        let event = try spool.appendCritical(.supervisorReady)
        #expect(Int64((event.timestamp.timeIntervalSince1970 * 1_000).rounded()) == 123_456)
    }

    @Test("an oversized pre-existing spool fails closed before unbounded recovery")
    func oversizedExistingSpoolFailsClosed() throws {
        let fixture = try makeFixture()
        let path = fixture.url.appendingPathComponent("events.spool")
        try Data(repeating: 0, count: 4_097).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #expect(throws: RunSupervisorError.corruptCommittedSpool) {
            try RunSupervisorEventSpool(
                directory: fixture.directory,
                capability: fixture.capability,
                maximumBytes: 4_096,
                criticalReserveBytes: 1_024
            )
        }
    }

    @Test("spool frames acknowledgements and offline recovery require the execution capability")
    func capabilityAuthenticatedOfflineRecovery() throws {
        let fixture = try makeFixture()
        var spool: RunSupervisorEventSpool? = try .init(
            directory: fixture.directory,
            capability: fixture.capability
        )
        let first = try spool!.appendCritical(.supervisorReady)
        let second = try spool!.appendOutput(.standardOutput, data: Data("bounded".utf8))
        let terminal = try spool!.appendCritical(
            .providerExited,
            payload: .init(exitCode: 0, terminationReason: .exited)
        )

        #expect(throws: RunSupervisorError.alreadyRunningOrInDoubt) {
            try RunSupervisorOfflineSpoolRecovery.replay(
                directory: fixture.directory,
                capability: fixture.capability,
                after: 0
            )
        }
        spool?.releaseOwnership()
        spool = nil

        let wrongCapability = try RunSupervisorCapability(bytes: Data(repeating: 0xF0, count: 32))
        #expect(throws: RunSupervisorError.corruptCommittedSpool) {
            try RunSupervisorOfflineSpoolRecovery.replay(
                directory: fixture.directory,
                capability: wrongCapability,
                after: 0
            )
        }
        #expect(throws: RunSupervisorError.oversizedFrame(limit: 4)) {
            try RunSupervisorOfflineSpoolRecovery.replay(
                directory: fixture.directory,
                capability: fixture.capability,
                after: 0,
                limit: 5
            )
        }

        let firstBatch = try RunSupervisorOfflineSpoolRecovery.replay(
            directory: fixture.directory,
            capability: fixture.capability,
            after: 0,
            limit: 2
        )
        #expect(firstBatch.events.map(\.sequence) == [first.sequence, second.sequence])
        #expect(firstBatch.lastSequence == terminal.sequence)
        try RunSupervisorOfflineSpoolRecovery.acknowledge(
            directory: fixture.directory,
            capability: fixture.capability,
            through: second.sequence
        )
        let terminalBatch = try RunSupervisorOfflineSpoolRecovery.replay(
            directory: fixture.directory,
            capability: fixture.capability,
            after: 0
        )
        #expect(terminalBatch.events == [terminal])
        #expect(terminalBatch.lastAcknowledgedSequence == second.sequence)
    }

    @Test("empty and absent spools remain capability-gated without offline creation or lock leaks")
    func emptySpoolCapabilityMarkerAndFailedInitCleanup() throws {
        let absent = try makeFixture()
        #expect(throws: RunSupervisorError.corruptCommittedSpool) {
            try RunSupervisorOfflineSpoolRecovery.replay(
                directory: absent.directory,
                capability: absent.capability,
                after: 0
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: absent.url.appendingPathComponent("events.spool").path
        ))

        let fixture = try makeFixture()
        var initialized: RunSupervisorEventSpool? = try .init(
            directory: fixture.directory,
            capability: fixture.capability
        )
        #expect(initialized != nil)
        initialized?.releaseOwnership()
        initialized = nil
        let wrongCapability = try RunSupervisorCapability(bytes: Data(repeating: 0xD1, count: 32))
        #expect(throws: RunSupervisorError.corruptCommittedSpool) {
            try RunSupervisorEventSpool(
                directory: fixture.directory,
                capability: wrongCapability
            )
        }
        let correctImmediatelyAfterFailure = try RunSupervisorEventSpool(
            directory: fixture.directory,
            capability: fixture.capability
        )
        #expect(try correctImmediatelyAfterFailure.replay(after: 0).isEmpty)

        let missingMarker = try makeFixture()
        let preexistingSpool = missingMarker.url.appendingPathComponent("events.spool")
        try Data().write(to: preexistingSpool)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: preexistingSpool.path
        )
        #expect(throws: RunSupervisorError.corruptCommittedSpool) {
            try RunSupervisorEventSpool(
                directory: missingMarker.directory,
                capability: wrongCapability
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: missingMarker.url.appendingPathComponent("events.auth").path
        ))
        #expect(throws: RunSupervisorError.corruptCommittedSpool) {
            try RunSupervisorEventSpool(
                directory: missingMarker.directory,
                capability: missingMarker.capability
            )
        }
    }

    @Test("acknowledgement HMAC rejects same-uid durable tampering")
    func acknowledgementTamperingFailsClosed() throws {
        let fixture = try makeFixture()
        var spool: RunSupervisorEventSpool? = try .init(
            directory: fixture.directory,
            capability: fixture.capability
        )
        let event = try spool!.appendCritical(.supervisorReady)
        try spool!.acknowledge(through: event.sequence)
        spool?.releaseOwnership()
        spool = nil

        let acknowledgement = fixture.url.appendingPathComponent("events.ack").path
        let fd = open(acknowledgement, O_RDWR)
        #expect(fd >= 0)
        var byte: UInt8 = 0xA5
        #expect(pwrite(fd, &byte, 1, 12) == 1)
        close(fd)
        #expect(throws: RunSupervisorError.corruptCommittedSpool) {
            try RunSupervisorEventSpool(
                directory: fixture.directory,
                capability: fixture.capability
            )
        }
    }

    @Test("every acknowledgement and compaction crash boundary recovers without loss or duplication")
    func acknowledgementCrashBoundaryRecovery() throws {
        for checkpoint in RunSupervisorSpoolPersistenceCheckpoint.allCases {
            let fixture = try makeFixture()
            var spool: RunSupervisorEventSpool? = try .init(
                directory: fixture.directory,
                capability: fixture.capability,
                faultInjector: OneShotSpoolFaultInjector(checkpoint: checkpoint)
            )
            let first = try spool!.appendCritical(.supervisorReady)
            let second = try spool!.appendOutput(.standardOutput, data: Data("two".utf8))
            let terminal = try spool!.appendCritical(
                .providerExited,
                payload: .init(exitCode: 0, terminationReason: .exited)
            )
            #expect(throws: InjectedSpoolCrash.self) {
                try spool!.acknowledge(through: second.sequence)
            }
            #expect(throws: RunSupervisorError.corruptCommittedSpool) {
                try spool!.replay(after: 0)
            }
            spool?.releaseOwnership()
            spool = nil

            var recovered: RunSupervisorEventSpool? = try .init(
                directory: fixture.directory,
                capability: fixture.capability
            )
            let replayed = try recovered!.replay(after: 0)
            let expectedAcknowledgement: UInt64 = checkpoint == .acknowledgementTemporarySynced
                ? 0
                : second.sequence
            #expect(recovered!.lastAcknowledgedSequence == expectedAcknowledgement)
            #expect(recovered!.lastSequence == terminal.sequence)
            #expect(Set(replayed.map(\.sequence)).count == replayed.count)
            if expectedAcknowledgement == 0 {
                #expect(replayed.map(\.sequence) == [first.sequence, second.sequence, terminal.sequence])
            } else {
                #expect(replayed == [terminal])
            }
            try recovered!.acknowledge(through: terminal.sequence)
            recovered?.releaseOwnership()
            recovered = nil

            let final = try RunSupervisorEventSpool(
                directory: fixture.directory,
                capability: fixture.capability
            )
            #expect(try final.replay(after: 0).isEmpty)
            #expect(final.lastSequence == terminal.sequence)
        }
    }

    private func makeFixture() throws -> (
        root: RunSupervisorTrustedRoot,
        directory: RunSupervisorRunDirectory,
        url: URL,
        capability: RunSupervisorCapability
    ) {
        let rootURL = try RunSupervisorTestSupport.temporaryDirectory("spool-root")
        let root = try RunSupervisorTrustedRoot(path: rootURL.path)
        let payload = try RunSupervisorTestSupport.payload()
        let directory = try root.acquireExecutionDirectory(payload.manifest.executionID).directory
        return (
            root,
            directory,
            URL(fileURLWithPath: directory.path, isDirectory: true),
            payload.capability
        )
    }
}

private struct FractionalClock: RunSupervisorClock {
    let date: Date
    func now() -> Date { date }
}

private struct InjectedSpoolCrash: Error {}

private final class OneShotSpoolFaultInjector: RunSupervisorSpoolFaultInjecting, @unchecked Sendable {
    private let target: RunSupervisorSpoolPersistenceCheckpoint
    private let lock = NSLock()
    private var fired = false

    init(checkpoint: RunSupervisorSpoolPersistenceCheckpoint) {
        target = checkpoint
    }

    func checkpoint(_ checkpoint: RunSupervisorSpoolPersistenceCheckpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard checkpoint == target, !fired else { return }
        fired = true
        throw InjectedSpoolCrash()
    }
}
