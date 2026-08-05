import Foundation
import SwiftData
import ASTRACore
import ASTRAModels
import ASTRAPersistence

/// The only production writer for a task's read/unread state.
///
/// Read state is cleared in memory first because every consumer (sidebar
/// ordering, row weight, the selected-task unread signature) reads
/// `AgentTask.unreadAt` on the same run-loop turn; deferring the mutation would
/// leave the opened task rendering unread and re-fire the observer that called
/// us. Only the durable write is coalesced: the workspace JSON mirror is a
/// derived view, so it goes through the debounced export instead of blocking
/// task navigation on a whole-workspace export.
///
/// The injected persistence seam makes save failures deterministic in tests.
@MainActor
struct TaskReadStateService {
    typealias Persistence = @MainActor (AgentTask, ModelContext) throws -> Void

    private let modelContext: ModelContext
    private let persist: Persistence

    init(modelContext: ModelContext, persist: Persistence? = nil) {
        self.modelContext = modelContext
        self.persist = persist ?? { task, context in
            let workspace = task.workspace
            try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(
                workspace: workspace,
                modelContext: context,
                taskID: task.id,
                auditFields: ["operation": "mark_task_read"]
            )
            if let workspace {
                WorkspacePersistenceCoordinator.scheduleAutoExport(
                    workspace: workspace,
                    modelContext: context
                )
            }
        }
    }

    func markRead(_ task: AgentTask) {
        task.markRead()
        do {
            try persist(task, modelContext)
        } catch {
            // Deliberately no rollback, unlike WorkspaceCanvasItemPreferenceService:
            // restoring `unreadAt` would pop the unread dot back under the user on a
            // transient save failure, and the next save of this context supersedes it.
            AppLogger.audit(.taskFailed, category: "UI", taskID: task.id, fields: [
                "operation": "mark_task_read",
                "error_type": String(describing: type(of: error))
            ], level: .error)
        }
    }
}
