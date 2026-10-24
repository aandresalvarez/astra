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
    private let key: String
    private var lease: RuntimeExecutionOwnerStore.Lease?
    private(set) var record: RuntimeExecutionOwnerRecord
    let isRecovery: Bool
    var remoteWorkExcluded = false
    private let task: AgentTask
    private let context: ModelContext
    private var run: TaskRun?
    private var writeFailed = false

    private init(key: String, lease: RuntimeExecutionOwnerStore.Lease, record: RuntimeExecutionOwnerRecord,
                 isRecovery: Bool, task: AgentTask, context: ModelContext) {
        self.key = key; self.lease = lease; self.record = record
        self.isRecovery = isRecovery; self.task = task; self.context = context
    }

    static func store(in context: ModelContext) -> RuntimeExecutionOwnerStore {
        let configuration = context.container.configurations.first!
        let root = configuration.isStoredInMemoryOnly
            ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("astra-test-execution-owners")
            : configuration.url.deletingLastPathComponent().appendingPathComponent("runtime-owners")
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
        if let runID = record.runID, task.runs.contains(where: { $0.id == runID && $0.status == .completed }) {
            record.state = .finished
            if record.canBeginNewTurn { return record }
        }
        return saved
    }

    private static func requiresExistingReceipt(_ task: AgentTask) -> Bool {
        // An audit event can require verification, but can never grant a lease.
        // A restored database must not treat a missing sidecar as a fresh task.
        if task.events.contains(where: { $0.type == TaskEventTypes.System.runtimeExecutionOwnership.rawValue }) { return true }
        let reason = task.runs.max(by: { $0.startedAt < $1.startedAt })?.typedStopReason
        return reason == .appRestarted || reason == .runtimeConnectionLost
    }

    static func inspection(task: AgentTask, context: ModelContext) throws -> RuntimeSessionInspection? {
        guard let record = try existing(task: task, context: context) else { return nil }
        return .inspect(record, ownedHere: active.contains(key(taskID: task.id, context: context)))
    }

    enum RetryDecision { case legacy, continuation, blocked }

    /// Read first, before Retry changes usage, enqueues a turn or resets state.
    static func retryDecision(task: AgentTask, context: ModelContext) -> RetryDecision {
        do {
            guard let record = try existing(task: task, context: context) else {
                if requiresExistingReceipt(task) {
                    report("The saved execution receipt is missing. ASTRA cannot verify that earlier work stopped, so Retry is blocked.", task: task, context: context, pause: true)
                    return .blocked
                }
                return .legacy
            }
            let here = active.contains(key(taskID: task.id, context: context))
            if !here && record.canBeginNewTurn { return .legacy }
            if !here && record.canReplace { return .continuation }
            let inspection = RuntimeSessionInspection.inspect(record, ownedHere: here)
            report(inspection.message, task: task, context: context, pause: !here)
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
                || (record.state == .preparing && record.appProcess.presence == .absent) { return false }
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
                        newUserTurn: Bool = false, launchTask: AgentTask? = nil) -> RuntimeExecutionOwner? {
        let key = key(taskID: task.id, context: context)
        do {
            guard !active.contains(key) else { throw RuntimeExecutionOwnerStore.Failure.busy }
            let lease = try store(in: context).acquire(taskID: task.id)
            let previous = try lease.read().map { reconciledCompletion($0, task: task) }
            guard previous == nil || previous?.taskID == task.id else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
            if previous == nil, requiresExistingReceipt(task) {
                report("The saved execution receipt is missing. ASTRA preserved this task and blocked replacement work.", task: task, context: context, pause: true)
                return nil
            }
            if let previous {
                let abandonedBeforeLaunch = previous.state == .preparing && previous.appProcess.presence == .absent
                guard previous.canReplace || previous.canBeginNewTurn || abandonedBeforeLaunch
                    || (newUserTurn && previous.canAcceptUserTurn) else {
                    report(RuntimeSessionInspection.inspect(previous, ownedHere: false).message, task: task, context: context, pause: true)
                    return nil
                }
            }
            guard let app = RuntimeProcessIdentity.read(ProcessInfo.processInfo.processIdentifier) else { throw RuntimeExecutionOwnerStore.Failure.unreadable }
            let recovering = previous != nil && previous?.canBeginNewTurn != true
            let configuration = launchTask ?? task
            let limits = recovering ? previous!.limits : RuntimeRecoveryLimits(
                tokenCeiling: AgentRuntimeProcessRunner.effectiveTokenBudget(for: configuration),
                turnsRemaining: configuration.maxTurns > 0 ? configuration.maxTurns : Int.max,
                secondsRemaining: maxRunSeconds > 0 ? maxRunSeconds : .greatestFiniteMagnitude,
                tokensSpent: 0, costSpent: 0)
            let record = RuntimeExecutionOwnerRecord(taskID: task.id, ownerID: UUID(), executionID: UUID(),
                appProcess: app, runtime: recovering ? previous!.runtime : task.resolvedRuntimeID.rawValue, sessionID: recovering ? previous?.sessionID : nil,
                state: .preparing, limits: limits, automaticRestarts: recovering ? previous!.automaticRestarts : 0, updatedAt: Date())
            try lease.save(record) // fail closed before any worker/provider side effect
            active.insert(key)
            return .init(key: key, lease: lease, record: record, isRecovery: recovering, task: task, context: context)
        } catch {
            let live = active.contains(key)
            report(live ? "ASTRA reconnected to the existing recovery owner. No competing attempt was started."
                : "Recovery ownership could not be verified or saved. No provider was started.", task: task, context: context, pause: !live)
            return nil
        }
    }

    func restoreSession(for runtime: AgentRuntimeID) {
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
        guard !writeFailed, lease != nil, record.state == .preparing || record.canReplace else { throw RuntimeExecutionOwnerStore.Failure.busy }
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
        guard let sessionID, !sessionID.isEmpty, record.sessionID != sessionID else { return }
        record.sessionID = sessionID; try? save(nil)
    }

    func waitingForInput(_ waiting: Bool) {
        guard record.state == .working || record.state == .waitingForInput else { return }
        record.state = waiting ? .waitingForInput : .working
        try? save(waiting ? "The existing provider session is waiting for input. Automatic restart is paused." : nil)
    }

    func stopped(proof: RuntimeExecutionStopProof?, turns: Int, tokens: Int, seconds: TimeInterval) {
        guard record.state != .notStarted else { return }
        record.stopProof = proof
        record.limits.tokensSpent += max(0, tokens)
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

    func finish() {
        defer { lease = nil; Self.active.remove(key) }
        guard lease != nil else { return }
        record.limits.costSpent += run?.costUSD ?? 0
        if record.state == .preparing { record.state = .notStarted }
        if run?.status == .completed, record.stopProof?.reaped == true, record.stopProof?.processGroupEmpty == true { record.state = .finished }
        try? save(nil)
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
        if audit || message != nil {
            let payload = TaskEvent.payloadString(record, fallback: "{}")
            context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.runtimeExecutionOwnership, payload: payload, run: run))
            if let message { Self.report(message, task: task, context: context) }
            else { WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: context) }
        }
    }

    static func report(_ message: String, task: AgentTask, context: ModelContext, pause: Bool = false, autoExport: Bool = true) {
        if pause { TaskStateMachine.pauseForRuntimeReview(task, modelContext: context) }
        context.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.info, payload: message))
        if autoExport { WorkspacePersistenceCoordinator.saveAndAutoExport(workspace: task.workspace, modelContext: context) }
        else { WorkspacePersistenceCoordinator.saveWithoutAutoExport(modelContext: context) }
    }

    private static func key(taskID: UUID, context: ModelContext) -> String { store(in: context).root.path + "/" + taskID.uuidString }
}
