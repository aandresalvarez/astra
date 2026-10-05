import Foundation
import SwiftData
import ASTRAModels
import ASTRAPersistence

extension TaskExecutionContext {
    @MainActor @discardableResult
    func bindStorage(task: AgentTask, modelContext: ModelContext) throws -> TaskEvent? {
        try validate(task: task)
        guard let scope = resourceScope else { return nil }
        return try TaskStorageBindingService.bind(task: task, scope: scope, modelContext: modelContext)
    }

    @MainActor
    static func prepareLaunch(task: AgentTask, launchTask: AgentTask, requestID: UUID?, modelContext: ModelContext) -> Bool {
        do {
            guard let requestID else {
                guard launchTask.acceptedResourceScope == nil else { throw ContextError.invalid }
                return true
            }
            guard let owner = try TaskTurnRequestRepository.request(id: requestID, in: modelContext),
                  owner.taskID == task.id, launchTask.id == task.id,
                  let scope = owner.executionPolicySnapshot?.resourceScope,
                  scope == launchTask.acceptedResourceScope else { throw ContextError.invalid }
            if try TaskExecutionContext(taskID: task.id, acceptedScope: scope).bindStorage(task: task, modelContext: modelContext) != nil {
                try WorkspacePersistenceCoordinator.saveWithoutAutoExportOrThrow(workspace: task.workspace, modelContext: modelContext,
                    taskID: task.id, auditFields: ["operation": "bind_execution_storage"])
            }
            return true
        } catch {
            AppLogger.audit(.workerBlocked, category: "Worker", taskID: task.id,
                fields: ["reason": "invalid_launch_authority", "error": error.localizedDescription], level: .error)
            TaskStateMachine.failFromRuntime(task, modelContext: modelContext)
            modelContext.insert(TaskEvent(task: task, eventType: TaskEventTypes.System.error,
                payload: "Accepted execution authority could not be restored: \(error.localizedDescription)"))
            return false
        }
    }
}

extension RuntimeTurnSettlementService.Checkpoint {
    @MainActor
    func executionContext(for task: AgentTask) -> TaskExecutionContext {
        if let scope = launchSnapshot.resourceScope {
            return .init(taskID: task.id, acceptedScope: scope, workingDirectory: executionPath)
        }
        return .legacy(task: task, workingDirectory: executionPath)
    }

    @MainActor
    func bindExecutionStorage(task: AgentTask, modelContext: ModelContext) throws {
        guard launchSnapshot.id == task.id,
              launchSnapshot.resourceScope == nil || requestID != nil else {
            throw RuntimeTurnSettlementService.Failure.invalidRequestOwner
        }
        if let requestID {
            guard let request = try TaskTurnRequestRepository.request(id: requestID, in: modelContext),
                  request.taskID == task.id,
                  request.executionPolicySnapshotJSON == nil || request.executionPolicySnapshot != nil,
                  request.executionPolicySnapshot?.resourceScope == launchSnapshot.resourceScope else {
                throw RuntimeTurnSettlementService.Failure.invalidRequestOwner
            }
        }
        try executionContext(for: task).bindStorage(task: task, modelContext: modelContext)
    }
}
