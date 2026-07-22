import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// Owns the persistence lifetime used by a queue. Queue coroutines may retain
/// this session, but must not retain a caller-borrowed context independently.
/// The container is held explicitly so an in-memory/test store cannot be torn
/// down while a cancelled coroutine is still unwinding.
@MainActor
final class TaskQueueStoreSession {
    let modelContainer: ModelContainer
    let modelContext: ModelContext

    private(set) var didRepairLegacyRequests = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.modelContainer = modelContext.container
    }

    func matches(_ modelContext: ModelContext) -> Bool {
        self.modelContext === modelContext
    }

    /// Legacy status repair is a store-open compatibility action, not queue
    /// admission policy. It therefore runs at most once for this store session.
    @discardableResult
    func repairLegacyRequestsIfNeeded() -> ExecutionRequestLegacyRepairService.Report? {
        guard !didRepairLegacyRequests else { return nil }
        let report = ExecutionRequestLegacyRepairService.repair(in: modelContext)
        didRepairLegacyRequests = report.isComplete
        AppLogger.audit(.taskStats, category: "Persistence", fields: [
            "operation": "repair_legacy_execution_requests",
            "queued_task_count": String(report.queuedTaskCount),
            "created_request_count": String(report.createdRequestCount),
            "failed_request_count": String(report.failedRequestCount),
            "repair_complete": String(report.isComplete)
        ], level: report.failedRequestCount == 0 ? .debug : .error)
        return report
    }
}

/// One-time compatibility repair for stores created before durable execution
/// requests became the queue authority. New submissions must go through
/// `ExecutionRequestSubmissionService`; normal queue iterations never call it.
@MainActor
enum ExecutionRequestLegacyRepairService {
    struct Report: Equatable {
        let queuedTaskCount: Int
        let createdRequestCount: Int
        let failedRequestCount: Int
        let isComplete: Bool
        let failureReasons: [String]
    }

    static func repair(in modelContext: ModelContext) -> Report {
        let tasks: [AgentTask]
        do {
            // `AgentTask.status` is a persisted Codable enum. SwiftData rejects
            // a predicate that captures TaskStatus as an unsupported constant
            // (and older framework builds have trapped in that fetch path).
            // This compatibility repair runs once per store session, so fetch
            // once and filter the enum safely in memory.
            tasks = try modelContext.fetch(FetchDescriptor<AgentTask>())
                .filter { $0.status == .queued }
        } catch {
            AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                "operation": "fetch_legacy_queued_tasks",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return Report(
                queuedTaskCount: 0,
                createdRequestCount: 0,
                failedRequestCount: 1,
                isComplete: false,
                failureReasons: ["fetch_legacy_queued_tasks:\(String(describing: error))"]
            )
        }

        var created = 0
        var failed = 0
        let taskIDsWithRequestHistory: Set<UUID>
        do {
            taskIDsWithRequestHistory = Set(
                try modelContext.fetch(FetchDescriptor<TaskTurnRequest>()).map(\.taskID)
            )
        } catch {
            AppLogger.audit(.taskFailed, category: "Persistence", fields: [
                "operation": "fetch_active_requests_for_legacy_repair",
                "error_type": String(describing: type(of: error))
            ], level: .error)
            return Report(
                queuedTaskCount: tasks.count,
                createdRequestCount: 0,
                failedRequestCount: tasks.count,
                isComplete: false,
                failureReasons: ["fetch_request_history:\(String(describing: error))"]
            )
        }
        var failureReasons: [String] = []
        for task in tasks {
            // Any durable history proves this task is modern. In particular, a
            // cancelled request must never be resurrected as a new initial turn
            // merely because no ACTIVE request remains.
            guard !taskIDsWithRequestHistory.contains(task.id) else { continue }
            do {
                _ = try TaskWorkspaceAccess(task: task).ensureTaskFolder()
            } catch {
                failed += 1
                failureReasons.append("prepare_task_folder:\(task.id):\(String(describing: error))")
                AppLogger.audit(.taskFailed, category: "Persistence", taskID: task.id, fields: [
                    "operation": "prepare_legacy_request_task_folder",
                    "error_type": String(describing: type(of: error))
                ], level: .error)
                continue
            }
            switch ExecutionRequestSubmissionService.submitInitial(for: task, into: modelContext) {
            case .success:
                created += 1
            case .failure(let error):
                failed += 1
                failureReasons.append("submit_request:\(task.id):\(String(describing: error))")
                AppLogger.audit(.taskFailed, category: "Persistence", taskID: task.id, fields: [
                    "operation": "submit_legacy_execution_request",
                    "error": String(describing: error)
                ], level: .error)
            }
        }
        return Report(
            queuedTaskCount: tasks.count,
            createdRequestCount: created,
            failedRequestCount: failed,
            isComplete: failed == 0,
            failureReasons: failureReasons
        )
    }
}
