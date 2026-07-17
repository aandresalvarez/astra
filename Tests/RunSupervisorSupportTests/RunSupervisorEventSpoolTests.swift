import Darwin
import Foundation
import Testing
@testable import RunSupervisorSupport

@Suite("Run supervisor event spool", .serialized)
struct RunSupervisorEventSpoolTests {
    @Test("reconnect replay is ordered and cursor-exclusive across reopen and acknowledgement")
    func orderedReplayAndCompaction() throws {
        let fixture = try makeFixture()
        var spool: RunSupervisorEventSpool? = try .init(directory: fixture.directory)
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
        spool = nil

        let reopened = try RunSupervisorEventSpool(directory: fixture.directory)
        #expect(reopened.lastSequence == highest)
        #expect(reopened.lastAcknowledgedSequence == first.sequence)
        #expect(try reopened.replay(after: first.sequence).allSatisfy { $0.sequence > first.sequence })
    }

    @Test("replay and acknowledgement pump converges and restores its non-event watermark")
    func replayAcknowledgementPumpConverges() throws {
        let fixture = try makeFixture()
        var spool: RunSupervisorEventSpool? = try .init(directory: fixture.directory)
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
        spool = nil

        let reopened = try RunSupervisorEventSpool(directory: fixture.directory)
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
        var spool: RunSupervisorEventSpool? = try .init(directory: fixture.directory)
        let committed = try spool!.appendCritical(.supervisorReady)
        spool = nil
        let path = fixture.url.appendingPathComponent("events.spool").path
        let incomplete = try RunSupervisorSpoolFrameCodec.encode(
            .init(
                sequence: committed.sequence + 1,
                id: RunSupervisorTestSupport.uuid(77),
                timestamp: .distantPast,
                kind: .standardOutput,
                payload: .init(data: Data("incomplete".utf8))
            )
        ).prefix(9)
        let fd = open(path, O_WRONLY | O_APPEND)
        #expect(fd >= 0)
        _ = incomplete.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)

        let recovered = try RunSupervisorEventSpool(directory: fixture.directory)
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
        var spool: RunSupervisorEventSpool? = try .init(directory: fixture.directory)
        _ = try spool!.appendCritical(.supervisorReady)
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
            try RunSupervisorEventSpool(directory: fixture.directory)
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
            try RunSupervisorEventSpool(directory: fixture.directory)
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
        let spool = try RunSupervisorEventSpool(directory: fixture.directory, clock: clock)
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
                maximumBytes: 4_096,
                criticalReserveBytes: 1_024
            )
        }
    }

    private func makeFixture() throws -> (
        root: RunSupervisorTrustedRoot,
        directory: RunSupervisorRunDirectory,
        url: URL
    ) {
        let rootURL = try RunSupervisorTestSupport.temporaryDirectory("spool-root")
        let root = try RunSupervisorTrustedRoot(path: rootURL.path)
        let execution = try RunSupervisorTestSupport.payload().manifest.executionID
        let directory = try root.acquireExecutionDirectory(execution).directory
        return (root, directory, URL(fileURLWithPath: directory.path, isDirectory: true))
    }
}

private struct FractionalClock: RunSupervisorClock {
    let date: Date
    func now() -> Date { date }
}
