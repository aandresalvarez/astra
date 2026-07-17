import ASTRACore
@testable import ASTRARunLedger
import Foundation
import Testing
@testable import RunBrokerKit

@Suite("RunBroker canonical RunLedger adapter")
struct RunBrokerRunLedgerAdapterTests {
    @Test("Live composition opens the channel-scoped canonical ledger")
    func liveCompositionPath() throws {
        let fixture = try AdapterLedgerFixture()
        defer { fixture.cleanup() }
        let identity = RunBrokerChannelIdentity(
            channel: .development,
            homeDirectory: fixture.root.appendingPathComponent("home", isDirectory: true),
            channelApplicationSupportDirectory: fixture.root.appendingPathComponent(
                "AstraDev",
                isDirectory: true
            )
        )
        try FileManager.default.createDirectory(
            at: identity.supportDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: identity.supportDirectory.path
        )

        let adapter = try RunBrokerRunLedgerAdapter(
            identity: identity,
            installationID: fixture.installationID
        )
        #expect(adapter.isAvailable)
        #expect(try adapter.recoverMonitorDeadlines().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: identity.ledgerDirectoryURL.appendingPathComponent(
                RunLedgerConfiguration.databaseFileName
            ).path
        ))
    }

    @Test("Signed scheduler mutations carry their complete exact CAS projection")
    func wireCarriesExactSchedule() throws {
        let fixture = try AdapterLedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let operation = try fixture.createActiveOperation(in: ledger, seed: 100)
        let expected = fixture.deadline(
            operation: operation,
            dueOffset: 10.9999,
            recordedOffset: 3.4444,
            attempt: 2,
            generation: adapterUUID(110)
        )
        let next = fixture.deadline(
            operation: operation,
            dueOffset: 20.8888,
            recordedOffset: 4.3333,
            attempt: 3,
            generation: adapterUUID(111)
        )
        let secret = try RunBrokerCapabilitySecret(bytes: Data(repeating: 7, count: 32))
        let authenticator = RunBrokerRequestAuthenticator(
            secret: secret,
            random: AdapterRandom()
        )
        let upsert = try authenticator.authenticatedRequest(
            requestID: adapterUUID(112),
            idempotencyKey: adapterUUID(113),
            channel: .development,
            installationID: fixture.installationID,
            command: .scheduler(.upsert(.init(deadline: next, replacing: expected))),
            now: fixture.date(5)
        )
        let removal = try authenticator.authenticatedRequest(
            requestID: adapterUUID(114),
            idempotencyKey: adapterUUID(115),
            channel: .development,
            installationID: fixture.installationID,
            command: .scheduler(.remove(.init(
                expected: expected,
                occurredAt: fixture.date(6.9876)
            ))),
            now: fixture.date(6)
        )
        let wire = RunBrokerWireCodec()

        #expect(try wire.decodeRequest(frame: wire.encode(request: upsert)) == upsert)
        let decodedRemoval = try wire.decodeRequest(frame: wire.encode(request: removal))
        #expect(decodedRemoval == removal)
        guard case .scheduler(.remove(let mutation)) = decodedRemoval.command else {
            Issue.record("Expected exact scheduler removal")
            return
        }
        #expect(mutation.expected == expected)
        #expect(mutation.occurredAt == canonicalAdapterDate(fixture.date(6.9876)))
    }

    @Test("Two connections fence stale CAS and endpoint reconciles durable truth")
    func twoConnectionCASAndReconciliation() throws {
        let fixture = try AdapterLedgerFixture()
        defer { fixture.cleanup() }
        let first = try fixture.open()
        defer { try? first.close() }
        let operation = try fixture.createActiveOperation(in: first, seed: 200)
        let second = try fixture.open(expectedStoreID: first.identity.storeID)
        defer { try? second.close() }
        let firstAdapter = RunBrokerRunLedgerAdapter(ledger: first)
        let secondAdapter = RunBrokerRunLedgerAdapter(ledger: second)
        let scheduler = RunBrokerMonitorScheduler(
            ledger: firstAdapter,
            monitor: AdapterMonitor(),
            timer: AdapterTimer(),
            clock: AdapterClock(now: fixture.date(50)),
            diagnostics: NoOpRunBrokerDiagnostics()
        )
        try scheduler.recover()
        let initialKey = adapterUUID(210)
        let initialRequest = fixture.deadline(
            operation: operation,
            dueOffset: 10.9876,
            recordedOffset: 3.1239,
            attempt: 0,
            generation: adapterUUID(999)
        )
        try scheduler.upsert(initialRequest, replacing: nil, idempotencyKey: initialKey)
        let initial = try #require(scheduler.status().first)
        #expect(initial.generation == initialKey)
        #expect(initial.authority == operation.authority)
        #expect(initial.dueAt == canonicalAdapterDate(initialRequest.dueAt))
        #expect(initial.recordedAt == canonicalAdapterDate(initialRequest.recordedAt))

        let rowsAfterInitial = try first.events().count
        try scheduler.upsert(initialRequest, replacing: nil, idempotencyKey: initialKey)
        #expect(try first.events().count == rowsAfterInitial)
        #expect(try first.outbox().count == rowsAfterInitial)

        let winnerKey = adapterUUID(211)
        let winnerRequest = fixture.deadline(
            operation: operation,
            dueOffset: 20,
            recordedOffset: 4,
            attempt: 1,
            generation: winnerKey
        )
        #expect(try secondAdapter.upsertMonitorDeadline(
            winnerRequest,
            replacing: initial,
            idempotencyKey: winnerKey
        ) == .appended)
        let winner = try #require(secondAdapter.recoverMonitorDeadlines().first)
        let rowsAfterWinner = try first.events().count
        let auditBeforeConflict = try adapterAuditCount(first)

        let secret = try RunBrokerCapabilitySecret(bytes: Data(repeating: 9, count: 32))
        let authenticator = RunBrokerRequestAuthenticator(
            secret: secret,
            random: AdapterRandom()
        )
        let endpoint = RunBrokerRequestEndpoint(
            channel: .development,
            installationID: fixture.installationID,
            brokerVersion: "adapter-test",
            authenticator: authenticator,
            peerPolicy: .init(expectedUserID: 501),
            scheduler: scheduler
        )
        let loserKey = adapterUUID(212)
        let loser = fixture.deadline(
            operation: operation,
            dueOffset: 30,
            recordedOffset: 5,
            attempt: 2,
            generation: loserKey
        )
        let request = try authenticator.authenticatedRequest(
            requestID: adapterUUID(213),
            idempotencyKey: loserKey,
            channel: .development,
            installationID: fixture.installationID,
            command: .scheduler(.upsert(.init(deadline: loser, replacing: initial))),
            now: fixture.date(5)
        )
        let response = endpoint.handle(
            request,
            peer: .init(effectiveUserID: 501, processID: 42),
            now: fixture.date(5)
        )
        #expect(response.error?.code == .monitorScheduleConflict)
        #expect(response.error?.retryable == true)
        #expect(try scheduler.status() == [winner])
        #expect(scheduler.isOperational)
        #expect(try first.events().count == rowsAfterWinner)
        #expect(try first.outbox().count == rowsAfterWinner)
        #expect(try adapterAuditCount(first) == auditBeforeConflict)

        #expect(throws: RunBrokerSchedulerError.monitorScheduleConflict(operation.operationID)) {
            try scheduler.remove(
                expected: initial,
                occurredAt: fixture.date(6),
                idempotencyKey: adapterUUID(214)
            )
        }
        #expect(try scheduler.status() == [winner])
        #expect(try first.events().count == rowsAfterWinner)
        #expect(try first.outbox().count == rowsAfterWinner)

        // Replaying the old successful event must fetch the current projection,
        // not overwrite the scheduler cache with the replayed command body.
        try scheduler.upsert(initialRequest, replacing: nil, idempotencyKey: initialKey)
        #expect(try scheduler.status() == [winner])
        #expect(try first.events().count == rowsAfterWinner)
        #expect(try first.outbox().count == rowsAfterWinner)
    }

    @Test("Authority transfer and execution control share one causal authority fence")
    func authorityAndControlFence() throws {
        let fixture = try AdapterLedgerFixture()
        defer { fixture.cleanup() }
        let first = try fixture.open()
        defer { try? first.close() }
        let operation = try fixture.createActiveOperation(in: first, seed: 300)
        let second = try fixture.open(expectedStoreID: first.identity.storeID)
        defer { try? second.close() }
        let adapter = RunBrokerRunLedgerAdapter(ledger: first)
        let scheduler = RunBrokerMonitorScheduler(
            ledger: adapter,
            monitor: AdapterMonitor(),
            timer: AdapterTimer(),
            clock: AdapterClock(now: fixture.date(50)),
            diagnostics: NoOpRunBrokerDiagnostics()
        )
        let initialKey = adapterUUID(310)
        let initial = fixture.deadline(
            operation: operation,
            dueOffset: 10,
            recordedOffset: 3,
            attempt: 0,
            generation: initialKey
        )
        #expect(try adapter.upsertMonitorDeadline(
            initial,
            replacing: nil,
            idempotencyKey: initialKey
        ) == .appended)
        try scheduler.recover()

        let nextAuthority = RunBrokerAuthority(
            id: .init(rawValue: adapterUUID(311)),
            epoch: .init(rawValue: operation.authority.epoch.rawValue + 1)
        )
        try second.append(.init(
            eventID: .init(rawValue: adapterUUID(312)),
            occurredAt: fixture.date(4),
            event: .executionAuthorityTransferred(
                executionID: operation.executionID,
                expectedAuthority: operation.authority,
                newAuthority: nextAuthority
            )
        ))
        let transferred = try #require(adapter.recoverMonitorDeadlines().first)
        #expect(transferred.authority == nextAuthority)
        #expect(transferred.dueAt == initial.dueAt)
        #expect(transferred.recordedAt == initial.recordedAt)
        #expect(transferred.attempt == initial.attempt)
        #expect(transferred.generation == initial.generation)
        let rowsAfterTransfer = try first.events().count
        let staleReplacement = fixture.deadline(
            operation: operation,
            dueOffset: 20,
            recordedOffset: 5,
            attempt: 1,
            generation: adapterUUID(319)
        )
        #expect(throws: RunBrokerSchedulerError.monitorScheduleConflict(operation.operationID)) {
            try scheduler.upsert(
                staleReplacement,
                replacing: initial,
                idempotencyKey: adapterUUID(319)
            )
        }
        #expect(try scheduler.status() == [transferred])
        #expect(try first.events().count == rowsAfterTransfer)
        #expect(try first.outbox().count == rowsAfterTransfer)

        #expect(adapterLedgerError {
            try first.append(.init(
                eventID: .init(rawValue: adapterUUID(313)),
                occurredAt: fixture.date(5),
                event: .executionAuthorityTransferred(
                    executionID: operation.executionID,
                    expectedAuthority: nextAuthority,
                    newAuthority: .init(
                        id: .init(rawValue: adapterUUID(314)),
                        epoch: .init(rawValue: nextAuthority.epoch.rawValue + 2)
                    )
                )
            ))
        } == .invalidEvent("Authority transfer must advance exactly one epoch"))
        #expect(adapterLedgerError {
            try first.append(.init(
                eventID: .init(rawValue: adapterUUID(315)),
                occurredAt: fixture.date(5),
                event: .executionControlTransitioned(
                    executionID: operation.executionID,
                    authority: operation.authority,
                    transition: .executionStarted,
                    backendCapabilities: .monitoringOnly
                )
            ))
        } == .claimTransitionRejected(.staleEpochRejected))
        #expect(try first.events().count == rowsAfterTransfer)
        #expect(try first.outbox().count == rowsAfterTransfer)

        try first.append(.init(
            eventID: .init(rawValue: adapterUUID(316)),
            occurredAt: fixture.date(5),
            event: .executionControlTransitioned(
                executionID: operation.executionID,
                authority: nextAuthority,
                transition: .executionStarted,
                backendCapabilities: .monitoringOnly
            )
        ))
        let rowsAfterControl = try first.events().count
        #expect(adapterLedgerError {
            _ = try adapter.recordMonitorAttempt(
                expectedDeadline: transferred,
                attemptedAt: fixture.date(3.5),
                disposition: .retryableFailure,
                nextDueAt: fixture.date(20),
                idempotencyKey: adapterUUID(317)
            )
        } == .invalidEvent("Applied monitor evidence predates the current operation claim"))
        #expect(try first.events().count == rowsAfterControl)

        let attemptKey = adapterUUID(318)
        #expect(try adapter.recordMonitorAttempt(
            expectedDeadline: transferred,
            attemptedAt: fixture.date(11),
            disposition: .retryableFailure,
            nextDueAt: fixture.date(20.5559),
            idempotencyKey: attemptKey
        ) == .applied)
        let retry = try #require(adapter.recoverMonitorDeadlines().first)
        #expect(retry.authority == nextAuthority)
        #expect(retry.recordedAt == fixture.date(11))
        #expect(retry.dueAt == canonicalAdapterDate(fixture.date(20.5559)))
        #expect(retry.attempt == 1)
        #expect(retry.generation == attemptKey)
    }

    @Test("A stale attempt is journaled once and exact replay duplicates no durable row")
    func staleAttemptExactReplay() throws {
        let fixture = try AdapterLedgerFixture()
        defer { fixture.cleanup() }
        let ledger = try fixture.open()
        defer { try? ledger.close() }
        let operation = try fixture.createActiveOperation(in: ledger, seed: 400)
        let adapter = RunBrokerRunLedgerAdapter(ledger: ledger)
        let scheduleKey = adapterUUID(410)
        let current = fixture.deadline(
            operation: operation,
            dueOffset: 10,
            recordedOffset: 3,
            attempt: 0,
            generation: scheduleKey
        )
        #expect(try adapter.upsertMonitorDeadline(
            current,
            replacing: nil,
            idempotencyKey: scheduleKey
        ) == .appended)
        #expect(try adapter.upsertMonitorDeadline(
            current,
            replacing: nil,
            idempotencyKey: scheduleKey
        ) == .exactReplay)
        let stale = RunBrokerMonitorDeadline(
            operationID: current.operationID,
            authority: current.authority,
            dueAt: current.dueAt,
            recordedAt: current.recordedAt,
            attempt: current.attempt,
            generation: adapterUUID(411)
        )
        let key = adapterUUID(412)
        let eventsBefore = try ledger.events().count
        let outboxBefore = try ledger.outbox().count
        let auditBefore = try adapterAuditCount(ledger)

        #expect(try adapter.recordMonitorAttempt(
            expectedDeadline: stale,
            attemptedAt: fixture.date(11),
            disposition: .completed,
            nextDueAt: nil,
            idempotencyKey: key
        ) == .stale)
        #expect(try adapter.recordMonitorAttempt(
            expectedDeadline: stale,
            attemptedAt: fixture.date(11),
            disposition: .completed,
            nextDueAt: nil,
            idempotencyKey: key
        ) == .stale)
        #expect(try ledger.events().count == eventsBefore + 1)
        #expect(try ledger.outbox().count == outboxBefore + 1)
        #expect(try adapterAuditCount(ledger) == auditBefore + 1)
        #expect(try adapter.recoverMonitorDeadlines() == [current])
        #expect(try ledger.projection().operations[operation.operationID]?.record.holdsEffects == true)
    }
}
