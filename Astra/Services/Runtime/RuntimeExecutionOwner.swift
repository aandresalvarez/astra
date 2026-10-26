import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// One fenced owner spans admission, automatic recovery and final settlement.
/// Its protected journal owns launch authorization; the typed events explain it.
@MainActor
final class RuntimeExecutionOwner {
    private static var active: Set<String> = []
    private static let memoryStores = NSMapTable<ModelContainer, NSURL>.weakToStrongObjects()
    private let key: String
    private var lease: RuntimeExecutionOwnerStore.Lease?
    private(set) var record: RuntimeExecutionOwnerRecord
    let isRecovery: Bool
    var remoteWorkExcluded = false
    private let task: AgentTask
    private let context: ModelContext
    private var run: TaskRun?
    var settlementScope: RuntimeSettlementExecutionScope?
    private var writeFailed = false
    private let initialTokensSpent: Int

    private init(key: String, lease: RuntimeExecutionOwnerStore.Lease, record: RuntimeExecutionOwnerRecord,
                 isRecovery: Bool, task: AgentTask, context: ModelContext) {
        self.key = key; self.lease = lease; self.record = record
        self.isRecovery = isRecovery; self.task = task; self.context = context
        self.initialTokensSpent = record.limits.tokensSpent
    }

    static func store(in context: ModelContext) -> RuntimeExecutionOwnerStore {
        let configuration = context.container.configurations.first!
        if configuration.isStoredInMemoryOnly {
            if let root = memoryStores.object(forKey: context.container) { return .init(root: root as URL) }
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("astra-test-execution-owners-" + UUID().uuidString)
            memoryStores.setObject(root as NSURL, forKey: context.container)
            return .init(root: root)
        }
        let root = configuration.url.deletingLastPathComponent().appendingPathComponent("runtime-owners")
        RuntimeProviderResourceRegistry.register(root)
        return .init(root: root)
    }

    static func existing(task: AgentTask, context: ModelContext) throws -> RuntimeExecutionOwnerRecord? {
        let record = try store(in: context).read(taskID: task.id)
        guard record == nil || record?.taskID == task.id else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        return record.map { reconciledCompletion($0, task: task) }
    }

    // Settlement can finish after an app crash between the OS receipt and finish().
    // Only the durable matching run plus the bound OS receipt may close that window.
    private static func reconciledCompletion(_ saved: RuntimeExecutionOwnerRecord, task: AgentTask) -> RuntimeExecutionOwnerRecord {
        var record = saved
        if task.status == .completed, let runID = record.runID,
           task.runs.contains(where: { $0.id == runID && $0.status == .completed }) {
            record.state = .finished
            if record.canBeginNewTurn { return record }
        }
        return saved
    }

    static func requiresExistingReceipt(_ task: AgentTask) -> Bool {
        // An audit event can require verification, but can never grant a lease.
        // A restored database must not treat a missing sidecar as a fresh task.
        if task.events.contains(where: { $0.type == TaskEventTypes.System.runtimeExecutionOwnership.rawValue }) { return true }
        return !task.runs.isEmpty || task.hasProviderSession
    }

    static func inspection(task: AgentTask, context: ModelContext) throws -> RuntimeSessionInspection? {
        guard let record = try existing(task: task, context: context) else { return nil }
        return .inspect(record, ownedHere: active.contains(key(taskID: task.id, context: context)))
    }

    enum RetryDecision { case legacy, continuation, blocked }

    /// Read first, before Retry changes usage, enqueues a turn or resets state.
    static func retryDecision(task: AgentTask, context: ModelContext) -> RetryDecision {
        do {
            let lease = try store(in: context).acquire(taskID: task.id)
            defer { withExtendedLifetime(lease) {} }
            guard let record = try existing(task: task, context: context) else {
                if requiresExistingReceipt(task) {
                    report("The saved execution receipt is missing. ASTRA cannot verify that earlier work stopped, so Retry is blocked.", task: task, context: context, pause: true)
                    return .blocked
                }
                return .legacy
            }
            let here = active.contains(key(taskID: task.id, context: context))
            if !here && record.canReplace { return .continuation }
            let inspection = RuntimeSessionInspection.inspect(record, ownedHere: here)
            report(replacementBlockedMessage(record, inspection: inspection), task: task, context: context, pause: !here)
            return .blocked
        } catch RuntimeExecutionOwnerStore.Failure.busy {
            report("The existing execution owner is still active. No competing recovery was queued.", task: task, context: context)
            return .blocked
        } catch {
            report("The saved recovery owner could not be read. Retry is blocked so it cannot compete with earlier work.", task: task, context: context, pause: true)
            return .blocked
        }
    }

    /// Startup does not turn loss of its old UI connection into stop proof.
    static func preserveUnresolvedSession(task: AgentTask, context: ModelContext, reportStatus: Bool, autoExport: Bool = true) -> Bool {
        do {
            guard let record = try existing(task: task, context: context) else { return false }
            if record.canReplace || record.canBeginNewTurn
                || record.canRecoverPreparation { return false }
            if reportStatus {
                report(RuntimeSessionInspection.inspect(record, ownedHere: false).message, task: task, context: context, pause: true, autoExport: autoExport)
            }
            return true
        } catch {
            if reportStatus { report("The saved execution owner is unreadable. ASTRA preserved this session and blocked replacement work.", task: task, context: context, pause: true, autoExport: autoExport) }
            return true
        }
    }

    static func acquire(task: AgentTask, context: ModelContext, maxRunSeconds: TimeInterval,
                        newUserTurn: Bool = false, newUserRequest: Bool = false, launchTask: AgentTask? = nil,
                        resourceClaims: [TaskResourceLockClaim]? = nil) -> RuntimeExecutionOwner? {
        let key = key(taskID: task.id, context: context)
        do {
            guard !active.contains(key) else { throw RuntimeExecutionOwnerStore.Failure.busy }
            let store = store(in: context)
            let admission = try store.acquireAdmission()
            defer { withExtendedLifetime(admission) {} }
            let claims = resourceClaims ?? TaskExecutionResourceAdmissionPolicy.lockClaims(
                for: nil, task: task, runMode: "runtime", fallbackAccess: .write, sandboxEnforcement: .off)
            let held = try RuntimeResourceOwnership.claims(in: store, context: context, excluding: task.id)
            guard TaskExecutionResourceBroker.canAcquire(claims, active: held) else {
                report(TaskExecutionResourceBroker.blockerSummary(requested: claims, active: held)
                    + " Previous execution cleanup is not yet confirmed.", task: task, context: context, pause: true)
                return nil
            }
            let lease = try store.acquire(taskID: task.id)
            let previous = try lease.read().map { reconciledCompletion($0, task: task) }
            guard previous == nil || previous?.taskID == task.id else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
            if previous == nil, requiresExistingReceipt(task) {
                report("The saved execution receipt is missing. ASTRA preserved this task and blocked replacement work.", task: task, context: context, pause: true)
                return nil
            }
            if let previous {
                if previous.cancellationRequested == true, previous.resourcesReleased != true,
                   !previous.canReplace, !previous.canRecoverPreparation {
                    report("The cancelled execution still owns resources because its tools have not been confirmed stopped.",
                        task: task, context: context, pause: true)
                    return nil
                }
                let abandonedBeforeLaunch = previous.canRecoverPreparation
                guard previous.canReplace || abandonedBeforeLaunch
                    || (newUserTurn && previous.canAcceptUserTurn) else {
                    report(replacementBlockedMessage(previous, inspection: .inspect(previous, ownedHere: false)), task: task, context: context, pause: true)
                    return nil
                }
            }
            guard let app = RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier) else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
            // A separately authored request gets its own limits after verified
            // cleanup, including when the prior request exhausted its budget.
            // Retry and approved continuations keep the same request's limits.
            let startsNewRequest = newUserRequest && previous?.canAcceptUserTurn == true
            let recovering = previous != nil && !startsNewRequest
            let configuration = launchTask ?? task
            let limits = recovering ? previous!.limits : RuntimeRecoveryLimits(
                tokenCeiling: AgentRuntimeProcessRunner.effectiveTokenBudget(for: configuration),
                turnsRemaining: configuration.maxTurns > 0 ? configuration.maxTurns : Int.max,
                secondsRemaining: maxRunSeconds > 0 ? maxRunSeconds : .greatestFiniteMagnitude,
                tokensSpent: 0, costSpent: 0)
            var record = RuntimeExecutionOwnerRecord(taskID: task.id, ownerID: UUID(), executionID: UUID(),
                appProcess: app, runtime: recovering ? previous!.runtime : task.resolvedRuntimeID.rawValue, sessionID: recovering ? previous?.sessionID : nil,
                state: .preparing, limits: limits, automaticRestarts: recovering ? previous!.automaticRestarts : 0, updatedAt: Date())
            record.inheritedToolUncertainty = previous?.hasUnverifiedTools
            record.resourceClaims = claims
            record.resourcesReleased = false
            try lease.save(record) // fail closed before any worker/provider side effect
            active.insert(key)
            return .init(key: key, lease: lease, record: record, isRecovery: recovering, task: task, context: context)
        } catch RuntimeExecutionOwnerStore.Failure.busy {
            report("The existing execution owner is still active. No competing attempt was started.", task: task, context: context)
            return nil
        } catch {
            report("Recovery ownership could not be verified or saved. No provider was started.", task: task, context: context, pause: true)
            return nil
        }
    }

    enum SettlementAdmission {
        case acquired(RuntimeExecutionOwner), deferred, unresolved(RuntimeExecutionOwnerStore.Lease)
        var mustDefer: Bool { if case .deferred = self { return true }; return false }
        var owner: RuntimeExecutionOwner? {
            if case .acquired(let owner) = self { return owner }
            return nil
        }
    }

    static func acquireSettlement(task: AgentTask, run: TaskRun, context: ModelContext,
                                  resourceClaims: [TaskResourceLockClaim]? = nil) -> SettlementAdmission {
        let key = key(taskID: task.id, context: context)
        do {
            guard !active.contains(key) else { throw RuntimeExecutionOwnerStore.Failure.busy }
            let store = store(in: context)
            let admission = try store.acquireAdmission()
            defer { withExtendedLifetime(admission) {} }
            let lease = try store.acquire(taskID: task.id)
            let saved: RuntimeExecutionOwnerRecord?
            do { saved = try lease.read() } catch { return .unresolved(lease) }
            if let saved, saved.taskID != task.id || saved.runID != run.id { return .deferred }
            guard var saved, saved.settlementInProgress != true,
                  saved.canAcceptUserTurn,
                  saved.cancellationRequested != true || saved.canReplace else { return .unresolved(lease) }
            let claims = resourceClaims ?? saved.resourceClaims ?? TaskExecutionResourceAdmissionPolicy.lockClaims(
                for: nil, task: task, runMode: "settlement", fallbackAccess: .write, sandboxEnforcement: .off)
            let held = try RuntimeResourceOwnership.claims(in: store, context: context, excluding: task.id)
            guard TaskExecutionResourceBroker.canAcquire(claims, active: held) else { return .deferred }
            saved.resourceClaims = claims
            saved.resourcesReleased = false
            try lease.save(saved)
            active.insert(key)
            return .acquired(.init(key: key, lease: lease, record: saved, isRecovery: true, task: task, context: context))
        } catch { return .deferred }
    }

    func restoreSession(for runtime: AgentRuntimeID) {
        guard isActive else { return }
        if isRecovery, record.runtime == runtime.rawValue, let session = record.sessionID { task.sessionId = session }
    }

    func bind(run: TaskRun) throws {
        self.run = run; record.runID = run.id
        let runtime = run.runtimeID ?? task.resolvedRuntimeID.rawValue
        if record.runtime != runtime { record.sessionID = nil }
        record.runtime = runtime
        try save(isRecovery ? "Continuing the saved task within its remaining limits." : nil, audit: true)
    }

    func prepareLaunch(sessionID: String? = nil) throws {
        guard !writeFailed, lease != nil, record.cancellationRequested != true,
              record.state == .preparing || record.canReplace else { throw RuntimeExecutionOwnerStore.Failure.busy }
        record.executionID = UUID(); record.providerProcess = nil; record.stopProof = nil
        record.sessionID = sessionID
        record.state = .launching
        try save(nil, audit: true)
    }

    func launched(_ process: AgentExecutionScopedProcess) throws {
        guard let identity = process.executionIdentity else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
        record.providerProcess = identity; record.state = .working
        try save(nil)
    }

    func didNotLaunch() { record.state = .notStarted; try? save(nil) }

    func session(_ sessionID: String?) {
        guard isActive else { return }
        guard let sessionID, !sessionID.isEmpty, record.sessionID != sessionID else { return }
        record.sessionID = sessionID; try? save(nil)
    }

    func waitingForInput(_ waiting: Bool) {
        guard isActive else { return }
        guard record.state == .working || record.state == .waitingForInput else { return }
        record.state = waiting ? .waitingForInput : .working
        try? save(waiting ? "The existing provider session is waiting for input. Automatic restart is paused." : nil)
    }

    func stopped(proof: RuntimeExecutionStopProof?, turns: Int, tokens: Int, seconds: TimeInterval) {
        guard isActive else { return }
        guard record.state != .notStarted else { return }
        record.stopProof = proof
        record.limits.tokensSpent = RuntimeUsageArithmetic.adding(record.limits.tokensSpent, tokens)
        record.limits.turnsRemaining = max(0, record.limits.turnsRemaining - max(1, turns))
        record.limits.secondsRemaining = max(0, record.limits.secondsRemaining - max(0, seconds))
        record.state = proof?.permitsReplacement == true ? .stopped : .unverified
        try? save(nil)
    }

    func authorizeAutomaticRestart() -> Bool {
        guard !writeFailed, lease != nil, record.canReplace, record.automaticRestarts == 0,
              record.limits.tokensSpent < record.limits.tokenCeiling,
              record.limits.turnsRemaining > 0, record.limits.secondsRemaining > 0,
              !Task.isCancelled, task.status == .running, run?.status == .running else { return false }
        record.automaticRestarts += 1
        do { try save("The prior execution and its relevant tools are confirmed stopped. ASTRA will retry once with the task context and remaining limits."); return true }
        catch { return false }
    }

    func permitsSuspendedRecovery(runID: UUID) -> Bool {
        !writeFailed && lease != nil && record.runID == runID
            && record.state == .working
            && record.providerProcess?.presence == .present
    }

    func chargePreparation(seconds: TimeInterval) {
        guard isActive else { return }
        record.limits.secondsRemaining = max(0, record.limits.secondsRemaining - max(0, seconds))
        try? save(nil)
    }

    func reconcileUsage() {
        guard isActive else { return }
        if let run, run.isLive {
            record.limits.tokensSpent = max(record.limits.tokensSpent, RuntimeUsageArithmetic.adding(initialTokensSpent, run.tokensUsed))
        }
        try? save(nil)
    }

    func beginSettlement() throws {
        guard record.settlementInProgress != true else { throw RuntimeExecutionOwnerStore.Failure.busy }
        record.resourcesReleased = false
        record.settlementInProgress = true
        record.settlementLocalWorkStopped = false
        try save(nil, audit: true)
    }

    func completeSettlement(localWorkStopped: Bool, toolsStopped: Bool) throws {
        record.settlementLocalWorkStopped = localWorkStopped
        record.settlementToolsStopped = record.settlementToolsStopped != false && toolsStopped
        record.settlementInProgress = false
        try save(nil)
    }

    func finish() {
        defer { lease = nil; Self.active.remove(key) }
        guard lease != nil else { return }
        reconcileUsage()
        if let run, run.isLive { record.limits.costSpent += run.costUSD }
        if record.state == .preparing { record.state = .notStarted }
        if task.isLive, task.status == .completed, let run, run.isLive, run.status == .completed,
           record.stopProof?.reaped == true, record.stopProof?.processGroupEmpty == true { record.state = .finished }
        if !writeFailed && record.canReplace {
            record.resourcesReleased = true
            record.providerSharedStateReleased = true
        }
        let unresolved = record.resourcesReleased != true && record.providerProcess != nil
        try? save(unresolved ? "The provider exited, but ASTRA cannot confirm that its execution and tools stopped. Its resources remain reserved; new work and recovery must wait. The result, context and remaining limits are preserved." : nil)
    }

    var isActive: Bool { lease != nil && !writeFailed }
    var persistedResourceRelease: Bool { !writeFailed && record.resourcesReleased == true }

    func releaseProviderSharedState() -> Bool {
        let neverLaunched = record.state == .preparing && record.providerProcess == nil
            && !record.hasUnverifiedTools && record.settlementInProgress != true
            && record.settlementLocalWorkStopped != false
        guard isActive, record.canReplace || neverLaunched else { return false }
        record.providerSharedStateReleased = true
        do { try save(nil); return true } catch { return false }
    }

    func requestCancellation() {
        guard isActive, record.cancellationRequested != true else { return }
        record.cancellationRequested = true
        settlementScope?.cancel()
        try? save("Stopping the provider. ASTRA will keep its resources reserved until cleanup is confirmed.", audit: true)
    }

    var providerOwnershipReference: RuntimeProviderOwnershipReference {
        .init(journalRoot: Self.store(in: context).root.path, taskID: record.taskID, ownerID: record.ownerID)
    }

    func bindProviderSharedState(_ key: AgentRuntimeSharedStateKey) throws {
        guard isActive, record.cancellationRequested != true,
              record.providerSharedStateReleased == true || record.providerSharedStateKey == nil
                || record.providerSharedStateKey == key.rawValue else { throw RuntimeExecutionOwnerStore.Failure.busy }
        record.providerSharedStateKey = key.rawValue
        record.providerSharedStateReleased = false
        try save(nil)
    }

    private static func replacementBlockedMessage(_ record: RuntimeExecutionOwnerRecord, inspection: RuntimeSessionInspection) -> String {
        if record.canBeginNewTurn && !record.canReplace {
            return "The provider turn finished, but ASTRA cannot verify that all relevant tools stopped. Recovery is blocked; the conversation and remaining limits are preserved."
        }
        return inspection.message
    }

    private func save(_ message: String?, audit: Bool = false) throws {
        guard let lease, !writeFailed else { throw RuntimeExecutionOwnerStore.Failure.writeFailed }
        record.updatedAt = Date()
        do { try lease.save(record) }
        catch {
            writeFailed = true
            Self.report("ASTRA could not update the recovery record. The existing attempt retains ownership; further launches are blocked until its state can be verified.", task: task, context: context)
            throw error
        }
        if task.isLive, task.modelContext === context, audit || message != nil {
            let payload = TaskEvent.payloadString(record, fallback: "{}")
            context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership, payload: payload, run: run))
            if let message { Self.report(message, task: task, context: context) }
            else { WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: context) }
        }
    }

    static func report(_ message: String, task: AgentTask, context: ModelContext, pause: Bool = false, autoExport: Bool = true) {
        guard task.isLive, task.modelContext === context else { return }
        if pause { TaskStateMachine.pauseForRuntimeReview(task, modelContext: context) }
        context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info, payload: message))
        if autoExport { WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: context) }
        else { WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: context) }
    }

    private static func key(taskID: UUID, context: ModelContext) -> String { store(in: context).root.path + "/" + taskID.uuidString }
}
