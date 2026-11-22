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
                let uncancelled = current.filter { !$0.status.isTerminal && $0.cancellationRequestedAt == nil }
                // The owner's cancellation only matters to a job still to be
                // cancelled, so the receipt is read only when there is one.
                if !uncancelled.isEmpty,
                   try RuntimeExecutionOwner.existing(task: task, context: context)?.cancellationRequested == true {
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
                    let tasks = try Self.registeredTasks(journal: try await Self.journal(context: context), context: context)
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
                    // Read again: the refreshes above awaited, and a cancellation
                    // saved meanwhile belongs to this pass.
                    let executions = try await Self.journal(context: context).owners.flatMap(\.executions)
                    let deliveries = try RemoteWorkspaceJobCancellationDelivery.pending(executions: executions, context: context)
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

    /// One read of the protected journal: every owner, its retained
    /// executions, and whether any of them registered remote jobs.
    struct Journal: Sendable {
        struct Owner: Sendable {
            let record: RuntimeExecutionOwnerRecord
            /// The owner's own execution first, then the ones it retains.
            let executions: [RuntimeExecutionOwnerRecord]
            let isRegistered: Bool
        }
        let owners: [Owner]
    }

    /// Reads the journal as `registeredTasks` always has, from wherever it is
    /// called. It is file reading and decoding only, which is why a pass can
    /// do it off the main actor: every 15 seconds it opens each owner's
    /// receipt and each execution it retains, and that grows with every run.
    nonisolated static func readJournal(ownersRoot: URL) throws -> Journal {
        let authority = RuntimeExecutionOwnerStore(root: ownersRoot)
        return Journal(owners: try authority.records().map { owner in
            let executions = [owner] + (try authority.retainedExecutions(of: owner))
            let isRegistered = executions.contains {
                let root = RemoteWorkspaceJobRegistration.directory(
                    taskID: $0.taskID, executionID: $0.executionID, ownersRoot: ownersRoot)
                return FileManager.default.fileExists(atPath: root.appendingPathComponent("configuration.json").path)
            }
            return Journal.Owner(record: owner, executions: executions, isRegistered: isRegistered)
        })
    }

    /// `readJournal` on a worker thread, for the pass. A fresh projection of
    /// the journal each time, never a cached owner: what a refresh acts on is
    /// read again by that refresh.
    static func journal(context: ModelContext) async throws -> Journal {
        let root = RuntimeExecutionOwner.store(in: context).root
        let offMain = await BlockingWork.run(qos: .utility) { Result { try readJournal(ownersRoot: root) } }
        if case .success(let journal) = offMain { return journal }
        // A writer on the main actor can replace or retire a receipt between
        // the worker's listing and its read. No writer can interleave here,
        // so an error from this read is the journal's own.
        return try readJournal(ownersRoot: root)
    }

    /// Only tasks with a registration in their retained execution lineage can have
    /// remote jobs to observe. Fetching every task every 15 seconds faults all
    /// workspace relationships and retains thousands of unrelated models.
    /// This is a fresh projection of the protected journal, not a cached owner.
    static func registeredTasks(context: ModelContext) throws -> [AgentTask] {
        try registeredTasks(
            journal: readJournal(ownersRoot: RuntimeExecutionOwner.store(in: context).root), context: context)
    }

    static func registeredTasks(journal: Journal, context: ModelContext) throws -> [AgentTask] {
        let registered = journal.owners.filter(\.isRegistered).map(\.record)
        guard !registered.isEmpty else { return [] }
        // A receipt bound to a row names it, and a row is found by identity.
        // Only an unbound receipt has to be matched by the task's portable
        // ID, which no index serves: those share one walk of the task table
        // instead of one walk each.
        let unboundIDs = Array(Set(registered.filter { $0.taskOwnerID == nil }.map(\.taskID)))
        var unbound: [UUID: [AgentTask]] = [:]
        if !unboundIDs.isEmpty {
            let rows = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { unboundIDs.contains($0.id) }))
            unbound = Dictionary(grouping: rows, by: \.id)
        }
        var result: [AgentTask] = []
        var seen: Set<PersistentIdentifier> = []
        for owner in registered {
            let taskID = owner.taskID
            let candidates: [AgentTask]
            // An unbound receipt is attributed by going over every task with
            // its ID. Those are the rows just fetched, so attribution reuses
            // them instead of walking the table again for each candidate.
            let sharingID: [AgentTask]?
            if let row = owner.taskOwnerID {
                candidates = try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.persistentModelID == row }))
                    .filter { $0.id == taskID }
                sharingID = nil
            } else {
                candidates = unbound[taskID] ?? []
                sharingID = candidates
            }
            for task in candidates where task.isLive {
                guard let current = try RuntimeExecutionOwner.existing(task: task, context: context, sharingID: sharingID),
                      current.ownerID == owner.ownerID, current.executionID == owner.executionID,
                      seen.insert(task.persistentModelID).inserted else { continue }
                result.append(task)
            }
        }
        return result
    }

    deinit { loop?.cancel() }
}
