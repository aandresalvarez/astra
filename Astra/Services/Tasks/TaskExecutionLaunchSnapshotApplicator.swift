import Foundation
import ASTRAModels

/// Applies the immutable launch configuration captured by a durable request.
/// The queue uses this only for the lifetime of one dispatch, then restores the
/// task's current editable configuration so queue waiting never rewrites user
/// preferences.
@MainActor
enum TaskExecutionLaunchSnapshotApplicator {
    struct Restoration {
        private let snapshot: TaskExecutionPolicySnapshotV1
        private let runtimeID: String?
        private let model: String
        private let tokenBudget: Int

        fileprivate init(task: AgentTask) {
            snapshot = TaskExecutionPolicySnapshotV1(task: task)
            runtimeID = task.runtimeID
            model = task.model
            tokenBudget = task.tokenBudget
        }

        func restore(_ task: AgentTask) {
            Self.apply(snapshot, runtimeID: runtimeID, model: model, tokenBudget: tokenBudget, to: task)
        }

        fileprivate static func apply(
            _ snapshot: TaskExecutionPolicySnapshotV1,
            runtimeID: String?,
            model: String,
            tokenBudget: Int,
            to task: AgentTask
        ) {
            task.runtimeID = runtimeID
            task.model = model
            task.tokenBudget = tokenBudget
            task.runtimeExplicitlySelected = snapshot.runtimeExplicitlySelected
            task.maxTurns = snapshot.maxTurns
            task.isolationStrategy = IsolationStrategy(rawValue: snapshot.isolationStrategyRawValue) ?? .sameDirectory
            task.validationStrategy = ValidationStrategy(rawValue: snapshot.validationStrategyRawValue) ?? .manual
            task.testCommand = snapshot.testCommand
            task.useAgentTeam = snapshot.useAgentTeam
            task.teamSize = snapshot.teamSize
            task.teamInstructions = snapshot.teamInstructions
            task.executionRootPath = snapshot.executionRootPath
            task.executionEnvironmentSnapshotJSON = snapshot.executionEnvironmentSnapshotJSON
            task.templateHooksJSON = snapshot.templateHooksJSON
            task.skillSnapshotsJSON = snapshot.skillSnapshotsJSON
            task.runtimePermissionGrantsJSON = snapshot.runtimePermissionGrantsJSON
        }
    }

    /// Legacy V15 requests have no complete snapshot and intentionally keep
    /// their historical live-task behavior. A malformed V16 policy also fails
    /// closed without partially applying a mixed launch configuration.
    static func apply(request: TaskTurnRequest, to task: AgentTask) -> Restoration? {
        guard let runtimeID = request.runtimeIDSnapshot,
              let model = request.modelSnapshot,
              let tokenBudget = request.tokenBudgetSnapshot,
              let policy = request.executionPolicySnapshot,
              IsolationStrategy(rawValue: policy.isolationStrategyRawValue) != nil,
              ValidationStrategy(rawValue: policy.validationStrategyRawValue) != nil else {
            return nil
        }
        let restoration = Restoration(task: task)
        Restoration.apply(
            policy,
            runtimeID: runtimeID,
            model: model,
            tokenBudget: tokenBudget,
            to: task
        )
        return restoration
    }
}
