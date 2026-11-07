import Foundation
import Observation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence
import WorkspaceToolSupport

/// Presentation is a cache of the protected job journal. Refreshes can only
/// observe or deliver a saved cancellation; they never start/retry a provider.
@MainActor @Observable
final class RemoteWorkspaceJobMonitor {
    static let shared = RemoteWorkspaceJobMonitor()
    struct Presentation: Equatable {
        var jobs: [RemoteWorkspaceJobRecord] = []
        var error: String?
        /// Check now is running. Automatic passes stay silent.
        var refreshing = false
        /// Another task's request is waiting on a fresh check of these jobs.
        var awaited = false
    }
    private struct Key: Hashable { let root: String; let owner: PersistentIdentifier }
    private var presentations: [Key: Presentation] = [:]
    private var inFlight: Set<Key> = []
    private var forcedAfterPass: Set<Key> = []

    func presentation(task: AgentTask, context: ModelContext) -> Presentation {
        guard task.isLive else { return Presentation() }
        return presentations[key(task: task, context: context)] ?? Presentation()
    }

    /// Mid-refresh list: jobs already observed, the configuration being read,
    /// then jobs not reached yet as last seen. Without the last part the list
    /// empties at every refresh, and the rail drops its rows and their state.
    /// A completed refresh publishes `observed` alone.
    nonisolated static func interimJobs(
        observed: [RemoteWorkspaceJobRecord],
        current: [RemoteWorkspaceJobRecord],
        previous: [RemoteWorkspaceJobRecord]
    ) -> [RemoteWorkspaceJobRecord] {
        let seen = Set((observed + current).map(\.jobID))
        return observed + current + previous.filter { !seen.contains($0.jobID) }
    }

    /// `previous` with one configuration's records swapped in by job ID, in
    /// place, and its new jobs appended: other configurations' jobs stay listed.
    nonisolated static func replacingJobs(
        _ previous: [RemoteWorkspaceJobRecord],
        with updates: [RemoteWorkspaceJobRecord]
    ) -> [RemoteWorkspaceJobRecord] {
        let byID = Dictionary(updates.map { ($0.jobID, $0) }, uniquingKeysWith: { $1 })
        let known = Set(previous.map(\.jobID))
        return previous.map { byID[$0.jobID] ?? $0 } + updates.filter { !known.contains($0.jobID) }
    }

    /// `force` is Check now: every job is checked and the box shows progress.
    /// An automatic pass contacts the host only for jobs the observation
    /// policy says are due, and publishes nothing unless a record changed.
    /// `awaited` comes from the monitor session; nil keeps the last value.
    func refresh(task: AgentTask, context: ModelContext, force: Bool = false, awaited: Bool? = nil) async {
        guard task.isLive, task.modelContext === context, !Task.isCancelled else { return }
        let key = key(task: task, context: context)
        let awaited = awaited ?? presentations[key]?.awaited ?? false
        guard inFlight.insert(key).inserted else {
            // Check now during an automatic pass runs in full right after it.
            if force { forcedAfterPass.insert(key); setRefreshing(true, key) }
            return
        }
        var force = force
        while true {
            if force { setRefreshing(true, key) }
            await observe(task: task, context: context, key: key, force: force, awaited: awaited)
            guard forcedAfterPass.remove(key) != nil, task.isLive, task.modelContext === context,
                  !Task.isCancelled else { break }
            force = true
        }
        inFlight.remove(key)
        forcedAfterPass.remove(key)
        setRefreshing(false, key)
    }

    private func observe(task: AgentTask, context: ModelContext, key: Key, force: Bool, awaited: Bool) async {
        let taskID = task.id
        do {
            let configurations = try RemoteWorkspaceJobRegistration.loadAll(task: task, context: context)
            guard !configurations.isEmpty else {
                publish(nil, key)
                return
            }
            let previous = presentations[key]?.jobs ?? []
            var observed: [RemoteWorkspaceJobRecord] = []
            for config in configurations {
                let store = RemoteWorkspaceJobStore(rootPath: config.recordRootPath)
                var current = try store.records().sorted { $0.createdAt < $1.createdAt }
                for job in current { try RemoteWorkspaceJobEventReconciler.reconcile(job, task: task, context: context, store: store) }
                let cancellation = try RuntimeExecutionOwner.existing(task: task, context: context)?.cancellationRequested == true
                let uncancelled = current.filter { !$0.status.isTerminal && $0.cancellationRequestedAt == nil }
                if cancellation && !uncancelled.isEmpty {
                    for job in uncancelled {
                        try store.update(jobID: job.jobID) { $0.requestCancellation(at: Date()) }
                    }
                    current = try store.records().sorted { $0.createdAt < $1.createdAt }
                }
                let now = Date()
                let delivery = try RemoteWorkspaceJobCancellationDelivery.savedDelivery(for: config)
                let due = current.filter { force || RemoteWorkspaceJobObservationPolicy.isDue($0, awaited: awaited, now: now) }
                    .map { (jobID: $0.jobID, configuration: Self.observationConfiguration(for: $0, task: config, delivery: delivery)) }
                var after = current
                if !due.isEmpty {
                    publish(Self.interimJobs(observed: observed, current: current, previous: previous), awaited: awaited, key)
                    // Each task has an independent observation worker. A disconnected
                    // host cannot block unrelated tasks or Swift's cooperative pool.
                    let result = await BlockingWork.run(qos: .utility) { () -> Result<[RemoteWorkspaceJobRecord], Error> in
                        for check in due { _ = RemoteWorkspaceJobManager(configuration: check.configuration).status(jobID: check.jobID) }
                        return Result { try RemoteWorkspaceJobStore(rootPath: config.recordRootPath).records() }
                    }
                    guard task.isLive, task.modelContext === context, !Task.isCancelled else {
                        publish(nil, key)
                        return
                    }
                    after = try result.get().sorted { $0.createdAt < $1.createdAt }
                }
                observed += after
                publish(Self.interimJobs(observed: observed, current: [], previous: previous), awaited: awaited, key)
                for job in after { try RemoteWorkspaceJobEventReconciler.reconcile(job, task: task, context: context, store: store) }
            }
            publish(observed, awaited: awaited, key)
        } catch {
            guard task.isLive, task.modelContext === context, !Task.isCancelled else { return }
            var value = presentations[key] ?? Presentation()
            value.error = "Remote job check failed: \(error.localizedDescription) The task reservation is preserved."
            publish(value, key)
            AppLogger.audit(.workerBlocked, category: "RemoteJobs", taskID: taskID,
                fields: ["reason": "observation_failed", "error": error.localizedDescription], level: .warning)
        }
    }

    /// A job with a saved cancellation is checked as the outbox sends it, with
    /// the trust file pinned in its receipt; `status` delivers the cancel.
    nonisolated static func observationConfiguration(
        for job: RemoteWorkspaceJobRecord,
        task configuration: RemoteWorkspaceJobConfiguration,
        delivery: RemoteWorkspaceJobConfiguration?
    ) -> RemoteWorkspaceJobConfiguration {
        job.cancellationRequestedAt == nil ? configuration : delivery ?? configuration
    }

    /// Writes only real changes: every write re-renders each view reading the
    /// cache, and an automatic pass that changed nothing must not.
    private func publish(_ value: Presentation?, _ key: Key) {
        guard presentations[key] != value else { return }
        presentations[key] = value
    }

    /// A completed or partial list: clears the last error, keeps `refreshing`.
    private func publish(_ jobs: [RemoteWorkspaceJobRecord], awaited: Bool, _ key: Key) {
        var value = presentations[key] ?? Presentation()
        value.jobs = jobs
        value.error = nil
        value.awaited = awaited
        publish(value, key)
    }

    private func setRefreshing(_ refreshing: Bool, _ key: Key) {
        guard (presentations[key]?.refreshing ?? false) != refreshing else { return }
        var value = presentations[key] ?? Presentation()
        value.refreshing = refreshing
        presentations[key] = value
    }

    /// Synchronous durable intent, followed by an idempotent asynchronous
    /// delivery. Even a crash between these steps cannot erase cancellation.
    @discardableResult
    func requestCancellation(task: AgentTask, jobID: String? = nil, context: ModelContext,
        deliver: @escaping @Sendable (RemoteWorkspaceJobConfiguration) async -> Void = { await RemoteWorkspaceJobCancellationDelivery.deliver($0) }) -> Bool {
        guard task.isLive, task.modelContext === context else { return false }
        do {
            let configurations = try RemoteWorkspaceJobRegistration.loadAll(task: task, context: context)
            for config in configurations {
            let store = RemoteWorkspaceJobStore(rootPath: config.recordRootPath)
            let jobs = try store.records().filter { (jobID == nil || $0.jobID == jobID) && !$0.status.isTerminal }
            guard jobID == nil || !jobs.isEmpty else { continue }
            let delivery = try RemoteWorkspaceJobCancellationDelivery.persist(configuration: config, task: task, cancelExecution: jobID == nil)
            for job in jobs {
                guard job.cancellationRequestedAt == nil else { continue }
                let saved = try store.update(jobID: job.jobID) { $0.requestCancellation(at: Date()) }
                try RemoteWorkspaceJobEventReconciler.reconcile(saved, task: task, context: context, store: store)
            }
            let presentationKey = key(task: task, context: context)
            var value = presentations[presentationKey] ?? Presentation()
            value.jobs = Self.replacingJobs(value.jobs, with: try store.records())
            publish(value, presentationKey)
            Task {
                await deliver(delivery)
                await refresh(task: task, context: context)
            }
            }
            return true
        } catch {
            presentations[key(task: task, context: context), default: Presentation()].error =
                "Cancellation could not be saved: \(error.localizedDescription). The reservation is preserved."
            AppLogger.audit(.workerBlocked, category: "RemoteJobs", taskID: task.id,
                fields: ["reason": "cancellation_failed", "error": error.localizedDescription], level: .error)
            return false
        }
    }

    func tail(task: AgentTask, jobID: String, context: ModelContext) async -> String {
        guard task.isLive, task.modelContext === context else { return "Task no longer available." }
        do {
            let configurations = try RemoteWorkspaceJobRegistration.loadAll(task: task, context: context)
            guard let config = try configurations.first(where: {
                try RemoteWorkspaceJobStore(rootPath: $0.recordRootPath).records().contains { $0.jobID == jobID }
            }) else { return "Job registration unavailable." }
            return await BlockingWork.run {
                switch RemoteWorkspaceJobManager(configuration: config).tail(jobID: jobID, stream: "stdout", lines: 80) {
                case .text(_, _, let text): return text.isEmpty ? "No output yet." : text
                case .failure(let message): return message
                }
            }
        } catch { return error.localizedDescription }
    }

    private func key(task: AgentTask, context: ModelContext) -> Key {
        Key(root: RuntimeExecutionOwner.store(in: context).root.path, owner: task.persistentModelID)
    }


}

/// Owned by the queue's store session; restart reopens the same journal. This
/// timer is only an observable refresh trigger, never execution authority.
@MainActor
final class RemoteWorkspaceJobMonitorSession {
    private var loop: Task<Void, Never>?
    init(context: ModelContext) {
        guard context.container.configurations.allSatisfy({ !$0.isStoredInMemoryOnly }) else { return }
        loop = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    let tasks = try Self.registeredTasks(context: context)
                    let awaited = try Self.awaitedTaskIDs(context: context)
                    await withTaskGroup(of: Void.self) { group in
                        for task in tasks {
                            let isAwaited = awaited.contains(task.id)
                            group.addTask { @MainActor in
                                await RemoteWorkspaceJobMonitor.shared.refresh(task: task, context: context, awaited: isAwaited)
                            }
                        }
                    }
                    // After the refreshes: a live task's refresh delivers its own
                    // saved cancellations, so the outbox finds those jobs just
                    // checked and contacts only hosts no refresh reached.
                    let deliveries = try RemoteWorkspaceJobCancellationDelivery.pending(context: context)
                    await withTaskGroup(of: Void.self) { group in
                        for delivery in deliveries {
                            group.addTask { await RemoteWorkspaceJobCancellationDelivery.deliver(delivery) }
                        }
                    }
                } catch {
                    AppLogger.audit(.workerBlocked, category: "RemoteJobs",
                        fields: ["reason": "monitor_fetch_failed", "error": error.localizedDescription], level: .warning)
                }
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    /// Tasks holding a workspace that another task's request is waiting for.
    /// Continuing that workspace needs a recent complete check of the holder's
    /// jobs, so they stay on the live cadence while the request waits. The
    /// request names only its first conflicting holder; a saved continuation
    /// checks every predecessor it lists, so all of them are awaited.
    static func awaitedTaskIDs(context: ModelContext) throws -> Set<UUID> {
        let waiting = TaskTurnRequestState.waitingForResource.rawValue
        let requests = try context.fetch(FetchDescriptor<TaskTurnRequest>(
            predicate: #Predicate { $0.stateRawValue == waiting }))
        let store = RuntimeExecutionOwner.store(in: context)
        var awaited = Set(requests.compactMap(\.blockingTaskID))
        for request in requests {
            // Cadence only: an unreadable continuation fails admission anyway.
            let sources = (try? store.workspaceContinuation(requestID: request.id))?.sources ?? []
            awaited.formUnion(sources.map(\.receipt.taskID))
        }
        return awaited
    }

    /// Only tasks with a registration in their retained execution lineage can have
    /// remote jobs to observe. Fetching every task every 15 seconds faults all
    /// workspace relationships and retains thousands of unrelated models.
    /// This is a fresh projection of the protected journal, not a cached owner.
    static func registeredTasks(context: ModelContext) throws -> [AgentTask] {
        let authority = RuntimeExecutionOwner.store(in: context)
        let owners = try authority.records()
        var result: [AgentTask] = []
        var seen: Set<PersistentIdentifier> = []
        for owner in owners {
            let executions = [owner] + (try authority.retainedExecutions(of: owner))
            guard executions.contains(where: {
                let root = RemoteWorkspaceJobRegistration.directory(taskID: $0.taskID,
                    executionID: $0.executionID, context: context)
                return FileManager.default.fileExists(atPath: root.appendingPathComponent("configuration.json").path)
            }) else { continue }
            let taskID = owner.taskID
            let candidates = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID }))
            for task in candidates where task.isLive {
                guard let current = try RuntimeExecutionOwner.existing(task: task, context: context),
                      current.ownerID == owner.ownerID, current.executionID == owner.executionID,
                      seen.insert(task.persistentModelID).inserted else { continue }
                result.append(task)
            }
        }
        return result
    }

    deinit { loop?.cancel() }
}
