import Foundation
import SwiftData
import Testing
import ASTRAModels
@testable import ASTRA

@Suite("Task external operation monitor")
@MainActor
struct TaskExternalOperationMonitorServiceTests {
    @Test("stale poll cannot overwrite a newer terminal observation")
    func stalePollCannotOverwriteTerminalObservation() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(executionState: .running)
        let observer = BlockingOperationObserver(
            observation: TaskExternalOperationObservation(executionState: .running, health: .healthy)
        )
        let service = fixture.makeService(observer: observer)

        let poll = Task { @MainActor in
            await service.poll(operationID: operation.id)
        }
        await observer.waitUntilCalled()

        operation.generation += 1
        operation.executionState = .failed
        operation.observationHealth = .healthy
        operation.terminalObservedAt = fixture.clock.now()
        operation.monitoringState = .completed
        try fixture.context.save()

        await observer.release()
        #expect(await poll.value == .staleIgnored)
        #expect(operation.executionState == .failed)
        #expect(operation.monitoringState == .completed)
    }

    @Test("manual and scheduled polls coalesce onto one backend read")
    func concurrentPollsCoalesce() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(executionState: .running)
        let observer = BlockingOperationObserver(
            observation: TaskExternalOperationObservation(executionState: .running, health: .healthy)
        )
        let service = fixture.makeService(observer: observer)

        let first = Task { @MainActor in
            await service.poll(operationID: operation.id, trigger: .scheduled)
        }
        await observer.waitUntilCalled()
        let second = Task { @MainActor in
            await service.poll(operationID: operation.id, trigger: .manual)
        }
        await Task.yield()
        await observer.release()

        #expect(await first.value == .applied)
        #expect(await second.value == .coalesced(.applied))
        #expect(await observer.callCount == 1)
    }

    @Test("unreachable observation changes health without claiming execution failed")
    func unreachablePreservesExecutionState() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(executionState: .running)
        let observer = SequenceOperationObserver(observations: [
            TaskExternalOperationObservation(executionState: .failed, health: .unreachable)
        ])
        let backoff = FixedOperationBackoff(delay: 75)
        let service = fixture.makeService(observer: observer, backoff: backoff)

        #expect(await service.poll(operationID: operation.id) == .applied)
        #expect(operation.executionState == .running)
        #expect(operation.observationHealth == .unreachable)
        #expect(operation.consecutiveObservationFailures == 1)
        #expect(operation.nextCheckAt == fixture.clock.now().addingTimeInterval(75))
        #expect(operation.terminalObservedAt == nil)
    }

    @Test("unchanged semantic observation deduplicates notifications and agent wakes")
    func semanticObservationDeduplicatesNotificationAndWake() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(executionState: .running)
        let ambiguous = TaskExternalOperationObservation(executionState: .unknown, health: .healthy)
        let observer = SequenceOperationObserver(observations: [ambiguous, ambiguous])
        let wakeSink = RecordingOperationWakeSink()
        let notificationSink = RecordingOperationNotificationSink()
        let service = fixture.makeService(
            observer: observer,
            wakeSink: wakeSink,
            notificationSink: notificationSink
        )

        #expect(await service.poll(operationID: operation.id) == .applied)
        #expect(await service.poll(operationID: operation.id) == .applied)

        #expect(await wakeSink.requests.count == 1)
        #expect(await notificationSink.notifications.count == 1)
        #expect(operation.lastWakeKey != nil)
        #expect(operation.lastNotificationKey != nil)
    }

    @Test("stopping monitoring never invokes cancellation while cancel is explicit")
    func stopMonitoringIsDistinctFromCancellation() async throws {
        let fixture = try Fixture()
        let stopped = fixture.insertOperation(externalIdentity: "docker:stopped", executionState: .running)
        let cancelled = fixture.insertOperation(externalIdentity: "docker:cancelled", executionState: .running)
        let observer = SequenceOperationObserver(observations: [])
        let canceller = RecordingOperationCanceller(
            observation: TaskExternalOperationObservation(executionState: .cancelled, health: .healthy)
        )
        let service = fixture.makeService(observer: observer, canceller: canceller)

        #expect(service.stopMonitoring(operationID: stopped.id) == .applied)
        #expect(stopped.monitoringState == .stopped)
        #expect(stopped.executionState == .running)
        #expect(await canceller.callCount == 0)

        #expect(await service.cancelExternalWork(operationID: cancelled.id) == .applied)
        #expect(await canceller.callCount == 1)
        #expect(cancelled.executionState == .cancelled)
        #expect(cancelled.monitoringState == .completed)
    }

    @Test("stopped monitoring resumes without launching or cancelling work")
    func stoppedMonitoringResumes() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(
            executionState: .running,
            observationHealth: .healthy,
            monitoringState: .stopped
        )
        let observer = SequenceOperationObserver(observations: [])
        let canceller = RecordingOperationCanceller(
            observation: .init(executionState: .cancelled, health: .healthy)
        )
        let service = fixture.makeService(observer: observer, canceller: canceller)

        #expect(service.resumeMonitoring(operationID: operation.id) == .applied)
        #expect(operation.monitoringState == .active)
        #expect(operation.executionState == .running)
        #expect(operation.observationHealth == .unknown)
        #expect(operation.nextCheckAt == fixture.clock.now())
        #expect(await observer.callCount == 0)
        #expect(await canceller.callCount == 0)
    }

    @Test("terminal operation cannot be cancelled again")
    func terminalOperationCannotBeCancelledAgain() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(
            executionState: .cancelled,
            observationHealth: .healthy,
            monitoringState: .completed
        )
        let canceller = RecordingOperationCanceller(
            observation: .init(executionState: .cancelled, health: .healthy)
        )
        let service = fixture.makeService(
            observer: SequenceOperationObserver(observations: []),
            canceller: canceller
        )

        #expect(await service.cancelExternalWork(operationID: operation.id) == .notMonitoring)
        #expect(await canceller.callCount == 0)
    }

    @Test("quarantine reactivation requires backend ownership proof before contact")
    func quarantineReactivationRequiresOwnershipProof() async throws {
        let fixture = try Fixture()
        let rejected = fixture.insertOperation(
            externalIdentity: "docker:rejected",
            executionState: .running,
            observationHealth: .quarantined,
            monitoringState: .quarantined
        )
        let accepted = fixture.insertOperation(
            externalIdentity: "docker:accepted",
            executionState: .running,
            observationHealth: .quarantined,
            monitoringState: .quarantined
        )
        let validator = SelectiveOwnershipValidator(acceptedIdentity: accepted.externalIdentity)
        let observer = SequenceOperationObserver(observations: [])
        let service = fixture.makeService(observer: observer, ownershipValidator: validator)

        #expect(await service.reactivateQuarantinedOperation(operationID: rejected.id) == .ownershipRejected)
        #expect(rejected.monitoringState == .quarantined)
        #expect(rejected.observationHealth == .quarantined)

        #expect(await service.reactivateQuarantinedOperation(operationID: accepted.id) == .applied)
        #expect(accepted.monitoringState == .active)
        #expect(accepted.observationHealth == .unknown)
        #expect(accepted.nextCheckAt == fixture.clock.now())
        #expect(await observer.callCount == 0)
        #expect(await validator.callCount == 2)
    }

    @Test("reactivating a terminal quarantined operation restores its pending wake instead of stranding it")
    func reactivationRestoresTerminalDeliveryState() async throws {
        let fixture = try Fixture()
        // A processCompleted job that was quarantined by import: reactivating it
        // to `.active` would make it invisible to both polling and terminal
        // delivery, stranding the task in waitingExternal forever.
        let operation = fixture.insertOperation(
            externalIdentity: "docker:reactivate-terminal",
            executionState: .processCompleted,
            observationHealth: .quarantined,
            monitoringState: .quarantined
        )
        let validator = SelectiveOwnershipValidator(acceptedIdentity: operation.externalIdentity)
        let wakeSink = RecordingOperationWakeSink()
        let observer = SequenceOperationObserver(observations: [])
        let service = fixture.makeService(
            observer: observer,
            ownershipValidator: validator,
            wakeSink: wakeSink
        )

        #expect(await service.reactivateQuarantinedOperation(operationID: operation.id) == .applied)
        // Restored to its delivery state, never re-polled, never re-observed.
        #expect(operation.monitoringState == .validating)
        #expect(operation.executionState == .processCompleted)
        #expect(operation.nextCheckAt == nil)
        #expect(await observer.callCount == 0)

        // Terminal reconciliation now delivers the pending completion-validation
        // wake; before the fix (.active) it delivered nothing.
        await service.runDueChecks()
        #expect(await wakeSink.requests.count == 1)
    }

    @Test("stopping the monitor suppresses an in-flight poll's wake")
    func stopSuppressesInFlightWake() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(executionState: .running)
        // Blocks mid-poll, then returns a terminal (wake-worthy) observation.
        let observer = BlockingOperationObserver(
            observation: TaskExternalOperationObservation(executionState: .processCompleted, health: .healthy)
        )
        let wakeSink = RecordingOperationWakeSink()
        let service = fixture.makeService(observer: observer, wakeSink: wakeSink)

        let poll = Task { @MainActor in await service.poll(operationID: operation.id) }
        await observer.waitUntilCalled()
        // The monitor stops (e.g. for a pending update install) while the poll is
        // still awaiting its backend read.
        service.stop()
        await observer.release()
        _ = await poll.value

        // The in-flight poll must not launch provider work after stop; the
        // transition stays unacknowledged for redelivery on the next start.
        #expect(await wakeSink.requests.isEmpty)
        #expect(operation.lastWakeKey == nil)
    }

    @Test("quarantined registrations never contact an observer")
    func quarantinedRegistrationNeverPolls() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(
            executionState: .running,
            observationHealth: .quarantined,
            monitoringState: .quarantined,
            nextCheckAt: fixture.clock.now().addingTimeInterval(-60)
        )
        let observer = SequenceOperationObserver(observations: [
            TaskExternalOperationObservation(executionState: .running, health: .healthy)
        ])
        let service = fixture.makeService(observer: observer)

        await service.reconcileAfterRestart()
        #expect(await service.poll(operationID: operation.id) == .quarantined)
        #expect(await observer.callCount == 0)
        #expect(operation.monitoringState == .quarantined)
    }

    @Test("restart reconciliation reclaims an expired lease and resumes polling")
    func restartReconciliationReclaimsExpiredLease() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(executionState: .running, nextCheckAt: nil)
        operation.leaseOwner = "dead-process"
        operation.leaseExpiresAt = fixture.clock.now().addingTimeInterval(-1)
        try fixture.context.save()
        let observer = SequenceOperationObserver(observations: [
            TaskExternalOperationObservation(executionState: .running, health: .healthy)
        ])
        let service = fixture.makeService(observer: observer)

        await service.reconcileAfterRestart()

        #expect(await observer.callCount == 1)
        #expect(operation.leaseOwner == nil)
        #expect(operation.leaseExpiresAt == nil)
        #expect(operation.executionState == .running)
        #expect(operation.nextCheckAt != nil)
    }

    @Test("wake uses latest context while retaining originating revision provenance")
    func wakeUsesLatestContextAndOriginatingProvenance() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(
            executionState: .running,
            originatingContextRevision: "capsule-revision-at-launch"
        )
        let observer = SequenceOperationObserver(observations: [
            TaskExternalOperationObservation(executionState: .processCompleted, health: .healthy)
        ])
        let wakeSink = RecordingOperationWakeSink()
        var latestContext = "old objective"
        let service = fixture.makeService(
            observer: observer,
            wakeSink: wakeSink,
            contextProvider: { _ in latestContext }
        )
        latestContext = "latest objective after user follow-up"

        #expect(await service.poll(operationID: operation.id) == .applied)
        let request = try #require(await wakeSink.requests.first)
        #expect(request.latestContext == "latest objective after user follow-up")
        #expect(request.originatingContextRevision == "capsule-revision-at-launch")
        #expect(request.intent == .completionValidation)
        #expect(request.originatingRunID == operation.originatingRunID)
        #expect(operation.executionState == .processCompleted)
        #expect(operation.monitoringState == .validating)
    }

    @Test("restart redelivers unacknowledged completion validation exactly until acknowledged")
    func restartRedeliversUnacknowledgedCompletionValidation() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(
            executionState: .processCompleted,
            observationHealth: .healthy,
            monitoringState: .validating,
            originatingContextRevision: "launch-revision"
        )
        let observer = SequenceOperationObserver(observations: [])
        let wakeSink = RecordingOperationWakeSink()
        let notificationSink = RecordingOperationNotificationSink()
        var latestContext = "context after restart"
        let service = fixture.makeService(
            observer: observer,
            wakeSink: wakeSink,
            notificationSink: notificationSink,
            contextProvider: { _ in latestContext }
        )

        await service.reconcileAfterRestart()

        #expect(await wakeSink.requests.count == 1)
        #expect(await notificationSink.notifications.count == 1)
        #expect(operation.lastWakeKey == "v1|process_completed|healthy|completion_validation")
        #expect(operation.lastNotificationKey == "v1|process_completed|healthy")
        let firstRequest = try #require(await wakeSink.requests.first)
        #expect(firstRequest.latestContext == "context after restart")
        #expect(firstRequest.originatingContextRevision == "launch-revision")

        latestContext = "newer context that should not cause a duplicate"
        await service.reconcileAfterRestart()

        #expect(await wakeSink.requests.count == 1)
        #expect(await notificationSink.notifications.count == 1)
        #expect(await observer.callCount == 0)
    }

    @Test("failed wake admission remains unacknowledged and retries on scheduler pass")
    func failedWakeAdmissionRetries() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(
            executionState: .processCompleted,
            observationHealth: .healthy,
            monitoringState: .validating
        )
        let wakeSink = FlakyOperationWakeSink(results: [false, true])
        let service = fixture.makeService(
            observer: SequenceOperationObserver(observations: []),
            wakeSink: wakeSink
        )

        await service.runDueChecks()
        #expect(await wakeSink.callCount == 1)
        #expect(operation.lastWakeKey == nil)

        await service.runDueChecks()
        #expect(await wakeSink.callCount == 2)
        #expect(operation.lastWakeKey != nil)

        await service.runDueChecks()
        #expect(await wakeSink.callCount == 2)
    }

    @Test("failed terminal reasoning wake retries until acknowledged")
    func failedTerminalReasoningWakeRetries() async throws {
        let fixture = try Fixture()
        let operation = fixture.insertOperation(
            executionState: .failed,
            observationHealth: .healthy,
            monitoringState: .completed
        )
        let wakeSink = FlakyOperationWakeSink(results: [false, true])
        let service = fixture.makeService(
            observer: SequenceOperationObserver(observations: []),
            wakeSink: wakeSink
        )

        await service.runDueChecks()
        #expect(await wakeSink.callCount == 1)
        #expect(operation.lastWakeKey == nil)

        await service.runDueChecks()
        #expect(await wakeSink.callCount == 2)
        #expect(operation.lastWakeKey == "v1|failed|healthy|user_facing_reasoning")

        await service.runDueChecks()
        #expect(await wakeSink.callCount == 2)
    }
}

@MainActor
private struct Fixture {
    let container: ModelContainer
    let context: ModelContext
    let clock: TestOperationClock

    init() throws {
        container = try ModelContainer(
            for: ASTRASchema.current,
            migrationPlan: ASTRAMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        context = container.mainContext
        clock = TestOperationClock(Date(timeIntervalSince1970: 2_000_000_000))
    }

    func insertOperation(
        externalIdentity: String = "docker:job-1",
        executionState: TaskExternalOperationExecutionState,
        observationHealth: TaskExternalOperationObservationHealth = .unknown,
        monitoringState: TaskExternalOperationMonitoringState = .active,
        nextCheckAt: Date? = nil,
        originatingContextRevision: String? = nil
    ) -> TaskExternalOperation {
        let operation = TaskExternalOperation(
            taskID: UUID(),
            externalIdentity: externalIdentity,
            originatingRunID: UUID(),
            backendKindRaw: "workspace_managed_docker",
            backendJobID: externalIdentity,
            originatingContextRevision: originatingContextRevision,
            executionState: executionState,
            observationHealth: observationHealth,
            monitoringState: monitoringState,
            nextCheckAt: nextCheckAt,
            createdAt: clock.now()
        )
        context.insert(operation)
        try? context.save()
        return operation
    }

    func makeService(
        observer: any TaskExternalOperationObserving,
        canceller: any TaskExternalOperationCancelling = RecordingOperationCanceller(
            observation: TaskExternalOperationObservation(executionState: .cancelled, health: .healthy)
        ),
        ownershipValidator: any TaskExternalOperationOwnershipValidating = RejectingTaskExternalOperationOwnershipValidator(),
        wakeSink: any TaskExternalOperationWakeSinking = RecordingOperationWakeSink(),
        notificationSink: any TaskExternalOperationNotificationSinking = RecordingOperationNotificationSink(),
        backoff: any TaskExternalOperationBackoffPolicy = FixedOperationBackoff(delay: 30),
        contextProvider: @escaping TaskExternalOperationMonitorService.ContextProvider = { _ in "" }
    ) -> TaskExternalOperationMonitorService {
        TaskExternalOperationMonitorService(
            modelContext: context,
            observer: observer,
            canceller: canceller,
            ownershipValidator: ownershipValidator,
            wakeSink: wakeSink,
            notificationSink: notificationSink,
            clock: clock,
            backoff: backoff,
            leaseDuration: 60,
            leaseOwner: "test-monitor",
            contextProvider: contextProvider
        )
    }
}

private final class TestOperationClock: TaskExternalOperationClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func sleep(until _: Date) async throws {
        try await Task<Never, Never>.sleep(for: .seconds(3_600))
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }
}

private struct FixedOperationBackoff: TaskExternalOperationBackoffPolicy {
    let delay: TimeInterval

    func delay(
        after _: TaskExternalOperationObservation,
        consecutiveFailures _: Int
    ) -> TimeInterval {
        delay
    }
}

private actor SequenceOperationObserver: TaskExternalOperationObserving {
    private var observations: [TaskExternalOperationObservation]
    private(set) var callCount = 0

    init(observations: [TaskExternalOperationObservation]) {
        self.observations = observations
    }

    func observe(_: TaskExternalOperationBackendRequest) -> TaskExternalOperationObservation {
        callCount += 1
        guard !observations.isEmpty else {
            return TaskExternalOperationObservation(executionState: .unknown, health: .malformed)
        }
        return observations.removeFirst()
    }
}

private actor BlockingOperationObserver: TaskExternalOperationObserving {
    private let observation: TaskExternalOperationObservation
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var callCount = 0
    private var released = false

    init(observation: TaskExternalOperationObservation) {
        self.observation = observation
    }

    func observe(_: TaskExternalOperationBackendRequest) async -> TaskExternalOperationObservation {
        callCount += 1
        let waiters = callWaiters
        callWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !released {
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }
        return observation
    }

    func waitUntilCalled() async {
        guard callCount == 0 else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor RecordingOperationCanceller: TaskExternalOperationCancelling {
    private let observation: TaskExternalOperationObservation
    private(set) var callCount = 0

    init(observation: TaskExternalOperationObservation) {
        self.observation = observation
    }

    func cancel(_: TaskExternalOperationBackendRequest) -> TaskExternalOperationObservation {
        callCount += 1
        return observation
    }
}

private actor SelectiveOwnershipValidator: TaskExternalOperationOwnershipValidating {
    private let acceptedIdentity: String
    private(set) var callCount = 0

    init(acceptedIdentity: String) {
        self.acceptedIdentity = acceptedIdentity
    }

    func validateOwnership(_ request: TaskExternalOperationBackendRequest) -> Bool {
        callCount += 1
        return request.externalIdentity == acceptedIdentity
    }
}

private actor RecordingOperationWakeSink: TaskExternalOperationWakeSinking {
    private(set) var requests: [TaskExternalOperationWakeRequest] = []

    func wake(_ request: TaskExternalOperationWakeRequest) -> Bool {
        requests.append(request)
        return true
    }
}

private actor RecordingOperationNotificationSink: TaskExternalOperationNotificationSinking {
    private(set) var notifications: [TaskExternalOperationNotification] = []

    func notify(_ notification: TaskExternalOperationNotification) -> Bool {
        notifications.append(notification)
        return true
    }
}

private actor FlakyOperationWakeSink: TaskExternalOperationWakeSinking {
    private var results: [Bool]
    private(set) var callCount = 0

    init(results: [Bool]) {
        self.results = results
    }

    func wake(_: TaskExternalOperationWakeRequest) -> Bool {
        callCount += 1
        return results.isEmpty ? false : results.removeFirst()
    }
}
