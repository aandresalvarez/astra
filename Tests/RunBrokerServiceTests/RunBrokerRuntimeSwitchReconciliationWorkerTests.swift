import Foundation
import Testing
import ASTRACore
import ASTRARunLedger
@testable import RunBrokerKit
import RunBrokerPolicy
@testable import RunBrokerService

@Suite("RunBroker runtime-switch reconciliation worker")
struct RunBrokerRuntimeSwitchReconciliationWorkerTests {
    @Test("same-wake archive preserves keyed history and exact retries across backend changes")
    func replacementRunningArchivesBeforeWorkerQuiesces() throws {
        let fixture = try BrokerFixture()
        try fixture.admitOnly()
        let requestID = RuntimeSwitchRequestID(rawValue: brokerUUID(160))
        let source = try RuntimeSwitchSourceFence(
            manifest: fixture.manifest,
            manifestSHA256: RuntimeSwitchDigests.manifest(fixture.manifest)
        )
        let target = try runtimeSwitchTarget(
            fixture: fixture,
            requestID: requestID,
            executionID: .init(rawValue: brokerUUID(161)),
            revision: "worker-target-1"
        )
        let request = try ActiveRuntimeSwitchRequest.defaultHandoff(intent: .init(
            requestID: requestID,
            mode: .graceful,
            expectedSource: source,
            target: target,
            requestedAt: brokerTestDate
        ))
        let digest = try RuntimeSwitchDigests.request(request)
        let reservationID = RuntimeSwitchEvidenceID(rawValue: brokerUUID(162))
        _ = try fixture.ledger.admitRuntimeSwitch(
            request: request,
            requestDigest: digest,
            reservationID: reservationID,
            forceChallenge: nil,
            eventID: .init(rawValue: brokerUUID(163)),
            occurredAt: brokerTestDate
        )
        var state = try fixture.ledger.projection().runtimeSwitchPolicyState
        let reservation = try #require(state.record?.targetReservation)
        let controlEffectID = RuntimeSwitchEffectID(rawValue: brokerUUID(164))
        let supervisor = try RuntimeSwitchSupervisorFence(
            installationID: source.installationID,
            storeID: source.storeID,
            executionID: source.executionID,
            authority: source.authority,
            cohortID: "worker-archive",
            protocolIdentity: .init(adapterID: "worker-supervisor", protocolVersion: 1)
        )
        let checkpoint = try VerifiedRuntimeSwitchCheckpointAttestation(
            request: request,
            requestDigest: digest,
            effectID: controlEffectID,
            checkpointID: .init(rawValue: "worker-checkpoint"),
            checkpointGeneration: 1,
            ledgerSequence: reservation.ledgerSequence + 1,
            effectWatermark: 0,
            toolOperationWatermark: 0,
            inFlightEffectCount: 0,
            inFlightToolOperationCount: 0,
            providerContinuation: .init(adapterID: "worker-provider", protocolVersion: 1),
            supervisor: supervisor
        )
        var next = RuntimeSwitchPolicy.observeSafeCheckpoint(state, attestation: checkpoint).state
        try transition(fixture, from: state, to: next, effectID: controlEffectID, id: 165, offset: 1)
        state = next
        let control = VerifiedRuntimeSwitchControlAcceptance(
            evidenceID: .init(rawValue: brokerUUID(166)),
            effectID: controlEffectID,
            source: source,
            ledgerSequence: checkpoint.fence.ledgerSequence + 1
        )
        next = RuntimeSwitchPolicy.acknowledgeControl(state, acceptance: control).state
        try transition(fixture, from: state, to: next, effectID: nil, id: 167, offset: 2)
        state = next
        let replacementEffectID = RuntimeSwitchEffectID(rawValue: brokerUUID(168))
        let terminal = try VerifiedRuntimeSwitchTerminalAttestation(
            evidenceID: .init(rawValue: brokerUUID(169)),
            source: source,
            observedState: .cancelled,
            ledgerSequence: control.ledgerSequence + 1,
            replacementEffectID: replacementEffectID
        )
        next = RuntimeSwitchPolicy.observeSourceTerminal(state, attestation: terminal).state
        try transition(
            fixture,
            from: state,
            to: next,
            effectID: replacementEffectID,
            id: 170,
            offset: 3
        )
        state = next
        let replacement = VerifiedRuntimeSwitchReplacementAcceptance(
            evidenceID: .init(rawValue: brokerUUID(171)),
            effectID: replacementEffectID,
            targetReservationID: reservationID,
            targetExecutionID: target.manifest.executionID,
            targetManifestSHA256: target.manifestSHA256,
            ledgerSequence: terminal.terminalFence.ledgerSequence + 1
        )
        next = RuntimeSwitchPolicy.acknowledgeReplacement(state, acceptance: replacement).state
        try transition(fixture, from: state, to: next, effectID: nil, id: 172, offset: 4)
        #expect(next.record?.progress == .awaitingReplacementRunning)

        let runtimeService = RunBrokerRuntimeSwitchService(
            ledger: fixture.ledger,
            vault: fixture.vault,
            orchestrator: fixture.orchestrator(),
            backend: ReplacementRunningOnlyBackend(
                evidence: .init(
                    evidenceID: .init(rawValue: brokerUUID(173)),
                    ledgerSequence: replacement.ledgerSequence + 1
                )
            )
        )
        let clock = RuntimeSwitchWorkerClock(now: brokerTestDate.addingTimeInterval(5))
        let timer = RuntimeSwitchWorkerTimer()
        let worker = RunBrokerRuntimeSwitchReconciliationWorker(
            service: runtimeService,
            timer: timer,
            clock: clock,
            random: RuntimeSwitchWorkerRandom(),
            backoff: .init(initialDelay: 5, maximumDelay: 10, jitterFraction: 0)
        )
        worker.start()
        try timer.fireNext()
        let archived = try fixture.ledger.projection()
        #expect(archived.runtimeSwitchPolicyState.record == nil)
        #expect(archived.runtimeSwitchArchivedRecords[requestID]?.requestDigest == digest)
        #expect(timer.activeDeadlines.isEmpty)

        let nextRequestID = RuntimeSwitchRequestID(rawValue: brokerUUID(174))
        let nextTarget = try runtimeSwitchTarget(
            fixture: fixture,
            requestID: nextRequestID,
            executionID: .init(rawValue: brokerUUID(175)),
            revision: "worker-target-2"
        )
        let nextRequest = try ActiveRuntimeSwitchRequest.defaultHandoff(intent: .init(
            requestID: nextRequestID,
            mode: .graceful,
            expectedSource: source,
            target: nextTarget,
            requestedAt: brokerTestDate.addingTimeInterval(6)
        ))
        #expect(try fixture.ledger.admitRuntimeSwitch(
            request: nextRequest,
            requestDigest: RuntimeSwitchDigests.request(nextRequest),
            reservationID: .init(rawValue: brokerUUID(176)),
            forceChallenge: nil,
            eventID: .init(rawValue: brokerUUID(177)),
            occurredAt: brokerTestDate.addingTimeInterval(6)
        ).disposition == .appended)
        try archiveCurrentGracefulSwitch(fixture, seed: 180)

        let thirdRequestID = RuntimeSwitchRequestID(rawValue: brokerUUID(194))
        let thirdTarget = try runtimeSwitchTarget(
            fixture: fixture,
            requestID: thirdRequestID,
            executionID: .init(rawValue: brokerUUID(195)),
            revision: "worker-target-3"
        )
        let thirdRequest = try ActiveRuntimeSwitchRequest.defaultHandoff(intent: .init(
            requestID: thirdRequestID,
            mode: .graceful,
            expectedSource: source,
            target: thirdTarget,
            requestedAt: brokerTestDate.addingTimeInterval(7)
        ))
        _ = try fixture.ledger.admitRuntimeSwitch(
            request: thirdRequest,
            requestDigest: RuntimeSwitchDigests.request(thirdRequest),
            reservationID: .init(rawValue: brokerUUID(196)),
            forceChallenge: nil,
            eventID: .init(rawValue: brokerUUID(197)),
            occurredAt: brokerTestDate.addingTimeInterval(7)
        )
        try archiveCurrentGracefulSwitch(fixture, seed: 200)

        let projection = try fixture.ledger.projection()
        #expect(projection.runtimeSwitchArchivedRecords.count == 3)
        #expect(projection.runtimeSwitchArchivedRecords[requestID]?.requestDigest == digest)

        let replay = RunBrokerApplicationRuntimeSwitchSubmission(
            requestID: requestID,
            mode: .graceful,
            expectedSource: source,
            targetDraft: .init(
                executionID: target.manifest.executionID,
                taskID: target.manifest.taskID,
                configuration: target.manifest.configuration,
                declaredEffects: target.manifest.declaredEffects,
                supervisionPolicy: try #require(target.manifest.supervisionPolicy),
                createdAt: target.manifest.createdAt
            ),
            requestedAt: request.intent.requestedAt,
            targetProtocol: .baseline
        )
        let beforeReplay = try fixture.ledger.events(limit: 1_000)
        #expect(try runtimeService.submit(
            replay,
            now: brokerTestDate.addingTimeInterval(3_600)
        ).progress == .archived)
        #expect(try fixture.ledger.events(limit: 1_000) == beforeReplay)
    }

    @Test("reconciliation failures expose bounded degraded health")
    func failureHealthIsBoundedAndStructured() throws {
        let clock = RuntimeSwitchWorkerClock(now: Date(timeIntervalSince1970: 900))
        let timer = RuntimeSwitchWorkerTimer()
        let worker = makeWorker(
            clock: clock,
            timer: timer,
            signals: RuntimeSwitchWorkerSignals(),
            attempts: RuntimeSwitchWorkerAttempts([])
        )
        #expect(worker.healthSnapshot().state == .stopped)
        worker.start()
        try timer.fireNext()
        let health = worker.healthSnapshot()
        #expect(health.state == .degraded)
        #expect(health.consecutiveFailures == 1)
        #expect(health.lastFailureAt == clock.now)
        #expect((health.lastErrorType?.utf8.count ?? 0) <= 256)
        #expect(health.lastErrorType?.contains("RuntimeSwitchWorkerTestError") == true)
    }

    @Test("startup reconciliation is broker-owned, coalesced, and quiesces when idle")
    func startupPassIsCoalesced() throws {
        let clock = RuntimeSwitchWorkerClock(now: Date(timeIntervalSince1970: 1_000))
        let timer = RuntimeSwitchWorkerTimer()
        let signals = RuntimeSwitchWorkerSignals()
        let attempts = RuntimeSwitchWorkerAttempts([.idle])
        let worker = makeWorker(
            clock: clock,
            timer: timer,
            signals: signals,
            attempts: attempts
        )

        worker.start()
        worker.start()
        #expect(timer.activeDeadlines == [clock.now])
        try timer.fireNext()
        #expect(attempts.recordedDates == [clock.now])
        #expect(timer.activeDeadlines.isEmpty)
        #expect(signals.installCount == 1)
    }

    @Test("pending durable state retries with capped backoff and mutation signals preempt delay")
    func pendingStateRetriesWithBoundedBackoff() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let clock = RuntimeSwitchWorkerClock(now: start)
        let timer = RuntimeSwitchWorkerTimer()
        let signals = RuntimeSwitchWorkerSignals()
        let attempts = RuntimeSwitchWorkerAttempts([.pending, .pending, .completed])
        let worker = makeWorker(
            clock: clock,
            timer: timer,
            signals: signals,
            attempts: attempts,
            backoff: .init(initialDelay: 5, maximumDelay: 8, jitterFraction: 0)
        )

        worker.start()
        try timer.fireNext()
        #expect(timer.activeDeadlines == [start.addingTimeInterval(5)])

        clock.now = start.addingTimeInterval(5)
        try timer.fireNext()
        #expect(timer.activeDeadlines == [start.addingTimeInterval(13)])

        signals.signal()
        #expect(timer.activeDeadlines == [clock.now])
        try timer.fireNext()
        #expect(timer.activeDeadlines.isEmpty)
        #expect(attempts.recordedDates == [start, start.addingTimeInterval(5), clock.now])
    }

    @Test("stop removes the mutation signal and cancels pending work")
    func stopCancelsPendingWork() {
        let clock = RuntimeSwitchWorkerClock(now: Date(timeIntervalSince1970: 3_000))
        let timer = RuntimeSwitchWorkerTimer()
        let signals = RuntimeSwitchWorkerSignals()
        let attempts = RuntimeSwitchWorkerAttempts([.pending])
        let worker = makeWorker(
            clock: clock,
            timer: timer,
            signals: signals,
            attempts: attempts
        )

        worker.start()
        worker.stop()
        #expect(timer.activeDeadlines.isEmpty)
        #expect(signals.removeCount == 1)
        signals.signal()
        #expect(timer.activeDeadlines.isEmpty)
    }

    @Test("a callback fired before schedule returns cannot overwrite its retry")
    func synchronousScheduleCallbackPreservesRetry() throws {
        let start = Date(timeIntervalSince1970: 4_000)
        let clock = RuntimeSwitchWorkerClock(now: start)
        let timer = RuntimeSwitchWorkerTimer(firesFirstBeforeReturning: true)
        let signals = RuntimeSwitchWorkerSignals()
        let attempts = RuntimeSwitchWorkerAttempts([.pending, .completed])
        let worker = makeWorker(
            clock: clock,
            timer: timer,
            signals: signals,
            attempts: attempts
        )

        worker.start()
        #expect(attempts.recordedDates == [start])
        #expect(timer.activeDeadlines == [start.addingTimeInterval(5)])
        clock.now = start.addingTimeInterval(5)
        try timer.fireNext()
        #expect(timer.activeDeadlines.isEmpty)
    }

    @Test("a mutation signal during reconciliation supersedes the stale retry")
    func signalDuringFireWins() throws {
        let start = Date(timeIntervalSince1970: 5_000)
        let clock = RuntimeSwitchWorkerClock(now: start)
        let timer = RuntimeSwitchWorkerTimer()
        let signals = RuntimeSwitchWorkerSignals()
        let attempts = RuntimeSwitchWorkerAttempts([.pending, .completed]) { index in
            if index == 0 { signals.signal() }
        }
        let worker = makeWorker(
            clock: clock,
            timer: timer,
            signals: signals,
            attempts: attempts
        )

        worker.start()
        try timer.fireNext()
        #expect(timer.activeDeadlines == [start])
        try timer.fireNext()
        #expect(timer.activeDeadlines.isEmpty)
        #expect(attempts.recordedDates == [start, start])
    }

    private func makeWorker(
        clock: RuntimeSwitchWorkerClock,
        timer: RuntimeSwitchWorkerTimer,
        signals: RuntimeSwitchWorkerSignals,
        attempts: RuntimeSwitchWorkerAttempts,
        backoff: RunBrokerBackoffPolicy = .init(
            initialDelay: 5,
            maximumDelay: 15,
            jitterFraction: 0
        )
    ) -> RunBrokerRuntimeSwitchReconciliationWorker {
        RunBrokerRuntimeSwitchReconciliationWorker(
            reconcile: { try attempts.reconcile(at: $0) },
            installSignal: { signals.install($0) },
            removeSignal: { signals.remove() },
            timer: timer,
            clock: clock,
            random: RuntimeSwitchWorkerRandom(),
            backoff: backoff
        )
    }
}

private func runtimeSwitchTarget(
    fixture: BrokerFixture,
    requestID: RuntimeSwitchRequestID,
    executionID: RunBrokerExecutionID,
    revision: String
) throws -> RuntimeSwitchResolvedTarget {
    let configuration = ExecutionLaunchConfigurationSnapshot(
        runtimeID: .claudeCode,
        executablePath: "/usr/bin/true",
        workingDirectory: "/tmp",
        configurationRevision: revision
    )
    let policy = try #require(fixture.manifest.supervisionPolicy)
    let authority = try RunBrokerAuthorityDerivation.runtimeSwitchTarget(
        installationID: fixture.manifest.installationID,
        storeID: fixture.manifest.storeID,
        requestID: requestID,
        executionID: executionID,
        taskID: fixture.manifest.taskID,
        configuration: configuration,
        declaredEffects: fixture.manifest.declaredEffects,
        supervisionPolicy: policy,
        createdAt: brokerTestDate
    )
    let manifest = ExecutionLaunchManifest(
        installationID: fixture.manifest.installationID,
        storeID: fixture.manifest.storeID,
        executionID: executionID,
        taskID: fixture.manifest.taskID,
        authority: authority,
        configuration: configuration,
        declaredEffects: fixture.manifest.declaredEffects,
        supervisionPolicy: policy,
        createdAt: brokerTestDate
    )
    return try .init(
        manifest: manifest,
        manifestSHA256: RuntimeSwitchDigests.manifest(manifest)
    )
}

private func transition(
    _ fixture: BrokerFixture,
    from expected: RuntimeSwitchPolicyState,
    to next: RuntimeSwitchPolicyState,
    effectID: RuntimeSwitchEffectID?,
    id: UInt8,
    offset: TimeInterval
) throws {
    _ = try fixture.ledger.transitionRuntimeSwitchPolicy(
        expected: expected,
        next: next,
        effectID: effectID,
        eventID: .init(rawValue: brokerUUID(id)),
        occurredAt: brokerTestDate.addingTimeInterval(offset)
    )
}

/// Drives the currently admitted graceful switch through only policy-owned
/// evidence and archives it. IDs are deterministic per seed so history tests
/// can prove that older records survive multiple later rollovers.
private func archiveCurrentGracefulSwitch(
    _ fixture: BrokerFixture,
    seed: UInt8
) throws {
    var state = try fixture.ledger.projection().runtimeSwitchPolicyState
    let record = try #require(state.record)
    let request = record.request
    let digest = record.requestDigest
    let source = request.intent.expectedSource
    let reservation = record.targetReservation
    let controlEffectID = RuntimeSwitchEffectID(rawValue: brokerUUID(seed))
    let supervisor = try RuntimeSwitchSupervisorFence(
        installationID: source.installationID,
        storeID: source.storeID,
        executionID: source.executionID,
        authority: source.authority,
        cohortID: "history-\(seed)",
        protocolIdentity: .init(adapterID: "history-supervisor", protocolVersion: 1)
    )
    let checkpoint = try VerifiedRuntimeSwitchCheckpointAttestation(
        request: request,
        requestDigest: digest,
        effectID: controlEffectID,
        checkpointID: .init(rawValue: "history-checkpoint-\(seed)"),
        checkpointGeneration: 1,
        ledgerSequence: reservation.ledgerSequence + 1,
        effectWatermark: 0,
        toolOperationWatermark: 0,
        inFlightEffectCount: 0,
        inFlightToolOperationCount: 0,
        providerContinuation: .init(adapterID: "history-provider", protocolVersion: 1),
        supervisor: supervisor
    )
    var next = RuntimeSwitchPolicy.observeSafeCheckpoint(state, attestation: checkpoint).state
    try transition(
        fixture,
        from: state,
        to: next,
        effectID: controlEffectID,
        id: seed &+ 1,
        offset: TimeInterval(seed)
    )
    state = next

    let control = VerifiedRuntimeSwitchControlAcceptance(
        evidenceID: .init(rawValue: brokerUUID(seed &+ 2)),
        effectID: controlEffectID,
        source: source,
        ledgerSequence: checkpoint.fence.ledgerSequence + 1
    )
    next = RuntimeSwitchPolicy.acknowledgeControl(state, acceptance: control).state
    try transition(
        fixture,
        from: state,
        to: next,
        effectID: nil,
        id: seed &+ 3,
        offset: TimeInterval(seed) + 1
    )
    state = next

    let replacementEffectID = RuntimeSwitchEffectID(rawValue: brokerUUID(seed &+ 4))
    let terminal = try VerifiedRuntimeSwitchTerminalAttestation(
        evidenceID: .init(rawValue: brokerUUID(seed &+ 5)),
        source: source,
        observedState: .cancelled,
        ledgerSequence: control.ledgerSequence + 1,
        replacementEffectID: replacementEffectID
    )
    next = RuntimeSwitchPolicy.observeSourceTerminal(state, attestation: terminal).state
    try transition(
        fixture,
        from: state,
        to: next,
        effectID: replacementEffectID,
        id: seed &+ 6,
        offset: TimeInterval(seed) + 2
    )
    state = next

    let replacement = VerifiedRuntimeSwitchReplacementAcceptance(
        evidenceID: .init(rawValue: brokerUUID(seed &+ 7)),
        effectID: replacementEffectID,
        targetReservationID: reservation.reservationID,
        targetExecutionID: request.intent.target.manifest.executionID,
        targetManifestSHA256: request.intent.target.manifestSHA256,
        ledgerSequence: terminal.terminalFence.ledgerSequence + 1
    )
    next = RuntimeSwitchPolicy.acknowledgeReplacement(state, acceptance: replacement).state
    try transition(
        fixture,
        from: state,
        to: next,
        effectID: nil,
        id: seed &+ 8,
        offset: TimeInterval(seed) + 3
    )
    state = next

    let running = VerifiedRuntimeSwitchReplacementRunningAttestation(
        evidenceID: .init(rawValue: brokerUUID(seed &+ 9)),
        targetReservationID: reservation.reservationID,
        targetExecutionID: request.intent.target.manifest.executionID,
        targetManifestSHA256: request.intent.target.manifestSHA256,
        ledgerSequence: replacement.ledgerSequence + 1
    )
    next = RuntimeSwitchPolicy.observeReplacementRunning(state, attestation: running).state
    try transition(
        fixture,
        from: state,
        to: next,
        effectID: nil,
        id: seed &+ 10,
        offset: TimeInterval(seed) + 4
    )
    _ = try fixture.ledger.archiveRuntimeSwitchCompletion(
        expected: next,
        archiveEvidenceID: .init(rawValue: brokerUUID(seed &+ 11)),
        eventID: .init(rawValue: brokerUUID(seed &+ 12)),
        occurredAt: brokerTestDate.addingTimeInterval(TimeInterval(seed) + 5)
    )
}

private struct ReplacementRunningOnlyBackend: RunBrokerRuntimeSwitchBackend {
    let evidence: RunBrokerReplacementRunningEvidence
    let supportsGracefulHandoff = false
    let supportsImmediateTermination = false

    func safeCheckpoint(for: RuntimeSwitchRecord) throws -> RunBrokerCheckpointEvidence? { nil }
    func handoffIf(_: RuntimeSwitchControlDirective) throws {}
    func controlAcceptance(for: RuntimeSwitchRecord) throws -> RunBrokerControlAcceptanceEvidence? { nil }
    func terminalEvidence(for: RuntimeSwitchRecord) throws -> RunBrokerTerminalEvidence? { nil }
    func startReservedIf(
        reservation: RuntimeSwitchTargetReservation,
        manifestDigest: ExecutionLaunchArgumentsSHA256,
        effectID: RuntimeSwitchEffectID,
        directive: RuntimeSwitchReplacementDirective
    ) throws -> RunBrokerReplacementAcceptanceEvidence? { nil }
    func replacementRunning(for: RuntimeSwitchRecord) throws -> RunBrokerReplacementRunningEvidence? {
        evidence
    }
}

private final class RuntimeSwitchWorkerClock: RunBrokerSchedulerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) { value = now }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private struct RuntimeSwitchWorkerRandom: RunBrokerSchedulerRandomSource {
    func nextUnitInterval() -> Double { 0.5 }
}

private final class RuntimeSwitchWorkerAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var dispositions: [RunBrokerRuntimeSwitchReconciliationDisposition]
    private var dates: [Date] = []
    private let onAttempt: (@Sendable (Int) -> Void)?

    init(
        _ dispositions: [RunBrokerRuntimeSwitchReconciliationDisposition],
        onAttempt: (@Sendable (Int) -> Void)? = nil
    ) {
        self.dispositions = dispositions
        self.onAttempt = onAttempt
    }

    var recordedDates: [Date] { lock.withLock { dates } }

    func reconcile(at date: Date) throws -> RunBrokerRuntimeSwitchReconciliationDisposition {
        let result = try lock.withLock { () -> (
            index: Int,
            disposition: RunBrokerRuntimeSwitchReconciliationDisposition
        ) in
            dates.append(date)
            guard !dispositions.isEmpty else {
                throw RuntimeSwitchWorkerTestError.unexpectedAttempt
            }
            return (dates.count - 1, dispositions.removeFirst())
        }
        onAttempt?(result.index)
        return result.disposition
    }
}

private final class RuntimeSwitchWorkerSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private(set) var installCount = 0
    private(set) var removeCount = 0

    func install(_ action: @escaping @Sendable () -> Void) {
        lock.withLock {
            installCount += 1
            self.action = action
        }
    }

    func remove() {
        lock.withLock {
            removeCount += 1
            action = nil
        }
    }

    func signal() {
        let action = lock.withLock { self.action }
        action?()
    }
}

private final class RuntimeSwitchWorkerTimer: RunBrokerOneShotTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RuntimeSwitchWorkerDeadline] = []
    private let firesFirstBeforeReturning: Bool
    private var didFireSynchronously = false

    init(firesFirstBeforeReturning: Bool = false) {
        self.firesFirstBeforeReturning = firesFirstBeforeReturning
    }

    var activeDeadlines: [Date] {
        lock.withLock {
            entries.filter { !$0.isCancelled }.map(\.deadline).sorted()
        }
    }

    func schedule(
        at deadline: Date,
        _ action: @escaping @Sendable () -> Void
    ) -> any RunBrokerScheduledDeadline {
        let entry = RuntimeSwitchWorkerDeadline(deadline: deadline, action: action)
        let shouldFire = lock.withLock { () -> Bool in
            entries.append(entry)
            guard firesFirstBeforeReturning, !didFireSynchronously else { return false }
            didFireSynchronously = true
            return true
        }
        if shouldFire { entry.fire() }
        return entry
    }

    func fireNext() throws {
        let entry = lock.withLock {
            entries
                .filter { !$0.isCancelled }
                .min { $0.deadline < $1.deadline }
        }
        guard let entry else { throw RuntimeSwitchWorkerTestError.missingDeadline }
        entry.fire()
    }
}

private final class RuntimeSwitchWorkerDeadline: RunBrokerScheduledDeadline, @unchecked Sendable {
    let deadline: Date
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(deadline: Date, action: @escaping @Sendable () -> Void) {
        self.deadline = deadline
        self.action = action
    }

    var isCancelled: Bool { lock.withLock { action == nil } }

    func cancel() { lock.withLock { action = nil } }

    func fire() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { self.action = nil }
            return self.action
        }
        action?()
    }
}

private enum RuntimeSwitchWorkerTestError: Error {
    case missingDeadline
    case unexpectedAttempt
}
