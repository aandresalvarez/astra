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
    struct Presentation {
        var jobs: [RemoteWorkspaceJobRecord] = []
        var error: String?
        var refreshing = false
    }
    private var presentations: [String: Presentation] = [:]
    private var inFlight: Set<String> = []

    func presentation(task: AgentTask, context: ModelContext) -> Presentation {
        guard task.isLive else { return Presentation() }
        return presentations[key(task: task, context: context)] ?? Presentation()
    }

    func refresh(task: AgentTask, context: ModelContext) async {
        guard task.isLive, task.modelContext === context, !Task.isCancelled else { return }
        let taskID = task.id
        let key = key(task: task, context: context)
        guard inFlight.insert(key).inserted else { return }
        defer { inFlight.remove(key); presentations[key]?.refreshing = false }
        do {
            let configurations = try RemoteWorkspaceJobRegistration.loadAll(task: task, context: context)
            var observed: [RemoteWorkspaceJobRecord] = []
            for config in configurations {
            let store = RemoteWorkspaceJobStore(rootPath: config.recordRootPath)
            let before = try store.records()
            for job in before { try RemoteWorkspaceJobEventReconciler.reconcile(job, task: task, context: context, store: store) }
            presentations[key] = .init(jobs: observed + before, refreshing: !before.isEmpty)
            let cancellation = try RuntimeExecutionOwner.existing(task: task, context: context)?.cancellationRequested == true
            if cancellation {
                for job in before where !job.status.isTerminal && job.cancellationRequestedAt == nil {
                    try store.update(jobID: job.jobID) { $0.cancellationRequestedAt = Date() }
                }
            }
            // Each task has an independent observation worker. A disconnected
            // host cannot block unrelated tasks or Swift's cooperative pool.
            let result = await BlockingWork.run(qos: .utility) { () -> Result<[RemoteWorkspaceJobRecord], Error> in
                let manager = RemoteWorkspaceJobManager(configuration: config)
                for job in before { _ = manager.status(jobID: job.jobID) }
                return Result { try manager.store.records() }
            }
            guard task.isLive, task.modelContext === context, !Task.isCancelled else {
                presentations.removeValue(forKey: key)
                return
            }
            let after = try result.get().sorted { $0.createdAt < $1.createdAt }
            observed += after
            presentations[key] = .init(jobs: observed)
            for job in after { try RemoteWorkspaceJobEventReconciler.reconcile(job, task: task, context: context, store: store) }
            }
        } catch {
            guard task.isLive, task.modelContext === context, !Task.isCancelled else { return }
            var value = presentations[key] ?? Presentation()
            value.error = "Remote job check failed: \(error.localizedDescription) The task reservation is preserved."
            presentations[key] = value
            AppLogger.audit(.workerBlocked, category: "RemoteJobs", taskID: taskID,
                fields: ["reason": "observation_failed", "error": error.localizedDescription], level: .warning)
        }
    }

    /// Synchronous durable intent, followed by an idempotent asynchronous
    /// delivery. Even a crash between these steps cannot erase cancellation.
    @discardableResult
    func requestCancellation(task: AgentTask, jobID: String? = nil, context: ModelContext,
        deliver: @escaping @Sendable (RemoteWorkspaceJobConfiguration) async -> Void = RemoteWorkspaceJobCancellationDelivery.deliver) -> Bool {
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
                let saved = try store.update(jobID: job.jobID) { $0.cancellationRequestedAt = Date() }
                try RemoteWorkspaceJobEventReconciler.reconcile(saved, task: task, context: context, store: store)
            }
            presentations[key(task: task, context: context)] = .init(jobs: try store.records())
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

    private func key(task: AgentTask, context: ModelContext) -> String {
        RuntimeExecutionOwner.store(in: context).root.path + "/" + task.id.uuidString
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
                    let deliveries = try RemoteWorkspaceJobCancellationDelivery.pending(context: context)
                    await withTaskGroup(of: Void.self) { group in
                        for delivery in deliveries { group.addTask { await RemoteWorkspaceJobCancellationDelivery.deliver(delivery) } }
                        for task in tasks {
                            group.addTask { @MainActor in
                                await RemoteWorkspaceJobMonitor.shared.refresh(task: task, context: context)
                            }
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
    /// Only tasks with a registration in their retained execution lineage can have
    /// remote jobs to observe. Fetching every task every 15 seconds faults all
    /// workspace relationships and retains thousands of unrelated models.
    /// This is a fresh projection of the protected journal, not a cached owner.
    static func registeredTasks(context: ModelContext) throws -> [AgentTask] {
        let authority = RuntimeExecutionOwner.store(in: context)
        let owners = try authority.records()
        var result: [AgentTask] = []
        for owner in owners {
            let executions = [owner] + (try authority.retainedExecutions(of: owner))
            guard executions.contains(where: {
                let root = RemoteWorkspaceJobRegistration.directory(taskID: $0.taskID,
                    executionID: $0.executionID, context: context)
                return FileManager.default.fileExists(atPath: root.appendingPathComponent("configuration.json").path)
            }) else { continue }
            let taskID = owner.taskID
            result += try context.fetch(FetchDescriptor<AgentTask>(predicate: #Predicate { $0.id == taskID }))
        }
        return result
    }

    deinit { loop?.cancel() }
}
