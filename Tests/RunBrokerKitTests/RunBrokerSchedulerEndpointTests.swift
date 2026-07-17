import Foundation
import Testing
import ASTRACore
@testable import RunBrokerKit

@Suite("RunBroker durable monitor scheduler")
struct RunBrokerSchedulerEndpointTests {
    @Test("Recovery reconstructs projection and arms only the earliest durable deadline")
    func recoveryAndRearm() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let first = deadline(1, dueAt: now.addingTimeInterval(10), attempt: 0)
        let second = deadline(2, dueAt: now.addingTimeInterval(20), attempt: 0)
        let ledger = FakeMonitorLedger(deadlines: [second, first])
        let timer = FakeOneShotTimer()
        let scheduler = RunBrokerMonitorScheduler(
            ledger: ledger,
            monitor: FakeMonitor(),
            timer: timer,
            clock: FixedClock(now: now),
            random: FixedUnitRandom(value: 0.5)
        )

        try scheduler.recover()
        #expect(timer.scheduledDates == [first.dueAt])
        #expect(try scheduler.status() == [first, second])
    }

    @Test("Retry uses bounded deterministic exponential backoff and one-shot rearm")
    func deterministicBackoff() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        let due = deadline(3, dueAt: now, attempt: 0)
        let ledger = FakeMonitorLedger(deadlines: [due])
        let timer = FakeOneShotTimer()
        let scheduler = RunBrokerMonitorScheduler(
            ledger: ledger,
            monitor: FakeMonitor(disposition: .retryableFailure),
            timer: timer,
            clock: FixedClock(now: now),
            random: FixedUnitRandom(value: 0.5),
            backoff: .init(initialDelay: 5, maximumDelay: 60, jitterFraction: 0.2)
        )
        try scheduler.recover()
        try scheduler.wake()

        let next = try #require(ledger.deadlines[due.operationID])
        #expect(next.attempt == 1)
        #expect(next.dueAt == now.addingTimeInterval(10))
        #expect(timer.scheduledDates.last == next.dueAt)
        #expect(ledger.attemptKeys.count == 1)
    }

    @Test("Same recovered attempt produces the same durable attempt idempotency key")
    func deterministicAttemptKey() throws {
        let now = Date(timeIntervalSince1970: 30_000)
        let due = deadline(4, dueAt: now, attempt: 2)
        let firstLedger = FakeMonitorLedger(deadlines: [due])
        let secondLedger = FakeMonitorLedger(deadlines: [due])
        for ledger in [firstLedger, secondLedger] {
            let scheduler = RunBrokerMonitorScheduler(
                ledger: ledger,
                monitor: FakeMonitor(disposition: .completed),
                timer: FakeOneShotTimer(),
                clock: FixedClock(now: now),
                random: FixedUnitRandom(value: 0.5)
            )
            try scheduler.recover()
            try scheduler.wake()
        }
        #expect(firstLedger.attemptKeys == secondLedger.attemptKeys)
    }

    @Test("Duplicate recovered rows fail closed without trapping")
    func duplicateRecoveryFailsClosed() throws {
        let now = Date(timeIntervalSince1970: 35_000)
        let first = deadline(40, dueAt: now, attempt: 0)
        let duplicate = deadline(40, dueAt: now.addingTimeInterval(1), attempt: 1)
        let ledger = FakeMonitorLedger(deadlines: [])
        ledger.recoveryRows = [first, duplicate]
        let scheduler = RunBrokerMonitorScheduler(
            ledger: ledger,
            monitor: FakeMonitor(),
            timer: FakeOneShotTimer(),
            diagnostics: NoOpRunBrokerDiagnostics()
        )
        #expect(throws: RunBrokerSchedulerError.duplicateRecoveredDeadline(first.operationID)) {
            try scheduler.recover()
        }
        #expect(!scheduler.isOperational)
    }

    @Test("Deadlines canonicalize signed due and recorded audit times to milliseconds")
    func deadlineDateCanonicalization() {
        let value = RunBrokerMonitorDeadline(
            operationID: RunBrokerOperationID(rawValue: uuid(50)),
            authority: RunBrokerAuthority(
                id: RunBrokerAuthorityID(rawValue: uuid(51)),
                epoch: .initial
            ),
            dueAt: Date(timeIntervalSince1970: 1.2349),
            recordedAt: Date(timeIntervalSince1970: 0.9879),
            attempt: 0,
            generation: uuid(52)
        )
        #expect(abs(value.dueAt.timeIntervalSince1970 - 1.234) < 0.000_001)
        #expect(abs(value.recordedAt.timeIntervalSince1970 - 0.987) < 0.000_001)
    }

    @Test("Concurrent upsert fences stale in-flight monitor completion")
    func inFlightUpsertWins() throws {
        let now = Date(timeIntervalSince1970: 36_000)
        let original = deadline(41, dueAt: now, attempt: 0)
        let replacement = deadline(41, dueAt: now.addingTimeInterval(60), attempt: 99)
        let durableReplacement = RunBrokerMonitorDeadline(
            operationID: replacement.operationID,
            authority: replacement.authority,
            dueAt: replacement.dueAt,
            recordedAt: replacement.recordedAt,
            attempt: replacement.attempt,
            generation: uuid(999)
        )
        let ledger = FakeMonitorLedger(deadlines: [original])
        let monitor = FakeMonitor(disposition: .completed)
        var scheduler: RunBrokerMonitorScheduler!
        scheduler = RunBrokerMonitorScheduler(
            ledger: ledger,
            monitor: monitor,
            timer: FakeOneShotTimer(),
            clock: FixedClock(now: now),
            diagnostics: NoOpRunBrokerDiagnostics()
        )
        monitor.onMonitor = {
            try scheduler.upsert(replacement, idempotencyKey: uuid(999))
        }
        try scheduler.recover()
        try scheduler.wake()
        #expect(try scheduler.status() == [durableReplacement])
        #expect(ledger.deadlines[original.operationID] == durableReplacement)
    }

    @Test("Ledger completion failure marks scheduler degraded and does not memory-retry")
    func ledgerFailureDegrades() throws {
        let now = Date(timeIntervalSince1970: 37_000)
        let due = deadline(42, dueAt: now, attempt: 0)
        let ledger = FakeMonitorLedger(deadlines: [due])
        ledger.failAttemptRecording = true
        let timer = FakeOneShotTimer()
        let diagnostics = RecordingSchedulerDiagnostics()
        let scheduler = RunBrokerMonitorScheduler(
            ledger: ledger,
            monitor: FakeMonitor(disposition: .completed),
            timer: timer,
            clock: FixedClock(now: now),
            diagnostics: diagnostics
        )
        try scheduler.recover()
        try scheduler.wake()
        #expect(!scheduler.isOperational)
        #expect(timer.scheduledDates.count == 1)
        #expect(diagnostics.events.contains(.schedulerOperationFailed))
    }

    @Test("Unavailable ledger fails before timer or monitor effects")
    func failBeforeEffects() throws {
        let timer = FakeOneShotTimer()
        let monitor = FakeMonitor()
        let scheduler = RunBrokerMonitorScheduler(
            ledger: UnavailableRunBrokerMonitorLedger(),
            monitor: monitor,
            timer: timer
        )
        #expect(throws: RunBrokerSchedulerError.ledgerUnavailable) {
            try scheduler.recover()
        }
        #expect(throws: RunBrokerSchedulerError.ledgerUnavailable) {
            try scheduler.upsert(
                deadline(5, dueAt: Date(), attempt: 0),
                idempotencyKey: UUID()
            )
        }
        #expect(timer.scheduledDates.isEmpty)
        #expect(monitor.monitored.isEmpty)
    }

    @Test("Endpoint reports degraded health but rejects scheduler effects without RunLedger")
    func endpointLedgerUnavailable() throws {
        let now = Date(timeIntervalSince1970: 40_000)
        let secret = try RunBrokerCapabilitySecret(bytes: Data(repeating: 4, count: 32))
        let installationID = RunBrokerInstallationID(rawValue: uuid(300))
        let authenticator = RunBrokerRequestAuthenticator(
            secret: secret,
            random: SequenceRandom()
        )
        let monitor = FakeMonitor()
        let scheduler = RunBrokerMonitorScheduler(
            ledger: UnavailableRunBrokerMonitorLedger(),
            monitor: monitor,
            timer: FakeOneShotTimer()
        )
        let endpoint = RunBrokerRequestEndpoint(
            channel: .development,
            installationID: installationID,
            brokerVersion: "test",
            authenticator: authenticator,
            peerPolicy: .init(expectedUserID: 501),
            scheduler: scheduler
        )
        let peer = RunBrokerPeerIdentity(effectiveUserID: 501, processID: 9)

        let health = try authenticator.authenticatedRequest(
            requestID: uuid(301),
            channel: .development,
            installationID: installationID,
            command: .health,
            now: now
        )
        let healthResponse = endpoint.handle(health, peer: peer, now: now)
        #expect(healthResponse.result == .health(
            .init(status: .degraded, brokerVersion: "test", ledgerAvailable: false)
        ))

        let mutation = try authenticator.authenticatedRequest(
            requestID: uuid(302),
            idempotencyKey: uuid(303),
            channel: .development,
            installationID: installationID,
            command: .scheduler(.upsert(deadline(9, dueAt: now, attempt: 0))),
            now: now
        )
        let mutationResponse = endpoint.handle(mutation, peer: peer, now: now)
        #expect(mutationResponse.error?.code == .ledgerUnavailable)
        #expect(monitor.monitored.isEmpty)
    }

    @Test("Only side-effect-free responses use ephemeral idempotency cache")
    func safeCacheOnly() throws {
        let now = Date(timeIntervalSince1970: 50_000)
        let secret = try RunBrokerCapabilitySecret(bytes: Data(repeating: 5, count: 32))
        let installationID = RunBrokerInstallationID(rawValue: uuid(400))
        let authenticator = RunBrokerRequestAuthenticator(secret: secret, random: SequenceRandom())
        let endpoint = RunBrokerRequestEndpoint(
            channel: .development,
            installationID: installationID,
            brokerVersion: "test",
            authenticator: authenticator,
            peerPolicy: .init(expectedUserID: 501),
            scheduler: .init(
                ledger: UnavailableRunBrokerMonitorLedger(),
                monitor: FakeMonitor(),
                timer: FakeOneShotTimer()
            )
        )
        let key = uuid(401)
        let first = try authenticator.authenticatedRequest(
            requestID: uuid(402),
            idempotencyKey: key,
            channel: .development,
            installationID: installationID,
            command: .health,
            now: now
        )
        let second = try authenticator.authenticatedRequest(
            requestID: uuid(403),
            idempotencyKey: key,
            channel: .development,
            installationID: installationID,
            command: .health,
            now: now
        )
        let peer = RunBrokerPeerIdentity(effectiveUserID: 501, processID: 1)
        #expect(endpoint.handle(first, peer: peer, now: now).error == nil)
        let replayed = endpoint.handle(second, peer: peer, now: now)
        #expect(replayed.requestID == second.requestID)
        #expect(replayed.result != nil)

        let conflicting = try authenticator.authenticatedRequest(
            requestID: uuid(404),
            idempotencyKey: key,
            channel: .development,
            installationID: installationID,
            command: .capabilities,
            now: now
        )
        #expect(endpoint.handle(conflicting, peer: peer, now: now).error?.code == .invalidRequest)
    }
}

private final class FakeMonitorLedger: RunBrokerMonitorLedger, @unchecked Sendable {
    private let lock = NSLock()
    var isAvailable: Bool { true }
    var deadlines: [RunBrokerOperationID: RunBrokerMonitorDeadline]
    var attemptKeys: [UUID] = []
    var recoveryRows: [RunBrokerMonitorDeadline]?
    var failAttemptRecording = false

    init(deadlines: [RunBrokerMonitorDeadline]) {
        self.deadlines = Dictionary(uniqueKeysWithValues: deadlines.map { ($0.operationID, $0) })
    }

    func recoverMonitorDeadlines() throws -> [RunBrokerMonitorDeadline] {
        lock.locked { recoveryRows ?? Array(deadlines.values) }
    }

    func upsertMonitorDeadline(
        _ deadline: RunBrokerMonitorDeadline,
        idempotencyKey: UUID
    ) throws {
        lock.locked { deadlines[deadline.operationID] = deadline }
    }

    func removeMonitorDeadline(
        operationID: RunBrokerOperationID,
        idempotencyKey: UUID
    ) throws {
        _ = lock.locked { deadlines.removeValue(forKey: operationID) }
    }

    func recordMonitorAttempt(
        expectedDeadline: RunBrokerMonitorDeadline,
        attemptedAt: Date,
        disposition: RunBrokerMonitorAttemptDisposition,
        nextDueAt: Date?,
        idempotencyKey: UUID
    ) throws -> RunBrokerMonitorAttemptCommit {
        try lock.locked {
            if failAttemptRecording { throw RunBrokerLedgerError.unavailable }
            guard deadlines[expectedDeadline.operationID] == expectedDeadline else {
                return .stale
            }
            attemptKeys.append(idempotencyKey)
            if disposition == .retryableFailure, let nextDueAt {
                deadlines[expectedDeadline.operationID] = .init(
                    operationID: expectedDeadline.operationID,
                    authority: expectedDeadline.authority,
                    dueAt: nextDueAt,
                    recordedAt: attemptedAt,
                    attempt: expectedDeadline.attempt == UInt64.max
                        ? UInt64.max
                        : expectedDeadline.attempt + 1,
                    generation: idempotencyKey
                )
            } else {
                deadlines[expectedDeadline.operationID] = nil
            }
            return .applied
        }
    }
}

private final class FakeMonitor: RunBrokerExternalOperationMonitoring, @unchecked Sendable {
    private let disposition: RunBrokerMonitorAttemptDisposition
    var monitored: [RunBrokerOperationID] = []
    var onMonitor: (() throws -> Void)?

    init(disposition: RunBrokerMonitorAttemptDisposition = .completed) {
        self.disposition = disposition
    }

    func monitor(operationID: RunBrokerOperationID) throws -> RunBrokerMonitorAttemptResult {
        monitored.append(operationID)
        try onMonitor?()
        return .init(disposition: disposition)
    }
}

private final class RecordingSchedulerDiagnostics: RunBrokerDiagnosing, @unchecked Sendable {
    var events: [RunBrokerDiagnosticEvent] = []
    func record(_ event: RunBrokerDiagnosticEvent, error: any Error) { events.append(event) }
}

private final class FakeDeadlineToken: RunBrokerScheduledDeadline, @unchecked Sendable {
    var cancelled = false
    func cancel() { cancelled = true }
}

private final class FakeOneShotTimer: RunBrokerOneShotTimer, @unchecked Sendable {
    var scheduledDates: [Date] = []
    var actions: [@Sendable () -> Void] = []

    func schedule(
        at deadline: Date,
        _ action: @escaping @Sendable () -> Void
    ) -> any RunBrokerScheduledDeadline {
        scheduledDates.append(deadline)
        actions.append(action)
        return FakeDeadlineToken()
    }
}

private struct FixedClock: RunBrokerSchedulerClock {
    let now: Date
}

private struct FixedUnitRandom: RunBrokerSchedulerRandomSource {
    let value: Double
    func nextUnitInterval() -> Double { value }
}

private final class SequenceRandom: RunBrokerRandomGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt8 = 0
    func randomBytes(count: Int) throws -> Data {
        lock.locked {
            next &+= 1
            return Data(repeating: next, count: count)
        }
    }
}

private func deadline(_ value: Int, dueAt: Date, attempt: UInt64) -> RunBrokerMonitorDeadline {
    .init(
        operationID: RunBrokerOperationID(rawValue: uuid(value)),
        authority: RunBrokerAuthority(
            id: RunBrokerAuthorityID(rawValue: uuid(value + 20_000)),
            epoch: .init(rawValue: UInt64(value + 1))
        ),
        dueAt: dueAt,
        recordedAt: dueAt.addingTimeInterval(-1),
        attempt: attempt,
        generation: uuid(value + 10_000)
    )
}

private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func uuid(_ suffix: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
}
