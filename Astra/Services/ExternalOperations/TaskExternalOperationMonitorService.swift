import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

protocol TaskExternalOperationClock: Sendable {
    func now() -> Date
    func sleep(until deadline: Date) async throws
}

struct SystemTaskExternalOperationClock: TaskExternalOperationClock {
    func now() -> Date { Date() }

    func sleep(until deadline: Date) async throws {
        let delay = max(0, deadline.timeIntervalSinceNow)
        try await Task.sleep(for: .seconds(delay))
    }
}

protocol TaskExternalOperationBackoffPolicy: Sendable {
    func delay(
        after observation: TaskExternalOperationObservation,
        consecutiveFailures: Int
    ) -> TimeInterval
}

struct ExponentialTaskExternalOperationBackoffPolicy: TaskExternalOperationBackoffPolicy {
    var healthyDelay: TimeInterval = 30
    var initialFailureDelay: TimeInterval = 30
    var maximumFailureDelay: TimeInterval = 15 * 60

    func delay(
        after observation: TaskExternalOperationObservation,
        consecutiveFailures: Int
    ) -> TimeInterval {
        guard observation.health != .healthy else { return healthyDelay }
        let exponent = min(max(0, consecutiveFailures - 1), 10)
        return min(initialFailureDelay * pow(2, Double(exponent)), maximumFailureDelay)
    }
}

struct TaskExternalOperationBackendRequest: Equatable, Sendable {
    let operationID: UUID
    let taskID: UUID
    let originatingRunID: UUID
    let externalIdentity: String
    let backendKind: String
    let backendJobID: String
}

struct TaskExternalOperationObservation: Equatable, Sendable {
    let executionState: TaskExternalOperationExecutionState
    let health: TaskExternalOperationObservationHealth

    init(
        executionState: TaskExternalOperationExecutionState,
        health: TaskExternalOperationObservationHealth
    ) {
        self.executionState = executionState
        self.health = health
    }
}

protocol TaskExternalOperationObserving: Sendable {
    func observe(_ request: TaskExternalOperationBackendRequest) async -> TaskExternalOperationObservation
}

protocol TaskExternalOperationCancelling: Sendable {
    func cancel(_ request: TaskExternalOperationBackendRequest) async -> TaskExternalOperationObservation
}

protocol TaskExternalOperationOwnershipValidating: Sendable {
    /// Revalidates a persisted registration against the backend's trusted
    /// owner record without launching, polling, or cancelling external work.
    func validateOwnership(_ request: TaskExternalOperationBackendRequest) async -> Bool
}

struct RejectingTaskExternalOperationOwnershipValidator: TaskExternalOperationOwnershipValidating {
    func validateOwnership(_: TaskExternalOperationBackendRequest) async -> Bool { false }
}

enum TaskExternalOperationWakeIntent: String, Equatable, Sendable {
    case ambiguousObservation = "ambiguous_observation"
    case completionValidation = "completion_validation"
    case userFacingReasoning = "user_facing_reasoning"
}

struct TaskExternalOperationWakeRequest: Equatable, Sendable {
    static let maximumContextCharacters = 12_000

    let operationID: UUID
    let taskID: UUID
    let originatingRunID: UUID
    /// The bounded backend job identifier, so the fresh validation/reasoning
    /// session can address the job's status/tail/wait tools (which all require
    /// `job_id`) to inspect its logs and result. The managed start result is
    /// redacted from run history, so the wake prompt is the session's only path
    /// to the id.
    let backendJobID: String
    let originatingContextRevision: String?
    let latestContext: String
    let observation: TaskExternalOperationObservation
    let intent: TaskExternalOperationWakeIntent

    init(
        operationID: UUID,
        taskID: UUID,
        originatingRunID: UUID,
        backendJobID: String,
        originatingContextRevision: String?,
        latestContext: String,
        observation: TaskExternalOperationObservation,
        intent: TaskExternalOperationWakeIntent
    ) {
        self.operationID = operationID
        self.taskID = taskID
        self.originatingRunID = originatingRunID
        self.backendJobID = backendJobID
        self.originatingContextRevision = originatingContextRevision
        self.latestContext = String(latestContext.prefix(Self.maximumContextCharacters))
        self.observation = observation
        self.intent = intent
    }
}

protocol TaskExternalOperationWakeSinking: Sendable {
    /// Returns true only after the fresh provider session was admitted and its
    /// work completed. False leaves the durable dedupe key unacknowledged so a
    /// later scheduler pass can retry delivery.
    func wake(_ request: TaskExternalOperationWakeRequest) async -> Bool
}

struct NoopTaskExternalOperationWakeSink: TaskExternalOperationWakeSinking {
    func wake(_: TaskExternalOperationWakeRequest) async -> Bool { true }
}

struct TaskExternalOperationNotification: Equatable, Sendable {
    let operationID: UUID
    let taskID: UUID
    let observation: TaskExternalOperationObservation
}

protocol TaskExternalOperationNotificationSinking: Sendable {
    func notify(_ notification: TaskExternalOperationNotification) async -> Bool
}

struct NoopTaskExternalOperationNotificationSink: TaskExternalOperationNotificationSinking {
    func notify(_: TaskExternalOperationNotification) async -> Bool { true }
}

enum TaskExternalOperationPollTrigger: String, Sendable {
    case manual
    case scheduled
    case restartReconciliation = "restart_reconciliation"
}

enum TaskExternalOperationPollResult: Equatable, Sendable {
    case applied
    indirect case coalesced(TaskExternalOperationPollResult)
    case leased
    case missing
    case notMonitoring
    case quarantined
    case ownershipRejected
    case staleIgnored
}

@MainActor
final class TaskExternalOperationMonitorService {
    typealias ContextProvider = @MainActor (UUID) -> String

    private struct InFlightPoll {
        let token: UUID
        let task: Task<TaskExternalOperationPollResult, Never>
    }

    private struct InFlightDelivery {
        let token: UUID
        let task: Task<Void, Never>
    }

    private struct AcquiredPoll {
        let request: TaskExternalOperationBackendRequest
        let generation: Int
    }

    private struct AppliedObservation {
        let result: TaskExternalOperationPollResult
        let notification: TaskExternalOperationNotification?
        let notificationKey: String?
        let wakeRequest: TaskExternalOperationWakeRequest?
        let wakeKey: String?
    }

    private let modelContext: ModelContext
    private let observer: any TaskExternalOperationObserving
    private let canceller: any TaskExternalOperationCancelling
    private let ownershipValidator: any TaskExternalOperationOwnershipValidating
    private let wakeSink: any TaskExternalOperationWakeSinking
    private let notificationSink: any TaskExternalOperationNotificationSinking
    private let clock: any TaskExternalOperationClock
    private let backoff: any TaskExternalOperationBackoffPolicy
    private let contextProvider: ContextProvider
    private let leaseDuration: TimeInterval
    private let leaseOwner: String

    private var schedulerTask: Task<Void, Never>?
    private var inFlightPolls: [UUID: InFlightPoll] = [:]
    private var inFlightCancellations: [UUID: InFlightPoll] = [:]
    private var inFlightTerminalDeliveries: [UUID: InFlightDelivery] = [:]
    /// Set by `stop()` so an in-flight poll that was already awaiting a backend
    /// read cannot deliver a wake/notification after the monitor was stopped
    /// (e.g. for a pending update install). Delivery is what launches provider
    /// work; suppressing it here leaves the transition unacknowledged so it is
    /// redelivered on the next `start()`.
    private var isStopped = false

    init(
        modelContext: ModelContext,
        observer: any TaskExternalOperationObserving,
        canceller: any TaskExternalOperationCancelling,
        ownershipValidator: any TaskExternalOperationOwnershipValidating = RejectingTaskExternalOperationOwnershipValidator(),
        wakeSink: any TaskExternalOperationWakeSinking = NoopTaskExternalOperationWakeSink(),
        notificationSink: any TaskExternalOperationNotificationSinking = NoopTaskExternalOperationNotificationSink(),
        clock: any TaskExternalOperationClock = SystemTaskExternalOperationClock(),
        backoff: any TaskExternalOperationBackoffPolicy = ExponentialTaskExternalOperationBackoffPolicy(),
        leaseDuration: TimeInterval = 2 * 60,
        leaseOwner: String = UUID().uuidString.lowercased(),
        contextProvider: @escaping ContextProvider = { _ in "" }
    ) {
        self.modelContext = modelContext
        self.observer = observer
        self.canceller = canceller
        self.ownershipValidator = ownershipValidator
        self.wakeSink = wakeSink
        self.notificationSink = notificationSink
        self.clock = clock
        self.backoff = backoff
        self.leaseDuration = leaseDuration
        self.leaseOwner = leaseOwner
        self.contextProvider = contextProvider
    }

    func start() {
        guard schedulerTask == nil else { return }
        isStopped = false
        schedulerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await reconcileAfterRestart()
            while !Task.isCancelled {
                // Keep the scheduler alive even when the store is temporarily
                // empty. Registrations are created by a separate trusted
                // service and must be discovered without relying on a view or
                // provider callback to restart monitoring.
                let discoveryDeadline = clock.now().addingTimeInterval(30)
                let deadline = min(
                    nextSchedulerDeadline() ?? discoveryDeadline,
                    discoveryDeadline
                )
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await runDueChecks(trigger: .scheduled)
            }
            schedulerTask = nil
        }
    }

    func stop() {
        isStopped = true
        schedulerTask?.cancel()
        schedulerTask = nil
        // A due poll or cancellation may already be running in an unstructured
        // task. Cancelling only the scheduler would let it finish and invoke the
        // wake sink after a pre-install safety check; cancel and drop them too.
        // (The `isStopped` guard in `deliver` is the authoritative stop — task
        // cancellation is cooperative and may not interrupt synchronous work.)
        for poll in inFlightPolls.values { poll.task.cancel() }
        for cancellation in inFlightCancellations.values { cancellation.task.cancel() }
        for delivery in inFlightTerminalDeliveries.values { delivery.task.cancel() }
        inFlightPolls.removeAll()
        inFlightCancellations.removeAll()
        inFlightTerminalDeliveries.removeAll()
    }

    func reconcileAfterRestart() async {
        let now = clock.now()
        let allOperations = fetchOperations()
        let operations = allOperations.filter { $0.monitoringState == .active }
        var changed = false
        for operation in operations {
            if operation.leaseExpiresAt.map({ $0 <= now }) == true {
                operation.leaseOwner = nil
                operation.leaseExpiresAt = nil
                changed = true
            }
            if operation.nextCheckAt == nil {
                operation.nextCheckAt = now
                operation.updatedAt = now
                changed = true
            }
        }
        if changed { persist(operation: "external_operation_restart_reconciled") }
        await runDueChecks(trigger: .restartReconciliation)
    }

    func runDueChecks(trigger: TaskExternalOperationPollTrigger = .scheduled) async {
        // Terminal operations are intentionally not polled. Retry any
        // unacknowledged terminal notification/wake delivery on every scheduler
        // pass so temporary worker unavailability cannot lose the transition.
        // Dispatched but NOT awaited here: a wake dispatch can run a full
        // provider session (potentially minutes — `TaskQueue.continueSession`
        // awaits the entire run), and awaiting it in the scheduler pass would
        // block every subsequent pass's polls, notifications, and wake retries
        // for unrelated operations until that one validation finished. The
        // deliveries stay tracked in `inFlightTerminalDeliveries` (so `stop()`
        // cancels them and repeat passes coalesce onto the in-flight attempt);
        // tests that need "deliveries finished" determinism await
        // `drainInFlightTerminalDeliveries()` explicitly.
        reconcilePendingTerminalDeliveries(operations: fetchOperations())
        let now = clock.now()
        let operationIDs = fetchOperations()
            .filter { operation in
                guard operation.monitoringState == .active,
                      !operation.executionState.isTerminalObservation,
                      operation.nextCheckAt.map({ $0 <= now }) ?? true else {
                    return false
                }
                return operation.leaseExpiresAt.map({ $0 <= now }) ?? true
            }
            .map(\.id)

        let tasks = operationIDs.map { operationID in
            Task { @MainActor [weak self] in
                await self?.poll(operationID: operationID, trigger: trigger) ?? .missing
            }
        }
        for task in tasks {
            _ = await task.value
        }
    }

    /// Awaits every terminal delivery that is currently in flight. The
    /// scheduler deliberately does NOT await deliveries (each can run a full
    /// provider session and would block later passes for every other
    /// operation); tests and other callers that need "this pass's deliveries
    /// have finished" determinism await this explicitly instead.
    func drainInFlightTerminalDeliveries() async {
        while !inFlightTerminalDeliveries.isEmpty {
            let pending = inFlightTerminalDeliveries.values.map(\.task)
            for task in pending {
                await task.value
            }
        }
    }

    func poll(
        operationID: UUID,
        trigger _: TaskExternalOperationPollTrigger = .manual
    ) async -> TaskExternalOperationPollResult {
        if let existing = inFlightPolls[operationID] {
            return .coalesced(await existing.task.value)
        }

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await self?.performPoll(operationID: operationID) ?? .missing
        }
        inFlightPolls[operationID] = InFlightPoll(token: token, task: task)
        let result = await task.value
        if inFlightPolls[operationID]?.token == token {
            inFlightPolls.removeValue(forKey: operationID)
        }
        return result
    }

    func stopMonitoring(operationID: UUID) -> TaskExternalOperationPollResult {
        guard let operation = fetchOperation(id: operationID) else { return .missing }
        guard operation.monitoringState != .quarantined else { return .quarantined }
        let now = clock.now()
        operation.generation += 1
        operation.monitoringState = .stopped
        operation.nextCheckAt = nil
        operation.leaseOwner = nil
        operation.leaseExpiresAt = nil
        operation.updatedAt = now
        persist(operation: "external_operation_monitoring_stopped")
        return .applied
    }

    func resumeMonitoring(operationID: UUID) -> TaskExternalOperationPollResult {
        guard let operation = fetchOperation(id: operationID) else { return .missing }
        guard operation.monitoringState != .quarantined else { return .quarantined }
        guard operation.monitoringState == .stopped,
              !operation.executionState.isTerminalObservation else {
            return .notMonitoring
        }
        let now = clock.now()
        operation.generation += 1
        operation.monitoringState = .active
        operation.observationHealth = .unknown
        operation.nextCheckAt = now
        operation.leaseOwner = nil
        operation.leaseExpiresAt = nil
        operation.updatedAt = now
        persist(operation: "external_operation_monitoring_resumed")
        return .applied
    }

    func reactivateQuarantinedOperation(operationID: UUID) async -> TaskExternalOperationPollResult {
        guard let operation = fetchOperation(id: operationID) else { return .missing }
        guard operation.monitoringState == .quarantined else { return .notMonitoring }

        let generation = operation.generation
        let request = backendRequest(for: operation)
        guard await ownershipValidator.validateOwnership(request) else {
            AppLogger.audit(.workerBlocked, category: "ExternalOperation", taskID: operation.taskID, fields: [
                "operation": "external_operation_reactivate",
                "result": "ownership_rejected",
                "backend": operation.backendKindRaw
            ], level: .warning)
            return .ownershipRejected
        }

        // Ownership validation can suspend. A concurrent delete or state
        // transition must win rather than being overwritten by this result.
        guard let current = fetchOperation(id: operationID),
              current.generation == generation,
              current.monitoringState == .quarantined else {
            return .staleIgnored
        }
        let now = clock.now()
        current.generation += 1
        current.observationHealth = .unknown
        current.leaseOwner = nil
        current.leaseExpiresAt = nil
        // A terminal execution state is never polled again, so restoring it to
        // `.active` would strand the task: `runDueChecks`/`acquirePoll` skip
        // terminal rows and `reconcilePendingTerminalDeliveries` only drives
        // `.validating`/`.completed`. Restore the delivery state that terminal
        // reconciliation resumes (mirrors registration's initial-state mapping)
        // so the pending validation/reasoning wake is still delivered; only a
        // non-terminal operation returns to active polling.
        if current.executionState == .processCompleted {
            current.monitoringState = .validating
            current.nextCheckAt = nil
        } else if current.executionState.isTerminalObservation {
            current.monitoringState = .completed
            current.nextCheckAt = nil
        } else {
            current.monitoringState = .active
            current.nextCheckAt = now
        }
        current.updatedAt = now
        persist(operation: "external_operation_reactivated")
        return .applied
    }

    func cancelExternalWork(operationID: UUID) async -> TaskExternalOperationPollResult {
        if let existing = inFlightCancellations[operationID] {
            return .coalesced(await existing.task.value)
        }

        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await self?.performCancellation(operationID: operationID) ?? .missing
        }
        inFlightCancellations[operationID] = InFlightPoll(token: token, task: task)
        let result = await task.value
        if inFlightCancellations[operationID]?.token == token {
            inFlightCancellations.removeValue(forKey: operationID)
        }
        return result
    }

    private func performPoll(operationID: UUID) async -> TaskExternalOperationPollResult {
        guard let acquired = acquirePoll(operationID: operationID) else {
            guard let operation = fetchOperation(id: operationID) else { return .missing }
            if operation.monitoringState == .quarantined { return .quarantined }
            if operation.monitoringState != .active || operation.executionState.isTerminalObservation {
                return .notMonitoring
            }
            return .leased
        }

        let observation = await observer.observe(acquired.request)
        let applied = apply(
            observation,
            operationID: operationID,
            expectedGeneration: acquired.generation,
            expectedLeaseOwner: leaseOwner
        )
        await deliver(applied)
        return applied.result
    }

    private func performCancellation(operationID: UUID) async -> TaskExternalOperationPollResult {
        guard let operation = fetchOperation(id: operationID) else { return .missing }
        guard operation.monitoringState != .quarantined else { return .quarantined }
        guard !operation.executionState.isTerminalObservation else { return .notMonitoring }
        let now = clock.now()
        operation.generation += 1
        let generation = operation.generation
        operation.leaseOwner = leaseOwner
        operation.leaseExpiresAt = now.addingTimeInterval(leaseDuration)
        operation.updatedAt = now
        persist(operation: "external_operation_cancel_claimed")

        let observation = await canceller.cancel(backendRequest(for: operation))
        let applied = apply(
            observation,
            operationID: operationID,
            expectedGeneration: generation,
            expectedLeaseOwner: leaseOwner
        )
        await deliver(applied)
        return applied.result
    }

    private func acquirePoll(operationID: UUID) -> AcquiredPoll? {
        guard let operation = fetchOperation(id: operationID),
              operation.monitoringState == .active,
              !operation.executionState.isTerminalObservation else {
            return nil
        }
        let now = clock.now()
        if let expiresAt = operation.leaseExpiresAt,
           expiresAt > now {
            return nil
        }

        operation.generation += 1
        operation.leaseOwner = leaseOwner
        operation.leaseExpiresAt = now.addingTimeInterval(leaseDuration)
        operation.updatedAt = now
        persist(operation: "external_operation_poll_claimed")
        return AcquiredPoll(
            request: backendRequest(for: operation),
            generation: operation.generation
        )
    }

    private func apply(
        _ receivedObservation: TaskExternalOperationObservation,
        operationID: UUID,
        expectedGeneration: Int,
        expectedLeaseOwner: String
    ) -> AppliedObservation {
        guard let operation = fetchOperation(id: operationID) else {
            return AppliedObservation(
                result: .missing,
                notification: nil,
                notificationKey: nil,
                wakeRequest: nil,
                wakeKey: nil
            )
        }
        guard operation.generation == expectedGeneration,
              operation.leaseOwner == expectedLeaseOwner else {
            return AppliedObservation(
                result: .staleIgnored,
                notification: nil,
                notificationKey: nil,
                wakeRequest: nil,
                wakeKey: nil
            )
        }

        let now = clock.now()
        let priorState = operation.executionState
        let observedState: TaskExternalOperationExecutionState
        if receivedObservation.health == .unreachable {
            // Reachability is observation health, not evidence that execution
            // failed or changed state.
            observedState = priorState
        } else {
            observedState = receivedObservation.executionState
        }

        guard !priorState.isTerminalObservation || priorState == observedState else {
            operation.leaseOwner = nil
            operation.leaseExpiresAt = nil
            operation.updatedAt = now
            persist(operation: "external_operation_stale_terminal_ignored")
            return AppliedObservation(
                result: .staleIgnored,
                notification: nil,
                notificationKey: nil,
                wakeRequest: nil,
                wakeKey: nil
            )
        }

        operation.executionState = observedState
        operation.observationHealth = receivedObservation.health
        operation.lastObservedAt = now
        operation.updatedAt = now
        operation.leaseOwner = nil
        operation.leaseExpiresAt = nil
        if receivedObservation.health == .healthy {
            operation.consecutiveObservationFailures = 0
        } else {
            operation.consecutiveObservationFailures += 1
        }

        let effectiveObservation = TaskExternalOperationObservation(
            executionState: observedState,
            health: receivedObservation.health
        )
        if observedState.isTerminalObservation {
            operation.terminalObservedAt = operation.terminalObservedAt ?? now
            operation.nextCheckAt = nil
            operation.monitoringState = observedState == .processCompleted ? .validating : .completed
        } else {
            operation.nextCheckAt = now.addingTimeInterval(backoff.delay(
                after: effectiveObservation,
                consecutiveFailures: operation.consecutiveObservationFailures
            ))
        }

        let notificationKey = semanticKey(for: effectiveObservation)
        let shouldNotify = operation.lastNotificationKey != notificationKey

        let intent = wakeIntent(for: effectiveObservation)
        // A healthy, non-wake observation clears the dedupe key. Without this, a
        // wake→healthy→identical-wake-again cycle (e.g. two separate ambiguous
        // observations with a healthy reading in between) reproduces the exact
        // same semantic key and the second, genuinely-new incident is silently
        // suppressed as if already delivered.
        if intent == nil { operation.lastWakeKey = nil }
        let wakeKey = intent.map { "\(notificationKey)|\($0.rawValue)" }
        let shouldWake = wakeKey.map { operation.lastWakeKey != $0 } ?? false
        persist(operation: "external_operation_observation_applied")

        let notification = shouldNotify
            ? TaskExternalOperationNotification(
                operationID: operation.id,
                taskID: operation.taskID,
                observation: effectiveObservation
            )
            : nil
        let wakeRequest: TaskExternalOperationWakeRequest?
        if shouldWake, let intent {
            wakeRequest = TaskExternalOperationWakeRequest(
                operationID: operation.id,
                taskID: operation.taskID,
                originatingRunID: operation.originatingRunID,
                backendJobID: operation.backendJobID,
                originatingContextRevision: operation.originatingContextRevision,
                latestContext: contextProvider(operation.taskID),
                observation: effectiveObservation,
                intent: intent
            )
        } else {
            wakeRequest = nil
        }
        return AppliedObservation(
            result: .applied,
            notification: notification,
            notificationKey: shouldNotify ? notificationKey : nil,
            wakeRequest: wakeRequest,
            wakeKey: shouldWake ? wakeKey : nil
        )
    }

    private func deliver(_ applied: AppliedObservation) async {
        // The monitor was stopped (e.g. for a pending update install) while this
        // observation was in flight. Do not launch provider work or post
        // notifications during shutdown; leave the transition unacknowledged so
        // it is redelivered on the next start.
        guard !isStopped else { return }
        if let notification = applied.notification,
           let notificationKey = applied.notificationKey,
           isCurrentNotificationKey(
                operationID: notification.operationID,
                semanticKey: notificationKey
           ) {
            if await notificationSink.notify(notification) {
                acknowledgeNotification(
                    operationID: notification.operationID,
                    semanticKey: notificationKey
                )
            }
        }
        if let wakeRequest = applied.wakeRequest,
           let wakeKey = applied.wakeKey,
           isCurrentWakeKey(
                operationID: wakeRequest.operationID,
                semanticKey: wakeKey
           ) {
            if await wakeSink.wake(wakeRequest) {
                acknowledgeWake(
                    operationID: wakeRequest.operationID,
                    semanticKey: wakeKey
                )
            }
        }
    }

    /// Terminal operations are not polled again, so scheduler/restart
    /// reconciliation redelivers every unacknowledged terminal transition.
    /// Process completion remains validating until a fresh provider proves
    /// task success; other terminal states remain completed while their
    /// user-facing reasoning wake is retried independently.
    private func isPendingTerminalDelivery(_ operation: TaskExternalOperation) -> Bool {
        let isPendingProcessValidation = operation.executionState == .processCompleted
            && operation.monitoringState == .validating
        // A quarantined-import row (observationHealth == .quarantined) landed
        // as `.completed` because its ALREADY-PROCESSED terminal state was
        // inherited from another machine's export, not because a fresh
        // reasoning wake was ever delivered here. Treating it as pending
        // would launch a brand-new provider continuation on a task the user
        // believes is finished, merely because the workspace was imported.
        let isPendingTerminalReasoning = operation.executionState.isTerminalObservation
            && operation.executionState != .processCompleted
            && operation.monitoringState == .completed
            && operation.observationHealth != .quarantined
        return isPendingProcessValidation || isPendingTerminalReasoning
    }

    /// Returns the dispatched (or already in-flight/coalesced) delivery task
    /// for every pending operation. The scheduler pass does NOT await these —
    /// a delivery can run a full provider session, and awaiting it would block
    /// every later pass's polls and wake retries for unrelated operations.
    /// Callers needing delivery-completion determinism (tests) await
    /// `drainInFlightTerminalDeliveries()` instead.
    @discardableResult
    private func reconcilePendingTerminalDeliveries(
        operations: [TaskExternalOperation]
    ) -> [Task<Void, Never>] {
        operations
            .filter(isPendingTerminalDelivery)
            .map { dispatchTerminalDeliveryIfNeeded(operationID: $0.id) }
    }

    /// Dispatches one operation's terminal-delivery attempt as its own
    /// independently-tracked Task instead of sequentially awaiting it inline
    /// (the prior design). A single wake dispatch can run a full provider
    /// session — potentially minutes — and awaiting it in the scheduler loop
    /// blocked every other operation's polling/notification/wake-retry for the
    /// rest of that pass. Tracked in `inFlightTerminalDeliveries` so `stop()`
    /// can cancel it, mirroring `inFlightPolls`/`inFlightCancellations`.
    @discardableResult
    private func dispatchTerminalDeliveryIfNeeded(operationID: UUID) -> Task<Void, Never> {
        if let existing = inFlightTerminalDeliveries[operationID] {
            return existing.task
        }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await self?.performTerminalDelivery(operationID: operationID)
            if self?.inFlightTerminalDeliveries[operationID]?.token == token {
                self?.inFlightTerminalDeliveries.removeValue(forKey: operationID)
            }
        }
        inFlightTerminalDeliveries[operationID] = InFlightDelivery(token: token, task: task)
        return task
    }

    /// Re-fetches the operation fresh (rather than closing over the object
    /// passed to `reconcilePendingTerminalDeliveries`) so a delivery that was
    /// dispatched, then suspended for a while before actually running,
    /// observes any concurrent mutation instead of acting on stale state —
    /// matching `performPoll`'s existing re-fetch-by-ID pattern.
    private func performTerminalDelivery(operationID: UUID) async {
        guard let operation = fetchOperation(id: operationID), isPendingTerminalDelivery(operation) else { return }

        let observation = TaskExternalOperationObservation(
            executionState: operation.executionState,
            health: operation.observationHealth
        )
        guard let intent = wakeIntent(for: observation) else { return }
        let notificationKey = semanticKey(for: observation)
        let wakeKey = "\(notificationKey)|\(intent.rawValue)"
        let notification = operation.lastNotificationKey == notificationKey
            ? nil
            : TaskExternalOperationNotification(
                operationID: operation.id,
                taskID: operation.taskID,
                observation: observation
            )
        let wakeRequest = operation.lastWakeKey == wakeKey
            ? nil
            : TaskExternalOperationWakeRequest(
                operationID: operation.id,
                taskID: operation.taskID,
                originatingRunID: operation.originatingRunID,
                backendJobID: operation.backendJobID,
                originatingContextRevision: operation.originatingContextRevision,
                latestContext: contextProvider(operation.taskID),
                observation: observation,
                intent: intent
            )
        await deliver(AppliedObservation(
            result: .applied,
            notification: notification,
            notificationKey: notification == nil ? nil : notificationKey,
            wakeRequest: wakeRequest,
            wakeKey: wakeRequest == nil ? nil : wakeKey
        ))
    }

    private func acknowledgeNotification(operationID: UUID, semanticKey deliveredKey: String) {
        guard isCurrentNotificationKey(operationID: operationID, semanticKey: deliveredKey),
              let operation = fetchOperation(id: operationID) else { return }
        operation.lastNotificationKey = deliveredKey
        operation.updatedAt = clock.now()
        persist(operation: "external_operation_notification_acknowledged")
    }

    private func acknowledgeWake(operationID: UUID, semanticKey deliveredKey: String) {
        guard isCurrentWakeKey(operationID: operationID, semanticKey: deliveredKey),
              let operation = fetchOperation(id: operationID) else { return }
        operation.lastWakeKey = deliveredKey
        operation.updatedAt = clock.now()
        persist(operation: "external_operation_wake_acknowledged")
    }

    private func isCurrentNotificationKey(operationID: UUID, semanticKey expectedKey: String) -> Bool {
        guard let operation = fetchOperation(id: operationID) else { return false }
        return semanticKey(for: TaskExternalOperationObservation(
            executionState: operation.executionState,
            health: operation.observationHealth
        )) == expectedKey
    }

    private func isCurrentWakeKey(operationID: UUID, semanticKey expectedKey: String) -> Bool {
        guard let operation = fetchOperation(id: operationID) else { return false }
        let observation = TaskExternalOperationObservation(
            executionState: operation.executionState,
            health: operation.observationHealth
        )
        guard let intent = wakeIntent(for: observation) else { return false }
        return "\(semanticKey(for: observation))|\(intent.rawValue)" == expectedKey
    }

    private func wakeIntent(
        for observation: TaskExternalOperationObservation
    ) -> TaskExternalOperationWakeIntent? {
        if observation.health == .malformed ||
            (observation.health == .healthy && observation.executionState == .unknown) {
            return .ambiguousObservation
        }
        switch observation.executionState {
        case .processCompleted:
            return .completionValidation
        case .interrupted, .failed, .cancelled, .timedOut:
            return .userFacingReasoning
        case .registered, .queued, .running, .unknown:
            return nil
        }
    }

    private func semanticKey(for observation: TaskExternalOperationObservation) -> String {
        "v1|\(observation.executionState.rawValue)|\(observation.health.rawValue)"
    }

    private func backendRequest(for operation: TaskExternalOperation) -> TaskExternalOperationBackendRequest {
        TaskExternalOperationBackendRequest(
            operationID: operation.id,
            taskID: operation.taskID,
            originatingRunID: operation.originatingRunID,
            externalIdentity: operation.externalIdentity,
            backendKind: operation.backendKindRaw,
            backendJobID: operation.backendJobID
        )
    }

    private func nextSchedulerDeadline() -> Date? {
        let now = clock.now()
        return fetchOperations()
            .filter { $0.monitoringState == .active && !$0.executionState.isTerminalObservation }
            .compactMap { operation in
                if let leaseExpiresAt = operation.leaseExpiresAt, leaseExpiresAt > now {
                    return leaseExpiresAt
                }
                return operation.nextCheckAt ?? now
            }
            .min()
    }

    private func fetchOperation(id: UUID) -> TaskExternalOperation? {
        var descriptor = FetchDescriptor<TaskExternalOperation>(
            predicate: #Predicate<TaskExternalOperation> { operation in
                operation.id == id
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchOperations() -> [TaskExternalOperation] {
        (try? modelContext.fetch(FetchDescriptor<TaskExternalOperation>())) ?? []
    }

    private func persist(operation: String) {
        WorkspacePersistenceCoordinator.saveAndAutoExport(
            workspace: nil,
            modelContext: modelContext,
            auditFields: ["operation": operation]
        )
    }
}
