import Foundation
import ASTRAModels

/// Immutable request-time configuration passed through a runtime launch.
/// Keeping this value outside SwiftData prevents a queued request from
/// rewriting editable task preferences while it waits for a worker.
struct AgentTaskLaunchSnapshot: Sendable, Equatable {
    let id: UUID
    let model: String
    let maxTurns: Int
    let runtimeID: String?
    let runtimeExplicitlySelected: Bool
    let tokenBudget: Int
    let isolationStrategy: IsolationStrategy
    let validationStrategy: ValidationStrategy
    let testCommand: String
    let useAgentTeam: Bool
    let teamSize: Int
    let teamInstructions: String
    let executionRootPath: String?
    let executionEnvironmentSnapshotJSON: String?
    let templateHooksJSON: String
    let skillSnapshotsJSON: String
    let runtimePermissionGrantsJSON: String?

    init(task: AgentTask) {
        id = task.id
        model = task.model
        maxTurns = task.maxTurns
        runtimeID = task.runtimeID
        runtimeExplicitlySelected = task.runtimeExplicitlySelected
        tokenBudget = task.tokenBudget
        isolationStrategy = task.isolationStrategy
        validationStrategy = task.validationStrategy
        testCommand = task.testCommand
        useAgentTeam = task.useAgentTeam
        teamSize = task.teamSize
        teamInstructions = task.teamInstructions
        executionRootPath = task.executionRootPath
        executionEnvironmentSnapshotJSON = task.executionEnvironmentSnapshotJSON
        templateHooksJSON = task.templateHooksJSON
        skillSnapshotsJSON = task.skillSnapshotsJSON
        runtimePermissionGrantsJSON = task.runtimePermissionGrantsJSON
    }

    init(
        id: UUID,
        model: String,
        maxTurns: Int,
        runtimeID: String?,
        runtimeExplicitlySelected: Bool,
        tokenBudget: Int,
        isolationStrategy: IsolationStrategy,
        validationStrategy: ValidationStrategy,
        testCommand: String,
        useAgentTeam: Bool,
        teamSize: Int,
        teamInstructions: String,
        executionRootPath: String?,
        executionEnvironmentSnapshotJSON: String?,
        templateHooksJSON: String,
        skillSnapshotsJSON: String,
        runtimePermissionGrantsJSON: String?
    ) {
        self.id = id
        self.model = model
        self.maxTurns = maxTurns
        self.runtimeID = runtimeID
        self.runtimeExplicitlySelected = runtimeExplicitlySelected
        self.tokenBudget = tokenBudget
        self.isolationStrategy = isolationStrategy
        self.validationStrategy = validationStrategy
        self.testCommand = testCommand
        self.useAgentTeam = useAgentTeam
        self.teamSize = teamSize
        self.teamInstructions = teamInstructions
        self.executionRootPath = executionRootPath
        self.executionEnvironmentSnapshotJSON = executionEnvironmentSnapshotJSON
        self.templateHooksJSON = templateHooksJSON
        self.skillSnapshotsJSON = skillSnapshotsJSON
        self.runtimePermissionGrantsJSON = runtimePermissionGrantsJSON
    }
}
