import Foundation
import ASTRACore
import ASTRAModels

/// Immutable request-time configuration passed through a runtime launch.
/// Keeping this value outside SwiftData prevents a queued request from
/// rewriting editable task preferences while it waits for a worker.
struct AgentTaskLaunchSnapshot: Codable, Sendable, Equatable {
    let id: UUID
    let model: String
    let reasoningEffort: String?
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
    /// The plugin activations the launch runs with (see
    /// `TaskExecutionPolicySnapshotV1.pluginActivations`); nil reads the live
    /// workspace's.
    let pluginActivations: [PluginActivationRecord]?
    /// The plugin definitions and bound accounts frozen with those
    /// activations (`TaskExecutionPolicySnapshotV1`); nil reads the live
    /// library and rows.
    let pluginDefinitions: [PluginPackage]?
    let pluginAccounts: [PluginAccountRecord]?

    init(task: AgentTask) {
        id = task.id
        model = task.model
        reasoningEffort = task.reasoningEffort
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
        pluginActivations = task.workspace.map {
            WorkspaceCapabilityActivation.activations(of: $0).map(PluginActivationRecord.init)
        }
        // A launch copy carries its request's frozen definitions on; a live
        // task is projected from the library as it is now.
        pluginDefinitions = task.workspace?.launchPluginDefinitions
        pluginAccounts = task.workspace.map(PluginAccountRecord.boundAccounts(of:))
    }

    init(
        id: UUID,
        model: String,
        reasoningEffort: String?,
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
        runtimePermissionGrantsJSON: String?,
        pluginActivations: [PluginActivationRecord]? = nil,
        pluginDefinitions: [PluginPackage]? = nil,
        pluginAccounts: [PluginAccountRecord]? = nil
    ) {
        self.id = id
        self.model = model
        self.reasoningEffort = reasoningEffort
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
        self.pluginActivations = pluginActivations
        self.pluginDefinitions = pluginDefinitions
        self.pluginAccounts = pluginAccounts
    }
}
